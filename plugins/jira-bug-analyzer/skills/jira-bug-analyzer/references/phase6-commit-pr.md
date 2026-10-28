# Phase 6 — Commit & Create PR (the `[1COMMIT]` + PR + Jira finalize)

## Must-do checklist (read this even if you skim the rest)
Every line is a command or a check; the end-of-run report quotes each one's evidence (or says `chưa làm` + why). `<skill-dir>` = this skill's folder.
- [ ] One commit per ticket (`[1COMMIT]`); PR body with the Phase-3 + Phase-5 facts.
- [ ] Write the `[VN]` resolve comment to a file (template below, no code names), then ONE command: `bash <skill-dir>/assets/jira.sh finalize <TICKET> <body-file> .jira-bug/evidence/<TICKET>/ --time <30m> --pr <PR url> --ledger <PROJ> <PHASE> --root "<repo root>" --auto-eval <pending|->` + under `--auto` `--labels auto-fixed[,auto-fix-behavioral][,auto-fix-low]` — attaches + embeds evidence, Resolved, worklog, labels, the `[AUTO-FIX EVAL]` line, ledger `pr-created`, pr-watch, each read back. The main session runs it directly (one Bash call — a subagent costs more than the call). A separate MCP label update or REST eval comment after it is a bug. Quote `FINALIZE=ok`, `LEDGER_COMMIT=`, `PR_WATCH=`. `FINALIZE=partial MISSING=…` → report exactly those. Doing these through MCP one by one is a bug (AAP857-112: Markdown comment, no evidence, no Resolved, no worklog, no ledger until the dev asked).
- [ ] End-of-run report: one line per item above with its evidence — PR url, Jira status, worklog id, `LEDGER_COMMIT=`, pr-watch entry, device serial used.

> **The full text is `references/details/phase6-commit-pr.md` — never read it whole** (the A/B runs measured 125–183k characters of reference text per ticket in the main session, paid again every turn).
> Read the one section a checklist line or a step needs: `bash <skill-dir>/assets/section.sh <skill-dir>/references/details/phase6-commit-pr.md "<anchor>"`.

## Sections (anchors for section.sh)
```
    entry contract
    step 1 — commit [options] (commit now / not yet)
    step 2 — create pr & update jira (the old fix-13)
      resolve-comment template ([vn], evidence embedded — the comment a reporter/qa actually rea
      pr-description template (one section per ticket — carries phase 3 + phase 5)
    step 3 — offer discord review-request
    multi/team
```
