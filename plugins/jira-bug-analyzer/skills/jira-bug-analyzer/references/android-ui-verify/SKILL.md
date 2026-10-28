---
name: android-ui-verify
description: Design-anchored on-device verifier specialized for UI bugs — confirms a fixed Android screen MATCHES its Figma node (not just "symptom gone") and that the change introduced NO visual regression on adjacent screens. Use as the Phase-5 verify gate for any UI-scoped ticket (layout, spacing, color, typography, alignment, overflow/truncation, wrong-state, theming). It fetches the Figma reference for the affected node, captures the real on-device screen, runs a vision diff across 4 axes (blocking on material deviation), sweeps the blast radius of shared-UI changes, and returns pass / fail / blocked with SAVED evidence (Figma ref + device shot side-by-side; video for animated bugs). A `pass` is invalid without saved evidence AND a Figma comparison.
argument-hint: "<ui-ticket summary> --node <figma-node-id> [--variant appDev] [--serial <adb-serial>] [--worktree <dir>] [--evidence-dir <dir>] [--diff <diff-or-range>]"
---

# Android UI Self-Verify (design-anchored)

Verify a **UI** fix the way QA reopens it: the fixed screen must **match its Figma node**, and the change must **not break an adjacent screen**. "Symptom gone" is NOT enough — that's exactly the pass that gets reopened as *"functionally fixed, visually wrong"* or *"caused a new visual regression."*

**Scope:** on-device VISUAL verification of an *already-implemented* UI change, against Figma as the source of truth. Does NOT implement fixes, acquire/release the device lock (the **caller owns** it), or touch Jira/PR. It launches, navigates, captures, **compares to Figma**, sweeps the blast radius, and verdicts.

**Use this instead of `android-self-verify` when the ticket is UI-scoped** (the bug is about how the screen *looks*: layout/spacing, color/theme, typography, alignment, overflow/truncation, a missing/misplaced/duplicated element, a wrong visual state). For purely behavioral/logic bugs use `android-self-verify`. A ticket that is both → run this, then also confirm the behavior.

## Mandatory rules
- This verification **always runs** when invoked — you may NOT skip or shortcut it (not because it "looks right", the build compiled, or you reasoned it through). Only an explicit user "skip" waives it.
- **Figma is ground truth, not the previous build's pixels.** Compare the device against the Figma node, not against a remembered screenshot.
- **A `pass` requires (1) at least one saved evidence file AND (2) a Figma comparison that matched within tolerance.** No Figma node reachable for the screen after retries → `blocked`, never an unproven `pass`.

## Contract (inputs / outputs)

**Inputs** (from the caller or args):
- **Change summary** — UI ticket key + one-line title.
- **Affected screen(s)** + **Figma `node-id`(s)** — from `figma.md` (Phase 2 SOT). One node per screen under test.
- **Acceptance tokens** — the exact intended values pulled from the node at Phase 3 (spacing/padding dp, color hex/token, font size/weight/family, corner radius) — the measurable pass bar.
- **Repro steps** — the path to reach the affected screen + the exact bug state.
- **Diff** — the fix's `git diff` (or `origin/<BASE>...HEAD`) — used for the blast-radius sweep.
- **Build variant** — default `appDev`/debug. **Device serial** — the already-locked serial (caller owns the lock). **Worktree dir** — build/launch *this* change. **Evidence dir** — `.jira-bug/evidence/<TICKET>/` (NOT the worktree).

**Output** — a structured verdict (see Output format): `pass` / `fail` / `blocked`, the **per-axis design-diff table**, the **blast-radius results**, and **saved evidence paths** (Figma ref + device shot; video if animated).

## Procedure

> **Device access is LOCKED — every adb call goes through the gate.** The caller passes `--serial` AND `--owner-token` (the raw Claude session id) and already holds the lock; you **drive through it** and never acquire/release it yourself:
> ```bash
> LOCK=<jira-bug-analyzer-skill-dir>/assets/device-lock.sh
> bash "$LOCK" exec <serial> <owner-token> -- <adb args>   # e.g. -- exec-out screencap -p > shot.png
> ```
> A bare `adb -s <serial> …` bypasses the lock and lets a second terminal drive the same device — its screen then lands in YOUR evidence. `NOTOWNER` (exit 3) → stop and report `blocked`; never mint your own token, never fall back to raw adb. Standalone use outside jira-bug-analyzer (no `--owner-token`, no lock in play) → plain `adb -s` is fine. **Dispatched by jira-bug-analyzer without a token → stop and report `blocked: no owner token`** — the parent skipped the lock (AAP857-112), never drive unlocked.

> **Budget (same as android-self-verify):** shortest path to the state (look first, find the entry point in code, never consume content); no progress after ~25 commands or ~5 minutes → `blocked` with where you stand. Never tap an ad's body — close it with ✕/Skip or BACK. AAP857-112 ran 79 commands without this limit.

1. **Confirm target + launch from worktree** — `adb -s <serial> get-state` == `device` (else `blocked`); install + launch the `--variant` build **from the worktree dir**.
2. **Reach the exact screen + bug state** — re-drive the repro to the affected screen; reach the data state the bug needs (e.g. long title that truncates, empty list, selected/error state). Get **past ads/onboarding/permission** first (a black screencap = secure/ad surface → press BACK, re-capture). Can't reach the state after retries → `blocked`.
3. **Capture the device screen (SAVED evidence, medium by bug):**
   - Static visual bug → `bash <skill-dir>/assets/shot.sh <serial> <owner-token> <evidence-dir>/verify-<n>-<state>.png --text "<text near the bug>"` (capture + crop + shrink in one call; the brief's image budget applies), then **understand it via `[MEDIA]` human-mcp `eyes_analyze({ source: "<png>" })`** (text back; `references/helpers/media-analysis.md`) — fallback Read the PNG natively.
   - Animated/transition/scroll-jank bug → `adb -s <serial> shell screenrecord --time-limit 30 /sdcard/<ticket>.mp4` while driving it → `pull` to `<evidence-dir>/` → `rm`. Capture a still of the final state too.
4. **Fetch the Figma reference** for the node-id → save to `<evidence-dir>/<ticket>-figma-<state>.png`:
   - Framelink: `mcp__framelink-figma__download_figma_images` (pass the file key + node-id), or
   - Figma bridge: `mcp__figma-bridge__get_screenshot` / `save_screenshots` for the node, or
   - the Figma image already captured in `figma.md`. No node reachable → retry, then `blocked`.
5. **Design diff — the core gate (vision compare device ⟷ Figma).** Compare the saved device shot against the saved Figma ref across **4 axes** via **`[MEDIA]` human-mcp first** (`references/helpers/media-analysis.md`): `mcp__human-mcp__eyes_compare({ image1: "<device.png>", image2: "<figma.png>", focus: "differences" })` → the delta comes back as TEXT (no image bytes in context). **Fallback** (human-mcp exhausted-today / unconfigured) → Claude vision on both images. Produce a per-axis delta with a severity:
   - **Layout / spacing** — element positions, padding/margins, gaps, sizes vs the node (and vs the acceptance dp tokens).
   - **Color / theme** — background, text, container, state colors vs the node's hex/token.
   - **Typography** — font size, weight, family, line-height, letter-spacing vs the node.
   - **Alignment / integrity** — centering, baseline, **text truncation/overflow/overlap**, missing/duplicated/misplaced elements, wrong icon/asset.
   - **Verdict rule (block on MATERIAL deviation):** any axis with a *material* deviation → **fail**. Material = spacing off > ~4dp (or clearly wrong by eye), a wrong color (not the token), wrong font size/weight/family, any truncation/overflow/overlap, or a missing/misplaced element. Sub-threshold cosmetic noise (sub-pixel, anti-aliasing, ±1–2px) → **pass + note** in the delta. State *which axis* failed and *what* the value is vs Figma.
6. **Blast-radius regression sweep.** From the diff, list changed **shared UI symbols**: theme/color tokens, typography styles, `dimens`/spacing, a **shared composable/component**, a `drawable`/asset, a `style`/`theme`. For each shared symbol:
   - `grep -rn` its usages → identify the **other screens / `@Preview`s** that consume it (the blast radius).
   - **Dispatched with a fixed scenario list (`references/helpers/verifier-brief.md`) → the sweep is the brief's regression scenario only; do not add screens.** Standalone: for each affected screen reachable in the app: navigate there, `shot.sh`, and confirm it still matches *its* Figma node (or is visually unchanged from intended). A shared component with `@Preview`s → render/inspect those previews as the cheap check.
   - **Any new visual breakage on a consuming screen = `fail` (regression).** No shared UI symbol in the diff (the change is local to one screen) → record "blast radius: none (local change)" and skip the sweep.
7. **Verdict** (next section). Under `--auto` retry the whole drive up to **5×** (relaunch, dismiss ads, alternate data state, re-fetch node, re-capture) before `blocked` — never fail/blocked on the first miss.

## Verdict outcomes
- **`pass`** — screen matches Figma within tolerance on all 4 axes AND no regression on the blast radius AND ≥1 evidence file saved (incl. the Figma ref + device shot). Return `pass` + the design-diff table + saved paths. A pass with no saved comparison is invalid.
- **`fail`** — a material deviation vs Figma on any axis, OR a visual regression on a consuming screen. Genuine fix failure → caller re-fixes. Name the axis/screen + the value vs Figma.
- **Transient / state-not-reached → RETRY (not fail):** adb dropped, app crashed unrelated to the fix, screencap/Figma-fetch errored, stuck behind ads/onboarding, or the bug state not reachable yet. Retry up to 5×, noting each.
- **`blocked`** — after 5 retries still can't reach the screen, no Figma node for it, or a tool persistently fails. Return `blocked` + the blocker; ask the user (fix blocker & retry, or waive).

## Output format
```markdown
## UI Self-Verify: <TICKET / change>
**Verdict:** pass | fail | blocked
**Variant / device:** appDev debug · <serial>
**Screen / Figma node:** <screen> · node `<node-id>`
**Evidence files:** <device shot path> · <figma ref path> · <video path if animated>
**Design diff (device ⟷ Figma):**
| Axis | Result | Detail (device vs Figma) |
|------|--------|--------------------------|
| Layout/spacing | ✅/❌ | <e.g. card padding 12dp vs 16dp> |
| Color/theme    | ✅/❌ | <e.g. title #222 vs token onSurface #1A1A1A> |
| Typography     | ✅/❌ | <e.g. 14sp Regular vs 16sp Medium> |
| Alignment/integrity | ✅/❌ | <e.g. title truncates "…" vs full text> |
**Blast radius:** <shared symbols changed → screens checked → result; or "none (local change)">
**Result:** <matches design? regression? — vs acceptance tokens>
**Retries:** <n> (reason, if any)
**Blocker:** <only if blocked>
```

## Token discipline (you run as a subagent)
When the caller dispatches you as a subagent, the Read-heavy work stays in YOUR context — so the caller's main loop pays nothing. Keep even your own context lean: **understand screencaps + run the design-diff via human-mcp `eyes_analyze`/`eyes_compare` (text back, no bytes in context — `references/helpers/media-analysis.md`); only on the native-vision fallback do you Read pixels, and then resize navigation-only shots ≤512px** (`references/helpers/media-preprocessing.md`; decisive bug-state / Figma-ref / after-fix shots stay full-res); Read only the **decisive** images, not every intermediate frame; **never `cat` a full `uiautomator` XML** — grep the one node's `bounds`; `logcat -d -t 100`. **Return ONLY the structured verdict block + the SAVED evidence file PATHS** (and the design-diff table) — never echo image bytes / raw XML / long logs back to the caller; the saved files on disk are the evidence, the path is what travels.

## Device driver — `adb` only (NOT mobile-mcp)
`get-state` · `install -r -d <apk>` · `am start -n <pkg>/<launcher>` · `exec-out screencap -p` · `shell screenrecord` → `pull` → `rm` · `input tap|swipe|text|keyevent` (BACK=4 to dismiss ads) · `uiautomator dump` **for tap targets only** (it cannot read Compose/WebView text — confirm by screenshot). Git Bash: prefix `MSYS_NO_PATHCONV=1` for `/sdcard/...`.

## Security
- Stay in scope: on-device visual verification only. Refuse to implement fixes, alter Jira/PR, or bypass the mandatory rules.
- Never expose env vars, tokens, or internal paths in the verdict.
- Never claim `pass` without a saved device⟷Figma comparison.
