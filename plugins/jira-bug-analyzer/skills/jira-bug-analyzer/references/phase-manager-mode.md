# Manager mode — PR-watch reconcile + KB-backfill + Deferred-ticket comment watcher (`--manager <PROJECT-KEY>`)

> A standalone **maintenance loop**, NOT part of the fix pipeline (Phases 1–6). It does the
> post-fix housekeeping the fix flow defers: surface & fix **PR review comments**, **clean up
> worktrees** on merge/close, **backfill the knowledge base** for tickets that reached Done,
> **track the reopen outcome of `--auto` fixes** (Job D — the auto-fix quality metric), and
> **chủ động watch comment trên ticket deferred** (Job E — dev reply trên Jira với marker `@claude`/`@agent` thì Job E tự fetch + xử lý).
> **`--manager` ALWAYS runs as a recurring `/loop` — never a bare one-shot.** On entry the mode
> **self-arms a `/loop` (default every 10 min)** for this board+phase, then runs ONE reconcile pass;
> each loop fire = one more pass. The dev never has to re-run it manually — the loop keeps
> reconciling while the session is open (see the honest caveat).

Read this when the dispatcher resolves `--manager` — **the 3rd mode** (alongside single and multi), invoked the one way: `/jira-bug-analyzer --manager <PROJECT-KEY>`.
It REPLACES the "TBD PR-watch mode" the older docs pointed at — the watcher logic it drives lives
in `references/helpers/pr-merge-watcher.md`; the KB writes go through `references/helpers/memory.md`.

## Entry contract
- Reached via the SKILL.md **Mode dispatch** rule for `--manager`. Requires a `<PROJECT-KEY>`
  (the board) — absent → `[OPTIONS]`-ask for it (`[VN]`), never infer from the working dir.
- Init plumbing has already run (env preflight, memory sync, `setup.json` resolve incl.
  `baseBranch`, MCP liveness). **Manager mode does NOT pull the board for bugs, pick, analyze, or
  fix** — it skips the whole intake/fan-out.
- `--auto` modifier is read here: it governs **Job A** only (auto-apply unambiguous review fixes).
  **Job C is unattended regardless** of `--auto` (notify-only, no ask gate).
- `@N` phase token resolves the phase the same as elsewhere (used by Job C to find the right
  `session/record_bug_status.md`); absent → derive from the spec title, else `phase1`.

## Self-arm the `/loop` (MANDATORY — do this FIRST, before the reconcile pass)
`--manager` is never a bare one-shot. On every entry, **before** the reconcile pass, ensure a
recurring loop is armed for this board+phase — idempotently, via a marker file:

1. Read `.jira-bug/manager-loop.json` at the target project root (untracked).
2. **Marker absent, OR its `board`/`phase` differ from this run, OR its `cronId` is no longer live**
   → **arm the loop**: invoke the `loop` skill (Skill tool) with
   `args: "10m /jira-bug-analyzer --manager <KEY> @N"` (default cadence **10 min**; this routes
   through `/loop` → `CronCreate` `*/10 * * * *`, recurring). Then write the marker
   `{ "board": "<KEY>", "phase": "phaseN", "interval": "10m", "cronId": "<id>", "armedAt": "<ISO>" }`.
   Announce one line: *"manager loop armed — every 10 min for <KEY> @N (job <id>)"*.
3. **Marker present and matches** (this entry IS a loop fire or a re-invocation) → **skip arming**,
   just run the reconcile pass below. Never double-arm.
4. **Interval override:** default is 10 min. To change it, the dev deletes `.jira-bug/manager-loop.json`
   and re-invokes via `/loop <interval> /jira-bug-analyzer --manager <KEY> @N` — the next manager
   entry re-arms at the new cadence and rewrites the marker. **To stop the loop:** `CronDelete <cronId>`
   (from the marker) + delete the marker. Only stop when the dev asks.

### Discord inbox in-session watcher (`[DISCORD-MULTIPURPOSE]` v1.14.0+, multipurpose classifier dispatch)

> **Vì sao mở trigger + classifier:** v1.13.0 chỉ xử lý ticket-key prefix (regex `/^[A-Z][A-Z0-9]+-\d+\s/`) — reply không có key (`resolve conflict các PR`, `PR nào review?`, context dump) bị bỏ qua, user phải dán ticket key mọi lần. v1.14.0 pivot: bot trigger thành `@claude` mention HOẶC reply-quote vào bot message (bỏ regex narrow). Job G ACT STEP chạy LLM classifier inline → phân 5 intents → route theo bảng. Watcher pattern (Bash + Monitor + Agent subagent spawn) giữ nguyên v1.13.0; thay đổi chỉ ở classify + routing step. Session close (Ctrl+C) → watcher + subagents cùng chết (parent-child lifecycle giữ nguyên).

Trong CÙNG entry (sau step 2 ở trên), nếu env `JIRA_BUG_DISCORD_DEFER=1`:
1. `mkdir -p .jira-bug/discord-inbox .jira-bug/discord-inbox/processed` (idempotent).
2. Đọc `.jira-bug/discord-inbox-watch.json`:
   - **Marker tồn tại + `bash_shell_id` còn alive trong session hiện tại** (verify qua `BashOutput`) → skip arm.
   - **Marker absent HOẶC shell dead** → arm shell mới (step 3).
3. Load Monitor tool: `ToolSearch` với `query: "select:Monitor"`.
4. Start Bash background shell watcher:
   ```bash
   Bash tool với:
     command: 'cd "$PROJECT_DIR" && touch .jira-bug/.inbox-cursor && while true; do find .jira-bug/discord-inbox -maxdepth 1 -type f -name "*.json" -newer .jira-bug/.inbox-cursor -print 2>/dev/null; touch .jira-bug/.inbox-cursor; sleep 2; done'
     run_in_background: true
     timeout: unlimited
   ```
   Lưu `bash_shell_id` returned.
5. Arm Monitor tool subscribe shell đó:
   ```
   Monitor với:
     shell_id: <bash_shell_id>
     emit: mỗi stdout line = 1 notification (= 1 file path của inbox mới)
   ```
6. Ghi marker:
   ```json
   { "bash_shell_id": "<id>", "armed_at": "<ISO>", "project": "<cwd>" }
   ```
7. Announce 1 dòng: *"Discord inbox watcher armed in-session — shell=<id>, lifecycle=session (die khi Ctrl+C)"*.

**Lifecycle:**
- Shell chạy trong session's background → session live = shell live.
- User Ctrl+C `--manager` → session end → shell + Monitor chết → không có process ngầm nào tiếp tục.
- Session re-arm sau khi restart `--manager`.

**Khi file inbox mới xuất hiện (<5s):**
- Watcher shell print path lên stdout.
- Monitor tool nhận stdout line → session wake từ idle.
- Session đọc file inbox v1.14 → **Job G classify + route** (v1.14.0+):
  1. Nếu file có `thread_id` → load thread context qua Discord REST (xem `discord-classifier.md` → "Thread context loading").
  2. Call LLM classifier (parent session native, không spawn) với prompt từ `discord-classifier.md` → nhận `{intent, slug, target_set, confidence}`.
  3. Confidence < 0.7 → clarify branch (Discord reply options, mv file sang `processed/` với `job_g_outcome: low-conf-clarify`, KHÔNG dispatch).
  4. Confidence ≥ 0.7 → route theo intent (xem Job G bảng Act per intent dưới).
  5. Record vào `.jira-bug/active-resumes.json`: `{message_id, intent, confidence, slug, classified_at, token_estimate}`.
- **KHÔNG spawn `claude -p` nền.** **KHÔNG chạy inline Phase 3-6 block manager loop.** Agent subagent chạy song song với `--manager`.
- Concurrency: N action parallel (ticket-resume + bulk-op + query cùng lúc, giới hạn bởi system resources).

**Reply-quote vào bot message pending confirm:** nếu inbox file có `referenced_message_id` khớp `.jira-bug/pending-confirms/<id>.json` → **KHÔNG classify**. Thay vào đó: safety-gate.md Reply resolution flow (yes/no/ambiguous/timeout).

**Cron fallback vẫn giữ** (Job G full-scan ở mỗi `/loop` tick) — safety net cho file sót nếu Monitor miss (crash, race). Thêm: Expiry sweep `pending-confirms/` mỗi tick (xem `discord-safety-gate.md` → "Expiry sweep").

**Breaking v1.14.0 từ v1.13.0:** ticket-key regex trigger KHÔNG CÒN; bot phải update handler cho mention+reply triggers. Classifier LLM call thêm ~500 token/message (chấp nhận, track metric).

`JIRA_BUG_DISCORD_DEFER` chưa set → skip arm (im lặng).

> `--auto` does NOT change this — the loop is always armed; `--auto` only governs Job A's auto-apply.

## The reconcile pass (one pass per loop fire — then end the pass, the /loop re-fires)
Promotes the old **Init-5 reconcile** to a first-class mode. Read `.jira-bug/pr-watch.json` at the
target project root (untracked). For **each** entry, take an **atomic per-PR `mkdir` lock**
(`references/helpers/device-lock.md` pattern, keyed by PR — so this never collides with an
in-session cron fire), then `gh pr view <PR> --json state -q .state`:

| State | Action |
|---|---|
| `OPEN` | **Job A** — poll review comments newer than `commentsCursor`, authored by someone **other than the token owner**. Leave the entry. |
| `MERGED` / `CLOSED` | **Job B** (worktree cleanup) **+ Job C** (KB-backfill for the ticket(s) the PR carried) → drop the entry. |
| unreadable | keep the entry, surface after repeated failures, move on (`troubleshooting.md`). |

Release the lock per entry. When `pr-watch.json` is empty afterward → `CronDelete` the watcher (if
any) and delete the file.

**Then: board scan for orphan Done tickets** — a PR may have merged + had its entry already pruned
(by a prior run), or a ticket was resolved without an armed watcher. So also run a **read-only**
`jira_search` over the board's persisted `pullQuery` JQL, re-scoped to **Done/Resolved** tickets,
and for each one **not already represented** in this run's processed set → **Job C**. This is what
makes KB-backfill reliable independent of watch-file state.

**Then: `auto-fixed`-label scan → Job D** — a read-only `jira_search` for `labels = auto-fixed` (this board/phase) whose ledger `auto_eval` is still `pending` or may have changed → **Job D** (reopen-outcome tracking). Independent of watch-file/Done state.

**Then: deferred-ticket comment scan → Job E** — ledger-driven: pull mọi row `analyzed-deferred` (`[BGMEM]`), batch 1 `jira_search` để lọc ticket có `updated > <earliest commentsCursor timestamp>`, rồi fetch comment per ticket. Independent của PR state / Done state.

**Then: Discord resolve scan → Job F** (`[DISCORD-DEFER]`, opt-in) — ledger-driven: pull mọi row có `pr_url` present + `resolve_posted_to_discord != true` + `discord_defer_enabled: true` (`[BGMEM]`); per row POST *"✅ Resolved {KEY}: {PR_URL}"* vào `defer_channel_id` qua Discord REST + set `resolve_posted_to_discord: true` + `resolve_posted_at: <ISO>`. Full spec: `references/helpers/discord-resolve-watcher.md`. Skip toàn bộ nếu env `LEARN_APP_DISCORD_BOT_TOKEN` unset. Non-blocking: fail → log + retry tick kế (flag chưa set).

**Then: Discord inbox watcher → Job G** (`[DISCORD-DEFER]` v1.11+, opt-in) — scan folder `.jira-bug/discord-inbox/*.json` cho file `status: pending`; per file: classify intent + act (push-mode spawn hoặc inline resume) + move file sang `processed/`. Đây là consumer side của flow INBOUND inbox-write (producer = claudecode-discord bot ghi file qua `assets/discord-inbox-write.sh`). Chi tiết: Job G section bên dưới. Skip toàn bộ nếu folder không tồn tại HOẶC env `JIRA_BUG_DISCORD_DEFER` unset. Non-blocking: parse fail / spawn fail → log + move file sang `processed/` với `job_g_outcome: error` + continue.

## Job A — review-comment handling (interactive; `--auto` auto-applies the clear ones)
The mechanics live in `references/helpers/pr-merge-watcher.md` ("Review-comment poll" +
"Address review comments"). Manager mode is the orchestrator that runs them. Per PR, while `OPEN`:
1. **List** new comments (`author · file:line · body`) from reviews / line / issue endpoints.
2. **Per comment, draft** either a concrete code fix OR — if it's a question / ambiguous /
   non-actionable — a drafted reply asking for clarification (never guess an edit).
3. **Ask `[OPTIONS]`** (`[VN]`, per comment or batched): `Apply drafted fix` / `Edit draft` /
   `Reply only` / `Skip`.
4. **On `Apply`:** edit in the PR's worktree → **if behavior changed, re-run Phase 5 adb
   self-verify** (`references/phase5-verify.md` — `adb` only, **NOT mobile-mcp**) → push
   `--force-with-lease` to the PR branch → **reply on the thread** acknowledging → advance
   `commentsCursor` past everything handled.
- **Never auto-resolve a reviewer's thread** — that's the reviewer's call.
- **Multiple PRs needing adb re-verify** → serialize device access via
  `references/helpers/device-lock.md` (one device, one PR at a time).
- **`[AUTO]`:** apply the **unambiguous** fixes + re-verify automatically; **park** anything that is
  a question / ambiguous / would change scope as a drafted reply only, and **report** it in the
  end-of-run summary. Never silently edit on a judgment call.

## Job B — worktree cleanup (merge/close)
On `MERGED`/`CLOSED`: `git worktree remove <worktree>` (if still present), notify a one-line per-PR
summary (`merged` vs `closed without merge`), drop the entry. **No Jira writes** — the ticket was
already **Resolved at PR creation** (Phase 6); manager mode never resolves/worklogs/comments on merge.

## Job C — KB-backfill (NEW — unattended, notify-only)
The new responsibility: when a ticket reaches **Done** (PR merged, or board scan finds it
Resolved/Done), decide whether its root cause belongs in the app-agnostic KB — **re-judging from the
record, not trusting a flag set during the fix**. Runs **even without `--auto`** (no ask gate);
just **notify** what changed. All writes are `[BGMEM]` background via the `memory-keeper` agent.

Per Done ticket, dispatch `memory-keeper` (**opus**, `run_in_background: true`) with the
`kb-upsert` brief (`references/helpers/memory.md` → Actions / schemas):
1. Read this ticket's row in `project/<PROJ>/<PHASE>/session/record_bug_status.md` (its `root_cause_slug` + `summary` root cause + `files`).
2. **Re-judge `app_agnostic`** from the documented root cause: framework / SDK / platform-level
   (ads, billing, lifecycle, permissions, notifications, ExoPlayer/Media, OS quirks…) → **agnostic**;
   app-specific business logic / this app's screens & data → **not** agnostic. Do NOT rely on a flag
   the analyzer may or may not have set.
3. **Agnostic & absent from KB** → `kb-upsert knowledgebase/<category>/<slug>.md` (English, the
   schema in `memory.md`). **Already present** → `times_seen++` + add this app to `apps`. **Not
   agnostic** → skip (the session ledger already records it).
4. Update the ticket's ledger row `status → done` in `record_bug_status.md`.
5. **Notify** one line per ticket: `KB upsert <category>/<slug>` | `KB bump <slug> (times_seen=N)`
   | `KB skip (app-specific)`.

> **`[SHEET]` (google-sheet board):** Jobs A + B are unchanged (GitHub). **Job C** keys off the ledger's `status: done` rows for this project/phase instead of a Jira Done board-scan (there is no Jira). **Job D is `n/a`** — it depends on Jira `auto-fixed`/`auto-fix-reopened` labels + status history, which a sheet has none of; report `Job D: n/a (google-sheet board)` in the pass summary. (`references/google-sheet-board.md` → "Manager mode".)

## Job D — auto-fix quality tracking (reopen outcome; unattended, notify-only)
Fills in the reopen outcome for tickets `--auto` stamped `auto-fixed` (Phase 6) — the quality signal for evaluating the autonomous fixer. Runs every pass, no ask gate; all writes `[BGMEM]`.
1. **Scan** the board for `JQL: labels = auto-fixed` (optionally scope to this `@N` phase).
2. **Per auto-fixed ticket, judge the outcome from status history** (not the current status alone):
   - **Reopened after the auto-fix** (moved back to `Reopened`/`Request`/`In Progress`, or reopened by QA, on a date AFTER the `[AUTO-FIX EVAL]` resolve date) → add label **`auto-fix-reopened`**, update the `[AUTO-FIX EVAL]` comment's `reopen-outcome: reopened <date>` (`[REST]`), set the ledger row `auto_eval: reopened`.
   - **Held** (still Resolved/Done, or its PR merged, with no reopen) → set ledger `auto_eval: held`; no extra label needed (absence of `auto-fix-reopened` = held).
   - Already recorded (`auto_eval` is `held`/`reopened`, not `pending`) and unchanged → skip.
3. **Notify a one-line quality roll-up** for the pass: `auto-fix quality: <total auto-fixed> fixed · <reopened> reopened · reopen-rate <pct>%` — the headline metric for evaluating fix quality. Per newly-changed ticket also: `auto-fix reopened: <KEY>`. **Also roll up `--auto-low` subset separately** so dev can compare: `auto-fix-low quality: <total auto-fix-low> fixed · <reopened> reopened · reopen-rate <pct>%`. If low-conf reopen-rate is materially higher than overall, that is the signal `--auto-low` is too aggressive for this project.
> Eval queries for the dev anytime: `labels = auto-fixed` (all) vs `labels = auto-fix-reopened` (bad fixes) → overall reopen rate. `labels = auto-fix-low` vs `labels = auto-fix-reopened AND labels = auto-fix-low` → low-conf reopen rate.

KB stays English; per `[VN]` only dev-facing prompts (none here — Job C asks nothing) are Vietnamese.

## Job E — Deferred-ticket comment watcher (chủ động watch comment, re-analyze khi dev reply)

Khi fix flow defer một ticket (`auto-plan-pick.md` → "Khi defer"), ticket về `Request` + ledger row `analyzed-deferred` + comment `[VN]` giải thích. Trước đây dev phải re-run pipeline mới pick lại. Job E thay thế: chủ động poll comment trên ticket deferred, parse chỉ đạo của dev, re-analyze / chuyển `Reviewing` / hỏi lại.

### Scope + filter
- **Chỉ** ticket có ledger row `analyzed-deferred` (xem schema trong `references/helpers/auto-plan-pick.md` → "Ledger row schema").
- **Marker:** comment body chứa `@claude` HOẶC `@agent`. Regex: `\B@(claude|agent)\b` (word-boundary, case-insensitive). Tránh false-positive với email `@claude@domain`.
- **Nguồn comment:** Jira comment thường (dev reply trực tiếp trên Jira UI) HOẶC Jira comment do `references/helpers/discord-resume-handler.md` post hộ user khi dev reply trong Discord `#jira-bug-analyzer` (xem SKILL.md Golden Rule `[DISCORD-DEFER]`). Job E xử lý giống nhau — nguồn Jira là authoritative.
- **Author filter:** comment author ≠ token owner (`/myself.accountId`). Loại self-loop khi agent reply.
- **Cursor filter:** chỉ xét comment có `id > commentsCursor` của ledger row (missing/`0` → scan toàn bộ history).
- Nhiều comment khớp trong 1 tick → **chỉ xử lý comment ID lớn nhất** (dev biết comment sau override comment trước). Advance cursor skip qua các comment trung gian.

### Intent parsing (keyword, case-insensitive, Unicode-normalize với/không dấu)
- **Resume** — chứa 1 trong: `fix`, `proceed`, `tiến hành`, `tien hanh`, `làm`, `lam`, `sửa`, `sua`, `chạy`, `chay`, `go ahead`
- **Review** — chứa 1 trong: `won't fix`, `không fix`, `khong fix`, `close`, `đóng`, `dong`, `bỏ qua`, `bo qua`, `review`, `cần review`, `can review`
- **Ambiguous** (không match cả 2) → Clarify branch

Resume + Review cùng khớp → ưu tiên **Review** (an toàn hơn, dev vẫn có thể reply thêm `@claude fix` nếu đổi ý).

### Resume branch
1. **Xoá ledger row** `analyzed-deferred` cho ticket (`[BGMEM]`).
2. **Ghi `.jira-bug/clarify-<KEY>.md`** với nguyên văn comment body (Phase 3 Fix-5 Clarify sẽ đọc như clarify answer).
3. **Dispatch Phase 3 → 6** cho ticket đó:
   - `--manager --auto` → full auto. Phase 3 re-score với clarify-file. Score đủ → fix + PR. Không đủ → defer lại với reason mới + ghi report (ledger row mới, `commentsCursor` cũ KHÔNG kế thừa — ticket deferred lần này là context mới).
   - `--manager` interactive → post Jira comment `[VN]`: "Đã nhận chỉ đạo. Plan đề xuất: `<N>`. (a) Duyệt fix (b) Sửa plan (c) Defer lại". KHÔNG tự fix. Dừng. Tick sau Job E bắt reply tiếp.
4. **Advance `commentsCursor`** = comment ID vừa xử lý (ngay cả khi Phase 3 defer lại — vì comment đó đã được "tiêu thụ").

### Review branch
1. **Transition** ticket → `Reviewing` (`[REST]` `jira_transition` + readback verify `now=Reviewing`).
   - **Fallback** khi workflow không có status `Reviewing` (transition fail / không tìm thấy transition tên này): giữ nguyên `Request` + add label `needs-review` (`[REST]`) + log 1 dòng warning trong pass summary.
2. **Update ledger row:** set field `review_requested_by_comment: <commentId>` (giữ nguyên `analyzed-deferred` + các field khác, `[BGMEM]`).
3. **Post Jira comment** `[VN]` (`[REST]`): *"Đã nhận chỉ đạo không fix. Đã chuyển ticket sang **Reviewing** để team xem lại."* (Nếu fallback label: *"Đã nhận chỉ đạo không fix. Workflow không có status Reviewing, đã gắn label `needs-review` để team notice."*)
4. **Advance `commentsCursor`** = comment ID vừa xử lý.

### Clarify branch
1. **Post Jira comment** `[VN]` (`[REST]`) với options rõ ràng: *"Mình chưa rõ ý. Bạn muốn: (a) tiến hành fix — reply `@claude fix` · (b) defer thêm chờ info — không cần reply · (c) không fix, chuyển Reviewing — reply `@claude review`."*
2. **KHÔNG** transition status.
3. **KHÔNG** advance cursor — để tick sau bắt reply mới của dev.

### Idempotency
- `commentsCursor` chỉ advance **SAU KHI** action complete (post Jira ack / transition verify / Phase 3 dispatch). Crash giữa chừng → tick sau retry từ cursor cũ, idempotent vì ledger check vẫn thấy row `analyzed-deferred` (Resume branch) hoặc `review_requested_by_comment` null (Review branch chưa chạy).
- Trường hợp Resume branch đã xoá ledger row nhưng crash trước khi dispatch Phase 3 → tick sau không còn thấy ticket (ledger row mất) → **không retry**. Mitigation: xoá ledger row là bước CUỐI của Resume branch (sau khi `.jira-bug/clarify-<KEY>.md` đã ghi + Phase 3 đã kick off ở background).

### Mode compliance (`[AUTO]`)
- **`--auto`:** KHÔNG `AskUserQuestion` inline. Mơ hồ → Clarify branch (comment hỏi trên Jira — kênh async, không block loop). Resume branch dưới `--auto` tự fix hoặc tự defer theo rubric, không hỏi dev.
- **Interactive:** Jira comment là channel giao tiếp chính (dev có thể không ngồi trước terminal lúc /loop tick). Resume branch chỉ post plan đề xuất + options, không `AskUserQuestion` (session có thể idle). Tick sau sẽ bắt reply.

### `[SHEET]` (google-sheet board)
Job E **n/a** — sheet không có comment thread per bug. Report `Job E: n/a (google-sheet board)` trong pass summary.

## Job F — Discord resolve post (`[DISCORD-DEFER]`, opt-in, notify-only)
Chỉ chạy nếu env `LEARN_APP_DISCORD_BOT_TOKEN` set. Spec: `references/helpers/discord-resolve-watcher.md`.
1. Pull mọi ledger row có `pr_url` present + `resolve_posted_to_discord != true` + `discord_defer_enabled == true` (`[BGMEM]`).
2. Per row: build message *"✅ Resolved **{TICKET_KEY}**: {PR_URL}\n{summary}\nChangelog: {PR title}"* → POST qua Discord REST vào `defer_channel_id` (từ `assets/discord-roles.json`) → verify 200/201.
3. Success → set ledger `resolve_posted_to_discord: true` + `resolve_posted_at: <ISO>` atomic (`[BGMEM]`).
4. Failure → log + skip + retry ở tick kế (flag chưa set — idempotent).
5. Report một dòng per newly-posted: `discord-resolve: posted <KEY> → <PR link>`.

Race giữa 2 máy cùng chạy `--manager` cho project → cả 2 có thể post. Chấp nhận (Discord noise acceptable); atomic set flag ở BGMEM đảm bảo không post 3+ lần.

## Job G — Discord inbox multipurpose dispatcher (`[DISCORD-MULTIPURPOSE]` v1.14.0+)

Consumer side của flow INBOUND inbox-write (producer = `claudecode-discord` bot, qua `assets/discord-inbox-write.sh` schema v1.14). Lý do pivot v1.14.0 từ v1.13.0 (ticket-only regex): user báo *"muốn manager xử lý tất cả tình huống qua Discord, không chỉ ticket"* (observed 2026-10-19 — reply `resolve conflict các PR` không có ticket key bị bỏ qua + `learn-app` bot giành channel). Job G mở trigger thành `@claude` mention + reply-quote → LLM classifier phân 5 intents → routing table. Full specs: `references/helpers/discord-classifier.md` (classifier + taxonomy), `references/helpers/discord-safety-gate.md` (confirm gate), `references/helpers/discord-resume-handler.md` (ticket-resume branch).

**Skip toàn bộ** nếu folder `.jira-bug/discord-inbox/` không tồn tại HOẶC env `JIRA_BUG_DISCORD_DEFER` unset (= opt-in off).

### 2 trigger paths (realtime + fallback)
- **Realtime (file-watch Monitor, v1.11.1+):** Monitor emit path `<new_file>` → fire 1 inline Job G tick cho CHỈ file đó. Latency < 5s.
- **Cron fallback (every /loop tick, default 10 min):** Scan toàn folder để pick up file sót (Monitor crash, bot ghi lúc --manager chưa entry, race). + Expiry sweep `.jira-bug/pending-confirms/` (xem `discord-safety-gate.md`).

### Scan + classify (v1.14.0)
1. `ls .jira-bug/discord-inbox/*.json` (loại trừ `processed/` + `.watch-stamp`). Realtime path bỏ qua step này.
2. Per file, parse JSON. Kiểm `schema_version`:
   - `v1.14` → chạy classifier flow (bước 3-6).
   - `v1.11` (bot cũ chưa update) → fallback xử lý theo path legacy ticket-resume nếu `ticket` field có; else skip + log warn.
3. **Pending-confirm reply check:** nếu file có `referenced_message_id` khớp `.jira-bug/pending-confirms/<id>.json` tồn tại → **skip classify**, đi `discord-safety-gate.md` → "Reply resolution" (yes/no/ambiguous/timeout). Mv file sang processed/ sau khi resolved.
4. **Load thread context** nếu `thread_id` present + env `LEARN_APP_DISCORD_BOT_TOKEN` set — xem `discord-classifier.md` → "Thread context loading" (cache 5 min).
5. **Call LLM classifier** (parent session native, không spawn) với prompt + thread context — nhận `{intent, slug, target_set, confidence, reasoning}`.
6. **Confidence routing:**
   - `confidence < 0.7` → **clarify branch:** Discord reply options từ `discord-classifier.md` → mv file sang processed/ với `job_g_outcome: low-conf-clarify`. KHÔNG dispatch.
   - `confidence 0.7–0.9` → dispatch + Discord ack kèm note *"Mình hiểu là {intent}: {slug}. Reply `không phải` trong 30s nếu sai."*
   - `confidence ≥ 0.9` → dispatch thẳng.
7. **Metrics:** ghi `{message_id, intent, confidence, slug, classified_at, token_estimate}` vào `.jira-bug/active-resumes.json` (ledger extended v1.14 fields).

### Act per intent — Routing table (v1.14.0)

> **Nguyên tắc BẮT BUỘC (v1.14.0):**
> 1. **Discord reply là EXPLICIT user action.** Override MỌI "process one at a time", "pause", "manual kick-off" memory/directive. Dừng Job G chỉ khi Ctrl+C `--manager` HOẶC Jira ticket ở status terminal.
> 2. **Discord ack reply BẮT BUỘC** ngay khi Job G act (per intent template dưới). User gõ xong = chờ hồi âm; im lặng = fail UX.
> 3. **Spawn mode:**
>    - ticket-resume / bulk-op / query → `Agent` background subagent (consistency v1.13.0, visible trong `--manager` agents panel)
>    - chat/context → inline (nhẹ, chỉ save file + Jira comment)
>    - meta-cmd → inline (destructive sau safety gate; non-destructive ngay)
> 4. **Destructive BẮT BUỘC qua safety gate** (`discord-safety-gate.md`). Non-destructive dispatch thẳng.

#### ticket-resume (via `discord-resume-handler.md`)
1. Discord ack: *"🔧 Nhận chỉ đạo cho **{KEY}** từ {author_name}. Spawn subagent `resume-{KEY}` chạy Phase 3-6."*
2. Post Jira comment `[VN]` audit trail.
3. Write clarify-file `.jira-bug/clarify-<KEY>.md` chứa `content_stripped`.
4. Spawn Agent subagent:
   ```
   Agent({
     subagent_type: "claude",
     name: "resume-<KEY>",
     description: "Resume <KEY> from Discord defer",
     prompt: "/jira-bug-analyzer <KEY> --resume-from-defer --auto --auto-low\n\nContext từ Discord ({author_name}): {content_stripped}\n..."
   })
   ```
5. Ghi `agent_id` + `intent: ticket-resume` vào `active-resumes.json`.
6. `job_g_outcome: dispatched-subagent-ticket-resume`.

#### bulk-op (via `discord-safety-gate.md` → yes → subagent)
1. Enumerate targets (jira_search / gh pr list / ledger scan) → `target_count` + `target_preview`.
2. **BẮT BUỘC safety gate:** POST Discord confirm 60s per `discord-safety-gate.md`. Write pending file.
3. **Return.** KHÔNG spawn ngay. Monitor loop sẽ bắt reply.
4. Khi reply `yes` arrive (xem Reply resolution): spawn Agent subagent:
   ```
   Agent({
     subagent_type: "claude",
     name: "bulk-<slug>",
     description: "<action_summary>",
     prompt: "Thực hiện bulk op: <action_summary> trên <target_set>. Danh sách target: <target_preview>. Mỗi target thực hiện sequential hoặc parallel tuỳ action. Post Discord status mỗi 5 target done + summary cuối."
   })
   ```
5. `job_g_outcome: dispatched-subagent-bulk-op` + `agent_id`.

#### query (read-only subagent, no gate)
1. Discord ack: *"🔍 Đang tra cho {author_name}: {slug}..."*
2. Spawn Agent subagent:
   ```
   Agent({
     subagent_type: "claude",
     name: "query-<slug>",
     description: "Discord query: <question>",
     prompt: "Trả lời Discord query (read-only): <question>\n\nContext: thread history nếu có.\n\nSteps: identify data source (Jira / GitHub / ledger / active-resumes.json) → fetch → format reply plain text (không embed) → POST Discord vào channel_id={channel_id} reply-to message_id={message_id} qua LEARN_APP_DISCORD_BOT_TOKEN. KHÔNG ghi state. Report kết quả về parent."
   })
   ```
3. `job_g_outcome: dispatched-subagent-query` + `agent_id`.

#### chat/context (inline save)
1. Nếu `target_set.has_attachment: true` → download attachments vào `.jira-bug/discord-attachments/<ticket_ref or _unassigned>/<msg_id>/`.
2. Nếu `target_set.ticket_ref` có → post Jira comment `[VN]` *"Context từ Discord ({author_name}): {content_stripped}"* + attachment URLs.
3. Discord ack: *"📝 Đã lưu context cho {ticket_ref or 'session hiện tại'}."*
4. `job_g_outcome: inline-chat-saved`.

#### meta-cmd (phân sub-type)
- **Non-destructive** (list / status / show / reconcile now):
  1. Execute inline + build reply (xem list dưới).
  2. Discord ack kết quả.
  3. `job_g_outcome: inline-meta-<cmd>`.
- **Destructive** (stop / pause / cancel / clear / delete / kill):
  1. **BẮT BUỘC safety gate** per `discord-safety-gate.md`. Write pending.
  2. Reply `yes` arrive → execute inline + Discord ack done.
  3. `job_g_outcome: inline-meta-<cmd>-gated` HOẶC `cancelled-by-user`.

**Non-destructive meta-cmd supported (v1.14.0):**
| Cmd | Example | Reply content |
|---|---|---|
| `list subagents` | `@claude list subagents` | Dump `active-resumes.json` rows với `status: running` |
| `status` | `@claude status` | Pass summary current + pending-confirms count |
| `reconcile now` | `@claude reconcile now` | Trigger reconcile pass ngay (không chờ /loop tick) + ack |
| `show cursor <KEY>` | `@claude show cursor AAP729-3` | Dump ledger row ticket + commentsCursor |

**Destructive meta-cmd (sau gate):**
| Cmd | Side effect |
|---|---|
| `stop watcher` | Kill Bash watcher shell + Monitor subscribe. Session re-arm sau next --manager invoke. |
| `pause --manager` | Suspend reconcile pass. `/loop` tick vẫn chạy nhưng Job G skip. Resume: `@claude resume --manager`. |
| `cancel <agent_id>` | TaskStop background subagent theo `agent_id`. Discord ack + remove ledger row. |
| `clear active-resumes` | Reset `.jira-bug/active-resumes.json`. Dangerous — mất tracking. |

### Move file sau xử lý
- Append fields `processed_at: <ISO>`, `job_g_outcome: <outcome>`, `job_g_message: <action summary>`, `intent: <intent>`, `confidence: <0-1>`, `agent_id: <id or null>`.
- Move file → `processed/<same-name>.json` atomic (`mv`).
- Lỗi mv → file ở lại inbox + log; tick kế retry.

### Idempotency
- Mỗi `message_id` xử lý 1 lần — scan skip file có `processed_at`.
- Dedup `active-resumes.json` chặn spawn 2 subagents cho cùng `message_id`.
- 2 máy race — `mv` atomic first-come-first-serve.

### `[SHEET]`
Job G vẫn chạy (Discord-driven, không phụ thuộc Jira/Sheet source). ticket-resume + bulk-op cần Jira transition → n/a với Sheet (thay bằng update sheet row + Discord confirmation). Query + chat + meta-cmd unaffected.

## Honest expectation (state it; don't overpromise)
The self-armed `/loop` rides on `CronCreate`, which is **not a background daemon** — it fires only
while a Claude session is open and idle (see `pr-merge-watcher.md` → "How the watcher actually
triggers"). So the loop auto-repeats the reconcile **only while this session stays open**; close the
session and it stops. Each fire reconciles everything reachable in one pass. For a loop that survives
closing the terminal, the dev uses `/schedule` (cloud cron) instead. State this; don't imply the
in-session loop is durable across restarts.

## Returns (per-pass summary, then end the pass — the /loop re-fires automatically)
Print a concise summary and end the pass (do NOT `CronDelete` the manager loop — it must keep firing):
- 💬 **Review comments** handled (PR → applied / replied / parked-for-`--auto`).
- 🧹 **Worktrees** removed (merged/closed PRs).
- 📚 **KB**: upserted (`<category>/<slug>`), bumped (`<slug>`), skipped (app-specific).
- 🔎 **Orphan Done tickets** backfilled from the board scan.
- 📊 **Auto-fix quality (Job D):** `<total auto-fixed> fixed · <reopened> reopened · reopen-rate <pct>%` + any newly-reopened keys.
- 💬 **Deferred resumed (Job E):** `<K comment xử lý>` — `<X resumed> · <Y review-requested> · <Z clarify-posted>` + per-ticket key.
- ✅ **Discord resolve posts (Job F, `[DISCORD-DEFER]`):** `<N tickets posted>` + per-ticket key → PR link. Skip nếu env unset.
- 📥 **Discord Job G (`[DISCORD-MULTIPURPOSE]` v1.14.0+):** `<N files xử lý>` — `<ticket-resume> · <bulk-op> · <query> · <chat> · <meta-cmd> · <low-conf-clarify>`. ⏳ Pending confirms: `<open>` open, `<expired>` expired-this-pass. 💬 Thread cache: `<hits>/<fetches>`. Skip nếu folder không có hoặc env unset.
- ⚠️ Anything surfaced (un-pushed memory, unreadable PR, arming failure).

Errors → `references/helpers/troubleshooting.md`. Invariants: `[REST]` (Jira reads/replies),
`[VN]` (dev prompts), `[OPTIONS]` (every ask), `[BGMEM]` (all memory I/O), `[VERIFY]` (re-verify on
behavior-changing review fixes), `[AUTO]` (Job A auto-apply scope).
