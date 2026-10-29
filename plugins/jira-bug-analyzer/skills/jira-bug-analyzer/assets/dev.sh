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
#   close_ad                 # an ad activity has focus -> Close / BACK until it is gone (nav_to does this on a miss)
#   launch <package>         # start the app's launcher activity
#   tap_id <id> [n]          # tap the node whose resource-id ends with :id/<id> (language-independent)
#   nav_home <setup.json>    # reach the app's home in ONE call: the shared First Open layer, then the app's own
#                            # `navRecipe` from setup.json
#   nav_save <setup.json> '<json array>'   # save the app's own steps after First Open (first run of a project)
#   nav_save_fo '<json array>'             # save / fix this app's First Open steps (in its app map)
#   map_show [setup.json]    # what is already known about this app (assets/app-map.sh: <repo>/.jira-bug/app-map.json)
#   nav_to <screen> [setup.json]           # home (FO + after-FO) then the saved route to <screen>, each hop checked
#   state <name> [setup.json]              # build a saved data state (e.g. saved_video_word) the same way
#   map_save screen|state <name> '<json steps>' '<check>' [from=<screen>] [setup.json]
#                            # save how you got here; refused unless <check> (text:… | id:…) holds on screen NOW
#
# navRecipe steps (strings): "launch <package>", "sleep <s>", "back", "back_if <text>" (BACK only when <text> shows),
# "tap <text>" (must exist), "tap? <text>" (optional), "wait <text>" (fail if it never shows),
# "tap_id <id>", "tap_id? <id>", "back_if_id <id>", "repeat <n> <step>".
#
# First Open layer: every Apero app ships apero-inhouse:first-open, whose screens are the library's own XML
# layouts with the same view ids in every app (4.20.0: buttonLanguageNext on the language picker,
# btnNextOnboarding on the onboarding pages; view_overlay_gradient exists only on the full-screen native ad).
# The steps live in the app's own map (firstOpen); on an app's first run they are seeded from assets/nav/
# (one seed per FO major version, read from gradle/libs.versions.toml) and then kept and fixed per app.
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

DEV_UI_CACHE="${TMPDIR:-/tmp}/jba-ui-$DEV_SERIAL.xml"   # last dump; shot.sh --text reuses it when fresh

# uiautomator dump waits for the screen to go idle, so on animated screens (onboarding, video, shimmer) every
# dump runs into its deadline — A/B AIP396-465 lost 144 s walking onboarding and >120 s on one cropped shot.
# Animations are switched off while this device is driven; device-lock.sh release puts the user's values back.
anim_off() {
  local f="${TMPDIR:-/tmp}/jba-anim-$DEV_SERIAL" k
  [ -f "$f" ] && return 0
  for k in window_animation_scale transition_animation_scale animator_duration_scale; do
    printf '%s=%s\n' "$k" "$(L shell settings get global "$k" 2>/dev/null | tr -d '\r')" >> "$f"
    L shell settings put global "$k" 0 >/dev/null 2>&1
  done
  echo "ANIM=off (restored on device-lock release)"
}

ui() {
  L shell uiautomator dump /sdcard/jba-ui.xml >/dev/null 2>&1
  L exec-out cat /sdcard/jba-ui.xml 2>/dev/null | tee "$DEV_UI_CACHE" | python3 -c '
import re, sys
for n in re.findall(r"<node [^>]*>", sys.stdin.read()):
    t = " ".join(x for x in re.findall(r"(?:text|content-desc)=\"([^\"]*)\"", n) if x)
    b = re.search(r"bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"", n)
    if t and b:
        x1, y1, x2, y2 = map(int, b.groups()); print(f"{t!r} {(x1 + x2) // 2} {(y1 + y2) // 2}")'
}

_nodes() {   # rid<TAB>text<TAB>x<TAB>y for every node of the last dump (refresh it with ui first)
  python3 -c '
import re, sys
for n in re.findall(r"<node [^>]*>", open(sys.argv[1], errors="replace").read()):
    rid = (re.search(r"resource-id=\"([^\"]*)\"", n) or [None, ""])[1]
    t = " ".join(x for x in re.findall(r"(?:text|content-desc)=\"([^\"]*)\"", n) if x)
    b = re.search(r"bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"", n)
    if b and (rid or t):
        x1, y1, x2, y2 = map(int, b.groups()); print(f"{rid}\t{t}\t{(x1 + x2) // 2}\t{(y1 + y2) // 2}")' "$DEV_UI_CACHE" 2>/dev/null
}

has_id() { ui >/dev/null; _nodes | awk -F'\t' -v id="$1" '$1 ~ (":id/" id "$") {f=1} END {exit !f}'; }

tap_id() {
  local id="$1" nth="${2:-1}" xy
  ui >/dev/null
  xy="$(_nodes | awk -F'\t' -v id="$1" -v n="$nth" '$1 ~ (":id/" id "$") {c++; if (c == n) {print $3, $4; exit}}')"
  if [ -z "$xy" ]; then echo "TAP=NOT_FOUND id=$id"; return 1; fi
  L shell input tap $xy && echo "TAP=ok id=$id at $xy"
}

# tap_text scrolls down up to TAP_SCROLL times (default 3) before NOT_FOUND: a label below the fold is not
# "missing from this build" (A/B AAP857-112: "Video AI" sat under the fold of Công cụ, tap_text said NOT_FOUND,
# and the repro agent concluded the build had no such entry — two stops, ~7 min). Optional nav steps pass 0.
_screen_h() {
  [ -n "${DEV_SCREEN_H:-}" ] || DEV_SCREEN_H="$(L shell wm size 2>/dev/null | grep -oE '[0-9]+x[0-9]+' | tail -1 | cut -dx -f2)"
  echo "${DEV_SCREEN_H:-2000}"
}

tap_text() {
  local want="$1" nth="${2:-1}" xy k=0 h
  while :; do
    xy="$(ui | python3 -c '
import sys
want, nth = sys.argv[1].lower(), int(sys.argv[2])
hits = [l.rsplit(" ", 2) for l in sys.stdin if sys.argv[1].lower() in l.lower()]
print(f"{hits[nth - 1][1]} {hits[nth - 1][2]}" if len(hits) >= nth else "")' "$want" "$nth")"
    [ -n "$xy" ] || [ "$k" -ge "${TAP_SCROLL:-3}" ] && break
    k=$((k + 1)); h="$(_screen_h)"
    L shell input swipe 540 $((h * 7 / 10)) 540 $((h * 7 / 20)) 300; sleep 1
  done
  if [ -z "$xy" ]; then echo "TAP=NOT_FOUND text=$want${k:+ scrolled=$k}"; return 1; fi
  L shell input tap $xy && echo "TAP=ok text=$want at $xy$([ "$k" -gt 0 ] && echo " scrolled=$k")"
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

launch() {   # launch <package> | <package>/<activity> (what an analyzer saved in the A/B rerun)
  case "$1" in
    */*) L shell am start -n "$1" >/dev/null 2>&1 ;;
    *)   L shell monkey -p "$1" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 ;;
  esac && echo "LAUNCH=ok $1"
}

_nav_steps() {   # _nav_steps <label> — run steps from stdin; prints NAV=stopped and returns 1 on a required miss
  local label="$1" i=0 step arg n
  while IFS= read -r step; do
    [ -n "$step" ] || continue
    i=$((i + 1)); n=1
    case "$step" in "repeat "*) n="${step#repeat }"; n="${n%% *}"; step="${step#repeat $n }" ;; esac
    while [ "$n" -gt 0 ]; do
      n=$((n - 1)); arg="${step#* }"
      case "$step" in
        "launch "*)     launch "$arg" >/dev/null ;;
        "sleep "*)      sleep "$arg" ;;
        back)           back ;;
        "back_if "*)    ui | grep -qiF -- "$arg" && back ;;
        "back_if_id "*) has_id "$arg" && back ;;
        "tap? "*)       TAP_SCROLL=0 tap_text "${step#"tap? "}" >/dev/null || true ;;
        "tap_id? "*)    tap_id "${step#"tap_id? "}" >/dev/null || true ;;
        "tap_id "*)     tap_id "$arg" >/dev/null || { echo "NAV=stopped layer=$label step=$i ($step)"; return 1; } ;;
        "tap "*)        tap_text "$arg" >/dev/null || { echo "NAV=stopped layer=$label step=$i ($step)"; return 1; } ;;
        "wait "*)       wait_text "$arg" 20 >/dev/null || { echo "NAV=stopped layer=$label step=$i ($step)"; return 1; } ;;
        *)              echo "NAV=bad-step layer=$label step=$i ($step)"; return 1 ;;
      esac
      sleep 1
    done
  done
  echo "$i"
}

fo_major() {   # First Open major version of the project that owns <setup.json>, from the version catalog / gradle files
  local root; root="$(cd "$(dirname "$1")/.." 2>/dev/null && pwd)"
  grep -rhoE '(aperoFirstOpen|firstOpen)[[:space:]]*=[[:space:]]*"[0-9]+|first-open:[0-9]+' \
    "$root/gradle/libs.versions.toml" "$root"/app/build.gradle* "$root"/build.gradle* 2>/dev/null | grep -oE '[0-9]+$' | head -1
}

fo_steps() {   # the app map's First Open steps; first run of an app: seed them from the skill (assets/nav/) into the map
  local setup="$1" major="$2" seed
  if bash "$DEV_ASSETS/app-map.sh" fo "$setup" 2>/dev/null | grep -q .; then
    bash "$DEV_ASSETS/app-map.sh" fo "$setup"; return 0
  fi
  seed="$DEV_ASSETS/nav/first-open-$major.x.json"
  [ -n "$major" ] && [ -f "$seed" ] || return 1
  bash "$DEV_ASSETS/app-map.sh" fo "$setup" "$(python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1]))["steps"]))' "$seed")" "$major.x" >/dev/null
  bash "$DEV_ASSETS/app-map.sh" fo "$setup"
}

nav_home() {
  local setup="$1" major fo n_fo=0 n_app=0 out app_steps
  major="$(fo_major "$setup")"
  app_steps="$( { bash "$DEV_ASSETS/app-map.sh" after-fo "$setup" 2>/dev/null | grep . ||
                   python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print("\n".join(d.get("navRecipe") or []))' "$setup" 2>/dev/null; } )"
  # the app's saved steps start with `launch …`: start the app FIRST, then get past First Open, then the rest
  # (A/B AIP396-465: the FO steps ran on whatever was on screen, the launch after them restarted the app into its
  # onboarding, and the verifier was left to tap through it by hand)
  local n_launch; n_launch="$(printf '%s\n' "$app_steps" | sed -n '/^launch /p' | _nav_steps app 2>/dev/null || echo 0)"
  app_steps="$(printf '%s\n' "$app_steps" | sed '/^launch /d')"
  if fo="$(fo_steps "$setup" "$major")"; then
    out="$(printf '%s\n' "$fo" | _nav_steps "first-open-$major.x")" \
      || { echo "$out (fix it by hand, then nav_save_fo the steps that worked)"; return 1; }
    n_fo="$out"
  fi
  out="$(printf '%s\n' "$app_steps" | _nav_steps app)" || { echo "$out"; return 1; }
  n_app=$((out + n_launch))
  if [ "$n_fo" = 0 ] && [ "$n_app" = 0 ]; then
    echo "NAV=no-recipe FO=${major:-none} (find the way once, then nav_save / nav_save_fo it)"; return 1
  fi
  local label="none" pkg; [ -n "$major" ] && label="$major.x"
  # every step can be optional, so "no step failed" is not "the app is on screen": check the foreground app
  # (A/B rerun AIP396-465: NAV=ok while the phone sat on the launcher — the saved launch step had not started it)
  pkg="$( { bash "$DEV_ASSETS/app-map.sh" app "$setup" 2>/dev/null | sed -n 's/^applicationId=//p'
            bash "$DEV_ASSETS/app-map.sh" after-fo "$setup" 2>/dev/null | sed -n 's/^launch \([^/ ]*\).*/\1/p'; } | head -1)"
  if [ -n "$pkg" ] && ! focus | grep -q "$pkg"; then
    echo "NAV=stopped layer=foreground app=$pkg not on screen after the recipe (launch it: launch $pkg)"; return 1
  fi
  echo "NAV=ok fo=$label fo_steps=$n_fo app_steps=$n_app"
}

nav_save_fo() {   # nav_save_fo '<json array>' [setup.json] — the steps that got past First Open, into this app's map
  local steps="$1" setup="${2:-.jira-bug/setup.json}" major
  major="$(fo_major "$setup")"
  bash "$DEV_ASSETS/app-map.sh" fo "$setup" "$steps" "${major:+$major.x}" >/dev/null && echo "NAV_SAVED_FO=$(bash "$DEV_ASSETS/app-map.sh" path "$setup")"
}

nav_save() {   # nav_save <setup.json> '<json array>' — the app's own steps after First Open, into the app map
  bash "$DEV_ASSETS/app-map.sh" after-fo "$1" "$2" >/dev/null && echo "NAV_SAVED=$(bash "$DEV_ASSETS/app-map.sh" path "$1")"
}

anim_off >&2   # every session that sources dev.sh drives the device: animations off from the first call

check_ok() {   # check_ok text:<visible text> | id:<view id>
  case "$1" in
    text:*) ui | grep -qiF -- "${1#text:}" ;;
    id:*)   has_id "${1#id:}" ;;
    *)      return 1 ;;
  esac
}

map_show() { bash "$DEV_ASSETS/app-map.sh" show "${1:-.jira-bug/setup.json}"; }

nav_to() {   # nav_to <screen|state> [setup.json]
  local want="$1" setup="${2:-.jira-bug/setup.json}" hop=0 steps check out
  out="$(bash "$DEV_ASSETS/app-map.sh" route "$setup" "$want")" || { echo "NAV=unknown screen=$want (reach it by hand, then map_save)"; return 1; }
  local homecheck; homecheck="$(bash "$DEV_ASSETS/app-map.sh" route "$setup" home 2>/dev/null | cut -f2 | head -1)"
  if [ -z "$homecheck" ] || ! check_ok "$homecheck"; then   # not on home (or home never mapped): go there first
    nav_home "$setup" >/dev/null || { echo "NAV=stopped at=home (run nav_home to see where)"; return 1; }
  fi
  while IFS=$'\t' read -r steps check; do
    hop=$((hop + 1))
    python3 -c 'import json,sys;print("\n".join(json.loads(sys.argv[1])))' "$steps" | _nav_steps "$want#$hop" >/dev/null \
      || { close_ad && python3 -c 'import json,sys;print("\n".join(json.loads(sys.argv[1])))' "$steps" | _nav_steps "$want#$hop" >/dev/null; } \
      || { echo "NAV=stopped screen=$want hop=$hop (fix by hand, then map_save)"; return 1; }
    [ -z "$check" ] || check_ok "$check" || { echo "NAV=stopped screen=$want hop=$hop check=$check (fix by hand, then map_save)"; return 1; }
  done <<EOF
$out
EOF
  echo "NAV=ok screen=$want hops=$hop"
}

# An interstitial can open on any screen (A/B AAP857-112: a test ad covered home and nav_to stopped at hop 1).
# close_ad: when an ad activity has focus, tap its Close or press BACK until it is gone; 1 when there was none.
close_ad() {
  local i=0
  focus | grep -q 'AdActivity' || return 1
  while [ "$i" -lt 4 ] && focus | grep -q 'AdActivity'; do
    i=$((i + 1)); TAP_SCROLL=0 tap_text "Close" >/dev/null || back; sleep 2
  done
  focus | grep -q 'AdActivity' && return 1
  echo "AD=closed"
}

state() { nav_to "$@"; }

map_save() {   # map_save screen|state <name> '<json steps>' '<check>' [from=<screen>] [setup.json]
  local kind="$1" name="$2" steps="$3" check="$4" from="from=home" setup=".jira-bug/setup.json"
  shift 4
  for a in "$@"; do case "$a" in from=*) from="$a" ;; *) setup="$a" ;; esac; done
  check_ok "$check" || { echo "MAP_SAVE=refused check=$check does not hold on screen now"; return 1; }
  bash "$DEV_ASSETS/app-map.sh" set "$setup" "$kind" "$name" "$steps" "$check" "$from"
}
