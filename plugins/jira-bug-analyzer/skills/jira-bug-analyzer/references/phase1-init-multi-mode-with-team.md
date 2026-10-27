# Init phase — Multi mode WITH team (`--team` launcher → MainCharacter)

> Loaded by SKILL.md's mode dispatch when the invocation contains **`--team`** (with or without `--mode multi`). This session becomes **MainCharacter** (the team lead) and stands up the parallel `jira-bugfix` Agent Team — it does NOT run the solo worker flow. Self-contained for launch; the role cards + full launch recipe live at `team/team.md` (loaded at spawn). The board pull + bug listing reuse the canonical **Pull & list by category** block in `references/phase1-init-multi-mode-without-team.md` (NOT phase2). Cross-cutting invariants are SKILL.md **Golden Rules** — cited by tag, not restated.

`/jira-bug-analyzer --team [--mode multi] [--devs N]` turns **this** session into the lead. The plain command is the *worker*; `--team` is the *launcher*. Spawned teammates run their slices **without** `--team` (Devs run the truncated single flow per their role card).

## Init-1…5 — one script, then act on the result

Run the team-mode init probe once at start, passing the **target bug repo root** and `--project <KEY>` when the key is known:

```bash
bash <skill-dir>/assets/init-team.sh "<PROJECT_ROOT>" --project <KEY>   # add --recheck-env to force a fresh env probe
```

It prints an `INIT-STATUS` block (`MODE=team`, probes **only the `TIER=now` deps** via `preflight-env.sh --now-only` unless a fresh env cache exists, `memory-sync.sh pull 600`, setup local→remote, pending state, plus `TEAM_FLAG=set|unset` hinting the Agent-Teams env flag — all read-only, cached, never blocks, exits 0). On a warm cache it also emits `PULLQUERY_JQL=<jql>` (fire `jira_search` from it — no separate `Read` of `setup.json`). Both the env probe AND the `MCP_SETUP` status are cached together in the **user-scope** `~/.claude/jira-bug-analyzer/probe-cache.json` (30d TTL, machine-local, shared across projects; legacy `.jira-bug/env-cache.json` auto-migrated); a warm cache skips both the preflight and the `setup-mcp.sh status` fork; `--recheck-env` bypasses. `later`/`cond` deps are re-probed at their gates. **In the same first turn also fire `ToolSearch select:mcp__jira__jira_search` AND `ToolSearch TeamCreate` (substrate probe — see Init-8).** Then act per this table:

| INIT-STATUS line | Action |
|---|---|
| `ENV=ok` | jira deps present → continue (device/gh checked at the team's verify/PR gates, not here) |
| `ENV=block:<dep>` | **HARD-BLOCK** (`jira-mcp`/`jira-creds` missing). Resolve via `AskUserQuestion` `[OPTIONS]` before launching. Recipes: `references/helpers/environment-setup.md`. |
| `MEMORY=fresh` \| `pulled` | shared memory in sync → continue |
| `MEMORY=offline` | warn once, continue on the last local copy |
| `TEAM=active` | a `jira-bugfix` team is already in flight → display `.jira-bug/team-board.md` and **reconcile/resume** that team (Init-5) instead of launching a duplicate. |
| `TEAM=none` | no team running → fresh launch |
| `SETUP=cached` + `PULLQUERY=cached` | local cache hit → reuse the saved board/status/assignee SILENTLY for the lead's pull. |
| `SETUP=remote` (`REMOTE_SETUP=<path>` printed) | a teammate's `project/<KEY>/setup.json` exists → hydrate the local mirror (project-level fields only; `env` stays local), name `savedBy`, continue. |
| `SETUP=absent` | first run → ask board/status/assignee (Init-9), pull, then **persist** both layers (First-run persist, as in the without-team file). |
| `BASEBRANCH=<branch>` | integration branch already persisted → the lead uses it verbatim as `<BASE>` for every teammate worktree + PR. Continue. |
| `BASEBRANCH=none` (the local setup doesn't carry it) | the lead **ASKS the dev — NEVER auto-fills.** `AskUserQuestion` `[OPTIONS]`: recommended one-tap = `BASEBRANCH_SUGGEST` if emitted, else the value resolved from the **Base branch** block (`references/run-blocks.md`); + other branch(es) + **Other**. On the pick, persist local + push shared (`memory-keeper`) **BEFORE dispatching teammates** — so every teammate branches from the same `origin/<baseBranch>`. |
| `TEAM_FLAG=unset` | the `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` env flag is not set — substrate **A** (native Agent Teams) is unavailable. This is only a *hint*: confirm via the ToolSearch substrate probe (Init-8) before deciding A vs B; do NOT hard-block on the flag alone. |
| `TEAM_FLAG=set` | env flag present → substrate A likely available; still confirm via ToolSearch. |
| `PENDING_WATCH=yes` / `PENDING_BATCH=yes`, **no `--resume`** | one-line hint, then continue fresh. |
| any pending state **with `--resume`** | **Init-5 reconcile** (below). |

Then continue Init-6 (model) → Init-8 (substrate + launch) → Init-9 (context for the lead's pull).

**Memory & manifest / First-run persist / Init-5 resume / Just-in-time re-probes** — identical to `references/phase1-init-multi-mode-without-team.md` (the lead is a multi worker that also orchestrates). In team mode, **Init-5 resume is owned per `team/team.md`**: the lead reconciles batch/board state; Observer re-attaches PR watchers. The full PR-watch reconcile (review-comment fixing) + KB-backfill is run via **`--manager`** (`references/phase-manager-mode.md`) after the team's batch, same as solo mode.

### Init-6 — Model
Per-stage matrix = the **Model matrix** in `references/constants.md` (same as the other modes); `--model <…>` overrides the judgment stages only. **Agent-Teams constraint (substrate A): all teammates run Opus** regardless of the matrix — the matrix's cheaper-stage choices apply only on the Agent-tool fallback (substrate B) where per-Agent model is free to set.

### Init-8 — Substrate detection + become MainCharacter
The skill needs *a* multi-agent substrate, **NOT specifically `TeamCreate`**. Hard-block only if NEITHER exists:
- **(A) Native Agent Teams** — `TeamCreate`/`TeamDelete` exposed (confirm via ToolSearch). Live teammate sessions + tmux panes. Needs `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` (`TEAM_FLAG`) **and a CLI terminal (NOT VSCode)**.
- **(B) Agent-tool substrate (fallback — functionally identical)** — `Agent` + `TaskCreate`/`TaskUpdate` + `SendMessage`. Spawn each role as a background Agent, coordinate via the Task board + SendMessage. Difference is execution shape only (run-to-completion + re-engage via `SendMessage`, no tmux). Same outcome.
- **Choose A if exposed, else B.** A missing `TeamCreate` is a tooling-surface mismatch, not a disabled feature — do NOT downgrade to solo when the user asked for `--team` and substrate B exists. **Hard-block ONLY when neither exists** → STOP, tell the user to set `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` and relaunch from a terminal.

**Launch flow — act as MainCharacter (delegate mode), per `team/team.md`:**
1. Stand up the team: A → `TeamCreate(team_name: "jira-bugfix")`; B → spawn named background Agents (no team-create call).
2. Enter delegate mode — coordinate only, never edit source.
3. Spawn support roles via `Agent`: **Github Observer**, **Tester**, **Dev-Fixer-PR**.
4. Resolve `N` Devs (`--devs N` or ask, default 2), sized from the board.
5. **Pull** (the canonical **Pull & list by category** block in `references/phase1-init-multi-mode-without-team.md`) → group by category (≤4/cat) → **claim** each picked ticket (`[CLAIM]`) → spawn `Dev1..DevN`, one ticket per Dev. Re-pull each turn until the board empties, then stand down.
6. **Write `.jira-bug/team-board.md`** (template in `team/team.md`) — this is what `TEAM=active` displays. Exclude it from git.
7. Drive by the **Step → Role matrix** in `team/team.md`: auto-approve `Risk: low` plans (escalate med/high); Devs fix+commit then set `ready`; at each PR-round cutoff the **lead** cuts the round, **hands it to Tester for the MANDATORY on-device verify gate — Phase 5, driven by `adb` (NOT mobile-mcp)** (no round PR before Tester returns `pass` for every ticket — only the human may waive), then the lead runs Phase 6 to open the round PR + finalize Jira. **`[VERIFY]` — never fix → PR/resolved skipping Tester.**

### Init-9 — Context (lead's pull)
The lead needs **board → status → assignee** (same intake + auto-select rules as `references/phase1-init-multi-mode-without-team.md` → Init-9), plus **`N` (Dev count)** sized from the board (`--devs N` or ask, default 2), plus **spec/figma/other** — the mandatory spec/figma *ask* up front, then captured in full in the background at the source-of-truth capture (Phase 2) for the whole phase (serves all tickets, not the picked set; the digest is non-blocking). Teammates do NOT self-pull — the lead pulls, claims, and dispatches.

> **`--devs N`** sets the Dev count; **`--pr-window <N>m`** sets the rolling PR-round window (default `TEAM_PR_ROUND`, `references/constants.md`) — team mode only; solo modes stream per ticket and ignore it. `--every` is removed (multi re-pulls automatically each turn) — warn + ignore if passed.

When the substrate is up and the team spawned → drive the run from `team/team.md` (Role Cards + Step→Role matrix + Running loop).
