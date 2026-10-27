#!/usr/bin/env bash
# ledger.sh — the ONE writer of the shared bug-status ledger
#   <memory clone>/project/<PROJ>/<PHASE>/session/record_bug_status.md
#
# Every status change of a ticket goes through this script (Phase 3 analyzed, Phase 6 pr-created,
# manager Job D done/reopened, Job E resume). A command, not prose: it pulls, upserts ONE ticket,
# commits, pushes (rebase-retry on a concurrent push) and prints the commit — the run quotes that
# line as proof the write happened.
#
# The ledgers in the shared repo come in two shapes; this script keeps whichever the file already has:
#   table    — "| ticket | status | ... |" (column order varies per project; missing columns are appended)
#   sections — "## <TICKET>" followed by "- key: value" lines
# A new file is created as a table with the canonical columns (references/helpers/memory.md).
#
# Usage:
#   ledger.sh upsert <PROJ> <PHASE> <TICKET> key=value [key=value ...] [--no-push] [--root <project>]
#   ledger.sh get    <PROJ> <PHASE> <TICKET>
#   ledger.sh delete <PROJ> <PHASE> <TICKET> [--no-push]
# Keys: status root_cause_slug dev summary files pr auto_eval reopen_reason reopen_note (any other key
# is accepted and added). `updated` is set to today automatically.
# Output: LEDGER_COMMIT=<sha> FILE=<path>   |   LEDGER_ROW=...   |   LEDGER_ERROR=<why> (exit 1)
# status=pr-created with pr=<url> also registers the PR in <project>/.jira-bug/pr-watch.json
# (assets/pr-watch.sh; <project> = --root, default the current directory) and prints PR_WATCH=… —
# one command, so the --manager hand-off cannot be dropped the way the prose Step 3 was (AAP857-113).
# LEDGER_WARN=… flags a pr-created with no earlier analyzing/analyzed row (Phase 3 checklist skipped).
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD="${1:-}"; PROJ="${2:-}"; PHASE="${3:-}"; TICKET="${4:-}"
[ -n "$CMD" ] && [ -n "$PROJ" ] && [ -n "$PHASE" ] && [ -n "$TICKET" ] || {
  echo "usage: ledger.sh {upsert|get|delete} <PROJ> <PHASE> <TICKET> [key=value ...] [--no-push]"; exit 2; }
shift 4
PUSH=1; KV=(); ROOT="$PWD"; NEXT_ROOT=0
for a in "$@"; do
  if [ "$NEXT_ROOT" -eq 1 ]; then ROOT="$a"; NEXT_ROOT=0; continue; fi
  case "$a" in
    --no-push) PUSH=0 ;;
    --root) NEXT_ROOT=1 ;;
    *=*) KV+=("$a") ;;
    *) echo "LEDGER_ERROR=bad argument '$a' (expected key=value)"; exit 1 ;;
  esac
done

CLONE="$(bash "$SELF_DIR/memory-sync.sh" path)"
[ -d "$CLONE/.git" ] || { echo "LEDGER_ERROR=no memory clone at $CLONE (run memory-sync.sh autowire)"; exit 1; }
REL="project/$PROJ/$PHASE/session/record_bug_status.md"
FILE="$CLONE/$REL"

pull() { git -C "$CLONE" pull -q --rebase >/dev/null 2>&1 || true; }

edit() { # rewrite FILE for CMD; prints CHANGED=0|1 (and LEDGER_ROW for get)
  python3 - "$FILE" "$CMD" "$TICKET" "$PROJ" "$PHASE" "${KV[@]+"${KV[@]}"}" <<'PY'
import datetime, os, re, sys
path, cmd, ticket, proj, phase, *kv = sys.argv[1:]
today = datetime.date.today().isoformat()
fields = {}
for item in kv:
    k, v = item.split("=", 1)
    fields[k.strip()] = " ".join(v.split())          # one line per value
if cmd == "upsert":
    fields["updated"] = today
CANON = ["ticket", "status", "root_cause_slug", "dev", "summary", "files", "pr", "auto_eval", "updated"]

text = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
lines = text.split("\n") if text else []

def cells(row):
    parts = re.split(r"(?<!\\)\|", row.strip())
    return [c.strip() for c in parts[1:-1]]

def esc(v):
    return v.replace("|", "\\|")

table_hdr = next((i for i, l in enumerate(lines) if l.startswith("|") and "ticket" in [c.lower() for c in cells(l)]), None)
has_sections = any(re.match(r"^##\s+[A-Z][A-Z0-9_]*-\d+\s*$", l) for l in lines)
mode = "table" if table_hdr is not None else ("sections" if has_sections else "new")
if mode == "new" and text.strip():
    # Never overwrite a file we cannot read: it may hold another dev's history.
    print("LEDGER_ERROR=unrecognised ledger format in " + path + " (no '| ticket |' table, no '## KEY-N' sections); fix it by hand")
    sys.exit(3)

if mode == "new":
    if cmd != "upsert":
        print("CHANGED=0"); sys.exit()
    lines = ["---", f"project: {proj}", f"phase: {phase}", f"updated: {today}", "---",
             f"# {proj} {phase} — bug status ledger (cross-dev + cross-ticket dedup)",
             "| " + " | ".join(CANON) + " |", "|" + "---|" * len(CANON)]
    table_hdr, mode = 6, "table"

if mode == "table":
    hdr = cells(lines[table_hdr])
    low = [h.lower() for h in hdr]
    tcol = low.index("ticket")
    rows = [i for i in range(table_hdr + 2, len(lines)) if lines[i].startswith("|")]
    hit = next((i for i in rows if (cells(lines[i]) + [""])[tcol] == ticket), None)
    if cmd == "get":
        print("LEDGER_ROW=" + (lines[hit] if hit is not None else "")); print("CHANGED=0"); sys.exit()
    if cmd == "delete":
        if hit is None: print("CHANGED=0"); sys.exit()
        del lines[hit]
    else:
        new = [k for k in fields if k.lower() not in low]
        if new:  # add columns: extend header, separator and every row's end
            lines[table_hdr] = lines[table_hdr].rstrip() + "".join(f" {k} |" for k in new)
            lines[table_hdr + 1] = lines[table_hdr + 1].rstrip() + "---|" * len(new)
            for i in rows:
                lines[i] = lines[i].rstrip() + " |" * len(new)
            hdr += new; low += [k.lower() for k in new]
        cur = (cells(lines[hit]) if hit is not None else [""] * len(hdr))
        cur += [""] * (len(hdr) - len(cur))
        if "status" in low: print("PRIOR=" + cur[low.index("status")])
        cur[tcol] = ticket
        for k, v in fields.items():
            cur[low.index(k.lower())] = esc(v)
        row = "| " + " | ".join(cur[:len(hdr)]) + " |"
        if hit is not None: lines[hit] = row
        else:
            end = (rows[-1] + 1) if rows else table_hdr + 2
            lines.insert(end, row)
else:  # sections
    start = next((i for i, l in enumerate(lines) if re.match(r"^##\s+" + re.escape(ticket) + r"\s*$", l)), None)
    end = None
    if start is not None:
        end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
    if cmd == "get":
        print("LEDGER_ROW=" + (" ; ".join(l for l in lines[start:end] if l.strip()) if start is not None else "")); print("CHANGED=0"); sys.exit()
    if cmd == "delete":
        if start is None: print("CHANGED=0"); sys.exit()
        del lines[start:end]
    else:
        if start is None:
            while lines and not lines[-1].strip(): lines.pop()
            lines += ["", f"## {ticket}"]
            start, end = len(lines) - 1, len(lines)
        body = lines[start + 1:end]
        print("PRIOR=" + next((l.split(":", 1)[1].strip() for l in body if re.match(r"^-\s*status\s*:", l)), ""))
        for k, v in fields.items():
            idx = next((j for j, l in enumerate(body) if re.match(r"^-\s*" + re.escape(k) + r"\s*:", l)), None)
            if idx is None:
                last = max([j for j, l in enumerate(body) if l.startswith("- ")], default=-1)
                body.insert(last + 1, f"- {k}: {v}")
            else:
                body[idx] = f"- {k}: {v}"
        lines[start + 1:end] = body

out = "\n".join(lines).rstrip("\n") + "\n"
changed = out != text
if changed:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w", encoding="utf-8").write(out)
print("CHANGED=" + ("1" if changed else "0"))
PY
}

kv() { printf '%s\n' "${KV[@]+"${KV[@]}"}" | sed -n "s/^$1=//p" | head -1; }
STATUS="$(kv status)"; PR_URL="$(kv pr)"

watch() { # status=pr-created + pr=<url> -> the PR goes on --manager's list; failure is loud (exit 1)
  [ "$CMD" = "upsert" ] && [ "$STATUS" = "pr-created" ] && [ -n "$PR_URL" ] || return 0
  bash "$SELF_DIR/pr-watch.sh" add "$ROOT" "$PR_URL" "$TICKET" "$(kv summary)" || WATCH_FAILED=1
}
WATCH_FAILED=0

[ "$PUSH" -eq 1 ] && pull
OUT="$(edit)" || { printf '%s\n' "$OUT"; exit 1; }
if [ "$CMD" = "get" ]; then printf '%s\n' "$OUT" | grep '^LEDGER_ROW='; exit 0; fi
PRIOR="$(printf '%s\n' "$OUT" | sed -n 's/^PRIOR=//p' | head -1)"
if [ "$STATUS" = "pr-created" ]; then
  case "$PRIOR" in analyzing|analyzed|pr-created|reopened*|fixing) ;;
    *) echo "LEDGER_WARN=$TICKET had no analyzing/analyzed row before pr-created (prior='${PRIOR}') — Phase 3 checklist (claim + ledger) was skipped" ;;
  esac
fi
if ! printf '%s\n' "$OUT" | grep -q '^CHANGED=1'; then
  echo "LEDGER_COMMIT=$(git -C "$CLONE" rev-parse --short HEAD) FILE=$REL (no change)"; watch; exit "$WATCH_FAILED"
fi

git -C "$CLONE" add "$REL"
git -C "$CLONE" commit -q -m "chore($PROJ): ledger $TICKET ${STATUS:-$CMD}"
if [ "$PUSH" -eq 1 ]; then
  for attempt in 1 2 3; do
    if git -C "$CLONE" push -q 2>/dev/null; then break; fi
    [ "$attempt" -eq 3 ] && { echo "LEDGER_ERROR=push failed after 3 attempts (commit kept locally: $(git -C "$CLONE" rev-parse --short HEAD))"; exit 1; }
    git -C "$CLONE" pull -q --rebase >/dev/null 2>&1 || { echo "LEDGER_ERROR=rebase conflict on $REL — resolve in $CLONE"; exit 1; }
  done
fi
echo "LEDGER_COMMIT=$(git -C "$CLONE" rev-parse --short HEAD) FILE=$REL"
watch; exit "$WATCH_FAILED"
