#!/usr/bin/env bash
# lint: no-strict-mode — init must always print INIT-STATUS and exit 0 (set -u only).
# Single-mode init entry — fix ONE ticket by key. Sources the shared core and
# emits a single-tailored INIT-STATUS (no BOARD/PULLQUERY/TEAM — single doesn't pull).
# Behavior table: references/phase1-init-single-mode.md
# Usage: bash init-single.sh [PROJECT_ROOT] [--project <KEY>] [--recheck-env]
set -u
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=init-lib.sh
. "$SELF_DIR/init-lib.sh"
jb_init_run single "$@"
exit 0
