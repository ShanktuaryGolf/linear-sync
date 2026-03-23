#!/bin/bash
# Linear Pipeline Status — Show current state of all issues.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/../.env}"
if [ -f "$ENV_FILE" ]; then set -a; source "$ENV_FILE"; set +a; fi

: "${LINEAR_API_KEY:?Set LINEAR_API_KEY}"
: "${LINEAR_TEAM_ID:?Set LINEAR_TEAM_ID}"
: "${LINEAR_PROJECT_SLUG:?Set LINEAR_PROJECT_SLUG}"

ISSUES=$(curl -s --max-time 15 -X POST https://api.linear.app/graphql \
    -H "Authorization: $LINEAR_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"query\": \"{ team(id: \\\"$LINEAR_TEAM_ID\\\") { issues(filter: { project: { slugId: { eq: \\\"$LINEAR_PROJECT_SLUG\\\" } } }, first: 100) { nodes { identifier title state { name type } priority completedAt } } } }\"}")

python3 -c "
import sys, json
data = json.load(sys.stdin)['data']['team']['issues']['nodes']
groups = {'Gate Approved':[],'Human Review':[],'Code Review':[],'Rework':[],'In Progress':[],'Todo':[],'done':[]}
for i in data:
    s = i['state']['name']
    e = (i['identifier'], i['title'], i['priority'], i.get('completedAt',''))
    if s in groups: groups[s].append(e)
    elif i['state']['type'] in ('completed','canceled'): groups['done'].append(e)
print()
print('Pipeline Status')
print('='*50)
for label, items in [('GATE APPROVED',groups['Gate Approved']),('WAITING FOR REVIEW',groups['Human Review']),
    ('CODE REVIEW',groups['Code Review']),('REWORK',groups['Rework']),
    ('IN PROGRESS',groups['In Progress']),('TODO',groups['Todo'])]:
    if items:
        print(f'\n{label}:')
        for ident,title,pri,_ in items: print(f'  {ident}  \"{title}\"  P{pri}')
if groups['done']:
    print('\nDONE:')
    for ident,title,pri,c in sorted(groups['done'],key=lambda x:x[3] or '',reverse=True):
        print(f'  {ident}  \"{title}\"  {(c or \"\")[:10]}')
print()
" <<< "$ISSUES"

if command -v gt &> /dev/null && [ -n "${GT_ROOT:-}" ]; then
    echo "Active polecats:"
    cd "$GT_ROOT" && gt polecat list --all 2>/dev/null || echo "  (none)"
    echo
fi
