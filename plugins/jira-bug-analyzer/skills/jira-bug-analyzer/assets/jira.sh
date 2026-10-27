#!/usr/bin/env bash
# jira.sh — the Jira writes of a fix, as commands (REST v2; jira.apero.vn is Server/DC).
#
# AAP857-112 did Phase 6 by hand through MCP: a Markdown comment (Jira Server shows `**` and backticks
# literally), no evidence until the dev asked, no Resolved until the dev asked, no worklog, no ledger.
# Each step here is one call that also reads its result back.
#
# Usage:
#   jira.sh claim    <TICKET>                       # In Progress + assign to the token owner
#   jira.sh finalize <TICKET> <body-file> <evidence-dir> [--time 30m] [--pr <url>]
#                    [--ledger <PROJ> <PHASE> --root <repo-root> [--auto-eval pending|-]]
#     body-file    = the [VN] resolve comment (wiki markup; Markdown **bold** / `code` are converted)
#     evidence-dir = .jira-bug/evidence/<TICKET>/ — every repro-* / verify-* image or video in it is
#                    attached FIRST, then embedded in the comment (images inline, videos as chips)
#     --ledger     = also run ledger.sh status=pr-created (which adds the PR to pr-watch.json)
# Output: one KEY=value line per step, last line FINALIZE=ok | FINALIZE=partial MISSING=<steps> (exit 1).
# Creds: JIRA_URL / JIRA_PERSONAL_TOKEN from the env, else the jira MCP server env in ~/.claude.json
# or ./.mcp.json (references/helpers/jira-rest-api.md "Credential bootstrap").
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD="${1:-}"; TICKET="${2:-}"
[ -n "$CMD" ] && [ -n "$TICKET" ] || { echo "usage: jira.sh {claim <TICKET> | finalize <TICKET> <body-file> <evidence-dir> [opts]}"; exit 2; }
shift 2

BODY=""; EVID=""; TIME="30m"; PR=""; LPROJ=""; LPHASE=""; LROOT="$PWD"; AEVAL="-"
if [ "$CMD" = "finalize" ]; then
  BODY="${1:?finalize needs <body-file>}"; EVID="${2:?finalize needs <evidence-dir>}"; shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --time) TIME="$2"; shift 2 ;;
      --pr) PR="$2"; shift 2 ;;
      --ledger) LPROJ="$2"; LPHASE="$3"; shift 3 ;;
      --root) LROOT="$2"; shift 2 ;;
      --auto-eval) AEVAL="$2"; shift 2 ;;
      *) echo "JIRA_ERROR=unknown option $1"; exit 2 ;;
    esac
  done
  [ -f "$BODY" ] || { echo "JIRA_ERROR=no body file $BODY"; exit 1; }
fi

python3 - "$CMD" "$TICKET" "$BODY" "$EVID" "$TIME" "$PR" <<'PY' || RC=$?
import json, mimetypes, os, re, sys, urllib.request, urllib.error, uuid

cmd, key, body_file, evid, time_spent, pr = sys.argv[1:]

def cred(name):
    v = os.environ.get(name, "")
    for p in (os.path.expanduser("~/.claude.json"), ".mcp.json"):
        if v: break
        try: d = json.load(open(p))
        except Exception: continue
        for n, s in (d.get("mcpServers") or {}).items():
            if "jira" in n.lower() and (s.get("env") or {}).get(name):
                v = s["env"][name]; break
    return v

URL, TOKEN = cred("JIRA_URL").rstrip("/"), cred("JIRA_PERSONAL_TOKEN")
if not URL or not TOKEN:
    print("JIRA_ERROR=no JIRA_URL / JIRA_PERSONAL_TOKEN (env, ~/.claude.json jira server, .mcp.json)"); sys.exit(1)
API = f"{URL}/rest/api/2"

def call(method, path, data=None, raw=None, ctype="application/json", extra=None):
    hdr = {"Authorization": "Bearer " + TOKEN, "Accept": "application/json"}
    if extra: hdr.update(extra)
    payload = raw if raw is not None else (json.dumps(data).encode() if data is not None else None)
    if payload is not None: hdr["Content-Type"] = ctype
    req = urllib.request.Request(API + path, data=payload, method=method, headers=hdr)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            txt = r.read().decode() or "null"
            return r.status, json.loads(txt)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")[:300]

def status():
    _, d = call("GET", f"/issue/{key}?fields=status")
    return d["fields"]["status"]["name"] if isinstance(d, dict) else "?"

def transition(target):
    _, d = call("GET", f"/issue/{key}/transitions")
    tid = next((t["id"] for t in d.get("transitions", []) if t["to"]["name"].lower() == target.lower()), "") if isinstance(d, dict) else ""
    if tid:  # resolved by TARGET name, never a cached id (ids differ per current status)
        code, _ = call("POST", f"/issue/{key}/transitions", {"transition": {"id": tid}})
        for res in ("Done", "Fixed", "Resolved"):
            if code == 204: break
            code, _ = call("POST", f"/issue/{key}/transitions", {"transition": {"id": tid}, "fields": {"resolution": {"name": res}}})
    return status()

if cmd == "claim":
    now = transition("In Progress")
    _, me = call("GET", "/myself")
    user = me.get("name", "") if isinstance(me, dict) else ""
    code, _ = call("PUT", f"/issue/{key}/assignee", {"name": user})
    print(f"JIRA_STATUS={now} JIRA_ASSIGNEE={user if code == 204 else 'FAILED:' + str(code)}")
    sys.exit(0 if now.lower() == "in progress" and code == 204 else 1)

if cmd != "finalize":
    print("JIRA_ERROR=unknown command " + cmd); sys.exit(2)

missing = []
# 1) attach evidence first — an embed only renders when the attachment already exists
files = sorted(os.path.join(evid, f) for f in os.listdir(evid)) if os.path.isdir(evid) else []
files = [f for f in files if os.path.isfile(f) and re.match(r"(repro|verify)", os.path.basename(f))
         and (mimetypes.guess_type(f)[0] or "").split("/")[0] in ("image", "video")]
embeds = []
for f in files:
    b = uuid.uuid4().hex
    raw = (f"--{b}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{os.path.basename(f)}\"\r\n"
           f"Content-Type: {mimetypes.guess_type(f)[0]}\r\n\r\n").encode() + open(f, "rb").read() + f"\r\n--{b}--\r\n".encode()
    code, d = call("POST", f"/issue/{key}/attachments", raw=raw, ctype=f"multipart/form-data; boundary={b}",
                   extra={"X-Atlassian-Token": "no-check"})
    if code == 200 and isinstance(d, list) and d:
        name = d[0]["filename"]  # Jira may rename on collision — embed the RETURNED name
        embeds.append(f"!{name}!" if mimetypes.guess_type(name)[0].startswith("image") else f"[^{name}]")
    else:
        missing.append("attach:" + os.path.basename(f))
print(f"JIRA_ATTACHED={len(embeds)}/{len(files)}")
if not files:
    print("JIRA_WARN=no repro-*/verify-* media in " + evid + " — the comment carries no proof")

# 2) comment: wiki markup, evidence embedded
text = open(body_file, encoding="utf-8").read().rstrip()
text = re.sub(r"\*\*(.+?)\*\*", r"*\1*", text)        # Markdown bold -> wiki bold
text = re.sub(r"`([^`\n]+)`", r"{{\1}}", text)        # Markdown code -> wiki monospace
if pr and pr not in text:
    text += f"\n\nPR: {pr}"
if embeds:
    cap = "Ảnh/Video kiểm thử"
    if cap.lower() not in text.lower(): text += f"\n\n*{cap}:*"
    text += "\n" + "\n".join(embeds)
code, d = call("POST", f"/issue/{key}/comment", {"body": text})
cid = d.get("id") if code == 201 and isinstance(d, dict) else None
if not cid:
    missing.append("comment"); print(f"JIRA_COMMENT=FAILED:{code}")
else:
    _, r = call("GET", f"/issue/{key}/comment/{cid}?expand=renderedBody")
    html = r.get("renderedBody", "") if isinstance(r, dict) else ""
    ok = not any(e.startswith("!") for e in embeds) or bool(re.search(r"<img|/attachment/", html))
    if not ok: missing.append("embed")
    print(f"JIRA_COMMENT={cid} EMBED={'ok' if ok else 'NOT-RENDERED'}")

# 3) Resolved, read back
now = transition("Resolved")
if now.lower() != "resolved": missing.append("resolved")
print(f"JIRA_STATUS={now}")

# 4) worklog, read back
_, before = call("GET", f"/issue/{key}/worklog")
n0 = before.get("total", 0) if isinstance(before, dict) else 0
code, d = call("POST", f"/issue/{key}/worklog", {"timeSpent": time_spent, "comment": f"Fixed {key}" + (f" — {pr}" if pr else "")})
_, after = call("GET", f"/issue/{key}/worklog")
n1 = after.get("total", 0) if isinstance(after, dict) else 0
if code != 201 or n1 <= n0: missing.append("worklog")
print(f"JIRA_WORKLOG={d.get('id') if isinstance(d, dict) else 'FAILED:' + str(code)} TIME={time_spent}")

if missing:
    print("FINALIZE=partial MISSING=" + ",".join(missing)); sys.exit(1)
PY
RC="${RC:-0}"
[ "$CMD" = "finalize" ] || exit "$RC"

# 5) ledger (+ pr-watch via ledger.sh), so the --manager hand-off rides on the same command
if [ -n "$LPROJ" ]; then
  [ -n "$PR" ] || { echo "FINALIZE=partial MISSING=ledger(no --pr)"; exit 1; }
  bash "$SELF_DIR/ledger.sh" upsert "$LPROJ" "$LPHASE" "$TICKET" status=pr-created "pr=$PR" "auto_eval=$AEVAL" --root "$LROOT" \
    || { echo "FINALIZE=partial MISSING=ledger"; exit 1; }
fi
[ "$RC" -eq 0 ] && echo "FINALIZE=ok"
exit "$RC"
