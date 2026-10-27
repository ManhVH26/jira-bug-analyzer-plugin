# jira-bugfix Agent Team — roles & launch

> Durable definition + launch recipe for the parallel Jira bug-fixing team. The lead (MainCharacter) loads this at `--team` launch. Run state lives in `.jira-bug/team-board.md`. (Roles section first, then the launch recipe.)

## Team `jira-bugfix` — Role Cards & Coordination Memory

Durable definition of the parallel Jira bug-fixing Agent Team. The lead (MainCharacter) loads this file at launch and spawns one teammate per card. Pair with the Launch Recipe section below and the live `.jira-bug/team-board.md` (run state).

> **Substrate (either runs this identical team):** **(A)** native Agent Teams (`TeamCreate` exposed) — live teammate sessions + tmux panes; CLI only (NOT VSCode), all teammates on Opus, requires `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`. **(B)** Agent-tool fallback (`TeamCreate` not exposed, but `Agent` + `TaskCreate`/`TaskUpdate` + `SendMessage` are) — same roles as background named Agents coordinated via the Task board; no panes, terminal-agnostic. Hard-block only if NEITHER exists. See `references/phase1-init-multi-mode-with-team.md` → Init-8 / the Launch Recipe section (§0 below).
> **Each Dev/role works the SAME `/jira-bug-analyzer` skill** — but in a *team-truncated* way governed by these cards (see "Team-mode deviations").

---

### Topology

```
MainCharacter (lead, --delegate)
├── Github Observer        (persistent · cheap · watches PRs/CI)
├── Dev1 .. DevN           (code-only · own worktree · NO device)
├── Tester                 (SOLE device owner · serial verify)
└── Dev-Fixer-PR           (applies review-comment fixes)
```

N (Dev count) is a launch parameter — pick it from board size at run time.

---

### Per-ticket lifecycle (the board `stage` column)

```
claimed → analyzing → plan-ready → approved → fixing → committed → ready(in PR-round window)
   → round-verify(build once, all tickets) → verify-pass → pr-open → in-review → (fixing-review ⇄ round-verify) → resolved
                    ↘ verify-fail → fixing (rejoins NEXT round)        ↘ blocked
```

PRs are cut in **rolling 5-min rounds**: a ticket sits at `ready` until the window closes, then the round's commits are verified together (`round-verify`) and shipped in one PR. Late/`verify-fail`/cherry-pick-conflict tickets roll to the next round.

TaskList (native) is **authoritative** for `stage`. `.jira-bug/team-board.md` is the durable, human-readable mirror updated at every handoff (recovery anchor if a session dies).

---

### Approval policy (decided)

- **Stream approvals per ticket — NO barrier. Do NOT batch.** The instant a Dev's root-cause + fix-plan arrives, the lead presents/decides it **immediately** and the Dev proceeds to fix **right away** — in parallel with other Devs still analyzing. Never hold ticket A's plan waiting for B/C to finish analyzing ("human gates batched" is the wrong behavior). A slow analysis on one ticket must never stall approving + fixing another.
- Lead **auto-approves** fix-plans whose `Mức rủi ro` (Risk) is **low**, and clean code-review diffs.
- **Medium / high** risk plans, or any contested/large diff → **escalate to the human** via the lead — but still **per ticket as it arrives**, not collected into a batch.
- The analyzer's Vietnamese fix-plan `Mức rủi ro` field is the gate signal.

---

### Mandatory verify gate (team mode — same force as solo)

The **verify gate is MANDATORY and PR-blocking**, exactly as in solo `/jira-bug-analyzer`. The gate has two parts and follows the solo `--auto` rule:
- **User-verify (Lead/human checklist) — ALWAYS mandatory**, every round, regardless of `--auto`. No round PR opens without it.
- **adb self-verify (Tester, device-driven) — runs ONLY on `--auto`** (mirrors solo Phase 5 Gate 2). Without `--auto`, Tester does not drive the device; the Lead/human user-verify card is the gate. With `--auto`, Tester also runs the Phase 5 adb self-verify (`adb`, NOT mobile-mcp).

In team mode the device side of the gate is **owned by Tester** and run **once per PR round** — deferred, but (within its `--auto` condition) NEVER optional:

- **No ticket reaches `pr-open` without verify-pass.** The only board path is `ready → round-verify → verify-pass → pr-open`. There is **NO** edge from `ready`/`committed` straight to `pr-open`/`resolved`. The lead **MUST** run the round's user-verify (and the Tester adb self-verify when `--auto`) and **MUST NOT** open the round PR until every ticket the round carries passes.
- **A `ready` ticket cannot sit unverified.** When the PR-round window closes (or all picked tickets are terminal), the lead **cuts the round and verifies it immediately** — **even a round of ONE ticket** gets the full round build + Gate-1 GitHub-diff review + user-verify (+ the Tester adb self-verify when `--auto`). Never skip because "only one ticket" or "the fix looks trivial / it compiled".
- **Only the human may waive** a verify (mirrors solo's only-user-can-skip). The lead never self-skips the gate.
- `verify-fail` → drop from this round → back to the Dev → rejoins the **next** round (re-verified there). `blocked` (no device after retries, `--auto`) → lead surfaces to the human; do **NOT** proceed to PR.
- **If the lead is about to PR and a ticket has no recorded verify verdict → STOP and run the verify first.** A missing verdict is treated as fail, never as pass.

---

### Team-mode deviations from solo `/jira-bug-analyzer` (CRITICAL — every Dev obeys)

1. **Devs are code-only.** Run claim → analyze → plan → fix → **build the APK** (`<BUILD_CMD>`), then **STOP at the verify gate** and hand to the Lead/Tester. A Dev NEVER runs the Phase 5 adb self-verify (`adb`, NOT mobile-mcp), NEVER acquires the device lock, NEVER `adb install`.
2. **Devs do NOT arm the PR-watcher cron.** Github Observer owns watching. (Solo Phase 6 watcher-cron step is skipped in team mode.)
3. **Dispatch is central.** Devs do NOT self-pull the board; the lead pulls + claims + assigns. A Dev only works the ticket handed to it.
4. **Approval goes to the lead, not the human directly** — Dev sends the plan/diff to the lead, who applies the approval policy above.
5. Everything else (claim-before-analyze In-Progress lock, Vietnamese root-cause/fix-plan, worktree off `origin/<BASE>` (the resolved `setup.json.baseBranch`, NOT a hardcoded `origin/main`), one-commit-per-ticket, Jira-via-REST, Discord enqueue) is unchanged.

---

### File ownership (no overlapping edits)

- Each **Dev owns its own worktree only**: `../<proj>-<TICKET>` on branch `phaseX/fixbug/<TICKET>`. No Dev edits another Dev's worktree.
- **Tester owns no source** — reads Dev worktrees, drives the device, writes only verdicts (messages + board).
- **Dev-Fixer-PR** edits only the worktree of the PR it is fixing (hand-off from Observer).
- **Lead** owns the board file + TaskList + Jira claims/assignments; edits no source (delegate mode).
- `.jira-bug/team-board.md` is written by the **lead only** (others report via SendMessage; lead transcribes) to avoid write races.

---

### Step → Role ownership matrix (natural-seam delegation)

Every `/jira-bug-analyzer` step maps to ONE owning role. The **Dev owns a contiguous slice** (analyze→fix→PR) so investigation context never crosses sessions — ownership only changes hands at real seams.

| Skill step | Owner | Scope | Handoff trigger |
|---|---|---|---|
| Init-1 env preflight (`init-team.sh`) | **Lead** | once / team run | — |
| Init team board (`TEAM=active` display) | **Lead** writes · **all** read | continuous | board updated each handoff |
| Init setup memory · Init-9 intake (model/board/status/spec/figma) | **Lead** | once / team run | — |
| Init-5 resume / `--resume` reconcile | **Observer** (PR watchers) · **Lead** (batch state) | continuous | — |
| Pull & list by category (`phase1-init-multi-mode-without-team.md`) | **Lead** | once / round | — |
| Fix-1 claim (In-Progress lock) + assign | **Lead** | per ticket | → assigns a Dev |
| Source-of-truth capture (spec/figma/external — background, non-blocking) | **Lead** | once / phase | §2.0 auto-discover spec/figma (`references/helpers/source-of-truth-discovery.md`; Lead confirms the hit), then background-capture digest |
| Pre-fix context import (doc digests) | **Dev** | per ticket | — |
| **Fix-3–Fix-6** fetch → attachments → media → root cause + plan (VN) | **Dev** | per ticket | Dev → Lead: plan |
| Fix-7 clarify | **Dev** drafts | per ticket | ambiguity → Lead / human |
| **Fix-8 approval** | **Lead** | per plan | auto low-risk · escalate med/high |
| Fix-9 non-code VN comment | **Dev** posts | per ticket | ticket disposition → Lead |
| Fix-10 worktree · Fix-11 fix by the plan · Fix-12 **build APK** (`<BUILD_CMD>`) + **commit (1/ticket)** | **Dev** | per ticket | Dev → Lead: ready (joins PR round) |
| **PR round window (5m, rolling)** — collect `ready` tickets, cut round at cutoff | **Lead** | per round | → assemble round branch |
| Phase 5 — assemble round branch + **build ONCE** (combined commits) | **Lead** (+ Dev worktrees) | per round | → Tester for device |
| Phase 5 Gate 1 — **review the combined round diff on the GitHub webview** (FIRST) | **Lead** | per round | `No change` → build · `Needs change` → Dev (Phase 4 impl) / Phase 3 (plan) |
| Phase 5 Gate 2 — **adb self-verify ALL round tickets in one build** (`adb`, NOT mobile-mcp) — **ONLY on `--auto`** | **Tester** (sole device owner) | **per PR round** (one lock, one install) | pass → user-verify · a ticket fails → that Dev (next round) · **no verdict → STOP, do not PR** |
| Phase 5 Gate 2 — **user-verify checklist** (one block per ticket: link, title, description, image/video, expected, steps) — **ALWAYS mandatory, PR-blocking; only the human may waive** | **Lead / human** | per round | OK → round PR · needs-update → Dev/Phase 3 |
| Phase 6 — open round PR (**full Phase-3+5 body**) + **attach PR + Jira Resolved in a background subagent** (link, Resolved, worklog, Discord enqueue) for every ticket it carries | **Lead** | per round | → Observer arms watch |
| PR watcher — watch review comments / CI | **Observer** | post-PR | new comment → Dev-Fixer-PR |
| PR review-comment fixes + "đã fix, review lại" | **Dev-Fixer-PR** | post-PR | behavior change → Tester re-verify |
| Worktree cleanup on merge/close | **Lead** | post-merge | Observer signals |

**Contiguous Dev slice (one session, never split):** Fix-3–Fix-7, Fix-10, Fix-11, Fix-12 (compile). Verify = **Phase 5** (Tester, adb), commit + PR = **Phase 6** (Lead).
**Seams (ownership changes hands):** Lead↔Dev at claim + approval; Dev↔Tester at device-verify (Phase 5, adb); Dev↔Observer↔Dev-Fixer-PR post-PR.

> Why not finer? Splitting analyze (1–4) from fix (8) across sessions re-loads the root-cause context the analyzer built — net loss. The analyzer→fixer split is the one exception (and it **streams per ticket — no barrier**: each plan is approved and fixed the moment it's ready, not collected into a wave), passing the **approved plan verbatim** to the fixer to preserve that context.

---

### Role cards

#### MainCharacter (lead)
**Charge:** orchestrate, never touch source (`--delegate`).
- **Pull & claim:** run the `/jira-bug-analyzer` pull query (board/status/assignee from setup). Group by natural category, cap ≤4/category. **Claim each picked ticket** (In-Progress lock + assign to dev account) BEFORE assigning.
- **Dispatch:** create one Task per claimed ticket; assign exactly one to each free Dev. Maintain the board file.
- **Approve:** receive Dev fix-plans + the round's combined diff. Apply the approval policy (auto-approve low-risk; escalate med/high to human) — **streamed per ticket, no batching**.
- **PR rounds (windowed):** collect Devs' `ready` tickets into a **rolling 5-min window** (`--pr-window`, default 5m). At each cutoff: assemble the **round branch** (cherry-pick per-ticket commits, defer conflicts to next round), **review the combined diff on the GitHub webview** (`No change`/`Needs change` → back to Phase 4/Phase 3 by scope), have it **built ONCE**, **hand it to Tester to user-verify ALL its tickets in one build (MANDATORY — see "Mandatory device-verify gate"; adb self-verify only on `--auto`)**, then **open ONE PR for the round** (full Phase-3+5 body) and finalize Jira (attach PR + Resolved, background subagent) for every ticket it carries. Reopen the window for later/deferred tickets → next round → next PR.
- **Always cut the round at the window close — even with a single `ready` ticket** — and **always route it through Tester before any PR**. A `ready` ticket must never skip verify or stall unverified waiting for siblings.
- **Coordinate:** resolve file-ownership/blocker conflicts; on a teammate `blocked`, provide context / re-scope / escalate.
- **Cleanup:** on Observer "PR merged/closed", remove that round's worktrees; mark `resolved` on the board.
- **Never:** edit code, run device verify, or **open a round PR before Tester has returned `pass` for every ticket in it** (missing verdict = treat as fail → run Tester first). (Lead **does** open the round PRs — Devs no longer self-PR.)

#### Github Observer
**Charge:** be the reliable, always-on replacement for the per-skill PR-watcher cron.
- Poll open PRs created by the team (`gh pr list` / `gh pr view`) every ~1–2 min for **new review/line/issue comments** and **CI status**.
- New review comment → `SendMessage` Dev-Fixer-PR with PR#, comment body, file/line.
- PR **merged/closed** → `SendMessage` lead to clean the worktree + mark `resolved`.
- CI red → `SendMessage` the ticket's Dev (or Dev-Fixer-PR) with the failing job.
- Read-only on Jira and source. Cheap model is fine.

#### Dev1 .. DevN
**Charge:** turn one assigned ticket into a fixed, committed change — code only. **Does NOT open PRs** (the lead PRs per round).
- Work the assigned ticket via `/jira-bug-analyzer single <TICKET>` in own worktree, **team-truncated** (deviations above).
- Produce the Vietnamese root-cause + fix-plan → send to lead → on approval, implement → compile-check → **commit the one per-ticket commit** (`fix(scope): … (TICKET)`).
- `SendMessage` lead: `{ticket, worktree, branch, commit, variant, repro steps, acceptance}` → set stage `ready` (joins the lead's PR round). **Do NOT open a PR or write to Jira.**
- On `verify-fail` (from the round's Tester pass) → fix more → re-commit → rejoin the next round.
- **Never** touch the device or another Dev's files.

#### Tester (sole device owner) — **only engaged on `--auto`**
**Charge:** the ONLY process that drives the device; runs **only when the run was invoked with `--auto`** (without `--auto` the round's gate is the Lead/human user-verify card, no device driving). When engaged, verify **each PR round's combined build** (all its tickets in one install), not per ticket.
- When the lead cuts a round, it hands `{round branch, commit list, per-ticket repro+acceptance, variant}`.
- **Once per round (`--auto` only):** **acquire the device lock via the script** (`bash <skill-dir>/assets/device-lock.sh acquire <serial> <raw-session-id>` — never hand-roll the lockdir; drive every adb call via `… exec <serial> <token> --`, `references/helpers/device-lock.md`) → install + launch the **round branch APK** (combined commits, appDev/debug — reuse the round build, don't rebuild) → run **the Phase 5 adb self-verify (`adb`, NOT mobile-mcp)** driving **every** ticket's repro + edge cases + screenshots in that **single** session → **release the lock**.
- Per-ticket verdicts back to the lead: ticket `pass` → stays in the round PR; ticket `fail` → message lead + that Dev (`verify-fail`) → lead **drops it from the round** (it rejoins a later round). `blocked` → message lead (can't verify after retries).
- Serial by design (one device, one lock **per round** — far less thrash than per-ticket). A 2nd device lets a 2nd round verify in parallel with its own lock; else queue.
- Edits no source; writes only verdicts.

#### Dev-Fixer-PR
**Charge:** close the review loop on open PRs.
- On Observer "new review comment": open that PR's worktree, draft a fix per comment, **get lead approval** (same policy), apply, push (`--force-with-lease`).
- If the change alters behavior → hand to Tester for re-verify before pushing.
- Post the **"đã fix, review lại"** reply / Discord re-review ping (only while PR is OPEN & unapproved).
- Never resolve/merge unilaterally — merge is human/lead decision.

---

### `.jira-bug/team-board.md` template (live file — created at first run, untracked)

Add to `.git/info/exclude`; never `git add`. Lead is the sole writer.

```markdown
# jira-bugfix board — <board> — started <UTC>

| # | ticket | category | prio | stage | owner | worktree | branch | PR | verify | notes |
|---|--------|----------|------|-------|-------|----------|--------|----|--------|-------|
| 1 | AIP806A-1017 | UI | High | fixing | Dev1 | ../proj-AIP806A-1017 | phase1/fixbug/AIP806A-1017 | — | — | |
| 2 | AIP806A-1019 | Crash | Highest | ready-for-verify | Dev2 | ../proj-AIP806A-1019 | phase1/fixbug/AIP806A-1019 | — | — | |
```

`stage` ∈ claimed · analyzing · plan-ready · approved · fixing · committed · ready · round-verify · verify-pass · pr-open · in-review · fixing-review · resolved · blocked. (`ready` = committed + waiting in the PR-round window; `round-verify` = the round's combined build is on the device.)

> **Teammates see this board automatically.** Every `/jira-bug-analyzer` init file displays `.jira-bug/team-board.md` (read-only) on the `TEAM=active` row on every startup if present — so any Dev opening the skill sees the whole team's in-flight state. The skill never writes it; the lead remains sole writer.

---

### Recovery (session death)

- Board file + TaskList survive. On relaunch, lead reconciles: re-read board, re-spawn missing roles, re-assign any `claimed`/`analyzing`/`approved`/`fixing` ticket whose Dev is gone.
- Open PRs: Observer re-attaches by `gh pr list`; or a Dev runs `/jira-bug-analyzer --resume` to reconcile its own PR watchers.

## Team `jira-bugfix` — Launch Recipe

How to stand up the parallel bug-fixing team. The Role Cards section above is the source of truth for what each teammate does.

> **One-command launch:** `/jira-bug-analyzer --team [--mode multi] [--devs N]` makes the current session become MainCharacter and runs this recipe automatically (see `references/phase1-init-multi-mode-with-team.md` → Init-8). `multi` is the only worker mode (it pulls + fixes in re-pulling turns; `pull`/`batch` are accepted aliases). The manual steps below are exactly what that flag executes — do them by hand only if orchestrating without the flag.

---

### 0. Preconditions (hard requirements)

**A multi-agent substrate must exist — but it does NOT have to be the `TeamCreate` tool.** Two substrates run the identical team (see `references/phase1-init-multi-mode-with-team.md` → Init-8):
- **(A) Native Agent Teams** — `TeamCreate`/`TeamDelete` exposed → live teammate sessions + tmux panes. Needs the CLI-terminal + env-flag rows below.
- **(B) Agent-tool fallback** — `TeamCreate` not exposed, but `Agent` + `TaskCreate`/`TaskUpdate` + `SendMessage` are → same team as background named Agents coordinated via the Task board. No tmux panes; agents re-engage via `SendMessage`. **Functionally identical outcome.**

Hard-block ONLY if **neither** substrate is available. A missing `TeamCreate` alone is NOT a stop when substrate B is present.

- [ ] **Substrate A or B present** (see above). Neither → set the env flag + relaunch from a terminal.
- [ ] **CLI terminal** (substrate A only — Agent Teams do NOT run in the VSCode extension; substrate B is terminal-agnostic).
- [ ] `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` set in `settings.json` env (substrate A).
- [ ] All teammates run **Opus** (Agent Teams constraint).
- [ ] `/jira-bug-analyzer` env preflight passes for the target repo (jira-mcp + jira-creds present) — run it once solo if unsure.
- [ ] At least **one Android device/emulator** connected (`adb devices`) — the Tester's only resource.
- [ ] `gh` authenticated (Observer + Dev PRs).

---

### 0.5 Seeing the team (display mode — tmux split panes)

> **Substrate B has no display picker / no panes.** The split-panes UX below is **substrate A only** (native Agent Teams). On the Agent-tool fallback, teammates are background Agents — track them via `TaskList` + `.jira-bug/team-board.md` + their `SendMessage` replies; there is no tmux view. Skip this whole section on B.

At launch (substrate A), Claude Code shows a **"Choose a display mode"** picker for how teammate sessions appear. This overrides the `teammateMode` setting — pick at the prompt:

- **In-process** — all teammates run inside your main terminal; `Shift+Up/Down` selects a teammate, type to message. Works in any terminal, no setup. You do NOT see separate panes.
- **Split panes (recommended to *watch* the team)** — each teammate (Observer / Tester / Dev1..N / Dev-Fixer-PR) gets **its own pane**; see everyone at once, click a pane to interact. **Requires tmux.**

To get split panes:
1. Install tmux if missing (`brew install tmux`), and start the lead from **inside a real terminal** (Terminal.app / iTerm2 — NOT VSCode).
2. Launch `/jira-bug-analyzer --team …`, then choose **Split panes** at the picker.
3. Navigate panes: **click** a pane to focus, or `Ctrl-b ←/→/↑/↓` to move; `Ctrl-b z` zooms the focused pane fullscreen (toggle back with `Ctrl-b z`).

**Notes:**
- Panes appear only **after the lead spawns teammates** (`TeamCreate` + spawn step) — not at the board-display/intake phase. The tmux status bar shows `1:Tester 2:Dev1 …` once they spawn.
- tmux has known limitations on some OSes/legacy terminals; on **macOS (iTerm2/Terminal) it works fine**. If split panes misbehave, fall back to **In-process** and track teammates via `TaskList` + `.jira-bug/team-board.md`.

---

### 1. Pick the parameters

| Param | How to choose |
|---|---|
| `N` (Dev count) | From board size: pull the board first (count to-do bugs), set `N = min(bugs, 2–3)`. Start at 2; scale only if the verify queue stays empty. |
| board / status / assignee | From the shared `project/<PROJ>/setup.json` (a teammate's saved config) or the local `.jira-bug/setup.json` (reuse) — see `references/phase1-init-multi-mode-with-team.md` (setup memory); else ask once. |

---

### 2. Launch sequence (lead drives)

The team has **no native `/ck:team` template** (only research/cook/code-review/debug ship). So the lead orchestrates from the Role Cards above:

1. **Stand up the team on the detected substrate (§0):** **A** → `TeamCreate(team_name: "jira-bugfix", ...)`; **B** → no team-create call — the team is just the named background Agents + the Task board, so go straight to spawning. Stop only if neither substrate exists.
2. **Enter delegate mode** (lead coordinates only, never edits source).
3. **Spawn support roles via the `Agent` tool** (one background teammate each, named so `SendMessage` can address them, per their role card): `Github Observer`, `Tester`, `Dev-Fixer-PR`.
4. **Pull + claim + dispatch:** lead runs the `/jira-bug-analyzer` pull query → groups by category (≤4/cat) → **claims** each picked ticket (In-Progress + assign) → spawns `Dev1..DevN` and `TaskCreate` one ticket per Dev. **When the current set drains, re-pull for the next turn** (multi loop) and dispatch the new batch to idle Devs; stand the team down when a pull returns empty.
5. **Init the board:** write `.jira-bug/team-board.md` (template above); add it to `.git/info/exclude`.
6. Hand each teammate its role card text + ticket context (no session history — explicit briefs only).

---

### 3. Running loop (lead)

- Watch TaskList + incoming messages. Transcribe every handoff to the board file (lead is sole writer).
- **Approvals:** auto-approve `Risk: low` plans + clean diffs; escalate medium/high to the human.
- **Verify queue:** Tester drains serially. If it backs up, pause new Dev dispatch rather than piling on.
- **PRs:** Observer surfaces review comments → Dev-Fixer-PR. On merge/close → lead removes the worktree, marks `resolved`.
- **Blocked:** give context / re-scope / escalate — never let a `blocked` sit silent.

---

### 4. Shutdown

- Each teammate marks its current task `completed` before approving shutdown.
- Lead confirms every ticket is `resolved`/`commented`/`blocked`, all worktrees removed, then deletes `.jira-bug/team-board.md`.
- **A** → `TeamDelete(team_name: "jira-bugfix")`. **B** → no team to delete; just confirm every background Agent has returned/completed (they run-to-completion).

---

### 5. One-line mental model

> Lead pulls & claims → Devs fix code in parallel (no device) → Tester verifies serially on the one device → Devs PR + resolve → Observer catches review comments → Dev-Fixer-PR closes them → lead cleans up.
