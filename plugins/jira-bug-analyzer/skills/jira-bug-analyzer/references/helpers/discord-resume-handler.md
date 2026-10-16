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
| **resume command** | "chọn phương án B", "fix", "làm đi", "proceed", "@claude fix", "tiến hành" | **Push mode (v1.10+ default):** write clarify file + post Jira `@claude {body}` + Bash spawn background Claude session `nohup claude -p "/jira-bug-analyzer <KEY> --resume-from-defer --auto" >logs 2>&1 &` + record pid vào `.jira-bug/active-resumes.json` + ack "spawn pid X, ETA 5-30 min". Dedup: cùng KEY đã có pid alive → skip spawn, ack "đã busy". **Legacy mode (set env `JIRA_BUG_DISCORD_PUSH=0`):** chỉ post Jira comment, chờ `--manager` Job E tick (v1.9.0 flow). |
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

## Push mode spawn chi tiết (v1.10+)

Khi Resume intent được chọn + `JIRA_BUG_DISCORD_PUSH != 0`:

**Bước 1 — Dedup check + concurrency cap (default 3):**
```bash
# Đọc .jira-bug/active-resumes.json (local, không BGMEM)
# Format: {"<KEY>": {"pid": 12345, "spawned_at": "2026-10-16T20:30:00Z", "log": ".jira-bug/resume-logs/<KEY>-<ts>.log"}}
# Trước tiên: cleanup stale entries (kill -0 <pid> fail → xoá entry)

# (a) Per-ticket dedup:
# Nếu entry cho <KEY> tồn tại + pid alive → skip spawn, reply "⏳ Đang có fix session cho {KEY} (pid X). Chờ xong hoặc kill nếu stuck."

# (b) Global concurrency cap (default MAX=3, overrideable qua env JIRA_BUG_DISCORD_PUSH_MAX=<N>):
# count = len(active-resumes.json entries after cleanup)
# Nếu count >= MAX → skip spawn, Jira comment vẫn đã post ở Bước 2 (audit trail + fallback).
# Reply: "⏳ Đã đạt giới hạn {MAX}/{MAX} fix sessions đồng thời.
#          Ticket {KEY} sẽ xử lý qua --manager Job E ở tick kế (ETA ~10 min).
#          Đang chạy: {list keys đang active}.
#          Giảm cap: `kill <pid>` một session cũ nếu urgent."
```

Note thứ tự: Bước 2 (post Jira) chạy TRƯỚC Bước 1 cap check — đảm bảo cap-reject vẫn có fallback qua Job E. Pseudo-code order:
```
write clarify-file → post Jira @claude  →  dedup check → cap check → spawn (hoặc skip với ack phù hợp)
```

**Bước 2 — Write clarify + post Jira (giữ v1.9 behavior):**
- Ghi `.jira-bug/clarify-<KEY>.md` với `{reply_body}`
- Post Jira comment `@claude {reply_body}` qua `[REST]` (audit trail + fallback cho dev khác chạy --manager)

**Bước 3 — Spawn background session:**
```bash
LOG_PATH=".jira-bug/resume-logs/<KEY>-$(date +%Y%m%d-%H%M%S).log"
mkdir -p .jira-bug/resume-logs
nohup claude -p "/jira-bug-analyzer <KEY> --resume-from-defer --auto" > "$LOG_PATH" 2>&1 &
SPAWN_PID=$!
disown
```
- `nohup` + `&` + `disown` → session detach khỏi bot process, chạy độc lập.
- `claude -p` = print mode (headless, one-shot). Session xử lý Phase 3-6 rồi exit.
- Log file giữ output cho debug sau.

**Bước 4 — Record pid:**
- Update `.jira-bug/active-resumes.json` với entry `{pid, spawned_at, log}` cho `<KEY>`.
- Khi spawned session exit (success/fail), nó tự xoá entry trong Phase 6 cleanup OR next spawn attempt detect stale pid + cleanup.

**Bước 5 — Ack Discord:**
```
Hiểu là: resume · {TICKET_KEY}
✅ Spawn fix session pid {SPAWN_PID} · ETA 5-30 min
Log: {LOG_PATH}
```

**Error handling:**
- `claude` CLI không trong PATH → reply error "⚠️ claude CLI not found. Push mode disabled, dùng --manager fallback."
- Spawn thành công nhưng session crash: log file có stderr; next reply reset dedup lock. Dev kiểm tra log.
- Dev kill thủ công: `kill $(jq -r '."<KEY>".pid' .jira-bug/active-resumes.json)` + xoá entry.

## Related

- `phase-manager-mode.md` → Job E Resume/Review/Clarify (fallback khi push mode off hoặc fail)
- `discord-notify-defer.md` → OUTBOUND defer pair
- `discord-resolve-watcher.md` → Job F post ✅ Resolved (fallback cho non-push resumes)
- `phase6-commit-pr.md` → inline Discord post khi `--resume-from-defer` active (bypass Job F)
- `assets/discord-roles.json` → config
- SKILL.md Mode dispatch → `--resume-from-defer` flag mechanics
- SKILL.md Golden Rule `[DISCORD-DEFER]`
