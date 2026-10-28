# §2.0 — Source-of-truth discovery: find the spec / figma / other refs from the PROJECT CODE + PHASE

> **The maintainable ruleset for HOW the skill finds a phase's ground truth.** Extracted from Phase 2 — that file now owns only the *capture* (digest the resolved links into memory); **this file owns the *discovery* (resolve them in the first place)**. Edit here to change how the skill hunts for a spec, and every mode/phase picks it up.
>
> **Called from:** Phase 2 (`references/phase2-source-of-truth.md`) — the one synchronous step before the background capture. Also cited by the multi pick step (`phase1-init-multi-mode-without-team.md`), the SKILL.md warm fast-path, and the `[AUTO]` golden rule.
>
> **Input:** the project code (`AIP686`) + the phase (`@3`, or derived). **Output:** a resolved `spec` + `figma` (+ `otherRefs`) with a tier, a `detectedFrom` provenance string, and a **rung trace** — or an explicit NONE with that trace. Cross-cutting invariants are SKILL.md **Golden Rules**, cited by tag.

## The rule: detect first, ask last
The dev almost always already put the links somewhere the agent can see — on a ticket, on an epic, on the fixVersion, in the project description. Asking them to paste what Jira already knows is pure friction.

Walk the rungs **in order and SHORT-CIRCUIT** — the moment spec (and figma) are resolved at STRONG, stop. A repeat run of a phase costs **zero calls** (L0/L1 cache hit). A first run with a known phase costs **≤4 Jira MCP calls, once per phase, then cached** (L2d/L2e/L2f). Every rung is MCP-native; **there is no discovery script**.

**The mental model: resolve the PROJECT and the PHASE first, then ask Jira where that phase's resources live.** `@N` is not just a folder name — it is the key that unlocks the fixVersion, the phase epic, and the project-wide sweep. A run given `AIP686 @3` has everything it needs to find the spec on its own; it should never fall through to a paste-ask without having actually asked Jira.

| # | Source | How | Tier | Fires in practice? |
|---|---|---|---|---|
| **L0** | `<PHASE>/doc/metadata.json` present + fresh | memory (the existing cache path) | — → SOT ready, **no discovery, no ask** | **often** (2nd+ run of a phase) |
| **L0.5** | **`--spec <url>` / `--figma <url>` passed on the invocation** | the arg itself — no call | **STRONG** (beats L1 and every rung below) | **override / escape hatch** — correcting a wrong adopt, or a project Jira genuinely knows nothing about. **NOT the primary path** — L2d/L2e should find it |
| **L1** | `setup.json` `sotByPhase[<PHASE>]` | `assets/setup-json.sh get <file> sotByPhase.<PHASE>.spec` | **STRONG** | **often — the win on repeat runs.** Resolved once per phase, then never again |
| **L2** | The picked tickets' `description` + `comments` — Confluence/Figma URLs (**host-agnostic**, see "URL shapes") | free — bodies already in context from the pull. **Read the RAW wiki `description` from `jira_search`, NOT `jira_get_issue`** (see the corruption trap) | **STRONG** | **rarely** — only on tooling-created tickets |
| **L2b** | The tickets' **remote links** (+ parent) — a Confluence page *explicitly linked to the ticket* | `jira_get_issue(<KEY>, include="remote_links")` → `remote_links[].object.url` + `.title` | **STRONG** | **rarely** — see the coverage reality below |
| **L2c** | **Labels** — a ticket created by the `confluence-to-jira` tooling carries `auto-from-confluence` + `confluence-<page-slug>` | already in `fields.labels`; the slug names the spec page | **STRONG** | tooling-created tickets only |
| **L2d** | **PROJECT-WIDE link sweep** — any issue in the project carrying a Confluence/Figma URL, not just the picked bugs | ONE `jira_search` JQL (recipe below). Hit on an issue whose `fixVersions` = the resolved phase version → **STRONG**; hit elsewhere in the project → FUZZY | **STRONG / FUZZY** | **the backbone for `@N` runs** — bugs carry no links, but the project's epics/stories do |
| **L2e** | **The phase OBJECT itself** — the fixVersion and/or the phase Epic named `Phase <N>` | `jira_get_project_versions(<PROJ>)` → version `name`+**`description`** · then `jira_search` `issuetype=Epic AND (summary ~ "Phase <N>" OR fixVersion = "<ver>")` → its description + `jira_get_issue(include="remote_links")` | **STRONG** | **often** — version/epic descriptions are where PMs put the spec link |
| **L2f** | **Project metadata** — the project's own `description` / lead / URL field (space link often lives here) | `jira_get_all_projects` (or `jira_search_projects "<PROJ>"`) → match `key == <PROJ>` → read `description` | FUZZY | cheap one-call bonus |
| **L3a** | **Siblings of the previous phase's spec** — the old spec URL hands you the space *and* the parent for free | `confluence_get_page_children(<parent of sotByPhase[phaseN-1].spec>)`, match title `Phase <N>` | MEDIUM | when a prior phase was captured |
| **L3b** | Confluence search | `confluence_search` (raw CQL): `type=page AND text ~ "<PROJ>" AND title ~ "Phase <N>"`, limit 5, recent first | **FUZZY** | the Confluence-side rung when Jira yields nothing → pick-list |
| **L4** | Figma links **inside the resolved spec body** | free — the capture already scans the spec for embedded links | **STRONG** | **the most reliable figma source** |
| **L5** | Figma file whose name matches the project/phase | `mcp__figma-bridge__list_files` | FUZZY | last resort |

## L2d/L2e/L2f — project-level discovery via Jira MCP (the `@N` path)
This is what a run like `/jira-bug-analyzer AIP686 @3 --auto` does **before** concluding anything is missing. **≤4 MCP calls, once per phase**, then cached — it does NOT re-run on later turns.

Run in this order, **short-circuiting** the moment spec is STRONG:

**Step 1 — resolve the phase OBJECT (L2e), and with it the phase's real name.**
```
jira_get_project_versions(<PROJ>)          # → [{id, name:"Phase 3 — Gamification", description, released, …}]
```
Match `@N` against each version `name` (`Phase 3` · `Sprint 3` · `Milestone 3` · `v3` · `3.0`). This gives three things at once:
- **confirmation the phase exists** (an `@N` with no matching version is worth surfacing — likely a typo),
- **the phase's full human name** → feeds the L3b CQL `title ~` and the auto-adopt bar (a far better matcher than the bare string `"Phase 3"`),
- the version's **`description`**, a common place for the spec link — **regex it for Confluence/Figma URLs (URL shapes below) → STRONG on a hit.**

Then the phase **Epic**:
```
jira_search(jql='project = <PROJ> AND issuetype = Epic AND (summary ~ "<phase name>" OR fixVersion = "<version name>")',
            fields='summary,description,issuelinks', limit=5)
jira_get_issue(<epicKey>, include="remote_links")     # only for the best epic match
```
The epic's `description` (RAW wiki — see the corruption trap) + its `remote_links` are the single most reliable spec source in a PM-run board. Hit → **STRONG**.

**Step 2 — project-wide link sweep (L2d).** One call, no phase needed:
```
jira_search(
  jql='project = <PROJ> AND (description ~ "confluence" OR description ~ "figma" OR comment ~ "figma.com" OR comment ~ "confluence") ORDER BY created DESC',
  fields='summary,description,issuetype,fixVersions,labels', limit=25)
```
Regex every returned **RAW `description`** for Confluence/Figma URLs, then rank:
1. issue's `fixVersions` contains the resolved phase version → **STRONG** (it is this phase's link),
2. `issuetype` ∈ {Epic, Story, Task} → FUZZY-high,
3. anything else (another Bug) → FUZZY-low.

**A `figma.com` URL found by this sweep is a legitimate figma source** — unlike the bug-body rung, which genuinely has nothing.

**Step 3 — project metadata (L2f), only if 1+2 came back empty.**
```
jira_get_all_projects()      # or jira_search_projects("<PROJ>") → match key
```
Read the project `description` for a space/docs link → FUZZY.

**Cache the whole probe** into `sotByPhase[<PHASE>]` alongside the links (see "Persist what was resolved"): `phaseVersion`, `phaseEpic`, `probedAt`, `detectedFrom`. Later turns hit **L1** and skip Step 1–3 entirely — the sweep is a per-phase one-off, not a per-turn cost.

**`[VN]` surface what it found**, one line, so a wrong adoption is caught instantly:
`✅ Tự phát hiện qua Jira: Phase 3 = "Phase 3 — Gamification" (fixVersion) → spec từ Epic AIP686-12 (remote link)`

**Failure is silent and non-fatal** — a project with no versions, a `jira_search` that errors on a `~` operator the instance doesn't support (some Server configs), an empty sweep: skip that rung, record it in the trace, fall through to L3a/L3b. Never crash, never block.

## ⚠️ Coverage reality — measured, not assumed
Probed against real Apero boards (AIP686 / AIP304 / AIP688), **the tickets this skill actually processes — human-filed bugs — carry no links at all**: `remote_links` is `[]`, there is no Confluence URL in the description or comments, and there are **ZERO `figma.com` URLs on the bugs across all three projects** (designs get referenced as `prnt.sc` / `streamable.com` links or inline image attachments instead). Only tickets created by the `confluence-to-jira` tooling (labelled `auto-from-confluence`) carry a spec link.

**⚠️ But that measurement was scoped to the PICKED BUGS — and that scoping was the mistake.** "The bugs carry no links" does NOT mean "the project carries no links": the same project's **epics, stories, fixVersions and project description** are written by PMs and by the `confluence-to-jira` tooling, and those routinely DO carry the spec. The old ladder only ever looked at the 3–4 bugs in front of it, concluded NONE, and gave up. **L2d/L2e/L2f exist to fix exactly that: sweep the PROJECT, not the picked set.** A bug ticket is the worst possible place to look for a spec link — it is just the only place the old ladder looked.

What each rung actually buys:
- **L2 / L2b / L2c are a bonus**, not the backbone — they fire on tooling-created tickets and essentially never on a hand-filed bug.
- **L2d/L2e are the backbone whenever the phase is known** (`@N` given or derived) — they search where the links actually live, and a hit tied to the phase's own fixVersion is STRONG enough to adopt unattended.
- **L1 is the win on repeat runs** — resolved at most once per phase, then cached *per phase* (never mis-inherited from another phase).
- **Figma usually comes from L4** (a link inside the spec). **Do not build a figma rung against BUG bodies** — but **L2d does sweep the whole project for `figma.com`**, a much better bet.
- **NONE → the paste-ask** should be rare, not routine. If it fires on a project with an active `@N`, that is a signal worth reporting (the rung trace shows which sweeps came back empty).

## ⚠️ The URL-corruption trap — regex the RAW wiki field, never the converted one
`jira_get_issue` converts Jira wiki markup → markdown and **silently strips `+` from URLs**:
`…/display/PROJ/Phase+4%3A+Gamification` → `…/display/PROJ/Phase4%3AGamification` — **which 404s.** Any body-regex that reads `jira_get_issue`'s `description` therefore yields dead links, unrecoverably (you cannot re-insert the spaces post-hoc).
- **L2b's `remote_links[].object.url` is NOT affected** — it is the only source that returns a correct URL. **Prefer it.**
- For L2 **and L2d/L2e's description regex**, read the **raw wiki `description` via `jira_search`** (`fields=description`), where the link is still `[Title|https://…/Phase+4%3A+Gamification]`.
- Match the **wiki-markup link form**, not just a bare URL: `\[([^|\]]+)\|(https?://[^\]\s]+)\]`, and allow `+` and `%XX` in the path.
- On Jira **Server**, `remote_links[]` entries have **only** `object.url` + `object.title` — `relationship`, `globalId` and `application.name` are absent. Do not branch on them.

**A dead/absent MCP is not an error** — that rung is skipped and the ladder falls through to the next. Discovery must never crash or block the run.

## URL shapes — match HOST-AGNOSTICALLY (Cloud *and* self-hosted Server)
**Do NOT hardcode `atlassian.net`.** Many orgs (Apero included) run **self-hosted Confluence/Jira Server**, where the spec lives on `confluence.<org>` and the URL shape is completely different from Cloud's. A Cloud-only regex silently detects nothing and the whole ladder collapses to the paste-ask. Match **any** of:

| Product | Cloud | Self-hosted Server |
|---|---|---|
| **Confluence** | `<site>.atlassian.net/wiki/spaces/<SPACE>/pages/<ID>/<Title>` | `confluence.<org>/pages/viewpage.action?pageId=<ID>` · `confluence.<org>/display/<SPACE>/<Title>` |
| **Jira** | `<site>.atlassian.net/browse/<KEY>` | `jira.<org>/browse/<KEY>` |

→ Treat a URL as **Confluence** when its host contains `confluence`, **or** its path contains `/wiki/spaces/`, `/pages/viewpage.action`, or `/display/`. Figma is a fixed SaaS host: `figma.com/(design|file|proto|board)/…`.
→ The org's actual hosts are already known at runtime — derive them from the configured Jira/Confluence MCP base URLs rather than assuming, and never assume Cloud.
→ `sotByPhase[…].spec` may be stored as a bare URL string **or** as an object (`{"confluence": "<url>"}` — the shape some existing setups already carry). Accept both on read; write the bare string.

## Applies to EVERY mode — detection is universal, only the CONFIRMATION differs
**Single, multi, team and `--auto` all run this ladder.** There is no mode that skips discovery: single mode mines its one ticket **plus the whole project** (L2d/L2e/L2f are project-scoped — they do not care how many tickets were picked), multi/team mine the picked set plus the project, `--auto` does the same unattended. The *only* thing that varies by mode is what happens **after** a candidate is found:

| | **Interactive (manual)** — single · multi · team | **`--auto`** |
|---|---|---|
| **Detection** | full ladder | full ladder — **identical** |
| **On a result** | **ALWAYS confirm with the dev** (below) | **never ask — self-verify instead** (below) |
| **On NONE** | blocking paste-ask | rung trace; per ticket: expected result from ticket / code precedent → proceed, else `no-sot` defer |

### Interactive — ALWAYS confirm the adoption, never adopt silently
Even a STRONG, unambiguous hit is **proposed, not imposed**. Auto-detection saves the dev from *typing* the link; it does not entitle the agent to *assume* it. A wrong spec silently adopted poisons every ticket in the phase and is very hard to notice later — one cheap confirm is worth it, and it costs a single tap.

| Outcome | Do this |
|---|---|
| **STRONG, unambiguous** | **Show what was found and ask a ONE-TAP confirm** `[OPTIONS]` — never a silent adopt, never a bare paste prompt. Present *title · nguồn (rung + evidence) · link*, options: **`Đúng, dùng cái này`** (recommended) · `Chọn ứng viên khác` (→ pick-list of the runner-ups) · `Dán link khác` (free-text) · `Không có spec`. Example prompt line: `Tự tìm được spec: "AIP686 — Phase 3 Reader" (từ remote-link của Epic AIP686-12). Dùng cái này?` |
| **FUZZY**, or **≥2 STRONG candidates that disagree** | **One-tap `[OPTIONS]` pick-list** — top 3 candidates, each showing *title · nguồn · vì sao khớp* — plus `Dán link khác` (free-text) and `Không có`. |
| **NONE** (ladder exhausted) | Fall back to the **blocking free-text ask** — the last resort, never the entry point. `spec`+`figma` cannot be waived here. |

**Confirm ONCE per phase, not per turn.** The confirmed answer is persisted to `sotByPhase[<PHASE>]` (L1) — every later turn and every later run of that phase reuses it with **no prompt at all**. Re-confirmation happens only on `--rediscover`, or when the resolved link changes.

### `--auto` — no ask; SELF-VERIFY before trusting the hit
**The ladder STILL WALKS — `--auto` forbids *asks*, not *detection*. Skipping discovery under `--auto` is a BUG** (SKILL.md `[AUTO]`). Since no human confirms, `--auto` must **earn** that trust by checking the candidate itself before adopting:

1. **Fetch it, don't just link it.** Open the candidate Confluence page (`confluence_get_page`) / Figma node. **Unreachable, 404, or empty → NOT a valid hit**; drop it and continue down the ladder. A URL that was never fetched is an unverified guess.
2. **Verify identity against the project + phase.** The fetched page's title/breadcrumb/body must corroborate **both** the project (key or name) **and** the phase (`@N`, or the L2e version name). Corroborated → adopt. Contradicted (e.g. the page says Phase 2) → **reject and record**, never "close enough".
3. **Verify it is a spec, not a stub.** A page with no requirement/behavior content (a placeholder, an index page, a meeting note) fails — adopt only something that can actually answer "what was this supposed to do".
4. **FUZZY → the deterministic auto-adopt bar below.** Bar not cleared → treat as NONE.
5. **NONE / all candidates rejected → never ask**: record the gap in the "what's missing" report + the end-of-run report **with the rung trace** (which rungs ran, what each returned, why each candidate was rejected) and hand the tickets to the per-ticket check in `references/helpers/auto-plan-pick.md` (expected result from the ticket or a code precedent → proceed; else defer `no-sot`). Discovery never stalls the auto loop.

Persist the verification outcome with the entry (`"verifiedBy": "auto:page-fetch+phase-match"`), and state it in the `[VN]` line so the dev can audit the batch afterwards. **An `--auto` adoption that skipped steps 1–3 is not an adoption — it is a guess, and guessing the spec is worse than deferring.**

### The FUZZY auto-adopt bar (`--auto` only) — deterministic, not a judgment call
A FUZZY candidate may be adopted **without a human** only when one of these is objectively true:
1. the rung returned **exactly ONE** candidate, **or**
2. the top candidate's title contains **BOTH** the project key/name **AND** the resolved phase marker, **AND no other candidate contains both**. **Match against the phase's REAL name resolved by L2e** (`jira_get_project_versions` → e.g. `"Phase 3 — Gamification"`) when available, not just the literal `Phase <N>` — a real version name is a far stronger discriminator, **or**
3. the candidate came from **L2d/L2e tied to the phase's own `fixVersion`** (the link was found on an issue or version object belonging to this exact phase). That tie is objective provenance, not a guess — it is already STRONG and needs no bar.

Anything else — two plausible titles, a project-key match with no phase marker, a phase marker on the wrong space — **fails the bar and is treated as NONE**. Never "pick the most likely one"; a wrong spec poisons every ticket in the phase.

On auto-adopt: persist `autoAdopted: true` alongside `detectedFrom`, **plus `runnerUps: ["<title>", …]`** (the candidates you rejected), and emit ONE `[VN]` line + an end-of-run report row so a wrong adoption is auditable and reversible with `--rediscover`:
`🤖 Tự chọn spec (auto): "AIP686 — Phase 3 Reader" (CQL trả duy nhất 1 kết quả) — sai thì chạy lại với --rediscover hoặc --spec <url>`

## The `<PHASE>` chicken-and-egg — read this before implementing L2e/L3
The phase is normally *confirmed from the spec title* (Phase 2, "Which phase folder") — but L2e/L3a/L3b need the phase in order to *find* the spec. Resolve it this way:
- **`@N` given** → authoritative, **and it is the key that unlocks project-level discovery**: resolve it against `jira_get_project_versions(<PROJ>)` to get the phase's REAL name/description (L2e), which then targets L2d's ranking, L3a/L3b's `title ~`, and the auto-adopt bar. `@N` with no matching version → still honor `@N` for the folder, but **surface it** (likely a typo, or the board tracks phases as epics/labels instead of versions — fall back to matching epics by `summary ~ "Phase <N>"`).
- **No `@N` → try to DERIVE `N` from the picked tickets before giving up on L2e/L3.** The pull already carries the fields: read the picked set's **`fixVersions`**, **sprint name**, and **`labels`** and extract a phase marker (`Phase 3` · `Sprint 3` · `phase-3` · `Milestone 3` · `v3.0` → `N=3`). **All picked tickets agree on one `N` → adopt it for discovery ONLY and enable L2e/L3a/L3b** (a resulting CQL hit is still FUZZY → it must clear the auto-adopt bar under `--auto`). Tickets disagree, or no marker anywhere → fall back to the rule below. A derived `N` is **weaker than `@N`**: it targets the search, and the final `<PHASE>` is still confirmed from the found spec's title. Surface it — `ℹ️ Suy ra Phase 3 từ fixVersion của các ticket đã pick (không có @N)`.
- **No `@N` and no derivable `N`** → run the **phase-independent rungs** (L0.5 / L1 / L2 / L2b / **L2d** / **L2f** / L4 — L2d's project sweep and L2f's project metadata need no phase at all, they just can't rank by fixVersion), then derive the phase from the found spec's title. **Skip blind CQL** — `title ~ "Phase <N>"` without an `N` is meaningless — and skip L2e (it is phase-keyed). Nothing found → rung trace + remedy: pass `@N` (unlocks L2e + ranked L2d), or override with `--spec`/`--figma`.

## Persist what was resolved
On adopt (STRONG) or confirm (pick-list), write the phase's entry to **BOTH** the local `.jira-bug/setup.json` mirror **AND** the shared `project/<PROJ>/setup.json`, same turn, via `memory-keeper` (`[BGMEM]` — background, non-blocking):
```
setup-json.sh merge-set <file> 'sotByPhase.phase3={"spec":"…","figma":"…","otherRefs":"…","phaseVersion":"Phase 3 — Gamification","phaseEpic":"AIP686-12","detectedFrom":"jira:epic-remotelink","autoAdopted":false,"confirmedBy":"hungnd","savedAt":"2026-07-14","probedAt":"2026-07-14"}'
```
**Use the dotted form** — a plain `sotByPhase={…}` REPLACES the object and destroys the other phases' entries. Local-only = the next dev gets re-asked, so the shared push is mandatory, not deferred. Schema + the legacy-flat demotion rule: `references/helpers/memory.md`.

## The override flags — `--spec` / `--figma` / `--rediscover`
- **`--spec <url>` / `--figma <url>` = the L0.5 rung.** Priority **above L1** — an explicitly passed link is the dev speaking; it **overrides** a cached `sotByPhase` entry (that is how you correct a wrong auto-adoption). Tier **STRONG, zero prompts**, in every mode including `--auto`. Validate the shape only (Confluence per the URL-shapes table · `figma.com/(design|file|proto|board)/…`); a malformed value → one `[VN]` warning and that half falls through to normal detection, never a crash. **Either or both** — `--spec` alone still lets figma resolve via L4. **Persist immediately** to BOTH layers exactly like an adopt (`detectedFrom: "arg:--spec"`), so it is a **one-shot seed**: subsequent runs of the same phase hit L1. The phase it seeds is `@N` when given, else the phase confirmed from the seeded spec's own title — **do not write it into `phase1` by default**.
- **`--rediscover`** forces a fresh detect: skip the L0 (`metadata.json`) and L1 (`sotByPhase`) short-circuits and re-walk the ladder from L2. Use it when the spec page moved, or a wrong page was adopted.

## What discovery returns to Phase 2
- **resolved** — `spec` (+ `figma`, + any `otherRefs`) with tier, `detectedFrom`, and the rung trace → Phase 2 launches the background capture on them. **The links are usable context immediately** (Phase-3 Context-source rule); analysis never waits for the digest.
- **none** — the ladder is exhausted. Interactive → the blocking paste-ask (spec+figma cannot be waived). `--auto` → **never ask**: emit the rung trace + remedy; each ticket then needs an expected-result source (ticket / code precedent) or defers `no-sot`.

**Reaching `none` without having run L2d/L2e/L2f (when a phase was known) is a BUG, not a legitimate NONE** — the trace must show those sweeps actually ran and came back empty.
