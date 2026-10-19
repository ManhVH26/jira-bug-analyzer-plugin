# Discord notify ticket status — ping-back cho mọi state change

> **Scope:** `[DISCORD-TICKET-STATUS]` (v1.12.2+). Khi 1 ticket có ledger field `discord_defer_enabled: true` (= ticket được triggered từ Discord qua Job G hoặc post defer ở `auto-plan-pick.md`), MỌI state change trên ticket đó PHẢI post 1 status update vào `defer_channel_id`. User gõ reply Discord xong là chờ hồi âm cho tới khi ticket đóng — im lặng giữa chừng = fail UX.

## Khi gọi (các điểm trigger)

| Trigger | Who calls | Message template |
|---|---|---|
| **Defer post** (`auto-plan-pick.md` step 2.b) | `discord-notify-defer.md` | (existing) full defer notify |
| **Resume start** (Job G act plan-pick/resume-fix/clarify) | `phase-manager-mode.md` Job G | *"🔧 Nhận chỉ đạo cho **{KEY}** từ {author}. Bắt đầu Phase 3..."* |
| **Phase 3 done** | Phase 3 analyzer finalize | *"🔍 **{KEY}** root cause: `<slug>`. Phase 4 fix."* |
| **Phase 4 build pass** | Phase 4 finalize | *"🔨 **{KEY}** build pass trên `<branch>`. Phase 5 verify."* |
| **Phase 4 build fail** | Phase 4 retry/fail | *"❌ **{KEY}** Phase 4 build fail (attempt N/2). Lý do: `<msg>`."* |
| **Phase 5 verify pass** | Phase 5 finalize | *"✅ **{KEY}** Phase 5 verify pass (device + adb)."* |
| **Phase 5 verify fail** | Phase 5 retry/fail | *"⚠️ **{KEY}** Phase 5 verify fail (attempt N/5). `<reason>`."* |
| **PR opened** (Phase 6) | Phase 6 commit-pr | *"✅ **{KEY}** Resolved: `<PR_URL>`\nChangelog: `<PR title>`\nResume từ: `{author}`"* |
| **PR review comment arrived** (Job A) | `phase-manager-mode.md` Job A | *"💬 **{KEY}** nhận review comment mới trên PR. Agent đang xử lý..."* |
| **PR review comment addressed** | Job A finalize | *"✔️ **{KEY}** đã fix review comment, push force update."* |
| **PR merged** | Job B pre-cleanup | *"🎉 **{KEY}** PR merged vào `<base>`."* |
| **PR closed without merge** | Job B pre-cleanup | *"🗑️ **{KEY}** PR closed không merge. Lý do: `<msg>`."* |
| **Jira ticket reopened** (Job D) | `phase-manager-mode.md` Job D | *"🔄 **{KEY}** bị reopen trên Jira. Reporter: `<user>`. Reason: `<text>` (nếu có)."* |
| **New Jira comment arrived** (Job E) | `phase-manager-mode.md` Job E | *"📝 **{KEY}** có comment mới trên Jira từ `<author>`. Agent đang xử lý..."* |
| **Deferred lại** (mid-fix wrong-plan) | `auto-plan-pick.md` | *"⏸️ **{KEY}** defer lại — lý do: `<reason>`. Chi tiết đã post trên Jira."* |
| **No-op resolve** (pre-existing fix found) | Phase 6 / Job A | *"<@{qa_user_id}> ✅ **{KEY}** đã ship từ `<YYYY-MM-DD>` — commit `<short_sha>` ("`<commit title>`", tác giả: `<author>`, merged `<base>`). Mời QA retest trên build mới nhất. Nếu vẫn tái → reply ở đây hoặc reopen ticket kèm build#."* |

## Điều kiện bật

- Ledger row cho `TICKET_KEY` có field `discord_defer_enabled: true` (`[BGMEM]`).
- `assets/discord-roles.json` tồn tại + parse OK.
- Env `LEARN_APP_DISCORD_BOT_TOKEN` set.

Thiếu bất kỳ cái gì → skip silently + log *"discord-ticket-status: skipped (<reason>) for <KEY>"*, KHÔNG fail flow chính.

## Mention format (BẮT BUỘC)

Mọi mention Discord **CHỈ** dùng cú pháp **user mention `<@USER_ID>`** với `USER_ID` numeric lookup từ `assets/discord-roles.json → roles[po|dev|qa]`.

**CẤM tuyệt đối cú pháp role mention `<@&ID>`** — file `discord-roles.json` chỉ chứa **user IDs**, KHÔNG có role IDs. Dùng `<@&user_id>` → Discord render ra **`@unknown-role`** (bug UX). Nếu không cần ping ai cụ thể → BỎ mention line, KHÔNG bịa `@qa` / `<@&qa>` plain text.

Khi template bảng trên ghi `<@{qa_user_id}>` / `<@{dev_user_id}>` / `<@{po_user_id}>` → lookup `roles.qa` / `roles.dev` / `roles.po` từ `discord-roles.json` và paste nguyên numeric ID, giữ cú pháp `<@...>` (không `&`).

Grep guard trong bash curl helper:
```bash
if echo "$CONTENT" | grep -q '<@&'; then
  echo "ABORT: role-mention syntax <@&...> is forbidden — use <@USER_ID> only" >&2
  exit 1
fi
```

## Build message

Format cố định ngắn (1-3 dòng, Discord không spam):

```
<emoji> **<TICKET_KEY>** <action verb> — <1 dòng status>
<optional 1 dòng detail / link>
```

Emojis mapping:
- 🔧 start resume · 🔍 analyze done · 🔨 build pass · ❌ build fail
- ✅ verify pass / resolved · ⚠️ verify fail · 💬 review comment
- 🎉 merged · 🗑️ closed · 🔄 reopened · 📝 new comment · ⏸️ deferred

`[VN]` áp dụng cho prose. Technical tokens (ticket key, slug, branch, URL) giữ verbatim.

## Gọi Discord REST

```bash
TOKEN="${LEARN_APP_DISCORD_BOT_TOKEN}"
CHANNEL_ID="$(python3 -c "import json; print(json.load(open('<plugin>/assets/discord-roles.json'))['defer_channel_id'])")"
CONTENT='<built message, JSON-escaped>'

curl -sS -w '\n%{http_code}' \
  -X POST \
  -H "Authorization: Bot ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"content\": ${CONTENT}}" \
  "https://discord.com/api/v10/channels/${CHANNEL_ID}/messages"
```

- `200`/`201` → log 1 dòng *"discord-ticket-status: posted <action> for <KEY>"*. KHÔNG append ledger (chỉ Phase 6 Resolved mới set `resolve_posted_to_discord` cho Job F dedup).
- `429` → honor `Retry-After`, 1 retry. Nếu vẫn fail → log + skip.
- `401/403/404` → log + skip + warn dev check env.
- Non-blocking: fail → log, flow chính không ngắt.

## Rate limiting + batching

Trong 1 phase thường chỉ post 1 message (start, done, fail). Nếu 1 ticket có nhiều phase trong 1 session liên tục → 5-7 message/ticket là bình thường, chấp nhận. KHÔNG batch — mỗi event là 1 message rời để Discord render timeline rõ.

Phase 4 build retry/attempt → có thể skip post intermediate retries để tránh spam. Chỉ post khi:
- Attempt 1 bắt đầu
- Final build pass hoặc final build fail (sau khi hết retry budget 2)

## Related

- `SKILL.md` Golden Rule `[DISCORD-TICKET-STATUS]` (v1.12.2+)
- `discord-notify-defer.md` OUTBOUND defer notify (initial)
- `discord-resume-handler.md` INBOUND inbox-write
- `phase-manager-mode.md` Jobs A/B/D/E/G trigger status updates
- `phase4-fix-and-build.md`, `phase5-verify.md`, `phase6-commit-pr.md` cite rule inline
- `auto-plan-pick.md` defer-again cite rule inline
