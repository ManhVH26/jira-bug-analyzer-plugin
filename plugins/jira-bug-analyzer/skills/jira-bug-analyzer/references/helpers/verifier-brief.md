# Verifier brief — the template every on-device verifier is dispatched with

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
- **Package:** `<applicationId>`. **Evidence dir:** `<repo-root>/.jira-bug/evidence/<TICKET>/`; name files `verify-<what>.png|mp4`
  (and `repro-<what>…` for the before state).
- **Target state:** <the screen + data state the bug needs>. **Code entry point:** <file:line / composable / event
  from the analysis that reaches it>. Go there by the shortest path; don't explore.
- **Checks:** <numbered: what must be true after the fix, plus one regression check>.
- **Budget:** ~25 commands or ~5 minutes without progress → `blocked` with where you are and what is missing.
  Never tap an ad's body (it opens a browser/store); close it with ✕/Skip or BACK. Stuck behind onboarding/ads after ~5 commands → `blocked`.
- **Report:** per check `PASS` / `FAIL` / `NOT REACHED` with the evidence path; never claim a check you did not see.
