#!/usr/bin/env bash
# Re-publish the canonical skill into this plugin.
#
# SOURCE OF TRUTH = the TeraKit repo's project-scope skill
# (TeraKit/.claude/skills/jira-bug-analyzer) — it is the git-tracked copy.
# Do NOT sync from ~/.claude/skills: that is an install target, not a source,
# and syncing from it is what silently dropped --discord/device-lock before.
#
#   ./scripts/sync-from-local-skill.sh            # sync + show diff
#   SKILL_SRC=/path/to/skill ./scripts/sync-from-local-skill.sh
#   TERAKIT=/path/to/TeraKit ./scripts/sync-from-local-skill.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
TERAKIT="${TERAKIT:-$HOME/Desktop/src/TeraKit}"
SKILL_SRC="${SKILL_SRC:-$TERAKIT/.claude/skills/jira-bug-analyzer}"
DEST="$REPO_ROOT/plugins/jira-bug-analyzer/skills/jira-bug-analyzer"

if [ ! -f "$SKILL_SRC/SKILL.md" ]; then
  echo "ERROR: source skill not found at $SKILL_SRC (no SKILL.md). Set SKILL_SRC=... or TERAKIT=..." >&2
  exit 1
fi

# Guard: refuse the old ~/.claude source unless explicitly forced. It is the
# install target; publishing from it re-introduces the drift this repo suffered.
case "$SKILL_SRC" in
  "$HOME/.claude/skills/"*)
    if [ "${ALLOW_USER_SCOPE_SRC:-0}" != "1" ]; then
      echo "ERROR: refusing to publish from user scope ($SKILL_SRC)." >&2
      echo "       Use the git-tracked TeraKit copy, or set ALLOW_USER_SCOPE_SRC=1 to override." >&2
      exit 1
    fi ;;
esac

# Guard: the TeraKit copy on GitHub stopped at 2026-08-11 while this repo moved to v1.15.x. A source that
# predates references/constants.md (v1.15.3) is older than this repo; rsync --delete would erase newer work.
if [ -f "$DEST/references/constants.md" ] && [ ! -f "$SKILL_SRC/references/constants.md" ] && [ "${FORCE_OLDER_SRC:-0}" != "1" ]; then
  echo "ERROR: $SKILL_SRC has no references/constants.md — it is older than this plugin (v1.15.3+)." >&2
  echo "       Bring the source up to date first, or set FORCE_OLDER_SRC=1 if you really mean to roll back." >&2
  exit 1
fi

echo "Syncing: $SKILL_SRC  ->  $DEST"
mkdir -p "$DEST"
# --delete so removed files in the source disappear here too. Never touch VCS/OS cruft.
rsync -a --delete --exclude '.DS_Store' "$SKILL_SRC/" "$DEST/"

echo ""
echo "Lint + tests on the synced copy:"
if bash "$REPO_ROOT/tests/run_all.sh"; then echo "All green."; else echo "WARNING: lint/tests failed — fix before committing." >&2; fi

echo ""
echo "Done. Review changes:"
( cd "$REPO_ROOT" && git status --short "plugins/jira-bug-analyzer/skills/jira-bug-analyzer" || true )
echo ""
echo "Next: bump version in plugins/jira-bug-analyzer/.claude-plugin/plugin.json + .claude-plugin/marketplace.json,"
echo "      then: git add -A && git commit -m 'chore: sync skill' && git push"
