# Changelog — jira-bug-analyzer

Format: one section per version; **Behavior change** lists what a teammate notices; **Migration** says what to do. Metrics per change: `METRICS.md`.

## 1.15.3 — 2026-10-27

Driven by AAP729 data (16–22/10/2026): `--auto` fixes were reopened 30 % (25/83) vs 16 % (8/50) for the project's other bugs; tickets fixed after a defer were reopened 8/8.

### Behavior change
- **Resume never auto-fixes (R2).** `--resume-from-defer` and Job E stop after Phase 3: re-analyze, then post the plan (or ask for the missing info). The dev fixes with single mode. `--auto` never picks a ticket labelled `analyzed-deferred`, `qa-info-needed` or `needs-po-clarification`.
- **`--auto` fixes UI-only tickets by default (R5, `AUTO_SCOPE=ui-only`).** Behavioral tickets (network, lifecycle, rotation, ads, timing, performance) defer `behavioral-scope`. Per project: `setup.json` `autoScope: "all"` once the reopen rate meets the target.
- **No device → behavioral `--auto` tickets defer `no-device` (R3)** instead of shipping on static review. UI-only and interactive runs keep the fail-open.
- **Verifier runs state-change scenarios (R4)** — network off/on, rotation, background/foreground, process death, ads, date change — when the ticket's category matches.
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

### Migration
- Run `/plugin marketplace update apero-tools`.
- Projects that are not `appDev` flavored: answer the one build-task question (saved to `setup.json`).
- Teams using `@claude` on Jira from QA/PO accounts: add them to `setup.json` `allowedCommenters`.
- Known: S0 (a security follow-up reported to the owner privately) is deferred; the lint tolerates its findings via `scripts/lint-known-secrets.txt`.

## 1.15.2 and earlier
History is in the git log (`git log --oneline`); notable breaking releases: 1.12.0, 1.13.0, 1.14.0 (Discord flow rewrites).
