# Jira Bug Analyzer — Claude Code Plugin

A Claude Code plugin that packages the **jira-bug-analyzer** skill: a harness-loop agent
that fetches Jira bug tickets via MCP, analyzes attached images/videos, scores each bug
against a confidence rubric, verifies fixes on-device via `adb`, opens PRs, and learns into
a shared GitHub memory.

Modes: **single** (fix one ticket by key), **multi** (pull the board, fix several together),
**manager** (`--manager` — PR review comments, worktree cleanup, KB backfill), **team** (`--team`).

The board can also be a link-shared **Google Sheet** instead of Jira (`--google-sheet <URL>`,
read-only; status is kept in the memory ledger).

## Install

Run both inside Claude Code — no repo access needed, this marketplace is public:

```bash
/plugin marketplace add hung-apero/jira-bug-analyzer-plugin
/plugin install jira-bug-analyzer@apero-tools
```

Both steps are required: `@apero-tools` is a *marketplace name*, and `marketplace add` is
what maps that name to this repo. There is no one-step `/plugin install owner/repo` form.

Teams can skip step 1 by committing the marketplace into a project's `.claude/settings.json`
— teammates are then offered the plugin automatically on checkout:

```json
"extraKnownMarketplaces": {
  "apero-tools": {
    "source": { "source": "github", "repo": "hung-apero/jira-bug-analyzer-plugin" }
  }
}
```

If you already keep a hand-copied `jira-bug-analyzer` in `~/.claude/skills/` or a project's
`.claude/skills/`, **delete it** — it shadows the plugin and silently drifts out of date.

Update later with `/plugin marketplace update apero-tools`.

Then invoke the skill:

```
/jira-bug-analyzer AIP686-179     # single mode (ticket key)
/jira-bug-analyzer AIP686         # multi mode (project/board key)
/jira-bug-analyzer AIP686 @3      # multi, phase 3 — @N unlocks project-level spec discovery
/jira-bug-analyzer AIP686 @3 --auto
/jira-bug-analyzer --manager AIP686
/jira-bug-analyzer --google-sheet <SHEET_URL> --project AIP686   # sheet board
```

### Source of truth (spec / Figma)

The skill resolves the phase's spec + Figma **by itself** — it asks Jira, it does not ask you
to paste links. Given `@N` it reads the project's fixVersions to resolve the phase, then mines
the phase Epic, a project-wide link sweep, and the project description (≤4 MCP calls, cached
per phase). Confluence search is the fallback.

Interactive runs **confirm** the hit with a one-tap prompt before adopting it; `--auto` never
asks and instead **self-verifies** the candidate (fetches the page, checks it names this project
and this phase, rejects stubs) — and defers the ticket as `no-sot` rather than guessing.

Override when needed:

```
/jira-bug-analyzer AIP686 @3 --spec <confluence-url> --figma <figma-url>
/jira-bug-analyzer AIP686 @3 --rediscover     # a wrong page was adopted / the spec moved
```

### Ticket template for QA (optional)

[`plugins/jira-bug-analyzer/QA-TICKET-TEMPLATE.md`](plugins/jira-bug-analyzer/QA-TICKET-TEMPLATE.md) — what to
write so a bug is reproduced and fixed faster (steps naming the exact screen/source, Expect in plain words). Never
a gate: a partial or messy ticket is fixed as before.

## Prerequisites

The skill auto-installs its MCP server *config* on first run (jira, confluence, figma, human-mcp)
and prompts for the per-dev `JIRA_PERSONAL_TOKEN` (Jira → Profile → Personal Access Tokens). The
jira/confluence servers run the `mcp-atlassian` executable, which you install once per machine:
`uv tool install mcp-atlassian` (or `pipx install mcp-atlassian`), then restart Claude Code.
It also expects, at their gates:
`gh` (authenticated), `adb` (for on-device verify), and a Gradle Android project for the
fix/build phases.

**Apero devs only:** the shared memory/KB lives in the private repo
`hung-apero/jira-bug-memory`. Your `gh` account needs **write** access to it, or the
memory phase (cross-dev bug dedup + the Android knowledge base) will fail. Ask
@hung-apero for access. The plugin is public, but this repo is not — outside Apero, the
memory phase will not work.

## Repo layout (marketplace + plugin monorepo)

```
.claude-plugin/marketplace.json          # marketplace manifest (name: apero-tools)
plugins/jira-bug-analyzer/
  .claude-plugin/plugin.json             # plugin manifest
  skills/jira-bug-analyzer/              # the skill (SKILL.md + assets + references + team)
scripts/sync-from-local-skill.sh         # re-publish the canonical skill into this repo
```

## Maintaining

**Source of truth = the TeraKit repo's project-scope skill**, `TeraKit/.claude/skills/jira-bug-analyzer`.
That is the git-tracked copy; edit it there, never here and never in `~/.claude/skills`
(that path is an *install target*, not a source — publishing from it is what previously
dropped `--discord` and `device-lock` from the plugin, so the sync script now refuses it).

```bash
# after committing skill edits in TeraKit:
TERAKIT=/path/to/TeraKit ./scripts/sync-from-local-skill.sh
# bump version in plugins/jira-bug-analyzer/.claude-plugin/plugin.json + marketplace.json
git add -A && git commit -m "feat: sync skill" && git push
```

Consumers pick up the update with `/plugin marketplace update apero-tools`.

> **Open question (P0):** the TeraKit copy on GitHub has no skill change since 2026-08-11, while this
> repo shipped v1.4 → v1.15.3. Until the owner confirms where edits happen, the sync script refuses a
> source older than this repo (no `references/constants.md`) — set `FORCE_OLDER_SRC=1` only to roll back.

### Checks before every release

```bash
python3 scripts/lint_skill.py   # refs, tags, constants, models, size, secrets, bash — must be 0 errors
bash tests/run_all.sh           # lint + unit + shell-behavior tests (CI runs the same)
python3 scripts/metrics.py      # static metrics vs the v1.15.2 baseline and each phase's target
```

Behavior that only an LLM run can show is checked by hand with `tests/SCENARIOS.md`. Runtime metrics
(reopen rate, tokens, manager quiet fires) and how to read them: `METRICS.md`. What changed: `CHANGELOG.md`.
