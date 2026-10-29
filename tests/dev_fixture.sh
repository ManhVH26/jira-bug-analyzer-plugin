#!/usr/bin/env bash
# dev_fixture.sh <assets-dir> <tmp-dir> — exercises assets/dev.sh against a stub device lock
set -u
A="$1"; T="$2"; mkdir -p "$T"
printf '%s' '<hierarchy><node text="Tiếp tục" bounds="[340,1261][741,1399]"/><node text="" content-desc="Đóng" bounds="[934,735][979,780]"/></hierarchy>' > "$T/ui.xml"
printf '#!/bin/bash\nshift 4\ncase "$*" in *"cat /sdcard"*) cat %s/ui.xml;; *"input tap"*) echo "$*" >> %s/taps;; esac\n' "$T" "$T" > "$T/lock.sh"
export JBA_DEVICE_LOCK="$T/lock.sh" TMPDIR="$T" HOME="$T"
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
printf '{}' > "$T/setup3.json"; nav_save "$T/setup3.json" '["launch com.x","tap Tiếp tục"]'; python3 -c "import json,sys;print('SAVED', json.load(open(sys.argv[1]))['afterFirstOpen'])" "$T/app-map.json"
# animations: switched off on source (values saved), put back by device-lock.sh release
cat "$T/jba-anim-S" | tr '\n' ' '; echo
mkdir -p "$T/bin"; printf '#!/bin/bash\necho "$*" >> %s/adb.log\n' "$T" > "$T/bin/adb"; chmod +x "$T/bin/adb"
printf 'window_animation_scale=1.0\nanimator_duration_scale=null\n' > "$T/jba-anim-S2"
mkdir -p "$T/h/.claude/jira-bug-analyzer/device-locks"
HOME="$T/h" PATH="$T/bin:$PATH" FORCE=1 bash "$A/device-lock.sh" acquire S2 12345678 60 >/dev/null 2>&1 || true
HOME="$T/h" PATH="$T/bin:$PATH" FORCE=1 bash "$A/device-lock.sh" release S2 12345678
cat "$T/adb.log" 2>/dev/null | tr '\n' ';'; echo
# First Open layer: tap by the library's view id, whatever the app's package and language
mkdir -p "$T/fo/gradle" "$T/fo/.jira-bug"
printf '[versions]\naperoFirstOpen = "4.20.0"\n' > "$T/fo/gradle/libs.versions.toml"
printf '{"navRecipe": ["tap? Khám phá"]}' > "$T/fo/.jira-bug/setup.json"
printf '%s' '<hierarchy><node resource-id="com.some.app:id/buttonLanguageNext" text="Next" bounds="[800,100][1000,200]"/><node resource-id="com.some.app:id/btnNextOnboarding" text="" bounds="[400,2000][680,2100]"/></hierarchy>' > "$T/ui.xml"
: > "$T/taps"; echo "FO_MAJOR=$(fo_major "$T/fo/.jira-bug/setup.json")"; nav_home "$T/fo/.jira-bug/setup.json"; tr '\n' ';' < "$T/taps"; echo
python3 -c "import json,sys;d=json.load(open(sys.argv[1]))['firstOpen'];print('FO_SEEDED', d['version'], len(d['steps']))" "$T/fo/.jira-bug/app-map.json"
nav_save_fo '["tap_id? buttonLanguageNext","repeat 2 tap_id? btnNextOnboarding"]' "$T/fo/.jira-bug/setup.json"
python3 -c "import json,sys;d=json.load(open(sys.argv[1]))['firstOpen'];print('FO_SAVED', d['version'], d['steps'])" "$T/fo/.jira-bug/app-map.json"
# app map: save only when the check holds; nav_to replays home -> screen, checking every hop
mkdir -p "$T/fo2/gradle" "$T/fo2/.jira-bug"; printf '{"project": "P1"}' > "$T/fo2/.jira-bug/setup.json"
printf '%s' '<hierarchy><node text="Trang chủ" bounds="[0,2200][200,2300]"/><node text="Phần thưởng" bounds="[600,2200][800,2300]"/><node text="Nhiệm vụ hằng ngày" bounds="[0,300][500,400]"/></hierarchy>' > "$T/ui.xml"
map_save screen rewards '["tap Phần thưởng"]' 'text:Không có' "$T/fo2/.jira-bug/setup.json"
map_save screen home '[]' 'text:Trang chủ' "$T/fo2/.jira-bug/setup.json"
map_save screen rewards '["tap Phần thưởng"]' 'text:Nhiệm vụ' from=home "$T/fo2/.jira-bug/setup.json"
: > "$T/taps"; nav_to rewards "$T/fo2/.jira-bug/setup.json"; tr '\n' ';' < "$T/taps"; echo
nav_to nowhere "$T/fo2/.jira-bug/setup.json"
map_show "$T/fo2/.jira-bug/setup.json" | tr '\n' ';'; echo
# nav_home must not say ok when the app is not on screen
mkdir -p "$T/fg/.jira-bug"; printf '{"project": "FG"}' > "$T/fg/.jira-bug/setup.json"
bash "$A/app-map.sh" after-fo "$T/fg/.jira-bug/setup.json" '["launch com.fg.app/com.fg.Splash"]' >/dev/null
nav_home "$T/fg/.jira-bug/setup.json"
# the app map lives in the app's own repo, next to setup.json, whatever the shared memory holds
mkdir -p "$T/.claude/jira-bug-memory/project/P1"; echo "MAP_PATH=$(bash "$A/app-map.sh" path "$T/fo2/.jira-bug/setup.json")"; ls "$T/fo2/.jira-bug/app-map.json" >/dev/null && echo "MAP_LOCAL=yes"
