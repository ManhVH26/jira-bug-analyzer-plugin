# Phase 4 — Fix workflow (worktree → fix by the plan → build app to verify compilation)

## Must-do checklist (read this even if you skim the rest)
Every line is a command or a check; the end-of-run report quotes each one's evidence (or says `chưa làm` + why). `<skill-dir>` = this skill's folder.
- [ ] `git fetch` then a worktree from `origin/<BASE>` — never edit the main checkout.
- [ ] Change only what the approved plan says (`references/helpers/fix-code-rules.md` R1–R22).
- [ ] `<BUILD_CMD>` green before Phase 5; quote the build result.

> The flow's fourth phase: **Intake (phase1) → Source-of-truth capture (phase2, background) → Analyze (phase3) → Fix (THIS phase).** It starts from an **approved plan** (Phase 3 Fix-8), fixes by that plan in an isolated worktree, and **builds the app (`<BUILD_CMD>`) to verify it compiles** — a green build is Phase 4's done gate. Verify-on-device / PR / Jira are NOT in this phase (Phase 5 + Phase 6). The **analyze** steps (claim → fetch → media → root-cause + plan → clarify → approval) live in `references/phase3-analyze.md`. The other named blocks (Post-analysis dedup · In-Progress lock · Pre-fix context · Fix worktree · Multi fan-out · Post-fix gates · PR round · PR watcher) live in `references/run-blocks.md` — keep it loaded. The **Pull & list by category** block lives in `references/phase1-init-multi-mode-without-team.md` (re-pulls reuse it). Invariants are SKILL.md Golden Rules (`[CLAIM]` `[VERIFY]` `[1COMMIT]` `[VN]` `[OPTIONS]` `[REST]`). SOT ground truth is resolved via the **Context-source rule** in `references/phase3-analyze.md` (memory if ready, else the dev's provided refs — never block on the background capture).

## What Phase 4 needs to do (exactly)

Phase 4 takes an **approved plan** (from Phase 3) and turns it into a **green build** — nothing more:

1. **Create the fix worktree** — isolated, **`git fetch origin` fresh first**, then branched off the **latest `origin/<BASE>`** (Fix-10) — the same ref Phase 3 analyzed; always newest, never a stale local ref.
2. **Fix strictly by the approved plan** — implement the change; never deviate (Fix-11). Plan wrong mid-fix → STOP + re-confirm.
3. **Build the app to verify compilation** — run `<BUILD_CMD>` from the worktree (Fix-12). `<BUILD_CMD>` / `<APK_GLOB>` = the `BUILD_CMD=` / `APK_GLOB=` lines init printed (from `setup.json` `buildCmd` / `apkGlob`, else `DEFAULT_BUILD_CMD` / `DEFAULT_APK_GLOB` in `references/constants.md`). If the task does not exist in this project (`./gradlew tasks --all` has no match), ask the dev once `[OPTIONS]` for the right task and save it with `assets/setup-json.sh merge-set .jira-bug/setup.json buildCmd=<cmd>` (local + shared, like `baseBranch`).
4. **Green build → Phase 4 is done** → hand the built fix to **Phase 5**. **Red build → back to step 2**, fix the error, re-build.

**Exception (Fix-9):** if the plan's root cause is **not fixable in app code** (config/console, backend, env/device, works-as-designed, can't-reproduce) → do NOT branch/fix/build; post the `[VN]` non-code comment instead and stop.

Phase 4 does **NOT** run-on-device, verify, code-review, commit, PR, or touch Jira — those are **Phase 5** (`references/phase5-verify.md`) and **Phase 6** (`references/phase6-commit-pr.md`).

**Multi mode:** one background **fixer agent per approved ticket** (Multi fan-out block) does exactly steps 1–4 in its own worktree and returns `fixed-in-worktree` (green) / `blocked` (red or wrong-plan). **The instant a fixer returns green, that ticket enters Phase 5 immediately — its diff is shown + the browser auto-opened, and on `OK` it is merged into the batch branch first, without waiting for any other ticket** (Per-ticket review & batch-merge block). The full multi-mode turn loop that drives the fan-out (pull → pick → analyze → approve → fix → per-ticket review & batch-merge → re-pull) lives in **SKILL.md → "Multi mode — the turn loop"**.

---

## Single-ticket workflow — fix steps (Fix-9 … Fix-12; then Phase 5 → Phase 6)

> Fix-1 … Fix-8 (claim → fetch → media → root-cause + plan → clarify → approval) are in `references/phase3-analyze.md`. This phase begins once the plan is approved.

**Fix-9 — Non-code resolution** (comment `[VN]`, then stop). When the bug isn't fixable by app code — config/console (Remote Config, ad-unit IDs, flags, CMS), backend/server, stale build/env/device, works-as-designed/duplicate, or cannot-reproduce after analysis+clarification — do NOT branch/code. Post a plain `[VN]` comment a non-technical reader understands (no code/stack/paths in the comment — those go to the dev in chat), via REST, verify `HTTP 201`:
```
🔍 Kết quả kiểm tra — [TICKET_KEY]

• Vấn đề: <mô tả ngắn gọn, dễ hiểu>
• Nguyên nhân: <giải thích đơn giản, không thuật ngữ>
• Vì sao chưa thể sửa bằng code: <lý do — ví dụ: lỗi nằm ở cấu hình quảng cáo trên hệ thống, không nằm trong code app>
• Cần làm tiếp theo: <hành động + ai phụ trách — ví dụ: nhờ tester cài lại APK mới nhất; hoặc team ASO cập nhật ID quảng cáo trên Firebase Console>
```
After it lands: **no code, no PR, NOT transitioned to Resolved.** It was claimed In Progress → ask `[OPTIONS]` (`Leave In Progress (note added)` / `Move back to <status>` / `Reassign to <team/person>`). Multi → mark `commented` (not `done`), skip, drain the rest. Tell the dev the full tech detail in chat.

**Fix-10 — Create fix worktree.** Verify still In Progress (re-apply `[CLAIM]` if not). **First check Fix-9:** plan's root cause not fixable in app code (Files = "none") → go to Fix-9 instead, don't branch. **Then resolve `<BASE>`:** it is the `setup.json.baseBranch`. If it's still absent at this point (`BASEBRANCH=none` was emitted at init and not yet answered) you **MUST** run the **Base branch** ASK gate (`references/run-blocks.md`) FIRST — `AskUserQuestion`, never branch off a hardcoded `origin/main`, never silently resolve. Only with `<BASE>` set do you create the isolated worktree (Fix worktree block — fetch + branch off **`origin/<BASE>`** (e.g. `origin/develop` for AIP686), NOT `origin/main`; the `phaseX/` prefix = the **phase resolved at the Source-of-truth gate** (`@N` arg or spec-title-derived — SKILL.md Phase resolution; e.g. `phase3/fixbug/...`), NOT a blind `phase1`).

**Fix-11 — Investigate & fix (by the plan):** pre-fix context import (Pre-fix context block — read the SOT as ground truth via the Context-source rule: the phase digests if the background capture has landed, else the dev's provided refs) → follow the approved Fix-8 plan **verbatim** → search for the source files → implement. Plan wrong mid-fix → STOP + re-confirm, don't deviate. On clean compile, proceed to Fix-12 to build the app.

**`[CLEANFIX]` — write the fix to the code-rules.** Before and while editing, follow **`references/helpers/fix-code-rules.md`** (the maintainable clean-code ruleset, `R1`–`R22`): a bug fix is **surgical** — smallest diff for the root cause (R1–R4), fix the cause not the symptom (R5–R7), match surrounding style with **no new comments** (R8–R10), respect Clean-Architecture/MVI layers + design-system + TeraKit primitives (R11–R13), introduce **no regression** (R14–R17), leave it hygienic (R18–R22). This is exactly what the Phase-5 review gate checks the diff against, so violating a rule just bounces the fix back here — write it clean the first time.

**Fix-12 — Build the app to verify compilation, then hand off to Phase 5 (Verify).** Phase 4's done gate is a **green app build**, not just an editor/compiler check. After implementing the fix, run the `appDev`/`debug` assemble from the worktree to prove the app actually compiles **and** builds:
```bash
<BUILD_CMD>
```
- **Build succeeds (APK produced)** → Phase 4 is **done**. The built APK + warm shared Gradle cache carry straight into Phase 5 (no rebuild — Phase 5's install reuses this APK). Hand the built fix in its worktree to **Phase 5** (`references/phase5-verify.md`): review the diff on GitHub → install this APK + user-verify (adb self-verify only on `--auto`).
- **Build fails (compile/build error)** → back to Fix-11 to fix the error, then re-build. Never hand a red build to Phase 5.

Run the assemble in the background (`run_in_background`, from the worktree, no device) so it doubles as the pre-warm — but **wait for it to finish green** before declaring Phase 4 done; never start a second concurrent build of the same worktree. Phase 5 (verify+review) then hands the approved fix to **Phase 6** (`references/phase6-commit-pr.md`) for the `[1COMMIT]` + PR + Jira finalize. Any later gate's "needs update" loops back here to Fix-11, re-builds, then re-enters Phase 5.

> Fix-13 (Create PR & update Jira) moved to **Phase 6** (`references/phase6-commit-pr.md`) — it runs after Phase 5's code-review passes and the `[1COMMIT]` is made. The fix worktree is kept until the PR merges/closes (review fixes); the watcher removes it then.
