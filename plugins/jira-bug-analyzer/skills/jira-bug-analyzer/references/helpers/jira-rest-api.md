# Jira REST & MCP reference

Read this when fetching attachments, posting comments/worklogs, or transitioning status. SKILL.md tells you *when* and *what rule* applies; this file is the *how* (exact calls).

## MCP / REST split — read first

The local `jira` MCP exposes only the toolsets in `.mcp.json` (typically `jira_issues,jira_search,jira_projects,jira_boards,jira_sprints`). It does **NOT** cover:

- Comment add/update/delete
- Worklog add/update
- Status transitions
- Attachment download / inline image fetch

When you send `update.comment` / `update.worklog` via `mcp__jira__jira_update_issue`'s `additional_fields`, the MCP returns `"Issue updated successfully"` but **silently drops them** — the comment/worklog never lands. **Do not trust the success message; always verify** (see "Verify landed" below). For anything in the NOT-covered list, fall back to REST.

## Credential bootstrap

Resolve creds **process env first** (where the MCP server already got them), then the jira server's `env` block in `~/.claude.json` (user-global, uncommitted — the canonical place for the per-dev token), then the project `.mcp.json`. Never assume creds live only in `.mcp.json`, and never read `.claude/.env` for the token (Claude Code does not load it into MCP env).

```bash
read_jira() { # read_jira <KEY>
  python3 - "$1" "$HOME/.claude.json" ".mcp.json" <<'PY'
import json,os,sys
key=sys.argv[1]
v=os.environ.get(key,"")                         # 1) process env
if not v:
    for p in sys.argv[2:]:                        # 2) ~/.claude.json  3) .mcp.json
        try: d=json.load(open(p))
        except Exception: continue
        for n,s in d.get("mcpServers",{}).items():
            if "jira" in n.lower():
                v=(s.get("env",{}) or {}).get(key,"")
                if v: break
        if v: break
print(v)
PY
}
JIRA_TOKEN=$(read_jira JIRA_PERSONAL_TOKEN)
JIRA_URL=$(read_jira JIRA_URL); JIRA_URL=${JIRA_URL%/}
# Use $JIRA_URL/rest/api/2/... with header `Authorization: Bearer $JIRA_TOKEN`
```

**Author identity caveat:** comments/worklogs posted via this token are authored by the **token owner**, not the assignee — note this when handing off to the user.

## Attachments (Fix-4)

```bash
# List attachments
curl -sS -H "Authorization: Bearer $JIRA_TOKEN" \
  "$JIRA_URL/rest/api/2/issue/TICKET_KEY?fields=attachment" | python3 -m json.tool

# Download a specific attachment
curl -sS -L -H "Authorization: Bearer $JIRA_TOKEN" \
  -o /tmp/<filename> \
  "$JIRA_URL/secure/attachment/<id>/<filename>"
```

The MCP `jira_get_issue` response does not always include `attachment` even with `fields="*all"`; re-fetch with `fields="attachment,comment,description,summary"` or use the REST list above. If REST is unavailable, ask the user to paste the relevant images/logs directly.

## Comment (Fix-13 — PR link)

```bash
BODY=$(python3 -c 'import json; print(json.dumps({"body":"PR opened: [PR_URL|PR_URL]\n\nBranch: BRANCH_NAME\n\nFix: ONE_LINE_SUMMARY"}))')
curl -sS -w "HTTP %{http_code}\n" -X POST \
  -H "Authorization: Bearer $JIRA_TOKEN" -H "Content-Type: application/json" \
  --data "$BODY" \
  "$JIRA_URL/rest/api/2/issue/TICKET_KEY/comment"
```

- Expect `HTTP 201` with a comment `id`. Anything else → surface the body + code; do **not** silently fall back to a description-append.
- Use `[text|url]` wiki-links.

## Evidence — attach it AND EMBED it in the comment (used TWICE per ticket)

> **Called at two points, not one** (`[EVIDENCE]`): **(1) repro confirmed** — Phase 3, the main session posts the "đã tái hiện được" comment with the `repro-*` media; **(2) resolve** — Phase 6, the comment carries **both** `repro-*` (before) and `verify-*` (after) plus the PR link. A third call covers the **unreproducible defer** (the ask-reporter comment attaches the `repro-attempt-*` cases that did NOT trigger the bug).
>
> **Filename convention makes the embed self-explanatory — no per-file captions needed.** Save evidence into `.jira-bug/evidence/<TICKET>/` as **`repro-<what>.png|mp4`** (before / the bug happening), **`repro-attempt-<case>.png|mp4`** (a case driven that did NOT reproduce), **`verify-<what>.png|mp4`** (after the fix). Jira shows the filename on every inline image and attachment chip, so a reader can tell before from after at a glance.

> **[HARD RULE — uploading evidence is only HALF the job. An attachment that is not referenced by the comment body lands in the ticket's *Attachments* panel and is invisible from the comment — the reporter/QA reads the comment and sees no proof. Every comment that claims a fix was verified MUST embed its evidence inline.]**

**Order is mandatory: ATTACH first, COMMENT second.** The v2 comment endpoint converts wiki markup → ADF **at write time**, and `!file.png!` only becomes an image node if that attachment **already exists on the issue**. Comment-then-attach silently renders the literal text `!file.png!` and can never be fixed by attaching afterwards.

**Use the filename Jira RETURNS, not your local one** — on a name collision Jira renames the upload (`shot.png` → `shot_1.png`), and an embed pointing at the local name renders as dead literal text.

```bash
# jira_evidence_comment <TICKET_KEY> <BODY_FILE> <EVIDENCE_FILE>...
#   BODY_FILE = the [VN] comment prose (wiki markup). The evidence block is appended by this function.
#   EVIDENCE_CAPTION (env, optional) = heading above the embeds. Default "Ảnh/Video kiểm thử".
#     repro comment      → EVIDENCE_CAPTION="Ảnh/Video tái hiện lỗi"
#     unreproducible ask → EVIDENCE_CAPTION="Các trường hợp đã thử (không ra lỗi)"
#     resolve comment    → default (carries both repro-* before and verify-* after)
#   Attaches every evidence file, embeds images inline (!name.png!), links non-images ([^name.mp4]),
#   posts the comment, then VERIFIES the embed actually rendered.
jira_evidence_comment() {
  local KEY="$1" BODY_FILE="$2"; shift 2
  local EMBEDS=""

  for F in "$@"; do
    # 1) Upload. Expect HTTP 200; response is a JSON array — take the RETURNED filename.
    local RESP; RESP=$(curl -sS -X POST \
      -H "Authorization: Bearer $JIRA_TOKEN" -H "X-Atlassian-Token: no-check" \
      -F "file=@$F" \
      "$JIRA_URL/rest/api/2/issue/$KEY/attachments")   # v2: Jira Server/DC (jira.apero.vn) has no /rest/api/3
    local NAME; NAME=$(printf '%s' "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["filename"])' 2>/dev/null)
    [ -z "$NAME" ] && { echo "ATTACH FAILED for $F: $RESP" >&2; continue; }

    # 2) Build the embed line. Images render inline; video/other render as an attachment chip.
    case "${NAME##*.}" in
      png|jpg|jpeg|gif|webp) EMBEDS="${EMBEDS}\n!${NAME}!" ;;
      *)                     EMBEDS="${EMBEDS}\n[^${NAME}]" ;;
    esac
  done

  # 3) Post the comment WITH the evidence block appended (attachments now exist → embeds resolve).
  local CID; CID=$(BODY_FILE="$BODY_FILE" EMBEDS="$EMBEDS" \
    EVIDENCE_CAPTION="${EVIDENCE_CAPTION:-Ảnh/Video kiểm thử}" python3 - "$JIRA_URL" "$KEY" <<'PY'
import json, os, subprocess, sys
url, key = sys.argv[1], sys.argv[2]
body = open(os.environ["BODY_FILE"]).read().rstrip()
embeds = os.environ["EMBEDS"].replace("\\n", "\n")
if embeds.strip():
    cap = os.environ["EVIDENCE_CAPTION"]
    # The caller's body may already end with the caption line (older templates did) — never write it twice.
    if cap.lower() not in body.lower():
        body += "\n\n*" + cap + ":*"
    body += embeds
out = subprocess.run([
    "curl", "-sS", "-X", "POST",
    "-H", "Authorization: Bearer " + os.environ["JIRA_TOKEN"],
    "-H", "Content-Type: application/json",
    "--data", json.dumps({"body": body}),
    f"{url}/rest/api/2/issue/{key}/comment",
], capture_output=True, text=True).stdout
print(json.loads(out)["id"])
PY
)
  [ -z "$CID" ] && { echo "COMMENT FAILED for $KEY" >&2; return 1; }

  # 4) VERIFY the embed rendered — a 201 alone is NOT proof the image is visible in the comment.
  local RENDERED; RENDERED=$(curl -sS -H "Authorization: Bearer $JIRA_TOKEN" \
    "$JIRA_URL/rest/api/2/issue/$KEY/comment/$CID?expand=renderedBody" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("renderedBody",""))')
  if printf '%s' "$RENDERED" | grep -qE '<img|/rest/api/[23]/attachment|data-media'; then
    echo "OK: comment $CID embeds the evidence"
  else
    echo "EMBED DID NOT RENDER on comment $CID — evidence is attached but NOT visible in the comment" >&2
    return 2
  fi
}
```

- Expect `HTTP 200` per upload (attachments endpoint, **not** 201) and `HTTP 201` for the comment.
- **Return `2` (embed didn't render) is a failure, not a warning** — report it to the dev and never claim "evidence attached to the comment". Retry once with the plain `!name!` form (drop any `|width=`/`|thumbnail` params — Jira Cloud's wiki→ADF converter drops unknown params and can swallow the whole macro).
- `.mp4`/`.webm` **cannot** be embedded inline — `[^name.mp4]` is the correct, rendering form (an attachment chip QA can click).

## Worklog (Fix-13)

```bash
WL=$(python3 -c 'import json; print(json.dumps({"timeSpent":"TIME_SPENT","comment":"Fixed TICKET_KEY: ONE_LINE_SUMMARY. PR #N opened."}))')
curl -sS -w "HTTP %{http_code}\n" -X POST \
  -H "Authorization: Bearer $JIRA_TOKEN" -H "Content-Type: application/json" \
  --data "$WL" \
  "$JIRA_URL/rest/api/2/issue/TICKET_KEY/worklog"
```

Ask the user for time spent (default `30m`, offered as options). Expect `HTTP 201`; non-201 → surface and ask the user to log time manually.

## Transition status (Fix-13)

Used by the **In-Progress lock** (claim at pickup) and the **on-PR-creation → Resolved** transition.

> **[HARD RULE — NEVER hardcode or cache a transition `id`; always resolve it by TARGET status name, immediately before the POST.]** Transition ids are **workflow- and current-status-dependent** and change as the issue moves: from *Request* the "Resolve Issue" transition may be id `41`, but from *In Progress* the very same target (`Resolved`) is id `21`. Reusing an id discovered for one status against another status is exactly what returns **`HTTP 400`**. So the only correct pattern is: (1) GET the transitions for the issue **right now**, (2) pick the one whose `to.name` equals the target (`In Progress` / `Resolved`), (3) POST that id, (4) on `400` retry once **with a `resolution` field**, (5) **verify** the status actually changed (a `2xx` alone is not proof). The helper below does all five — use it for every transition.

```bash
# jira_transition <TICKET_KEY> <TARGET_STATUS_NAME>   e.g. jira_transition AIP686-171 "Resolved"
# Discovers the id by target name (never hardcoded), POSTs, retries with resolution on 400, verifies.
jira_transition() {
  local KEY="$1" TARGET="$2"
  # 1+2. resolve the transition id whose to.name == TARGET, from the CURRENT status
  local TID
  TID=$(curl -sS -H "Authorization: Bearer $JIRA_TOKEN" \
        "$JIRA_URL/rest/api/2/issue/$KEY/transitions" \
        | python3 -c 'import sys,json; t=sys.argv[1].lower(); print(next((x["id"] for x in json.load(sys.stdin)["transitions"] if x["to"]["name"].lower()==t),""))' "$TARGET")
  if [ -z "$TID" ]; then
    echo "$KEY: no transition to '$TARGET' from current status — already there, or use a different target"; return 0
  fi
  # 3. POST plain
  local C
  C=$(curl -sS -o /dev/null -w "%{http_code}" -X POST \
        -H "Authorization: Bearer $JIRA_TOKEN" -H "Content-Type: application/json" \
        --data "{\"transition\":{\"id\":\"$TID\"}}" \
        "$JIRA_URL/rest/api/2/issue/$KEY/transitions")
  # 4. on 400, retry with a resolution field (some workflows require it on resolve/close screens)
  if [ "$C" != "204" ]; then
    for R in Done Fixed Resolved; do
      C=$(curl -sS -o /dev/null -w "%{http_code}" -X POST \
            -H "Authorization: Bearer $JIRA_TOKEN" -H "Content-Type: application/json" \
            --data "{\"transition\":{\"id\":\"$TID\"},\"fields\":{\"resolution\":{\"name\":\"$R\"}}}" \
            "$JIRA_URL/rest/api/2/issue/$KEY/transitions")
      [ "$C" = "204" ] && break
    done
  fi
  # 5. verify
  local NOW
  NOW=$(curl -sS -H "Authorization: Bearer $JIRA_TOKEN" "$JIRA_URL/rest/api/2/issue/$KEY?fields=status" \
        | python3 -c 'import sys,json; print(json.load(sys.stdin)["fields"]["status"]["name"])')
  echo "$KEY: POST=$C now=$NOW"
  [ "$NOW" = "$TARGET" ]
}
```

Expect the final `now=<TARGET>`. If it still didn't land, re-list the transitions (the workflow may name the target differently, e.g. `Done` instead of `Resolved`) and call again with that exact `to.name`. **Do not report a transition as done off a single `2xx` — confirm via the `now=` readback.**

### In-Progress claim = transition **and** assign to the dev account (atomic)

When the transition is the In-Progress lock, assign the ticket to the dev account (current user / token owner) in the **same** claim so status + ownership land together:

```bash
# a. Resolve current user's username (the dev account / token owner)
DEV_USER=$(curl -sS -H "Authorization: Bearer $JIRA_TOKEN" \
  "$JIRA_URL/rest/api/2/myself" | python3 -c 'import sys,json; print(json.load(sys.stdin)["name"])')
# b. Resolve the "In Progress" transition id by TARGET name (never hardcode it — see HARD RULE above)
TID=$(curl -sS -H "Authorization: Bearer $JIRA_TOKEN" \
  "$JIRA_URL/rest/api/2/issue/TICKET_KEY/transitions" \
  | python3 -c 'import sys,json; print(next((x["id"] for x in json.load(sys.stdin)["transitions"] if x["to"]["name"].lower()=="in progress"),""))')
# c. Transition → In Progress AND set assignee in one POST
BODY=$(python3 -c 'import json,sys; print(json.dumps({"transition":{"id":sys.argv[1]},"fields":{"assignee":{"name":sys.argv[2]}}}))' "$TID" "$DEV_USER")
curl -sS -w "HTTP %{http_code}\n" -X POST \
  -H "Authorization: Bearer $JIRA_TOKEN" -H "Content-Type: application/json" \
  --data "$BODY" \
  "$JIRA_URL/rest/api/2/issue/TICKET_KEY/transitions"
```
(Empty `TID` = the issue is already In Progress → skip the transition, just run the assign in the next step.)

- Expect `HTTP 204`. If the workflow screen rejects `assignee` during the transition, fall back to a standalone assign **after** the transition:
  ```bash
  curl -sS -w "HTTP %{http_code}\n" -X PUT \
    -H "Authorization: Bearer $JIRA_TOKEN" -H "Content-Type: application/json" \
    --data "$(python3 -c 'import json,sys; print(json.dumps({"name":sys.argv[1]}))' "$DEV_USER")" \
    "$JIRA_URL/rest/api/2/issue/TICKET_KEY/assignee"
  ```
  Expect `HTTP 204`. Jira Cloud uses `accountId` instead of `name` — read `myself.accountId` and send `{"accountId":"..."}` if the `name` form is rejected.
- If the ticket is already In Progress (transition skipped), still run step **b**'s assign (or the fallback PUT) so the dev account owns it.

## Verify landed (Fix-13 — after PR creation finalize)

```
mcp__jira__jira_get_issue(issue_key="TICKET_KEY", fields="comment,worklog,status,updated", comment_limit=5)
```

Confirm `worklog.total` increased, the PR-link comment is present, and `status.name == "Resolved"`. If any didn't land, tell the user — never claim success from a single `2xx`.
