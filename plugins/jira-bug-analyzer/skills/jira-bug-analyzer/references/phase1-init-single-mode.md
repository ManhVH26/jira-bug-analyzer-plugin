# Init phase — Single mode (fix ONE ticket by key)

## Must-do checklist (read this even if you skim the rest)
Every line is a command or a check; the end-of-run report quotes each one's evidence (or says `chưa làm` + why). `<skill-dir>` = this skill's folder.
- [ ] `bash <skill-dir>/assets/init-single.sh "<repo root>" --project <BOARD> [--auto] [--repro|--no-repro]` (pass the invocation's flags) — act on every INIT-STATUS line; `ENV=block:*` / a `TIER=now` dep missing → stop and fix (`references/helpers/environment-setup.md`).
- [ ] `MEMORY_CLONE=present` (else `bash <skill-dir>/assets/memory-sync.sh autowire`) — without it no ledger write can happen later.
- [ ] `BASEBRANCH=none` → ask now and save: `bash <skill-dir>/assets/setup-json.sh merge-set .jira-bug/setup.json board=<BOARD> baseBranch=<branch>` (+ the shared copy). `SETUP=absent` must not survive Phase 1 — AAP857-113 asked, never saved, and the next run would ask again.
- [ ] Keep `BUILD_CMD` / `BUILD_CMD_SOURCE` / `APK_GLOB` / `AUTO_SCOPE` / `REPRO_ON` from INIT-STATUS for Phases 3–5 (`REPRO_ON=false` + NL repro intent in the request → true).
- [ ] Next: Phase 2 §2.0 discovery (`references/helpers/source-of-truth-discovery.md`) BEFORE the claim.

> **The full text is `references/details/phase1-init-single-mode.md` — never read it whole** (the A/B runs measured 125–183k characters of reference text per ticket in the main session, paid again every turn).
> Read the one section a checklist line or a step needs: `bash <skill-dir>/assets/section.sh <skill-dir>/references/details/phase1-init-single-mode.md "<anchor>"`.

## Sections (anchors for section.sh)
```
    init-1…5 — one script, then act on the result
        init-5 — --resume reconcile
      init-6 — model (per-stage policy — do not ask)
      init-9 — context (single)
```
