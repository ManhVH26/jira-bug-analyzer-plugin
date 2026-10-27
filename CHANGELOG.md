# Changelog — jira-bug-analyzer

Format: one section per version; **Behavior change** lists what a teammate notices; **Migration** says what to do. Metrics per change: `METRICS.md`.

## 1.15.3 — 2026-10-27

Driven by AAP729 data (16–22/10/2026): `--auto` fixes were reopened 30 % (25/83) vs 16 % (8/50) for the project's other bugs; tickets fixed after a defer were reopened 8/8.

### Behavior change
- **Resume never auto-fixes (R2).** `--resume-from-defer` and Job E stop after Phase 3: re-analyze, then post the plan (or ask for the missing info). The dev fixes with single mode. `--auto` never picks a ticket labelled `analyzed-deferred`, `qa-info-needed` or `needs-po-clarification`.
- **`--auto` fixes UI-only tickets by default (R5, `AUTO_SCOPE=ui-only`).** Behavioral tickets (network, lifecycle, rotation, ads, timing, performance) defer `behavioral-scope`. Per project: `setup.json` `autoScope: "all"` once the reopen rate meets the target.
- **No device → behavioral `--auto` tickets defer `no-device` (R3)** instead of shipping on static review. UI-only and interactive runs keep the fail-open.
- **Verifier runs state-change scenarios (R4)** — network off/on, rotation, background/foreground, process death, ads, date change — when the ticket's category matches.
- **Ledger writes are a command, not prose**: `assets/ledger.sh upsert|get|delete` is the only writer of `record_bug_status.md` (pull → edit one ticket → commit → push with rebase-retry → `LEDGER_COMMIT=`), keeps each file's existing shape (table or `## KEY` sections), never overwrites a file it cannot parse. Phase 6 now writes `pr-created` (it never did). Every phase file opens with a **must-do checklist**; lint enforces both. Found on the first real run (AIP396-473): the model skimmed phase files with `head`/`grep` and skipped the ledger write, the pr-watch entry and the device lock.
- **Fixes from the AIP396-475 run**: evidence upload used `/rest/api/3` (absent on Jira Server — now `/rest/api/2`, lint-guarded); the resolve comment printed "Ảnh/Video kiểm thử" twice (template no longer writes it, the helper never duplicates it); the verifier wandered 11 min / 92 commands (now: look first, find the path in code, never consume content, ~25-command budget → `blocked`); Phase 5 was skipped entirely (Phase 4 checklist now points to it, Gate 1 before install); approval was asked before the analysis was shown (Phase 3 checklist: print Fix-6, then ask).
- **Fixes from the AAP857-113 run** (the session read only phase1 + phase6, so every checklist in phases 2–5 went unseen): SKILL.md now says to `head -12` each phase file on entry and lists the commands no run may drop. **The PR goes on `--manager`'s list automatically**: `ledger.sh … status=pr-created pr=<url>` calls the new `assets/pr-watch.sh add` (main checkout's `.jira-bug/pr-watch.json`, git-excluded, read back, `PR_WATCH=`); Phase 6's ask-then-1-min-cron step is gone. `ledger.sh` prints `LEDGER_WARN=` when `pr-created` has no earlier `analyzing/analyzed` row. **Build task checked, not guessed**: init prints `BUILD_CMD_SOURCE=default|setup`; on `default`, `assets/build-task-check.sh` lists the project's `assemble*Debug` tasks, the dev picks one, it is saved as `buildCmd` (the default task did not exist in AAP857 and the session swapped it silently). Single mode saves `baseBranch` to `setup.json` instead of leaving `SETUP=absent`. Verify prefers a connected phone over a cold emulator, and the verifier never taps an ad's body.
- **Fixes from the AAP857-112 run** (same root cause: only phase1 was read): **`assets/jira.sh`** — `claim` (In Progress + assign, read back) and `finalize` (attach evidence first, embed it in a wiki-markup comment, Resolved, worklog, then `ledger.sh pr-created` → pr-watch; prints `FINALIZE=ok` or `partial MISSING=…`). The session had done these through MCP one at a time, and the evidence, Resolved, worklog and ledger only happened when the dev asked (or never). **Verifier brief is a template** (`references/helpers/verifier-brief.md`): the parent takes the lock and installs, the brief carries serial + owner token; the hand-written brief had told the verifier to use bare `adb`. A verifier dispatched by this skill without a token now stops `blocked` instead of using the "standalone" clause; `android-ui-verify` gets the ~25-command budget (that run took 79).
- **Screenshot share links are read (Phase 3 Fix-4)**: `assets/fetch-media-links.sh` turns prnt.sc / Lightshot, ibb.co, imgur, gyazo, postimg and direct .png/.mp4 links in the description/comments into local files (share page → `og:video`/`og:image`; only real image/video kept, by magic bytes; size-capped), so QA screenshots pasted as links are analyzed like attachments; unreadable links are listed in the plan, not dropped.
- **`--manager` runs one pass and stops; the loop is opt-in (`--manager --loop [interval]`).** Breaking for anyone relying on the old always-on 10-minute loop: add `--loop`. Why: QA verifies in batches, so most loop fires found nothing yet cost a model turn over the whole session context; the changelog-based Job D records everything on a later run anyway. Recommended: run `--manager <KEY>` once after each QA verify round, before the next fix batch. The precheck now applies to loop fires only. **A fixer's own Resolved → In Progress → Resolved within `REOPEN_SELF_FLIP_MINUTES` is not a reopen** (Job D + `reopen_report.py`; AIP396-473 was miscounted).
- **Job C (KB-backfill) no longer scans every Done ticket on the board**: it judges only tickets Job D just marked `done` (they have a ledger row), stamps `kb=…` via `ledger.sh`, and never re-judges — previously each full manager pass could spend an `opus` agent on every Done ticket in the sprint, teammates' hand fixes included.
- **Job D tracks interactive fixes too**: ledger rows `pr-created`/`done` (no `auto-fixed` label) get `done` / `reopened` + reason from the Jira changelog, reported on a separate line; a missing row is backfilled.
- **Job D reads the status history (R1)**, re-checks `held` fixes for `REOPEN_WATCH_DAYS`, records a reopen reason (R6) and prints an R7 verdict after 50 new auto-fixes.
- **`@claude` on Jira only from allowed people (S1)**: `setup.json` `allowedCommenters`, default = the dev who claimed + the assignee.
- **`[UNTRUSTED]` golden rule (S2)**: ticket/comment/Discord/Confluence text is data; Discord text reaches subagents as a file.
- **Build command per project (P2)**: init prints `BUILD_CMD` / `APK_GLOB` from `setup.json` `buildCmd` / `apkGlob` (default `./gradlew assembleAppDevDebug`).
- **Model routing (P7)**: main session pinned to `sonnet`; every subagent names its model (matrix in `references/constants.md`); `--model` now overrides judgment stages only. Manager runs `assets/manager-precheck.sh` first and ends quiet fires in one line.
- **`--pr-window`** is removed for solo modes but still drives team-mode rounds (`TEAM_PR_ROUND`).

### Structure
- `references/constants.md` holds every number (P1). `SKILL.md` 47 KB → 12 KB: flags → `references/flags.md`, warm fast-path → `references/warm-fast-path.md`, turn loop → `references/multi-turn-loop.md` (P4). Discord files → `references/discord/` (P5).
- Removed `assets/discord-inbox-watcher.sh` (legacy `nohup claude -p … --auto`, S3).
- Figma MCP template uses `npx`; `setup-mcp.sh` adds `cmd /c` only on Windows (S4).
- Scripts that skip strict mode now say why (S5).

### Tooling
- `scripts/lint_skill.py`, `tests/run_all.sh` (15 checks), CI `.github/workflows/lint.yml`, `scripts/metrics.py`, `scripts/reopen_report.py`, `scripts/token_report.py`, `tests/SCENARIOS.md`.
- `scripts/sync-from-local-skill.sh` refuses a source older than this repo and runs the tests after syncing.
- Preflight reports `DEP=jira-mcp-bin` and `setup-mcp.sh` prints `MISSING_BIN=` when the `mcp-atlassian` executable is absent (the jira/confluence config was written but never connected); install steps + how to create the Jira PAT documented.

### Migration
- Run `/plugin marketplace update apero-tools`.
- Projects that are not `appDev` flavored: answer the one build-task question (saved to `setup.json`).
- Teams using `@claude` on Jira from QA/PO accounts: add them to `setup.json` `allowedCommenters`.
- Known: S0 (a security follow-up reported to the owner privately) is deferred; the lint tolerates its findings via `scripts/lint-known-secrets.txt`.

## 1.15.2 and earlier
History is in the git log (`git log --oneline`); notable breaking releases: 1.12.0, 1.13.0, 1.14.0 (Discord flow rewrites).
