#!/usr/bin/env bash
# lint: no-strict-mode — probe table must always print; never exits non-zero by contract.
# Read-only env preflight for the jira-bug-analyzer skill.
# Probes the deps the skill needs and prints a machine-readable status table.
# NEVER blocks, mutates, or exits non-zero — the model parses the output and decides.
#
# Usage: bash preflight-env.sh [PROJECT_ROOT]
#   PROJECT_ROOT defaults to $PWD. .mcp.json / .claude / gradlew are resolved against it.
#
# Output: one line per dependency —
#   DEP=<id> TIER=<now|later|cond> STATUS=<ok|warn|missing> [NEEDED_AT=<step>] [HINT=<text>]
#   TIER  now   = hard-block if missing (skill cannot start)
#         later = needed at a downstream gate; warn only, re-probe just-in-time
#         cond  = needed only on a condition (video media, CLAUDE.md gate, scheduling)
#   STATUS ok / warn (present-but-degraded) / missing

ROOT="$PWD"; NOW_ONLY=0
for a in "$@"; do
  case "$a" in
    --now-only) NOW_ONLY=1 ;;
    -*) ;;            # ignore unknown flags
    *)  ROOT="$a" ;;  # first non-flag = project root
  esac
done
MCP="$ROOT/.mcp.json"
# MCP servers may live in the project .mcp.json OR globally in ~/.claude.json — search both
# so a globally-configured Jira/Confluence/Figma server isn't reported as missing.
CFGS="$MCP $HOME/.claude.json"

emit() { # emit DEP TIER STATUS [NEEDED_AT] [HINT...]
  local dep="$1" tier="$2" status="$3" needed="$4"; shift 4 2>/dev/null || shift $#
  local line="DEP=$dep TIER=$tier STATUS=$status"
  [ -n "$needed" ] && line="$line NEEDED_AT=$needed"
  [ -n "$*" ] && line="$line HINT=$*"
  printf '%s\n' "$line"
}

have() { command -v "$1" >/dev/null 2>&1; }

# --- MCP server-block / field probes across all candidate config files ---
mcp_has() { # mcp_has <server-name-regex>  -> "1" if any config defines a matching mcpServers key
  python3 - "$1" $CFGS <<'PY' 2>/dev/null || echo 0
import json,re,sys
pat=re.compile(sys.argv[1])
for p in sys.argv[2:]:
    try:
        d=json.load(open(p))
    except Exception:
        continue
    if any(pat.search(k) for k in d.get("mcpServers",{})):
        print(1); sys.exit()
print(0)
PY
}

mcp_field() { # mcp_field <server-name-regex> <env-key>  -> first non-empty value across configs
  python3 - "$1" "$2" $CFGS <<'PY' 2>/dev/null
import json,re,sys
pat=re.compile(sys.argv[1]); key=sys.argv[2]
for p in sys.argv[3:]:
    try:
        d=json.load(open(p))
    except Exception:
        continue
    for name,s in d.get("mcpServers",{}).items():
        if pat.search(name):
            v=(s.get("env",{}) or {}).get(key,"")
            if v:
                print(v); sys.exit()
PY
}

# ---- FAST PATH: --now-only emits ONLY the TIER=now deps in a single python pass ----
# Used by init-lib.sh on the hot path so the list isn't blocked by later/cond probes
# (gh/adb/gradle/figma/confluence/mobile/skills) — those are re-probed at their gates.
if [ "$NOW_ONLY" -eq 1 ]; then
  python3 - "$MCP" "$HOME/.claude.json" <<'PY' 2>/dev/null
import json,os,re,sys
servers={}
for p in sys.argv[1:]:
    try: d=json.load(open(p))
    except Exception: continue
    servers.update(d.get("mcpServers",{}) or {})
jira=re.compile(r'(^|_)jira')
if any(jira.search(k) for k in servers):
    print("DEP=jira-mcp TIER=now STATUS=ok")
else:
    print("DEP=jira-mcp TIER=now STATUS=missing NEEDED_AT=1 HINT=no jira server in .mcp.json (and verify mcp__jira__ tools are connected)")
# REST creds: process env FIRST, then the jira server's env block.
tok=os.environ.get("JIRA_PERSONAL_TOKEN",""); url=os.environ.get("JIRA_URL","")
if not tok or not url:
    for name,s in servers.items():
        if jira.search(name):
            env=(s.get("env",{}) or {})
            tok=tok or env.get("JIRA_PERSONAL_TOKEN","")
            url=url or env.get("JIRA_URL","")
if tok and url:
    print("DEP=jira-creds TIER=now STATUS=ok")
else:
    miss="+".join([x for x,v in (("JIRA_URL",url),("JIRA_PERSONAL_TOKEN",tok)) if not v])
    print("DEP=jira-creds TIER=now STATUS=missing NEEDED_AT=0.5 HINT=missing %s (checked .mcp.json + ~/.claude.json)" % miss)
PY
  exit 0
fi

# ---- TIER now: Jira MCP + REST creds (skill cannot start without these) ----
if [ "$(mcp_has '(^|_)jira')" = "1" ]; then
  emit jira-mcp now ok "" ""
else
  emit jira-mcp now missing 1 "no jira server in .mcp.json (and verify mcp__jira__ tools are connected)"
fi

# Read process env FIRST (so creds exported into the env or living in ~/.claude.json both resolve),
# then fall back to the jira server's env block in .mcp.json / ~/.claude.json.
JTOK="${JIRA_PERSONAL_TOKEN:-$(mcp_field '(^|_)jira' JIRA_PERSONAL_TOKEN)}"
JURL="${JIRA_URL:-$(mcp_field '(^|_)jira' JIRA_URL)}"
if [ -n "$JTOK" ] && [ -n "$JURL" ]; then
  emit jira-creds now ok "" ""
elif [ ! -f "$MCP" ] && [ ! -f "$HOME/.claude.json" ]; then
  emit jira-creds now missing 0.5 "no .mcp.json or ~/.claude.json — REST comment/worklog/transition/claim need JIRA_URL + JIRA_PERSONAL_TOKEN"
else
  miss=""; [ -z "$JURL" ] && miss="JIRA_URL"; [ -z "$JTOK" ] && miss="${miss:+$miss+}JIRA_PERSONAL_TOKEN"
  emit jira-creds now missing 0.5 "jira block found but missing $miss (checked .mcp.json + ~/.claude.json)"
fi

# ---- TIER cond: ground-truth + media + scheduling ----
[ "$(mcp_has confluence)" = "1" ] && emit confluence-mcp cond ok 8 "" \
  || emit confluence-mcp cond missing 8 "no confluence server in .mcp.json — spec ground truth / CLAUDE.md gate"

[ "$(mcp_has figma)" = "1" ] && emit figma-mcp cond ok 8 "" \
  || emit figma-mcp cond missing 8 "no figma server in .mcp.json — design ground truth / CLAUDE.md gate"

# human-mcp analyzes images/videos → text (Fix-5 + verify screen-understanding). Fallback = Claude-native vision.
[ "$(mcp_has '(^|_|-)human')" = "1" ] && emit human-mcp cond ok media "" \
  || emit human-mcp cond missing media "no human-mcp server — media analysis (setup-mcp.sh human-mcp; keys via HUMAN_MCP_GEMINI_KEYS in .claude/.env). Non-blocking: falls back to Claude-native vision."

# ---- TIER later: PR / worktree / on-device verify ----
if have gh; then
  if gh auth status >/dev/null 2>&1; then emit gh-cli later ok 9A ""
  else emit gh-cli later warn 9A "gh installed but not authenticated (gh auth login)"; fi
else
  emit gh-cli later missing 9A "gh CLI not installed — PR create / diff-web / merge poll"
fi

have git && emit git later ok 7 "" || emit git later missing 7 "git not on PATH — fix worktree isolation"

if have adb; then
  DEVCOUNT="$(adb devices 2>/dev/null | awk 'NR>1 && $2=="device"' | wc -l | tr -d ' ')"
  if [ "${DEVCOUNT:-0}" -gt 0 ]; then emit adb-device later ok verify "$DEVCOUNT device(s)"
  else emit adb-device later warn verify "adb present but no device/emulator connected — start one before self-verify"; fi
else
  emit adb-device later missing verify "adb not on PATH — on-device run + self-verify"
fi

[ -x "$ROOT/gradlew" ] && emit gradle later ok verify "" \
  || emit gradle later warn verify "no ./gradlew in $ROOT — build/launch (skip if target repo differs from CWD)"

# ---- TIER later: sibling skills the gates delegate to ----
for sk in android-self-verify worktree run; do
  found=""
  for base in "$ROOT/.claude/skills" "$HOME/.claude/skills"; do
    [ -d "$base/$sk" ] && { found="$base/$sk"; break; }
  done
  [ -n "$found" ] && emit "skill-$sk" later ok verify "" \
    || emit "skill-$sk" later warn verify "skill '$sk' not found under .claude/skills — gate delegation may fall back"
done

exit 0
