#!/usr/bin/env bash
# build-task-check.sh — does BUILD_CMD's Gradle task exist in THIS project?
#
# The default (references/constants.md DEFAULT_BUILD_CMD) assumes an `app` flavor dimension; a project
# with only `dev`/`prod` flavors does not have that task (AAP857: the task is assembleDevDebug).
# Run once before the first build when init printed BUILD_CMD_SOURCE=default, then save the answer
# with setup-json.sh so the next run never guesses again.
#
# Usage:   build-task-check.sh <project-root> "<BUILD_CMD>"
# Output:  BUILD_TASK=ok TASK=<t>
#          BUILD_TASK=missing TASK=<t> CANDIDATES=<a,b,…>   (assemble*Debug tasks the project does have)
#          BUILD_TASK=unknown REASON=<why>                    (no gradlew / gradle itself failed)
set -euo pipefail

ROOT="${1:-}"; CMDLINE="${2:-}"
[ -d "$ROOT" ] && [ -n "$CMDLINE" ] || { echo "usage: build-task-check.sh <project-root> \"<BUILD_CMD>\""; exit 2; }
[ -x "$ROOT/gradlew" ] || { echo "BUILD_TASK=unknown REASON=no executable gradlew in $ROOT"; exit 0; }

# The task = first word after gradlew that is not an option.
TASK="$(printf '%s\n' "$CMDLINE" | tr ' ' '\n' | awk 'f && $0 !~ /^-/ && NF {print; exit} /gradlew$/ {f=1}')"
[ -n "$TASK" ] || { echo "BUILD_TASK=unknown REASON=no task in '$CMDLINE'"; exit 0; }

LIST="$(cd "$ROOT" && ./gradlew -q tasks --all 2>/dev/null)" || { echo "BUILD_TASK=unknown REASON=gradlew tasks failed"; exit 0; }
NAMES="$(printf '%s\n' "$LIST" | awk '{print $1}' | grep -E '^[A-Za-z0-9_:.-]+$' || true)"
SHORT="${TASK#:}"
if printf '%s\n' "$NAMES" | grep -qxF "$SHORT" || printf '%s\n' "$NAMES" | grep -qE "(^|:)${SHORT##*:}\$"; then
  echo "BUILD_TASK=ok TASK=$TASK"
else
  CAND="$(printf '%s\n' "$NAMES" | grep -E '(^|:)assemble[A-Za-z0-9]*Debug$' | sed 's/^.*://' | awk '!s[$0]++' | paste -sd, -)"
  echo "BUILD_TASK=missing TASK=$TASK CANDIDATES=${CAND:-none}"
fi
