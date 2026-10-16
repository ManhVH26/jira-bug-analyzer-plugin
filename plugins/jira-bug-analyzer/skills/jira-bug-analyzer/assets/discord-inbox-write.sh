#!/usr/bin/env bash
# discord-inbox-write.sh — bot-side helper (v1.11)
#
# claudecode-discord bot calls this on every Discord reply matching
# /^[A-Z][A-Z0-9]+-\d+\s+/. The script writes a JSON file into the
# inbox folder; the --manager terminal (Job G) picks it up via Monitor.
#
# No Claude session is spawned here. No tool-use is triggered.
#
# Exit codes:
#   0  — file written
#   10 — duplicate (file already exists)
#   20 — missing required arg
#   30 — inbox dir not writable
#
# Compatible with bash 3.2+ (macOS default).

set -euo pipefail

TICKET=""
MESSAGE_ID=""
CHANNEL_ID=""
GUILD_ID=""
AUTHOR_ID=""
AUTHOR_NAME=""
CONTENT=""
CONTENT_STRIPPED=""
ATTACHMENTS="[]"
INBOX_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --ticket)            TICKET="$2";            shift 2 ;;
    --message-id)        MESSAGE_ID="$2";        shift 2 ;;
    --channel-id)        CHANNEL_ID="$2";        shift 2 ;;
    --guild-id)          GUILD_ID="$2";          shift 2 ;;
    --author-id)         AUTHOR_ID="$2";         shift 2 ;;
    --author-name)       AUTHOR_NAME="$2";       shift 2 ;;
    --content)           CONTENT="$2";           shift 2 ;;
    --content-stripped)  CONTENT_STRIPPED="$2";  shift 2 ;;
    --attachments)       ATTACHMENTS="$2";       shift 2 ;;
    --inbox-dir)         INBOX_DIR="$2";         shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 20 ;;
  esac
done

missing=""
[ -z "$TICKET" ]     && missing="$missing --ticket"
[ -z "$MESSAGE_ID" ] && missing="$missing --message-id"
[ -z "$CHANNEL_ID" ] && missing="$missing --channel-id"
[ -z "$AUTHOR_ID" ]  && missing="$missing --author-id"
[ -z "$CONTENT" ]    && missing="$missing --content"
[ -z "$INBOX_DIR" ]  && missing="$missing --inbox-dir"
if [ -n "$missing" ]; then
  echo "missing required args:$missing" >&2
  exit 20
fi

mkdir -p "$INBOX_DIR" "$INBOX_DIR/processed" || { echo "cannot mkdir $INBOX_DIR" >&2; exit 30; }

OUT="$INBOX_DIR/${TICKET}-${MESSAGE_ID}.json"

if [ -e "$OUT" ]; then
  echo "duplicate: $OUT" >&2
  exit 10
fi

RECEIVED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

export TICKET MESSAGE_ID CHANNEL_ID GUILD_ID AUTHOR_ID AUTHOR_NAME \
       CONTENT CONTENT_STRIPPED ATTACHMENTS RECEIVED_AT OUT

python3 - <<'PY'
import json, os, sys
payload = {
    "ticket":            os.environ["TICKET"],
    "message_id":        os.environ["MESSAGE_ID"],
    "channel_id":        os.environ["CHANNEL_ID"],
    "guild_id":          os.environ.get("GUILD_ID", ""),
    "author_id":         os.environ["AUTHOR_ID"],
    "author_name":       os.environ.get("AUTHOR_NAME", ""),
    "content":           os.environ["CONTENT"],
    "content_stripped":  os.environ.get("CONTENT_STRIPPED", ""),
    "attachments":       json.loads(os.environ.get("ATTACHMENTS", "[]")),
    "received_at":       os.environ["RECEIVED_AT"],
    "status":            "pending",
    "schema_version":    "v1.11",
}
with open(os.environ["OUT"], "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False, indent=2)
PY

echo "$OUT"
