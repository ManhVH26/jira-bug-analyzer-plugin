# Confidence rubric — fix-vs-defer gate (the score ROUTES the gate ONLY under `--auto`)

The analyzer scores each ticket against this weighted rubric and returns a **scorecard**. **The score routes the approval gate ONLY under `--auto`:**
**`--auto` + sum ≥ threshold → auto-approve** (skip the plan-approval question, fix unattended) · **`--auto` + sum < threshold → defer + report**.

**Interactive (default, NO `--auto`): the plan-approval question is ALWAYS asked, regardless of the score.** The scorecard is rendered inside the plan for the dev's context, but it NEVER auto-skips the `Approve`/`Needs changes` ask — only `--auto` waives the human approval (`[VERIFY]`/`[OPTIONS]`). A high score in interactive mode does **not** auto-fix; the dev still approves first.

Either way, on-device verify + PR always run — the rubric never skips review.

## Weights (tunable)
| Criterion | Pts | Counts when… |
|---|---|---|
| Single unambiguous root cause | 40 | one clear cause with concrete code evidence (`file:line`); NOT 2–3 competing hypotheses |
| Small change | 30 | within `SMALL_CHANGE_MAX` (`references/constants.md`) AND no DB-migration / DI-graph change AND a shared / public API is only *extended* — a new parameter with a default value, so no existing call site changes. Removing, renaming or changing the meaning of a shared API → 0 |
| KB hit | 20 | a matching app-agnostic `knowledgebase/<category>/<slug>.md` with a proven fix exists |
| Deterministic repro | 10 | **reproduced on-device** at Fix-5.5 (`bug-analysis-rules.md` A4) or via a candidate case (A9); not flaky/once-seen. **Not reproduced (A10) → 0** (and under `--auto` with `[REPRO_ON]=true` that routes to defer). Interactive `not device-verified` (A7b) → score conservatively (partial/0). **`[REPRO_ON]=false` (default — no `--repro` flag / NL intent, A7c): expected 0 by design**, `reason: no-repro-flag` — not a failure, the raised auto threshold (`AUTO_THRESHOLD_DEFAULT`) compensates. |

**Auto-approve threshold (`--auto` only):**
- `[REPRO_ON]=true` (user opted in via `--repro` or NL intent) → **`AUTO_THRESHOLD_REPRO`** (`references/constants.md`).
- `[REPRO_ON]=false` (default-skip, device-repro not required) → **`AUTO_THRESHOLD_DEFAULT`** (`references/constants.md`) — stricter bar compensates for the missing `deterministic_repro` points.

> **`[AUTO]` note:** scoring happens the same way in EVERY mode — but the score only **routes the gate under `--auto`** (`references/helpers/auto-plan-pick.md`): sum ≥ the run's threshold (`references/constants.md`) → fix unattended, below it → **defer + report**. **In interactive mode the score is informational** — it is shown in the plan, but the dev ALWAYS approves the plan before any code (Fix-8). There is no interactive "high score → skip the ask" path.

## Scorecard the analyzer returns
```json
{
  "single_root_cause": 40,
  "small_change": 30,
  "kb_hit": 0,
  "deterministic_repro": 10,
  "sum": 80,
  "decision": "auto",          // auto | ask — consumed ONLY under --auto; ignored in interactive (always ask)
  "kb_slug": "ads/anr-on-interstitial-show",   // if kb_hit
  "app_agnostic": false
}
```

## Rules
- **Each criterion is all-or-nothing** at its listed points (no partial). Keep scoring honest — when unsure, score 0.
- **Mid-fix guard:** if the fixer discovers the plan is wrong mid-implementation, it STOPs and the ticket downgrades to **ask**, regardless of the original score.
- **When shown in the ask gate**, render the scorecard with Vietnamese labels (the prose is VN; the numbers/criterion keys stay verbatim).
- **Not persisted to memory:** the scorecard is shown at the ask/auto gate, but it is **NOT written to the shared memory** — the only per-bug memory record is the `record_bug_status.md` ledger row (`root_cause_slug` + root-cause `summary` + `files`; see `references/helpers/memory.md`), and there is **no per-ticket file**. The auto-vs-ask audit stays in the run/chat.
- **KB feedback:** a `kb_hit` fix that verifies `pass` bumps the matched KB entry's `confidence` (memory-keeper).

## Tuning
Edit the weights/thresholds in `references/constants.md` (`RUBRIC_WEIGHTS`, `AUTO_THRESHOLD_*`); the change ships with the skill version. Check the effect with `scripts/reopen_report.py` (reopen rate of `auto-fixed` tickets vs the project's non-auto bugs) before and after. Raise the threshold or KB-hit weight if `--auto` auto-fixes start landing wrong; lower it to auto-fix more aggressively under `--auto` once the KB matures. (Interactive mode is unaffected — it always asks.) **The `AUTO_THRESHOLD_REPRO` / `AUTO_THRESHOLD_DEFAULT` split by `[REPRO_ON]` is intentional** — flipping default-skip back to default-on means both collapse to `AUTO_THRESHOLD_REPRO` again; keep them aligned with the `[REPRO]` default in SKILL.md.
