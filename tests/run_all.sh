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
LG upsert P ph P-1 status=pr-created pr=u >/dev/null; LG upsert P ph P-2 status=analyzed >/dev/null
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
check "every write reached the remote" "ledger Q-2 delete" "$(git --git-dir="$TMP/mem.git" log --oneline -1)"

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
