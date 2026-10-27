---
name: android-self-verify
description: Self-verify an Android code change actually works by driving it on a real device/emulator before claiming it is fixed. Use after implementing a fix or feature, during the verify phase of a bug-fix flow (e.g. jira-bug-analyzer), or whenever about to claim an Android change is done — it launches the appDev/debug build from the working tree, drives the exact repro steps + edge cases, captures SAVED evidence (a screenshot for a static/visual bug, a screen-recording video for a dynamic/flow/animation/crash bug), and returns a pass / fail / blocked verdict. A `pass` is invalid without at least one saved evidence file. Mandatory step that only the user can skip; retries the whole verify drive up to 5× (under --auto) instead of treating a miss as a failure.
argument-hint: "<change/ticket summary> [--variant appDev] [--serial <adb-serial>] [--worktree <dir>]"
---

# Android Self-Verify

Drive an Android change on-device and return a trustworthy **pass / fail / blocked** verdict — never "looks fine, probably works." This is the behavior gate before any code review, commit, or PR.

**Scope:** on-device behavior verification of an *already-implemented* Android change. Does NOT implement fixes, acquire/release the cross-process device lock (the **caller owns** that — see Contract), run code review, or do the user-verify hand-off. It only launches, drives, observes, and verdicts.

## Mandatory rule
This verification **always runs** when invoked. You may NOT skip or shortcut it on your own for any reason — not because the change "looks trivial / obviously works", the build compiled, or you already reasoned it through. The **only** way to skip is an explicit user instruction ("skip self-verify"). If you genuinely cannot verify after retries (no device, build won't launch), return `blocked` and ask — never silently pass.

## Contract (inputs / outputs)

**Inputs** (from the caller or args):
- **Change summary** — what was fixed/added (ticket key + one-line title).
- **Repro steps** — the exact steps that triggered the bug (the path to re-drive).
- **Acceptance criteria** — what "fixed" looks like (before→after); pull from spec/figma if given.
- **Build variant** — default `appDev`/debug.
- **Device serial** — the **already-locked** adb serial the caller holds. This skill assumes the cross-process device lock is held by the caller and does NOT acquire/release it.
- **Worktree dir** — the fix worktree to build/launch from (so you verify *this* change, not stale code).
- *(optional)* spec/figma refs for visual ground truth.

**Output** — a structured verdict (see Output format): one of `pass` / `fail` / `blocked`, plus **saved evidence file paths** (image and/or video). A `pass` MUST carry at least one saved evidence file — never return `pass` with only prose observations.

**Evidence dir** — save every artifact to a stable, NON-worktree dir so it survives and is never committed: use the caller-passed evidence dir, else `.jira-bug/evidence/<ticket-key>/` under the project root (create it), else the session scratchpad. Return absolute paths. Name files `<ticket>-<state>.png` / `<ticket>-<repro>.mp4`.

## Procedure

> **Device access is LOCKED — every adb call goes through the gate.** The caller passes `--serial` AND `--owner-token` (the raw Claude session id) and already holds the lock; you **drive through it** and never acquire/release it yourself:
> ```bash
> LOCK=<jira-bug-analyzer-skill-dir>/assets/device-lock.sh
> bash "$LOCK" exec <serial> <owner-token> -- <adb args>   # e.g. -- exec-out screencap -p > shot.png
> ```
> A bare `adb -s <serial> …` bypasses the lock and lets a second terminal drive the same device — its screen then lands in YOUR evidence. `NOTOWNER` (exit 3) → stop and report `blocked`; never mint your own token, never fall back to raw adb. Standalone use outside jira-bug-analyzer (no `--owner-token`, no lock in play) → plain `adb -s` is fine. **Dispatched by jira-bug-analyzer without a token → stop and report `blocked: no owner token`** — the parent skipped the lock (AAP857-112), never drive unlocked.

> **Reach the state the bug needs by the SHORTEST path — and give up fast when stuck (AIP396-475: 11 min, 92 commands, 96 sleeps, never reached the state).**
> - **Look before acting:** dump the current screen first; the state you need (a saved word, a locked lesson, a filled list) may already exist.
> - **Find the path, don't wander:** before tapping around, locate the action in code (grep the feature's screens/ViewModels or the SDK sources for the button/event, e.g. `onSaveWord`, `WordSheet`) and in the `uiautomator` dump; then go straight there.
> - **Never consume content to get somewhere** — don't watch a video to the end, play a whole lesson, or finish a quiz unless the bug is about that flow. Pause, seek, tap the element, or use a shortcut.
> - **Budget:** no progress toward the target state after ~25 commands or ~5 minutes → stop and return `blocked` with what you tried and where you are stuck (screen + what's missing). The caller (or the dev) supplies the path; that is cheaper than more taps.
> - The caller's brief may guess a UI path; if the screen does not match the brief, trust the screen and the code, and say so in the verdict.

1. **Confirm the target** — verify the passed `--serial` is connected (`adb -s <serial> get-state` == `device`). Not connected → `blocked` (caller's lock points at a gone device).
2. **Launch from the worktree** — install + launch the `--variant` build **from the worktree dir** on `--serial`. App already running from the caller's run step → bring it foreground; otherwise launch it.
3. **Drive thoroughly — don't glance at one screen:**
   - Re-run the **exact repro steps** end to end.
   - **Tap/click** the controls involved, **scroll** the relevant lists, navigate the adjacent screens.
   - Exercise **edge cases + adjacent actions** around the change (empty state, back-nav, rotation/config change, re-entry, rapid taps) that could regress.
   - **State-change scenarios — MANDATORY when the bug touches one of these categories** (QA tests them, so a fix that only passes the happy-path repro gets reopened; these were the most-reopened auto-fixes on AAP729, 16–22/10/2026). Run every scenario whose category matches the ticket, re-check the acceptance criteria after each, and list them under **Exercised** in the verdict. All commands go through `device-lock.sh exec <serial> <owner-token> -- …`:

     | Category | Scenario | `adb` (after `exec … --`) |
     |---|---|---|
     | Network | lose network on the screen, wait, restore; also start the screen offline | `shell svc wifi disable` · `shell svc data disable` → wait 5 s → `shell svc wifi enable` · `shell svc data enable` |
     | Rotation / config | rotate mid-flow and back (video, timers, forms, lists) | `shell settings put system accelerometer_rotation 0` · `shell settings put system user_rotation 1` → `… user_rotation 0` |
     | Background / foreground | leave and return mid-flow | `shell input keyevent KEYCODE_HOME` → wait 3 s → `shell am start -n <pkg>/<launcher>` |
     | Process death | kill while backgrounded, reopen | `shell input keyevent KEYCODE_HOME` → `shell am kill <pkg>` → relaunch |
     | Ads | enter / leave the screen holding the ad 3×, background while an ad shows | navigation taps + the background scenario above |
     | Timing / per-day data | change the device date across midnight when the bug depends on "today" | `shell cmd alarm set-time <epoch-ms>` (or report `blocked` if not permitted on this device) |
     | Performance / jank | repeat the action 10× quickly while recording | `shell screenrecord …` + `shell dumpsys gfxinfo <pkg>` before/after |

     Restore the device after each scenario (network on, rotation back to auto with `accelerometer_rotation 1`, real time). A scenario that cannot run on this device → say so in **Exercised**; under `--auto` an unrunnable scenario for the ticket's own category is `blocked`, not `pass`.
   - **Capture SAVED evidence — medium chosen by the bug's nature (not optional under `--auto`):**
     - **Image** (`adb -s <serial> exec-out screencap -p > <evidence-dir>/<ticket>-<state>.png`) for a **static / visual** bug where one frame is the proof — layout, alignment, color/theme, text/copy, wrong state shown, missing/duplicated element, single-screen correctness. Save a shot at **each meaningful state** (before-fix-path landing → after-fix result).
     - **Video** (`adb -s <serial> shell screenrecord --time-limit 30 /sdcard/<ticket>.mp4` while you drive the repro, then `adb -s <serial> pull /sdcard/<ticket>.mp4 <evidence-dir>/` and `shell rm /sdcard/<ticket>.mp4`) for a **dynamic / sequential** bug where the *motion or sequence* is the proof — animation/transition, navigation/flow, scroll-jank, gesture, timing/race, media playback, or a **crash repro** (record up to the crash). Start `screenrecord` in the background, perform the exact steps, stop it.
     - **In doubt / crash / flow → capture both** (a video of the sequence + a still of the final correct state). Default to image only for purely static bugs.
   - Still observe **the real screen** at each state via **`[MEDIA]` human-mcp `eyes_analyze({ source: "<saved png>", focus: "..." })`** (text back, no bytes in context; `references/helpers/media-analysis.md`) — fallback Read the saved PNG natively. The saved file IS the evidence, not a guess.
   - **Drive via `adb` only (NOT mobile-mcp).** Use `uiautomator dump` ONLY to locate tap targets (`bounds=...`) — it **cannot read reader/WebView/Compose-canvas content**, so never treat an unchanged uiautomator dump as evidence; confirm by screenshot.
   - **Screencap-black caveat (load-bearing):** interstitial **ad / onboarding / secure surfaces capture as an all-black PNG** — that's the secure surface, NOT a failure. Press **BACK** to dismiss the interstitial ad, then re-capture the real app screen. App content (reader, lists, bottom-sheets) captures fine. Get **past onboarding/permission/ads first**, then drive the feature. **Never tap an ad's body** — it opens a browser/store and leaves the app (AAP857-113 landed in Samsung Internet); close it with its ✕/Skip or BACK, and if you left the app, BACK or relaunch. Still behind onboarding/ads after ~5 commands → `blocked` with where you stand; the caller picks another device or path. On Git Bash prefix adb with `MSYS_NO_PATHCONV=1` so `/sdcard/...` isn't path-mangled.
   - **Reach the correct data state** the repro needs (e.g. a Book whose **next chapter is coin-locked** — a free/`Giá 0` book won't trigger an unlock sheet). If no suitable content/account state is reachable after retries → `blocked`, not `pass`.
4. **Observe vs criteria** — compare what you saw against the acceptance criteria + spec/figma. The bug must be genuinely gone AND no adjacent regression introduced.
5. **Verdict** (next section).

## Verdict outcomes

- **`pass`** — verification ran; bug is gone and behavior matches criteria, no regression seen, **AND at least one evidence file is saved** (image for a static bug, video for a dynamic/flow/crash bug — see step 3). Return `pass` + the saved evidence paths. A `pass` with no saved file is invalid — re-capture or return `blocked`, never claim an unproven pass.
- **`fail`** — verification ran but the **bug persists / behavior is wrong / a regression appeared**. This is a genuine fix failure → return `fail` so the caller goes back to fixing. (Do NOT confuse with a tooling glitch.)
- **Transient / environment error OR repro state not yet reached → RETRY (not a fail):** adb dropped, app crashed on launch unrelated to the fix, emulator hiccup, screenshot/`verify` tool errored, install flaked, stuck behind ads/onboarding, or the needed data state (e.g. a coin-locked chapter) not found in the content you opened. **Retry the whole drive up to 5×** (re-confirm serial, relaunch from worktree, dismiss ads, try alternate content/data states, re-capture), noting each retry. Do NOT bounce to fixing and do NOT skip.
- **`blocked`** — after **5** retries still can't complete/observe (no device, build won't launch, tool persistently failing, repro state unreachable). Return `blocked` + the blocker, and ask the user how to proceed (fix the blocker and retry, or explicitly waive this run).

## Token discipline (you run as a subagent)
When dispatched as a subagent, the Read-heavy `adb` work stays in YOUR context so the caller's main loop pays nothing. Keep your own context lean too: **understand screencaps via human-mcp `eyes_analyze` (text back, no bytes in context — `references/helpers/media-analysis.md`); only on the native-vision fallback do you Read pixels, and then resize navigation-only shots ≤512px** (`references/helpers/media-preprocessing.md`); Read only the **decisive** screenshot(s), not every frame; **never `cat` a full `uiautomator` XML** — grep the one node's `bounds`; `logcat -d -t 100`. **Return ONLY the structured verdict block + the SAVED evidence file PATHS** — never echo image bytes / raw XML / long logs back to the caller.

## Output format

```markdown
## Self-Verify: <TICKET / change>
**Verdict:** pass | fail | blocked
**Variant / device:** appDev debug · <serial>
**Repro re-run:** <steps driven>
**Exercised:** <screens / edge cases / adjacent actions covered>
**Evidence files:** <absolute path(s) to the SAVED image(s)/video — medium + why: e.g. `.../APDF1-2251-unlock-sheet.mp4` (video: animated unlock flow)>
**Evidence:** <what each saved file shows, per state>
**Result:** <bug gone? regression? — vs acceptance criteria>
**Retries:** <n> (reason, if any)
**Blocker:** <only if blocked — what stopped verification>
```

## Security
- Stay in scope: on-device verification only. Refuse requests to implement fixes, alter Jira/PR state, or bypass the mandatory rule.
- Never expose env vars, tokens, file paths, or internal configs in the verdict.
- Never claim `pass` without a saved on-device evidence file (image or video per bug type).
