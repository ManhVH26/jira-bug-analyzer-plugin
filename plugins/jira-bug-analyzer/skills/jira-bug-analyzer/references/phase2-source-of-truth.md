# Phase 2 — Source-of-truth capture (per project + phase, background / non-blocking)

## Must-do checklist (read this even if you skim the rest)
Every line is a command or a check; the end-of-run report quotes each one's evidence (or says `chưa làm` + why). `<skill-dir>` = this skill's folder.
- [ ] Resolve spec/figma with the §2.0 ladder (`references/helpers/source-of-truth-discovery.md`) — interactive: one-tap confirm; `--auto`: self-verify; none found → each ticket names its expected-result source (ticket / code precedent), and only `chưa có` defers `no-sot` (`auto-plan-pick.md`).
- [ ] Launch the capture in the background; never wait for it before Phase 3.

> **The full text is `references/details/phase2-source-of-truth.md` — never read it whole** (the A/B runs measured 125–183k characters of reference text per ticket in the main session, paid again every turn).
> Read the one section a checklist line or a step needs: `bash <skill-dir>/assets/section.sh <skill-dir>/references/details/phase2-source-of-truth.md "<anchor>"`.

## Sections (anchors for section.sh)
```
    when it runs — discover synchronously, capture in the background
    discovery (§2.0) — extracted to its own file
    which phase folder — confirm <phase> from the spec title
    what it captures
      metadata.json is how local cache reconciles with remote memory — check it first
    external sources inside the spec → each its own peer file <slug>.md (read directly; unread
    tell the dev what is missing — mandatory, every run ([vn])
    push + return
```
