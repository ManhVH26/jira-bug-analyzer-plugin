# Discord resume handler — inbox-write pattern (v1.11+)

> **Scope:** `[DISCORD-MULTIPURPOSE]` v1.14.0+ **ticket-resume branch** — một trong 5 intents classifier (`discord-classifier.md`) có thể route tới. Trigger: classifier phân intent = `ticket-resume` (ticket key present + verb fix/làm/sửa/proceed/B/C). Action: spawn `Agent` tool background subagent (v1.13.0+ pattern) chạy `/jira-bug-analyzer <KEY> --resume-from-defer --auto --auto-low` — subagent hiện trong `--manager` agents panel (user watch Phase 3-6 live), parent session non-blocking (bắt được reply kế). Spawn chạy trong env dev, hoàn toàn vô hình với Discord bot. 4 intents còn lại (bulk-op / query / chat / meta-cmd) route tới helpers khác — xem `discord-classifier.md` → "Routing table".

> **Vì sao đổi:** v1.10 cho bot invoke `Skill` tool → mỗi reply = 1 Claude session chạy ngay trong Discord bot, tool-use hiện tràn channel (observed: AAP729-42 reply → bot gọi `jira_get_issue`/`Bash`/`Skill` ngay trên Discord, user không muốn). v1.11 kéo spawn về `--manager` terminal: Discord thuần relay, speed giữ nguyên (<5s file-watch), 1 execution path, không phải approve/reject tool-use trên Discord nữa.

## Prerequisites

- claudecode-discord bot running (bất kỳ máy nào), `/register` channel `#jira-bug-analyzer` → folder có plugin + `.jira-bug/` ghi được. Bot phải mount được folder đó (local path hoặc shared drive / rsync tới máy dev).
- Terminal dev chạy `--manager --auto <PROJECT>` → Job G (inbox watcher, `phase-manager-mode.md`) tự Monitor `.jira-bug/discord-inbox/` khi manager mode entry.
- `assets/discord-inbox-write.sh` sẵn trong plugin — bot invoke script này thay cho spawn Claude Skill.
- `.env` bot: `ALLOWED_USER_IDS=<whitelist>` giữ nguyên.

## Flow

```
[Discord] User reply: "AAP729-42 B" (hoặc free text, hoặc @claude fix…)
    │
[Bot] match /^[A-Z][A-Z0-9]+-\d+\s/ regex
    │   - match → run assets/discord-inbox-write.sh (xem schema bên dưới)
    │   - no match → chat thường, bot bỏ qua (giữ compat với chat tự do)
    │
[Bot] ack: "✅ Đã nhận {TICKET}. Chuyển về terminal --manager để resume (ETA <10s)."
    │   (BOT KẾT THÚC. Không spawn, không tool-use, không Skill)
    │
[--manager terminal] Monitor .jira-bug/discord-inbox/*.json phát hiện file mới
    │
[--manager Job G] đọc file → classify intent → act (push-mode spawn hoặc inline)
    │   (chi tiết trong phase-manager-mode.md Job G)
```

## Inbox file schema

Bot ghi vào `.jira-bug/discord-inbox/<TICKET>-<message_id>.json`:

```json
{
  "ticket": "AAP729-42",
  "message_id": "1560650882062753845",
  "channel_id": "1560595714386567169",
  "guild_id": "1476773352130740375",
  "author_id": "703224453185929327",
  "author_name": "HungND",
  "content": "AAP729-42 B",
  "content_stripped": "B",
  "attachments": [],
  "received_at": "2026-10-16T20:54:00Z",
  "status": "pending",
  "schema_version": "v1.11"
}
```

- `content` = raw message body.
- `content_stripped` = `content` với ticket key + leading whitespace đã bỏ (giúp Job G parse intent nhanh — `B`, `@claude fix`, `scope = full app`).
- `attachments` = array of `{filename, url, size}` cho file đính kèm (log, screenshot). Job G download riêng nếu cần.
- `schema_version` → future-compat.

Sau khi Job G xử lý xong: move file sang `.jira-bug/discord-inbox/processed/<TICKET>-<message_id>.json` + append field `processed_at` + `job_g_outcome` (`spawned` / `inline-resumed` / `skipped-dedup` / `error`).

## Bot-side invocation

Bot (claudecode-discord repo, Node.js) nhận message qua Discord Gateway. Trước khi forward vào Claude SDK session (hành vi mặc định cũ), check hook:

```javascript
// Pseudo-code trong bot handler
const TICKET_RE = /^([A-Z][A-Z0-9]+-\d+)\s+(.+)$/s
const match = message.content.match(TICKET_RE)

if (match) {
  const [, ticket, rest] = match
  // Call plugin helper (shells out, không spawn Claude)
  const result = spawnSync('bash', [
    path.join(PLUGIN_DIR, 'assets/discord-inbox-write.sh'),
    '--ticket', ticket,
    '--message-id', message.id,
    '--channel-id', message.channelId,
    '--guild-id', message.guildId,
    '--author-id', message.author.id,
    '--author-name', message.author.username,
    '--content', message.content,
    '--content-stripped', rest,
    '--attachments', JSON.stringify(message.attachments.map(a => ({filename: a.name, url: a.url, size: a.size}))),
    '--inbox-dir', INBOX_DIR  // từ env, mặc định ~/Desktop/src/<project>/.jira-bug/discord-inbox
  ], {encoding: 'utf-8'})

  if (result.status === 0) {
    await message.reply(`✅ Đã nhận ${ticket}. Chuyển về terminal --manager để resume (ETA <10s).`)
  } else {
    await message.reply(`⚠️ Inbox write fail: ${result.stderr}. Fallback: dán nội dung này vào terminal --manager.`)
  }
  return  // STOP — không forward sang Claude SDK session
}

// Không match ticket pattern → chat thường, forward như cũ
```

**Lưu ý:** `INBOX_DIR` cần config per-channel (từ `/register` hoặc env mapping). Nếu bot chạy trên máy khác dev → `INBOX_DIR` cần là shared location (NFS, rsync target, hoặc dev commit lên git ngắn — v1.11 chọn solution tối giản: bot và dev CÙNG máy, hoặc shared folder qua Dropbox/iCloud. Multi-machine routing là scope v1.12).

## Dedup + idempotency

- Mỗi `message_id` chỉ ghi 1 file (`<TICKET>-<message_id>.json`); nếu file đã tồn tại → bot skip ghi, ack "duplicate, đã forward".
- Bot's own messages (`author.bot === true`) → skip hoàn toàn, không ghi file.
- User ngoài `ALLOWED_USER_IDS` → bot filter ở Gateway layer, không tới helper.

## Testing

1. Trigger defer thật (`--auto --discord-defer`) → thấy Discord ping đúng format v1.11.
2. **Resume test:** reply `AAP-123 B` → bot ack ngay <2s. Kiểm `.jira-bug/discord-inbox/AAP-123-<msg_id>.json` tồn tại. Terminal `--manager` log Job G detect + spawn. KHÔNG thấy tool-use trong Discord.
3. **Chat tự do test:** reply không prefix ticket → bot behave như chat thường (forward Claude SDK hoặc im lặng tuỳ bot config).
4. **Dedup test:** quote-reply cũ → bot ack "duplicate" + không ghi file 2 lần.
5. **Attachment test:** reply `AAP-123 log attached` + attach file → inbox file có `attachments[0]` với URL Discord CDN. Job G download riêng khi xử lý.

## Related

- `phase-manager-mode.md` → **Job G: Discord inbox watcher** (consumer side)
- `discord-notify-defer.md` → OUTBOUND defer pair (producer side)
- `discord-resolve-watcher.md` → Job F post ✅ Resolved khi PR open
- `assets/discord-inbox-write.sh` → bot-side helper script
- `assets/discord-roles.json` → config
- SKILL.md Golden Rule `[DISCORD-DEFER]`
