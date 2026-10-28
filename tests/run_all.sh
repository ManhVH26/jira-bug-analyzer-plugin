#!/usr/bin/env bash
# Runs every deterministic test of the plugin: lint, python unit tests, shell-script behavior tests.
# Usage: bash tests/run_all.sh        (CI runs the same command)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS="$REPO/plugins/jira-bug-analyzer/skills/jira-bug-analyzer/assets"
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() { # check <name> <expected-substring> <actual>
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (expected '$2', got: $(printf '%s' "$3" | head -c 300))" ;; esac
}
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "lint"
if python3 "$REPO/scripts/lint_skill.py" >/dev/null; then ok "lint_skill.py clean"; else bad "lint_skill.py reports errors (run it for details)"; fi

echo "lint catches drift"
cp -R "$REPO/plugins" "$REPO/scripts" "$REPO/.claude-plugin" "$TMP/" && mkdir -p "$TMP/drift" && mv "$TMP/plugins" "$TMP/scripts" "$TMP/.claude-plugin" "$TMP/drift/"
echo "Auto-approve when the sum is ≥ 80." >> "$TMP/drift/plugins/jira-bug-analyzer/skills/jira-bug-analyzer/references/phase3-analyze.md"
echo "See references/helpers/does-not-exist.md." >> "$TMP/drift/plugins/jira-bug-analyzer/skills/jira-bug-analyzer/references/phase4-fix-and-build.md"
out="$(python3 "$TMP/drift/scripts/lint_skill.py" --root "$TMP/drift" 2>&1 || true)"
check "copied threshold is an error" "constant-copy" "$out"
check "broken reference is an error" "ref-broken" "$out"

echo "python unit tests"
if python3 -m unittest discover -s "$REPO/tests" -p 'test_*.py' >/dev/null 2>&1; then ok "unittest"; else bad "unittest (run: python3 -m unittest discover -s tests)"; fi

echo "init prints BUILD_CMD / APK_GLOB / AUTO_SCOPE"
P="$TMP/proj"; mkdir -p "$P/.jira-bug"
out="$(HOME="$TMP/home" bash "$ASSETS/init-single.sh" "$P" 2>&1)"
check "default build command" "BUILD_CMD=./gradlew assembleAppDevDebug" "$out"
check "default auto scope" "AUTO_SCOPE=ui-only" "$out"
printf '{\n  "board": "AAP729",\n  "buildCmd": "./gradlew :app:assembleProdDebug",\n  "autoScope": "all"\n}\n' > "$P/.jira-bug/setup.json"
out="$(HOME="$TMP/home" bash "$ASSETS/init-single.sh" "$P" --project AAP729 2>&1)"
check "build command from setup.json" "BUILD_CMD=./gradlew :app:assembleProdDebug" "$out"
check "auto scope from setup.json" "AUTO_SCOPE=all" "$out"
out="$(CLAUDE_CODE_ENTRYPOINT=sdk-cli HOME="$TMP/home" bash "$ASSETS/init-single.sh" "$P" 2>&1)"
check "claude -p is headless" "HEADLESS=1" "$out"
out="$(CLAUDE_CODE_ENTRYPOINT=cli HOME="$TMP/home" bash "$ASSETS/init-single.sh" "$P" 2>&1)"
check "interactive is not headless" "HEADLESS=0" "$out"
check "interactive run: no device repro by default" "REPRO_ON=false REPRO_SOURCE=default" "$out"
check "--auto turns device repro on" "REPRO_ON=true REPRO_SOURCE=auto-default" "$(HOME="$TMP/home" bash "$ASSETS/init-single.sh" "$P" --auto 2>&1)"
check "--auto --no-repro turns it off" "REPRO_ON=false REPRO_SOURCE=no-repro-flag" "$(HOME="$TMP/home" bash "$ASSETS/init-single.sh" "$P" --auto --no-repro 2>&1)"
check "--repro alone turns it on" "REPRO_ON=true REPRO_SOURCE=flag" "$(HOME="$TMP/home" bash "$ASSETS/init-single.sh" "$P" --repro 2>&1)"

echo "manager precheck"
M="$TMP/mgr"; mkdir -p "$M/.jira-bug/discord-inbox"
check "first fire runs a full pass" "FULL_DUE=yes" "$(bash "$ASSETS/manager-precheck.sh" "$M" AAP729)"
check "second fire with no change is quiet" "LOCAL=quiet" "$(bash "$ASSETS/manager-precheck.sh" "$M" AAP729)"
touch "$M/.jira-bug/discord-inbox/1.json"
check "a new inbox file is a change" "LOCAL=changed" "$(bash "$ASSETS/manager-precheck.sh" "$M" AAP729)"
for _ in 4 5; do bash "$ASSETS/manager-precheck.sh" "$M" AAP729 >/dev/null; done   # fires 4-5; the next is fire 6
check "a full pass is forced every 6 fires" "FULL_DUE=yes" "$(bash "$ASSETS/manager-precheck.sh" "$M" AAP729)"

echo "setup-mcp figma command per platform"
H="$TMP/mcp"; mkdir -p "$H"
HOME="$H" MSYSTEM= bash "$ASSETS/setup-mcp.sh" figma >/dev/null 2>&1
check "mac/linux uses npx directly" '"command": "npx"' "$(cat "$H/.claude.json")"
HOME="$H" MSYSTEM=MINGW64 bash "$ASSETS/setup-mcp.sh" figma --force >/dev/null 2>&1
check "git-bash wraps npx in cmd /c" '"command": "cmd"' "$(cat "$H/.claude.json")"

echo "missing mcp-atlassian is reported"
HB="$TMP/mcpbin"; mkdir -p "$HB"
out="$(HOME="$HB" PATH="/usr/bin:/bin" JIRA_PERSONAL_TOKEN=dummy bash "$ASSETS/setup-mcp.sh" jira 2>&1)"
check "setup-mcp names the missing executable" "MISSING_BIN=mcp-atlassian" "$out"
out="$(HOME="$HB" PATH="/usr/bin:/bin" bash "$ASSETS/preflight-env.sh" --now-only "$TMP" 2>&1)"
check "preflight blocks on the missing executable" "DEP=jira-mcp-bin TIER=now STATUS=missing" "$out"

echo "preflight flags TOOLSETS that block every jira tool"
TH="$TMP/tsh"; mkdir -p "$TH"; printf '{"mcpServers":{"jira":{"command":"sh","env":{"TOOLSETS":"jira,confluence"}}}}' > "$TH/.claude.json"
check "old toolset names are reported" "DEP=jira-mcp-toolsets TIER=now STATUS=missing" "$(HOME="$TH" bash "$ASSETS/preflight-env.sh" --now-only "$TMP" 2>&1)"
printf '{"mcpServers":{"jira":{"command":"sh","env":{"TOOLSETS":"all"}}}}' > "$TH/.claude.json"
case "$(HOME="$TH" bash "$ASSETS/preflight-env.sh" --now-only "$TMP" 2>&1)" in *jira-mcp-toolsets*) bad "TOOLSETS=all passes" ;; *) ok "TOOLSETS=all passes" ;; esac

echo "ledger.sh — the only writer of record_bug_status.md"
LH="$TMP/lhome"; git init -q --bare "$TMP/mem.git"; git clone -q "$TMP/mem.git" "$LH/.claude/jira-bug-memory" 2>/dev/null
LC="$LH/.claude/jira-bug-memory"; git -C "$LC" config user.email t@t; git -C "$LC" config user.name t
mkdir -p "$LC/project/P/ph/session" "$LC/project/Q/ph/session" "$LC/project/R/ph/session"
printf '# P\n\n## P-1\n- status: analyzed\n- dev: a\n' > "$LC/project/P/ph/session/record_bug_status.md"
printf '| ticket | dev | status | summary |\n|---|---|---|---|\n| Q-1 | a | done | x \\| y |\n| Q-2 | b | done | z |\n' > "$LC/project/Q/ph/session/record_bug_status.md"
printf 'free notes\n' > "$LC/project/R/ph/session/record_bug_status.md"
git -C "$LC" add -A && git -C "$LC" commit -qm init && git -C "$LC" push -q origin HEAD 2>/dev/null
LG() { HOME="$LH" bash "$ASSETS/ledger.sh" "$@"; }
check "new file: creates the canonical table and pushes" "LEDGER_COMMIT=" "$(LG upsert N ph N-1 status=analyzed dev=me 'summary=a | b')"
check "new file: pipe in a value is escaped" '| N-1 | analyzed |  | me | a \| b |' "$(cat "$LC/project/N/ph/session/record_bug_status.md")"
WR="$TMP/wrepo"; git init -q "$WR"; git -C "$WR" commit -q --allow-empty -m init -c user.email=t@t -c user.name=t 2>/dev/null || git -C "$WR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
NOGH="$TMP/nogh"; mkdir -p "$NOGH"; printf '#!/bin/sh\nexit 1\n' > "$NOGH/gh"; chmod +x "$NOGH/gh"   # offline: no GitHub lookups
LGW() { HOME="$LH" PATH="$NOGH:$PATH" bash "$ASSETS/ledger.sh" "$@"; }
LGW_OUT="$(LGW upsert P ph P-1 status=pr-created pr=https://github.com/o/r/pull/7 --root "$WR")"; LG upsert P ph P-2 status=analyzed >/dev/null
out="$(cat "$LC/project/P/ph/session/record_bug_status.md")"
check "sections: updates the ticket's block" "- status: pr-created" "$out"
check "sections: adds a new ticket block, keeps the old one" "## P-2" "$out"
check "sections: other fields kept" "- dev: a" "$out"
LG upsert Q ph Q-1 status=reopened reopen_reason=missed-case >/dev/null
out="$(cat "$LC/project/Q/ph/session/record_bug_status.md")"
check "table: new column appended, row updated" "| Q-1 | a | reopened | x \\| y | missed-case |" "$out"
check "table: other rows untouched (only empty cells added)" "| Q-2 | b | done | z | | |" "$out"
check "get prints the row" "LEDGER_ROW=| Q-1" "$(LG get Q ph Q-1)"
LG delete Q ph Q-2 >/dev/null
case "$(cat "$LC/project/Q/ph/session/record_bug_status.md")" in *Q-2*) bad "delete removes the row" ;; *) ok "delete removes the row" ;; esac
out="$(LG upsert R ph R-1 status=analyzed 2>&1 || true)"
check "unreadable file is never overwritten" "LEDGER_ERROR=unrecognised" "$out"
check "unreadable file left as it was" "free notes" "$(cat "$LC/project/R/ph/session/record_bug_status.md")"
check "pr-created also puts the PR on the watch list" "PR_WATCH=added #7" "$LGW_OUT"
check "watch entry carries the ticket" '"key": "P-1"' "$(cat "$WR/.jira-bug/pr-watch.json")"
check "watch file is git-excluded" ".jira-bug/" "$(cat "$WR/.git/info/exclude")"
out="$(LGW upsert N ph N-9 status=pr-created pr=https://github.com/o/r/pull/7 --root "$WR")"
check "pr-created with no earlier analyzing row is flagged" "LEDGER_WARN=N-9" "$out"
check "a batch PR gains the second ticket" "PR_WATCH=updated #7" "$out"
git -C "$WR" worktree add -q "$TMP/wt1" -b wt1 2>/dev/null
check "from a worktree the entry lands in the main checkout" "wrepo/.jira-bug/pr-watch.json" "$(PATH="$NOGH:$PATH" bash "$ASSETS/pr-watch.sh" add "$TMP/wt1" https://github.com/o/r/pull/8 N-10)"
check "drop removes an entry" "PR_WATCH=dropped #8" "$(bash "$ASSETS/pr-watch.sh" drop "$WR" 8)"
check "every write reached the remote" "ledger N-9 pr-created" "$(git --git-dir="$TMP/mem.git" log --oneline -1)"

echo "build-task-check.sh — the build task must exist in this project"
BT="$TMP/bt"; mkdir -p "$BT"
printf '#!/bin/sh\nprintf "Build tasks\\n-----------\\napp:assembleDevDebug - Assembles DevDebug\\napp:assembleProdDebug - x\\napp:assembleDevRelease - x\\n"\n' > "$BT/gradlew"; chmod +x "$BT/gradlew"
check "an existing task is ok" "BUILD_TASK=ok" "$(bash "$ASSETS/build-task-check.sh" "$BT" "./gradlew assembleDevDebug")"
out="$(bash "$ASSETS/build-task-check.sh" "$BT" "./gradlew assembleAppDevDebug")"
check "a missing task is reported with candidates" "BUILD_TASK=missing TASK=assembleAppDevDebug CANDIDATES=assembleDevDebug,assembleProdDebug SUGGEST=assembleDevDebug" "$out"
check "no gradlew is unknown, not a failure" "BUILD_TASK=unknown" "$(bash "$ASSETS/build-task-check.sh" "$TMP" "./gradlew x")"
check "init says where BUILD_CMD came from" "BUILD_CMD_SOURCE=default" "$(HOME="$TMP/home" bash "$ASSETS/init-single.sh" "$TMP/bt" 2>&1)"

echo "jira.sh — Phase 6 Jira writes as one command (local mock of Jira Server)"
JM="$TMP/jm"; mkdir -p "$JM/ev"; python3 "$REPO/tests/jira_mock.py" "$JM/port" "$JM/log" & JPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$JM/port" ] && break; sleep 0.3; done
printf '\x89PNG\r\n\x1a\nfake' > "$JM/ev/verify-after.png"; printf 'x' > "$JM/ev/notes.txt"
printf '**Đã sửa:** icon của chip dùng `ic_tool_video`.\n' > "$JM/body.txt"
JENV() { HOME="$TMP/jhome" JIRA_URL="http://127.0.0.1:$(cat "$JM/port")" JIRA_PERSONAL_TOKEN=t "$@"; }
out="$(JENV bash "$ASSETS/jira.sh" finalize T-1 "$JM/body.txt" "$JM/ev" --pr https://github.com/o/r/pull/5 2>&1 || true)"
check "finalize attaches only repro/verify media" "JIRA_ATTACHED=1/1" "$out"
check "finalize embeds the evidence in the comment" "EMBED=ok" "$out"
check "finalize moves the ticket to Resolved" "JIRA_STATUS=Resolved" "$out"
check "finalize logs work" "JIRA_WORKLOG=91 TIME=30m" "$out"
check "finalize reports success only when every step landed" "FINALIZE=ok" "$out"
log="$(cat "$JM/log")"
check "markdown bold becomes wiki bold" '*\\u0110\\u00e3 s\\u1eeda:*' "$log"
check "markdown code becomes wiki monospace" "{{ic_tool_video}}" "$log"
case "$log" in *"attachments"*"/comment "*) ok "attach happens before the comment" ;; *) bad "attach happens before the comment" ;; esac
check "claim reports status and assignee" "JIRA_STATUS=In Progress JIRA_ASSIGNEE=dev1" "$(JENV bash "$ASSETS/jira.sh" claim T-1 2>&1 || true)"
printf '\x89PNG\r\n\x1a\nfake' > "$JM/ev/repro-before.png"
out="$(JENV bash "$ASSETS/jira.sh" evidence T-1 "$JM/body.txt" "$JM/ev" 2>&1 || true)"
check "evidence attaches only repro-* media" "JIRA_ATTACHED=1/1" "$out"
check "evidence embeds it and says ok" "EVIDENCE=ok" "$out"
out="$(JENV bash "$ASSETS/jira.sh" finalize T-1 "$JM/body.txt" "$JM/ev" --pr https://github.com/o/r/pull/5 --labels auto-fixed,auto-fix-behavioral --auto-eval pending 2>&1 || true)"
check "finalize merges labels and reads them back" "JIRA_LABELS=old,auto-fixed,auto-fix-behavioral" "$out"
check "finalize posts the AUTO-FIX EVAL line" "JIRA_AUTO_EVAL=ok" "$out"
kill "$JPID" 2>/dev/null; wait "$JPID" 2>/dev/null || true

echo "shot.sh — one screenshot = capture through the lock + crop to text + shrink"
bash "$REPO/tests/shot_fixture.sh" "$ASSETS" "$TMP/shot" > "$TMP/shot.out" 2>&1
check "full screen is shrunk to 540 wide" "W=540 H=1200" "$(sed -n 1p "$TMP/shot.out")"
check "--text crops to that node" "CROP=mang" "$(sed -n 2p "$TMP/shot.out")"
check "missing text falls back to full screen and says so" "CROP=not-found" "$(sed -n 3p "$TMP/shot.out")"

echo "dev.sh — one call per device action (tap by text, wait for text)"
bash "$REPO/tests/dev_fixture.sh" "$ASSETS" "$TMP/dev" > "$TMP/dev.out" 2>&1 || true   # the fixture ends on an expected failure
check "tap_text taps the center of the matching node" "TAP=ok text=tiếp tục at 540 1330" "$(cat "$TMP/dev.out")"
check "tap_text matches content-desc too" "TAP=ok text=Đóng at 956 757" "$(cat "$TMP/dev.out")"
check "tap_text says when the text is absent" "TAP=NOT_FOUND text=nope" "$(cat "$TMP/dev.out")"
check "wait_text finds visible text" "FOUND=Tiếp" "$(cat "$TMP/dev.out")"
check "nav_home replays the saved recipe" "NAV=ok fo=none fo_steps=0 app_steps=5" "$(cat "$TMP/dev.out")"
check "nav_home taps through the recipe" "shell input tap 540 1330" "$(sed -n '/NAV=ok/,$p' "$TMP/dev.out")"
check "a missing required step stops nav_home" "NAV=stopped layer=app step=1 (tap Không có)" "$(cat "$TMP/dev.out")"
check "nav_save writes the app's after-FO steps to the app map" "SAVED ['launch com.x', 'tap Tiếp tục']" "$(cat "$TMP/dev.out")"
check "dev.sh switches animations off and saves the old values" "window_animation_scale=" "$(cat "$TMP/dev.out")"
check "device-lock release puts the user's animation values back" "settings put global window_animation_scale 1.0" "$(cat "$TMP/dev.out")"
check "an unset animation value is deleted again, not set to null" "settings delete global animator_duration_scale" "$(cat "$TMP/dev.out")"
check "the First Open version comes from the version catalog" "FO_MAJOR=4" "$(cat "$TMP/dev.out")"
check "nav_home runs the shared First Open layer, then the app's own" "NAV=ok fo=4.x fo_steps=6 app_steps=1" "$(cat "$TMP/dev.out")"
check "First Open buttons are tapped by view id (language picker, then onboarding)" "shell input tap 900 150;shell input tap 540 2050;" "$(cat "$TMP/dev.out")"
check "nav_save_fo writes the shared First Open recipe for that major version" "FO_SAVED apero-inhouse:first-open 4.* ['tap_id? buttonLanguageNext', 'repeat 2 tap_id? btnNextOnboarding']" "$(cat "$TMP/dev.out")"
check "map_save refuses a route whose check does not hold on screen" "MAP_SAVE=refused check=text:Không có" "$(cat "$TMP/dev.out")"
check "map_save keeps a route whose check holds" "MAP_SAVED=screen:rewards" "$(cat "$TMP/dev.out")"
check "nav_to replays the saved route and checks it" "NAV=ok screen=rewards hops=2" "$(cat "$TMP/dev.out")"
check "nav_to taps the saved steps" "shell input tap 700 2250;" "$(sed -n '/NAV=ok screen=rewards/,$p' "$TMP/dev.out")"
check "nav_to says when a screen was never mapped" "NAV=unknown screen=nowhere" "$(cat "$TMP/dev.out")"
check "map_show lists what is known" "SCREEN rewards from=home check=text:Nhiệm vụ steps=1" "$(cat "$TMP/dev.out")"
check "nav_home refuses NAV=ok when the app is not in the foreground" "NAV=stopped layer=foreground app=com.fg.app" "$(cat "$TMP/dev.out")"
check "a hung adb call is cut off" "DEV_TIMEOUT=adb shell true" "$(cat "$TMP/dev.out")"
check "a hung screencap ends with SHOT_ERROR, not a hang" "SHOT_ERROR=screencap timed out" "$(cat "$TMP/dev.out")"

echo "section.sh — one section of a reference file, never the whole file"
SEC="$TMP/sec.md"; printf '# T\n\n## A\na1\n**Fix-1 — one** x\nf1\n**Fix-2 — two** y\nf2\n## B\nb1\n' > "$SEC"
check "a heading prints up to the next heading of its level" "$(printf '## A\na1\n**Fix-1 — one** x\nf1\n**Fix-2 — two** y\nf2')" "$(bash "$ASSETS/section.sh" "$SEC" "A")"
out="$(bash "$ASSETS/section.sh" "$SEC" "Fix-1")"
case "$out" in *"f1"*) case "$out" in *"f2"*) bad "a step label stops at the next step";; *) ok "a step label stops at the next step";; esac;; *) bad "a step label stops at the next step";; esac
check "an unknown anchor lists the anchors" "SECTION_ERROR=no anchor" "$(bash "$ASSETS/section.sh" "$SEC" "zzz" || true)"

echo "apk-cache.sh — one base APK per (repo, commit, task)"
AC="$TMP/ac"; mkdir -p "$AC/repo" && git -C "$AC/repo" init -q && git -C "$AC/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
printf 'apk' > "$AC/x.apk"
check "a commit never built is a miss" "APK=miss" "$(JBA_APK_CACHE="$AC/c" bash "$ASSETS/apk-cache.sh" get "$AC/repo" HEAD assembleDevDebug || true)"
check "put stores it" "APK_CACHED=" "$(JBA_APK_CACHE="$AC/c" bash "$ASSETS/apk-cache.sh" put "$AC/repo" HEAD :app:assembleDevDebug "$AC/x.apk")"
check "the same commit and task is a hit" "APK=$AC/c/repo/" "$(JBA_APK_CACHE="$AC/c" bash "$ASSETS/apk-cache.sh" get "$AC/repo" HEAD assembleDevDebug)"

echo "fetch-media-links.sh — screenshot share links become files (offline, file:// fixtures)"
FM="$TMP/fml"; mkdir -p "$FM/site"
python3 - "$FM/site/shot.png" <<'PY'
import struct, sys, zlib
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(b"\x00\xff\x00\x00")) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
PY
printf '<html><head><meta content="file://%s/site/shot.png" property="og:image"></head></html>' "$FM" > "$FM/site/prnt.sc-AAA.html"
printf '<html><head><title>deleted</title></head></html>' > "$FM/site/prnt.sc-GONE.html"
printf 'not an image' > "$FM/site/fake.png"
printf 'Lỗi chữ, xem file://%s/site/prnt.sc-AAA.html, ảnh trực tiếp file://%s/site/shot.png.\nLink hỏng file://%s/site/prnt.sc-GONE.html\nGiả file://%s/site/fake.png\nKhông phải media https://example.com/docs\n' "$FM" "$FM" "$FM" "$FM" > "$FM/ticket.txt"
out="$(bash "$ASSETS/fetch-media-links.sh" list "$FM/ticket.txt")"
check "list finds share pages and direct media" "prnt.sc-AAA.html" "$out"
case "$out" in *example.com*) bad "list ignores non-media links" ;; *) ok "list ignores non-media links" ;; esac
out="$(bash "$ASSETS/fetch-media-links.sh" fetch "$FM/ticket.txt" "$FM/out")"
check "share page resolved through og:image to a PNG" "SOURCE=file://$FM/site/prnt.sc-AAA.html" "$out"
check "page without og:image is reported, not dropped" "REASON=no og:image" "$out"
check "a non-image behind a .png URL is rejected" "REASON=not an image/video" "$out"
check "saved files are real PNGs" "PNG image data" "$(file "$FM/out/"link-*.png | head -1)"

echo "setup-json merge keeps JSON valid"
S="$TMP/s.json"; printf '{\n  "board": "X"\n}\n' > "$S"
bash "$ASSETS/setup-json.sh" merge-set "$S" buildCmd="./gradlew assembleDebug" >/dev/null
if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['buildCmd']=='./gradlew assembleDebug' and d['board']=='X'" "$S"; then ok "merge-set buildCmd"; else bad "merge-set buildCmd"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
