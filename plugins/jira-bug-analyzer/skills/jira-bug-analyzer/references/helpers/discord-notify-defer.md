# Discord notify on defer — ping đúng role khi ticket defer

> **Scope:** OUTBOUND Discord ping song song với Jira defer comment. Jira vẫn source of truth; Discord là chuông đánh thức để dev không phải refresh Jira. Áp dụng cho MỌI defer path (`auto-plan-pick.md` "Khi defer", bất kể `--auto`/interactive).

## Khi gọi

Ngay SAU khi `auto-plan-pick.md` "Khi defer" bước 2 (Jira comment đã post + verify 201). Gọi NON-BLOCKING: nếu notify fail, defer flow vẫn thành công — chỉ log vào end-of-run report.

## Điều kiện bật

- Config file `assets/discord-roles.json` tồn tại và parse được JSON.
- Env `LEARN_APP_DISCORD_BOT_TOKEN` set (đọc từ `~/.claude/settings.json` env block hoặc shell env).
- Opt-in: flag `--discord-defer` present trên invocation, HOẶC env `JIRA_BUG_DISCORD_DEFER=1`. Mặc định **OFF** (giống `--discord` pattern có sẵn).

**Thiếu bất cứ cái gì** → skip silently + log 1 dòng warning vào report (`discord-defer: skipped (config/token/flag missing)`), không fail defer.

## LLM pick role

Dựa context bug (summary + Fix-6 root cause + ticket labels), LLM chọn 1 trong 3:
- **`po`** → bug liên quan sản phẩm / UX / business logic / spec ambiguity / copy / design intent
- **`dev`** → bug liên quan code / architecture / technical implementation / performance (**default fallback** khi mơ hồ)
- **`qa`** → bug liên quan repro steps / test coverage / edge cases chưa cover / cần info từ reporter

Tra `roles[<picked>]` → `discord_user_id`.

## Build message

**Nguyên tắc đồng nhất:** Discord message **copy nguyên văn body của Jira defer comment vừa post ở step 2.a**, chỉ thêm Discord mention ở đầu + Reply action footer ở cuối. ONE source of truth = Jira comment. Dev/QA/PO đọc Jira hay Discord đều cùng thông tin, không phải maintain 2 nơi.

Format:

```
<@{discord_user_id}> **{TICKET_KEY}** cần quyết định — ping **{role}**

{COPY NGUYÊN VĂN body của Jira comment vừa post ở auto-plan-pick.md step 2.a — bao gồm reason defer, bug summary, clarify questions nếu có, phương án đề xuất nếu có, link ledger slug. Không re-format, không rút gọn — người đọc Discord phải thấy đúng những gì người đọc Jira thấy.}

📎 **Jira:** {ticket_url}

📝 **Chọn 1 trong các option sau** (dev/QA/PO đều reply được, prefix bằng ticket key):

{IF Jira comment có liệt kê plan A/B/C — render từng option 1 dòng với label}
- `{TICKET_KEY} A` → **{tên plan A, 1 dòng — vd "Giữ gate 4 TAB_ROUTES, không thay đổi code"}**
- `{TICKET_KEY} B` → **{tên plan B — vd "Mở scope ra toàn app, bỏ gate 4 TAB_ROUTES"}**
- `{TICKET_KEY} C` → **{tên plan C — vd "Thêm remote config toggle điều khiển runtime"}**

**🖊️ Custom (nếu không option nào vừa):**
- `{TICKET_KEY} <tự viết câu trả lời/đề xuất phương án khác/dán link/cung cấp info>` → agent nhận context mới + re-analyze

**⚡ Command đặc biệt:**
- `{TICKET_KEY} @claude fix` → bắt đầu fix ngay với context hiện có (nếu đã đủ info)
- `{TICKET_KEY} @claude review` → chỉ review phân tích, không fix
- `{TICKET_KEY} close <lý do>` → đóng ticket (invalid / won't-fix / duplicate / cannot-reproduce)

_Reply được chuyển về terminal `--manager` đang chạy để resume — không spawn session mới trên Discord, không hiện tool-use._
```

**Build steps cụ thể:**
1. Lấy `jira_comment_body` = chuỗi body đã post lên Jira ở step 2.a (giữ nguyên markdown Jira, Discord render được ADF-style markdown tương tự: `**bold**`, `*italic*`, `` `code` ``, bullet `-`, numbered `1.`). Nếu Jira dùng cú pháp đặc thù (ADF `panel`, `expand`) → convert sang markdown thường trước khi post Discord.
2. Prepend 1 dòng mention + 1 dòng trống.
3. Append Jira URL + Reply action footer.
4. Nếu tổng > 1900 ký tự (Discord limit 2000, chừa 100 cho mention + markdown overhead) → giữ nguyên mention + 400 ký tự đầu Jira body + `… (xem đầy đủ trên Jira)` + Jira link + Reply footer.

**Không tự generate câu hỏi/plan trong message này** — chỉ copy. Nếu Jira comment không có clarify questions / plan options (ví dụ `no-sot` chỉ ghi "thiếu spec") thì Discord cũng không có — không bịa thêm.

**Nguyên tắc build:**
- `clarify_questions` + `plan_options` lấy **nguyên văn** từ Fix-6 block của ticket (`.jira-bug/project/<KEY>/<TICKET>/analysis.md` section "Câu hỏi cần làm rõ" / "Phương án fix đề xuất"). KHÔNG tự generate — nếu Fix-6 không có → bỏ cả section (ví dụ `no-sot` thuần, không có question để hỏi).
- `clarify-gap` → **BẮT BUỘC** có section Câu hỏi (reason của defer).
- `score<threshold` → **BẮT BUỘC** có section Phương án (có plan nhưng score thấp — hỏi PO duyệt).
- `no-sot` → **BẮT BUỘC** có 1 dòng remedy (ví dụ "Cần spec/figma cho Phase 3 — thêm `@3` khi reply, hoặc dán link `--spec <url>`") THAY cho Phương án.
- `mid-fix wrong-plan` → **BẮT BUỘC** có 1 dòng mô tả plan sai + câu hỏi hướng đi mới.
- `[VN]` áp dụng cho prose. Technical tokens (ticket key, reason enum, action verb như `@claude fix`) giữ verbatim.
- Hạn chế độ dài message ≤ 2000 ký tự (Discord limit). Nếu questions/options dài → tóm tắt + trỏ link Jira.

## Gọi Discord REST

```bash
TOKEN="${LEARN_APP_DISCORD_BOT_TOKEN}"
CHANNEL_ID="$(python3 -c "import json; print(json.load(open('<plugin>/assets/discord-roles.json'))['defer_channel_id'])")"
CONTENT='<built message above, JSON-escaped>'

curl -sS -w '\n%{http_code}' \
  -X POST \
  -H "Authorization: Bot ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"content\": ${CONTENT}}" \
  "https://discord.com/api/v10/channels/${CHANNEL_ID}/messages"
```

**Kết quả:**
- `200`/`201` → log 1 dòng `discord-defer: pinged <role> for <TICKET>` vào report.
- `429` → honor `Retry-After` header, 1 retry only. Nếu vẫn fail → log + skip.
- `401`/`403` → bot token/permission issue — log + skip + remind dev check `[DISCORD-DEFER]` setup trong SKILL.md.
- `404` → channel ID stale — log + skip + remind dev re-fetch channel ID (bot kick khỏi channel / channel bị xoá).
- Other / network error → log + skip.

**Không block defer loop ở bất kỳ lỗi nào.**

## Idempotency

Discord REST không dedup — nếu defer đồng 1 ticket chạy 2 lần (crash recovery), sẽ có 2 ping. Chấp nhận — Discord noise acceptable. Dev thấy 2 ping = tín hiệu defer bị retry (có ích).

## Testing

Dry-run bằng cách gọi curl thẳng với message test:
```bash
curl -X POST -H "Authorization: Bot $LEARN_APP_DISCORD_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"content":"<@703224453185929327> **TEST-1** dry-run"}' \
  https://discord.com/api/v10/channels/1560595714386567169/messages
```

Verify: thấy message trong Discord channel `#jira-bug-analyzer`, mention @dev render đúng.

## Related

- `references/helpers/auto-plan-pick.md` → "Khi defer" step 2b (nơi gọi vào đây)
- `references/helpers/discord-resume-handler.md` → INBOUND counterpart (reply flow)
- `assets/discord-roles.json` → config
- SKILL.md Golden Rule `[DISCORD-DEFER]`
