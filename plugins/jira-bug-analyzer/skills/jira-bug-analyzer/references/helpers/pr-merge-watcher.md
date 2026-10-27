# PR watcher — surface review comments + clean up worktree on close

> **This is the Jobs A (review comments) + B (worktree cleanup) helper that `--manager` drives.** The orchestration (when to run, the per-board reconcile loop, the board scan, and Job C KB-backfill) lives in **`references/phase-manager-mode.md`** — read that for the mode; read this for the mechanics. **Job C (KB-backfill on ticket→Done) is NOT in this file** — it's owned by `phase-manager-mode.md` + `references/helpers/memory.md`.

Read this when arming the watcher on PR creation (Phase 6), or when running the reconcile via `--manager` (or the minimal Init-5 worktree cleanup on skill start).

**The ticket is already Resolved at PR-creation time** (Fix-13 transitions → Resolved + logs work + comments the PR link before the watcher is armed). The watcher therefore does **NOT** resolve, log work, or comment on merge. Two jobs per watched PR:
1. **New review comments → notify + draft, apply on approval:** while the PR is open, detect review/line/issue comments from other reviewers and **notify** with a summary. Drafting a fix per comment and applying it (edit + push + reply) happens **interactively on the dev's approval** — never auto-edited unattended (review comments are often questions/ambiguous).
2. **Merge/close → clean up:** detect the PR leaving OPEN and **remove the fix worktree** (kept open until now so review fixes were possible), then drop the watch entry.

## How the watcher triggers

There is no background process. The watcher acts **only when `/jira-bug-analyzer --manager <KEY>` runs** — once after each QA-verify round, before the next fix round (`--loop` only if the dev asks for one). It reads the **watch file**, surfaces pending review comments, cleans up merged/closed PRs' worktrees and backfills the KB. A PR missing from the watch file is invisible to it, so the watch-file entry is the whole arming. (A normal skill start also does the *minimal* Init-5 worktree cleanup.) Never tell the dev "it watches in the background" — tell them comments surface at the next `--manager` run. Nothing here gates the ticket's resolution — that already happened at PR creation.

## Watch state file

`.jira-bug/pr-watch.json` at the **target project root** (untracked — add to `.git/info/exclude`; never `git add`). A map keyed by PR number; one entry per open PR the skill created:

```json
{
  "<PR>": {
    "pr": 123,
    "url": "https://github.com/<org>/<repo>/pull/123",
    "base": "main",
    "branch": "phase1/fixbug/AIP568-191",
    "worktree": "../learnova-AIP568-191",
    "tickets": [
      { "key": "AIP568-191", "summary": "Energy reward missing on highscore streak" }
    ],
    "createdAt": "<ISO8601>",
    "commentsCursor": "<ISO8601 of the newest review comment already notified — init = arm time>"
  }
}
```

`commentsCursor` advances past comments already surfaced so the watcher never re-notifies the same one. (Tickets are already Resolved, so the entry exists only for review-comment surfacing + worktree cleanup.)

Batch = one PR, many entries in `tickets`.

## Arm (Phase 6, at PR creation)

`assets/ledger.sh upsert … status=pr-created pr=<url> --root <repo root>` calls `assets/pr-watch.sh add` — it writes the entry into the MAIN checkout's `.jira-bug/pr-watch.json` (even when run from the worktree), adds `.jira-bug/` to `.git/info/exclude`, reads the file back and prints `PR_WATCH=added|updated|unchanged #<n>`. A batch PR gains one `tickets` item per ticket. `PR_WATCH_ERROR=` → arming failed: say so and give the dev the `pr-watch.sh add` command. No ask, no cron (AAP857-113 dropped the old ask-then-cron prose step entirely).

## Each `--manager` reconcile — per watch entry

1. **Acquire an atomic per-PR lock** (`mkdir`-style, same pattern as `device-lock.md`, keyed by PR) so two `--manager` passes (or a `--loop` fire and a manual pass) never collide. Locked → skip this entry this pass.
2. `gh pr view <PR> --json state -q .state`:
   - `OPEN` → **poll for new review comments** (below), then leave the entry, release lock, wait for the next fire.
   - `MERGED` or `CLOSED` → **remove the fix worktree** (`git worktree remove <worktree>`, if still present), notify a short per-PR summary (`merged` vs `closed without merge`), remove the entry. **Do NOT touch Jira** — already Resolved.
3. Release the lock. When the watch file becomes empty → `CronDelete` the watcher and delete the file.

## Review-comment poll (each fire, while OPEN) — notify only, never auto-edit

Fetch comments newer than `commentsCursor`, authored by **someone other than the token owner** (don't react to your own replies):
- Reviews: `gh api repos/{owner}/{repo}/pulls/<PR>/reviews`
- Line comments: `gh api repos/{owner}/{repo}/pulls/<PR>/comments`
- Issue comments: `gh api repos/{owner}/{repo}/issues/<PR>/comments`

If any new → **notify** (push notification / scheduled-session output) a concise list: `author · file:line · snippet` per comment. Advance `commentsCursor` to the newest seen so it isn't re-notified. The unattended cron **stops here** — it does NOT edit code. Applying fixes is the interactive flow below, run when the dev engages (or at Init-5 if comments are pending).

## Address review comments — interactive (notify → draft → apply on approval)

Triggered when the dev engages after a comment notification, or surfaced at Init-5 when a watched PR has pending comments. Never runs unattended.
1. **List** the new comments: `author · file:line · body`.
2. **Per comment, draft** a response: either a concrete proposed code fix, or — if the comment is a question / ambiguous / non-actionable — a drafted reply asking for clarification (do NOT guess an edit).
3. **Ask as options** (per comment or batched): `Apply drafted fix` / `Edit draft` / `Reply only` / `Skip`.
4. **On `Apply`:** edit in the PR's worktree → if behavior changed, re-run **Phase 5 adb self-verify** (`references/phase5-verify.md` — NOT mobile-mcp) → push to the PR branch (`--force-with-lease`) → **reply on the thread** acknowledging (`gh api ... /pulls/<PR>/comments/<id>/replies` for line comments, or a PR comment).
5. Advance `commentsCursor` past everything handled; clear the pending flag.

Resolving a review thread or marking the comment addressed is the reviewer's call — don't auto-resolve their threads.

## Recovery — minimal Init-5 cleanup on skill start · full reconcile via `--manager`

The session may have been killed while a PR was open. There are two recovery paths:
- **Minimal Init-5 cleanup (any skill start):** read the watch file and, for each `MERGED`/`CLOSED` PR, **remove the fix worktree** (if still present) + drop the entry. Cheap, non-interactive — keeps stale worktrees from piling up. It does NOT chase review comments or backfill the KB.
- **Full reconcile (`/jira-bug-analyzer --manager <KEY>`):** the durable path — per PR:
  - `MERGED` or `CLOSED` → **remove the fix worktree** (if still present) and drop the entry. (No Jira work — already Resolved at PR creation.) Then **Job C KB-backfill** (`references/phase-manager-mode.md`).
  - `OPEN` → **re-poll review comments since `commentsCursor`** and, if any are pending, surface them to the dev (the Address-comments flow).
- File empty afterward → delete the file.

Same atomic per-PR lock as above.
