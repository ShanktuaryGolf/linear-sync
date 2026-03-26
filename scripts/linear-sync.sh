#!/bin/bash
# Linear Pipeline Sync v3 — Polls Linear and dispatches polecats via Gas Town.
#
# v3 changes (from v2):
# - Restored Phase 0: clean up idle/done polecats before checking for stuck work
# - All bead queries use Dolt directly (bd list --rig routing is unreliable)
# - Fixed merge detection: only matches beads with 'merge' in description/close_reason
# - Removed dangerous "move back to Todo" fallback that caused bounce loops
# - Added dedup check before dispatch to prevent duplicate polecats
#
# Configure via .env at the path specified by ENV_FILE below.
set -euo pipefail

# ---------------------------------------------------------------------------
# Config — reads from .env
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/../.env}"

if [ -f "$ENV_FILE" ]; then set -a; source "$ENV_FILE"; set +a; fi

: "${LINEAR_API_KEY:?Set LINEAR_API_KEY in .env}"
: "${LINEAR_TEAM_ID:?Set LINEAR_TEAM_ID in .env}"
: "${LINEAR_PROJECT_SLUG:?Set LINEAR_PROJECT_SLUG in .env}"
: "${GT_ROOT:?Set GT_ROOT in .env}"
: "${GT_RIG:?Set GT_RIG in .env}"

: "${LINEAR_STATE_IN_PROGRESS:?Set LINEAR_STATE_IN_PROGRESS in .env}"
: "${LINEAR_STATE_HUMAN_REVIEW:?Set LINEAR_STATE_HUMAN_REVIEW in .env}"
: "${LINEAR_STATE_CODE_REVIEW:=${LINEAR_STATE_HUMAN_REVIEW}}"
: "${LINEAR_STATE_TODO:=c184b789-8a72-4890-a5cf-e9da56175a0e}"
: "${LINEAR_STATE_DONE:=e052dd42-2d08-46cf-b065-82f588c3f806}"
: "${DOLT_PORT:=3307}"

LOG_FILE="$SCRIPT_DIR/linear-sync.log"
ROTATION_FILE="$SCRIPT_DIR/.review-rotation"

# Track issues moved this run to avoid re-dispatching
MOVED_THIS_RUN=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG_FILE"; }

linear_query() {
    curl -s --max-time 15 -X POST https://api.linear.app/graphql \
        -H "Authorization: $LINEAR_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$1"
}

move_to_state() {
    linear_query "{\"query\": \"mutation { issueUpdate(id: \\\"$1\\\", input: { stateId: \\\"$2\\\" }) { success } }\"}" > /dev/null
}

# Query rig's Dolt database directly — bd list --rig routing is unreliable
dolt_query() {
    mysql -h 127.0.0.1 -P "$DOLT_PORT" -u root "$GT_RIG" -N -e "$1" 2>/dev/null || true
}

get_last_stage() {
    linear_query "{\"query\": \"{ issue(id: \\\"$1\\\") { comments { nodes { body } } } }\"}" | \
        python3 -c "
import sys, json
comments = json.load(sys.stdin)['data']['issue']['comments']['nodes']
for c in comments:
    b = c['body']
    if b.startswith('## Code Review'): print('code-review'); sys.exit()
    if b.startswith('## Implementation'): print('implementation'); sys.exit()
    if b.startswith('## Investigation'): print('investigation'); sys.exit()
print('none')
"
}

next_reviewer() {
    local reviewers=("gemini-review" "opencode-review" "codex-review" "claude")
    local last=""
    if [ -f "$ROTATION_FILE" ]; then last=$(cat "$ROTATION_FILE"); fi
    local next="${reviewers[0]}"
    for i in "${!reviewers[@]}"; do
        if [ "${reviewers[$i]}" = "$last" ]; then
            local next_idx=$(( (i + 1) % ${#reviewers[@]} ))
            next="${reviewers[$next_idx]}"
            break
        fi
    done
    echo "$next" > "$ROTATION_FILE"
    echo "$next"
}

# ---------------------------------------------------------------------------
# Phase 0: Clean up idle/done polecats
# ---------------------------------------------------------------------------
log "Starting linear-sync"

ALL_POLECATS=$(cd "$GT_ROOT" && gt polecat list --all 2>/dev/null || true)
POLECAT_LINES=$(echo "$ALL_POLECATS" | grep -E "●|○" || true)
if [ -n "$POLECAT_LINES" ]; then
    echo "$POLECAT_LINES" | while read -r line; do
        polecat_name=$(echo "$line" | awk '{print $2}')
        polecat_state=$(echo "$line" | awk '{print $3}')
        if [ -z "$polecat_name" ]; then continue; fi

        # Clean up finished polecats (idle/done)
        if echo "$polecat_state" | grep -qE "idle|done"; then
            log "Cleaning up finished polecat: $polecat_name"
            cd "$GT_ROOT" && gt polecat nuke "$polecat_name" --force >> "$LOG_FILE" 2>&1 || true
            continue
        fi

        # Clean up orphaned polecats (state=working but tmux session is dead)
        if [ "$polecat_state" = "working" ]; then
            session_name="sl-$(echo "$polecat_name" | sed 's|.*/||')"
            if ! tmux has-session -t "$session_name" 2>/dev/null; then
                log "Cleaning up orphaned polecat (dead session): $polecat_name"
                cd "$GT_ROOT" && gt polecat nuke "$polecat_name" --force >> "$LOG_FILE" 2>&1 || true
            fi
        fi
    done
fi

# ---------------------------------------------------------------------------
# Phase 1: Sync completed work back to Linear
# ---------------------------------------------------------------------------
# Check "In Progress" issues in Linear. If no polecat is actively working on
# one, sync the Linear state forward based on what was accomplished.

IP_ISSUES=$(linear_query "{\"query\": \"{ team(id: \\\"$LINEAR_TEAM_ID\\\") { issues(filter: { project: { slugId: { eq: \\\"$LINEAR_PROJECT_SLUG\\\" } }, state: { name: { eq: \\\"In Progress\\\" } } }) { nodes { id identifier title } } } }\"}")
IP_COUNT=$(echo "$IP_ISSUES" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['data']['team']['issues']['nodes']))" 2>/dev/null || echo "0")

if [ "$IP_COUNT" != "0" ]; then
    # Check both Dolt beads AND working polecats for active work detection
    ACTIVE_BEADS=$(dolt_query "SELECT CONCAT(id, ' ', title) FROM issues WHERE status IN ('hooked','in_progress')")
    WORKING_POLECATS=$(cd "$GT_ROOT" && gt polecat list --all 2>/dev/null | grep "working" || true)

    echo "$IP_ISSUES" | python3 -c "
import sys, json
for n in json.load(sys.stdin)['data']['team']['issues']['nodes']:
    print(f\"{n['identifier']}|{n['id']}\")
" | while IFS='|' read -r identifier issue_uuid; do
        # Check if actively being worked — via bead status OR working polecat
        if echo "$ACTIVE_BEADS" | grep -q "$identifier" 2>/dev/null; then
            log "ACTIVE: $identifier has hooked/in_progress bead — skipping"
            continue
        fi
        if [ -n "$WORKING_POLECATS" ] && echo "$WORKING_POLECATS" | grep -q "working" 2>/dev/null; then
            # Double-check: is any working polecat's bead for this issue?
            for pc_bead in $(echo "$WORKING_POLECATS" | awk 'NR%2==0{print $1}'); do
                pc_title=$(dolt_query "SELECT title FROM issues WHERE id='$pc_bead' LIMIT 1")
                if echo "$pc_title" | grep -q "$identifier" 2>/dev/null; then
                    log "ACTIVE: $identifier has working polecat (bead $pc_bead) — skipping"
                    continue 2
                fi
            done
        fi

        # No active work — check if already merged
        was_merged=$(dolt_query "SELECT 'yes' FROM issues WHERE title LIKE '${identifier}:%' AND status = 'closed' AND (description LIKE '%merge stage%' OR close_reason LIKE '%merge%') LIMIT 1")
        if [ "$was_merged" = "yes" ]; then
            log "SYNC: $identifier already merged — moving to Done"
            move_to_state "$issue_uuid" "$LINEAR_STATE_DONE"
            MOVED_THIS_RUN="$MOVED_THIS_RUN $identifier"
            continue
        fi

        # Determine what stage completed. Check both Linear comments AND the
        # most recent closed bead's description (polecat may finish without posting).
        last_stage=$(get_last_stage "$identifier")

        # Also check the bead to see what stage was dispatched
        bead_id=$(dolt_query "SELECT id FROM issues WHERE title LIKE '${identifier}:%' AND status = 'closed' ORDER BY updated_at DESC LIMIT 1")
        bead_stage=""
        if [ -n "$bead_id" ]; then
            bead_stage=$(dolt_query "SELECT description FROM issues WHERE id = '$bead_id'" | \
                python3 -c "
import sys
d = sys.stdin.read().strip()
if 'merge stage' in d: print('code-review')
elif 'code-review stage' in d: print('code-review')
elif 'implement stage' in d: print('implementation')
elif 'investigate stage' in d: print('investigation')
else: print('none')
" 2>/dev/null || echo "none")
        fi

        # Use whichever gives more information — prefer bead stage if Linear
        # comments are stale (common when polecat finishes without posting)
        effective_stage="$last_stage"
        if [ "$last_stage" = "none" ] && [ "$bead_stage" != "none" ] && [ -n "$bead_stage" ]; then
            effective_stage="$bead_stage"
            log "  Using bead stage ($bead_stage) — no matching Linear comment found"
        elif [ "$bead_stage" != "none" ] && [ -n "$bead_stage" ] && [ "$bead_stage" != "$last_stage" ]; then
            # Bead shows a later stage than Linear comments — use bead
            effective_stage="$bead_stage"
            log "  Bead stage ($bead_stage) is newer than Linear comment stage ($last_stage)"
        fi

        if [ "$effective_stage" != "none" ]; then
            # Stage completed — advance to next gate
            if [ "$effective_stage" = "implementation" ]; then
                target_state="$LINEAR_STATE_CODE_REVIEW"
                target_name="Code Review"
            else
                target_state="$LINEAR_STATE_HUMAN_REVIEW"
                target_name="Human Review"
            fi

            # Try to recover and post findings if they're not already on Linear
            if [ -n "$bead_id" ] && [ "$last_stage" != "$effective_stage" ]; then
                findings=$(cd "$GT_ROOT" && bd show "$bead_id" --json 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if isinstance(d, list): d = d[0]
    design = d.get('design', '')
    notes = d.get('notes', '')
    if design and len(design) > 50: print(design)
    elif notes and len(notes) > 20: print(notes)
except: pass
" 2>/dev/null || true)

                if [ -n "$findings" ]; then
                    stage_header="## Investigation"
                    if [ "$effective_stage" = "implementation" ]; then stage_header="## Implementation"; fi
                    if [ "$effective_stage" = "code-review" ]; then stage_header="## Code Review"; fi

                    log "  Posting recovered findings for $identifier ($effective_stage)"
                    python3 -c "
import json, sys
body = '''$stage_header

$findings

_Agent: sync-timer (recovered from bead $bead_id)_'''
payload = {
    'query': 'mutation(\$input: CommentCreateInput!) { commentCreate(input: \$input) { success } }',
    'variables': {'input': {'issueId': '$issue_uuid', 'body': body}}
}
json.dump(payload, sys.stdout)
" | curl -s --max-time 15 -X POST https://api.linear.app/graphql \
                        -H "Authorization: $LINEAR_API_KEY" \
                        -H "Content-Type: application/json" \
                        -d @- > /dev/null
                fi
            fi

            log "SYNC: $identifier ($effective_stage done) → $target_name"
            move_to_state "$issue_uuid" "$target_state"
            MOVED_THIS_RUN="$MOVED_THIS_RUN $identifier"
        else
            # No stage determined from Linear comments or bead — truly stuck
            log "STUCK: $identifier — no stage info found. Leaving In Progress for human triage."
        fi
    done
fi

# ---------------------------------------------------------------------------
# Phase 2: Poll for actionable issues and dispatch
# ---------------------------------------------------------------------------
ISSUES=$(linear_query "{\"query\": \"{ team(id: \\\"$LINEAR_TEAM_ID\\\") { issues(filter: { project: { slugId: { eq: \\\"$LINEAR_PROJECT_SLUG\\\" } }, state: { name: { in: [\\\"Todo\\\", \\\"Gate Approved\\\", \\\"Code Review\\\", \\\"Rework\\\"] } } }) { nodes { id identifier title url state { name } priority } } } }\"}")
COUNT=$(echo "$ISSUES" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['data']['team']['issues']['nodes']))" 2>/dev/null || echo "0")

if [ "$COUNT" = "0" ]; then
    log "No actionable issues"
    # Dock rig if no work and no active polecats
    WORKING=$(cd "$GT_ROOT" && gt polecat list --all 2>/dev/null | grep -c "working" || echo "0")
    if [ "$WORKING" = "0" ]; then
        RIG_STATUS=$(cd "$GT_ROOT" && gt rig list 2>/dev/null | grep -A1 "$GT_RIG" | grep -c "running" || echo "0")
        if [ "$RIG_STATUS" != "0" ]; then
            log "No work, no polecats — docking $GT_RIG to save API costs"
            cd "$GT_ROOT" && gt rig dock "$GT_RIG" >> "$LOG_FILE" 2>&1 || true
        fi
    fi
    exit 0
fi

log "Found $COUNT actionable issue(s)"

# Undock rig if needed
RIG_DOCKED=$(cd "$GT_ROOT" && gt rig list 2>/dev/null | grep -A1 "$GT_RIG" | grep -c "docked" || echo "0")
if [ "$RIG_DOCKED" != "0" ]; then
    log "Undocking $GT_RIG for work dispatch"
    cd "$GT_ROOT" && gt rig undock "$GT_RIG" >> "$LOG_FILE" 2>&1 || true
    cd "$GT_ROOT" && gt rig start "$GT_RIG" >> "$LOG_FILE" 2>&1 || true
    sleep 3
fi

# Dispatch each actionable issue
echo "$ISSUES" | python3 -c "
import sys, json
for n in json.load(sys.stdin)['data']['team']['issues']['nodes']:
    print(f\"{n['identifier']}|{n['title']}|{n['url']}|{n['state']['name']}|{n['priority']}|{n['id']}\")
" | while IFS='|' read -r identifier title url state priority issue_uuid; do

    log "Processing $identifier: $title (state=$state)"

    if echo "$MOVED_THIS_RUN" | grep -q "$identifier" 2>/dev/null; then
        log "SKIP: $identifier was just moved this run"
        continue
    fi

    # Re-check current state to avoid races
    current_state=$(linear_query "{\"query\": \"{ issue(id: \\\"$identifier\\\") { state { name } } }\"}" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['issue']['state']['name'])" 2>/dev/null || echo "unknown")
    if [ "$current_state" = "Done" ] || [ "$current_state" = "Canceled" ] || [ "$current_state" = "Cancelled" ] || [ "$current_state" = "Human Review" ] || [ "$current_state" = "In Progress" ]; then
        log "SKIP: $identifier is already $current_state"
        continue
    fi

    # Determine stage and agent
    if [ "$state" = "Todo" ]; then
        stage="investigate"; agent="claude"; sling_flags="--no-merge"
    elif [ "$state" = "Code Review" ]; then
        stage="code-review"; agent=$(next_reviewer); sling_flags="--no-merge"
    elif [ "$state" = "Gate Approved" ] || [ "$state" = "Rework" ]; then
        last_stage=$(get_last_stage "$identifier")
        case "$last_stage" in
            investigation) stage="implement"
                if [ "$priority" -le 2 ]; then agent="claude"; else agent="codex-impl"; fi
                sling_flags="--no-merge" ;;
            implementation) stage="code-review"; agent=$(next_reviewer); sling_flags="--no-merge" ;;
            code-review) stage="merge"; agent="claude"; sling_flags="" ;;
            *) log "WARNING: Could not determine stage for $identifier, skipping"; continue ;;
        esac
        if [ "$state" = "Rework" ]; then
            case "$last_stage" in
                investigation) stage="investigate" ;; implementation) stage="implement" ;; code-review) stage="code-review" ;;
            esac
        fi
    fi

    log "$identifier -> $stage (agent=$agent)"

    # Dedup: check for existing in-flight bead for this issue
    existing=$(dolt_query "SELECT id FROM issues WHERE title LIKE '${identifier}:%' AND status IN ('hooked','in_progress','open') LIMIT 1")
    if [ -n "$existing" ]; then
        log "SKIP: $identifier already has in-flight bead $existing in $GT_RIG"
        continue
    fi

    # Create bead and dispatch
    bead_id=$(cd "$GT_ROOT" && bd create --rig "$GT_RIG" \
        --title="$identifier: $title" \
        --description="$stage stage for $identifier. Agent: $agent" \
        --type=task --priority="$priority" --json 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

    if [ -z "$bead_id" ]; then log "ERROR: Failed to create bead for $identifier"; continue; fi

    sling_args="LINEAR: $stage $identifier $url"
    if [ "$state" = "Rework" ]; then sling_args="LINEAR: $stage REWORK: $identifier $url"; fi

    agent_flag=""
    if [ "$agent" != "claude" ]; then agent_flag="--agent $agent"; fi

    if cd "$GT_ROOT" && gt sling "$bead_id" "$GT_RIG" $sling_flags $agent_flag --args "$sling_args" >> "$LOG_FILE" 2>&1; then
        log "Slung $identifier ($stage) to $GT_RIG with agent $agent"
        move_to_state "$issue_uuid" "$LINEAR_STATE_IN_PROGRESS"
    elif [ "$agent" != "claude" ]; then
        log "WARNING: Agent $agent failed — falling back to claude"
        if cd "$GT_ROOT" && gt sling "$bead_id" "$GT_RIG" $sling_flags --args "$sling_args" >> "$LOG_FILE" 2>&1; then
            log "Slung $identifier ($stage) with claude (fallback)"
            move_to_state "$issue_uuid" "$LINEAR_STATE_IN_PROGRESS"
        else
            log "ERROR: Failed to sling $identifier even with claude"
        fi
    else
        log "ERROR: Failed to sling $identifier"
    fi
done

log "linear-sync complete"
