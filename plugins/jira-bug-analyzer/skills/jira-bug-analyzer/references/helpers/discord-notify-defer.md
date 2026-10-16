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

Format cố định (dễ parse ngược bởi resume handler + đồng nhất Discord render):

```
<@{discord_user_id}> **{TICKET_KEY}** cần quyết định — ping **{role}**
{short summary 1-2 dòng, VN có dấu}
Reason: {defer_reason — vd `score<80`, `clarify-gap`, `no-sot`}
Jira: {ticket_url}

Reply thẳng trong channel này với ticket key để resume. Ví dụ:
`{TICKET_KEY} chọn phương án B` · `{TICKET_KEY} @claude fix` · `{TICKET_KEY} @claude review`
```

`[VN]` áp dụng cho summary + reason prose. Technical tokens (ticket key, reason enum) giữ verbatim.

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
