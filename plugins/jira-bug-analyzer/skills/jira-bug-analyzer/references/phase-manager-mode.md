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

### Discord inbox in-session watcher — DEFERRED load
If env `JIRA_BUG_DISCORD_DEFER=1`, arm the Bash+Monitor file-watch on `.jira-bug/discord-inbox/`. **The full setup + lifecycle lives in `references/helpers/manager-discord-jobs.md` → "Discord inbox in-session watcher"**. Load that file ONLY when env is set — otherwise skip entirely. If env unset: skip arm (silent, no log needed).

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

**Then: Jobs E / F / G — DEFERRED load.** All three are Discord-related and ledger-driven:
- **Job E** (deferred-ticket comment watcher) — load if the ledger has `analyzed-deferred` rows for this project+phase.
- **Job F** (Discord resolve post) — load if env `LEARN_APP_DISCORD_BOT_TOKEN` is set.
- **Job G** (Discord inbox multipurpose dispatcher) — load if folder `.jira-bug/discord-inbox/` exists AND env `JIRA_BUG_DISCORD_DEFER=1`.

**Full specs for all three live in `references/helpers/manager-discord-jobs.md`** — load that one file when ANY condition above fires; skip entirely if none do (saves ~5K tokens on a plain Jobs-A-through-D tick).

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
