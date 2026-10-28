# Fix-code rules — clean-code standard the fixer MUST follow

The **maintainable** ruleset for how the agent writes code when fixing a bug (Golden Rule `[CLEANFIX]`).
The fixer reads + follows this at **Fix-11** (`phase4-fix-and-build.md`); the **Phase-5 review gate**
(`phase5-verify.md` — `code-reviewer` + diff review) checks the diff against it and loops violations back to Fix-11.

> **How to maintain (this is the ONE place):** edit / add / remove rules right here. Keep each rule a short,
> checkable imperative (a reviewer must be able to say pass/fail against the diff). Changes sync
> project↔user-scope and apply to every project the skill fixes. Don't scatter fix-style rules into the phase
> files — link back to a rule id (`R#`) instead. A target project's own `docs/code-standards.md`, if present,
> is **additive** — follow it too; on conflict the stricter rule wins.

Foundation: **YAGNI · KISS · DRY**. A bug fix is **surgical**, not a rewrite.

## 1. Scope discipline — surgical change
- **R1** Smallest diff that fixes the root cause. Change only what's required; touch no line you don't have to.
- **R2** No unrelated refactors, reformatting, import reordering, or renames in a fix — they hide the real change and cause regressions. Spotted something worth cleaning? Note it separately, don't do it here.
- **R3** One fix = one concern. Don't bundle other bugs or "while I'm here" improvements.
- **R4** Follow the approved Fix-8 plan **verbatim**. Plan wrong mid-fix → STOP + re-confirm; never improvise a different fix silently.

## 2. Fix the root cause, not the symptom
- **R5** Address the documented Phase-3 root cause — not a surface patch that hides it.
- **R6** No band-aids: no empty/`catch`-and-swallow, no `?:`/default that masks a real null bug, no try-catch added only to silence a crash without fixing *why* it crashes.
- **R7** If the true fix is out of scope, defer/comment it (Fix-9) — do NOT ship a symptom patch to look done.

## 3. Match the surrounding code
- **R8** Mirror the style, naming, and idioms of the file/module you edit — read its neighbors first.
- **R9** Reuse existing helpers, utilities, and patterns (DRY). Search before adding anything new.
- **R10** **No new code comments** (KDoc/inline/block) unless the user explicitly asked — well-named identifiers + the diff document the change. Only touch a comment if it now lies.

## 4. Architecture boundaries (Android · Clean Architecture · MVI)
- **R11** Respect layers: **Presentation → Domain ← Data**. No repository call from a ViewModel (go through a use case), no DTO leaked to presentation, no Android/framework import in domain. (`.claude/rules/clean-architecture.md`)
- **R12** Extend TeraKit primitives, don't re-implement them — `MviViewModel` / `BaseMviActivity` / `BasePreferences` / `BaseRemoteConfiguration` / `BaseRepository`, poller/CMS via the service modules. (`.claude/rules/terakit-bom-usage.md`)
- **R13** UI goes through the design system: `AppText` / `AppColors` / `MaterialTheme` (no raw `Color(0xFF…)` / hardcoded dp), user-facing strings in `strings.xml` via `stringResource` (no literals in `Text`/`contentDescription`). Add a missing token to the design-system layer, never hardcode at the call site.

## 5. Safety — introduce no regression
- **R14** Preserve existing behavior everywhere except the bug. Before changing a shared symbol, check its call sites (the blast radius).
- **R15** Handle the edge cases the fix exposes — null / empty / error / loading / back-navigation — don't trade one bug for a new crash.
- **R16** No new nullability, lifecycle, or threading hazards; respect coroutine scopes and main-thread rules.
- **R17** Touching shared UI/logic → the fix must keep every consumer correct (ties to the Phase-5 blast-radius sweep).
- **R23** A read path does not write — and the fix for a wrong displayed value is to **compute the right value where it is read** (map it in memory in the repository/mapper), not to move the write somewhere else. A getter / `get*` / `observe*` / query that updates the database, preferences or a cache is a side effect the caller does not expect; so is a new listener (language change, app start, `init`) that rewrites stored rows to keep them "in sync" — it misses the cases where it does not fire (data not loaded yet, app killed mid-change) and spreads the fix over more files. (AIP396-475 A/B: the first auto-fix rewrote `definition` on every `getVocabWords()`; after R23 the next one moved the rewrite into a language-change collector reached through `GlobalContext` — 5 files. The real fix: one file, meanings mapped at read time.)
- **R24** Fix EVERY read path of the broken data, not just the one in the repro. List the sibling readers (list, detail, review/quiz, search, widget, export) and cite each as fixed or not affected. (AIP396-475 A/B: the auto-fix covered the list and review but not `getVocabWordById`, so the detail screen could still show the old meaning.) **Same for UI:** when the fix adds a parameter/variant to a shared component, `git grep` every call site of that component, list the ones inside the affected flow (here: every video screen) and pass the new value at each — cite each call site as changed or out of the flow. (AAP857-112 A/B: the fix covered Upload photo and Result but not the video-generation error screen, which the analyzer had itself listed; the real fix changed all of them.)
- **R25** A string defect is fixed in EVERY locale that has it. Before planning, `git grep` the key across all `values*/strings.xml` (and `plurals`), list which locales carry the same defect, and fix all of them — not only the language in the screenshot. Report `R25: <n>/<total> locales had it, all fixed`. (AAP857-113 A/B: both the old and the new skill fixed only `values-vi` (1/32); the real fix changed all 32.)

## 6. Hygiene
- **R18** No dead code, commented-out code, leftover debug logs / `println` / `Log.d`, or stray `TODO` from the fix.
- **R19** No hardcoded secrets, tokens, keys, or absolute local paths.
- **R20** Keep files **< 200 lines**. If the fix pushes a file over, extract a focused unit — but only if that stays in scope; otherwise note it for follow-up (R2).
- **R21** New files: kebab-case, descriptive names (respect language convention — Kotlin/Java types stay PascalCase).
- **R22** The change must **compile and build green** (Fix-12). Never hand a red build to Phase 5.

## Review checklist (Phase-5 gate uses this)
A fix **passes** the code-rule check only when the diff is: **surgical** (R1–R4) · **root-cause** (R5–R7) · **style-matching** (R8–R10) · **layer/design-system-correct** (R11–R13) · **regression-safe** (R14–R17, R23–R25) · **hygienic** (R18–R22). For a data/behavioral fix the reviewer answers R23 and R24 explicitly, and for a string fix R25, in its report ("R23: no write on read ✓" / "R24: readers X, Y, Z all covered ✓"). Any violation → report the failing `R#` + line, loop back to Fix-11.
