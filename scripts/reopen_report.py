#!/usr/bin/env python3
"""Reopen rate of jira-bug-analyzer auto-fixes vs the project's other bugs, from the Jira status history.

This is the Phase R metric. Labels are NOT trusted (they missed 12 of 31 reopens on AAP729); every
number here comes from the changelog.

Usage:
  JIRA_PERSONAL_TOKEN=... python3 scripts/reopen_report.py --project AAP729
  python3 scripts/reopen_report.py --project AAP729 --since 2026-10-28   # only auto-fixes made on/after
  python3 scripts/reopen_report.py --project AAP729 --json

Env: JIRA_URL (default https://jira.apero.vn), JIRA_PERSONAL_TOKEN (Bearer PAT, same one the Jira MCP uses).
"""
import argparse, json, math, os, sys, urllib.parse, urllib.request
from datetime import datetime, timezone

DONE = {"resolved", "closed", "done", "reviewing"}
OPEN = {"reopened", "request", "in progress", "to do", "open"}
DEFERRED_LABELS = {"analyzed-deferred", "qa-info-needed", "needs-po-clarification"}
PAGE = 100


def parse_time(s):
    return datetime.strptime(s[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)


def histories(issue):
    return sorted(issue.get("changelog", {}).get("histories", []), key=lambda h: h["created"])


def fix_time(issue, auto):
    """When the fix landed: the `auto-fixed` label for auto tickets, else the first move into a done status."""
    for h in histories(issue):
        for it in h.get("items", []):
            if auto and it.get("field") == "labels":
                before = set((it.get("fromString") or "").split())
                after = set((it.get("toString") or "").split())
                if "auto-fixed" in after and "auto-fixed" not in before:
                    return parse_time(h["created"])
    for h in histories(issue):
        for it in h.get("items", []):
            if it.get("field") == "status" and (it.get("toString") or "").lower() in DONE:
                return parse_time(h["created"])
    return None


def reopened_after(issue, t0):
    """First done -> open transition strictly after t0, or None."""
    for h in histories(issue):
        when = parse_time(h["created"])
        if when <= t0:
            continue
        for it in h.get("items", []):
            if it.get("field") == "status" and (it.get("fromString") or "").lower() in DONE \
                    and (it.get("toString") or "").lower() in OPEN:
                return when
    return None


def classify(issues, auto, since=None):
    rows = []
    for iss in issues:
        t0 = fix_time(iss, auto)
        if t0 is None or (since and t0 < since):
            continue
        labels = set(iss.get("fields", {}).get("labels") or [])
        rows.append({"key": iss["key"], "fixed": t0.isoformat(), "reopened": bool(reopened_after(iss, t0)),
                     "low": "auto-fix-low" in labels, "deferred_before": bool(labels & DEFERRED_LABELS),
                     "label_says_reopened": "auto-fix-reopened" in labels})
    return rows


def rate(rows):
    n = len(rows)
    r = sum(x["reopened"] for x in rows)
    return {"n": n, "reopened": r, "rate": round(r / n, 3) if n else None}


def two_prop_p(a, b):
    """Two-sided p-value of a two-proportion z-test (None when undefined)."""
    if not a["n"] or not b["n"]:
        return None
    p = (a["reopened"] + b["reopened"]) / (a["n"] + b["n"])
    se = math.sqrt(p * (1 - p) * (1 / a["n"] + 1 / b["n"]))
    if se == 0:
        return None
    z = abs(a["rate"] - b["rate"]) / se
    return round(2 * (1 - 0.5 * (1 + math.erf(z / math.sqrt(2)))), 3)


def summarize(auto_rows, base_rows):
    auto, base = rate(auto_rows), rate(base_rows)
    return {
        "auto": auto,
        "auto_low": rate([x for x in auto_rows if x["low"]]),
        "auto_normal": rate([x for x in auto_rows if not x["low"]]),
        "auto_deferred_before": rate([x for x in auto_rows if x["deferred_before"]]),
        "baseline_non_auto": base,
        "p_value_auto_vs_baseline": two_prop_p(auto, base),
        "label_missed_reopens": sum(1 for x in auto_rows if x["reopened"] and not x["label_says_reopened"]),
        "meets_target": (auto["rate"] is not None and base["rate"] is not None and auto["rate"] <= base["rate"]),
    }


def jira_search(url, token, jql):
    out, start = [], 0
    while True:
        q = urllib.parse.urlencode({"jql": jql, "fields": "labels,status", "expand": "changelog",
                                    "maxResults": PAGE, "startAt": start})
        req = urllib.request.Request(f"{url.rstrip('/')}/rest/api/2/search?{q}",
                                     headers={"Authorization": f"Bearer {token}", "Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.load(resp)
        out += data.get("issues", [])
        start += PAGE
        if start >= data.get("total", 0):
            return out


def pct(x):
    return "n/a" if x["rate"] is None else f"{x['reopened']}/{x['n']} = {x['rate'] * 100:.1f}%"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", required=True)
    ap.add_argument("--since", help="only auto-fixes made on/after this date (YYYY-MM-DD), e.g. the v1.15.3 install day")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    token = os.environ.get("JIRA_PERSONAL_TOKEN")
    if not token:
        sys.exit("JIRA_PERSONAL_TOKEN is not set")
    url = os.environ.get("JIRA_URL", "https://jira.apero.vn")
    since = parse_time(a.since + "T00:00:00") if a.since else None
    auto_rows = classify(jira_search(url, token, f'project = {a.project} AND labels = "auto-fixed"'), True, since)
    base_rows = classify(jira_search(url, token, f'project = {a.project} AND issuetype = Bug AND (labels is EMPTY OR labels not in ("auto-fixed")) AND statusCategory = Done'), False, since)
    s = summarize(auto_rows, base_rows)
    if a.json:
        print(json.dumps({"project": a.project, "since": a.since, **s}, indent=2))
        return
    print(f"Reopen report — {a.project}" + (f" (auto-fixes since {a.since})" if a.since else ""))
    print(f"  auto-fixed (all)          {pct(s['auto'])}")
    print(f"    --auto-low              {pct(s['auto_low'])}")
    print(f"    --auto (normal)         {pct(s['auto_normal'])}")
    print(f"    deferred before, fixed  {pct(s['auto_deferred_before'])}   (should be 0 tickets after v1.15.3)")
    print(f"  baseline (non-auto bugs)  {pct(s['baseline_non_auto'])}")
    print(f"  p-value auto vs baseline  {s['p_value_auto_vs_baseline']}")
    print(f"  reopens the label missed  {s['label_missed_reopens']}")
    print(f"  target (auto <= baseline) {'MET' if s['meets_target'] else 'not met'}")


if __name__ == "__main__":
    main()
