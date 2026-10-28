#!/usr/bin/env bash
# lint: no-strict-mode — exit codes ARE the API (3 = BUSY/NOTOWNER); -e would abort before the code is returned.
# device-lock.sh — serialize adb device access across jira-bug-analyzer sessions/projects.
#
# Why a script (not prose): every shell call from the agent is a SEPARATE process, so a
# pid-keyed lock dies between calls and looks "stale" instantly. This locks on a stable
# OWNER TOKEN (pass the Claude session id) + a TTL, so the claim survives across the many
# adb commands of one verify, and a crashed session self-heals after the TTL.
#
# Usage:
#   device-lock.sh acquire <serial> <owner-token> [ttl_sec]   # claim (or refresh if you already hold it)
#   device-lock.sh exec <serial> <owner-token> -- <adb args>  # ONLY sanctioned way to touch a device
#   device-lock.sh install <serial> <owner-token> <apk> [ttl] # acquire-then-install -r -d (keeps the lock held)
#   device-lock.sh release <serial> <owner-token>             # release (only if you own it, or FORCE=1)
#   device-lock.sh status  <serial>                           # FREE | LOCKED | STALE + owner
#   device-lock.sh list                                       # every current lock
#   device-lock.sh free-serial <owner-token> [ttl]           # print first UNLOCKED adb serial (and claim it)
#
# Exit: 0 ok · 3 busy/not-owner · 2 usage/bad-token.  (macOS bash 3.2 compatible — no same-line local back-refs)
set -uo pipefail

LOCKROOT="${HOME}/.claude/jira-bug-analyzer/device-locks"
mkdir -p "$LOCKROOT"
now() { date +%s; }
field() { sed -n "s/^$2=//p" "$1/owner" 2>/dev/null | head -1; }

# The owner token MUST be the raw Claude session id — the SAME string for every call of one
# session (every phase, every ticket, every subagent). A per-role/per-ticket variant
# ("<sid>-analyzer-319") makes your own session BUSY against itself, which is what trains a
# bare-adb bypass and lets a second terminal drive a device this session owns. Reject it here.
check_token() {
  local t="${1:-}"
  case "$t" in
    ""|unknown|*"<"*|*">"*|*" "*) ;;
    *) if printf '%s' "$t" | grep -qE '^[0-9a-fA-F]{8}[0-9a-fA-F-]*$'; then return 0; fi ;;
  esac
  echo "BADTOKEN '$t' — owner token must be the raw Claude session id (uuid or its first 8 hex chars)," >&2
  echo "  IDENTICAL across every phase/ticket/subagent of this session. Do NOT append a role or ticket" >&2
  echo "  (no '-analyzer-319'): that self-collides and defeats the lock. Two terminals = two session ids." >&2
  exit 2
}

dir_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

is_stale() {            # 0 = stale (age >= ttl)
  local lock="$1"
  local at; at=$(field "$lock" at)
  local ttl; ttl=$(field "$lock" ttl)
  [ -z "$ttl" ] && ttl=1800
  if [ -z "$at" ]; then
    # No parseable owner record. Two cases, and calling both "stale" corrupts the lock:
    #   (a) a peer created the dir microseconds ago and hasn't written `owner` yet → NOT stale
    #       (reclaiming it would delete a live lock and hand the device to two sessions);
    #   (b) a legacy/corrupt lock (e.g. the old pid= format) → stale after a short grace.
    # Fall back to the dir's mtime with a 60s grace to tell them apart.
    at=$(dir_mtime "$lock"); ttl=60
    [ -z "$at" ] && return 0
  fi
  [ $(( $(now) - at )) -ge "$ttl" ]
}

write_owner() {         # write_owner <lock> <token> <ttl>
  printf 'owner=%s\nproject=%s\nat=%s\nttl=%s\n' \
    "$2" "$(basename "$PWD")" "$(now)" "$3" > "$1/owner"
}

acquire() {             # acquire <serial> <token> [ttl]
  local serial="$1"
  local token="${2:-unknown}"
  local ttl="${3:-1800}"
  local lock="$LOCKROOT/$serial.lock"
  if mkdir "$lock" 2>/dev/null; then
    write_owner "$lock" "$token" "$ttl"; echo "ACQUIRED $serial"; return 0
  fi
  local cur; cur=$(field "$lock" owner)
  if [ "$cur" = "$token" ]; then            # we already hold it → refresh TTL
    write_owner "$lock" "$token" "$ttl"; echo "ACQUIRED $serial (refresh)"; return 0
  fi
  if is_stale "$lock"; then                  # holder timed out / crashed → reclaim
    # Serialize the reclaim: without this, two sessions both see STALE, both rm -rf, and the
    # second one deletes the FRESH lock the first just took — leaving both convinced they own
    # the device. The meta-lock makes check-and-replace atomic; re-verify staleness inside it.
    local meta="$LOCKROOT/.reclaim.lock"
    if mkdir "$meta" 2>/dev/null; then
      if is_stale "$lock"; then
        rm -rf "$lock"
        if mkdir "$lock" 2>/dev/null; then
          write_owner "$lock" "$token" "$ttl"; rmdir "$meta"
          echo "ACQUIRED $serial (stale-reclaim)"; return 0
        fi
      fi
      rmdir "$meta"
    fi
    # meta-lock held by a peer, or the lock got re-taken under us → treat as busy, re-read owner.
    cur=$(field "$lock" owner)
  fi
  echo "BUSY $serial held-by=$cur since=$(field "$lock" at) project=$(field "$lock" project)"; return 3
}

# exec — the ONLY sanctioned way to touch a device. Asserts ownership, refreshes the TTL
# (so a long drive can never look "stale" to a peer), then runs adb against the owned serial.
# A bare `adb -s <serial> …` bypasses all of this and is the bug this gate exists to prevent.
dexec() {               # dexec <serial> <token> -- <adb args...>
  local serial="$1" token="$2"; shift 2
  [ "${1:-}" = "--" ] && shift
  local lock="$LOCKROOT/$serial.lock"
  local cur; cur=$(field "$lock" owner)
  if [ ! -d "$lock" ]; then
    echo "NOLOCK $serial — acquire it first; never drive an unlocked device." >&2; return 3
  fi
  if [ "$cur" != "$token" ]; then
    echo "NOTOWNER $serial held-by=$cur project=$(field "$lock" project) — another session owns this device." >&2
    echo "  Do NOT run adb against it. Pick a free serial (free-serial) or wait for release." >&2
    return 3
  fi
  write_owner "$lock" "$token" "$(field "$lock" ttl)"   # heartbeat: every adb call refreshes the claim
  adb -s "$serial" "$@"
}

release() {             # release <serial> <token>
  local serial="$1"
  local token="${2:-}"
  local lock="$LOCKROOT/$serial.lock"
  [ -d "$lock" ] || { echo "FREE $serial"; return 0; }
  local cur; cur=$(field "$lock" owner)
  if [ "${FORCE:-0}" = "1" ] || [ "$cur" = "$token" ] || is_stale "$lock"; then
    local anim="${TMPDIR:-/tmp}/jba-anim-$serial" k v   # dev.sh switched animations off: put the user's values back
    if [ -f "$anim" ]; then
      while IFS='=' read -r k v; do
        case "$v" in ''|null) adb -s "$serial" shell settings delete global "$k" >/dev/null 2>&1 ;;
                     *) adb -s "$serial" shell settings put global "$k" "$v" >/dev/null 2>&1 ;; esac
      done < "$anim"
      rm -f "$anim"; echo "ANIM=restored $serial"
    fi
    rm -rf "$lock"; echo "RELEASED $serial"; return 0
  fi
  echo "NOTOWNER $serial held-by=$cur (use FORCE=1 to override)"; return 3
}

status() {              # status <serial>
  local serial="$1"
  local lock="$LOCKROOT/$serial.lock"
  if [ -d "$lock" ]; then
    if is_stale "$lock"; then
      echo "STALE $serial held-by=$(field "$lock" owner) project=$(field "$lock" project)"
    else
      echo "LOCKED $serial held-by=$(field "$lock" owner) project=$(field "$lock" project) since=$(field "$lock" at)"
    fi
  else
    echo "FREE $serial"
  fi
}

install() {             # install <serial> <token> <apk> [ttl] — acquire then install, keep lock held
  local serial="$1"
  local token="${2:-unknown}"
  local apk="$3"
  local ttl="${4:-1800}"
  acquire "$serial" "$token" "$ttl" || return 3
  # bounded: on a phone an install can wait forever on a device-side prompt (install-over-USB confirm,
  # Play Protect scan). A/B rerun AAP857-113: one install on the phone ran >300 s. Timed out -> say so; the
  # caller releases this serial and takes the next one (free-serial), or asks the dev to tap the prompt.
  local secs="${INSTALL_DEADLINE:-120}" out; out="$(mktemp)"
  adb -s "$serial" install -r -d "$apk" > "$out" 2>&1 & local pid=$!
  ( sleep "$secs"; kill -9 "$pid" ) >/dev/null 2>&1 & local guard=$!
  wait "$pid" 2>/dev/null; local rc=$?
  kill "$guard" 2>/dev/null; wait "$guard" 2>/dev/null
  cat "$out"; rm -f "$out"
  if [ "$rc" -eq 137 ]; then
    echo "INSTALL_TIMEOUT $serial after ${secs}s — the device may be showing an install / Play Protect prompt; release it and use another serial"
    return 4
  fi
  [ "$rc" -eq 0 ] || return "$rc"
}

free_serial() {         # free-serial <token> [ttl] — claim + print the first unlocked connected serial
  local token="${1:-unknown}"
  local ttl="${2:-1800}"
  local s
  for s in $(adb devices | awk 'NR>1 && $2=="device"{print $1}'); do
    if acquire "$s" "$token" "$ttl" >/dev/null 2>&1; then echo "$s"; return 0; fi
  done
  echo ""; return 3
}

cmd="${1:-}"
case "$cmd" in
  acquire)     check_token "${3:?token}"; acquire "${2:?serial}" "$3" "${4:-1800}";;
  exec)        check_token "${3:?token}"; XS="${2:?serial}"; XT="$3"; shift 3; dexec "$XS" "$XT" "$@";;
  release)     release "${2:?serial}" "${3:-}";;
  status)      status  "${2:?serial}";;
  install)     check_token "${3:?token}"; install "${2:?serial}" "$3" "${4:?apk}" "${5:-1800}";;
  free-serial) check_token "${2:?token}"; free_serial "$2" "${3:-1800}";;
  list)        shopt -s nullglob; for d in "$LOCKROOT"/*.lock; do status "$(basename "${d%.lock}")"; done;;
  *) echo "usage: device-lock.sh {acquire|exec|release|status|install|free-serial|list} <serial> <owner-token> [-- adb args|apk|ttl]"; exit 2;;
esac
