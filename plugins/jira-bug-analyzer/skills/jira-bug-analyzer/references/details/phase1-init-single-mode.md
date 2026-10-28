# Init phase — Single mode (fix ONE ticket by key) — full text

> Read ONE section at a time: `bash <skill-dir>/assets/section.sh <skill-dir>/references/details/phase1-init-single-mode.md "<anchor>"`. The checklist and index live in `references/phase1-init-single-mode.md`.


> Loaded by SKILL.md's mode dispatch when the invocation resolves to **single** (`--mode single <KEY>` or a bare `[A-Z][A-Z0-9]+-\d+` token). Self-contained: everything single needs is here — no board pull, no category listing. When you reach analyze read `references/phase3-analyze.md` (Single Fix-1…Fix-8) and for the fix read `references/phase4-fix-and-build.md` (Fix-9…Fix-13); the **Source-of-truth capture** is Phase 2 (`references/phase2-source-of-truth.md` — background, non-blocking), other shared gates live in `references/run-blocks.md`. Cross-cutting invariants are SKILL.md **Golden Rules** — cited by tag, not restated.

Single mode fixes **one** ticket. The key comes from the arg (`--mode single AIP686-179` or bare `AIP686-179`); if absent, ask for it `[OPTIONS]`/free-text before anything else.

## Init-1…5 — one script, then act on the result

Run the single-mode init probe once at start, passing the **target bug repo root** and, **when the project key is known**, `--project <KEY>` (for single, the key is just the prefix of the ticket key — `AIP686-179` → `AIP686`):

```bash
bash <skill-dir>/assets/init-single.sh "<PROJECT_ROOT>" --project <KEY>   # add --recheck-env to force a fresh env probe
```

It prints an `INIT-STATUS` block (`MODE=single`, probes **only the `TIER=now` deps** via `preflight-env.sh --now-only` unless a fresh env cache exists, `memory-sync.sh pull 600`, resolves setup local→remote, reads pending state — all read-only, cached, never blocks, exits 0). Both the env probe AND the `MCP_SETUP` status are cached together in the **user-scope** `~/.claude/jira-bug-analyzer/probe-cache.json` (30d TTL, machine-local, shared across projects; legacy `.jira-bug/env-cache.json` auto-migrated). A warm cache skips both the preflight and the `setup-mcp.sh status` fork; `--recheck-env` bypasses. `later`/`cond` deps are re-probed just-in-time at their gates, not here. Single does **not** pull a board, so the script omits `BOARD`/`PULLQUERY`/`PULLQUERY_JQL`/`TEAM`. **In the same first turn also fire `ToolSearch select:mcp__jira__jira_get_issue`** to preload the fetch tool. Then act per this table:

| INIT-STATUS line | Action |
|---|---|
| `ENV=ok` | deps present → continue |
| `ENV=block:<dep>` | **HARD-BLOCK** (`jira-mcp`/`jira-creds` missing). Do NOT fetch. `AskUserQuestion` `[OPTIONS]` (e.g. *add JIRA_URL+token to `.mcp.json`* / *paste ticket manually — no REST writes* / *cancel*). Proceed only once resolved. Recipes: `references/helpers/environment-setup.md`. |
| `MCP_SETUP=ok` | all template MCP servers already configured → continue |
| `MCP_SETUP=needs:<list>` | **REQUIRED init step — AUTO-INSTALL, don't ask whether to.** template servers `<list>` absent from `~/.claude.json`. Drop any already LIVE via another config (ToolSearch `mcp__<server>__*`, e.g. figma via Framelink). Genuinely-missing remainder → **run `bash <skill-dir>/assets/setup-mcp.sh all --token <JIRA_PERSONAL_TOKEN>` immediately, no confirm prompt** (skips present servers). **Only ask the dev for genuine input** — the `JIRA_PERSONAL_TOKEN` if unknown (`[VN]`) — never a "shall I install?" / "cancel run" gate. Then reload + re-probe on `RESTART_REQUIRED=yes`; continue once every template MCP is live. The **only** place MCPs are set up — gates never provision. Flow: `references/helpers/environment-setup.md`. |
| `MEMORY=fresh` \| `pulled` | shared memory in sync → continue |
| `MEMORY=offline` | warn once, continue on the last local copy |
| `SETUP=cached` | local cache hit → **reuse the saved model override + spec/figma SILENTLY** (the ticket key is the arg, not from setup). One-line saved-setup summary, then Fix-1. |
| `SETUP=remote` (`REMOTE_SETUP=<path>` printed) | a teammate's `project/<KEY>/setup.json` exists → hydrate the local mirror (project-level fields only — the machine-specific `env` block stays local / freshly probed). Emit ONE line naming `savedBy`. Continue to Fix-1. |
| `SETUP=absent` | no local cache and no remote setup → ask the few single-mode intake fields (Init-6/Init-9), then **persist BOTH layers in the same turn — local AND remote (two writes; the shared push is MANDATORY, not optional, not deferred):** (1) write the local `.jira-bug/setup.json` mirror; (2) push shared `project/<KEY>/setup.json` via the `memory-keeper` agent (`action: project-setup`, project-level fields only — never push `env`). Asking the dev is NOT persisting — config isn't saved until the shared `setup.json` reaches `origin`; a local-only write leaves the next dev re-asked. |
| `BASEBRANCH=<branch>` (e.g. `develop`) | integration branch already persisted in the setup → use it verbatim as `<BASE>` for the fix worktree + PR. No prompt, continue. |
| `BASEBRANCH=none` (the local setup doesn't carry it — new, predates the field, or the dev removed it) | **ASK the dev — NEVER auto-fill.** `AskUserQuestion` `[OPTIONS]` for the integration branch: recommended first option (one-tap) = `BASEBRANCH_SUGGEST` if emitted, else the value resolved from the **Base branch** block (`references/run-blocks.md`: CLAUDE.md/contributing docs → remote default branch → checked-out integration branch); + other plausible branch(es) + **Other** free-text. On the dev's pick, **persist into local `.jira-bug/setup.json` AND push shared `project/<KEY>/setup.json` via `memory-keeper`**. Needed before Fix-10 (worktree) — never branch from a hardcoded `origin/main`. |
| `PENDING_WATCH=yes` / `PENDING_BATCH=yes`, **no `--resume`** | one-line hint *"ℹ️ pending state — run `--resume` to continue; proceeding fresh"*, then continue fresh. |
| any pending state **with `--resume`** | **Init-5 reconcile** instead of fresh (below). |

Then continue Init-6 (model) → Init-9 (context).

**Memory & manifest (details: `references/helpers/memory.md`).** init-single.sh runs `memory-sync.sh pull 600` (TTL). **The memory repo is FIXED — `https://github.com/hung-apero/jira-bug-memory` — no fallback, no ask.** If the local clone is absent, run `memory-sync.sh autowire` (clones the fixed repo); `WIRED:configured` → continue. `REPO_ACCESS:<url>` → the dev needs `gh auth login` + permission on that repo — surface it, do NOT ask for a URL and do NOT proceed local-only. **MCP setup runs HERE at init (template-driven, AUTO):** `setup-mcp.sh status` reads the template and reports `MISSING=`/`NEEDS_SETUP=`; `NEEDS_SETUP=yes` → **auto-run `setup-mcp.sh all --token <tok>` immediately (no "shall I install?" prompt)** — provisions jira+confluence+figma+human-mcp at once (skips any present / live-via-other-config). Init still only *blocks* on `jira` being live; the rest are configured now so their gates find them ready. **The ONLY thing to ask is genuine user input** — the per-dev `JIRA_PERSONAL_TOKEN` when unknown (`[VN]` prompt), written as the literal into `~/.claude.json` by the script. (Full flow: `references/helpers/environment-setup.md`.) All later memory writes go through the `memory-keeper` agent.

**Init-5 — `--resume` reconcile** (only with `--resume`; a plain run is FRESH). **Minimal cleanup only:** per `.jira-bug/pr-watch.json`, `MERGED`/`CLOSED` → remove the fix worktree + drop the entry. **The full PR-watch reconcile (surface/fix review comments, re-arm cron) + KB-backfill is owned by `--manager`** (`references/phase-manager-mode.md`) — point the dev there; `--resume` does not chase review comments. Mechanics: `references/helpers/pr-merge-watcher.md`.

**Just-in-time re-probes** (volatile **non-MCP** deps only — re-checked at their gate, never cached): `adb-device` + `gradle` before the verify gate; `gh-cli` auth before PR (Fix-13). Missing at the gate → targeted `AskUserQuestion` `[OPTIONS]` there. **MCP servers are NOT here** — all template MCPs (jira/confluence/figma/human-mcp) are provisioned **once at init** (required `MCP_SETUP` step); gates only re-confirm an MCP's **liveness**, never provision. Durable deps stay cached in the `env` block; `--recheck-env` forces a fresh probe.

### Init-6 — Model (per-stage policy — do NOT ask)
Apply the **Model matrix** in `references/constants.md` automatically — main loop `sonnet`, analyzer `opus`, fixer/verifier/code-reviewer `sonnet`, mechanical stages `haiku`; pass `model` on every `Agent` spawn. **Do not ask for a model up front.** `--model <…>` overrides only the judgment stages (same file).

### Init-9 — Context (single)
Single mode needs the **ticket key** + optional design refs — no board/status/assignee, no pull. Anything supplied is ground truth, fed into the pre-fix context import (Fix-11) — no auto-discovery for those fields. Ask one at a time, wait for each, skip anything the args/earlier answers resolved:

- **Ticket** — the Jira key. From the arg if present; else ask (required — single can't proceed without it).
- **Spec / Figma / Other refs** — **AUTO-DISCOVERED** at the **source-of-truth capture** (Fix-2, Phase 2) via the **§2.0 ladder (`references/helpers/source-of-truth-discovery.md`)**: in single mode the one ticket *is* the discovery input (its remote-links / body URLs are the STRONG signals — L2/L2b), so the common case resolves with **zero prompts**. Fuzzy → one-tap pick-list; nothing found → the blocking paste-ask. The ladder + the required-vs-optional rule (Confluence + Figma REQUIRED; Other OPTIONAL) is defined **once** in `references/phase2-source-of-truth.md` (**Phase 2**) — follow it there, not restated here. A saved `sotByPhase[<PHASE>]` entry is reused silently (L1); `--rediscover` forces a fresh detect.

When ready → hand off to **Phase 3** `references/phase3-analyze.md` → **Single-ticket Fix-1 … Fix-8** (claim → analyze → approval), then **Phase 4** `references/phase4-fix-and-build.md` → **Fix-9 … Fix-12** (worktree → fix by the plan → build the APK to verify compilation), then **Phase 5** `references/phase5-verify.md` (review diff on GitHub → install the Phase-4 APK + user-verify; adb self-verify only on `--auto`) and **Phase 6** `references/phase6-commit-pr.md` (commit → PR with full Phase-3+5 body → Jira finalize in background).
