#!/usr/bin/env bash
# discord-inbox-watcher.sh — persistent daemon (v1.11.2)
#
# Watches .jira-bug/discord-inbox/*.json, spawns `claude -p` session per new file.
# Started by --manager self-arm via `nohup ... & disown`, survives session close.
# Daemon = independent process; does NOT depend on Monitor tool / Claude session idle.
#
# Usage:
#   ./discord-inbox-watcher.sh <project-dir>
#   # In --manager self-arm: nohup bash discord-inbox-watcher.sh "$PWD" > log 2>&1 & disown
#
# Idempotency: PID file .jira-bug/discord-inbox-watch.json; next --manager entry
# checks + skips if alive, respawns if dead.
#
# Exit when SIGTERM/SIGINT. User kills via: kill $(jq -r .pid .jira-bug/discord-inbox-watch.json)

set -euo pipefail

PROJECT_DIR="${1:-$(pwd)}"
INBOX="$PROJECT_DIR/.jira-bug/discord-inbox"
PROCESSED="$INBOX/processed"
LOG_DIR="$PROJECT_DIR/.jira-bug/resume-logs"
WATCHER_LOG="$PROJECT_DIR/.jira-bug/discord-inbox-watcher.log"

mkdir -p "$INBOX" "$PROCESSED" "$LOG_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$WATCHER_LOG"
}

process_file() {
  local f="$1"
  [ -f "$f" ] || return 0

  local name
  name=$(basename "$f")

  # Skip non-json or marker files
  case "$name" in
    *.json) ;;
    *) return 0 ;;
  esac

  # Extract ticket from filename: <TICKET>-<msgid>.json
  local ticket
  ticket=$(echo "$name" | sed -E 's/^([A-Z][A-Z0-9]+-[0-9]+)-.*\.json$/\1/')
  if [ -z "$ticket" ] || [ "$ticket" = "$name" ]; then
    log "skip (no ticket in name): $name"
    return 0
  fi

  # Dedup: ticket already being resumed?
  local active="$PROJECT_DIR/.jira-bug/active-resumes.json"
  if [ -f "$active" ] && python3 -c "
import json, os, sys
try:
    d = json.load(open('$active'))
    if '$ticket' in d:
        pid = d['$ticket'].get('pid')
        if pid and os.path.exists(f'/proc/{pid}'):
            sys.exit(0)
        try:
            os.kill(pid, 0)
            sys.exit(0)
        except: pass
except: pass
sys.exit(1)
"; then
    log "skip (dedup, already resuming): $ticket"
    mv "$f" "$PROCESSED/" 2>/dev/null || true
    return 0
  fi

  # Spawn claude -p session detached
  local ts
  ts=$(date +%Y%m%d-%H%M%S)
  local spawn_log="$LOG_DIR/${ticket}-${ts}.log"

  cd "$PROJECT_DIR"
  nohup claude -p "/jira-bug-analyzer ${ticket} --resume-from-defer --auto" \
    > "$spawn_log" 2>&1 &
  local pid=$!
  disown "$pid" 2>/dev/null || true

  log "spawned $ticket pid=$pid log=$spawn_log"

  # Record in active-resumes.json (atomic via tmp + mv)
  python3 - "$active" "$ticket" "$pid" "$spawn_log" <<'PY'
import json, os, sys, time
path, ticket, pid, log = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
d = {}
if os.path.exists(path):
    try: d = json.load(open(path))
    except: d = {}
d[ticket] = {"pid": pid, "spawned_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "log": log}
tmp = path + ".tmp"
with open(tmp, "w") as f: json.dump(d, f, indent=2)
os.rename(tmp, path)
PY

  # Move file to processed/
  mv "$f" "$PROCESSED/" 2>/dev/null || log "mv fail: $f"
}

# Startup banner
log "===== watcher started pid=$$ project=$PROJECT_DIR ====="

# Trap signals for clean exit
trap 'log "===== watcher stopped pid=$$ ====="; exit 0' TERM INT

# Catchup: process any files already in inbox at startup
for f in "$INBOX"/*.json; do
  [ -f "$f" ] || continue
  process_file "$f"
done

# Choose watcher backend
if command -v fswatch >/dev/null 2>&1; then
  log "backend: fswatch"
  # fswatch streams: 1 line per changed path, null-separated with -0
  fswatch -0 --event Created --event Updated --event Renamed "$INBOX" | \
    while IFS= read -r -d '' path; do
      # Skip paths under processed/
      case "$path" in
        */processed/*) continue ;;
        */processed) continue ;;
      esac
      process_file "$path"
    done
else
  log "backend: poll (fswatch not found)"
  # Poll loop fallback: scan every 2s
  while true; do
    sleep 2
    for f in "$INBOX"/*.json; do
      [ -f "$f" ] || continue
      process_file "$f"
    done
  done
fi
