#!/usr/bin/env bash
# NOTE: never edit this file while a queue is running it — bash reads scripts as it goes; an edit made
# mid-run re-ran the claude launch line once (AAP857-113 final) and broke the tail of another run.
# run.sh <RUN-dir> [prompt]  -> runs one headless session inside the sandbox; transcript in <RUN>/stream.jsonl
# The sandbox: HOME=<RUN>/home (own skill copy, own memory clone, own .gitconfig redirecting GitHub URLs
# to local bare repos), Jira = mock_jira.py on localhost, gh = bin/gh shim, no claude.ai connectors.
set -uo pipefail   # lint: no-strict-mode: a failed claude run must still stop the Jira stand-in and write timing.json
# run.sh --queue <RUN-dir>...  -> runs them one after another (one phone), skipping any that already ran
if [ "${1:-}" = "--queue" ]; then
  shift; for r in "$@"; do [ -f "$r/stream.jsonl" ] && { echo "skip $r"; continue; }; echo "== $(basename "$r") $(date +%T)"; bash "$0" "$r"; done; exit 0
fi
RUN="$(cd "$1" && pwd)"; SB="$(cd "$(dirname "$0")" && pwd)"; H="$RUN/home"; P="$(cat "$RUN/project")"; T="$(cat "$RUN/ticket")"
DEF="/jira-bug-analyzer $T --auto"; [ -f "$RUN/prompt" ] && DEF="$(cat "$RUN/prompt")"; PROMPT="${2:-$DEF}"
rm -f "$RUN/port"
TK="$SB/tickets"; [ -d "$RUN/tickets" ] && TK="$RUN/tickets"   # setup_run.sh --desc: this run's own ticket text
python3 "$SB/mock_jira.py" "$TK" "$RUN/port" "$RUN/jira.jsonl" & MOCK=$!
for _ in $(seq 1 30); do [ -s "$RUN/port" ] && break; sleep 0.2; done; PORT="$(cat "$RUN/port")"
python3 - "$H/.claude.json" "$PORT" "$RUN/mcp.json" <<'PY'
import json, sys
p, port, mcp = sys.argv[1:]
d = json.load(open(p)); j = d["mcpServers"]["jira"]; j["env"]["JIRA_URL"] = f"http://127.0.0.1:{port}"
json.dump(d, open(p, "w"), indent=1); json.dump({"mcpServers": {"jira": j}}, open(mcp, "w"), indent=1)
PY
# a project's local setup.json survives between tickets in real use: seed the navRecipe an earlier run saved
REC="$SB/runs/_recipes/${T%%-*}.json"
[ -f "$REC" ] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["navRecipe"]=json.load(open(sys.argv[2])); json.dump(d,open(sys.argv[1],"w"),indent=2)' "$P/.jira-bug/setup.json" "$REC"
# in real use the app's local map (<repo>/.jira-bug/app-map.json, First Open steps included) and the local APK
# cache persist between tickets: carry what earlier runs of the same project learned into this run
KEEP="$SB/runs/_kept"; PROJ="${T%%-*}"; MEMC="$H/.claude/jira-bug-memory"
MAPFROM="$(cat "$RUN/map_from" 2>/dev/null || true)"   # setup_run.sh --map-from: a fixed starting map, nothing saved back
if [ -n "$MAPFROM" ]; then cp "$MAPFROM" "$P/.jira-bug/app-map.json"
else [ -f "$KEEP/app-map/$PROJ.json" ] && cp "$KEEP/app-map/$PROJ.json" "$P/.jira-bug/app-map.json"; fi   # the app's local map persists in real use
cd "$P"
START=$(date +%s)
CONN_ENV="ENABLE_CLAUDEAI_MCP_SERVERS=false"; CONN_ARGS=(--strict-mcp-config)
if [ "$(cat "$RUN/connectors" 2>/dev/null)" = confluence-read ]; then   # setup_run.sh --connectors confluence-read
  CONN_ENV="ENABLE_CLAUDEAI_MCP_SERVERS=true"   # + the guard hook in the sandbox settings allows only Confluence reads
  CONN_ARGS=(--disallowedTools "$(python3 "$SB/connector-deny.py" | paste -sd, -)")
fi
env HOME="$H" PATH="$SB/bin:$PATH" GRADLE_USER_HOME="$HOME/.gradle" "$CONN_ENV" API_TIMEOUT_MS=180000 CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 \
  JBA_APK_CACHE="$SB/runs/_kept/apk" AB_GH_LOG="$RUN/gh.log" AB_GH_STATE="$RUN/gh-state" AB_REPO="AperoVN/$(basename "$P")" AB_BASE="$(cat "$RUN/branch")" \
  JIRA_URL="http://127.0.0.1:$PORT" JIRA_PERSONAL_TOKEN=sandbox-token \
  caffeinate -dimsu claude -p "$PROMPT" "${CONN_ARGS[@]}" --mcp-config "$RUN/mcp.json" --dangerously-skip-permissions \
  --output-format stream-json --verbose > "$RUN/stream.jsonl" 2> "$RUN/stderr.log"
RC=$?; END=$(date +%s)
kill "$MOCK" 2>/dev/null; wait "$MOCK" 2>/dev/null
printf '{"rc": %s, "seconds": %s}\n' "$RC" "$((END-START))" > "$RUN/timing.json"
mkdir -p "$KEEP/app-map"   # ...and keep what this run learned for the next ticket
[ -z "$MAPFROM" ] && [ -f "$P/.jira-bug/app-map.json" ] && cp "$P/.jira-bug/app-map.json" "$KEEP/app-map/$PROJ.json"
mkdir -p "$SB/runs/_recipes"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])).get("navRecipe"); r and json.dump(r,open(sys.argv[2],"w"),ensure_ascii=False)' "$P/.jira-bug/setup.json" "$REC" 2>/dev/null || true
echo "RC=$RC SECONDS=$((END-START))"
