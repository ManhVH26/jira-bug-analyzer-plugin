#!/usr/bin/env bash
# setup_run.sh <variant> <TICKET> [--skill <dir>]  -> builds an isolated run dir runs/<TICKET>-<variant>; prints RUN=<dir>
#   --skill   the skill folder to test (default: this repo's plugins/jira-bug-analyzer/skills/jira-bug-analyzer);
#             pass an older copy to get the "before" side of an A/B
#   --desc    a file whose text replaces the ticket's description in this run's Jira mock (the same ticket written
#             differently by QA — e.g. to the QA template, or half of it); attachments and comments stay
#   --map-from  start from this app map and do not save what the run learns back to runs/_kept (runs that are
#             compared with each other then all start from the same map, whatever order they run in)
# Needs cases.json (copy cases.example.json) and tickets/<TICKET>/issue.json (snapshot.py).
set -euo pipefail
VER="$1"; T="$2"; shift 2
SB="$(cd "$(dirname "$0")" && pwd)"; REPO_ROOT="$(cd "$SB/../.." && pwd)"
SKILL="$REPO_ROOT/plugins/jira-bug-analyzer/skills/jira-bug-analyzer"
CONNECTORS=""; DESC=""; MAPFROM=""
while [ $# -gt 0 ]; do case "$1" in --skill) SKILL="$2"; shift 2 ;; --connectors) CONNECTORS="$2"; shift 2 ;; --desc) DESC="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift 2 ;; --map-from) MAPFROM="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift 2 ;; *) echo "unknown option $1"; exit 2 ;; esac; done
[ -z "$CONNECTORS" ] || [ "$CONNECTORS" = confluence-read ] || { echo "--connectors: only confluence-read is supported"; exit 2; }
[ -f "$SB/cases.json" ] || { echo "no cases.json — copy cases.example.json and fill it"; exit 2; }
[ -f "$SB/tickets/$T/issue.json" ] || { echo "no tickets/$T/issue.json — run snapshot.py tickets $T"; exit 2; }
read -r R FIX BR CUT < <(python3 - "$SB/cases.json" "$T" <<'PY'
import json, os, sys
c = json.load(open(sys.argv[1]))[sys.argv[2]]
print(os.path.expanduser(c["repo"]), c["fix"], c["branch"], c["cut"].replace(" ", "T"))
PY
)
CUT="${CUT/T/ }"

RUN="$SB/runs/$T-$VER"; [ -f "$RUN/stream.jsonl" ] && { echo "REFUSED: $RUN already has results"; exit 1; }
rm -rf "$RUN"; mkdir -p "$RUN"; H="$RUN/home"; NAME="$(basename "$R")"; P="$RUN/$NAME"
BASE="$(git -C "$R" rev-parse "$FIX^")"
# project remote = local bare repo holding ONLY history up to the fix's parent (the fix is unreachable)
git init -q --bare "$RUN/remote.git"
git -C "$R" push -q "$RUN/remote.git" "$BASE:refs/heads/$BR"
git -C "$RUN/remote.git" symbolic-ref HEAD "refs/heads/$BR"
git clone -q "$RUN/remote.git" "$P"
cp "$R/local.properties" "$P/" 2>/dev/null || true
[ -f "$R/gradle/gradle-daemon-jvm.properties" ] && cp "$R/gradle/gradle-daemon-jvm.properties" "$P/gradle/"
mkdir -p "$P/.jira-bug"
python3 - "$R/.jira-bug/setup.json" "$P/.jira-bug/setup.json" "${T%%-*}" "$BR" <<'PY'
import json, sys
src, dst, board, br = sys.argv[1:]
try: d = json.load(open(src))
except Exception: d = {}
keep = {k: d[k] for k in ("project", "type", "board", "mode", "statusSet", "assigneeScope", "sprintScope", "sotByPhase") if k in d}
keep.update({"board": board, "project": board, "type": "jira", "baseBranch": br})
json.dump(keep, open(dst, "w"), indent=2)
PY
# shared memory as it was the moment the ticket was first picked up
MEMBASE="$(git -C ~/.claude/jira-bug-memory log -1 --format=%H --before="$CUT +0700" master)"
git init -q --bare "$RUN/memory.git"; git -C ~/.claude/jira-bug-memory push -q "$RUN/memory.git" "$MEMBASE:refs/heads/master"
git -C "$RUN/memory.git" symbolic-ref HEAD refs/heads/master
mkdir -p "$H/.claude/skills" "$H/Library"; ln -s ~/Library/Keychains "$H/Library/Keychains"
git clone -q "$RUN/memory.git" "$H/.claude/jira-bug-memory"
cp -R "$SKILL" "$H/.claude/skills/jira-bug-analyzer"
cat > "$H/.gitconfig" <<G
[user]
	name = Sandbox Dev
	email = dev@sandbox
[url "$RUN/remote.git"]
	insteadOf = https://github.com/AperoVN/$NAME.git
	insteadOf = https://github.com/AperoVN/$NAME
	insteadOf = git@github.com:AperoVN/$NAME.git
[url "$RUN/memory.git"]
	insteadOf = https://github.com/hung-apero/jira-bug-memory.git
	insteadOf = https://github.com/hung-apero/jira-bug-memory
	insteadOf = git@github.com:hung-apero/jira-bug-memory.git
[credential]
	helper =
G
git -C "$P" remote set-url origin "https://github.com/AperoVN/$NAME.git"
git -C "$H/.claude/jira-bug-memory" remote set-url origin https://github.com/hung-apero/jira-bug-memory.git
AB_CONNECTORS="$CONNECTORS" AB_DIR="$SB" python3 - "$H" "$P" "$HOME" <<'PY'
import json, os, sys
H, P, REAL = sys.argv[1:]
d = json.load(open(os.path.join(REAL, ".claude.json")))
keep = {k: d[k] for k in d if k in ("oauthAccount", "userID", "hasCompletedOnboarding", "lastOnboardingVersion", "firstStartTime", "installMethod")}
real = d["mcpServers"]["jira"]
keep["mcpServers"] = {"jira": {"type": "stdio", "command": real["command"], "args": real.get("args", []),
    "env": {"JIRA_URL": "http://127.0.0.1:PORT", "JIRA_PERSONAL_TOKEN": "sandbox-token", "TOOLSETS": "all"}}}
keep["projects"] = {P: {"hasTrustDialogAccepted": True, "allowedTools": []}}
json.dump(keep, open(os.path.join(H, ".claude.json"), "w"), indent=1)
# The run must not see the real shared memory / real transcripts: one A/B run read the real KB by absolute
# path and found the very ticket under test. Deny them; ab_report.py also flags any access as LEAK.
deny = [f"{t}({REAL}/.claude/{d}/**)" for t in ("Read", "Edit", "Write") for d in ("projects", "skills")]
deny += [f"{t}({REAL}/**/jira-bug-memory/**)" for t in ("Read", "Edit", "Write")]   # every real clone, not just ~/.claude's
deny += [f"Bash(*{REAL}/*jira-bug-memory*)", f"Bash(*{REAL}/.claude/projects*)"]
settings = {"permissions": {"defaultMode": "bypassPermissions", "deny": deny}, "skipDangerousModePermissionPrompt": True}
if os.environ.get("AB_CONNECTORS") == "confluence-read":
    # real use reads specs through the claude.ai "Confluence MCP" connector, which also carries Jira tools on the
    # REAL Jira: a PreToolUse hook (runs even under bypass) allows only the three Confluence read tools
    guard = os.path.join(os.environ["AB_DIR"], "connector-guard.py")
    settings["hooks"] = {"PreToolUse": [{"matcher": "mcp__claude_ai_.*", "hooks": [{"type": "command", "command": f"python3 {guard}"}]}]}
json.dump(settings, open(os.path.join(H, ".claude/settings.json"), "w"), indent=1)
PY
printf '%s\n' "$T" > "$RUN/ticket"; printf '%s\n' "$VER" > "$RUN/version"; printf '%s\n' "$BR" > "$RUN/branch"; printf '%s\n' "$P" > "$RUN/project"
printf '%s\n' "$HOME" > "$RUN/real_home"
[ -n "$CONNECTORS" ] && printf '%s\n' "$CONNECTORS" > "$RUN/connectors"
if [ -n "$DESC" ]; then   # run.sh serves $RUN/tickets instead of tickets/ when it exists
  mkdir -p "$RUN/tickets/$T"; ln -s "$SB/tickets/$T/attachments" "$RUN/tickets/$T/attachments" 2>/dev/null || true
  python3 - "$SB/tickets/$T/issue.json" "$DESC" "$RUN/tickets/$T/issue.json" <<'PY'
import json, sys
src, desc, dst = sys.argv[1:]
d = json.load(open(src)); f = d.get("fields", d); f["description"] = open(desc, encoding="utf-8").read().strip()
json.dump(d, open(dst, "w"), ensure_ascii=False, indent=1)
PY
  cp "$DESC" "$RUN/desc.txt"
fi
[ -n "$MAPFROM" ] && printf '%s\n' "$MAPFROM" > "$RUN/map_from"
echo "RUN=$RUN BASE=${BASE:0:8} MEMBASE=${MEMBASE:0:8}"
