#!/usr/bin/env bash
# dev_fixture.sh <assets-dir> <tmp-dir> — exercises assets/dev.sh against a stub device lock
set -u
A="$1"; T="$2"; mkdir -p "$T"
printf '%s' '<hierarchy><node text="Tiếp tục" bounds="[340,1261][741,1399]"/><node text="" content-desc="Đóng" bounds="[934,735][979,780]"/></hierarchy>' > "$T/ui.xml"
printf '#!/bin/bash\nshift 4\ncase "$*" in *"cat /sdcard"*) cat %s/ui.xml;; *"input tap"*) echo "$*" >> %s/taps;; esac\n' "$T" "$T" > "$T/lock.sh"
export JBA_DEVICE_LOCK="$T/lock.sh"
. "$A/dev.sh" S TOK
tap_text "tiếp tục"; tap_text "Đóng"; tap_text "nope"; wait_text "Tiếp" 3
cat "$T/taps"
# a hung adb call is cut off by the deadline
printf '#!/bin/bash\nsleep 20\n' > "$T/hang.sh"
OLD="$DEV_LOCK"; DEV_LOCK="$T/hang.sh"; DEV_DEADLINE=1 L shell true 2>&1; echo "RC=$?"; DEV_LOCK="$OLD"
JBA_DEVICE_LOCK="$T/hang.sh" SHOT_DEADLINE=1 bash "$A/shot.sh" S TOK "$T/h.png"; echo "SHOT_RC=$?"
# nav_home replays a saved recipe; a required step that is missing stops it
printf '{"navRecipe": ["launch com.x", "tap? Không có", "back_if Đóng", "tap Tiếp tục", "wait Tiếp"]}' > "$T/setup.json"
: > "$T/taps"; nav_home "$T/setup.json"; cat "$T/taps"
printf '{"navRecipe": ["tap Không có"]}' > "$T/setup2.json"; nav_home "$T/setup2.json"
printf '{}' > "$T/setup3.json"; nav_save "$T/setup3.json" '["launch com.x","tap Tiếp tục"]'; python3 -c "import json,sys;print('SAVED', json.load(open(sys.argv[1]))['navRecipe'])" "$T/setup3.json"
