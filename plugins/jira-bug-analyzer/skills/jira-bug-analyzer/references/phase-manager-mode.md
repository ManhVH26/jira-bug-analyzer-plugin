# Manager mode — PR-watch reconcile + KB-backfill + Deferred-ticket comment watcher (`--manager <PROJECT-KEY>`)

## Must-do checklist (read this even if you skim the rest)
Every line is a command or a check; the end-of-run report quotes each one's evidence (or says `chưa làm` + why). `<skill-dir>` = this skill's folder.
- [ ] **One pass by default.** Arm a recurring loop ONLY when the invocation carries `--loop [interval]` (section "Optional loop"); without it, run one full pass, report, stop — never arm a cron on your own.
- [ ] Under `--loop` only: `bash <skill-dir>/assets/manager-precheck.sh "<root>" <KEY>` first; quiet → one line, end the fire. A one-shot run skips the precheck and does a full pass.
- [ ] Job D writes every outcome with `bash <skill-dir>/assets/ledger.sh upsert … status=done|reopened …` (interactive and `--auto` fixes) → quote `LEDGER_COMMIT=`.
- [ ] Job B cleans worktrees only for PRs that are merged/closed.
- [ ] Job D ignores a done → open flip by the resolver within `REOPEN_SELF_FLIP_MINUTES` (workflow correction, not a reopen).
- [ ] Job C runs only on tickets Job D just marked `done` (or `done` rows without a `kb` field) — never a board-wide Done scan; it stamps `kb=…` via `ledger.sh` so a ticket is judged once.

> **The full text is `references/details/phase-manager-mode.md` — never read it whole** (the A/B runs measured 125–183k characters of reference text per ticket in the main session, paid again every turn).
> Read the one section a checklist line or a step needs: `bash <skill-dir>/assets/section.sh <skill-dir>/references/details/phase-manager-mode.md "<anchor>"`.

## Sections (anchors for section.sh)
```
  manager mode — pr-watch reconcile + kb-backfill + deferred-ticket comment watcher (--manag
    entry contract
    optional loop (--loop [interval] only)
      discord inbox in-session watcher — deferred load
    precheck — first step of every loop fire (p7, v1.15.3)
    the reconcile pass (one per --manager run, or per loop fire under --loop)
    job a — review-comment handling (interactive; --auto auto-applies the clear ones)
    job b — worktree cleanup (merge/close)
    job c — kb-backfill (unattended, notify-only; runs after job d)
    job d — fix outcome tracking: done / reopened (unattended, notify-only)
    honest expectation (state it; don't overpromise)
    returns (per-pass summary, then end the pass)
```
