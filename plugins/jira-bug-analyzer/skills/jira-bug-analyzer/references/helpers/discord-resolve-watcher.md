# Discord resolve watcher — post ✅ Resolved vào channel khi PR mở

> **Scope:** OUTBOUND, async. Khi dev's máy hoàn tất Phase 6 (open PR), central bot's `--manager` tick phát hiện ledger có `pr_url` field + chưa post resolve → POST message vào `#jira-bug-analyzer`: *"✅ Resolved AAP-123: {PR link} · {short changelog}"*. Giúp team biết issue đã được xử lý.

## Prerequisites

- Dev's máy chạy Phase 6 với `[DISCORD-DEFER]` present → ghi `pr_url` + `pr_opened_at` vào ledger row (xem `phase6-commit-pr.md` update).
- Central bot's máy chạy `--manager --auto` cho project (để Job E/F tick 10 min). Hoặc dev tự chạy `--manager` thì watcher chạy trên máy ấy.

## Mechanism

**Chạy như sub-job của `--manager` reconcile pass** (xem `phase-manager-mode.md`):

Mỗi tick, sau Job E (deferred-comment scan), chạy **Job F — Discord resolve post:**

1. Pull mọi ledger row có:
   - `pr_url` present
   - `resolve_posted_to_discord == false` HOẶC absent
   - `[DISCORD-DEFER]` was enabled lúc defer (ledger field `discord_defer_enabled == true`)
2. Per row:
   a. Build message:
      ```
      ✅ Resolved **{TICKET_KEY}**: {PR_URL}
      {ticket summary từ Jira}
      Changelog: {first commit message hoặc PR title}
      ```
   b. POST qua Discord REST vào `defer_channel_id` (từ `assets/discord-roles.json`).
   c. Verify 200/201 → set ledger `resolve_posted_to_discord = true` + `resolve_posted_at = <ISO>` (`[BGMEM]`).
   d. Failure (401/404/500/network) → log + skip + retry ở tick kế (flag chưa set).

## Idempotency

- `resolve_posted_to_discord` flag atomic set-after-success → crash giữa chừng không double-post.
- Nếu 2 máy cùng chạy `--manager` cho project → race condition. Mitigation: pre-check-and-set qua BGMEM lock pattern (reuse `device-lock.md` style). Hoặc chấp nhận 2 post (noise acceptable, 1 trong 2 sẽ win atomic set).

## Opt-out

- Ledger row không có `discord_defer_enabled == true` → skip (ticket defer trước v2a / không bật flag).
- Env `JIRA_BUG_DISCORD_DEFER` unset → skip toàn bộ Job F (handler nào bật thì mới có pr_url trong ledger để process).

## Testing

1. Trigger 1 defer với `--discord-defer` → ledger row có `discord_defer_enabled: true`.
2. Resume + fix thành công → Phase 6 open PR → ledger row có `pr_url`, `resolve_posted_to_discord: false`.
3. Chạy `--manager` tick → Job F phát hiện → POST vào Discord → verify message hiện ra + ledger flag flipped.
4. Chạy `--manager` tick lần 2 → Job F skip (flag đã set).

## Related

- `phase-manager-mode.md` → Job F integration point
- `phase6-commit-pr.md` → ghi `pr_url` + flags vào ledger
- `discord-notify-defer.md` → OUTBOUND defer pair
- `discord-resume-handler.md` → realtime Q&A/commands
- SKILL.md Golden Rule `[DISCORD-DEFER]`
