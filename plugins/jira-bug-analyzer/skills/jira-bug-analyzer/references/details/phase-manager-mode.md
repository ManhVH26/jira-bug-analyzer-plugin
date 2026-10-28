# Manager mode — PR-watch reconcile + KB-backfill + Deferred-ticket comment watcher (`--manager <PROJECT-KEY>`) — full text

> Read ONE section at a time: `bash <skill-dir>/assets/section.sh <skill-dir>/references/details/phase-manager-mode.md "<anchor>"`. The checklist and index live in `references/phase-manager-mode.md`.


> A standalone **maintenance loop**, NOT part of the fix pipeline (Phases 1–6). It does the
> post-fix housekeeping the fix flow defers: surface & fix **PR review comments**, **clean up
> worktrees** on merge/close, **backfill the knowledge base** for tickets that reached Done,
> **track the reopen outcome of `--auto` fixes** (Job D — the auto-fix quality metric), and
> **chủ động watch comment trên ticket deferred** (Job E — dev reply trên Jira với marker `@claude`/`@agent` thì Job E tự fetch + xử lý).
> **`--manager` runs ONE full reconcile pass and stops (v1.15.3).** Run it when there is something to
> reconcile — typically once after QA has verified a batch, before the next fix batch. Outcomes are
> read from the Jira changelog, so a run days later still records every done/reopen in between.
> `--manager --loop [interval]` opts into a recurring in-session loop (default `MANAGER_LOOP`) for teams
> that want review comments picked up within minutes.

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

## Optional loop (`--loop [interval]` only)
Default `--manager` is one pass: do NOT arm anything. Why: QA usually verifies in batches, so most
fires of a 10-minute loop find nothing and still cost a model turn over the whole session context.

Only when the invocation carries `--loop` (optionally `--loop 30m`; default `MANAGER_LOOP`):
1. Read `.jira-bug/manager-loop.json` at the target project root (untracked).
2. **Marker absent, OR its `board`/`phase` differ, OR its `cronId` is no longer live** → invoke the
   `loop` skill (Skill tool) with `args: "<interval> /jira-bug-analyzer --manager <KEY> @N"` (the inner
   command carries no `--loop`, so a fire never re-arms), then write the marker
   `{ "board": "<KEY>", "phase": "phaseN", "interval": "<interval>", "cronId": "<id>", "armedAt": "<ISO>" }`
   and announce *"manager loop armed — every <interval> for <KEY> @N (job <id>)"*.
3. **Marker present and live** (this entry IS a loop fire) → skip arming, run the precheck, then the pass.
4. **Stop:** `CronDelete <cronId>` (from the marker) + delete the marker, when the dev asks.

### Discord inbox in-session watcher — DEFERRED load
If env `JIRA_BUG_DISCORD_DEFER=1`, arm the Bash+Monitor file-watch on `.jira-bug/discord-inbox/`. **The full setup + lifecycle lives in `references/discord/manager-discord-jobs.md` → "Discord inbox in-session watcher"**. Load that file ONLY when env is set — otherwise skip entirely. If env unset: skip arm (silent, no log needed).

## Precheck — FIRST step of every LOOP fire (P7, v1.15.3)
A one-shot `--manager` (no `--loop`) skips this and runs the full pass. On a loop fire, before reading anything else (no Discord file, no ledger, no job text), run `bash <skill-dir>/assets/manager-precheck.sh "<root>" <KEY>` and act on its lines:
- `LOCAL=quiet` **and** `FULL_DUE=no` → run its `JIRA_JQL` once with `jira_search` (`limit: 1`). Total `0` → print ONE line `manager: no change (<KEY>, fire <n>)` and **end the pass** — do not run Jobs A–H.
- Anything else (`LOCAL=changed`, `FULL_DUE=yes`, or the JQL returns ≥ 1) → run the reconcile pass below. Jobs whose trigger did not change may still be skipped (e.g. `INBOX_NEW=0` → Job G/H have no input).
`FULL_DUE` forces a complete pass every `MANAGER_PRECHECK_FULL_EVERY` fires (default 6 ≈ 1 h at `MANAGER_LOOP`) so Job D's `held` re-checks (`REOPEN_WATCH_DAYS`) and orphan-Done scans still happen. Metric: the share of fires that end at the precheck (count `manager: no change` lines) — target ≥ 70 % on a quiet board.

## The reconcile pass (one per `--manager` run, or per loop fire under `--loop`)
Promotes the old **Init-5 reconcile** to a first-class mode. Read `.jira-bug/pr-watch.json` at the
target project root (untracked). For **each** entry, take an **atomic per-PR `mkdir` lock**
(`references/helpers/device-lock.md` pattern, keyed by PR — so this never collides with an
in-session cron fire), then `gh pr view <PR> --json state -q .state`:

| State | Action |
|---|---|
| `OPEN` | **Job A** — poll review comments newer than `commentsCursor`, authored by someone **other than the token owner**. Leave the entry. |
| `MERGED` / `CLOSED` | **Job B** (worktree cleanup); the ticket(s) the PR carried are judged by **Job D**, which hands newly-done ones to **Job C** → drop the entry. |
| unreadable | keep the entry, surface after repeated failures, move on (`troubleshooting.md`). |

Release the lock per entry. When `pr-watch.json` is empty afterward → `CronDelete` the watcher (if
any) and delete the file.

**No board-wide Done scan.** Done tickets reach Job C only through Job D (below), and only tickets the skill fixed (they have a ledger row). A board scan would also hit every teammate's hand-made fix — rows Job C cannot judge — and spend an `opus` agent on each, every full pass. Job D reads the changelog, so a PR whose watch entry was pruned, or a ticket resolved without a watcher, is still caught.

**Then: outcome scan → Job D, then Job C on what Job D marked done** — every ticket the skill fixed on this board/phase: `labels = auto-fixed` **plus** every ledger row with `status` ∈ `pr-created|done` (interactive fixes carry no label), whose outcome is still open (`pending`, or `held` inside `REOPEN_WATCH_DAYS`, `references/constants.md`) → **Job D** (done/reopen tracking). Independent of watch-file state.

**Then: Jobs E / F / G / H — DEFERRED load.** All four are Discord-related and ledger-driven:
- **Job E** (deferred-ticket comment watcher) — load if the ledger has `analyzed-deferred` rows for this project+phase.
- **Job F** (Discord resolve post) — load if env `LEARN_APP_DISCORD_BOT_TOKEN` is set.
- **Job G** (Discord inbox multipurpose dispatcher) — load if folder `.jira-bug/discord-inbox/` exists AND env `JIRA_BUG_DISCORD_DEFER=1`.
- **Job H** (user-override completion ack, v1.15.2+) — ALWAYS checked when env `LEARN_APP_DISCORD_BOT_TOKEN` is set: scan `.jira-bug/discord-inbox/*.json` for files WITHOUT `processed_at` that correspond to work parent session already finished this run → POST reply ack to `message_id` → mark + move to `processed/`. Closes the gap for inbox tasks executed outside Job G flow (user ask-reply override, inline execution of `out-of-scope` tasks, etc.).

**Full specs for all three live in `references/discord/manager-discord-jobs.md`** — load that one file when ANY condition above fires; skip entirely if none do (saves ~5K tokens on a plain Jobs-A-through-D tick).

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

## Job C — KB-backfill (unattended, notify-only; runs AFTER Job D)
Decide whether a fixed ticket's root cause belongs in the app-agnostic KB — **re-judging from the
record, not trusting a flag set during the fix**. Runs **even without `--auto`** (no ask gate);
just **notify** what changed.

**Input — only these tickets, never a board scan (v1.15.3):**
- tickets Job D moved to `status: done` in this pass, and
- ledger rows already `status: done` that have **no `kb` field yet** (one-time backfill of older rows).

A ticket without a ledger row (fixed by hand, outside the skill) is never judged. Once judged, the
row carries `kb=…`, so later passes skip it — Job C costs one `opus` agent per fixed ticket, once.

Per input ticket, dispatch `memory-keeper` (**opus**, `run_in_background: true`) with the
`kb-upsert` brief (`references/helpers/memory.md` → Actions / schemas):
1. Read the row: `bash <skill-dir>/assets/ledger.sh get <PROJ> <PHASE> <TICKET>` (`root_cause_slug` + `summary` + `files`).
2. **Re-judge `app_agnostic`** from the documented root cause: framework / SDK / platform-level
   (ads, billing, lifecycle, permissions, notifications, ExoPlayer/Media, OS quirks…) → **agnostic**;
   app-specific business logic / this app's screens & data → **not** agnostic. Do NOT rely on a flag
   the analyzer may or may not have set.
3. **Agnostic & absent from KB** → `kb-upsert knowledgebase/<category>/<slug>.md` (English, the
   schema in `memory.md`). **Already present** → `times_seen++` + add this app to `apps`. **Not
   agnostic** → no KB write.
4. Mark it judged: `bash <skill-dir>/assets/ledger.sh upsert <PROJ> <PHASE> <TICKET> kb=<category/slug|bump:<slug>|skip>` → quote `LEDGER_COMMIT=`.
5. **Notify** one line per ticket: `KB upsert <category>/<slug>` | `KB bump <slug> (times_seen=N)`
   | `KB skip (app-specific)`.

> **`[SHEET]` (google-sheet board):** Jobs A + B are unchanged (GitHub). **Job C** keys off the ledger's `status: done` rows for this project/phase instead of a Jira Done board-scan (there is no Jira). **Job D is `n/a`** — it depends on Jira `auto-fixed`/`auto-fix-reopened` labels + status history, which a sheet has none of; report `Job D: n/a (google-sheet board)` in the pass summary. (`references/google-sheet-board.md` → "Manager mode".)

## Job D — fix outcome tracking: done / reopened (unattended, notify-only)
Records what happened to every ticket the skill fixed — `--auto` (label `auto-fixed`) **and interactive** (ledger row `pr-created`/`done`, no label) — into the shared ledger, so a reopen or a done reaches memory whichever way the fix was made. The `--auto` subset is the quality signal for the autonomous fixer; the interactive subset is reported separately and never mixed into it. Runs every pass, no ask gate; all writes `[BGMEM]`. Nothing is pushed to the skill: the outcome is read from the Jira changelog on each pass, so a manager run days later still records every done/reopen that happened in between.
> **v1.15.3 — the status history is the source of truth, never the labels.** On AAP729 (16–22/10/2026) the `auto-fix-reopened` label caught 19 reopens while the Jira status history showed 30–31: a ticket recorded `held` early was never re-checked when QA reopened it days later. Labels are now only a convenience mirror of what this job reads from the changelog.
1. **Scan** (with `expand=changelog`, `[REST]`, `references/helpers/jira-rest-api.md`; optionally scoped to this `@N` phase): (a) `JQL: labels = auto-fixed` and (b) the keys of every ledger row in `project/<PROJ>/*/session/record_bug_status.md` with `status` ∈ `pr-created|done` and `auto_eval` ∈ `-|held` (interactive fixes). Ledger row missing for a ticket the board shows the skill fixed (a PR link in a skill comment) → write the row first (backfill), then judge it.
2. **Per ticket, judge the outcome from the changelog** (not the current status, not the labels):
   - **Fix time** = when the `auto-fixed` label was added (auto); for interactive fixes, the first `→ Resolved` after the ledger row reached `pr-created`.
   - **Done** (now `Closed`/`Done`, or `Resolved` with its PR merged, and no reopen after the fix time) → `ledger.sh upsert … status=done` (interactive rows keep `auto_eval: -`; the held/held-final rule below still applies to auto rows).
   - **Reopened after the fix** = a status transition AFTER the fix time from `Resolved`/`Closed`/`Reviewing`/`Done` to `Reopened`/`Request`/`In Progress`/`To Do`, **except** a flip by the same person who made the last done transition within `REOPEN_SELF_FLIP_MINUTES` (`references/constants.md`) — that is the fixer correcting the workflow (seen on AIP396-473: Resolved → In Progress → Resolved inside one minute), not QA → `ledger.sh upsert … status=reopened reopen_reason=<r> "reopen_note=<QA quote>"` for every ticket; auto tickets additionally get label **`auto-fix-reopened`** if missing, the `[AUTO-FIX EVAL]` comment's `reopen-outcome: reopened <date>` (`[REST]`) and `auto_eval: reopened`. Then classify the reason (step 3). A reopened ticket that the skill fixes again starts a new row cycle (`analyzing` …) and is judged again from its new fix time.
   - **Held** (no such transition) → ledger `auto_eval: held`. **`held` is NOT final**: re-check every pass until `REOPEN_WATCH_DAYS` (`references/constants.md`) after the fix time; only then mark `held-final` and skip.
   - Already `reopened` (or `held-final`) → skip.
3. **Reopen reason (R6) — read before you count.** For each newly reopened ticket, read the comments posted from 1 h before the reopen transition onward (QA explains there) and classify ONE reason: `fix-ineffective` (bug still there) · `regression` (fix broke something else) · `missed-case` (works on the repro path, fails on another state: network, rotation, background, another screen) · `design-mismatch` (behaves right, looks wrong vs Figma) · `requirement-changed` (QA/PO now want something different). Write it to the ledger row (`reopen_reason`, plus a one-line `reopen_note` quoting QA), append it to the `[AUTO-FIX EVAL]` comment, and when the ticket had a `kb_hit` or the fix is app-agnostic, add a `## Pitfalls` line to that `knowledgebase/<category>/<slug>.md` (`[BGMEM]`, memory-keeper `kb-upsert`) so the next analyzer reading it sees the trap. Unclear from the comments → `unknown` (never guess).
4. **Notify the quality roll-up** for the pass:
   - `auto-fix quality: <N> fixed · <R> reopened · reopen-rate <pct>% (status history)` and the same line for the `auto-fix-low` and `auto-fix-behavioral` subsets.
   - `baseline: non-auto bugs on <PROJECT> reopen-rate <pct>%` — same JQL with `labels != auto-fixed`, same changelog rule (or run `python3 scripts/reopen_report.py --project <KEY>` from the plugin repo, which prints both).
   - `reasons: fix-ineffective <n> · regression <n> · missed-case <n> · design-mismatch <n> · requirement-changed <n> · unknown <n>`.
   - `interactive fixes: <N> tracked · <D> done · <R> reopened · reopen-rate <pct>%` — separate line, never folded into the auto numbers.
   - Per newly-changed ticket: `reopened: <KEY> (<auto|interactive>, <reason>)` / `done: <KEY>`.
5. **Milestone check (R7).** Count auto-fixes with fix time on/after the v1.15.3 install date. Once that count reaches 50: compare the post-v1.15.3 reopen rate with the baseline and print ONE verdict line — `R7: auto reopen <a>% vs baseline <b>% → keep AUTO_SCOPE=ui-only` or `→ eligible: set setup.json autoScope="all" for <PROJECT>`. Never flip `autoScope` yourself; the dev decides.
> Eval queries for the dev anytime: `labels = auto-fixed AND status WAS Reopened` approximates the reopen count (it also counts a reopen that happened before the auto-fix, so prefer the script). Ledger `reopen_reason` gives the why.

KB stays English; per `[VN]` only dev-facing prompts (none here — Job C asks nothing) are Vietnamese.




## Honest expectation (state it; don't overpromise)
Only relevant with `--loop`: the loop rides on `CronCreate`, which is **not a background daemon** — it fires only
while a Claude session is open and idle (see `pr-merge-watcher.md` → "How the watcher actually
triggers"). So the loop auto-repeats the reconcile **only while this session stays open**; close the
session and it stops. Each fire reconciles everything reachable in one pass. For a loop that survives
closing the terminal, the dev uses `/schedule` (cloud cron) instead. State this; don't imply the
in-session loop is durable across restarts.

## Returns (per-pass summary, then end the pass)
Print a concise summary and end the pass (under `--loop`, do NOT `CronDelete` the loop — it keeps firing):
- 💬 **Review comments** handled (PR → applied / replied / parked-for-`--auto`).
- 🧹 **Worktrees** removed (merged/closed PRs).
- 📚 **KB**: upserted (`<category>/<slug>`), bumped (`<slug>`), skipped (app-specific).
- 🔎 **Orphan Done tickets** backfilled from the board scan.
- 📊 **Auto-fix quality (Job D):** `<total auto-fixed> fixed · <reopened> reopened · reopen-rate <pct>%` + any newly-reopened keys.
- 💬 **Deferred resumed (Job E):** `<K comment xử lý>` — `<X resumed> · <Y review-requested> · <Z clarify-posted>` + per-ticket key.
- ✅ **Discord resolve posts (Job F, `[DISCORD-DEFER]`):** `<N tickets posted>` + per-ticket key → PR link. Skip nếu env unset.
- 📥 **Discord Job G (`[DISCORD-MULTIPURPOSE]` v1.14.0+):** `<N files xử lý>` — `<ticket-resume> · <bulk-op> · <query> · <chat> · <meta-cmd> · <low-conf-clarify>`. ⏳ Pending confirms: `<open>` open, `<expired>` expired-this-pass. 💬 Thread cache: `<hits>/<fetches>`. Skip nếu folder không có hoặc env unset.
- ✉️ **Discord Job H (user-override ack, v1.15.2+):** `<N files acked>` — per-file `<message_id> → <ack msg_id>`. Skip nếu env unset hoặc không có file override.
- ⚠️ Anything surfaced (un-pushed memory, unreadable PR, arming failure).

Errors → `references/helpers/troubleshooting.md`. Invariants: `[REST]` (Jira reads/replies),
`[VN]` (dev prompts), `[OPTIONS]` (every ask), `[BGMEM]` (all memory I/O), `[VERIFY]` (re-verify on
behavior-changing review fixes), `[AUTO]` (Job A auto-apply scope).
