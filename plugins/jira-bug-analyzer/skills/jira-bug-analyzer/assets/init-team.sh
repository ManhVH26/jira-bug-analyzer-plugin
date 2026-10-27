#!/usr/bin/env bash
# lint: no-strict-mode — init must always print INIT-STATUS and exit 0 (set -u only).
# Team-mode (launcher) init entry — this session becomes MainCharacter and stands
# up the jira-bugfix Agent Team. Sources the shared core; emits BOARD/PULLQUERY/TEAM
# plus TEAM_FLAG (a hint for the CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS env flag; the
# real substrate check is via ToolSearch for TeamCreate / Agent-tool).
# Behavior table: references/phase1-init-multi-mode-with-team.md
# Usage: bash init-team.sh [PROJECT_ROOT] [--project <KEY>] [--recheck-env]
set -u
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=init-lib.sh
. "$SELF_DIR/init-lib.sh"
jb_init_run team "$@"
exit 0
