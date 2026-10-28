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


> **The full text is `references/details/source-of-truth-discovery.md` — never read it whole** (the A/B runs measured 125–183k characters of reference text per ticket in the main session, paid again every turn).
> Read the one section a checklist line or a step needs: `bash <skill-dir>/assets/section.sh <skill-dir>/references/details/source-of-truth-discovery.md "<anchor>"`.

## Sections (anchors for section.sh)
```
    l2d/l2e/l2f — project-level discovery via jira mcp (the @n path)
        step 1 — resolve the phase object (l2e), and with it the phase's real name.
        step 2 — project-wide link sweep (l2d).
        step 3 — project metadata (l2f), only if 1+2 came back empty.
    ⚠️ coverage reality — measured, not assumed
    ⚠️ the url-corruption trap — regex the raw wiki field, never the converted one
    url shapes — match host-agnostically (cloud and self-hosted server)
    applies to every mode — detection is universal, only the confirmation differs
      interactive — always confirm the adoption, never adopt silently
      --auto — no ask; self-verify before trusting the hit
      the fuzzy auto-adopt bar (--auto only) — deterministic, not a judgment call
    the <phase> chicken-and-egg — read this before implementing l2e/l3
    persist what was resolved
    the override flags — --spec / --figma / --rediscover
    what discovery returns to phase 2
```
