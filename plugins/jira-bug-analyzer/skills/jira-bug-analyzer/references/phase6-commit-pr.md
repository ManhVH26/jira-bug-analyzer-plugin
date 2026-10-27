# Phase 6 — Commit & Create PR (the `[1COMMIT]` + PR + Jira finalize)

## Must-do checklist (read this even if you skim the rest)
Every line is a command or a check; the end-of-run report quotes each one's evidence (or says `chưa làm` + why). `<skill-dir>` = this skill's folder.
- [ ] One commit per ticket (`[1COMMIT]`); PR body with the Phase-3 + Phase-5 facts.
- [ ] Jira via `[REST]`: comment with evidence embedded, transition → Resolved, worklog — re-read to verify.
- [ ] `bash <skill-dir>/assets/ledger.sh upsert <PROJ> <PHASE> <TICKET> status=pr-created pr=<PR url> auto_eval=<pending|->` → quote `LEDGER_COMMIT=`.
- [ ] Add the PR to `.jira-bug/pr-watch.json` (Step 3) so `--manager` handles review comments, merge and cleanup.
- [ ] End-of-run report: one line per item above with its evidence — PR url, Jira status, worklog id, `LEDGER_COMMIT=`, pr-watch entry, device serial used.

> The flow's sixth and final phase, **extracted from the old Fix-13**: **… → Fix (phase4) → Verify (phase5) → Commit & PR (THIS phase).** It runs **only after Phase 5's GitHub diff review (no-change) + user-verify both passed** (`[VERIFY]` — never enter here before verify is green). It makes the real `[1COMMIT]`, **opens the PR (with a full Phase-3 + Phase-5 description), then attaches the PR + transitions Jira → Resolved in a BACKGROUND subagent**, logs work, and (optionally) queues the Discord review-request. **Under `--auto` the ENTIRE phase is itself dispatched as a background agent** so the main loop returns to Phase 1 (re-pull) without blocking — see the `[AUTO]` note below. **PR review-comment observation/fixing + worktree cleanup + KB-backfill are owned by `--manager` (`references/phase-manager-mode.md`); this phase only *arms* the watcher by writing `.jira-bug/pr-watch.json` — under `--auto` even the inline arming-with-cron (Step 2.3) is skipped, but the watch file is still written so manager mode can reconcile it.** Invariants: SKILL.md Golden Rules (`[1COMMIT]` `[REST]` `[VN]` `[OPTIONS]`). Shared blocks (PR round, PR watcher, Base branch) live in `references/run-blocks.md`.

## Entry contract
Arrives from Phase 5 (Gate 3) with: the diff **reviewed on the GitHub webview (dev said no-change)** + **user-verified**, in its worktree, with only a throwaway `wip: <TICKET> review` render commit on the branch. Also carried in: the **Phase-3 analysis** (root cause, scorecard, plan, files) and the **Phase-5 verification** (steps, expected, evidence) — both go into the PR description. `<BASE>` = the resolved `setup.json.baseBranch` (e.g. `develop` — never a hardcoded `main`; Base branch block in `references/run-blocks.md`).

> **`[AUTO]` (`--auto`) — this WHOLE phase runs as a BACKGROUND agent (`run_in_background: true`); every prompt auto-resolves to its default, no asks** (SKILL.md `[AUTO]` rule): Step 1 `Commit now` · Step 2 `Create PR` + worklog `30m` · **Step 3 Discord OFF unless `--discord` was passed** — a plain auto batch never posts; with `--discord` the background agent enqueues the opened PR to Discord (best-effort: missing `PR_DISCORD_CHANNEL_URL` is logged to the run report + skipped, never blocks the loop). **Step 2.3 inline cron arming is SKIPPED, but the watch file `.jira-bug/pr-watch.json` IS still written** so `--manager` can reconcile the PR later — PR review-comment handling + worktree cleanup + KB-backfill are owned by `--manager` (`references/phase-manager-mode.md`), run after the batch. Auto opens the PR but **never merges**. The main loop dispatches this background agent and **immediately returns to Phase 1 (re-pull)** — it never awaits the commit/PR/Jira round-trips. The background agent appends this PR to the run's `.jira-bug/auto-report-<date>.md` (✅ PRs opened) and surfaces any failure there (never blocks the loop).

> **`[SHEET]` (google-sheet board):** `[1COMMIT]` + `gh pr create` are UNCHANGED (per-bug PR heading = `<PROJECT>-SHEET-<N°>`). But there is **no Jira** — replace the "Attach PR + finalize Jira" subagent (Step 2 item 2) with a single ledger update: upsert `record_bug_status.md` → `status: done`, `pr: <link>` (local + shared, `[BGMEM]`). **No comment / worklog / transition, and the sheet is never written.** Defer / non-code reasons go to the ledger + chat `[VN]`, not a Jira comment. Full spec: `references/google-sheet-board.md` → "Commit & PR". Steps 1 + 3 (Discord) + the PR body are unchanged.

## Step 1 — Commit `[OPTIONS]` (`Commit now` / `Not yet`)
On **`Commit now`** → amend the `wip:` render commit into the real message per `[1COMMIT]`:
```bash
git -C <wt> commit --amend -m "fix(scope): … (TICKET)"
git -C <wt> push --force-with-lease
```
- Stage only that ticket's fix files (never `.jira-bug/*`). **No `wip:` commit may remain in history.**
- Multi/team: the **batch branch** already holds **one commit per ticket** — `[1COMMIT]`, never `--squash`; each ticket's commit is its own `fix(scope): … (TICKET)` (merged in at its Phase-5 Gate-1 `OK`).
- **`Not yet`** → stop; the fix stays in the worktree, ticket stays In Progress.

## Step 2 — Create PR & update Jira (the old Fix-13)
Ask confirmation first `[OPTIONS]` (`Create PR` / `Skip PR`); **`Skip PR`** → ticket stays In Progress, stop. On **`Create PR`**, finalize (MCP for reads / field updates it supports — description, summary, labels, fixVersions; `[REST]` for comments/worklog/transitions). **Ticket reaches Resolved at PR-creation — not at merge.**
1. **Open or update the PR** with the full description. **Multi: if the batch PR is already open** (an earlier ticket opened it), do NOT create a second PR — the new commit on the batch branch already updates it; just append this ticket's section to the PR body (`gh pr edit <pr> --body-file <body>`). **If no batch PR exists yet** (first verified ticket), open it: `gh pr create --base <BASE> --title "fix(scope): … (TICKET)" --body-file <body>` from the batch branch. Build `<body>` from the **PR-description template below**, carrying every Phase-3 + Phase-5 fact **per ticket**; the batch branch holds one commit per ticket — `[1COMMIT]`, never `--squash`; the body has one section per ticket.
2. **Attach PR + finalize Jira — in a BACKGROUND subagent** (`run_in_background: true`, haiku) so the main session isn't blocked on Jira round-trips. The subagent does, per ticket the PR carries, all via `[REST]` and re-reads to confirm:
   - **Post the fix comment WITH its evidence EMBEDDED — one comment, never a bare attachment.** `[VN]` prose + the PR link + **BOTH halves of the evidence from `.jira-bug/evidence/<TICKET>/`: the `repro-*` "before" (the bug happening, saved at Phase 3) AND the `verify-*` "after" (the fix working, saved at Phase 5)** — before+after side by side is what lets a reporter close the ticket without re-testing. Order is **attach first, comment second** (see the Resolve-comment block below). *(The `repro-*` files were already posted once at Phase 3's repro comment — re-attaching them here is deliberate: the resolve comment must stand on its own.)* **Uploading the evidence is only half the job**: an attachment that the comment body never references sits in the ticket's *Attachments* panel, invisible from the comment — the reporter opens the comment and sees a fix claim with no proof. **A resolve comment without an embedded evidence line is a BUG.** Applies to **every** run that has evidence — not just `--auto` (interactive `android-ui-verify` saves evidence too).
   - **Transition → Resolved** (discover the exact "Resolved"/"Resolve Issue" transition id — it differs by current status; from In Progress it is often a different id than from Request). Multi: resolve **every** ticket the PR carries.
   - **`[AUTO]` — stamp the auto-fix quality flag (ONLY under `--auto`).** So auto-fixes can be evaluated later, mark every ticket this `--auto` run resolves:
     - **Add the Jira label `auto-fixed`** (MCP field update — labels are MCP-writable; merge, don't clobber existing labels). This is the queryable eval anchor: `JQL: labels = auto-fixed` lists every auto-fixed ticket. **Under `--auto-low` ALSO add label `auto-fix-low`** (both labels — not either/or): the two labels together mean "autonomously fixed under the lowered threshold branch". Manager Job D tracks reopen-rate separately for `auto-fix-low` as the quality metric for low-conf fixes (`JQL: labels = auto-fix-low` vs `labels = auto-fix-reopened AND labels = auto-fix-low`).
     - **Post an `[AUTO-FIX EVAL]` comment** (`[REST]`, expect `HTTP 201`): one line — `resolved by /jira-bug-analyzer --auto on <YYYY-MM-DD> · PR <link> · reopen-outcome: pending (tracked by --manager)`. Keep it lean — the reopen outcome is the quality signal and is filled in later, NOT now.
     - **Ledger:** add `auto_eval=pending` to the `pr-created` write below (so a cross-session eval can aggregate without Jira). *(Interactive runs — no `--auto` — write `auto_eval=-`; only autonomous fixes are under evaluation.)*
   - **Log work** — time spent asked in the main session first `[OPTIONS]` (`30m` default / `1h` / `2h` / free-text), passed to the subagent (expect `HTTP 201`).
   - **Ledger → `pr-created` (EVERY run, interactive and `--auto`):** `bash <skill-dir>/assets/ledger.sh upsert <PROJ> <PHASE> <TICKET> status=pr-created pr=<PR url> auto_eval=<pending|->` → must print `LEDGER_COMMIT=`. Manager Job D reads these rows to record done/reopened later; a fix without this row is invisible to dedup and to the reopen metric.
   - **Verify all landed** — re-read: `worklog.total` increased, PR-link comment present, `status.name == "Resolved"`. Missing → report back so the main session tells the user (never claim success from a single `2xx`).
3. **Arm the review-comment watcher** — write `.jira-bug/pr-watch.json` (the durable trigger that `--manager` reconciles). **Under `--auto`: write the watch file but SKIP the cron + the ask** (manager mode is run after the batch). When NOT `--auto`: `[OPTIONS]` (`Watch` default / `Don't watch`) — write + verify `.jira-bug/pr-watch.json`, then a `durable: true` 1-min `CronCreate` firing `/jira-bug-analyzer --manager <KEY>` (best-effort in-session polling); confirm via `CronList`. File write fails → arming failed, tell the dev to re-run `/jira-bug-analyzer --manager <KEY>`. (PR watcher block / `references/helpers/pr-merge-watcher.md`; the full reconcile + KB-backfill lives in `references/phase-manager-mode.md`.)
3b. **Discord hooks — only when the ledger row has `discord_defer_enabled: true` (or the run carries `--resume-from-defer`):** follow `references/discord/phase6-discord-hooks.md`. Non-blocking; skip entirely otherwise.

### Resolve-comment template (`[VN]`, evidence EMBEDDED — the comment a reporter/QA actually reads)
Written for a non-technical reader (`[VN]`: có dấu, no code/stack/paths — those go to the dev in chat). Wiki markup, posted via `[REST]` v2. **The `Ảnh/Video kiểm thử` block is NOT optional whenever `.jira-bug/evidence/<TICKET>/` has files** — it is what proves the fix, and it is exactly the part that has been silently dropped in the past.

> **Skip-mode variant (`[REPRO_ON]=false`, SKILL.md `[REPRO]` + `[EVIDENCE]` exception).** When Phase 3 skipped the on-device repro (no `--repro` flag / NL intent), there is **no `repro-*` "before"** — only `verify-*` (after) may exist from Phase 5. The resolve comment MUST then carry an explicit skip-mode line so the reporter/QA understands why there is no "trước khi sửa" media:
> ```
> *Lưu ý:* Lần chạy này chạy ở chế độ mặc định (không yêu cầu tái hiện trên máy ở bước phân tích), nên không có ảnh/video "trước khi sửa". Fix đã được kiểm thử sau khi sửa — bằng chứng ở dưới.
> ```
> Place it right above the `*Ảnh/Video kiểm thử:*` block. If **neither** `repro-*` nor `verify-*` exist (default-skip + Phase-5 no-device fallback hit), replace the `*Ảnh/Video kiểm thử:*` block with:
> ```
> *Kiểm thử:* Fix chưa được xác minh trên thiết bị (không có máy sẵn sàng ở bước Phase 5). Diff đã được review trên GitHub + build xanh — chi tiết trong PR.
> ```
> and label the PR with `not device-verified` (phase5 no-device fallback). The Phase-6 background agent still posts this comment — a resolve with no evidence line + no skip-mode explanation is a BUG (silent "fixed, trust me" is the exact failure this template prevents).
```
🔧 Đã sửa — [TICKET_KEY]

• Vấn đề: <mô tả ngắn, đúng thứ reporter thấy>
• Nguyên nhân: <giải thích đơn giản, không thuật ngữ>
• Đã sửa: <thay đổi gì, theo ngôn ngữ người dùng>
• Đã kiểm thử: <thiết bị + bước kiểm thử + kết quả quan sát được>
• Lưu ý cho QA: <điều QA cần biết / phần cố ý giữ nguyên>  ← bỏ dòng này nếu không có
• Pull request: [PR #N|<pr_url>] (đang chờ review, chưa merge)
```
The `*Ảnh/Video kiểm thử:*` heading and the `!image!` / `[^video]` embeds are appended by `jira_evidence_comment` — do NOT write them in the body (writing them too produced the heading twice on AIP396-475).
Do **not** hand-roll the upload+embed — call the helper, which attaches first, embeds by media type, posts, and **verifies the embed actually rendered** (`references/helpers/jira-rest-api.md` → *Evidence — attach it AND EMBED it in the comment*):
```bash
jira_evidence_comment "<TICKET>" /tmp/<TICKET>-comment.txt .jira-bug/evidence/<TICKET>/*
```
- Images (`.png/.jpg/.webp`) embed inline as `!name!`; video (`.mp4`) renders as an attachment chip `[^name]` — video cannot be inlined in Jira.
- **Always use the filename Jira RETURNS from the upload**, not the local one (Jira renames collisions `shot.png` → `shot_1.png`; an embed on the stale name renders as dead literal text).
- The helper returns non-zero if the re-read `renderedBody` carries no `<img>`/attachment node → **the evidence did not land in the comment**: surface it to the dev and never report the ticket as evidenced.

### PR-description template (one section per ticket — carries Phase 3 + Phase 5)
PR title/description stay **English** (grep/tooling consistency — Golden Rule `[VN]`). One `## <TICKET-KEY> — <title>` block per ticket:
```markdown
## <TICKET-KEY> — <short title>
**Jira:** <ticket link>  ·  **Priority:** <P>  ·  **Scope:** <feature/screen>

### Root cause (Phase 3)
<root_cause_slug + 1–2 line explanation>

### Fix (Phase 3 plan → Phase 4)
<what the approved plan changed, in prose>

**Files changed**
- `path/to/File.kt` — <what & why>

### Verification (Phase 5)
- **Expected:** <acceptance / expected behavior after fix>
- **Steps:** <numbered on-device steps used to verify>
- **Result:** user-verified OK <(interactive)> — OR — adb self-verify pass <(`--auto`, no human card)>
- **Evidence:** <BOTH halves from `.jira-bug/evidence/<TICKET>/` — **`repro-*` (before, Phase 3)** and **`verify-*` (after, Phase 5)**; image for a static/visual bug, video for a dynamic/flow/animation/crash bug; reference each file by name + what it shows. Under `--auto` a pass MUST list ≥1 `verify-*` file.>
- **UI tickets (verified by `android-ui-verify`) additionally carry:** the **design-diff table** (device ⟷ Figma across layout/color/typography/alignment, ✅/❌ per axis with the value vs Figma), the **Figma node-id** + the **device⟷Figma side-by-side** images, and the **blast-radius result** (shared-UI symbols changed → adjacent screens checked → no regression; or "none — local change").

<!-- Confidence scorecard sum: <N>/100 -->
```
## Step 3 — Offer Discord review-request
**Offer Discord review-request** (opt-in, independent of the watcher-arming in Step 2 — a failure here must NOT block watcher arming). **Gate depends on flags:**
- **`--discord` passed** → auto-yes, **skip the ask**, always enqueue (this is the flag's whole point). Under `--auto` this is the ONLY path that reaches Step 3's enqueue — without `--discord`, `--auto` skips it entirely (Discord OFF).
- **No flag, interactive** → ask *"Post review request to Discord via Cowork? [Y/n]"* (default **Y**).
- **No flag, `--auto`** → skipped (Discord OFF, per the `[AUTO]` note above).

On enqueue, post the PR via the `pr-discord-review-request` skill (Skill tool — auto-resolves any repo), or run its writer directly from user scope:
   ```bash
   ENQ="$(ls .claude/skills/pr-discord-review-request/scripts/enqueue-pr-review.cjs 2>/dev/null \
     || echo "$HOME/.claude/skills/pr-discord-review-request/scripts/enqueue-pr-review.cjs")"
   node "$ENQ" --pr <PR> --pr-url <url> --status-api-url repos/<owner>/<name>/pulls/<PR> \
     --title "<title>" --base <BASE> --branch <branch> --repo-slug <owner>__<name> \
     --channel-url "$PR_DISCORD_CHANNEL_URL" --mention "@terasofts" --ticket-key <KEY> --ticket-url <url>
   ```
   Channel from `PR_DISCORD_CHANNEL_URL` (`.claude/.env`) or ask once. Cowork posts on its own schedule — never claim "posted to Discord", only "queued for Cowork". Multi → enqueue once per round PR (pass the primary ticket key).

> The fix worktree is kept until the PR merges/closes (review fixes); **`--manager` removes it then** (`git worktree remove ../learnova-<Ticket-Id>` / `../learnova-batch-<YYMMDD>`). **Under `--auto` the loop does NOT clean up worktrees — `--manager` (`references/phase-manager-mode.md`) owns review-comment handling + worktree cleanup + KB-backfill; the looper just leaves the worktree in place and moves on. Run manager mode after the batch.**

## Multi/team
ONE batch PR, opened/updated per ticket — NOT a windowed round (Per-ticket review & batch-merge block, `references/run-blocks.md`). Each ticket, the instant its Phase-5 diff review is `OK` and its user-verify passes, has already had its `[1COMMIT]` merged into the **batch branch `phaseX/fixbug/batch-<YYMMDD>`** (at Gate 1 `OK`). This phase then, per ticket: **opens the batch PR if it doesn't exist yet, else lets the new commit update the already-open batch PR** (append that ticket's section to the PR body), and runs steps 2–7 for THAT ticket only (resolve it, log its work, arm the watcher once on first open — **interactive only, skipped under `--auto`**, Discord enqueue once). **Never wait for other tickets.** A ticket that fails review/verify loops back to its own fixer (Phase 4/Phase 3) and joins the batch PR later when it passes.
