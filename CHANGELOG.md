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
