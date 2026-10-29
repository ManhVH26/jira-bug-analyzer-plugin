# Phase 3 — Analyze (claim → investigate → root-cause + plan → approval)

## Must-do checklist (read this even if you skim the rest)
Every line is a command or a check; the end-of-run report quotes each one's evidence (or says `chưa làm` + why). `<skill-dir>` = this skill's folder.
- [ ] Claim `[CLAIM]` BEFORE reading code: `bash <skill-dir>/assets/jira.sh claim <TICKET>` (→ `JIRA_STATUS=In Progress JIRA_ASSIGNEE=…`), then `bash <skill-dir>/assets/ledger.sh upsert <PROJ> <PHASE> <TICKET> status=analyzing dev=<jira-user>`.
- [ ] Analyzer = subagent with `model: opus` (Fix-3 → Fix-6). Media = Jira attachments **plus** links in the description/comments: `bash <skill-dir>/assets/fetch-media-links.sh fetch <text> .jira-bug/media/<TICKET>/` (prnt.sc & other share pages → real image/video); analyze each via human-mcp.
- [ ] Same text file → `python3 <skill-dir>/assets/ticket_brief.py <text>` (→ `BRIEF=<n>/9 MISSING=…`, `STEP<i>=`, `EXPECT=`, `STATE=`, `FIGMA=`/`FIGMA_NODE=`). What the tester wrote is used first (steps = first repro try, Expect = the verify criterion, State = the data to build); a field in `MISSING=` is done exactly as before (media + title + app map + spec + code). A missing, messy or wrong field is **never** a reason to defer or to ask — the A/B tickets carried 23–84 characters and all six were fixed. Details: section `fix-3b`.
- [ ] After the analysis: `bash <skill-dir>/assets/ledger.sh upsert <PROJ> <PHASE> <TICKET> status=analyzed root_cause_slug=<slug> "summary=<one line>" files=<file:line;…> brief=<n>/9` → quote `LEDGER_COMMIT=`.
- [ ] Dedup: `bash <skill-dir>/assets/ledger.sh get …` + the cross-phase scan (`references/run-blocks.md`) before planning.
- [ ] Print the FULL Fix-6 block in chat (title, description, comment/resource links, root cause with `file:line`, fix plan, out of scope, risk, scorecard) — THEN ask for approval. Asking first and showing the analysis after is a bug (AIP396-475).
- [ ] `--auto` + `AUTO_SCOPE=ui-only`: the analyzer brief carries `AUTO_SCOPE`; the analyzer decides UI vs behavioral from ticket + media BEFORE any build or device repro; behavioral + no `--repro` skips both and defers (Fix-5.5 step 1b). No spec found → the Fix plan names `Kết quả đúng lấy từ:` (ticket / code precedent / chưa có).
- [ ] `[REPRO_ON]=true` + reproduced → ONE command posts the before-proof: `bash <skill-dir>/assets/jira.sh evidence <TICKET> <body-file> .jira-bug/evidence/<TICKET>/` (attaches every `repro-*` and embeds it) → quote `EVIDENCE=ok`. The analyzer's repro screenshots come only from `assets/shot.sh` (≤ 4 images). Reading `jira.sh` source to find out how to post is a bug (AAP857-113 spent 3 turns on it).
- [ ] **Any** subagent that touches the device (the analyzer doing the repro, or a separate repro agent) gets the Device block of `references/helpers/verifier-brief.md` in its brief — `source dev.sh`, `shot.sh`, `nav_home` / `nav_to`, the lock token. A hand-written repro brief without it is a bug (A/B: 3 of 7 repro agents wrote their own adb wrapper and walked ads/onboarding by hand).
- [ ] Plan approved before any code (interactive: ask; `--auto`: `references/helpers/auto-plan-pick.md`, incl. `AUTO_SCOPE`).

> **The full text is `references/details/phase3-analyze.md` — never read it whole** (the A/B runs measured 125–183k characters of reference text per ticket in the main session, paid again every turn).
> Read the one section a checklist line or a step needs: `bash <skill-dir>/assets/section.sh <skill-dir>/references/details/phase3-analyze.md "<anchor>"`.

## Sections (anchors for section.sh)
```
    context-source rule (memory-if-ready, else the dev's provided input)
    decide-from-sot rule (resolve the plan from ground truth — ask the dev only for genuine ga
    multi mode — analyze fan-out
    single-ticket workflow — analyze steps (fix-1 … fix-8)
        fix-1 — claim
        fix-2 — source-of-truth (background, non-blocking).
        fix-3 — fetch ticket:
        fix-3b — ticket brief (the qa template — a help, never a gate):
        fix-4 — fetch attachments:
        fix-5 — analyze media:
        fix-5.5 — [repro] reality-check (+ optionally reproduce) before root-causing (full rules: 
        fix-6 — synthesize root cause + fix plan
        fix-6b — [evidence] post the repro evidence to the ticket (main session, [rest]) — only wh
        fix-7 — clarify (only for genuine gaps — apply the decide-from-sot rule):
        fix-8 — approval gate:
```
