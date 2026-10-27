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

echo "setup-json merge keeps JSON valid"
S="$TMP/s.json"; printf '{\n  "board": "X"\n}\n' > "$S"
bash "$ASSETS/setup-json.sh" merge-set "$S" buildCmd="./gradlew assembleDebug" >/dev/null
if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['buildCmd']=='./gradlew assembleDebug' and d['board']=='X'" "$S"; then ok "merge-set buildCmd"; else bad "merge-set buildCmd"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
