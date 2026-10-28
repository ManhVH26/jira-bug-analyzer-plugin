#!/usr/bin/env bash
# section.sh <file> "<anchor>" — print ONE section of a reference file, never the whole file.
#
# The A/B runs measured the main session reading 125–183k characters of reference files per ticket, mostly
# whole phase files (phase3 alone is ~39 KB) — all of it stays in context and is paid again every turn.
# Phase files now keep only their checklist + a section index; the text lives in references/details/ and is
# read one section at a time with this script.
#
#   anchor = text of a heading (`## Gate 2`, `### Resolve-comment template`) or of a bold step label
#            (`Fix-5.5`, `Step 2`), case-insensitive, matched as a prefix after the markup.
# Output: the section, from its anchor line to the next anchor of the same or a higher level.
#         SECTION_ERROR=no anchor … (exit 1) with the file's anchors listed when nothing matches.
set -euo pipefail
FILE="${1:?usage: section.sh <file> <anchor>}"; WANT="${2:?anchor}"
[ -f "$FILE" ] || { echo "SECTION_ERROR=no such file $FILE"; exit 1; }
python3 - "$FILE" "$WANT" <<'PY'
import re, sys
path, want = sys.argv[1], sys.argv[2].strip().lower()
lines = open(path, encoding="utf-8").read().split("\n")

def anchor(line):
    """(level, label) for a heading or a bold step label; None otherwise. Bold steps rank below ###."""
    m = re.match(r"^(#{1,6})\s+(.*)", line)
    if m:
        return len(m.group(1)), m.group(2)
    m = re.match(r"^\*\*((?:Fix|Step|Gate|Init)-?\s?[\w.]+.*?)\*\*", line)
    if m:
        return 7, m.group(1)
    return None

def clean(label):
    return re.sub(r"[`*_]", "", label).strip().lower()

in_code = False
anchors = []
for i, l in enumerate(lines):
    if l.startswith("```"):
        in_code = not in_code
        continue
    a = None if in_code else anchor(l)
    if a:
        anchors.append((i, a[0], a[1]))

hit = next(((i, lvl) for i, lvl, lab in anchors if clean(lab).startswith(want.lstrip("#").strip())), None) \
    or next(((i, lvl) for i, lvl, lab in anchors if want in clean(lab)), None)
if not hit:
    print(f"SECTION_ERROR=no anchor '{sys.argv[2]}' in {path}. Anchors:")
    for _, lvl, lab in anchors:
        print("  " + ("  " * (min(lvl, 4) - 1)) + clean(lab)[:90])
    sys.exit(1)
start, level = hit
end = next((i for i, lvl, _ in anchors if i > start and lvl <= level), len(lines))
print("\n".join(lines[start:end]).rstrip())
PY
