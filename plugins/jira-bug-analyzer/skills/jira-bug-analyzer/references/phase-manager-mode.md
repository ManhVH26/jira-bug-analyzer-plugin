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

### Discord inbox file-watch arm (`[DISCORD-DEFER]` v1.11+, realtime Job G)

Trong CÙNG entry (sau step 2 ở trên), nếu env `JIRA_BUG_DISCORD_DEFER=1`:
- `mkdir -p .jira-bug/discord-inbox` + `mkdir -p .jira-bug/discord-inbox/processed` (idempotent, không fail nếu đã có).
- Arm Monitor tool (deferred — load qua `ToolSearch select:Monitor`) để watch folder cho file `.json` mới. Command gợi ý:
  ```bash
  while sleep 2; do find .jira-bug/discord-inbox -maxdepth 1 -name "*.json" -newer .jira-bug/discord-inbox/.watch-stamp -print 2>/dev/null; touch .jira-bug/discord-inbox/.watch-stamp; done
  ```
  (hoặc `fswatch -0 .jira-bug/discord-inbox` nếu máy có `brew install fswatch`).
- Monitor emit mỗi file mới (1 path per stdout line) như notification; nhận notification → fire 1 **inline Job G tick** chỉ cho file đó (xem Job G section), KHÔNG chờ cron tick kế.
- Latency file → spawn fix: typically <5s.
- Monitor crash / interrupt → cron tick 10 min vẫn pick up (defense-in-depth, Job G scan whole folder mỗi tick).
- Ghi marker `.jira-bug/discord-inbox-watch.json` `{ "monitor_shell_id": "<id>", "armed_at": "<ISO>" }` để tránh double-arm.
- `JIRA_BUG_DISCORD_DEFER` chưa set → skip arm (im lặng).

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

## Job G — Discord inbox watcher (`[DISCORD-DEFER]` v1.11+, inbound replies → push-mode spawn)

Consumer side của flow INBOUND inbox-write (producer = claudecode-discord bot, qua `assets/discord-inbox-write.sh`). Lý do pivot v1.11 từ bot-side spawn: tool-use của Skill `jira-bug-analyzer` hiện lù lù trong Discord channel (observed AAP729-42) — user không muốn. Job G kéo spawn về terminal `--manager`, Discord thuần relay. Full spec file schema + flow: `references/helpers/discord-resume-handler.md`.

**Skip toàn bộ** nếu folder `.jira-bug/discord-inbox/` không tồn tại HOẶC env `JIRA_BUG_DISCORD_DEFER` unset (= opt-in off).

### 2 trigger paths (realtime + fallback)
- **Realtime (file-watch Monitor, v1.11.1+):** Monitor armed ở self-arm section emit path `<new_file>` → fire 1 **inline Job G tick** cho CHỈ file đó (Scan step bỏ qua, dùng path thẳng từ event). Latency < 5s.
- **Cron fallback (every /loop tick, default 10 min):** Scan toàn folder (lệnh `ls` dưới) để pick up file sót (Monitor crash, bot ghi lúc --manager chưa entry, race). Logic sau đây áp dụng cho mỗi file tìm được.

### Scan + classify
1. `ls .jira-bug/discord-inbox/*.json` (loại trừ `processed/` + `.watch-stamp`) — mỗi file 1 reply đang pending. Realtime path bỏ qua step này, nhảy thẳng vào step 2 với path đã có.
2. Per file, đọc + parse JSON schema `v1.11` (`content_stripped` là intent payload).
3. Classify intent (regex trên `content_stripped`, case-insensitive, Unicode-normalize):

| Pattern (`content_stripped`) | Intent | Action |
|---|---|---|
| `^[A-C]$` (chỉ 1 chữ cái) | **plan-pick** | Resume với plan option được chọn |
| `^@claude\s+fix` hoặc `fix\|làm đi\|proceed\|tiến hành` | **resume-fix** | Resume fix với context hiện tại |
| `^@claude\s+review` hoặc `review\|chỉ review` | **review** | Chuyển sang Reviewing + Job E Review branch |
| `^close\s+` | **close** | Transition → `Won't Fix`/`Invalid` + comment lý do |
| anything else | **clarify** | Dev gửi info/câu trả lời/link → post Jira comment + re-analyze |

**Ambiguous → default `clarify`** (an toàn — re-analyze với context mới, không auto-fix mù).

### Act per intent
- **plan-pick / resume-fix / clarify (có đủ info để fix):**
  - **Push-mode default** (`JIRA_BUG_DISCORD_PUSH != 0`, default ON — giữ speed theo lựa chọn của user ở v1.10):
    1. Post Jira comment `[VN]` audit trail: *"Nhận chỉ đạo qua Discord từ `{author_name}`: `{content_stripped}`. Spawn fix session."*
    2. Write clarify-file `.jira-bug/clarify-<KEY>.md` chứa `{content_stripped}` + intent + plan-pick nếu có.
    3. Dedup check `.jira-bug/active-resumes.json` — ticket đã có pid alive → skip spawn + ack trong `job_g_outcome: skipped-dedup`.
    4. Concurrency cap check (default MAX=3, env `JIRA_BUG_DISCORD_PUSH_MAX`) — vượt → skip spawn + fallback qua Job E tick kế + `job_g_outcome: skipped-cap`.
    5. Spawn: `nohup claude -p "/jira-bug-analyzer <KEY> --resume-from-defer --auto" > .jira-bug/resume-logs/<KEY>-<ts>.log 2>&1 &` + record `{pid, spawned_at, log}` vào `active-resumes.json`.
    6. Post Discord confirmation vào `defer_channel_id` (reply vào `message_id` gốc nếu có): *"🚀 Đã spawn fix session cho {KEY} (pid {X}, ETA 5-30 min). Log: {LOG_PATH}"*.
    7. `job_g_outcome: spawned`.
  - **Legacy mode** (`JIRA_BUG_DISCORD_PUSH=0`): chỉ post Jira comment, không spawn. Job E tick kế pick up. `job_g_outcome: inline-resumed`.
- **review:** post Jira comment `[VN]` + chuyển ticket → `Reviewing`, xoá ledger row defer, Job E Review branch takeover. Discord confirmation: *"👀 Đã chuyển {KEY} sang Reviewing."* `job_g_outcome: review-queued`.
- **close:** transition → `Won't Fix` (hoặc status đóng gần nhất) + comment lý do + xoá ledger row. Discord: *"🚫 Đã close {KEY}: {lý do}."* `job_g_outcome: closed`.

### Move file sau xử lý
- Append field `processed_at: <ISO>` + `job_g_outcome: <outcome>` + `job_g_message: <action summary>` vào JSON.
- Move `<KEY>-<msg_id>.json` → `processed/<KEY>-<msg_id>.json` atomic (`mv`).
- Lỗi mv → file ở lại inbox + log; tick kế retry (`job_g_outcome: error` không ngăn retry nếu move fail).

### Idempotency
- Mỗi message_id chỉ xử lý 1 lần — scan skip file đã có `processed_at` field (phòng crash giữa chừng).
- Dedup `active-resumes.json` chặn spawn 2 lần cùng ticket.
- Race 2 máy cùng chạy `--manager` cho project: inbox file lock đơn giản — máy nào mv file trước thì xử lý; máy kia thấy file biến mất → skip.

### `[SHEET]`
Job G vẫn chạy — inbox là Discord-driven, không phụ thuộc Jira/Sheet source. `plan-pick`/`close` cần transition thì n/a với Sheet; thay bằng update sheet row + Discord confirmation.

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
- 📥 **Discord inbox (Job G, `[DISCORD-DEFER]` v1.11+):** `<N files xử lý>` — `<spawned> spawned · <inline> inline · <skipped> dedup/cap · <errors> error` + per-ticket key → outcome. Skip nếu folder không có hoặc env unset.
- ⚠️ Anything surfaced (un-pushed memory, unreadable PR, arming failure).

Errors → `references/helpers/troubleshooting.md`. Invariants: `[REST]` (Jira reads/replies),
`[VN]` (dev prompts), `[OPTIONS]` (every ask), `[BGMEM]` (all memory I/O), `[VERIFY]` (re-verify on
behavior-changing review fixes), `[AUTO]` (Job A auto-apply scope).
