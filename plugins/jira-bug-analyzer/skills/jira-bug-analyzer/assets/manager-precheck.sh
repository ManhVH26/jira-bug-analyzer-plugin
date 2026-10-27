#!/usr/bin/env bash
# manager-precheck.sh — cheap "did anything change?" gate run FIRST on every --manager loop fire.
#
# Most /loop fires find nothing new; without this gate each one still reads the phase files and
# walks Jobs A–H on the main model (~144 fires/day at MANAGER_LOOP=10 min). This script answers
# from local state + `gh` only, and hands the model ONE Jira query to confirm.
#
# Usage: bash manager-precheck.sh <project-root> <BOARD-KEY>
# Output (KEY=VALUE lines):
#   LOCAL=quiet|changed       pr-watch PR state/updatedAt or new Discord inbox files changed since last fire
#   FULL_DUE=yes|no           a full pass is forced every FULL_EVERY fires as a safety net
#   JIRA_JQL=<jql>            run once with jira_search (limit 1); total 0 + LOCAL=quiet + FULL_DUE=no -> end the pass
#   CHANGED_PRS=<n> INBOX_NEW=<n>
# Writes .jira-bug/manager-precheck.json (fingerprint, fire count, last fire time). Never touches Jira/GitHub state.
set -euo pipefail

ROOT="${1:?usage: manager-precheck.sh <project-root> <BOARD-KEY>}"
BOARD="${2:?usage: manager-precheck.sh <project-root> <BOARD-KEY>}"
FULL_EVERY="${MANAGER_PRECHECK_FULL_EVERY:-6}"
JB="$ROOT/.jira-bug"
STATE="$JB/manager-precheck.json"
mkdir -p "$JB"

# Current PR fingerprint: "<pr> <state> <updatedAt>" per pr-watch entry (gh failure -> "unreadable", counts as change).
PRS=""
if [ -f "$JB/pr-watch.json" ]; then
  PRS="$(python3 - "$JB/pr-watch.json" <<'PY' || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
# Map keyed by PR number (references/helpers/pr-merge-watcher.md): {"<PR>": {"pr": 123, ...}}
for k, e in (d.items() if isinstance(d, dict) else []):
    print((e.get("url") or e.get("pr") or k) if isinstance(e, dict) else k)
PY
)"
fi
FP=""
while IFS= read -r pr; do
  [ -z "$pr" ] && continue
  line="$(gh pr view "$pr" --json state,updatedAt -q '.state+" "+.updatedAt' 2>/dev/null || echo unreadable)"
  FP="${FP}${pr} ${line}"$'\n'
done <<< "$PRS"

INBOX_NEW=0
if [ -d "$JB/discord-inbox" ]; then
  INBOX_NEW="$(find "$JB/discord-inbox" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')"
fi

NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
python3 - "$STATE" "$FP" "$INBOX_NEW" "$FULL_EVERY" "$NOW_ISO" "$BOARD" <<'PY'
import json, sys
from datetime import datetime, timedelta
state_path, fp, inbox_new, full_every, now_iso, board = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5], sys.argv[6]
try:
    st = json.load(open(state_path))
except Exception:
    st = {}
def by_pr(text):
    return {l.split(" ", 1)[0]: l for l in text.splitlines() if l.strip()}
old, new = by_pr(st.get("fingerprint") or ""), by_pr(fp)
changed_prs = sum(1 for k in set(old) | set(new) if old.get(k) != new.get(k))
fires = int(st.get("fires", 0)) + 1
full_due = (fires % full_every == 0) or not st
local = "changed" if (changed_prs or inbox_new or not st) else "quiet"
# Jira "updated" is minute-granular in the server's zone; look back from the last fire minus 2 min of slack.
last = st.get("last_fire") or now_iso
since = datetime.strptime(last, "%Y-%m-%dT%H:%M:%SZ") - timedelta(minutes=2)
mins = max(1, int((datetime.strptime(now_iso, "%Y-%m-%dT%H:%M:%SZ") - since).total_seconds() // 60))
jql = (f'project = {board} AND updated >= -{mins}m AND (labels in ("auto-fixed","analyzed-deferred") '
       f'OR statusCategory = Done OR status = Reopened)')
json.dump({"fingerprint": fp, "fires": fires, "last_fire": now_iso}, open(state_path, "w"), indent=2)
print(f"LOCAL={local}")
print(f"FULL_DUE={'yes' if full_due else 'no'}")
print(f"CHANGED_PRS={changed_prs}")
print(f"INBOX_NEW={inbox_new}")
print(f"JIRA_JQL={jql}")
PY
