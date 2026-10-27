#!/usr/bin/env bash
# pr-watch.sh — the ONE writer of <project>/.jira-bug/pr-watch.json, the list of open PRs that
# --manager reconciles (review comments, merge/close cleanup, KB backfill).
#
# A PR missing from this file is invisible to --manager. On AAP857-113 the step was prose in
# Phase 6 Step 3 and got dropped, so ledger.sh now calls `add` itself on every status=pr-created.
#
# Usage:
#   pr-watch.sh add  <project-root> <pr-url> <TICKET> [summary]   # idempotent; a batch PR gains tickets
#   pr-watch.sh drop <project-root> <pr-number>
#   pr-watch.sh list <project-root>
# <project-root> may be the main checkout or any of its worktrees: the file always lands in the
# MAIN checkout (where --manager looks), never in a worktree that gets deleted after merge.
# Output: PR_WATCH=added|updated|unchanged|dropped #<n> FILE=<path>   |   PR_WATCH_ERROR=<why> (exit 1)
set -euo pipefail

CMD="${1:-}"; ROOT="${2:-}"
[ -n "$CMD" ] && [ -d "$ROOT" ] || { echo "usage: pr-watch.sh {add <root> <pr-url> <TICKET> [summary] | drop <root> <pr> | list <root>}"; exit 2; }

# Main checkout = parent of the common git dir (a worktree's .git points back to it).
COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
  || { echo "PR_WATCH_ERROR=$ROOT is not a git checkout"; exit 1; }
MAIN="$(dirname "$COMMON")"
FILE="$MAIN/.jira-bug/pr-watch.json"
mkdir -p "$MAIN/.jira-bug"
# Untracked by design: never committed with a fix.
EXCL="$COMMON/info/exclude"; mkdir -p "$(dirname "$EXCL")"
grep -qxF '.jira-bug/' "$EXCL" 2>/dev/null || echo '.jira-bug/' >> "$EXCL"

case "$CMD" in
  list) [ -f "$FILE" ] && cat "$FILE" || echo "{}"; exit 0 ;;
  drop) N="${3:?drop needs <pr-number>}"; URL=""; TICKET=""; SUMMARY="" ;;
  add)
    URL="${3:?add needs <pr-url>}"; TICKET="${4:?add needs <TICKET>}"; SUMMARY="${5:-}"
    N="$(printf '%s' "$URL" | sed -nE 's#.*/pull/([0-9]+).*#\1#p')"
    [ -n "$N" ] || { echo "PR_WATCH_ERROR=cannot read a PR number from '$URL'"; exit 1; }
    # base/branch from GitHub when gh can see it; the entry is still useful without them.
    META="$(gh pr view "$URL" --json baseRefName,headRefName -q '.baseRefName + " " + .headRefName' 2>/dev/null || true)"
    BASE="${META%% *}"; BRANCH="${META#* }"; [ -n "$META" ] || { BASE=""; BRANCH=""; }
    WT=""
    [ -n "$BRANCH" ] && WT="$(git -C "$MAIN" worktree list --porcelain \
      | awk -v b="refs/heads/$BRANCH" '/^worktree /{w=substr($0,10)} $0=="branch "b{print w; exit}')"
    ;;
  *) echo "usage: pr-watch.sh {add|drop|list} …"; exit 2 ;;
esac

python3 - "$FILE" "$CMD" "$N" "$URL" "$TICKET" "$SUMMARY" "${BASE:-}" "${BRANCH:-}" "${WT:-}" <<'PY'
import datetime, json, os, re, sys
path, cmd, n, url, ticket, summary, base, branch, wt = sys.argv[1:]
data = {}
if os.path.exists(path):
    text = open(path, encoding="utf-8").read()
    try:
        data = json.loads(re.sub(r",\s*([}\]])", r"\1", text)) if text.strip() else {}
    except ValueError:
        print(f"PR_WATCH_ERROR=unreadable {path}; fix it by hand (never overwritten)"); sys.exit(1)
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()
if cmd == "drop":
    state = "dropped" if data.pop(n, None) is not None else "unchanged"
else:
    e = data.get(n)
    state = "updated" if e else "added"
    e = e or {"pr": int(n), "url": url, "tickets": [], "createdAt": now, "commentsCursor": now}
    for k, v in (("base", base), ("branch", branch), ("worktree", wt)):
        if v: e[k] = v
    if not any(t.get("key") == ticket for t in e["tickets"]):
        e["tickets"].append({"key": ticket, "summary": summary})
    elif state == "updated":
        state = "unchanged"
    data[n] = e
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2); f.write("\n")
os.replace(tmp, path)
json.load(open(path, encoding="utf-8"))  # read back: a file we cannot parse is not "armed"
print(f"PR_WATCH={state} #{n} FILE={path}")
PY
