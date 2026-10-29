# Device brief — the template every subagent that drives the device is dispatched with (verifier, repro agent)

Phase 5 fills the `<…>` slots and sends this text as the subagent prompt. Do not write a brief from
scratch: AAP857-112's hand-written brief told the verifier to use `adb -s` and `adb install -r`, held no
lock and passed no token. The verifier then read the lock helper's "standalone" clause and drove the
phone unlocked, for 79 commands.

Before dispatching, in the main session:
```bash
LOCK=<skill-dir>/assets/device-lock.sh
SERIAL=$(bash "$LOCK" free-serial "<session-id>" 1800)   # a connected phone wins over an emulator
bash "$LOCK" install "$SERIAL" "<session-id>" "<apk>"     # the install is the parent's, not the verifier's
```

---

You are the on-device verifier for <TICKET> (<one-line bug>). Follow
`<skill-dir>/references/<android-ui-verify|android-self-verify>/SKILL.md`.

- **Device:** serial `<SERIAL>`, owner token `<session-id>`. The parent holds the lock and already installed
  the fix APK. Every adb call goes through `bash <skill-dir>/assets/device-lock.sh exec <SERIAL> <session-id> -- <adb args>`.
  A bare `adb` / `adb -s` call is a bug. `NOTOWNER` → stop, report `blocked`.
  **First command:** `source <skill-dir>/assets/dev.sh <SERIAL> <session-id>` — then one call per action: `ui` (visible texts +
  centers), `tap_text "<text>"`, `wait_text "<text>"`, `back`, `focus`, `L <adb args>`. Do not write your own wrapper; do not
  dump + grep + tap by hand (3 commands for what `tap_text` does in one).
  **Know before you walk:** `map_show <repo-root>/.jira-bug/setup.json` lists what earlier runs learned about this app (its local map, `<repo-root>/.jira-bug/app-map.json`; `<repo-root>` = the main checkout, not the fix worktree — a worktree path still resolves to the main checkout's map). Each scenario
  names its screen — `nav_to <screen> <repo-root>/.jira-bug/setup.json` gets there in one call. A screen you had to reach by hand:
  `map_save screen <name> '[…steps from its parent…]' 'text:<what proves you are there>' [from=<parent>] <repo-root>/.jira-bug/setup.json`.
  **Reaching the app's home:** `nav_home <repo-root>/.jira-bug/setup.json` (one call): the First Open steps in the app's map (seeded on its
  first run from the FO library's view ids), then the app's own steps. `NAV=stopped layer=first-open-…` → get past FO by hand with
  `tap_id <id>` (ids from `ui`/the dump) and save the fix into this app's map: `nav_save_fo '[…]' <repo-root>/.jira-bug/setup.json`.
  `NAV=no-recipe` / `NAV=stopped layer=app` → find the app's own way once with `ui` + `tap_text`, then save it: `nav_save <repo-root>/.jira-bug/setup.json '["launch <applicationId>","back_if Ad","tap? Tiếp tục",…]'`
  so every later run of this project skips the splash/ad/onboarding walk.
  **The bug needs another app language:** `app_lang "Tiếng Việt|Vietnamese" <repo-root>/.jira-bug/setup.json` (one call: clears the app's
  data, picks the language in the First Open picker, goes home). The system locale (`cmd locale`, Android settings) does not change an
  Apero app's language — do not try it. App data is cleared, so build any saved data state after this call, not before.
- **Package:** `<applicationId>`. **Evidence dir:** `<repo-root>/.jira-bug/evidence/<TICKET>/`; name files `verify-<what>.png|mp4`
  (and `repro-<what>…` for the before state).
- **Target state:** <the screen + data state the bug needs>. **Code entry point:** <file:line / composable / event
  from the analysis that reaches it>. Go there by the shortest path; don't explore.
- **Scenarios (fixed — do not add any):** <numbered list copied from the Fix plan's "Cách kiểm chứng": each = state to reach + the
  one thing to look at + the on-screen text to crop to; at most 3 incl. one regression check>. Running a scenario that is not on this
  list (another font scale, another sheet, another locale "to be sure") is a bug — it is what doubled AAP857-113's verify.
- **Screenshots: only `bash <skill-dir>/assets/shot.sh <SERIAL> <session-id> <evidence-dir>/verify-<n>-<what>.png --text "<crop text>" [--pad 120] [--width 720]`**
  (one call = capture + crop + shrink + save; prints `SHOT=… W= H= KB= CROP=`). Read only files it wrote. No `screencap` +
  `sips`/`ffmpeg` by hand, no re-cropping the same shot. **Image budget: 2 per scenario + 2 for navigation** — over it → stop
  and report what you have. To find where you are, read the uiautomator text (`device-lock.sh exec … shell uiautomator dump`),
  not a screenshot.
- **Budget:** ~25 commands (`shot.sh` counts as one) or ~5 minutes without progress → `blocked` with where you are and what is missing.
  Never tap an ad's body (it opens a browser/store); close it with ✕/Skip or BACK. Stuck behind onboarding/ads after ~5 commands → `blocked`.
- **Report:** per scenario `PASS` / `FAIL` / `NOT REACHED` with the evidence path, plus `IMAGES=<n>/<budget>` and a navigation line: `NAV=ok` (the saved routes worked) or `NAV_SAVED=…` / `MAP_SAVED=…` (you found the way and saved it). A report with `NAV=no-recipe` and no `NAV_SAVED=` is incomplete — the A/B verifier of AIP396-461 reached home by hand and left the next run to do it again. Never claim a check you did not see.
