#!/usr/bin/env python3
"""Static metrics of the skill vs the v1.15.2 baseline and each phase's target (see METRICS.md).

Usage: python3 scripts/metrics.py [--json]
Runtime metrics (reopen rate, tokens, manager quiet fires) come from scripts/reopen_report.py,
scripts/token_report.py and the manager log — they need Jira / a machine that ran the skill.
"""
import json, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# metric: (phase, target description, predicate on the current value)
TARGETS = {
    "constant_copies":            ("P1", "0", lambda v: v == 0),
    "build_cmd_hardcoded_files":  ("P2", "0", lambda v: v == 0),
    "lint_errors":                ("P3", "0", lambda v: v == 0),
    "has_ci":                     ("P3", "true", lambda v: v is True),
    "test_count":                 ("P3", ">= 15", lambda v: v >= 15),
    "skill_md_bytes":             ("P4", "<= 20000", lambda v: v <= 20000),
    "description_chars":          ("P4", "<= 400", lambda v: v <= 400),
    "golden_rules_bytes":         ("P5", "< baseline", lambda v: v < 34666),
    "agent_spawns_without_model": ("P7", "0", lambda v: v == 0),
    "main_model_pinned":          ("P7", "true", lambda v: v is True),
    "scripts_without_strict_mode": ("S5", "0", lambda v: v == 0),
    "secrets_found":              ("S0", "0 (deferred)", lambda v: v == 0),
}


def current():
    lint = json.loads(subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "lint_skill.py"), "--json"],
                                     capture_output=True, text=True).stdout)["metrics"]
    lint["has_ci"] = os.path.exists(os.path.join(ROOT, ".github", "workflows", "lint.yml"))
    tests = subprocess.run(["bash", os.path.join(ROOT, "tests", "run_all.sh")], capture_output=True, text=True).stdout
    lint["test_count"] = tests.count("  ok   ") + tests.count("  FAIL ")
    lint["tests_failed"] = tests.count("  FAIL ")
    return lint


def main():
    base = json.load(open(os.path.join(ROOT, "metrics", "baseline-v1.15.2.json")))["static"]
    now = current()
    rows = [(TARGETS[k][0], k, base.get(k), now.get(k), TARGETS[k][1], TARGETS[k][2](now.get(k))) for k in TARGETS]
    if "--json" in sys.argv:
        print(json.dumps([dict(zip(("phase", "metric", "baseline", "now", "target", "met"), r)) for r in rows], indent=2))
        return
    print(f"{'phase':<6}{'metric':<30}{'v1.15.2':>12}{'now':>12}  {'target':<14}status")
    for ph, k, b, n, t, met in rows:
        print(f"{ph:<6}{k:<30}{str(b):>12}{str(n):>12}  {t:<14}{'MET' if met else 'not met'}")
    print(f"\ntests failed: {now['tests_failed']}")


if __name__ == "__main__":
    main()
