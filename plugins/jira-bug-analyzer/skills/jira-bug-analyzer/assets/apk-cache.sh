#!/usr/bin/env bash
# apk-cache.sh — one APK per (repo, commit, build task) on this machine, so the base build that every
# --repro run needs (bug-analysis-rules A4.0) is built once per commit, not once per ticket.
#
#   apk-cache.sh get <repo-root> <commit> <build-task>          -> APK=<path> (exit 0) | APK=miss (exit 1)
#   apk-cache.sh put <repo-root> <commit> <build-task> <apk>    -> APK_CACHED=<path>
#
# A/B: AIP396-461 and -465 both repro'd on base 493fd70f and each built it again (~1 min each).
# Local only (~/.cache): APKs are large and machine-specific; never pushed to the shared memory.
set -euo pipefail
CMD="${1:?usage: apk-cache.sh get|put <repo-root> <commit> <build-task> [apk]}"
ROOT="${2:?repo root}"; COMMIT="${3:?commit}"; TASK="${4:?build task}"
SHA="$(git -C "$ROOT" rev-parse "$COMMIT^{commit}" 2>/dev/null)" || { echo "APK_ERROR=unknown commit $COMMIT"; exit 2; }
REPO="$(basename "$(git -C "$ROOT" rev-parse --show-toplevel)")"
DIR="${JBA_APK_CACHE:-$HOME/.cache/jira-bug-analyzer/apk}/$REPO"
F="$DIR/${SHA:0:12}-${TASK##*:}.apk"
case "$CMD" in
  get) [ -s "$F" ] && { echo "APK=$F"; exit 0; }; echo "APK=miss"; exit 1 ;;
  put) SRC="${5:?apk path}"; [ -s "$SRC" ] || { echo "APK_ERROR=no apk at $SRC"; exit 2; }
       mkdir -p "$DIR"; cp "$SRC" "$F.tmp" && mv "$F.tmp" "$F"
       ls -t "$DIR"/*.apk 2>/dev/null | tail -n +21 | xargs rm -f 2>/dev/null || true   # keep the 20 newest per repo
       echo "APK_CACHED=$F" ;;
  *) echo "APK_ERROR=unknown command $CMD"; exit 2 ;;
esac
