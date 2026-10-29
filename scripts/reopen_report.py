#!/usr/bin/env python3
"""Reopen rate of jira-bug-analyzer auto-fixes vs the project's other bugs, from the Jira status history.

This is the Phase R metric. Labels are NOT trusted (they missed 12 of 31 reopens on AAP729); every
number here comes from the changelog.

Usage:
  JIRA_PERSONAL_TOKEN=... python3 scripts/reopen_report.py --project AAP729
  python3 scripts/reopen_report.py --project AAP729 --since 2026-10-28   # only auto-fixes made on/after
  python3 scripts/reopen_report.py --project AIP396 --since 2026-10-28 --by vuhoangmanh   # only my auto-fixes
  python3 scripts/reopen_report.py --project AAP729 --json

Env: JIRA_URL (default https://jira.apero.vn), JIRA_PERSONAL_TOKEN (Bearer PAT, same one the Jira MCP uses).
"""
import argparse, json, math, os, sys, urllib.parse, urllib.request
from datetime import datetime, timezone

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "plugins", "jira-bug-analyzer",
                                "skills", "jira-bug-analyzer", "assets"))
import ticket_brief  # noqa: E402  (how much of the QA template the ticket carried — the same reader the run uses)

DONE = {"resolved", "closed", "done", "reviewing"}
OPEN = {"reopened", "request", "in progress", "to do", "open"}
DEFERRED_LABELS = {"analyzed-deferred", "qa-info-needed", "needs-po-clarification"}
PAGE = 100
BRIEF_FULL = 5   # ticket_brief fields (of 9) from which a ticket counts as "written to the template"
# A done -> open flip by the SAME person who just resolved it, within this window, is a workflow
# correction (e.g. Resolved -> In Progress -> Resolved while finalizing), not a QA reopen.
# Keep in sync with REOPEN_SELF_FLIP_MINUTES in references/constants.md.
REOPEN_SELF_FLIP_MINUTES = 30


def parse_time(s):
    return datetime.strptime(s[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)


def histories(issue):
    return sorted(issue.get("changelog", {}).get("histories", []), key=lambda h: h["created"])


def author(h):
    a = h.get("author") or {}
    return a.get("name") or a.get("key") or a.get("accountId") or ""


def auto_fix_entry(issue):
    """The changelog entry that added the `auto-fixed` label (None if absent)."""
    for h in histories(issue):
        for it in h.get("items", []):
            if it.get("field") == "labels":
                before = set((it.get("fromString") or "").split())
                after = set((it.get("toString") or "").split())
                if "auto-fixed" in after and "auto-fixed" not in before:
                    return h
    return None


def fix_time(issue, auto):
    """When the fix landed: the `auto-fixed` label for auto tickets, else the first move into a done status."""
    if auto:
        h = auto_fix_entry(issue)
        if h:
            return parse_time(h["created"])
    for h in histories(issue):
        for it in h.get("items", []):
            if it.get("field") == "status" and (it.get("toString") or "").lower() in DONE:
                return parse_time(h["created"])
    return None


def reopened_after(issue, t0):
    """First real reopen (done -> open) strictly after t0, or None. A flip back by the person who
    made the last done transition, within REOPEN_SELF_FLIP_MINUTES, is ignored."""
    last_done = None  # (time, author) of the latest move INTO a done status
    for h in histories(issue):
        when, who = parse_time(h["created"]), author(h)
        for it in h.get("items", []):
            if it.get("field") != "status":
                continue
            src, dst = (it.get("fromString") or "").lower(), (it.get("toString") or "").lower()
            if dst in DONE:
                last_done = (when, who)
            elif src in DONE and dst in OPEN and when > t0:
                self_flip = (last_done and who and who == last_done[1]
                             and (when - last_done[0]).total_seconds() <= REOPEN_SELF_FLIP_MINUTES * 60)
                if not self_flip:
                    return when
    return None


def classify(issues, auto, since=None, by=None):
    """by: keep only auto-fixes whose `auto-fixed` label was added by this Jira user (the dev who ran the skill).
    Filtering on the current assignee would drop reopened tickets that QA reassigned."""
    rows = []
    for iss in issues:
        if auto and by:
            h = auto_fix_entry(iss)
            if not h or author(h) != by:
                continue
        t0 = fix_time(iss, auto)
        if t0 is None or (since and t0 < since):
            continue
        f = iss.get("fields", {})
        labels = set(f.get("labels") or [])
        brief = len(ticket_brief.parse(f.get("description") or "")[4])
        rows.append({"key": iss["key"], "fixed": t0.isoformat(), "reopened": bool(reopened_after(iss, t0)),
                     "brief": brief, "reporter": (f.get("reporter") or {}).get("name") or "?",
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
        # does a fuller QA ticket get reopened less? (BRIEF_FULL of 9 template fields; a hint for QA, never a gate)
        "auto_brief_full": rate([x for x in auto_rows if x["brief"] >= BRIEF_FULL]),
        "auto_brief_thin": rate([x for x in auto_rows if x["brief"] < BRIEF_FULL]),
        "auto_by_reporter": {r: {**rate([x for x in auto_rows if x["reporter"] == r]),
                                 "brief_avg": round(sum(x["brief"] for x in auto_rows if x["reporter"] == r)
                                                    / sum(1 for x in auto_rows if x["reporter"] == r), 1)}
                             for r in sorted({x["reporter"] for x in auto_rows})},
        "baseline_non_auto": base,
        "p_value_auto_vs_baseline": two_prop_p(auto, base),
        "label_missed_reopens": sum(1 for x in auto_rows if x["reopened"] and not x["label_says_reopened"]),
        "meets_target": None if auto["rate"] is None or base["rate"] is None else auto["rate"] <= base["rate"],
    }


def jira_search(url, token, jql):
    out, start = [], 0
    while True:
        q = urllib.parse.urlencode({"jql": jql, "fields": "labels,status,description,reporter", "expand": "changelog",
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
    ap.add_argument("--by", help="only auto-fixes labelled by this Jira username (separates devs / plugin versions on one board)")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    token = os.environ.get("JIRA_PERSONAL_TOKEN")
    if not token:
        sys.exit("JIRA_PERSONAL_TOKEN is not set")
    url = os.environ.get("JIRA_URL", "https://jira.apero.vn")
    since = parse_time(a.since + "T00:00:00") if a.since else None
    auto_rows = classify(jira_search(url, token, f'project = {a.project} AND labels = "auto-fixed"'), True, since, a.by)
    base_rows = classify(jira_search(url, token, f'project = {a.project} AND issuetype = Bug AND (labels is EMPTY OR labels not in ("auto-fixed")) AND statusCategory = Done'), False, since)
    s = summarize(auto_rows, base_rows)
    if a.json:
        print(json.dumps({"project": a.project, "since": a.since, "by": a.by, **s}, indent=2))
        return
    print(f"Reopen report — {a.project}" + (f" (auto-fixes since {a.since})" if a.since else "") + (f" by {a.by}" if a.by else ""))
    print(f"  auto-fixed (all)          {pct(s['auto'])}")
    print(f"    --auto-low              {pct(s['auto_low'])}")
    print(f"    --auto (normal)         {pct(s['auto_normal'])}")
    print(f"    deferred before, fixed  {pct(s['auto_deferred_before'])}   (should be 0 tickets after v1.15.3)")
    print(f"    ticket >= {BRIEF_FULL}/9 fields  {pct(s['auto_brief_full'])}   (QA template, ticket_brief.py)")
    print(f"    ticket <  {BRIEF_FULL}/9 fields  {pct(s['auto_brief_thin'])}")
    for r, x in s["auto_by_reporter"].items():
        print(f"      reporter {r:<14} {pct(x)}   fields avg {x['brief_avg']}/9")
    print(f"  baseline (non-auto bugs)  {pct(s['baseline_non_auto'])}")
    print(f"  p-value auto vs baseline  {s['p_value_auto_vs_baseline']}")
    print(f"  reopens the label missed  {s['label_missed_reopens']}")
    verdict = {None: "n/a (no auto-fixes yet)", True: "MET", False: "not met"}[s["meets_target"]]
    print(f"  target (auto <= baseline) {verdict}")


if __name__ == "__main__":
    main()
