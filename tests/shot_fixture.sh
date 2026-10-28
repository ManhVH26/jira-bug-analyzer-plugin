#!/usr/bin/env bash
# shot_fixture.sh <assets-dir> <tmp-dir> — runs assets/shot.sh three times against a stub device lock
set -u
A="$1"; T="$2"; mkdir -p "$T"
python3 - "$T" <<'PY'
import struct, sys, zlib
d = sys.argv[1]
def png(w, h):
    raw = b"".join(b"\x00" + b"\x80\x40\x20" * w for _ in range(h))
    c = lambda t, b: struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + c(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + c(b"IDAT", zlib.compress(raw)) + c(b"IEND", b"")
open(d + "/full.png", "wb").write(png(1080, 2400))
open(d + "/ui.xml", "w").write('<hierarchy><node text="Chỉ cần mang khoảnh khắc" bounds="[100,1500][980,1620]"/></hierarchy>')
PY
printf '#!/bin/bash\nshift 4\ncase "$*" in *screencap*) cat %s/full.png;; *"cat /sdcard"*) cat %s/ui.xml;; esac\n' "$T" "$T" > "$T/lock.sh"
for args in "" "--text mang" "--text nope"; do JBA_DEVICE_LOCK="$T/lock.sh" bash "$A/shot.sh" S TOK "$T/x.png" $args; done
