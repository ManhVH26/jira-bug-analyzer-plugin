# Environment setup & preflight

Read this when **Init-1 — Environment preflight** reports a gap, or when a just-in-time re-probe before a gate fails. SKILL.md tells you *when* a dep is needed; this file is *what it's for* and *how to set it up*. Runtime errors after a dep is present live in `troubleshooting.md` — this doc is setup-time gaps.

## Tiers — what blocks vs what warns

| Tier | Meaning | Preflight behavior |
|---|---|---|
| `now` | Skill cannot start without it | **HARD-BLOCK** — ask the user via `AskUserQuestion`, do not proceed until resolved or a fallback chosen |
| `later` | Needed at a downstream gate (worktree, verify, PR) | **Warn only** at start; **re-probe just-in-time** before its gate and block *there* if still missing |
| `cond` | Needed only on a condition (video media, source-of-truth capture spec/figma, scheduling) | Warn only; surfaces when the condition actually arises |

> **MCP servers are an exception to tiering.** All template MCP servers (jira, confluence, figma, human-mcp) are **provisioned together at init** (the required `MCP_SETUP` step), regardless of the `now`/`later`/`cond` tier of *when they're first used*. The tier/"First needed" columns below describe when a server is **used**, not when it's set up. Gates never provision — they only re-confirm liveness.

## Dependency catalog

| DEP id | Tier | First needed | Purpose | Fix if missing |
|---|---|---|---|---|
| `jira-mcp` | now | Fix-3 | fetch/search tickets | **Auto-setup from the template:** `bash <skill-dir>/assets/setup-mcp.sh jira --token <JIRA_PERSONAL_TOKEN>` (merges the `jira` server def from `assets/mcp-setup-template.json` into `~/.claude.json`), then reload so `mcp__jira__*` connects; confirm with a real call. |
| `jira-mcp-bin` | now | Fix-3 | the `mcp-atlassian` executable the `jira` (and `confluence`) MCP servers launch — a config entry alone never connects without it | **Install once per machine:** `uv tool install mcp-atlassian` (or `pipx install mcp-atlassian`), then restart Claude Code. `setup-mcp.sh` prints `MISSING_BIN=mcp-atlassian` when it is absent. |
| `jira-creds` | now | Fix-1 claim | REST: comments, worklog, transitions, attachments, In-Progress claim | The same `setup-mcp.sh jira --token <tok>` writes `JIRA_URL` (from template) + the **literal** `JIRA_PERSONAL_TOKEN` into the `jira` server's `env` in **`~/.claude.json`** (user-global, uncommitted). NOT `.claude/.env` (Claude Code doesn't load it into MCP env). Readers check process env → `~/.claude.json` → `.mcp.json`. See `jira-rest-api.md` → Credential bootstrap. |
| `confluence-mcp` | cond | source-of-truth capture | spec ground truth | **Auto-setup from the template:** `bash <skill-dir>/assets/setup-mcp.sh confluence` (ships the fixed Confluence URL+token). **`spec` is REQUIRED to provide** — if setup still can't connect, the dev pastes the Confluence link/section manually (no skip for spec); the *ask* blocks until supplied, then the digest captures in the background. |
| `figma-mcp` | cond | source-of-truth capture | design ground truth | **Auto-setup from the template:** `bash <skill-dir>/assets/setup-mcp.sh figma` (ships the fixed Figma API key). **`figma` is REQUIRED to provide** — if it still can't connect, the dev pastes the Figma link/frame screenshots manually (no skip for figma); the *ask* blocks until supplied, then the digest captures in the background. |
| `human-mcp` | cond (media; non-blocking — native fallback) | Fix-5 (media) + Phase 5 (verify observe) | **analyze images/videos → TEXT** (`eyes_analyze`) + device⟷Figma diff (`eyes_compare`); bytes never enter context (`references/helpers/media-analysis.md`) | **Auto-setup from the template:** `bash <skill-dir>/assets/setup-mcp.sh human-mcp` — merges the `human-mcp` server def (`npx @goonnguyen/human-mcp`) into `~/.claude.json`. Keys: set **`HUMAN_MCP_GEMINI_KEYS`** (comma-separated Gemini keys) in **`.claude/.env`** before setup → the script writes them into the server's `GOOGLE_GEMINI_API_KEY` (human-mcp rotates them internally). No keys → the skill uses the **Claude-native vision fallback** (`media-preprocessing.md`). |
| ~~`mobile-mcp`~~ (RETIRED, removed from template) | — | — | — | **No longer used / no longer provisioned.** Phase 5 verify drives the device via **`adb` directly** (see `adb-device` below); mobile-mcp must not be used for verify. |
| `gh-cli` | later | Fix-13 | PR create, diff-web, review-comment poll | Install GitHub CLI then `gh auth login`. `warn` = installed-but-unauthenticated. |
| `git` | later | Fix-10 | isolated fix worktree | Install git / run inside a git repo. |
| `adb-device` | later | verify gate | on-device run + self-verify | Install platform-tools; connect a device or start an emulator (`adb devices` must list one as `device`). |
| `gradle` | later | verify gate | build/launch the appDev/debug variant | Run inside the Android repo (must have `./gradlew`). `warn` if CWD ≠ target repo — fine, build happens in the fix worktree. |
| `skill-worktree`, `skill-run` | later | verify / worktree gates | gate delegation | Provided by the skills install. A `warn` for a native/plugin skill (e.g. `run`) that resolves outside `.claude/skills` is harmless — it just couldn't be found on disk by the probe. (`android-self-verify` is retired — Phase 5 uses `adb` directly.) |
| `PR_DISCORD_CHANNEL_URL` | cond | Fix-13 (Discord opt-in) | target Discord channel for the Cowork review-request (`pr-discord-review-request`) | Add `PR_DISCORD_CHANNEL_URL=https://discord.com/channels/<guild>/<channel>` to `.claude/.env` (untracked). Unset → the opt-in asks once. Not a secret, but keep it out of git. |

## Running the preflight

```bash
bash <skill-dir>/assets/preflight-env.sh "<PROJECT_ROOT>"
```

- `PROJECT_ROOT` = the repo holding the bug (the target project / worktree source), not this skill's dir. Defaults to `$PWD`.
- Read-only, always exits 0. Prints one line per dep:
  `DEP=<id> TIER=<now|later|cond> STATUS=<ok|warn|missing> [NEEDED_AT=<step>] [HINT=<text>]`
- Parse it: any `TIER=now STATUS=missing` → hard-block + `AskUserQuestion`. `later`/`cond` `warn`/`missing` → one batched warning line; re-probe the specific dep before its gate.

## MCP setup is an INIT-PHASE step (template-driven + ask) — not per-gate

**Provision MCP servers at init, all together, from the bundled template** `assets/mcp-setup-template.json`
— don't wait for a gate, and don't provision only the one that's missing.

1. **At init, read the template + probe** (`INIT-STATUS` already emits `MCP_SETUP=` from this):
   ```bash
   bash <skill-dir>/assets/setup-mcp.sh status   # → TEMPLATE_SERVERS= / PRESENT= / MISSING= / NEEDS_SETUP=
   ```
2. **First make sure the server executables exist** (`DEP=jira-mcp-bin`): if `mcp-atlassian` is not on PATH, run `uv tool install mcp-atlassian` (fallback `pipx install mcp-atlassian`; neither `uv` nor `pipx` → ask the dev to install `uv`). Without it the `jira`/`confluence` entries are written but never connect.
   **Getting the `JIRA_PERSONAL_TOKEN` (per dev, once):** `https://jira.apero.vn` → avatar → **Profile** → **Personal Access Tokens** → **Create token**; it is shown once. The dev passes it in their own shell (`! JIRA_PERSONAL_TOKEN=<tok> bash <skill-dir>/assets/setup-mcp.sh jira`) so it never has to be pasted into the chat.
3. **`NEEDS_SETUP=yes` → REQUIRED, AUTO-INSTALL (do NOT ask whether to).** First **drop any server already
   LIVE via another config** (ToolSearch `mcp__<server>__*` — e.g. figma via the Framelink connector is live
   even though `~/.claude.json` lacks a `figma` entry; don't reinstall it). For the genuinely-missing
   remainder, **run it immediately — no "shall I install?" / "cancel run" prompt:**
   ```bash
   bash <skill-dir>/assets/setup-mcp.sh all --token <JIRA_PERSONAL_TOKEN>
   ```
   `all` is **idempotent**: adds every missing template server, **skips those already present**
   (`EXISTS_SKIPPED`), merges into user-global `~/.claude.json` (uncommitted — literal secrets safe),
   prints `ADDED:` / `RESTART_REQUIRED=`. After `RESTART_REQUIRED=yes`, reload + re-probe liveness
   (config written ≠ server connected). **Continue only once every template MCP is live.** **The ONLY
   thing to ask the dev is genuine input** — the `JIRA_PERSONAL_TOKEN` when it's unknown (see next bullet);
   provisioning itself is automatic.
4. **Gates NEVER provision MCPs.** Setup happens ONLY here at init. The source-of-truth (confluence/figma)
   gate merely **re-confirms liveness**; it does not run `setup-mcp.sh`. (The verify gate uses `adb` directly — no MCP to re-confirm.) (Single-server
   form `setup-mcp.sh <server> --force` exists only for a manual targeted re-add — not part of the flow.)
- Confluence + Figma ship with the team's fixed creds in the template → no prompt needed.
- `jira` needs the **per-dev token**: pass `--token` (or have `$JIRA_PERSONAL_TOKEN` set). Without a literal
  token the script warns (Claude Code won't expand `${VAR}` in MCP config) → ask the dev once for the token, re-run.
- After `RESTART_REQUIRED=yes`, reload the session, then **re-probe liveness** (config written ≠ server
  connected) before proceeding. Non-MCP CLI tools (`gh`, `adb`, `gradle`, `git`) are NOT in the template —
  install those per the catalog above.

## Setup-question pattern (MCP auto-installs; ask only for genuine input)

Missing template MCPs are **auto-installed at init** from the template — do NOT ask "shall I install?".
The only thing to prompt for is **genuine user input** (a token / a manual paste when a server can't connect):

- **jira-mcp / jira-creds missing** → auto-run `setup-mcp.sh jira --token …`; **ask only for the `JIRA_PERSONAL_TOKEN`** when it's unknown (genuine input). If the token can't be supplied at all, fall back `[OPTIONS]`: *"Paste ticket details manually (no REST writes)"* / *"Cancel"*.
- **confluence-mcp / figma-mcp missing** → auto-installed at init from the template (fixed team creds, no prompt). Only if a server **still can't connect** at the source-of-truth capture → `[OPTIONS]`: *"Paste the Confluence/Figma link manually"*.
- **Device verify (Phase 5)** uses **`adb` directly** (mobile-mcp retired). At the verify gate ensure `adb devices` shows the locked serial as `device`; none available → start an emulator (`emulator -avd <name>`) or ask the human to attach. Only if a device genuinely can't be obtained → `[OPTIONS]`: *"Skip verify (only the user may skip)"*.

For `later`/`cond` **non-MCP** deps the prompt fires **at the gate**, not at start — e.g. before the verify gate, if `adb-device` is still missing: *"Connect a device / start an emulator"* / *"Skip verify (only the user may skip)"*.
