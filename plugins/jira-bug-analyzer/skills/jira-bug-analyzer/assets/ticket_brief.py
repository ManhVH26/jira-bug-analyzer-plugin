#!/usr/bin/env python3
"""ticket_brief.py — read whatever the tester wrote in a ticket into the bug-report fields the run uses.

The QA template (Spec / Figma / Build / Thiết bị / Trạng thái / Mô tả bug / Tái hiện / Thực tế / Expect) is a
help, never a gate: testers write it partly, out of order, without headings, in Vietnamese or English. This reads
what it can and names the rest MISSING; for a missing field the run works exactly as it did before the template
(media + title + app map + spec + code). A missing or messy field is never a reason to defer or to ask.

The A/B tickets carried 23–84 characters each (a screenshot link and a few words) and all six were fixed — that
is the floor this must keep.

Usage:
  ticket_brief.py <text-file | text>      # the ticket description + comments (same dump fetch-media-links.sh reads)
Output, one line each (values on one line, " / " between lines):
  BRIEF=<n>/9  MISSING=<field,...|->
  SPEC=  FIGMA=  FIGMA_NODE=<id|page|->  BUILD=  DEVICE=  STATE=  BUG=  ACTUAL=  EXPECT=  FREQ=
  STEPS=<n> (STEPS_FROM=heading|numbered|arrows|-)  then STEP<i>=<text>
"""
import os
import re
import sys
import unicodedata

FIELDS = ["spec", "figma", "build", "device", "state", "bug", "steps", "actual", "expect"]
ALIASES = {  # matched on the heading with accents removed, lower case
    "spec": ["spec", "tai lieu", "confluence", "prd", "srs", "yeu cau"],
    "figma": ["figma", "design", "thiet ke", "ui design"],
    "build": ["build", "version", "phien ban", "ban build", "app version"],
    "device": ["thiet bi", "device", "may test", "may", "os", "android"],
    "state": ["trang thai", "dieu kien", "tien dieu kien", "precondition", "pre-condition", "tai khoan", "account",
              "du lieu", "data"],
    "bug": ["mo ta bug", "mo ta loi", "mo ta", "description", "bug", "van de", "loi"],
    "steps": ["tai hien bug", "tai hien", "cac buoc tai hien", "cac buoc", "buoc tai hien", "steps to reproduce",
              "steps", "repro", "str", "how to reproduce"],
    "freq": ["tan suat", "frequency", "ty le", "ti le", "rate"],
    "actual": ["thuc te", "ket qua thuc te", "actual result", "actual", "hien tai", "hien trang"],
    "expect": ["expect sau khi fix", "expect sau fix", "expected result", "expected", "expect", "ket qua mong doi",
               "mong doi", "mong muon", "ky vong", "ki vong", "sau khi fix", "sau fix"],
}
URL = re.compile(r"(?:https?)://[^\s\]\[|<>\"'{}]+")
STEP_MARK = re.compile(r"^\s*(?:[-*#•]+\s*)?(?:(?:b(?:uoc)?|step)\s*\d+\s*[:.)\-]?|\d+\s*[.):\-])\s*", re.I)
BULLET = re.compile(r"^\s*(?:[-*#•]+|\d+\s*[.)])\s+")
ARROW = re.compile(r"\s*(?:->|=>|→|>>|>)\s*")


def plain(s):
    s = unicodedata.normalize("NFD", s)
    s = "".join(c for c in s if unicodedata.category(c) != "Mn").replace("đ", "d").replace("Đ", "D")
    return s.lower()


def strip_markup(line):
    line = re.sub(r"^\s*h\d\.\s*", "", line)          # Jira wiki heading
    line = re.sub(r"\{color[^}]*\}", "", line)
    return line.replace("*", "").replace("_", " ").strip() if not URL.search(line) else re.sub(r"\*", "", line).strip()


def heading(line):
    """(field, rest) when the line starts a template field, else None."""
    body = strip_markup(line)
    head = re.sub(r"^[\s\-#>•]+", "", body)
    p = plain(head)
    for field, names in ALIASES.items():
        for n in sorted(names, key=len, reverse=True):
            m = re.match(rf"{re.escape(n)}\b[^:：\n]{{0,25}}?[:：]\s*(.*)$", p)
            if m:
                return field, head[len(head) - len(m.group(1)):].strip() if m.group(1) else ""
            if p.rstrip(" :：") == n:                    # a heading on its own line
                return field, ""
    return None


def split_steps(lines):
    items, cur = [], None
    for ln in lines:
        s = strip_markup(ln)
        if not s:
            continue
        m = STEP_MARK.match(plain(s)) or BULLET.match(plain(s))   # plain() keeps the length of NFC text
        if m:
            if cur:
                items.append(cur)
            cur = s[m.end():].strip()
        elif cur is not None:
            cur += " " + s
        else:
            cur = s
    if cur:
        items.append(cur)
    if len(items) == 1 and ARROW.search(items[0]):
        items = [x for x in ARROW.split(items[0]) if x.strip()]
    return [i.strip(" .") for i in items if i.strip(" .")]


def parse(text):
    lines = text.splitlines()
    got, order, cur = {}, [], None
    for ln in lines:
        h = heading(ln)
        if h:
            cur = h[0]
            got.setdefault(cur, [])
            if h[1]:
                got[cur].append(h[1])
            order.append(cur)
        elif cur:
            got[cur].append(ln)
        else:
            got.setdefault("_free", []).append(ln)
    out = {}
    for f in FIELDS + ["freq"]:
        if f == "steps":
            continue
        val = " / ".join(strip_markup(x) for x in got.get(f, []) if strip_markup(x))
        out[f] = val
    steps, src = [], "-"
    if got.get("steps"):
        steps, src = split_steps(got["steps"]), "heading"
    else:
        free = got.get("_free", [])
        numbered = [x for x in free if STEP_MARK.match(plain(strip_markup(x)))]
        if len(numbered) >= 2:
            steps, src = split_steps(numbered), "numbered"
        else:
            arrows = [URL.sub("", strip_markup(x)).strip(" []") for x in free]
            arrows = [x for x in arrows if ARROW.search(x)]
            if arrows:
                steps, src = [x.strip(" ,.") for x in ARROW.split(arrows[0]) if x.strip(" ,.")], "arrows"
    urls = URL.findall(text)
    sources = [u for u in urls if "figma.com" in u or re.search(r"confluence|/wiki/|viewpage|/display/", u)]
    # no headings at all: the tester's own words are the bug description, the media links show what they saw
    if not out["bug"]:
        words = " / ".join(x for x in (re.sub(r"\[\s*\]", "", URL.sub("", re.sub(r"![^!\s]+!", "", strip_markup(l)))).strip(" |")
                                       for l in got.get("_free", [])) if x)
        out["bug"] = words
    if not out["actual"]:   # what QA saw: the media links, and images embedded the Jira way (!shot.png|width=..!)
        embeds = re.findall(r"!([^!|\s]+\.(?:png|jpe?g|gif|webp|mp4|mov))(?:\|[^!]*)?!", text, re.I)
        out["actual"] = " ".join([u for u in urls if u not in sources] + embeds)
    if not out["spec"]:
        out["spec"] = next((u for u in urls if re.search(r"confluence|/wiki/|viewpage|/display/", u)), "")
    fig = out["figma"] if URL.search(out["figma"] or "") else next((u for u in urls if "figma.com" in u), out["figma"])
    out["figma"] = fig or ""
    node = "-"
    if "figma.com" in out["figma"]:
        m = re.search(r"node-id=([0-9]+)(?:-|:|%3A)([0-9]+)", out["figma"])
        node = f"{m.group(1)}:{m.group(2)}" if m else "page"
    if not out["freq"]:
        p = plain(text)
        out["freq"] = ("luon luon" if re.search(r"\bluon\b|always|100 ?%", p) else
                       "thinh thoang" if re.search(r"thinh thoang|sometimes|random|luc duoc luc khong", p) else "")
    present = [f for f in FIELDS if (steps if f == "steps" else out.get(f))]
    return out, steps, src, node, present


def main():
    arg = sys.argv[1] if len(sys.argv) > 1 else ""
    if not arg:
        print("usage: ticket_brief.py <text-file | text>")
        return 2
    text = open(arg, encoding="utf-8", errors="replace").read() if os.path.isfile(arg) else arg
    text = unicodedata.normalize("NFC", text)
    out, steps, src, node, present = parse(text)
    missing = [f for f in FIELDS if f not in present]
    print(f"BRIEF={len(present)}/{len(FIELDS)} MISSING={','.join(missing) or '-'}")
    for f in ["spec", "figma"]:
        print(f"{f.upper()}={out[f] or '-'}")
    print(f"FIGMA_NODE={node}")
    for f in ["build", "device", "state", "bug", "actual", "expect", "freq"]:
        print(f"{f.upper()}={out[f] or '-'}")
    print(f"STEPS={len(steps)} STEPS_FROM={src}")
    for i, s in enumerate(steps, 1):
        print(f"STEP{i}={s}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
