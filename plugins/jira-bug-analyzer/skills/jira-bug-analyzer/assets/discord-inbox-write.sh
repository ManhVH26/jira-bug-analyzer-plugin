#!/usr/bin/env bash
# discord-inbox-write.sh — bot-side helper (v1.14)
#
# claudecode-discord bot calls this on every Discord event in #jira-bug-analyzer
# that matches one of:
#   1. @claude mention anywhere in the content
#   2. reply-quote where parent message was authored by the bot (CLAUDE_BOT_USER_ID)
#
# The script writes a JSON file (schema v1.14) into the inbox folder; the
# --manager terminal (Job G) picks it up via Monitor, runs the LLM classifier,
# and routes to the right intent branch — see references/helpers/discord-classifier.md.
#
# No Claude session is spawned here. No tool-use is triggered.
#
# v1.14 changes from v1.11:
#   - --ticket is now OPTIONAL (classifier handles non-ticket intents too)
#   - new flags: --trigger-type, --referenced-ticket, --referenced-message-id, --thread-id
#   - filename falls back to "<trigger_type>-<message_id>.json" when --ticket is absent
#   - payload schema bumped to v1.14 with new fields populated
#
# v1.11 bot-side callers still work: passing --ticket + v1.11 flags produces
# a file with schema_version "v1.14" and trigger_type defaulted to "mention".
#
# Exit codes:
#   0  — file written
#   10 — duplicate (file already exists)
#   20 — missing required arg
#   30 — inbox dir not writable
#
# Example (v1.14 mention trigger, no ticket):
#   discord-inbox-write.sh \
#     --trigger-type mention \
#     --message-id 1561566668256186482 \
#     --channel-id 1560595714386567169 \
#     --author-id 123456789 \
#     --author-name LinhMyx \
#     --content "@claude PR nào đang review?" \
#     --content-stripped "PR nào đang review?" \
#     --thread-id "" \
#     --inbox-dir .jira-bug/discord-inbox
#
# Example (v1.14 reply-quote with ticket inherited from parent):
#   discord-inbox-write.sh \
#     --trigger-type reply \
#     --referenced-ticket AAP729-3 \
#     --referenced-message-id 1561566668256186482 \
#     --message-id 1561600000000000000 \
#     --channel-id 1560595714386567169 \
#     --author-id 123456789 \
#     --content "check lại giúp" \
#     --inbox-dir .jira-bug/discord-inbox
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
TRIGGER_TYPE=""
REFERENCED_TICKET=""
REFERENCED_MESSAGE_ID=""
THREAD_ID=""

while [ $# -gt 0 ]; do
  case "$1" in
    --ticket)                 TICKET="$2";                shift 2 ;;
    --message-id)             MESSAGE_ID="$2";            shift 2 ;;
    --channel-id)             CHANNEL_ID="$2";            shift 2 ;;
    --guild-id)               GUILD_ID="$2";              shift 2 ;;
    --author-id)              AUTHOR_ID="$2";             shift 2 ;;
    --author-name)            AUTHOR_NAME="$2";           shift 2 ;;
    --content)                CONTENT="$2";               shift 2 ;;
    --content-stripped)       CONTENT_STRIPPED="$2";      shift 2 ;;
    --attachments)            ATTACHMENTS="$2";           shift 2 ;;
    --inbox-dir)              INBOX_DIR="$2";             shift 2 ;;
    --trigger-type)           TRIGGER_TYPE="$2";          shift 2 ;;
    --referenced-ticket)      REFERENCED_TICKET="$2";     shift 2 ;;
    --referenced-message-id)  REFERENCED_MESSAGE_ID="$2"; shift 2 ;;
    --thread-id)              THREAD_ID="$2";             shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 20 ;;
  esac
done

# v1.14 backward-compat: --ticket present without --trigger-type → derive "mention"
if [ -n "$TICKET" ] && [ -z "$TRIGGER_TYPE" ]; then
  TRIGGER_TYPE="mention"
fi

missing=""
[ -z "$TRIGGER_TYPE" ] && missing="$missing --trigger-type"
[ -z "$MESSAGE_ID" ]   && missing="$missing --message-id"
[ -z "$CHANNEL_ID" ]   && missing="$missing --channel-id"
[ -z "$AUTHOR_ID" ]    && missing="$missing --author-id"
[ -z "$CONTENT" ]      && missing="$missing --content"
[ -z "$INBOX_DIR" ]    && missing="$missing --inbox-dir"
if [ -n "$missing" ]; then
  echo "missing required args:$missing" >&2
  exit 20
fi

mkdir -p "$INBOX_DIR" "$INBOX_DIR/processed" || { echo "cannot mkdir $INBOX_DIR" >&2; exit 30; }

# Filename: prefer ticket-based name for ticket intents (keeps v1.11 lookups working),
# fall back to trigger-type for non-ticket intents.
if [ -n "$TICKET" ]; then
  OUT="$INBOX_DIR/${TICKET}-${MESSAGE_ID}.json"
else
  OUT="$INBOX_DIR/${TRIGGER_TYPE}-${MESSAGE_ID}.json"
fi

if [ -e "$OUT" ]; then
  echo "duplicate: $OUT" >&2
  exit 10
fi

RECEIVED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

export TICKET MESSAGE_ID CHANNEL_ID GUILD_ID AUTHOR_ID AUTHOR_NAME \
       CONTENT CONTENT_STRIPPED ATTACHMENTS RECEIVED_AT OUT \
       TRIGGER_TYPE REFERENCED_TICKET REFERENCED_MESSAGE_ID THREAD_ID

python3 - <<'PY'
import json, os
payload = {
    "schema_version":        "v1.14",
    "trigger_type":          os.environ["TRIGGER_TYPE"],
    "ticket":                os.environ.get("TICKET", ""),
    "referenced_ticket":     os.environ.get("REFERENCED_TICKET", ""),
    "referenced_message_id": os.environ.get("REFERENCED_MESSAGE_ID", ""),
    "thread_id":             os.environ.get("THREAD_ID", ""),
    "message_id":            os.environ["MESSAGE_ID"],
    "channel_id":            os.environ["CHANNEL_ID"],
    "guild_id":              os.environ.get("GUILD_ID", ""),
    "author_id":             os.environ["AUTHOR_ID"],
    "author_name":           os.environ.get("AUTHOR_NAME", ""),
    "content":               os.environ["CONTENT"],
    "content_stripped":      os.environ.get("CONTENT_STRIPPED", ""),
    "attachments":           json.loads(os.environ.get("ATTACHMENTS", "[]")),
    "received_at":           os.environ["RECEIVED_AT"],
    "status":                "pending",
}
with open(os.environ["OUT"], "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False, indent=2)
PY

echo "$OUT"
