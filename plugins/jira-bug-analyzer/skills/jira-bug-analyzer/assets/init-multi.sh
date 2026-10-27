#!/usr/bin/env bash
# lint: no-strict-mode — init must always print INIT-STATUS and exit 0 (set -u only).
# Multi-mode (solo worker) init entry — pull the board, list bugs by category,
# pick + fix in re-pulling turns. Sources the shared core; emits BOARD/PULLQUERY/TEAM too.
# Behavior table: references/phase1-init-multi-mode-without-team.md
# Usage: bash init-multi.sh [PROJECT_ROOT] [--project <KEY>] [--recheck-env]
set -u
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=init-lib.sh
. "$SELF_DIR/init-lib.sh"
jb_init_run multi "$@"
exit 0
