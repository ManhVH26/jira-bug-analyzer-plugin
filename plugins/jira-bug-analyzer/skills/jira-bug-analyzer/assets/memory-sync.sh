#!/usr/bin/env bash
# lint: no-strict-mode — read subcommands always exit 0 and print one status line; push reports failure itself.
# Shared-memory sync helper for the jira-bug-analyzer skill.
# Runs under Git Bash on Windows or any POSIX sh. Read-mostly; mutations are git commits.
#
# Repo URL is FIXED: https://github.com/hung-apero/jira-bug-memory (see FIXED_REPO).
#   NO fallback — env $JIRA_BUG_MEMORY_REPO and the config memoryRepo field are ignored.
# Clone lives at ~/.claude/jira-bug-memory (one shared working copy per machine).
#
# Subcommands:
#   init [<url>]        Ensure local config + clone exist. With <url>, write it to config.
#                       If the remote repo is missing, create it private via `gh repo create`.
#   pull [<ttl-secs>]  git pull --rebase (run at session start). No-op if no clone yet.
#                       CACHE-FIRST: if <ttl-secs> is given and the last sync was within
#                       that window, SKIP the network pull and print "FRESH" (fast init).
#                       Omit <ttl-secs> (or 0) to always pull (backward-compatible).
#   push <file> [msg]  Stage one entry file, commit, push with pull--rebase retry (<=3).
#   path               Print the clone dir (for the skill to read/write entry files).
#   url                Print the resolved repo URL.
#
# Always exits 0 on read subcommands; push exits non-zero only if it cannot push after retries.

set -u
CFG="$HOME/.claude/jira-bug-analyzer.json"
CLONE="$HOME/.claude/jira-bug-memory"
RETRIES=3
# The memory repo is FIXED — one shared repo for every dev. NO fallback: no per-dev
# `<gh-login>/jira-bug-memory`, no env/config override, no local-only degrade. Always this URL.
FIXED_REPO="https://github.com/hung-apero/jira-bug-memory"

cfg_get() { # cfg_get <key>
  [ -f "$CFG" ] || { printf ''; return; }
  python3 - "$CFG" "$1" <<'PY' 2>/dev/null
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: print(""); sys.exit()
print(d.get(sys.argv[2],"") or "")
PY
}

cfg_set() { # cfg_set <key> <value>  — merge into the JSON config (create if absent)
  mkdir -p "$(dirname "$CFG")"
  python3 - "$CFG" "$1" "$2" <<'PY' 2>/dev/null
import json,sys,os
p,k,v=sys.argv[1],sys.argv[2],sys.argv[3]
d={}
if os.path.exists(p):
    try: d=json.load(open(p))
    except Exception: d={}
d[k]=v
json.dump(d,open(p,"w"),indent=2)
PY
}

repo_url() {
  # FIXED — always the one shared repo. Env/config are ignored on purpose (no fallback).
  printf '%s' "$FIXED_REPO"
}

stamp() {
  cfg_set lastSync "$(git -C "$CLONE" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  cfg_set lastSyncAt "$(date +%s 2>/dev/null || echo 0)"
}

cmd_init() {
  # FIXED repo — clone the one shared repo. It already EXISTS (hung-apero/jira-bug-memory), so we
  # never create/seed here (no per-dev repo, no fallback). Any passed URL arg is ignored.
  local url; url="$(repo_url)"
  if [ -d "$CLONE/.git" ]; then echo "OK: clone exists at $CLONE"; return 0; fi
  if git clone "$url" "$CLONE" 2>/dev/null; then
    cfg_set memoryRepo "$url"   # record for status readers; resolution still comes from FIXED_REPO
    stamp
    echo "OK: cloned $url"
  else
    echo "REPO_ACCESS: cannot clone $url — need gh auth + permission on the repo"; return 1
  fi
}

# cmd_autowire — make memory READY against the FIXED repo. NO discovery, NO create, NO local-only.
# Just clone/pull the one shared repo (FIXED_REPO):
#   • clone/pull OK               -> WIRED:configured
#   • cannot reach/clone it       -> REPO_ACCESS:<url>  (dev needs gh auth + permission on the repo;
#                                    the orchestrator surfaces this — it NEVER asks the dev for a URL)
# Prints EXACTLY one terminal status line. Always exits 0; the orchestrator branches on it.
cmd_autowire() {
  # FIXED repo, NO fallback: only ever clone/pull the one shared repo. Never discover a per-dev
  # repo, never create, never degrade to local-only. Success -> WIRED; failure -> the dev needs
  # ACCESS to the fixed repo (offline / no permission), surfaced as REPO_ACCESS (never an ask-for-URL).
  local url; url="$(repo_url)"
  [ -d "$CLONE/.git" ] || git clone "$url" "$CLONE" >/dev/null 2>&1
  if [ -d "$CLONE/.git" ]; then
    cmd_pull 0 >/dev/null 2>&1
    echo "WIRED:configured"
  else
    echo "REPO_ACCESS:$url"   # cannot reach/clone the fixed repo -> get access (gh auth + repo permission)
  fi
  return 0
}

cmd_pull() {
  local ttl="${1:-0}"
  [ -d "$CLONE/.git" ] || { echo "SKIP: no clone yet (run init)"; return 0; }
  # CACHE-FIRST: skip the network pull if synced within the TTL window.
  if [ "$ttl" -gt 0 ] 2>/dev/null; then
    local last now age; last="$(cfg_get lastSyncAt)"; last="${last:-0}"
    now="$(date +%s 2>/dev/null || echo 0)"; age=$((now - last))
    if [ "$last" -gt 0 ] 2>/dev/null && [ "$age" -lt "$ttl" ] 2>/dev/null; then
      echo "FRESH: skipped pull (synced ${age}s ago, ttl ${ttl}s)"; return 0
    fi
  fi
  git -C "$CLONE" pull --rebase --autostash -q 2>/dev/null && echo "OK: pulled" || echo "WARN: pull failed (offline?)"
  stamp; return 0
}

cmd_push() { # push <relpath-under-clone> [message]
  local rel="${1:?push needs a file path relative to the clone}"; shift || true
  local msg="${1:-chore: update memory ($rel)}"
  [ -d "$CLONE/.git" ] || { echo "ERR: no clone (run init)"; return 1; }
  local i=0
  while [ "$i" -lt "$RETRIES" ]; do
    ( cd "$CLONE" && git add "$rel" && git commit -m "$msg" -q 2>/dev/null
      git pull --rebase --autostash -q 2>/dev/null
      git push -q ) && { echo "OK: pushed $rel"; stamp; return 0; }
    i=$((i+1)); echo "WARN: push retry $i/$RETRIES"
  done
  echo "ERR: push failed after $RETRIES retries — entry saved locally at $CLONE/$rel"; return 1
}

case "${1:-}" in
  init)     shift; cmd_init "${1:-}";;
  autowire) cmd_autowire;;
  pull)     shift; cmd_pull "${1:-0}";;
  push)     shift; cmd_push "$@";;
  path)     printf '%s\n' "$CLONE";;
  url)      printf '%s\n' "$(repo_url)";;
  *) echo "usage: memory-sync.sh {init [url] | autowire | pull | push <file> [msg] | path | url}"; exit 0;;
esac
