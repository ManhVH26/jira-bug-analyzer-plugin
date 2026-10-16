# Discord resume handler — realtime Q&A + commands trong channel

> **Scope:** INBOUND, realtime. Khi dev / PO / QA reply trong Discord channel `#jira-bug-analyzer` (via claudecode-discord bot), Claude session trên máy central nhận message qua Gateway → classify intent → ack + action trong 2-8s. Fix thật vẫn trên máy dev gốc (Jira comment relay + dev's `--manager` tick).

## Vì sao realtime được

- claudecode-discord bot dùng Discord Gateway WebSocket (persistent connection) → `MESSAGE_CREATE` event push <200ms.
- Bot forward vào Claude session (via `@anthropic-ai/claude-agent-sdk`) → session đọc + reply qua Discord REST POST <5s total.
- Không polling, không webhook public — Gateway đã sẵn.

## Prerequisites

- claudecode-discord bot running trên 1 máy central (admin team), `/register` channel `#jira-bug-analyzer` → folder có plugin.
- `.env` của claudecode-discord: `ALLOWED_USER_IDS=<team whitelist>` (comma-separated).
- Máy dev chạy `--manager --auto <PROJECT>` để Job E pick up Jira comments resume.

## Detect flow

Áp regex `[A-Z][A-Z0-9]+-\d+` vào input message. **First match → `TICKET_KEY`**. No match → treat là chat bình thường ngoài scope, skip hoàn toàn (claudecode-discord vẫn forward reply như chat thường — không phải lỗi).

**Có TICKET_KEY** → tiếp tục intent classification.

## Intent classification (LLM-driven)

Dựa message body (sau khi strip ticket key) + context từ ledger (fetched BGMEM) + attachment (nếu có), classify thành 1 trong 5:

| Intent | Signal | Action |
|---|---|---|
| **ack-only** | "ok", "noted", "hiểu rồi", emoji phản hồi | Ack nhẹ nhàng, không action thêm |
| **context Q&A** | Câu hỏi: "plan là gì?", "root cause chỗ nào?", "file nào bị ảnh hưởng?", "@claude explain" | Đọc ledger `summary`+`plan`+`files` + fetch Jira ticket + reply inline (<10s) |
| **resume command** | "chọn phương án B", "fix", "làm đi", "proceed", "@claude fix", "tiến hành" | Post Jira `@claude {body}` qua `[REST]` + ack "forwarded" (v1.8.0 flow) |
| **review command** | "won't fix", "không fix", "close", "review", "@claude review" | Post Jira `@claude review {body}` + ack "forwarded for review" |
| **context push** | Có attachment (log file, screenshot) HOẶC paste code/stack trace dài | Save file/text vào `.jira-bug/discord-attachments/<KEY>/<timestamp>-<filename>` (local nếu central = dev; qua BGMEM nếu khác máy) + ack "received, saved for next analysis cycle" |

**Default khi ambiguous:** treat là context Q&A (an toàn — chỉ đọc, không write).

**Rule:** mọi reply của bot BẮT BUỘC nêu rõ *"Hiểu là: {intent}"* ở đầu để dev correct nhanh nếu classify sai. Vd: *"Hiểu là: resume. Đã forward `@claude chọn B` lên Jira..."*.

## Decision tree

1. **Fetch ticket** qua `mcp__jira__jira_get_issue`.
   - 404 → reply Discord *"⚠️ {KEY} không tìm thấy."* + stop.
2. **Check ledger row** `analyzed-deferred` cho ticket qua shared memory `[BGMEM]`.
   - **Không có** → reply Discord *"ℹ️ {KEY} không ở trạng thái defer. Nếu muốn fix mới, gọi `/jira-bug-analyzer {KEY}` trực tiếp."* + stop. (Giữ cho ticket không-defer vẫn chat tự nhiên không trigger side-effect.)
   - **Có** → vào intent classification + action tương ứng.
3. **Advance** `discord_last_processed_message_id` ledger field = message.id vừa xử lý (cho resolve watcher skip).

## Reply format (sticky)

```
Hiểu là: {intent} · {TICKET_KEY}

{action summary — 1-2 dòng}

{nếu Q&A: nội dung trả lời}
{nếu resume/review: Jira link}
```

Vietnamese `[VN]` có dấu. Technical tokens giữ verbatim.

## Multi-user whitelist

claudecode-discord `.env`:
```
ALLOWED_USER_IDS=885416107601723423,703224453185929327,1198956639571673231,1252444547355775046
```

User ngoài whitelist gõ → claudecode-discord filter trước, không forward vào session. Zero cost.

## Idempotency + loop prevention

- Bot's own messages: `message.author.id == bot_application_id` → skip. claudecode-discord đã filter self-messages không spawn session; thêm defensive check trong handler.
- Dev reply nhiều lần: mỗi message xử lý độc lập; ledger `discord_last_processed_message_id` advance monotonically.
- Handler crash giữa chừng (sau Jira comment post, trước ack reply) → vô hại. Dev không thấy ack nhưng Job E vẫn pick up Jira comment ở tick kế.

## Testing

1. Trigger defer thật (`--auto --discord-defer` với bug confidence thấp) → thấy Discord ping.
2. **Q&A test**: reply `AAP-123 plan là gì?` → bot reply trong 10s với plan từ ledger. Không trigger resume.
3. **Resume test**: reply `AAP-123 chọn phương án B` → bot ack + post Jira. Máy dev's --manager tick resume.
4. **Review test**: reply `AAP-123 không fix, review` → bot ack + post Jira `@claude review`.
5. **Context push test**: reply `AAP-123 kèm log` + attach file → bot ack + save file. Confirm `.jira-bug/discord-attachments/AAP-123/` có file.
6. **Negative**: reply `AAP-999` cho ticket không-defer → bot info-reply không side-effect.

## Related

- `phase-manager-mode.md` → Job E Resume/Review/Clarify (pick up Jira comment)
- `discord-notify-defer.md` → OUTBOUND pair
- `discord-resolve-watcher.md` → post ✅ Resolved khi PR open
- `assets/discord-roles.json` → config
- SKILL.md Golden Rule `[DISCORD-DEFER]`
