#!/usr/bin/env bash
# shot.sh — one screenshot = one call: capture through the device lock, crop to the bug, shrink, save.
#
# The A/B run (AAP857-113) read 39 screenshots where the old skill read 17: full-size PNGs, then
# hand-made `sips` crops retried until the region looked right. Every image read stays in the
# context and is paid again on every later turn, so the verifier reads ONLY files made here.
#
# Usage:
#   shot.sh <serial> <owner-token> <out.png> [--text "<visible text>"] [--pad 120] [--width 720]
#     --text  = crop to the on-screen node whose text/content-desc contains this (uiautomator bounds),
#               plus --pad px around it; not found -> full screen, CROP=not-found
#     --width = width cap after the crop (default 540 for a full screen, 720 for a --text crop):
#               a 540x1200 portrait costs ~860 image tokens, the raw 1080x2400 ~1.6k, on every later turn
# Output: SHOT=<out.png> W=<w> H=<h> KB=<size> CROP=<text|none|not-found>   (exit 1 + SHOT_ERROR= on failure)
set -uo pipefail   # lint: no-strict-mode: an optional crop/shrink tool may be missing; each step reports SHOT_ERROR/SHOT_WARN itself

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERIAL="${1:-}"; TOKEN="${2:-}"; OUT="${3:-}"
[ -n "$SERIAL" ] && [ -n "$TOKEN" ] && [ -n "$OUT" ] || { echo "usage: shot.sh <serial> <owner-token> <out.png> [--text <t>] [--pad 120] [--width 720]"; exit 2; }
shift 3
TEXT=""; PAD=120; WIDTH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --text) TEXT="$2"; shift 2 ;;
    --pad) PAD="$2"; shift 2 ;;
    --width) WIDTH="$2"; shift 2 ;;
    *) echo "SHOT_ERROR=unknown option $1"; exit 2 ;;
  esac
done
LOCK="${JBA_DEVICE_LOCK:-$SELF_DIR/device-lock.sh}"   # override only in tests
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$(dirname "$OUT")"

# every device step has a deadline: in the A/B run (AIP396-475) one `exec-out screencap` hung 15 min and
# stalled the whole analysis. A hung step is killed and retried once the slow way (screencap on the device + pull).
deadline() {  # deadline <secs> <cmd...> — run, kill after <secs>; exit 124 on timeout (macOS has no `timeout`)
  local secs="$1"; shift
  "$@" & local pid=$!
  ( sleep "$secs"; kill -9 "$pid" ) >/dev/null 2>&1 & local guard=$!   # detached from our stdout, so $(…) callers do not wait on the sleep
  wait "$pid" 2>/dev/null; local rc=$?
  kill "$guard" 2>/dev/null; wait "$guard" 2>/dev/null
  [ "$rc" -eq 137 ] && return 124 || return "$rc"
}
grab() { bash "$LOCK" exec "$SERIAL" "$TOKEN" -- exec-out screencap -p > "$TMP/full.png" 2>"$TMP/err"; }
grab_pull() {
  bash "$LOCK" exec "$SERIAL" "$TOKEN" -- shell screencap -p /sdcard/jba-shot.png >/dev/null 2>"$TMP/err" &&
  bash "$LOCK" exec "$SERIAL" "$TOKEN" -- pull /sdcard/jba-shot.png "$TMP/full.png" >/dev/null 2>>"$TMP/err"
}
if ! { deadline "${SHOT_DEADLINE:-25}" grab && [ -s "$TMP/full.png" ]; }; then
  rm -f "$TMP/full.png"
  deadline "$(( ${SHOT_DEADLINE:-25} * 8 / 5 ))" grab_pull && [ -s "$TMP/full.png" ] \
    || { echo "SHOT_ERROR=screencap timed out or failed twice (device asleep/locked? wake it: L shell input keyevent 224): $(head -c 160 "$TMP/err")"; exit 1; }
fi

CROP="none"; GEOM=""
if [ -n "$TEXT" ]; then
  # uiautomator dump never returns on a screen that keeps animating (video playback) -> bounded
  deadline 15 bash "$LOCK" exec "$SERIAL" "$TOKEN" -- shell uiautomator dump /sdcard/jba-ui.xml >/dev/null 2>&1
  deadline 10 bash "$LOCK" exec "$SERIAL" "$TOKEN" -- exec-out cat /sdcard/jba-ui.xml > "$TMP/ui.xml" 2>/dev/null
  GEOM="$(python3 - "$TMP/ui.xml" "$TEXT" "$PAD" "$TMP/full.png" <<'PY'
import re, struct, sys
xml, want, pad = open(sys.argv[1], errors="replace").read(), sys.argv[2].lower(), int(sys.argv[3])
fw, fh = struct.unpack(">II", open(sys.argv[4], "rb").read()[16:24])
for m in re.finditer(r'<node [^>]*>', xml):
    n = m.group(0)
    t = " ".join(re.findall(r'(?:text|content-desc)="([^"]*)"', n)).lower()
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n)
    if want in t and b:
        x1, y1, x2, y2 = map(int, b.groups())
        x1, y1, x2, y2 = max(0, x1 - pad), max(0, y1 - pad), min(fw, x2 + pad), min(fh, y2 + pad)
        print(f"{x2 - x1}:{y2 - y1}:{x1}:{y1}"); break
PY
)"
  CROP="${GEOM:+$TEXT}"; CROP="${CROP:-not-found}"
fi

[ -n "$WIDTH" ] || { [ -n "$GEOM" ] && WIDTH=720 || WIDTH=540; }
if command -v ffmpeg >/dev/null 2>&1; then
  VF="scale='min($WIDTH,iw)':-2"
  [ -n "$GEOM" ] && VF="crop=$GEOM,${VF}"
  ffmpeg -loglevel error -y -i "$TMP/full.png" -vf "$VF" "$OUT" 2>"$TMP/err" \
    || { [ -n "$GEOM" ] && ffmpeg -loglevel error -y -i "$TMP/full.png" -vf "scale='min($WIDTH,iw)':-2" "$OUT" 2>>"$TMP/err" && CROP="crop-failed"; } \
    || { echo "SHOT_ERROR=ffmpeg: $(head -c 200 "$TMP/err")"; exit 1; }
elif command -v sips >/dev/null 2>&1; then
  cp "$TMP/full.png" "$OUT"
  if [ -n "$GEOM" ]; then
    IFS=: read -r CW CH CX CY <<EOF
$GEOM
EOF
    sips -c "$CH" "$CW" --cropOffset "$CY" "$CX" "$OUT" >/dev/null 2>&1 || CROP="crop-failed"
  fi
  W0="$(sips -g pixelWidth "$OUT" 2>/dev/null | awk '/pixelWidth/{print $2}')"
  [ "${W0:-0}" -gt "$WIDTH" ] && sips --resampleWidth "$WIDTH" "$OUT" >/dev/null 2>&1
else
  cp "$TMP/full.png" "$OUT"; echo "SHOT_WARN=no ffmpeg/sips — saved full size"
fi

python3 - "$OUT" "$CROP" <<'PY'
import os, struct, sys
p, crop = sys.argv[1], sys.argv[2]
w, h = struct.unpack(">II", open(p, "rb").read()[16:24])
print(f"SHOT={p} W={w} H={h} KB={os.path.getsize(p) // 1024} CROP={crop}")
PY
