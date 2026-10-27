"""Unit tests for scripts/reopen_report.py — the Phase R metric must count reopens from the changelog only."""
import importlib.util, os, unittest

spec = importlib.util.spec_from_file_location("rr", os.path.join(os.path.dirname(__file__), "..", "scripts", "reopen_report.py"))
rr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rr)


def h(when, *items):
    return {"created": when, "items": [dict(zip(("field", "fromString", "toString"), it)) for it in items]}


def issue(key, labels, *hist):
    return {"key": key, "fields": {"labels": labels}, "changelog": {"histories": list(hist)}}


AUTO_REOPENED = issue("A-1", ["auto-fixed", "auto-fix-low"],
                      h("2026-10-20T10:00:00.000+0700", ("labels", "", "auto-fix-low auto-fixed")),
                      h("2026-10-20T10:01:00.000+0700", ("status", "In Progress", "Resolved")),
                      h("2026-10-22T09:00:00.000+0700", ("status", "Closed", "Reopened")))
AUTO_HELD = issue("A-2", ["auto-fixed"],
                  h("2026-10-20T10:00:00.000+0700", ("labels", "", "auto-fixed")),
                  h("2026-10-20T10:01:00.000+0700", ("status", "In Progress", "Resolved")))
AUTO_REOPENED_BEFORE_FIX_ONLY = issue("A-3", ["auto-fixed"],
                  h("2026-10-18T10:00:00.000+0700", ("status", "Closed", "Reopened")),
                  h("2026-10-20T10:00:00.000+0700", ("labels", "", "auto-fixed")))
AUTO_DEFERRED_THEN_FIXED = issue("A-4", ["auto-fixed", "analyzed-deferred", "auto-fix-reopened"],
                  h("2026-10-20T10:00:00.000+0700", ("labels", "analyzed-deferred", "analyzed-deferred auto-fixed")),
                  h("2026-10-21T10:00:00.000+0700", ("status", "Reviewing", "Request")))
BASE_REOPENED = issue("B-1", [], h("2026-10-19T10:00:00.000+0700", ("status", "In Progress", "Resolved")),
                      h("2026-10-19T12:00:00.000+0700", ("status", "Resolved", "Reopened")))
BASE_HELD = issue("B-2", [], h("2026-10-19T10:00:00.000+0700", ("status", "In Progress", "Resolved")))


class ReopenReport(unittest.TestCase):
    def test_counts_only_reopens_after_the_auto_fix(self):
        rows = rr.classify([AUTO_REOPENED, AUTO_HELD, AUTO_REOPENED_BEFORE_FIX_ONLY, AUTO_DEFERRED_THEN_FIXED], True)
        self.assertEqual({r["key"]: r["reopened"] for r in rows}, {"A-1": True, "A-2": False, "A-3": False, "A-4": True})

    def test_label_misses_are_reported(self):
        s = rr.summarize(rr.classify([AUTO_REOPENED, AUTO_DEFERRED_THEN_FIXED], True), [])
        self.assertEqual(s["label_missed_reopens"], 1)  # A-1 reopened without the auto-fix-reopened label

    def test_subsets_and_baseline(self):
        auto = rr.classify([AUTO_REOPENED, AUTO_HELD, AUTO_DEFERRED_THEN_FIXED], True)
        base = rr.classify([BASE_REOPENED, BASE_HELD], False)
        s = rr.summarize(auto, base)
        self.assertEqual((s["auto"]["n"], s["auto"]["reopened"]), (3, 2))
        self.assertEqual((s["auto_low"]["n"], s["auto_low"]["reopened"]), (1, 1))
        self.assertEqual((s["auto_deferred_before"]["n"], s["auto_deferred_before"]["reopened"]), (1, 1))
        self.assertEqual(s["baseline_non_auto"]["rate"], 0.5)
        self.assertFalse(s["meets_target"])

    def test_since_filters_on_fix_time(self):
        since = rr.parse_time("2026-10-21T00:00:00")
        self.assertEqual(rr.classify([AUTO_REOPENED, AUTO_HELD], True, since), [])

    def test_p_value_matches_the_aap729_numbers(self):
        p = rr.two_prop_p({"n": 83, "reopened": 25, "rate": 25 / 83}, {"n": 50, "reopened": 8, "rate": 8 / 50})
        self.assertTrue(0.05 < p < 0.1, p)


class ByDev(unittest.TestCase):
    def test_by_keeps_only_the_dev_who_added_the_label_even_after_reassign(self):
        mine = issue("A-5", ["auto-fixed"],
                     dict(h("2026-10-20T10:00:00.000+0700", ("labels", "", "auto-fixed")), author={"name": "me"}),
                     dict(h("2026-10-22T10:00:00.000+0700", ("status", "Closed", "Reopened")), author={"name": "qa"}))
        theirs = issue("A-6", ["auto-fixed"], dict(h("2026-10-20T10:00:00.000+0700", ("labels", "", "auto-fixed")), author={"name": "other"}))
        rows = rr.classify([mine, theirs], True, by="me")
        self.assertEqual([(r["key"], r["reopened"]) for r in rows], [("A-5", True)])


if __name__ == "__main__":
    unittest.main()
