#!/usr/bin/env bash
# lint: no-strict-mode — sourced library; its probes must never abort the caller (contract: read-only, always exits 0).
# Shared init core for the jira-bug-analyzer skill.
#
# This file is a LIBRARY — it is sourced, not run directly. The three per-mode
# entry scripts (init-single.sh / init-multi.sh / init-team.sh) source it and
# call `jb_init_run <MODE> "$@"`. ONE place holds the deterministic probe logic;
# each wrapper only declares its MODE so the printed INIT-STATUS is tailored.
#
# Read-only: NO writes, NO MCP, never blocks, always exits 0. The model reads
# INIT-STATUS and decides ACTIONS from the table in the matching mode file
# (phase1-init-<mode>.md) — behavior lives in that table, NOT in this script.
#
# Usage (via a wrapper): bash init-<mode>.sh [PROJECT_ROOT] [--project <KEY>] [--recheck-env]
#   PROJECT_ROOT defaults to $PWD (the target bug repo).
#   --project <KEY> is the Jira project key. When given AND there is no local
#                   .jira-bug/setup.json, init also checks the shared memory clone
#                   for project/<KEY>/setup.json so a teammate's saved setup is
#                   reused instead of re-running first-time intake.
#   --recheck-env forces a fresh env preflight, ignoring the cached env block.
#
# SETUP resolution (local cache -> remote memory -> absent):
#   1. local  .jira-bug/setup.json present                  -> SETUP=cached
#   2. else --project given + <clone>/project/<KEY>/setup.json present
#                                                            -> SETUP=remote  (REMOTE_SETUP=<path>)
#   3. else                                                  -> SETUP=absent
#
# Mode-gated output (BASEBRANCH is emitted in ALL modes — single fixes branch + PR off it too;
#   BASEBRANCH=none means the dev must be ASKED — init never auto-fills it. BASEBRANCH_SUGGEST=<v>
#   is the OPTIONAL shared-mirror value to offer as the recommended one-tap option, never persisted):
#   single -> ENV, SETUP, [REMOTE_SETUP], MEMORY, BASEBRANCH, [BASEBRANCH_SUGGEST], PENDING_WATCH, PENDING_BATCH   (no pull -> no BOARD/PULLQUERY/TEAM)
#   multi  -> + BOARD, PULLQUERY, TEAM                                           (solo worker pulls + lists)
#   team   -> + BOARD, PULLQUERY, TEAM, TEAM_FLAG                                (launcher: TEAM_FLAG hints the Agent-Teams env flag)

# --- read a field from a setup.json file (empty if absent / unparseable) ---
jb_setup_get() { # jb_setup_get <file> <python-expression-on-d>
  [ -f "$1" ] || { printf ''; return; }
  python3 - "$1" "$2" <<'PY' 2>/dev/null
import json,re,sys
try:
    text=open(sys.argv[1]).read()
except Exception: print(""); sys.exit()
try:
    d=json.loads(text)
except Exception:
    # tolerate trailing commas (`,}` / `,]`) — a hand-written setup.json must not read as empty
    try: d=json.loads(re.sub(r',(\s*[}\]])', r'\1', text))
    except Exception: print(""); sys.exit()
try:
    v=eval(sys.argv[2], {}, {"d": d})
except Exception:
    v=""
print(v if v not in (None, False) else "")
PY
}

# --- WARM state read (ZERO external forks): board + pullQuery.jql from setup.json, env/mcp cache
#     freshness from the user-scope probe cache (~/.claude/jira-bug-analyzer/probe-cache.json),
#     and the analyzer config's lastSyncAt (memory-pull freshness). SETS the caller's locals
#     directly via bash dynamic scope (no command-substitution, no eval):
#       BOARD  JQL  BASEBRANCH(value|'')  BUILDCMD/APKGLOB/AUTOSCOPE(value|'')  ENVCACHE(ok|'')  MCPCACHE(ok|'')  MEMFRESH(1|'')
#     This replaces the former single ~190ms python3 fork. On Windows/git-bash process creation is
#     THE cost (a fork ~60-75ms), so the rule is zero subprocesses: `while read` + parameter
#     expansion + integer arithmetic are all shell builtins -> the read is effectively free.
#     (An earlier sed/grep rewrite was SLOWER than python because ~10 small forks cost more than one
#     python startup — hence pure builtins, not "fewer forks".)
#     Correctness invariants that make this faithful to the old python (NOT a shortcut):
#       * jb_env_probe NEVER caches a block (it rm's the cache on block: and writes only on ENV=ok)
#         -> a FRESH probe-cache existing IS proof the last probe's required TIER=now deps were ok,
#         so ENV freshness == file freshness (no need to re-parse the deps map).
#       * the cache CAN still record a "missing" mcp server (env block ignores mcp), so MCP is ok
#         only if the fresh cache contains no "missing" token. Cached TIER=now deps are never
#         "missing" (a missing required dep would have blocked -> no write), so a "missing" token
#         can ONLY come from mcp_setup -> a substring test is sufficient and faithful.
#     jql lives on one line (json.dump keeps strings unbroken) with embedded \" and literal commas;
#     the terminator '",' is stripped as the line suffix so the internal \", in
#     (\"Request\",\"Reopened\") is not mistaken for it; then \" and \\ are unescaped. ---
jb_state() { # jb_state <setup-file> <probe-cache-file> <env-ttl> <now-epoch> <config-file> <mem-ttl>
  local setup="$1" envc="$2" ttl="$3" now="$4" cfg="$5" memttl="$6" line v
  BOARD="-"; JQL=""; BASEBRANCH=""; ENVCACHE=""; MCPCACHE=""; MEMFRESH=""; MEMREPO_SET=""
  TYPE=""; SHEETCSV=""; SHEETROWS=""; BUILDCMD=""; APKGLOB=""; AUTOSCOPE=""
  if [ -f "$setup" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        *'"board"'*:*)
          v=${line#*:}; v=${v#*\"}; v=${v%%\"*}
          [ -n "$v" ] && BOARD="$v" ;;
        *'"baseBranch"'*:*)
          v=${line#*:}; v=${v#*\"}; v=${v%%\"*}
          [ -n "$v" ] && BASEBRANCH="$v" ;;
        *'"buildCmd"'*:*)
          v=${line#*:}; v=${v#*\"}; v=${v%%\"*}
          [ -n "$v" ] && BUILDCMD="$v" ;;
        *'"autoScope"'*:*)
          v=${line#*:}; v=${v#*\"}; v=${v%%\"*}
          [ -n "$v" ] && AUTOSCOPE="$v" ;;
        *'"apkGlob"'*:*)
          v=${line#*:}; v=${v#*\"}; v=${v%%\"*}
          [ -n "$v" ] && APKGLOB="$v" ;;
        *'"type"'*:*)
          v=${line#*:}; v=${v#*\"}; v=${v%%\"*}
          [ -n "$v" ] && TYPE="$v" ;;
        *'"csvUrl"'*:*)
          v=${line#*:}; v=${v#*\"}; v=${v%%\"*}
          [ -n "$v" ] && SHEETCSV="$v" ;;
        *'"rows"'*)
          SHEETROWS="1" ;;
        *'"jql"'*:*)
          v=${line#*:}; v=${v#*\"}      # after the value's opening quote
          v=${v%\",}; v=${v%\"}         # strip trailing ", (or a bare " on the last field)
          v=${v//\\\"/\"}; v=${v//\\\\/\\}
          JQL="$v" ;;
      esac
    done < "$setup"
  fi
  if [ -f "$envc" ]; then
    local at="" hasmissing=""
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        *'"at"'*:*)      v=${line#*:}; at="${v//[!0-9]/}" ;;
        *'"missing"'*)   hasmissing=1 ;;
      esac
    done < "$envc"
    if [ -n "$at" ]; then
      local age=$(( now - at ))
      if [ "$age" -ge 0 ] && [ "$age" -lt "$ttl" ]; then
        ENVCACHE="ok"
        [ -z "$hasmissing" ] && MCPCACHE="ok"
      fi
    fi
  fi
  if [ -f "$cfg" ]; then
    local last=""
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        *'"lastSyncAt"'*:*) v=${line#*:}; last="${v//[!0-9]/}" ;;
        *'"memoryRepo"'*:*) v=${line#*:}; v=${v#*\"}; v=${v%%\"*}; [ -n "$v" ] && MEMREPO_SET="1" ;;
      esac
    done < "$cfg"
    if [ -n "$last" ]; then
      local memage=$(( now - last ))
      { [ "$memage" -ge 0 ] && [ "$memage" -lt "$memttl" ]; } && MEMFRESH="1"
    fi
  fi
}

# --- ENV + MCP-setup probe (the slow cold-tick work): `setup-mcp.sh status` + `preflight-env.sh`,
#     and on success writes the shared probe-cache so the NEXT run is warm. This is NOT run inline
#     by the normal init anymore — on a cold/forced env tick init emits ENV=recheck and the model
#     runs this in a BACKGROUND subagent (`init-<mode>.sh --env-refresh`) so the env check runs in
#     PARALLEL with the jira pull instead of blocking the list. Prints ENV=ok|block:<dep> and
#     MCP_SETUP=ok|needs:<list>. Also refreshes shared memory (pull) — one bg agent does both. ---
jb_env_probe() { # jb_env_probe <root> <cache-dir> <cache-file> <now>
  local SELF_DIR; SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  local ROOT="$1" CACHE_DIR="$2" ENVCACHE_FILE="$3" NOW="$4"
  local out blocked mcpout MISSING_MCP ENV MCPSETUP
  mcpout="$(bash "$SELF_DIR/setup-mcp.sh" status 2>/dev/null)"
  MISSING_MCP="$(printf '%s\n' "$mcpout" | awk -F= '/^MISSING=/{print $2}')"
  [ -n "$MISSING_MCP" ] && MCPSETUP="needs:$MISSING_MCP" || MCPSETUP="ok"
  out="$(bash "$SELF_DIR/preflight-env.sh" --now-only "$ROOT" 2>/dev/null)"
  blocked="$(printf '%s\n' "$out" | awk '/TIER=now/ && /STATUS=missing/ {sub(/^DEP=/,"",$1); print $1; exit}')"
  if [ -n "$blocked" ]; then
    # Do NOT cache a block — re-probe every run so the moment the dep is fixed it's picked up.
    ENV="block:$blocked"; rm -f "$ENVCACHE_FILE" 2>/dev/null || true
  else
    ENV="ok"
    if mkdir -p "$CACHE_DIR" 2>/dev/null; then
      python3 - "$ENVCACHE_FILE" "$NOW" "$mcpout" "$out" <<'PY' 2>/dev/null || true
import json,re,sys
cache,now,mcpout,out=sys.argv[1],int(sys.argv[2]),sys.argv[3],sys.argv[4]
deps={}
for line in out.splitlines():
    if 'TIER=now' not in line: continue
    m=re.search(r'DEP=(\S+).*\bSTATUS=(\S+)', line)
    if m: deps[m.group(1)]=m.group(2)
def field(k):
    for ln in mcpout.splitlines():
        if ln.startswith(k+"="):
            return [x for x in ln[len(k)+1:].strip().split(",") if x]
    return []
tmpl=field("TEMPLATE_SERVERS"); miss=set(field("MISSING"))
mcp={n:("missing" if n in miss else "ok") for n in tmpl}
json.dump({"deps":deps,"mcp_setup":mcp,"at":now}, open(cache,"w"), indent=2)
PY
    fi
  fi
  # refresh shared memory too (same bg agent), best-effort and non-fatal.
  bash "$SELF_DIR/memory-sync.sh" pull 0 >/dev/null 2>&1 || true
  printf 'ENV=%s\nMCP_SETUP=%s\n' "$ENV" "$MCPSETUP"
}

# --- main entry: jb_init_run <MODE:single|multi|team> [args...] ---
jb_init_run() {
  local MODE="${1:-multi}"; shift || true
  local SELF_DIR; SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  local ROOT="$PWD" RECHECK=0 PROJECT_KEY="" ENVREFRESH=0 SHEET_ARG="" AUTO=0 REPRO=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --recheck-env|--recheck) RECHECK=1 ;;
      --env-refresh) ENVREFRESH=1 ;;   # bg-subagent entry: probe env+mcp, write cache, pull memory
      --project)    shift; PROJECT_KEY="${1:-}" ;;
      --project=*)  PROJECT_KEY="${1#--project=}" ;;
      --google-sheet) shift; SHEET_ARG="${1:-}" ;;   # board source = a Google Sheet (references/google-sheet-board.md)
      --google-sheet=*) SHEET_ARG="${1#--google-sheet=}" ;;
      --auto)       AUTO=1 ;;
      --repro)      REPRO=on ;;
      --no-repro)   REPRO=off ;;
      -*) ;;                       # ignore unknown flags
      *)  ROOT="$1" ;;             # first non-flag = project root
    esac
    shift || break
  done

  local JB="$ROOT/.jira-bug"
  local SETUP="$JB/setup.json"
  # Machine-local probe cache lives in USER scope (shared across every project on this
  # machine) — both the TIER=now env deps (jira mcp+creds) AND the MCP-setup status derive
  # from ~/.claude.json, not the repo, so caching per-project just re-probed the same answer
  # for each board. NEVER pushed to shared memory.
  local CACHE_DIR="$HOME/.claude/jira-bug-analyzer"
  local ENVCACHE_FILE="$CACHE_DIR/probe-cache.json"
  # One-time migration: adopt a legacy project-level .jira-bug/env-cache.json if no user-scope
  # cache exists yet, then drop the old file so it stops confusing.
  if [ ! -f "$ENVCACHE_FILE" ] && [ -f "$JB/env-cache.json" ] && mkdir -p "$CACHE_DIR" 2>/dev/null; then
    cp "$JB/env-cache.json" "$ENVCACHE_FILE" 2>/dev/null && rm -f "$JB/env-cache.json" 2>/dev/null || true
  fi
  local ENV_TTL=2592000                     # 30d — env deps + MCP setup almost never change;
                                            # cached across sessions, self-heals monthly, --recheck-env forces a re-probe
  local CFG_FILE="$HOME/.claude/jira-bug-analyzer.json"   # analyzer config (holds lastSyncAt)
  local MEM_TTL=600                                        # memory-pull freshness window (s)
  local NOW; NOW="$(date +%s 2>/dev/null || echo 0)"

  # --- bg-subagent entry: ONLY do the deferred env+mcp probe (+memory pull) and exit. The model
  #     runs this in a BACKGROUND agent so it runs in PARALLEL with the main thread's jira pull. ---
  if [ "$ENVREFRESH" -eq 1 ]; then
    jb_env_probe "$ROOT" "$CACHE_DIR" "$ENVCACHE_FILE" "$NOW"
    return 0
  fi

  # --- SETUP resolution: local cache -> remote memory (needs --project) -> absent ---
  # Done BEFORE memory/jb_state so the warm (local-cache) path does ZERO network here. The
  # memory-clone path/pull is only needed for the cold remote-adopt case (no local setup +
  # a --project key) — that rare path pulls synchronously so the remote read is current.
  local CLONE="" REMOTE_SETUP="" SETUP_STATE EFF
  if [ -f "$SETUP" ]; then
    SETUP_STATE="cached"; EFF="$SETUP"
  elif [ -n "$PROJECT_KEY" ]; then
    # FORCE a fresh pull (ttl 0) before declaring the remote setup absent — a TTL-skipped
    # (stale) clone could miss a project/<KEY>/setup.json another dev just pushed, which would
    # wrongly route us into first-run intake. No local setup => this network round-trip is rare
    # (first run / post-cleanup only); the warm local-cached path above stays zero-network.
    bash "$SELF_DIR/memory-sync.sh" pull 0 >/dev/null 2>&1   # freshen clone before the remote read
    if CLONE="$(bash "$SELF_DIR/memory-sync.sh" path 2>/dev/null)" && [ -n "$CLONE" ] && [ -f "$CLONE/project/$PROJECT_KEY/setup.json" ]; then
      SETUP_STATE="remote"; REMOTE_SETUP="$CLONE/project/$PROJECT_KEY/setup.json"; EFF="$REMOTE_SETUP"
      # Auto-hydrate the LOCAL mirror so the NEXT run is a SETUP=cached local hit (project-level
      # fields only; the machine-local env lives in env-cache.json, never in setup.json).
      if mkdir -p "$JB" 2>/dev/null; then
        python3 - "$REMOTE_SETUP" "$SETUP" <<'PY' 2>/dev/null || true
import json,re,sys
try: text=open(sys.argv[1]).read()
except Exception: sys.exit(0)
try: d=json.loads(text)
except Exception:
    # tolerate trailing commas so a corrupt remote still hydrates the local mirror (and self-heals)
    try: d=json.loads(re.sub(r',(\s*[}\]])', r'\1', text))
    except Exception: sys.exit(0)
d.pop("env",None)                       # defensive: env is machine-local, never mirrored
json.dump(d, open(sys.argv[2],"w"), indent=2)
PY
      fi
    else
      SETUP_STATE="absent"; EFF=""
    fi
  else
    SETUP_STATE="absent"; EFF=""
  fi

  # --- board + jql (from EFF) + probe-cache (env+mcp) + memory TTL freshness, all via shell
  #     builtins (jb_state sets these locals directly — zero subprocess on the warm path) ---
  local BOARD="-" JQL="" BASEBRANCH="" ENVCACHE="" MCPCACHE="" MEMFRESH="" MEMREPO_SET=""
  local TYPE="" SHEETCSV="" SHEETROWS="" BUILDCMD="" APKGLOB="" AUTOSCOPE=""
  jb_state "$EFF" "$ENVCACHE_FILE" "$ENV_TTL" "$NOW" "$CFG_FILE" "$MEM_TTL"
  BOARD="${BOARD:--}"

  # --- board source type: the --google-sheet arg wins; else the setup's persisted `type`; else jira.
  #     A setup with NO `type` field reads as "jira" (every existing project is untouched). For a
  #     google-sheet board the pull is a LOCAL cache read (setup.sheet.rows) + a background CSV
  #     refresh — no jira_search, no network-first fast-path — so force read-phase1 / PULL_NOW=no and
  #     let the model follow references/google-sheet-board.md. See SKILL.md `[SHEET]`. ---
  local SETUP_TYPE="jira" SHEET_CSV="" SHEET_CACHE="absent"
  if [ -n "$SHEET_ARG" ] || [ "$TYPE" = "google-sheet" ]; then SETUP_TYPE="google-sheet"; fi
  if [ "$SETUP_TYPE" = "google-sheet" ]; then
    [ -n "$SHEET_ARG" ] && SHEET_CSV="$(bash "$SELF_DIR/sheet-board.sh" csv-url "$SHEET_ARG" 2>/dev/null)"
    [ -z "$SHEET_CSV" ] && SHEET_CSV="$SHEETCSV"          # fall back to the cached csvUrl
    [ -n "$SHEETROWS" ] && SHEET_CACHE="cached"
  fi

  # --- baseBranch missing from the EFFECTIVE setup: do NOT silently auto-fill. The dev must be
  #     ASKED (one-tap confirm) so they keep control and can change it — a removed/absent baseBranch
  #     is a signal to (re)configure, NOT to re-adopt the old value behind their back. We only READ
  #     the shared mirror's value (if any) to surface it as a NON-BINDING SUGGESTION the model offers
  #     as the recommended option; nothing is persisted here (init stays read-only on this path).
  #     Gated to the missing case -> the warm path (field present) pays NOTHING.
  #     NOTE: a wholesale SETUP=remote adoption already hydrated baseBranch into the local mirror
  #     above (adopting a teammate's complete setup), so this only triggers on a cached-local setup
  #     that LACKS the field (predates it, or the dev deliberately removed it). ---
  # baseBranch precedence: LOCAL (already read into BASEBRANCH from EFF) -> REMOTE mirror -> ask.
  # A value SAVED in memory (either layer) is authoritative config -> AUTO-REUSE, no prompt; only a
  # heuristic guess (CLAUDE.md / git default, resolved by the model) ever asks. So when BASEBRANCH is
  # still empty here (local cache lacked it), consult the shared remote mirror and ADOPT its saved
  # value, hydrating the local mirror so the NEXT run is a pure-local hit. Only when remote ALSO lacks
  # it does BASEBRANCH stay empty -> BASEBRANCH=none -> the model asks the dev (then saves to both).
  # (A wholesale SETUP=remote adoption already copied baseBranch into the local mirror above, so this
  # only triggers on a cached-LOCAL setup that predates / dropped the field.)
  local BASEBRANCH_SUGGEST=""
  if [ -z "$BASEBRANCH" ] && [ "$BOARD" != "-" ]; then
    local BB_CLONE BB_REMOTE BB_VAL=""
    if BB_CLONE="$(bash "$SELF_DIR/memory-sync.sh" path 2>/dev/null)" && [ -n "$BB_CLONE" ]; then
      BB_REMOTE="$BB_CLONE/project/$BOARD/setup.json"
      [ -f "$BB_REMOTE" ] && BB_VAL="$(bash "$SELF_DIR/setup-json.sh" get "$BB_REMOTE" baseBranch 2>/dev/null)"
    fi
    if [ -n "$BB_VAL" ]; then
      BASEBRANCH="$BB_VAL"                       # auto-reuse the saved remote value (no ask)
      [ -f "$SETUP" ] && bash "$SELF_DIR/setup-json.sh" merge-set "$SETUP" "baseBranch=$BB_VAL" >/dev/null 2>&1 || true
    fi
  fi

  # --- MEMORY: fresh per the cached lastSyncAt -> no work; else STALE -> the model refreshes it
  #     in a BACKGROUND subagent (memory is only needed later at the dedup/claim gate, never for
  #     the list), so the pull never blocks the main board. ---
  local MEMORY
  if [ -n "$MEMFRESH" ]; then MEMORY="fresh"; else MEMORY="stale"; fi

  # --- MEMORY_REPO: is the shared memory repo even WIRED UP on this machine? configured iff the
  #     $JIRA_BUG_MEMORY_REPO env is set OR ~/.claude/jira-bug-analyzer.json carries memoryRepo
  #     (detected by jb_state's config read -> MEMREPO_SET, zero extra fork). When unconfigured
  #     there is NO remote setup to reuse AND this run's setup cannot persist for the next dev, so
  #     SETUP=absent is meaningless here -> the model HARD-BLOCKS and onboards (phase1 table). ---
  # The memory repo is a FIXED constant (memory-sync.sh FIXED_REPO = hung-apero/jira-bug-memory),
  # so it is ALWAYS configured — no per-dev URL, no ask. Only the clone may be absent (autowire clones it).
  local MEMREPO="configured"
  # --- MEMORY_CLONE: does the local shared-memory clone actually exist on disk? A configured URL
  #     with NO clone (fresh machine, deleted clone) still needs auto-wiring (clone+sync) before the
  #     memory layer works -> the model runs `memory-sync.sh autowire` whenever NOT wired
  #     (unconfigured OR clone absent). Cheap dir test, no fork/network. ---
  local MEMCLONE
  [ -d "$HOME/.claude/jira-bug-memory/.git" ] && MEMCLONE="present" || MEMCLONE="absent"

  # --- ENV + MCP-setup: trust the fresh user-scope cache (warm path = instant, no fork). On a
  #     cold/forced tick do NOT run the (slow) preflight + setup-mcp probe inline — emit
  #     ENV=recheck / MCP_SETUP=recheck and let the model run `--env-refresh` in a BACKGROUND
  #     subagent that runs PARALLEL with the jira pull and writes the probe-cache (next run warm).
  #     A genuinely-missing jira mcp/creds still surfaces — the jira_search call fails and the
  #     subagent reports ENV=block:<dep>. The cache stays machine-local; --recheck-env forces a
  #     refresh. (The probe body lives in jb_env_probe.) ---
  local ENV MCPSETUP
  if [ "$RECHECK" -eq 0 ] && [ -n "$ENVCACHE" ] && [ -n "$MCPCACHE" ]; then
    ENV="$ENVCACHE"; MCPSETUP="$MCPCACHE"
  else
    ENV="recheck"; MCPSETUP="recheck"
  fi

  local PULLQUERY TEAM PWATCH PBATCH
  [ -n "$JQL" ] && PULLQUERY="cached" || PULLQUERY="none"
  [ -f "$JB/team-board.md" ]     && TEAM="active" || TEAM="none"
  [ -f "$JB/pr-watch.json" ]     && PWATCH="yes"  || PWATCH="no"
  [ -f "$JB/batch-progress.md" ] && PBATCH="yes"  || PBATCH="no"

  # --- NEXT: on a warm all-green multi run the model fires the pull WITHOUT reading the phase1
  #     init file (the canonical list spec is summarized in SKILL.md's fast-path). Any non-trivial
  #     state -> read-phase1. ENV=recheck/MEMORY=stale do NOT block NEXT=pull — they fan out to a
  #     background subagent that runs PARALLEL with the pull. A MISSING baseBranch (not in local nor
  #     adopted from remote) is non-trivial -> force read-phase1 so the model resolves & persists it
  #     (the list still renders fast — PULL_NOW below stays decoupled). ---
  # Memory must be WIRED (configured URL AND a local clone) before the fast-path pull — an
  # unconfigured-or-uncloned machine first runs `memory-sync.sh autowire` (phase1 table:
  # auto-adopt the existing remote, else ask the dev), so force read-phase1 until wired.
  local NEXT="read-phase1"
  if [ "$MODE" = "multi" ] && [ "$SETUP_STATE" = "cached" ] && [ "$PULLQUERY" = "cached" ] \
     && [ "$TEAM" = "none" ] && [ "$PWATCH" = "no" ] && [ "$PBATCH" = "no" ] && [ -n "$BASEBRANCH" ] \
     && [ "$MEMREPO" = "configured" ] && [ "$MEMCLONE" = "present" ]; then
    case "$ENV" in block:*) ;; *) NEXT="pull";; esac
  fi

  # --- PULL_NOW: decoupled from NEXT. The bug-list pull needs ONLY the cached JQL+fields (both
  #     emitted inline), so it is safe to fire jira_search IMMEDIATELY whenever the query is cached
  #     and env is not hard-blocked — even when a non-trivial state (pending batch/watch, stale
  #     memory) forces NEXT=read-phase1. The model fires the pull on PULL_NOW=yes and reads the
  #     phase1 detail file CONCURRENTLY (same message) / afterward — never before the jira call.
  #     This is the bug-list speedup: the slow network round-trip starts first, the local file read
  #     overlaps it, and pending-state handling happens after the list renders. ---
  local PULL_NOW="no"
  if { [ "$MODE" = "multi" ] || [ "$MODE" = "team" ]; } && [ "$PULLQUERY" = "cached" ] \
     && [ "$MEMREPO" = "configured" ] && [ "$MEMCLONE" = "present" ]; then
    case "$ENV" in block:*) ;; *) PULL_NOW="yes";; esac
  fi

  # --- google-sheet board: the list renders from the LOCAL setup.sheet cache (instant), refreshed
  #     in the background — no jira_search, so no network-first pull. Always read the phase1 sheet
  #     branch (references/google-sheet-board.md); a jira ENV block is irrelevant on this path. ---
  if [ "$SETUP_TYPE" = "google-sheet" ]; then NEXT="read-phase1"; PULL_NOW="no"; fi

  # --- REFRESH: what the background subagent should refresh (off the critical path). The model
  #     spawns ONE bg agent running `init-<mode>.sh --env-refresh` (does env+mcp probe AND a
  #     memory pull) when this is not "none". ---
  local REFRESH="none"
  if [ "$ENV" = "recheck" ] || [ "$MCPSETUP" = "recheck" ]; then REFRESH="env"; fi
  if [ "$MEMORY" = "stale" ]; then
    [ "$REFRESH" = "none" ] && REFRESH="memory" || REFRESH="$REFRESH,memory"
  fi

  # --- output (mode-gated) ---
  printf 'INIT-STATUS\n'
  printf 'MODE=%s\n'          "$MODE"
  printf 'ENV=%s\n'           "$ENV"
  printf 'MCP_SETUP=%s\n'     "$MCPSETUP"
  printf 'SETUP=%s\n'         "$SETUP_STATE"
  [ -n "$REMOTE_SETUP" ] && printf 'REMOTE_SETUP=%s\n' "$REMOTE_SETUP"
  printf 'MEMORY=%s\n'        "$MEMORY"
  printf 'MEMORY_REPO=%s\n'   "$MEMREPO"
  printf 'MEMORY_CLONE=%s\n'  "$MEMCLONE"
  printf 'BASEBRANCH=%s\n'    "${BASEBRANCH:-none}"
  [ -n "$BASEBRANCH_SUGGEST" ] && printf 'BASEBRANCH_SUGGEST=%s\n' "$BASEBRANCH_SUGGEST"
  # Build command + APK location per project (setup.json buildCmd/apkGlob); defaults = references/constants.md.
  printf 'BUILD_CMD=%s\n'     "${BUILDCMD:-./gradlew assembleAppDevDebug}"
  # default = a guess that may not exist in this project -> Phase 4 runs build-task-check.sh before building.
  printf 'BUILD_CMD_SOURCE=%s\n' "$([ -n "$BUILDCMD" ] && echo setup || echo default)"
  printf 'APK_GLOB=%s\n'      "${APKGLOB:-app/build/outputs/apk/**/debug/*.apk}"
  printf 'AUTO_SCOPE=%s\n'    "${AUTOSCOPE:-ui-only}"   # --auto fix scope (references/constants.md AUTO_SCOPE)
  # device repro: --auto turns it on by default (A/B 28/10: without it --auto deferred 6/6 at the 90 bar,
  # with it fixed 6/6); interactive stays off unless --repro / NL intent. --no-repro opts out.
  if [ "$REPRO" = on ]; then printf 'REPRO_ON=true REPRO_SOURCE=flag\n'
  elif [ "$REPRO" = off ]; then printf 'REPRO_ON=false REPRO_SOURCE=no-repro-flag\n'
  elif [ "$AUTO" = 1 ]; then printf 'REPRO_ON=true REPRO_SOURCE=auto-default\n'
  else printf 'REPRO_ON=false REPRO_SOURCE=default\n'; fi
  # claude -p (cron/CI) sets CLAUDE_CODE_ENTRYPOINT=sdk-*: no human wakes the session, and background agents are
  # stopped ~10 min after the turn ends -> the main session must wait for its agents in the same turn (SKILL.md).
  case "${CLAUDE_CODE_ENTRYPOINT:-}" in sdk-*) printf 'HEADLESS=1\n' ;; *) printf 'HEADLESS=0\n' ;; esac
  printf 'SETUP_TYPE=%s\n'    "$SETUP_TYPE"
  if [ "$SETUP_TYPE" = "google-sheet" ]; then
    [ -n "$SHEET_ARG" ] && printf 'SHEET_URL=%s\n' "$SHEET_ARG"
    [ -n "$SHEET_CSV" ] && printf 'SHEET_CSV=%s\n' "$SHEET_CSV"
    printf 'SHEET_CACHE=%s\n' "$SHEET_CACHE"
  fi
  printf 'NEXT=%s\n'          "$NEXT"
  printf 'PULL_NOW=%s\n'      "$PULL_NOW"
  printf 'REFRESH=%s\n'       "$REFRESH"
  if [ "$MODE" = "multi" ] || [ "$MODE" = "team" ]; then
    printf 'BOARD=%s\n'       "$BOARD"
    printf 'PULLQUERY=%s\n'   "$PULLQUERY"
    # Emit the resolved JQL + the list-step fields inline so the model fires jira_search directly
    # — no separate Read of setup.json. List needs only key/priority/summary/status/assignee;
    # descriptions are re-fetched per-ticket at fix time (smaller pull payload).
    [ "$PULLQUERY" = "cached" ] && printf 'PULLQUERY_JQL=%s\n' "$JQL"
    printf 'PULLQUERY_FIELDS=priority,summary,status,assignee\n'
    printf 'TEAM=%s\n'        "$TEAM"
  fi
  if [ "$MODE" = "team" ]; then
    # Hint only — true substrate detection (TeamCreate / Agent-tool) is via ToolSearch, not this script.
    [ "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-}" = "1" ] && printf 'TEAM_FLAG=set\n' || printf 'TEAM_FLAG=unset\n'
  fi
  printf 'PENDING_WATCH=%s\n' "$PWATCH"
  printf 'PENDING_BATCH=%s\n' "$PBATCH"
  return 0
}
