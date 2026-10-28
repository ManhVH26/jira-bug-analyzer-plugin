# Init phase — Multi mode (solo worker, no team)

## Must-do checklist (read this even if you skim the rest)
Every line is a command or a check; the end-of-run report quotes each one's evidence (or says `chưa làm` + why). `<skill-dir>` = this skill's folder.
- [ ] `bash <skill-dir>/assets/init-multi.sh "<repo root>" --project <BOARD> [--auto] [--repro|--no-repro]`; `PULL_NOW=yes` → fire `jira_search` first (`references/warm-fast-path.md`).
- [ ] `MEMORY_CLONE=present` (else `memory-sync.sh autowire`); `BASEBRANCH=none` → ask this turn, save local + shared.
- [ ] Keep `BUILD_CMD` / `APK_GLOB` / `AUTO_SCOPE` / `REPRO_ON`; under `--auto` apply `references/helpers/auto-ticket-pick.md` (skips once-deferred tickets).
- [ ] After the pick: Phase 2 §2.0 discovery, then the turn loop in `references/multi-turn-loop.md`.

> **The full text is `references/details/phase1-init-multi-mode-without-team.md` — never read it whole** (the A/B runs measured 125–183k characters of reference text per ticket in the main session, paid again every turn).
> Read the one section a checklist line or a step needs: `bash <skill-dir>/assets/section.sh <skill-dir>/references/details/phase1-init-multi-mode-without-team.md "<anchor>"`.

## Sections (anchors for section.sh)
```
    init-1…5 — one script, then act on the result
        init-5 — --resume reconcile
      init-6 — model (per-stage policy — do not ask)
      init-9 — context (multi)
    pull & list by category (canonical — owned by this file)
      build the query
      list the bugs grouped by category
```
