# Memory repo — keeper agent · onboarding · bundle-sync

> The shared GitHub memory: how it is written (memory-keeper agent), how a dev/repo is bootstrapped onto it (Init-2 onboarding), and how the bundled helper skills are kept in sync (maintenance).

## memory-keeper agent

The **sole writer** of the shared memory repo. The loop spawns it (via the Agent tool with this file as its brief) whenever memory must change; it gets info/indicators and writes + pushes single entry files. The loop itself never writes memory directly. Read-only on Jira and source.

> **`[BGMEM]` — always dispatch the keeper as a BACKGROUND agent (`run_in_background: true`).** All remote-memory I/O (the keeper's `pull`/write/`push`, plus any raw `memory-sync.sh pull`/`push` and the `source-of-truth` capture) runs off the critical path so the interactive flow never waits on git network I/O. Dispatch it and **move on immediately**; consume its completion notification lazily at the next gate that needs the result (dedup/claim). Non-blocking does **not** mean deferred — a write a phase marks *mandatory this turn* is still dispatched that same turn, just as a background agent. The only inline-allowed memory step is the Init warm-cache `pull 600` (a local timestamp check, not network I/O). Push failure → surface it; never block on it. See SKILL.md Golden Rule `[BGMEM]`.

**Model (Model matrix, `references/constants.md`):** spawn on **`opus`** for `kb-upsert` (deciding the bug's category + slug + app-agnostic). The **dedup match** (is this the same ticket / same root-cause slug as in-flight work) runs on **`sonnet`** and is re-run on `opus` only when the verdict is "maybe". Spawn on **`sonnet`** for the `source-of-truth` **build** (walking Figma frames + distilling the spec page into a digest is real reasoning). Spawn on **`haiku`** for the *mechanical* writes — plain `status` transitions, the `source-of-truth` **freshness check** (manifest compare, no rebuild), and `project-setup`.

Spawn it with: `{action, project, phase?, ticket?, payload}`. It resolves the clone dir with `bash <skill-dir>/assets/memory-sync.sh path`, `pull`s, writes the one file, then `push`es it.

### Remote memory tree
```
project/<PROJ>/setup.json                              # per-project setup (cross-dev reuse)
project/<PROJ>/<PHASE>/doc/metadata.json               # STATUS MANIFEST — one entry per source file (spec, figma, each external source, other)
project/<PROJ>/<PHASE>/doc/spec.md                     # Confluence spec digest
project/<PROJ>/<PHASE>/doc/figma.md                    # Figma link + per-screen node-id index
project/<PROJ>/<PHASE>/doc/<external-slug>.md          # ONE file per external source the spec references (e.g. ad_script.md, iap_pricing.md, event_tracking.md) — peer of spec.md
project/<PROJ>/<PHASE>/session/record_bug_status.md    # CONSOLIDATED per-phase bug-status ledger — the SOLE session record + dedup signal (cross-dev + cross-ticket)
knowledgebase/<category>/<slug>.md                     # app-agnostic KB
setup/manifest.json                                    # global MCP manifest (NOT per-project)
```
- **`doc/`** = source of truth the agent reads to know *how* to fix — **the FULL phase content, captured once per phase independent of which tickets were picked** (it serves every ticket in the phase). **One `.md` file per source** (`spec`, `figma`, `external`). `spec` + `figma` are **REQUIRED** — each must be a captured digest (`status: present`); they cannot be waived. `external` is captured whenever the spec embeds external links (peer of `spec.md` — see below). A source is never silently ignored. **`metadata.json` is the status manifest** — one file per phase recording every source's status/version/capturedAt; the gate reads it once to decide capture/reuse/stale instead of opening each `.md`.
- **`<PHASE>/session/`** = the per-phase bug-status records used for **dedup** — same bug across different tickets, same root cause, or already fixed in a previous session. Scoped per phase; the dedup scan globs `project/<PROJ>/*/session/` to also catch a fix landed in an earlier phase.
  - **`record_bug_status.md` is the SOLE session record and the dedup signal** — one row per analyzed bug (ticket · status · `root_cause_slug` · dev · summary · files · pr · updated). The memory-keeper **upserts the row right after a bug is analyzed** and at every later transition. The analyzer reads it post-analysis to dedup (timing rule in `references/run-blocks.md`). One file = one quick read covers the whole phase. The `summary` column carries the **concise root cause shown in Phase 3** (one line — what's wrong + where), and the `files` column the touched `file:line`s; together they are the dedup hook. **There is NO per-ticket file** — the full Fix-6 block (Fix plan, Risk, clarify, ticket meta) stays in chat only, never in memory.
- **`<PHASE>/doc/<external-slug>.md`** = **one file per external source the spec references**, named by slug (e.g. the spec links an "ad script" sheet → `ad_script.md`; an IAP-pricing sheet → `iap_pricing.md`). Each is a first-class peer of `spec.md` (same level — NOT inlined into the spec, NOT aggregated into one combined file). Body = the extracted content when readable (`status: present`), or a placeholder with the link URL + why-unreadable when not (`status: pending`). `metadata.json` carries one entry per such file with its own status. The analyzer/fixer reads the relevant `<slug>.md` the same way it reads `spec.md`. **There is NO `requests/` folder** — an unreadable source's file is flagged `pending` and re-tried directly on the next capture; the dev can also paste content straight into that `<slug>.md`.

### Actions
| action | writes | when |
|---|---|---|
| `project-setup` | `project/<PROJ>/setup.json` | SKILL.md Init-4 — on first config / `Change` / args override; project-level setup so any teammate reuses board/status/spec/figma/**baseBranch** without re-asking. **Resolving a previously-absent `baseBranch` (the `BASEBRANCH=none` ASK gate) IS a project-setup change → push it here the moment the dev picks, same as first config.** Don't treat baseBranch as local-only. **ALWAYS write this file with `bash <skill-dir>/assets/setup-json.sh merge-set <file> key=val …` (canonical, trailing-comma-safe, merges into existing fields) — NEVER hand-write/`echo` the JSON. A hand-written trailing comma reads back empty under strict parse and silently disables config reuse + local-mirror hydration.** |
| `source-of-truth` | `project/<PROJ>/<PHASE>/doc/spec.md` · `figma.md` · one `<slug>.md` per external source + `metadata.json` (status manifest) · **`setup.json` `sotByPhase.<PHASE>`** (the resolved links + `detectedFrom`, dotted deep-merge) | Source-of-truth gate (SKILL.md — before analyzing). **Captures the FULL phase content, independent of the picked tickets.** `spec`+`figma` REQUIRED (no waive): present digest fresh → reuse; stale → re-capture; absent → **auto-discover per `references/helpers/source-of-truth-discovery.md` (§2.0)** (interactive: the hit is CONFIRMED one-tap, never adopted silently — STRONG → confirm, FUZZY → pick-list; `--auto`: no ask, SELF-VERIFY the candidate instead; only a NONE result falls back to asking the dev to paste the link, BLOCK until supplied). **External sources: each gets its OWN `<slug>.md` file (named for the source). Read directly → readable → write content into `<slug>.md` (`status: present`); unreadable → write a `<slug>.md` with a `pending` placeholder (link URL + why-unreadable) + mark that source `pending` in `metadata.json`; do NOT block, proceed. NO `requests/` folder, NO co-worker hand-off.** Each capture run with a `pending` external source re-pulls + **re-attempts the direct read**; now readable → fill its `<slug>.md`. Always rewrite `metadata.json` when any source changed. Push only the file(s) touched this run. Returns `ready`/`built`/`blocked` (blocked only on a missing required source; a pending external source is `ready`, not blocked). |
| `status` | **Written ONLY by `assets/ledger.sh`** (`upsert` / `delete` / `get` — pulls, edits one ticket, commits, pushes with rebase-retry, prints `LEDGER_COMMIT=`; keeps the file's existing shape: `| ticket |` table or `## KEY` sections; never overwrites a file it cannot parse). **ONE file:** upsert the bug's row in `project/<PROJ>/<PHASE>/session/record_bug_status.md` (the consolidated ledger — `root_cause_slug` + the concise root cause in `summary` + touched `file:line`s in `files`). | **the moment a bug is analyzed** (write the row with `root_cause_slug` + summary + files), then each later transition: `analyzing` (claim) → `analyzed` (plan ready) → `fixing` → `pr-created` → `done` (also `commented`/`blocked`). One row per ticket, keyed by ticket — upsert, don't append duplicates. **There is no per-ticket file — the ledger row is the only memory record.** |
| `kb-upsert` | `knowledgebase/<category>/<slug>.md` | on `done` when analyzer flagged `app_agnostic=true` |
| `kb-feedback` | bump `confidence` in `knowledgebase/<category>/<slug>.md` | a `kb_hit` fix that verified `pass` |

### File schemas
**`project/<PROJ>/<PHASE>/session/record_bug_status.md`** (the SOLE session record + dedup signal; one row per analyzed bug, upserted by ticket):
```
---
project: AIP686
phase: phase3
updated: 2026-06-28
---
# AIP686 phase3 — bug status ledger (cross-dev + cross-ticket dedup)
| ticket | status | root_cause_slug | dev | summary | files | pr | auto_eval | updated |
|---|---|---|---|---|---|---|---|---|
| AIP686-154 | pr-created | comment/typing-bar-missing-emoji-and-placeholder | hungnd | Comment UI: emoji icon + placeholder differ from Figma | ReviewComponents.kt | <url> | - | 2026-06-28 |
| AIP686-197 | analyzed | comment/cms-fake-reviews-never-loaded | hungnd | CMS fake comments never loaded in Reader/Player | ReaderViewModel.kt:300; VideoPlayerViewModel.kt:336 | | pending | 2026-06-28 |
```
- `status` ∈ `analyzing|analyzed|fixing|pr-created|done|reopened|commented|blocked` (`done` / `reopened` are written by manager Job D from the Jira changelog, for interactive and `--auto` fixes alike). `root_cause_slug` is the dedup key **across tickets** — two tickets with the same slug are the same fix.
- **`[SHEET]` (google-sheet board):** the `ticket` column holds the sheet key `<PROJECT>-SHEET-<N°>` (e.g. `AIP304-SHEET-1`) and this ledger is the SOLE status store (there is no Jira to transition) — `done` is set at PR-creation. Dedup for a sheet key also checks the stored `summary` still matches the sheet row (a re-numbered `N°` = a new bug). `auto_eval` stays `-` (Job D is n/a for a sheet). See `references/google-sheet-board.md`.
- `auto_eval` ∈ `-|pending|held|held-final|reopened` — the **auto-fix quality flag** (`held` is re-checked until `REOPEN_WATCH_DAYS`, then `held-final`; a `reopened` row also carries `reopen_reason` ∈ `fix-ineffective|regression|missed-case|design-mismatch|requirement-changed|unknown` + a one-line `reopen_note` — Job D v1.15.3, status history is authoritative). `-` = interactive fix (not under evaluation). `pending` = `--auto` fixed it (Phase 6 stamped Jira label `auto-fixed`), outcome not yet known. `--manager` Job D fills it: `held` (still Resolved/merged) or `reopened` (ticket was reopened after the auto-fix — also gets Jira label `auto-fix-reopened`). Reopen-rate over `pending+held+reopened` rows = the auto-fix quality metric.
- The `summary` column carries the **concise root cause shown in Phase 3** (one line — what's wrong + where) and `files` the touched `file:line`s. This row is the **only** thing written to memory per bug — there is no per-ticket file; the full Fix-6 block (Fix plan, Risk, clarify, ticket meta) lives in chat only.
- **Read by the analyzer AFTER it settles a root cause** (not before claim): a matching `root_cause_slug`, or the same ticket already in-flight/done by another dev/prior session → surface the duplicate + ask (`Skip`/`Fix anyway`). Full timing rule: `references/run-blocks.md`.

**`knowledgebase/<category>/<slug>.md`** (app-agnostic only — English):
```
---
category: ads
slug: anr-on-interstitial-show
confidence: high
times_seen: 3
apps: [AIP806A, AIP712]
tags: [ANR, interstitial, main-thread]
last_seen: 2026-06-27
---
### Symptom
### Root cause (framework/SDK-level — NOT app-specific)
### Fix pattern (code-shaped, not project paths)
### References (ticket + PR links)
```

**`project/<PROJ>/setup.json`** (shared project-level setup — cross-dev reuse; **machine-specific `env` is excluded**):
```json
{
  "model": null,
  "board": "AIP806A",
  "statusSet": ["Request", "Reopened"],
  "assigneeScope": "Any assignee",
  "spec": "<LEGACY flat confluence url — reads as phase1 ONLY; see the phase-keyed rule below>",
  "figma": "<LEGACY flat figma url — reads as phase1 ONLY>",
  "otherRefs": "<LEGACY flat drawio / code paths / notes>",
  "sotByPhase": {
    "phase3": {
      "spec": "<confluence url>",
      "figma": "<figma url>",
      "otherRefs": "<drawio / sheets / code paths>",
      "detectedFrom": "remotelink:AIP806A-179",
      "confirmedBy": "hungnd",
      "savedAt": "2026-07-14"
    }
  },
  "pullQuery": { "jql": "project = \"AIP806A\" AND ...", "sprintMode": "sprinted" },
  "baseBranch": "develop",
  "savedAt": "2026-06-27",
  "savedBy": "dungnt2"
}
```

**`sotByPhase` — the source-of-truth links are PHASE-keyed, not project-keyed.** Different phases have
different spec/figma pages, so one flat `spec`/`figma` per project is wrong: a `@3` run would silently
inherit `@1`'s spec and every fix in the phase would be anchored to the wrong ground truth. Rules:
- **Read** `sotByPhase[<PHASE>]` — that is the only entry that may be **auto-adopted** for that phase.
- **Legacy flat `spec`/`figma`/`otherRefs`** (written before this field existed) resolve as a **`phase1`
  entry ONLY**. For any other phase they are demoted to a mere *candidate* — offered in the Phase-2
  pick-list, **never auto-adopted**. This is what makes cross-phase inheritance impossible.
- **Write** with the dotted deep-merge so sibling phases survive — `assets/setup-json.sh` handles this:
  `setup-json.sh merge-set <file> 'sotByPhase.phase3={"spec":"…","figma":"…","detectedFrom":"…"}'`.
  A plain `sotByPhase={…}` set would REPLACE the whole object and destroy the other phases' entries.
- `detectedFrom` records which discovery rung produced the link (`remotelink:<KEY>` / `ticket-body:<KEY>` /
  `cql` / `sibling` / `manual`) — it is the audit trail for "why is the agent using this spec?".

**`project/<PROJ>/<PHASE>/doc/metadata.json`** — the **status manifest for all doc sources this phase** (one read tells the gate what's captured / stale / pending):
```json
{
  "project": "AIP686",
  "phase": "phase3",
  "updated": "2026-06-28",
  "sources": {
    "spec":   { "type": "spec",  "status": "present", "file": "spec.md",  "url": "<confluence url>", "version": "42", "confirmedBy": "dungnt2", "capturedAt": "2026-06-28" },
    "figma":  { "type": "figma", "status": "present", "file": "figma.md", "url": "<figma url>", "version": "2026-06-20T08:00:00Z", "confirmedBy": "dungnt2", "capturedAt": "2026-06-28" },
    "ad_script":   { "type": "external", "status": "present", "file": "ad_script.md",   "kind": "google-sheet", "url": "<sheet url>", "method": "auto-direct-read", "capturedAt": "2026-06-28" },
    "iap_pricing": { "type": "external", "status": "pending", "file": "iap_pricing.md", "kind": "google-sheet", "url": "<sheet url>", "reason": "HTTP 401 (not link-shared)", "capturedAt": "2026-06-28" }
  }
}
```
- One `sources` entry **per source file** — `spec`, `figma`, **each external source keyed by its slug** (`ad_script`, `iap_pricing`, …). Each entry's `type` ∈ `spec | figma | external`; `status` ∈ `present` (captured) | `pending` (external source that couldn't be read directly — re-tried each run). `spec`+`figma` are always `present` (required). The keeper rewrites this file whenever any source changes.

**`project/<PROJ>/<PHASE>/doc/<source>.md`** — **one `.md` per source** (`spec.md`, `figma.md`, one `<slug>.md` per external source), each a captured digest (`status: present`) or a `pending` external placeholder. Frontmatter mirrors the source's `metadata.json` entry (the manifest is the index; each file carries its own copy for standalone reads):
```
---
source: ad_script          # spec/confluence | figma | <external-slug>
type: external             # spec | figma | external
status: present            # present | pending (external only)
url: <source link>         # the spec / figma / external URL
version: "2026-06-20T08:00:00Z"   # staleness guard: Confluence version.number | Figma file lastModified — empty for external
confirmedBy: dungnt2       # dev who captured it OR confirmed it doesn't exist
capturedAt: 2026-06-27
---
```
Body per source:
- **`spec.md`** — Confluence behavior + copy digest for this phase. External sources it references are NOT inlined here — each lives in its own `<slug>.md`; just reference them by name where relevant.
- **`figma.md`** — the **Figma file/page link** + a **screen-node index**: one line per screen `` `node-id` · <Screen name> — <key layout / spacing / component / copy notes> `` so a UI fix jumps straight to the node without re-walking the file.
- **`<external-slug>.md`** (e.g. `ad_script.md`, `iap_pricing.md`) — ONE file per external source the spec references. `status: present` → the extracted content. `status: pending` → the link URL + "Couldn't read directly (`<HTTP status>`). What it holds: … — re-tried each capture; dev can paste content here.".
> **No `requests/` folder.** An unreadable external source's own `<slug>.md` is flagged `pending` (mirrored in `metadata.json`) and re-tried by direct read on each capture run; there is no separate request file and no co-worker delegation.

### Rules
- **One file per write** + `memory-sync.sh push <file> "<msg>"` (pull-rebase-retry) ⇒ concurrent devs never conflict. `spec.md` / `figma.md` / each external `<slug>.md` are **independent entries** — push only the one(s) captured or updated this run, each as its own commit; also push `metadata.json` whenever any source's status/version changed.
- **Source-of-truth = background capture, NOT a blocking gate. `spec` + `figma` are MANDATORY to *provide* (NOT waivable).** `pull 0` first. The capture runs in the background — only the *ask* for the mandatory links blocks; the digest never blocks Analyze/Fix (they fall back to the dev's provided refs via the Context-source rule until the digest lands).
  - **`spec` + `figma` — REQUIRED to end up with, no waive.** Resolved iff a link was **auto-discovered (Phase-2 §2.0)** or supplied (digested into the `.md` as `status: present`, or in flight as `capturing`). "we don't have it" is NOT accepted. Only when §2.0 finds **nothing** → ask the dev to **paste the Confluence + Figma link** and keep `blocked` until supplied (dev may cancel the run, but may not opt out).
  - supplied → capture the digest, write `status: present`.
  Return `blocked` only while a **required** source (`spec`/`figma`) is still unsupplied — analysis must not start. Capture/build only the missing or stale sources.
- **Staleness check (every run that hits the gate):** read `metadata.json` once; for each `present` source compare its live version against the manifest `version` — Confluence `version.number`, Figma file `lastModified`/`version`; external sources have no auto-version (trust `capturedAt` unless the dev flags it). Live newer → re-capture that one source + bump its `version`/`capturedAt` (in the file frontmatter AND `metadata.json`). All within bounds → reuse as-is (no rebuild, no push).
- **External sources — each captured into its OWN `<slug>.md` file (peer of spec); read directly, flag the unreadable, never block, re-try. NO `requests/` folder, NO co-worker delegation.** While distilling the spec, detect every embedded external link (Google Sheet/Drive/external URL), give it a slug (e.g. `ad_script`, `iap_pricing`), and **read it directly**: Google Sheet → `WebFetch` the CSV export `…/export?format=csv&gid=<GID>` (follow the 307 → `googleusercontent.com` redirect); Drive file → `WebFetch` `…/uc?export=download&id=<ID>` (follow the 303 → `drive.usercontent.google.com` redirect); or an authenticated Google MCP if connected. **Readable** → write the content into `<slug>.md` (`status: present`, `method: auto-direct-read`), add the source to `metadata.json` as `present`, push. **Unreadable (401/login)** → write `<slug>.md` with a `status: pending` placeholder (link URL + `reason` = HTTP status + a one-line note of what it holds), add the source to `metadata.json` as `pending`. Do NOT block. Every capture run that sees a `pending` external source `pull 0`s and **re-attempts the direct read**: now readable → fill its `<slug>.md`, flip it `present` in `metadata.json`, push both; still unreadable → leave flagged, proceed. The dev may also paste the content into the `<slug>.md` manually. Never fabricate a private Sheet's data to "unblock" — leave it flagged until read or pasted.
- **`figma.md` = link + screen-node index for the phase page:** record the file/page URL plus each screen's `node-id` + name + key design notes so the analyzer/fixer references the exact node fast instead of re-walking the file.
- **KB only when NOT app-specific logic** (framework/SDK/platform: ads/sub/notification/lifecycle/permissions…). App-logic bugs → status file only. `times_seen++` + add app if entry exists.
- **`project-setup` carries project-level fields ONLY** — never write the local `env` dep-cache (machine-specific) or any token/secret into `project/<PROJ>/setup.json`. Keep it as exactly one file per project; on update, overwrite it and stamp `savedBy` + `savedAt`.
- **English** in `knowledgebase/` + session/status files (grep/tooling); the analyzer's VN prose stays in the chat/plan, not the KB.
- Never write secrets. Never edit two entry files in one commit unless they're the same logical update.
- If `push` fails after retries, the entry is saved locally in the clone — surface it; do not silently drop.

## Onboarding bootstrap + shared-memory sync

Run at **Init phase** (after the env preflight, before intake). Gets a new dev set up from the shared manifest with their own credentials, and keeps the shared memory in sync. Idempotent — a configured dev skips straight through.

### Pieces
- **Memory repo is FIXED — `https://github.com/hung-apero/jira-bug-memory`, no fallback** (hardcoded as `FIXED_REPO` in `memory-sync.sh`; env `$JIRA_BUG_MEMORY_REPO` + the config `memoryRepo` field are ignored for resolution — no per-dev repo, no ask-for-URL, no local-only degrade).
- **Local config** `~/.claude/jira-bug-analyzer.json` → `{ memoryRepo, lastSync }` — `memoryRepo` is only cached for status readers; the real URL always comes from `FIXED_REPO`.
- **Shared memory clone** `~/.claude/jira-bug-memory` (the fixed private repo `github.com/hung-apero/jira-bug-memory`). Tree: `setup/manifest.json` (global MCP manifest), `project/<PROJ>/setup.json` (per-project setup), `project/<PROJ>/<PHASE>/doc/spec.md + figma.md + per-source <slug>.md` + `metadata.json` (one ground-truth file per source + the status manifest), `project/<PROJ>/<PHASE>/session/record_bug_status.md` (consolidated bug-status ledger — the sole session record + dedup), `knowledgebase/<category>/<slug>.md` (app-agnostic KB).
- **Sync helper** `assets/memory-sync.sh` — `init [url] | pull | push <file> [msg] | path | url`.
- **Non-secret manifest** `assets/mcp-setup-template.json` (shipped) → seeds `setup/manifest.json`.
- **Per-dev secrets** in `<project>/.claude/.env` (gitignored) — referenced from `.mcp.json` via `${ENV}`.

### Init phase sequence
1. **Sync memory — AUTO-WIRE the FIXED repo, no ask.** When init reports the clone is missing (`MEMORY_CLONE=absent`; `MEMORY_REPO` is always `configured` since the repo is a constant), run:
   ```bash
   bash <skill-dir>/assets/memory-sync.sh autowire   # clones the FIXED repo (never creates/discovers); prints one status line
   ```
   - **`WIRED:configured`** → memory is now cloned + synced — **no dev prompt**. Re-run init and continue (setup typically resolves `SETUP=remote`).
   - **`REPO_ACCESS:<url>`** → the fixed repo can't be cloned (offline / not `gh auth login`'d / no permission on `hung-apero/jira-bug-memory`). **Surface it and STOP** — the dev authenticates + requests access, then retry `autowire`. Do **NOT** ask for a different URL, create a repo, or proceed local-only (no fallback).
   Once wired, the normal TTL sync applies: `memory-sync.sh pull 600` (CACHE-FIRST: skips the git round-trip if synced within the 600s TTL; `pull 0` forces a refresh — done on `--resume`). Offline / pull fails → warn once, continue with the last local copy. **`autowire` NEVER creates a repo.**
2. **MCP setup is an INIT-PHASE step, driven by the template + an ask** (`assets/mcp-setup-template.json`; `setup/manifest.json` if richer):
   - **At init, read the template and probe it:** `bash <skill-dir>/assets/setup-mcp.sh status` → prints `TEMPLATE_SERVERS=` / `PRESENT=` / `MISSING=` / `NEEDS_SETUP=`.
   - **`NEEDS_SETUP=yes` → REQUIRED before proceeding (drop any already-live-elsewhere first; never silently install, never defer):** ASK `[OPTIONS]` *"Thiếu MCP: `<MISSING>`. Cài tất cả từ template ngay bây giờ?"* → `Cài tất cả từ template (bắt buộc)` / `Huỷ run`. On accept → **`bash <skill-dir>/assets/setup-mcp.sh all --token <JIRA_PERSONAL_TOKEN>`** — merges every template server (jira, confluence, figma, human-mcp) into **user-global `~/.claude.json`** `mcpServers` (NOT the committed project `.mcp.json`), **skipping any already present** (idempotent), writing the literal Jira token. `~/.claude.json` is uncommitted, so literal secrets are safe.
   - **All MCPs are provisioned at init, together, as a REQUIRED step** — not just `jira`, never deferred. Continue only once every template MCP is live (drop ones already live via another connector first). After `RESTART_REQUIRED=yes`, reload + re-probe.
   - **MCP setup happens ONLY at init — NEVER during the dev/fix flow.** The source-of-truth gate (confluence/figma) only **re-confirms liveness**; it does NOT run `setup-mcp.sh`. (The Phase 5 verify gate uses `adb` directly — no MCP involved.) If a template MCP is somehow not live at its gate, fall back (ask the dev to paste the spec/figma content) — do not provision mid-run.
   - **Why not `.claude/.env`:** Claude Code does NOT load `.claude/.env` into MCP server env, and a value-less `${VAR}` in config fails to parse. So MCP-consumed secrets must be literal in `~/.claude.json` (or already in the process env).
   - Ship the non-secret values (JIRA_URL/CONFLUENCE_URL/TOOLSETS) + the fixed Confluence/Figma creds from the template as-is.
3. **Collect per-dev secrets.** The only per-dev secret is `JIRA_PERSONAL_TOKEN` — prompt the dev (VN) and write it as the **literal** value into `~/.claude.json` `mcpServers.jira.env.JIRA_PERSONAL_TOKEN`. (Confluence/Figma ship fixed in the template.) `.claude/.env` is used ONLY for values the skill reads itself, e.g. `PR_DISCORD_CHANNEL_URL` (gitignored — add to `.git/info/exclude`).
4. **GitHub assumed configured** — do NOT re-check `gh`/git here (see Fix-3). `gh` is only used by `memory-sync init` to create the repo if missing.
5. **Reload only if needed.** If `.mcp.json` changed AND the affected `mcp__*` tools are not live in this session → ask (VN) *"Cấu hình xong — khởi động lại session bây giờ?"* `[Khởi động lại / Để sau]`. `Để sau` → warn the affected tools (jira/confluence/figma/mobile) stay inactive until restart. **After a restart, re-probe `mcp__jira__*` liveness** before proceeding (config written ≠ server connected). If nothing changed / already live → no prompt, continue silently.

### Writing memory (via `memory-keeper`)
All memory writes go through the `memory-keeper` agent — **dispatched as a background agent (`run_in_background: true`) per `[BGMEM]`** so the main loop never blocks on the git round-trip. It calls:
```bash
bash <skill-dir>/assets/memory-sync.sh pull
# ...write/update the single entry file under $(memory-sync.sh path)...
bash <skill-dir>/assets/memory-sync.sh push "project/<PROJ>/<PHASE>/session/record_bug_status.md" "chore: <TICKET> status=<stage>"
```
Per-entry files + pull-rebase-retry ⇒ concurrent devs never merge-conflict. Entry types: `project/<PROJ>/setup.json` (per-project setup, `action: project-setup`), `project/<PROJ>/<PHASE>/doc/spec.md + figma.md + per-source <slug>.md` + `metadata.json`, `project/<PROJ>/<PHASE>/session/record_bug_status.md`, `knowledgebase/<category>/<slug>.md`.

### Shared vs local (what crosses devs)
- **Shared in the memory repo** (cross-dev): `project/<PROJ>/setup.json` (project-level setup — board/status/assignee/spec/figma/otherRefs/pullQuery/model), source-of-truth (`project/<PROJ>/<PHASE>/doc/`), ticket/session status (`project/<PROJ>/<PHASE>/session/`), KB (`knowledgebase/`). SKILL.md Init-4 reads `project/<PROJ>/setup.json` so a teammate inherits the saved config.
- **Local only** (per machine, never pushed): `~/.claude/jira-bug-analyzer/probe-cache.json` (user-scope, shared across all projects on the machine — caches both the `TIER=now` dep preflight AND a per-server `MCP_SETUP` map (e.g. `{"jira":"ok","confluence":"ok","figma":"ok","human-mcp":"ok"}`) with a 30d TTL, since both derive from `~/.claude.json` not the repo; each dev's installed MCPs/creds differ; the cache is an MCP hit only when every server is `ok`, so a missing/new server self-heals on the next run; `--recheck-env` forces a fresh probe; a legacy project-level `<project>/.jira-bug/env-cache.json` is auto-migrated to this path on first run), and `~/.claude/jira-bug-analyzer.json` (`memoryRepo`, `lastSync`).

### Gotchas
- `${ENV}` from `.claude/.env`: confirm Claude Code expands it at MCP launch (Phase 02 / Gap 1). If not, fall back to creds in `~/.claude.json` (uncommitted) and document.
- Windows: run via Git Bash; `memory-sync.sh` uses `python3` for JSON (same as `preflight-env.sh`).
- Never commit `.claude/.env` or any token into the memory repo (md + non-secret config only).

## Bundle sync — folded helper skills

This skill is self-contained: it ships copies of its helper skills under `references/` so one install needs zero external skill deps.

| Folded copy | Standalone source (source of truth) |
|---|---|
| `references/android-self-verify/` | `.claude/skills/android-self-verify/` |
| `references/worktree/` | `.claude/skills/worktree/` |
| (none — native/plugin) | `run` skill — invoked directly, not foldable |

**The standalone skills are the source of truth.** When a standalone helper changes, re-copy it here:

```bash
SRC=.claude/skills
DEST=.claude/skills/jira-bug-analyzer/references
for sk in android-self-verify worktree; do
  rm -rf "$DEST/$sk" && cp -r "$SRC/$sk" "$DEST/$sk"
done
```

Resolution at runtime: prefer the folded `references/<skill>/SKILL.md`; if absent, fall back to the standalone skill of the same name. `run` has no folded copy — invoke the standalone/native skill directly.
