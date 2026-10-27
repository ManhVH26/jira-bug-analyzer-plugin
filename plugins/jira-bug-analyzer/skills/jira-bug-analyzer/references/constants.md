# Constants — the ONE place every tunable number lives

Every other file names the constant (e.g. `AUTO_THRESHOLD_DEFAULT`) and points here; it never repeats the value. `scripts/lint_skill.py` fails the build when a value is copied elsewhere (human-facing pages `usage-by-mode.md` and `assets/flow-preview.html` may show the number, but must match this table).

| Constant | Value | Used by |
|---|---|---|
| `AUTO_THRESHOLD_DEFAULT` | 90 | `--auto` without `--repro`: auto-approve when the confidence sum reaches this (`helpers/confidence-rubric.md`) |
| `AUTO_THRESHOLD_REPRO` | 80 | `--auto --repro` (device repro required, so the 10 repro points can count) |
| `AUTO_THRESHOLD_LOW` | 40 | `--auto --auto-low`, always paired with `[LOW-RISK-GATE]` |
| `RUBRIC_WEIGHTS` | 40 / 30 / 20 / 10 | single root cause / small change / KB hit / deterministic repro (`helpers/confidence-rubric.md`) |
| `SMALL_CHANGE_MAX` | ≤ 20 LOC and ≤ 2 files | the "small change" rubric criterion |
| `AUTO_PICK_PER_TURN` | 3 | `helpers/auto-ticket-pick.md` |
| `CATEGORY_CAP` | 4 bugs / category / turn | multi-mode pick list |
| `REFIX_BUDGET` | 2 | re-fix attempts per ticket under `--auto` before `retries-exhausted` (`helpers/auto-run-test.md`) |
| `VERIFY_OBSERVE_RETRIES` | 5 | verifier observation retries before `blocked` |
| `MANAGER_LOOP` | 10 min | `--manager` self-armed `/loop` cadence |
| `REOPEN_WATCH_DAYS` | 14 | Job D keeps re-checking a `held` auto-fix for a reopen this long after it resolved |
| `REOPEN_SELF_FLIP_MINUTES` | 30 | a done → open flip by the same person who just resolved it, within this window, is a workflow correction, not a reopen (Job D + `scripts/reopen_report.py`) |
| `REOPEN_TARGET` | ≤ the project's non-auto reopen rate | Phase R success bar (`scripts/reopen_report.py` prints both) |
| `DISCORD_INTENTS` | 6 | `discord/discord-classifier.md` taxonomy size |
| `DISCORD_CONFIRM_TTL` | 60 s | `discord/discord-safety-gate.md` |
| `TEAM_PR_ROUND` | 5 min, rolling | `--team` only (`team/team.md`); solo modes stream per ticket |
| `DEFAULT_BUILD_CMD` | `./gradlew assembleAppDevDebug` | fallback when `setup.json` has no `buildCmd` (`assets/init-lib.sh` emits `BUILD_CMD=`) |
| `AUTO_SCOPE` | `ui-only` | `--auto` only fixes UI-scoped tickets; behavioral ones defer `behavioral-scope` (`helpers/auto-plan-pick.md`). Per project override: `setup.json` `autoScope: "all"` once R7's bar is met |
| `DEFAULT_APK_GLOB` | `app/build/outputs/apk/**/debug/*.apk` | fallback when `setup.json` has no `apkGlob` |

## Model matrix (P7 v1.15.3) — every subagent spawn names its model

The main session runs on `sonnet` (pinned by `model:` in SKILL.md frontmatter). Every `Agent` spawn passes `model` explicitly — a spawn without one inherits the user's (often most expensive) model; `scripts/lint_skill.py` fails on an `Agent({…})` block without `model:`.

| Stage | Model | Why |
|---|---|---|
| Main loop: board pull, list + categorize (inline), gates, orchestration | `sonnet` | shows results and takes choices; no deep reasoning |
| Get Jira ticket, attachments, search, Jira writes, comments, worklog, Phase-6 finalize, plain status writes | `haiku` | mechanical I/O |
| Analyzer (root cause, scorecard, plan) | `opus` | the quality-critical step; change only with data (P7 7.7) |
| Fixer (implement the approved plan) | `sonnet` | code execution against a plan |
| Verifier — `android-ui-verify` / `android-self-verify` | `sonnet` | scripted `adb` drive; images reach it as text via human-mcp |
| `code-reviewer` as the `--auto` Phase-5 gate | `sonnet` | diff vs `R1`–`R22` |
| `[LOW-RISK-GATE]` judge | `opus` | second rail when the threshold is `AUTO_THRESHOLD_LOW` — do not save here |
| memory-keeper: dedup match | `sonnet`; re-run on `opus` only when the verdict is "maybe" | mostly slug + summary comparison |
| memory-keeper: `kb-upsert` (category + slug + app-agnostic) | `opus` | rare; a wrong category pollutes the KB |
| memory-keeper: source-of-truth build | `sonnet` | distilling spec + Figma |
| memory-keeper: status writes, freshness check, project-setup | `haiku` | mechanical |
| Discord Job G classifier | inline on the main loop (`sonnet`) | one short classification; a `haiku` spawn would add a round trip for little saving |
| Discord subagents: `resume-<KEY>` / `bulk-<slug>` / `query-<slug>` | `sonnet` / `sonnet` / `haiku` | resume re-runs the skill (its own stages follow this table) |

**`--model <opus|sonnet|haiku>`** overrides only the judgment stages (analyzer, dedup, `kb-upsert`, `[LOW-RISK-GATE]`). Mechanical `haiku` stages stay `haiku` — forcing `opus` onto Jira writes buys nothing. Persist it to setup memory like before.

**Prompt caching for parallel subagents:** analyzers dispatched together share their prompt prefix, so put the stable part first (rules, the phase-file excerpt, SOT anchors) and the ticket-specific part (key, summary, attachments, clarify text) LAST; send the analyzer only the Fix-3 → Fix-6 part of `references/phase3-analyze.md`, not the whole file.
