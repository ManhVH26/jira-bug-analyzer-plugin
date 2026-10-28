# Phase 5 — Verify (review diff on GitHub → build/install → user-verify → PR; `--auto` self-verify via the `android-self-verify` skill)

## Must-do checklist (read this even if you skim the rest)
Every line is a command or a check; the end-of-run report quotes each one's evidence (or says `chưa làm` + why). `<skill-dir>` = this skill's folder.
- [ ] Gate 1: show the diff (GitHub webview; `--auto`: `code-reviewer`, `model: sonnet`).
- [ ] Device ONLY through the lock: `SERIAL=$(bash <skill-dir>/assets/device-lock.sh free-serial "<session-id>" 1800)` → `bash <skill-dir>/assets/device-lock.sh install "$SERIAL" "<session-id>" <apk>`. A bare `adb install` / `adb -s … install` is a bug.
- [ ] Verifier subagent (`model: sonnet`) dispatched with **`references/helpers/verifier-brief.md`** filled in (serial + owner token from `free-serial`; never a hand-written brief — AAP857-112's told it to use bare `adb`); evidence saved under `.jira-bug/evidence/<TICKET>/` (behavioral: state-change scenarios too). Its brief names the target state and, when known from the analysis, the code entry point that reaches it (e.g. "save a word: tap a subtitle word → word sheet → Lưu"); never a guessed UI path. A `blocked` after its ~25-command budget comes back to you — fix the path, don't re-launch the same brief.
- [ ] Device choice: a connected physical phone first; an emulator only when none is connected (a cold emulator spends its budget on onboarding + test ads — AAP857-113 burned 55 commands there). The verifier brief says: never tap an ad's body (it opens a browser and leaves the app) — close it with its ✕ or BACK; still stuck behind onboarding/ads after ~5 commands → `blocked`.
- [ ] The brief's **Scenarios** = the Fix plan's "Cách kiểm chứng" (≤ 3, one regression), each with the on-screen text to crop to; screenshots only via `assets/shot.sh`; the verifier's report ends `IMAGES=<n>/<budget>` and `NAV=ok` | `NAV_SAVED=…` — quote both; `NAV=no-recipe` without `NAV_SAVED=` → send it back to save the recipe.
- [ ] `--auto` + behavioral + no device → defer `no-device` (no PR).
- [ ] `bash <skill-dir>/assets/device-lock.sh release "$SERIAL" "<session-id>"` when done.

> **The full text is `references/details/phase5-verify.md` — never read it whole** (the A/B runs measured 125–183k characters of reference text per ticket in the main session, paid again every turn).
> Read the one section a checklist line or a step needs: `bash <skill-dir>/assets/section.sh <skill-dir>/references/details/phase5-verify.md "<anchor>"`.

## Sections (anchors for section.sh)
```
    entry contract
    the gates (in order)
      gate 1 — review the code change (first, before any device work) — per ticket, immediately,
      gate 2 — install the phase-4 apk + user-verify (--auto self-verify via the android-self-ve
      gate 3 — create/update the pr + jira finalize (hand to phase 6)
    device driver — adb only, not mobile-mcp (runs inside the verifier subagent)
    granularity
```
