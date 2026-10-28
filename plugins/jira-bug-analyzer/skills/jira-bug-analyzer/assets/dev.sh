#!/usr/bin/env bash
# dev.sh — device helpers for a verifier/analyzer, every call through the device lock.
#
#   source <skill-dir>/assets/dev.sh <serial> <owner-token>
#   L <adb args>             # adb through device-lock.sh exec (the only way to touch the device)
#   ui                       # print the visible texts with their centers: 'text' x y
#   tap_text "<text>" [n]    # find the node whose text/content-desc contains <text>, tap its center (n-th match, default 1)
#   wait_text "<text>" [s]   # poll the screen until <text> shows (default 15 s); prints FOUND/NOT_FOUND
#   back                     # BACK key
#   focus                    # current focused activity (ad / splash / app screen)
#   launch <package>         # start the app's launcher activity
#   nav_home <setup.json>    # replay the project's saved `navRecipe` (splash/ad/onboarding -> home) in ONE call
#   nav_save <setup.json> '<json array>'   # save the recipe that just worked (first run of a project)
#
# navRecipe steps (strings): "launch <package>", "sleep <s>", "back", "back_if <text>" (BACK only when <text> shows),
# "tap <text>" (must exist), "tap? <text>" (optional), "wait <text>" (fail if it never shows).
# A/B runs: every analyzer and verifier re-learned the same splash -> test ad -> 3 onboarding pages ->
# popup path, ~10 commands each, twice per ticket.
#
# A/B AIP396-465: the verifier spent 2 commands writing its own wrapper (zsh does not word-split a
# "$L exec …" string) and 3 commands per tap (dump, grep bounds, tap). One call per action here.
# lint: no-strict-mode: sourced into the caller's shell; `set -e` would end the caller's session on one failed lookup

DEV_SERIAL="${1:?usage: source dev.sh <serial> <owner-token>}"; DEV_TOKEN="${2:?owner token}"
DEV_ASSETS="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DEV_LOCK="${JBA_DEVICE_LOCK:-$DEV_ASSETS/device-lock.sh}"

# every call has a deadline (default 30 s, DEV_DEADLINE=<s> to change): a hung adb call (uiautomator on a
# playing video, screencap on a sleeping screen) once stalled an A/B analysis for 15 min
L() {
  bash "$DEV_LOCK" exec "$DEV_SERIAL" "$DEV_TOKEN" -- "$@" & local pid=$!
  ( sleep "${DEV_DEADLINE:-30}"; kill -9 "$pid" ) >/dev/null 2>&1 & local guard=$!   # detached from our stdout, so $(…) callers do not wait on the sleep
  wait "$pid" 2>/dev/null; local rc=$?
  kill "$guard" 2>/dev/null; wait "$guard" 2>/dev/null
  [ "$rc" -eq 137 ] && { echo "DEV_TIMEOUT=adb $* (>${DEV_DEADLINE:-30}s) — wake the screen (L shell input keyevent 224) or pause the video" >&2; return 124; }
  return "$rc"
}

ui() {
  L shell uiautomator dump /sdcard/jba-ui.xml >/dev/null 2>&1
  L exec-out cat /sdcard/jba-ui.xml 2>/dev/null | python3 -c '
import re, sys
for n in re.findall(r"<node [^>]*>", sys.stdin.read()):
    t = " ".join(x for x in re.findall(r"(?:text|content-desc)=\"([^\"]*)\"", n) if x)
    b = re.search(r"bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"", n)
    if t and b:
        x1, y1, x2, y2 = map(int, b.groups()); print(f"{t!r} {(x1 + x2) // 2} {(y1 + y2) // 2}")'
}

tap_text() {
  local want="$1" nth="${2:-1}" xy
  xy="$(ui | python3 -c '
import sys
want, nth = sys.argv[1].lower(), int(sys.argv[2])
hits = [l.rsplit(" ", 2) for l in sys.stdin if sys.argv[1].lower() in l.lower()]
print(f"{hits[nth - 1][1]} {hits[nth - 1][2]}" if len(hits) >= nth else "")' "$want" "$nth")"
  if [ -z "$xy" ]; then echo "TAP=NOT_FOUND text=$want"; return 1; fi
  L shell input tap $xy && echo "TAP=ok text=$want at $xy"
}

wait_text() {
  local want="$1" secs="${2:-15}" i=0
  while [ "$i" -lt "$secs" ]; do
    ui | grep -qiF -- "$want" && { echo "FOUND=$want"; return 0; }
    sleep 3; i=$((i + 3))
  done
  echo "NOT_FOUND=$want"; return 1
}

back() { L shell input keyevent 4; }
focus() { L shell dumpsys window | grep -m1 mCurrentFocus; }

launch() { L shell monkey -p "$1" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 && echo "LAUNCH=ok $1"; }

nav_home() {
  local setup="$1" steps i=0 step arg
  steps="$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print("\n".join(d.get("navRecipe") or []))' "$setup" 2>/dev/null)"
  [ -n "$steps" ] || { echo "NAV=no-recipe (find the way once, then nav_save it)"; return 1; }
  while IFS= read -r step; do
    i=$((i + 1)); arg="${step#* }"
    case "$step" in
      "launch "*)  launch "$arg" >/dev/null ;;
      "sleep "*)   sleep "$arg" ;;
      back)        back ;;
      "back_if "*) ui | grep -qiF -- "$arg" && back ;;
      "tap? "*)    arg="${step#"tap? "}"; tap_text "$arg" >/dev/null || true ;;
      "tap "*)     tap_text "$arg" >/dev/null || { echo "NAV=stopped step=$i ($step)"; return 1; } ;;
      "wait "*)    wait_text "$arg" 20 >/dev/null || { echo "NAV=stopped step=$i ($step)"; return 1; } ;;
      *)           echo "NAV=bad-step step=$i ($step)"; return 1 ;;
    esac
  done <<EOF
$steps
EOF
  echo "NAV=ok steps=$i"
}

nav_save() {
  bash "$DEV_ASSETS/setup-json.sh" merge-set "$1" "navRecipe=$2" >/dev/null && echo "NAV_SAVED=$1"
}
