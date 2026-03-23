#!/bin/bash
# Linear Pipeline Sync v2 — Polls Linear and dispatches polecats via Gas Town.
#
# v2 changes:
# - Removed polecat cleanup (Phase 0) — GT Witness handles polecat lifecycle
# - Kept bead-recovery logic from Phase 0.5 for Linear sync-back: if a polecat
#   completes without posting to Linear, we recover findings from the bead and
#   post them. Witness handles the GT side (restart/cleanup), we handle Linear.
# - Dispatch logic unchanged
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
# Phase 1: Sync completed work back to Linear
# ---------------------------------------------------------------------------
# Check "In Progress" issues in Linear. If no GT bead is actively working on
# one, the polecat either completed or died. Witness handles the GT side
# (restart/cleanup). We just sync the Linear state forward if work is done.

log "Starting linear-sync"

IP_ISSUES=$(linear_query "{\"query\": \"{ team(id: \\\"$LINEAR_TEAM_ID\\\") { issues(filter: { project: { slugId: { eq: \\\"$LINEAR_PROJECT_SLUG\\\" } }, state: { name: { eq: \\\"In Progress\\\" } } }) { nodes { id identifier title } } } }\"}")
IP_COUNT=$(echo "$IP_ISSUES" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['data']['team']['issues']['nodes']))" 2>/dev/null || echo "0")

if [ "$IP_COUNT" != "0" ]; then
    ACTIVE_BEADS=$(cd "$GT_ROOT" && bd list --status=hooked --status=in_progress --rig "$GT_RIG" 2>/dev/null || true)

    echo "$IP_ISSUES" | python3 -c "
import sys, json
for n in json.load(sys.stdin)['data']['team']['issues']['nodes']:
    print(f\"{n['identifier']}|{n['id']}\")
" | while IFS='|' read -r identifier issue_uuid; do
        # Still being worked on — skip
        if echo "$ACTIVE_BEADS" | grep -q "$identifier" 2>/dev/null; then continue; fi

        # No active bead — check if the stage completed (comment exists on Linear)
        last_stage=$(get_last_stage "$identifier")

        if [ "$last_stage" != "none" ]; then
            # Stage completed but Linear still shows In Progress — sync it forward
            if [ "$last_stage" = "implementation" ]; then
                target_state="$LINEAR_STATE_CODE_REVIEW"
                target_name="Code Review"
            else
                target_state="$LINEAR_STATE_HUMAN_REVIEW"
                target_name="Human Review"
            fi
            log "SYNC: $identifier ($last_stage done) → $target_name"
            move_to_state "$issue_uuid" "$target_state"
            MOVED_THIS_RUN="$MOVED_THIS_RUN $identifier"
        else
            # No Linear comment — polecat may have completed without posting.
            # Try to recover findings from the bead and post them to Linear.
            bead_id=$(cd "$GT_ROOT" && bd list --all --rig "$GT_RIG" --json 2>/dev/null | python3 -c "
import sys, json
try:
    for i in sorted(json.load(sys.stdin), key=lambda x: x.get('updated_at',''), reverse=True):
        if '$identifier' in i.get('title', ''):
            print(i['id']); break
except: pass
" 2>/dev/null || true)

            if [ -z "$bead_id" ]; then continue; fi

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
                log "Posting recovered findings for $identifier"
                stage_header="## Investigation"
                if cd "$GT_ROOT" && bd show "$bead_id" 2>/dev/null | grep -qi "implement"; then
                    stage_header="## Implementation"
                fi

                python3 -c "
import json, sys
body = '''$stage_header

$findings

_Agent: sync-timer (recovered from bead)_'''
payload = {
    'query': 'mutation(\$input: CommentCreateInput!) { commentCreate(input: \$input) { success } }',
    'variables': {'input': {'issueId': '$issue_uuid', 'body': body}}
}
json.dump(payload, sys.stdout)
" | curl -s --max-time 15 -X POST https://api.linear.app/graphql \
                    -H "Authorization: $LINEAR_API_KEY" \
                    -H "Content-Type: application/json" \
                    -d @- > /dev/null

                if echo "$stage_header" | grep -qi "implementation"; then
                    recovery_state="$LINEAR_STATE_CODE_REVIEW"
                else
                    recovery_state="$LINEAR_STATE_HUMAN_REVIEW"
                fi
                move_to_state "$issue_uuid" "$recovery_state"
                MOVED_THIS_RUN="$MOVED_THIS_RUN $identifier"
            else
                # No findings in bead either — move back to Todo for re-dispatch
                log "RECOVER: $identifier stuck with no findings — moving back to Todo"
                move_to_state "$issue_uuid" "$LINEAR_STATE_TODO"
                MOVED_THIS_RUN="$MOVED_THIS_RUN $identifier"
            fi
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
