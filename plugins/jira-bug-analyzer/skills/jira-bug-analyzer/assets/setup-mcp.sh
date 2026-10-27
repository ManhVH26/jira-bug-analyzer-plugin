#!/usr/bin/env bash
# lint: no-strict-mode — prints a per-server status (ADDED/EXISTS_SKIPPED/WARN) and keeps going on one server's failure.
# Set up a missing MCP server from this skill's bundled template
# (assets/mcp-setup-template.json) by merging its def into user-global ~/.claude.json.
#
# Use when a dep probe reports an MCP server missing (jira / confluence / figma / human-mcp).
# Non-MCP CLI tools (gh, adb, gradle, git) are NOT covered by the template — install those
# per environment-setup.md; this script only provisions MCP servers.
#
# Usage:
#   setup-mcp.sh <jira|confluence|figma|human-mcp|all> [--token <JIRA_PERSONAL_TOKEN>] [--force]
#   setup-mcp.sh <status|list>                       # report present/resolved/missing (read-only)
#   setup-mcp.sh ack <server> [<server>...]          # mark a template server confirmed LIVE (persist, machine-local)
#   setup-mcp.sh unack <server> [<server>...]        # clear an ack
#
# - Merges into ~/.claude.json (uncommitted, so literal secrets are safe there) — NOT the
#   committed project .mcp.json.
# - Existing server of the same name is kept unless --force (prints "exists, skipped").
# - `ack` exists because a template server can be served LIVE by a DIFFERENTLY-NAMED MCP
#   (e.g. template `figma` served by the Framelink connector `Framelink_MCP_for_Figma`).
#   The script can only name-match ~/.claude.json, so it can't see that. When the model
#   confirms a server's tools are live via ToolSearch, it runs `ack <server>` once; from
#   then on `status` treats it as covered and stops re-flagging it every session.
# - For `jira`, the template's ${JIRA_PERSONAL_TOKEN} placeholder is replaced with the literal
#   token from --token or $JIRA_PERSONAL_TOKEN; Claude Code does NOT expand ${VAR} in MCP config,
#   so without a literal the server won't authenticate — the script warns and asks for it.
set -u

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$SKILL_DIR/assets/mcp-setup-template.json"
DEST="$HOME/.claude.json"
# Machine-local: template servers confirmed LIVE (configured here OR served by a differently
# named connector). Never pushed to the memory repo — connector availability is per-machine.
RESOLVED="$HOME/.claude/jira-bug-mcp-resolved.json"

WANT="${1:-}"; shift || true
TOKEN="${JIRA_PERSONAL_TOKEN:-}"; FORCE=0; ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --token) TOKEN="${2:-}"; shift 2;;
    --force) FORCE=1; shift;;
    *) ARGS+=("$1"); shift;;       # positional servers (for ack/unack)
  esac
done
[ -n "$WANT" ] || { echo "usage: setup-mcp.sh <status|list|all|jira|confluence|figma|human-mcp|ack|unack> [servers...] [--token <tok>] [--force]"; exit 2; }
[ -f "$TEMPLATE" ] || { echo "NO_TEMPLATE at $TEMPLATE"; exit 1; }

# `ack` / `unack` — record (or clear) template servers the model confirmed LIVE via ToolSearch
# (e.g. template `figma` served by the Framelink connector under a different name). Persisted
# machine-local so `status` stops re-flagging them every session. Read/written here only.
if [ "$WANT" = "ack" ] || [ "$WANT" = "unack" ]; then
  [ "${#ARGS[@]}" -gt 0 ] || { echo "usage: setup-mcp.sh $WANT <server> [<server>...]"; exit 2; }
  WANT="$WANT" python3 - "$TEMPLATE" "$RESOLVED" "${ARGS[@]}" <<'PY'
import json,os,sys
tmpl=json.load(open(sys.argv[1],encoding="utf-8")).get("mcpServers",{})
resolved_p=sys.argv[2]; servers=sys.argv[3:]; want=os.environ["WANT"]
try: cur=set(json.load(open(resolved_p,encoding="utf-8")).get("resolved",[]))
except Exception: cur=set()
for s in servers:
    if s not in tmpl:
        print(f"UNKNOWN_SERVER {s} (template has: {', '.join(tmpl)})"); continue
    cur.add(s) if want=="ack" else cur.discard(s)
os.makedirs(os.path.dirname(resolved_p), exist_ok=True)
json.dump({"resolved":sorted(cur)}, open(resolved_p,"w",encoding="utf-8"), indent=2)
print("RESOLVED="+",".join(sorted(cur)))
PY
  exit 0
fi

# `list` / `status` — read the template and report which servers are present vs missing in ~/.claude.json.
# A server counts as covered if it is configured in ~/.claude.json OR has been ack'd (live via a
# differently-named connector). Init uses this to decide whether to provision. Read-only.
if [ "$WANT" = "list" ] || [ "$WANT" = "status" ]; then
  python3 - "$TEMPLATE" "$DEST" "$RESOLVED" <<'PY'
import json,sys
tmpl=json.load(open(sys.argv[1],encoding="utf-8")).get("mcpServers",{})
try: have=set(json.load(open(sys.argv[2],encoding="utf-8")).get("mcpServers",{}))
except Exception: have=set()
try: resolved=set(json.load(open(sys.argv[3],encoding="utf-8")).get("resolved",[]))
except Exception: resolved=set()
covered=have|resolved
miss=[n for n in tmpl if n not in covered]
pres=[n for n in tmpl if n in covered]
print("TEMPLATE_SERVERS="+",".join(tmpl))
print("PRESENT="+",".join(pres))
print("RESOLVED="+",".join(n for n in tmpl if n in resolved))
print("MISSING="+",".join(miss))
print("NEEDS_SETUP="+("yes" if miss else "no"))
PY
  exit 0
fi

TOKEN="$TOKEN" WANT="$WANT" FORCE="$FORCE" GEMINI_KEYS="${HUMAN_MCP_GEMINI_KEYS:-}" python3 - "$TEMPLATE" "$DEST" <<'PY'
import json,os,sys
tmpl_p,dest_p=sys.argv[1],sys.argv[2]
want=os.environ["WANT"]; token=os.environ.get("TOKEN",""); force=os.environ.get("FORCE")=="1"
gkeys=os.environ.get("GEMINI_KEYS","")
tmpl=json.load(open(tmpl_p,encoding="utf-8")).get("mcpServers",{})
try: dest=json.load(open(dest_p,encoding="utf-8"))
except Exception: dest={}
dest.setdefault("mcpServers",{})
names=list(tmpl) if want=="all" else [want]
added=[]; skipped=[]; warned=[]
for n in names:
    if n not in tmpl:
        print(f"UNKNOWN_SERVER {n} (template has: {', '.join(tmpl)})"); continue
    if n in dest["mcpServers"] and not force:
        skipped.append(n); continue
    sdef=json.loads(json.dumps(tmpl[n]))           # deep copy
    if n=="jira":
        env=sdef.get("env",{})
        if token: env["JIRA_PERSONAL_TOKEN"]=token
        elif env.get("JIRA_PERSONAL_TOKEN","")=="${JIRA_PERSONAL_TOKEN}":
            warned.append(n)                       # placeholder left — needs a literal token
    if n=="human-mcp":
        env=sdef.get("env",{})
        if gkeys: env["GOOGLE_GEMINI_API_KEY"]=gkeys   # comma-separated list; human-mcp rotates internally
        elif env.get("GOOGLE_GEMINI_API_KEY","")=="${HUMAN_MCP_GEMINI_KEYS}":
            warned.append(n)                       # placeholder left — needs HUMAN_MCP_GEMINI_KEYS
    # Templates use a plain `npx` command; Windows (cmd / git-bash) needs the `cmd /c` wrapper to resolve npx.cmd.
    if sdef.get("command")=="npx" and (os.name=="nt" or os.environ.get("MSYSTEM")):
        sdef["command"]="cmd"; sdef["args"]=["/c","npx"]+sdef.get("args",[])
    dest["mcpServers"][n]=sdef
    added.append(n)
json.dump(dest,open(dest_p,"w",encoding="utf-8"),indent=2)
if added:   print("ADDED: "+", ".join(added))
if skipped: print("EXISTS_SKIPPED: "+", ".join(skipped)+" (use --force to overwrite)")
if warned:
    if "jira" in warned:      print("WARN: jira JIRA_PERSONAL_TOKEN left as placeholder — pass --token <tok> (Claude Code won't expand ${VAR}).")
    if "human-mcp" in warned: print("WARN: human-mcp GOOGLE_GEMINI_API_KEY left as placeholder — set HUMAN_MCP_GEMINI_KEYS (comma-separated Gemini keys) in .claude/.env before setup; human-mcp rotates them internally.")
import shutil
for n in added:
    cmd=(dest["mcpServers"][n] or {}).get("command","")
    if cmd and cmd not in ("npx","cmd","uvx") and not shutil.which(cmd):
        print(f"MISSING_BIN={cmd} (server '{n}' cannot start) INSTALL=\"uv tool install {cmd}\" (or pipx install {cmd})")
print("RESTART_REQUIRED="+("yes" if added else "no")+" (reload the session so new mcp__* tools connect)")
PY
