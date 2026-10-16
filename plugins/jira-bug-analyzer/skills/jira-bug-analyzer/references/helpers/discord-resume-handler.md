# Discord resume handler — reply trên Discord để resume ticket defer

> **Scope:** INBOUND. Khi dev reply trong Discord channel `#jira-bug-analyzer` (via claudecode-discord bot), Claude session trong plugin folder nhận message → detect ticket key → forward thành Jira comment `@claude {text}` → Job E (next tick của `--manager`, hoặc trigger ngay inline) xử lý resume.

## Prerequisites

- claudecode-discord bot running + channel `#jira-bug-analyzer` đã `/register` map tới folder project có plugin.
- Khi dev reply trong channel đó, claudecode-discord spawn Claude session trong folder plugin với message làm input.
- User CLAUDE.md đã có rule "khi gặp ticket key → invoke `/jira-bug-analyzer` skill" (user-scope rule đã có).

## Detect flow

Khi Claude session nhận 1 input có dạng text thường (không phải full `/jira-bug-analyzer ...` invocation), áp regex `[A-Z][A-Z0-9]+-\d+` để extract ticket key (lấy match ĐẦU tiên; nhiều match → warn + lấy đầu).

**Không có ticket key** → treat như chat bình thường, không invoke skill. Bot claudecode-discord cứ reply tự nhiên.

**Có ticket key** → tiếp tục dưới đây.

## Decision tree

1. **Fetch ticket** qua `mcp__jira__jira_get_issue` để confirm tồn tại + đọc status + labels.

2. **Check ledger row** `analyzed-deferred` cho ticket này (local `.jira-bug/<KEY>/` hoặc shared memory `project/<KEY_PREFIX>/<PHASE>/session/record_bug_status.md` qua `[BGMEM]`).

   | Trường hợp | Hành động |
   |---|---|
   | Có ledger row `analyzed-deferred` | → **Resume path** (dưới) |
   | Không có ledger row, nhưng ticket exists | → skip resume. Giả định dev chỉ chat về ticket, KHÔNG trigger resume. Reply Discord: *"ℹ️ {KEY} không ở trạng thái defer, bỏ qua. Nếu muốn fix mới, gọi `/jira-bug-analyzer {KEY}`."* |
   | Ticket không tồn tại / 404 | → reply Discord: *"⚠️ {KEY} không tìm thấy trên Jira."* + log. |

## Resume path (ticket in `analyzed-deferred`)

1. **Strip ticket key khỏi message body** → `{reply_body}` (phần còn lại).
   - Nếu `{reply_body}` rỗng → treat như intent mơ hồ. Post Jira `@claude` comment với body ngắn: *"@claude (reply từ Discord không có nội dung — cần thêm chỉ đạo)"* → chạy Clarify branch. OR skip + reply Discord yêu cầu dev thêm text.
   - Khuyên: skip + reply Discord *"⚠️ Reply cần có nội dung sau ticket key. Ví dụ: `{KEY} chọn phương án B`."*

2. **Post Jira comment** qua `[REST]` (`jira_add_comment` endpoint — xem `references/helpers/jira-rest-api.md`):
   - Body: `@claude {reply_body}` *(cần có `@claude` để Job E detect marker — xem `phase-manager-mode.md` Job E "Marker")*
   - `[VN]`: body đã là tiếng Việt từ dev reply gốc, giữ nguyên.
   - Verify 201 + readback.

3. **Trigger Job E Resume branch inline** (không chờ `--manager` tick):
   - Giữ nguyên pattern của `phase-manager-mode.md` Job E Resume branch:
     a. Xoá ledger row `analyzed-deferred` (`[BGMEM]`)
     b. Ghi `.jira-bug/clarify-<KEY>.md` với `{reply_body}`
     c. Dispatch Phase 3 cho ticket đó (background hoặc inline — tùy context session)
     d. Advance `commentsCursor` = ID comment vừa post ở step 2
   - **Caveat:** session hiện tại là 1-off từ claudecode-discord forward, không phải trong `--manager /loop`. Hợp lý: chỉ làm **step a + b + d** (bọc Jira comment + xoá ledger + ghi clarify). Phase 3 dispatch để `--manager` tick sau xử lý (hoặc dev tự chạy `/jira-bug-analyzer {KEY}` để fix ngay).
   - **Alternative:** nếu dev muốn fix NGAY, invoke `/jira-bug-analyzer --manager <PROJECT-KEY>` inline (nặng — spawn full manager loop). Khuyên dev chỉ chạy khi cần urgent.

4. **Reply Discord** confirm (POST vào cùng channel — reuse helper từ `discord-notify-defer.md`):
   ```
   ✅ Đã post `@claude {reply_body}` lên Jira {KEY}. Job E (next `--manager` tick) sẽ resume.
   Jira: {ticket_url}
   ```

## Idempotency

- Dev reply 2 lần cùng ticket → 2 Jira comments → Job E cứ xử lý comment ID lớn nhất (xem `phase-manager-mode.md` Job E Scope). Chấp nhận.
- Reply có ticket key nhưng ledger row đã mất (ticket resumed từ trước) → fall qua "Không có ledger row" branch → skip + info reply.

## Loop prevention

**Nguy hiểm:** confirm reply của chính handler này chứa `✅ Đã post...` + có thể chứa ticket key → nếu bot nào lại forward lên Claude session → trigger lại.

Mitigation:
- Confirm message KHÔNG mention ticket key dạng trần trước `**` bold (format trên dùng backtick `{KEY}` → safe, regex `[A-Z][A-Z0-9]+-\d+` không match trong backtick-wrapped nếu detector smart; nhưng regex đơn giản VẪN match. Nên:
- **Author filter**: handler check `message.author.id` — nếu == bot's own `application_id` (`1553759426547159090` cho `learn-app` bot) → skip hoàn toàn. claudecode-discord đã filter message của chính nó không spawn session, nên về mặt lý thuyết OK; nhưng khi handler gửi confirm, confirm đó không trigger session mới.

## Testing

1. Dry: tạo 1 Jira ticket giả, add ledger row `analyzed-deferred` manual.
2. Trong Discord `#jira-bug-analyzer`, gõ: `AAP729-2 chọn phương án B`.
3. claudecode-discord forward → Claude session spawn.
4. Kỳ vọng:
   - Jira ticket có comment mới `@claude chọn phương án B`
   - Ledger row `analyzed-deferred` xóa
   - `.jira-bug/clarify-AAP729-2.md` xuất hiện với body `chọn phương án B`
   - Discord channel có reply `✅ Đã post ...`

## Related

- `phase-manager-mode.md` Job E — Resume branch mechanics
- `discord-notify-defer.md` — OUTBOUND counterpart
- `assets/discord-roles.json` — config (channel ID để reply confirm)
- SKILL.md Golden Rule `[DISCORD-DEFER]`
