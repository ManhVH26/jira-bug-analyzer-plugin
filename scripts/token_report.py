#!/usr/bin/env python3
"""Token spend of jira-bug-analyzer runs, by model, from local Claude Code transcripts (Phase 7 metric).

Counts every assistant message attributed to the skill, plus every message of the subagents those
sessions spawned (analyzer, fixer, verifier, memory-keeper...). Run it on the machine that ran the
skill, before and after a change, over the same kind of work.

Usage:
  python3 scripts/token_report.py                       # all time
  python3 scripts/token_report.py --since 2026-10-28    # only runs on/after a date
  python3 scripts/token_report.py --skill learn-app     # any other skill, same report
  python3 scripts/token_report.py --json
"""
import argparse, glob, json, os
from collections import defaultdict

FIELDS = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")


def iter_messages(path):
    seen = set()
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("type") != "assistant":
                continue
            m = d.get("message") or {}
            key = m.get("id") or d.get("requestId") or d.get("uuid")
            if key in seen or "usage" not in m:  # one API response can be logged once per content block
                continue
            seen.add(key)
            yield d, m


def report(root, skill, since):
    by_model = defaultdict(lambda: defaultdict(int))
    sessions = 0
    for main in glob.glob(os.path.join(root, "*", "*.jsonl")):
        hit = False
        rows = list(iter_messages(main))
        for d, _ in rows:
            if skill in (d.get("attributionSkill") or "") and (not since or d.get("timestamp", "") >= since):
                hit = True
                break
        if not hit:
            continue
        sessions += 1
        files = [(main, True)] + [(p, False) for p in glob.glob(os.path.join(main[:-6], "subagents", "*.jsonl"))]
        for path, is_main in files:
            for d, m in (rows if is_main else iter_messages(path)):
                if since and d.get("timestamp", "") < since:
                    continue
                if is_main and skill not in (d.get("attributionSkill") or ""):
                    continue
                u = m["usage"]
                b = by_model[m.get("model", "unknown")]
                for k in FIELDS:
                    b[k] += int(u.get(k) or 0)
                b["messages"] += 1
                b["from_subagents"] += 0 if is_main else 1
    return sessions, by_model


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--skill", default="jira-bug-analyzer")
    ap.add_argument("--since", help="YYYY-MM-DD")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    sessions, by_model = report(a.root, a.skill, a.since)
    if a.json:
        print(json.dumps({"skill": a.skill, "since": a.since, "sessions": sessions, "by_model": by_model}, indent=2))
        return
    print(f"Token report — skill '{a.skill}'" + (f" since {a.since}" if a.since else "") + f" — {sessions} session(s)")
    print(f"{'model':<28}{'msgs':>7}{'(sub)':>7}{'input':>12}{'cache-write':>14}{'cache-read':>14}{'output':>12}")
    for model, b in sorted(by_model.items(), key=lambda kv: -kv[1]["output_tokens"]):
        print(f"{model:<28}{b['messages']:>7}{b['from_subagents']:>7}{b['input_tokens']:>12,}{b['cache_creation_input_tokens']:>14,}{b['cache_read_input_tokens']:>14,}{b['output_tokens']:>12,}")


if __name__ == "__main__":
    main()
