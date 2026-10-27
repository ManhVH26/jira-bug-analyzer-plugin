# Google Sheet as board (`--google-sheet`) — `[SHEET]`

> Loaded whenever the run's board source is a Google Sheet: the invocation carries `--google-sheet <URL>`, OR the resolved setup has `type: "google-sheet"`. This is the **single source** for sheet-board behavior — the phase files cite it by the `[SHEET]` tag, they do NOT restate it. Everything NOT covered here (Phase 2 spec/figma, Phase 3 root-cause+plan, Phase 4 worktree+build, Phase 5 diff-review+APK+user-verify, `[REPRO]` `[CLEANFIX]` `[TOKEN]` `[MEDIA]` `[VN]` `[OPTIONS]` `[1COMMIT]` `[AUTO]`) is **identical to Jira mode** — only the board pull and the Jira-only write-backs change.

## What `[SHEET]` changes vs Jira mode (the whole delta)
1. **Board pull** — a link-shared Google Sheet replaces `jira_search`. The parsed rows are **cached in setup (local + shared memory)**; each turn renders from the cache and refreshes it in the background.
2. **No Jira writes** — there is no ticket to transition/comment/worklog. `[CLAIM]` becomes a **ledger row** (the lock), and Phase-6 "finalize Jira" becomes a **ledger update** (`done` + PR link). **The sheet itself is never written.**
3. **Status is still saved** — to the SAME `record_bug_status.md` ledger (local + shared), so cross-dev dedup, resume, and `--manager` KB-backfill all keep working.

Everything else streams through Phases 2→6 unchanged.

## Invocation & the `type` discriminator
- `--google-sheet <URL>` ⇒ **multi-without-team**, board = the sheet. Picking one index → the existing single-row shortcut. There is no "single sheet" mode (a sheet is a board). `--google-sheet` alongside a bare ticket-key token → treat as multi (the sheet is the board); ignore the key.
- Still requires a **`--project <KEY>`** — used only for memory namespacing (`project/<KEY>/<PHASE>/…`) and the branch prefix (`phaseX/fixbug/…`). Absent → `[OPTIONS]`-ask for it (same as Jira multi's ASK-FIRST gate). `@N` phase + `--auto` compose normally.
- **Setup gets a top-level `type` field** (`.jira-bug/setup.json` AND the shared `project/<KEY>/setup.json`):
  ```jsonc
  { "type": "google-sheet",         // "jira" (default; a missing type == "jira") | "google-sheet"
    "project": "AIP304",
    "baseBranch": "develop",
    "sheet": { … see below … } }
  ```
  A setup with **no `type`** is read as `"jira"` — every existing project is untouched. `init-multi.sh` emits `SETUP_TYPE=<jira|google-sheet>`; the Pull step branches on it.
- **Env:** sheet mode does NOT use the Jira MCP. If the env preflight reports `ENV=block:jira-mcp` / `block:jira-creds`, **ignore it under `type: google-sheet`** — Jira is not on this path. `git` + `gh` + `gradle`/`adb` + the memory repo are still required (their gates are unchanged).

## The `sheet` setup block (the cache — persisted local + remote)
Written with `bash <skill-dir>/assets/setup-json.sh merge-set <file> type=google-sheet 'sheet={…}'` (canonical, never hand-write), and pushed to the shared repo via `memory-keeper` (`[BGMEM]`, background) the SAME turn it's built/refreshed — local-only defeats cross-dev reuse.
```jsonc
"sheet": {
  "url":    "https://docs.google.com/spreadsheets/d/<ID>/edit#gid=<GID>",
  "csvUrl": "https://docs.google.com/spreadsheets/d/<ID>/export?format=csv&gid=<GID>",
  "columnMap": { "id":"N°","feature":"Feature","summary":"Tóm tắt lỗi","details":"Chi tiết",
                 "expected":"Kết quả mong muốn","status":"Trạng thái","priority":"Mức độ",
                 "reporter":"Người phát hiện lỗi" },
  "openStatusSet": ["open","reopen","being processed"],   // lowercased; needs-fix statuses
  "cachedAt": "2026-07-06T16:20:00+07:00",
  "rows": [ { "id":"1","feature":"Banner_pin","summary":"…","details":"…","expected":"…",
              "status":"Open","priority":"High","reporter":"HoaiNT",
              "attachments":[{"url":"https://ibb.co/…","kind":"image"}] }, … ]
}
```
- `csvUrl` is derived from any sheet URL by `bash <skill-dir>/assets/sheet-board.sh csv-url "<url>"` (extracts the spreadsheet id + `gid`, default `gid=0`).
- `rows` is the **cached snapshot of the WHOLE sheet** (all parsed rows, every status) — the authoritative bug list. `openStatusSet` filters it for the pick list; the full set stays cached so a status-change on the sheet is visible on the next refresh.

## Pull step (replaces "Build the query" + `jira_search` when `SETUP_TYPE=google-sheet`)
Runs where phase1's **Pull & list by category** block runs. No network-first fast-path is needed — the list renders from the LOCAL cache; the network refresh is background.

1. **Render from cache first.** Read `sheet.rows` from setup (local, instant). Filter to rows whose `status` (lowercased) ∈ `openStatusSet` AND that are NOT already `done`/`deferred`/`commented`/`blocked` in the ledger for a MATCHING summary (see Identity). Group + number them exactly like Jira mode — but **use the `feature` column as the category** when present (e.g. `Banner_pin`, `Banner_all`, `Survey`); fall back to summary-inference only when `feature` is blank. Same `≤4/category`, continuous numbering, priority-sorted (`Critical>High>Medium>Low`), `[OPTIONS]`/free-text pick, category-pick = proceed (no re-confirm).
2. **Refresh the cache in the background (every turn, `[BGMEM]`).** In the SAME message as (or right after) rendering, run `bash <skill-dir>/assets/sheet-board.sh fetch "<csvUrl>"` in a background subagent. If its `rows` differ from the cache → write the new snapshot + `cachedAt` to **both** local `.jira-bug/setup.json` and the shared `project/<KEY>/setup.json` (`setup-json.sh merge-set` + `memory-keeper` push). New/changed rows surface next turn. **Never block the list on the refresh.**
3. **First run / cold cache (`SHEET_CACHE=absent`).** Fetch synchronously once: `sheet-board.sh fetch "<csvUrl>"`.
   - `needMap` non-empty (a required column — `summary`/`status` — wasn't auto-detected) → show the parsed header row and `[OPTIONS]`-ask the dev to name the missing column(s) ONCE, then re-run `fetch` with the override map `'{"status":"<Header Name>"}'`. Cache the resolved `columnMap`.
   - `warnings` mentions an empty/unfetchable CSV → the sheet isn't link-shared or the gid is wrong; tell the dev to set "anyone with link can view" (or paste the correct URL). Do not fabricate rows.
   - Success → build the `sheet` block, `merge-set` it + `type=google-sheet` locally, push to shared (`[BGMEM]`), then render.
4. **Refresh failed / CSV unreachable** → fall back to the cached snapshot and prefix the list with a one-line `⚠️ sheet refresh failed — showing cache from <cachedAt>`.
5. **Empty (no open rows)** → STOP: `no open bugs on the sheet (<url>)`. (Under `--auto` an empty pull is the loop's only stop condition, same as Jira.)

## Bug identity, dedup & the ledger (this is where status is "saved")
- **Key** = `<PROJECT>-SHEET-<N°>` where `N°` is the row's `id` column (e.g. `AIP304-SHEET-1`). This is the ticket-key equivalent everywhere — ledger row, branch name (`phaseX/fixbug/AIP304-SHEET-1`), `[1COMMIT]` scope `fix(scope): … (AIP304-SHEET-1)`, PR body heading. Blank `id` → synthesize `<PROJECT>-SHEET-r<headerRowOffset>` and note it.
- **Summary fingerprint guards against re-numbering.** Store the row's `summary` in the ledger `summary`/`root_cause` columns. On re-pull, a `SHEET-<N°>` ledger row is a dedup hit ONLY if its stored summary still matches the current row's summary; if the summary changed, the `N°` was repurposed → treat it as a NEW bug (re-analyze), don't skip.
- **The `record_bug_status.md` ledger is the SOLE status store** (local + shared, `[BGMEM]`) — exactly as Jira mode, keyed by the sheet key. Status flow: `analyzing` (claim) → `analyzed` → `fixing` → `pr-created` → `done` (also `commented`/`blocked`/`deferred`). **`done` is set at PR-creation** (there is no Jira "Resolved"). `root_cause_slug` still keys cross-ticket dedup. This satisfies "save the status" without ever writing the sheet.

## Claim (`[CLAIM]` sheet variant)
No Jira transition/assignee. **Claim = write/upsert the ledger row `status: analyzing`** (`dev` = the git user / `gh` login) via `memory-keeper` (`[BGMEM]`) the moment a bug is picked, BEFORE Fix-3. That row is the cross-dev lock: if a picked bug already has a ledger row `analyzing`/`fixing`/`pr-created`/`done` owned by ANOTHER dev with a matching summary → surface it `[VN]` (`Skip`/`Vẫn làm`), drop on Skip. A row already owned by THIS dev/session → resume, don't re-claim.

## Analyze & media (Phase 3 deltas)
- The analyzer subagent gets the bug's `summary` + `details` + `expected` + `feature` text and the `attachments` URLs (from the cache) **instead of** a Jira ticket fetch — there is no Fix-3 `jira_get_issue`, no Fix-4 REST attachment download.
- **Media (`[MEDIA]`/`[TOKEN]`) runs on the URLs.** Resolve each to a real media file, then `eyes_analyze`:
  - **streamable / loom / youtube** → resolve per Fix-5's hosted-link recipe (Streamable → `curl https://api.streamable.com/videos/<id>` → `files.mp4.url`).
  - **ibb.co** (an image *page*, not a direct image) → `WebFetch`/`curl` the `ibb.co/<id>` page and take its `og:image` (the `https://i.ibb.co/…` direct URL), then analyze that.
  - direct image/video URL or Drive `uc?export=download` → fetch directly.
  - Save the fetched media under the scratchpad / `.jira-bug/evidence/<KEY>/` (evidence reused by Phase 5), analyze via human-mcp first (text back), native-vision fallback only.
- The Fix-6 block's `Title:` becomes `**Bug:** AIP304-SHEET-<N°> — <summary>` (no Jira link — there is none); `Resource link` Image/Video lines carry the sheet's attachment URLs (short-display markdown). Everything else in the Fix-6 format is unchanged.

## Fix / Verify (Phases 4–5) — identical
Worktree off `origin/<BASE>` at `phaseX/fixbug/<KEY>`, `<BUILD_CMD>`, GitHub diff-review gate, APK install + user-verify, `--auto` adb self-verify + saved evidence. No changes.

## Commit & PR (Phase 6 delta — ledger-only finalize, NO Jira, NO sheet write)
- `[1COMMIT]` + `gh pr create` are **unchanged** (PR title/body English; body carries the Phase-3 + Phase-5 facts per bug; the per-bug heading is the sheet key).
- **Replace the "Attach PR + finalize Jira" background subagent** with a ledger update: upsert the ledger row → `status: done`, `pr: <PR link>` (local + shared, `[BGMEM]`). **No Jira comment / worklog / transition. No write-back to the sheet.**
- Under `--auto`: same background dispatch; the auto-fix quality flag is recorded as a **ledger note** (`auto_eval: pending`) instead of a Jira `auto-fixed` label + `[AUTO-FIX EVAL]` comment (there is no Jira). The end-of-run report and `batch-progress.md` are unchanged.
- Defer / non-code "comment" reasons (Fix-9, auto-defer) are recorded to the **ledger + surfaced in chat `[VN]`** — there is no Jira ticket to comment on, and the sheet is read-only.

## Manager mode (`--manager`) deltas
- **Job A** (PR review comments) + **Job B** (worktree cleanup) — GitHub-based, unchanged.
- **Job C** (KB-backfill) — keys off ledger rows at `status: done` for this project/phase (the board-scan-for-Resolved-tickets step is Jira-only; under sheet mode, iterate the ledger's `done` rows instead).
- **Job D** (auto-fix reopen tracking) — **disabled**: it relies on Jira `auto-fixed`/`auto-fix-reopened` labels + status history, which don't exist for a sheet. State this in the pass summary (`Job D: n/a (google-sheet board)`). Reopen tracking for a sheet would require reading the sheet's status column each pass — out of scope (read-only, no label history).

## Reference — the worked example (the real QC sheet)
A QC tracker whose first rows are a **status legend** (`(Bug mới) Open`, `(Bug fix chưa đạt yêu cầu) Reopen`, `(Đã sửa) Fix`, `(Từ chối sửa) Reject`, `(Đã đóng) Close`, `(Không phải lỗi) Not a bug`, `(Pending ver sau sửa) Next Version`), then the header row `N° · Feature · Tóm tắt lỗi · Chi tiết · Kết quả mong muốn · Trạng thái · Mức độ · Người phát hiện lỗi · Ngày phát hiện · Dev FeedBack · QC Confirm`, then bug rows 1..N. `sheet-board.sh fetch` skips the legend, auto-detects every column, and harvests the ibb.co / streamable URLs out of `Chi tiết`. Open-set = `Open`+`Reopen` (+`Being processed` if the dev wants in-progress rows); done-set = `Fix`/`Reject`/`Close`/`Not a bug`/`Next Version`.
