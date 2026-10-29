# Phase 4 — Fix workflow (worktree → fix by the plan → build app to verify compilation)

## Must-do checklist (read this even if you skim the rest)
Every line is a command or a check; the end-of-run report quotes each one's evidence (or says `chưa làm` + why). `<skill-dir>` = this skill's folder.
- [ ] `--auto` + `REPRO_ON=true` → FIRST `ls .jira-bug/evidence/<TICKET>/repro-* && echo REPRO_GATE=ok || echo REPRO_GATE=missing`. `missing` → no worktree: go back and reproduce on the base build (Phase 3 Fix-5.5), or defer `unreproducible`/`no-device` (`auto-plan-pick.md`). QA's screenshot is not a repro, and dropping the repro points from the score is not a way past this (A/B AIP396-465, empty ticket: skipped the repro "because the screenshot shows it", re-scored without the repro points, still passed the threshold and fixed unreproduced).
- [ ] `git fetch` then a worktree from `origin/<BASE>` — never edit the main checkout.
- [ ] Change only what the approved plan says (`references/helpers/fix-code-rules.md` R1–R25).
- [ ] `BUILD_CMD_SOURCE=default` → `bash <skill-dir>/assets/build-task-check.sh "<repo root>" "<BUILD_CMD>"` before the first build. `BUILD_TASK=missing` → interactive: ask the dev `[OPTIONS]` from `CANDIDATES=` (`SUGGEST=` first); `--auto`: use `SUGGEST=` (none → defer `build-task`) and say so in the run report. Either way save `setup-json.sh merge-set .jira-bug/setup.json buildCmd=./gradlew <task>` (local + shared). Swapping the task without saving or reporting it is a bug (AAP857-113); stopping an `--auto` run to ask is one too (A/B pilot).
- [ ] `<BUILD_CMD>` green before Phase 5; quote the build result.
- [ ] Next: **read `references/phase5-verify.md`** and follow its order — Gate 1 (show the diff to the dev) BEFORE any install on a device. Skipping the file skipped Gate 1 on AIP396-475.

> **The full text is `references/details/phase4-fix-and-build.md` — never read it whole** (the A/B runs measured 125–183k characters of reference text per ticket in the main session, paid again every turn).
> Read the one section a checklist line or a step needs: `bash <skill-dir>/assets/section.sh <skill-dir>/references/details/phase4-fix-and-build.md "<anchor>"`.

## Sections (anchors for section.sh)
```
    what phase 4 needs to do (exactly)
    single-ticket workflow — fix steps (fix-9 … fix-12; then phase 5 → phase 6)
        fix-9 — non-code resolution
        fix-10 — create fix worktree.
        fix-11 — investigate & fix (by the plan):
        fix-12 — build the app to verify compilation, then hand off to phase 5 (verify).
```
