# Discord classifier — intent taxonomy + routing (`[DISCORD-MULTIPURPOSE]` v1.14.0+)

> **Scope:** CONSUMER-SIDE classifier chạy inline trong Job G của `--manager`. Đọc inbox file v1.14 (bot ghi theo `assets/discord-inbox-write.sh`) → load Discord thread context nếu có → gọi LLM phân loại intent (6 nhóm, incl. `out-of-scope` v1.15.1+) → trả về `{intent, slug, target_set, confidence}` → Job G route theo bảng dưới. KHÔNG spawn subagent cho classify (gọi LLM native parent session, cheap). Spawn subagent xảy ra ở route step (xem bảng routing).

## Khi nào gọi classifier

Job G gọi classifier mỗi khi xử lý 1 inbox file v1.14. Skip nếu `schema_version != "v1.14"` (bot cũ) — fallback xử lý theo v1.13.0 path (ticket-resume only, nếu có `ticket` field).

## Intent taxonomy (6 nhóm, v1.15.1+)

| Intent | Trigger signals (`content_stripped`) | Target format | Example (VN) | Example (EN) |
|---|---|---|---|---|
| **ticket-resume** | Có `ticket` HOẶC `referenced_ticket` + verb fix/làm/sửa/proceed/tiến hành/B/C/go ahead | single key | `AAP729-3 fix`, reply vào ✅ Resolved với `check lại` | `fix it`, `proceed with plan B` |
| **bulk-op** | Verb bulk (resolve/close/fix/update/review) + set (các PR, hết defer, AAP*, sprint này) | query pattern string | `resolve conflict các PR`, `close hết defer AAP*` | `fix all open bugs this sprint` |
| **query** | Interrogative (nào/sao/bao nhiêu/phase nào/mấy cái/when/how many/which) | question text | `PR nào đang review?`, `còn bao nhiêu ticket defer?` | `which PRs are blocked?` |
| **chat/context** | Non-ticket free-form, OR có attachment, OR context dump | content + attachments | `đây là log cho AAP729-5`, `thấy crash ở Android 13` | `here's the error from staging` |
| **meta-cmd** | Imperative control (stop/pause/list/cancel/run/reconcile now) | command name + args | `stop watcher`, `list running subagents`, `reconcile now` | `pause --manager`, `cancel resume-AAP729-3` |
| **out-of-scope** (v1.15.1+) | Message nhắc project key / sản phẩm KHÁC `current_board`, HOẶC yêu cầu non-jira task (Firebase remote config, sheet reading, generic coding) HOẶC prefix slash-skill khác (`/claude-in-chrome`, `/figma`, `/learn-app`) addressed to non-manager target | mismatch descriptor | `tạo remote config AAP927 từ sheet này` (board=AAP729), `dùng /claude-in-chrome đọc sheet`, `scaffold Compose UI từ Figma` | `generate config for ProjectX`, `use /figma to extract tokens` |

**Prioritization khi overlap** (ví dụ `AAP729-3 fix hết các commit conflict`):
1. Nếu project key / sản phẩm trong message ≠ `current_board` AND không có ticket key của `current_board` → **out-of-scope** (highest priority, chặn mọi intent khác). Exception: query dạng `PR nào ở AAP927?` vẫn là **query** read-only (manager có thể trả lời cross-project qua `gh`/`jira_search`).
2. Nếu có `ticket` xác định (prefix khớp `current_board`) → **ticket-resume** (dù có từ bulk).
3. Nếu có set target rõ (các/hết/all) + verb action → **bulk-op**.
4. Nếu kết thúc bằng dấu `?` HOẶC bắt đầu bằng từ hỏi → **query**.
5. Nếu khớp meta-cmd verb list → **meta-cmd**.
6. Mặc định → **chat/context**.

## Classifier prompt template

Job G build prompt dưới + gọi LLM native (parent session) — không spawn subagent. Response phải là valid JSON parseable.

```
Bạn là intent classifier cho Discord message chuyển vào Claude Code --manager session.

Message content (đã strip @claude mention):
"""
{content_stripped}
"""

Trigger type: {trigger_type}  (mention | reply)
Ticket key extracted (nếu có): "{ticket}"
Referenced ticket (nếu reply-quote): "{referenced_ticket}"
Current manager board (v1.15.1+): "{current_board}"
Thread context (last 20 messages, nếu trong thread):
"""
{thread_context}
"""

Phân loại message vào ĐÚNG 1 trong 6 intents, trả về JSON:

{
  "intent": "ticket-resume" | "bulk-op" | "query" | "chat" | "meta-cmd" | "out-of-scope",
  "slug": "<short-kebab-case, dưới 40 char>",
  "target_set": "<theo bảng dưới>",
  "confidence": 0.0-1.0,
  "reasoning": "<1 câu VN giải thích>"
}

target_set format per intent:
- ticket-resume: {"key": "AAP729-3"}
- bulk-op:      {"query": "các PR open", "verb": "resolve conflict"}
- query:        {"question": "PR nào đang review?"}
- chat:         {"ticket_ref": "AAP729-5 hoặc ''", "has_attachment": true/false}
- meta-cmd:     {"cmd": "stop", "args": "watcher"}
- out-of-scope: {"mentioned_project": "AAP927", "requested_action": "tạo remote config từ sheet", "reason": "project-mismatch" | "non-jira-task" | "other-skill-target"}

Rules (áp dụng theo thứ tự ưu tiên):
1. **out-of-scope first**: nếu message nhắc project key / sản phẩm KHÁC `{current_board}` (vd `AAP927` khi board=AAP729) AND không có ticket key hợp lệ cho `{current_board}` → out-of-scope, `reason: "project-mismatch"`. Trường hợp message yêu cầu task không thuộc jira-bug flow (Firebase remote config, Google Sheet reading, Figma extract, generic coding scaffold) → out-of-scope, `reason: "non-jira-task"`. Message prefix slash-skill khác (`/claude-in-chrome`, `/figma`, `/learn-app`, `/aip-bootstrap-android`) addressed to session khác → out-of-scope, `reason: "other-skill-target"`. Exception: query dạng `PR nào ở AAP927?` vẫn là query read-only.
2. Nếu có `ticket` HOẶC `referenced_ticket` + verb fix/làm/sửa/proceed → ticket-resume.
3. Nếu verb bulk (resolve/close/fix/update/review) + set keyword (các/hết/all/AAP*) → bulk-op.
4. Interrogative (nào/sao/bao nhiêu/when/how many/which) → query.
5. Imperative control (stop/pause/list/cancel/reconcile now) → meta-cmd.
6. Khác → chat.
7. confidence < 0.7 → ƯU TIÊN "chat" (an toàn, dễ clarify sau). KHÔNG áp dụng cho out-of-scope — out-of-scope cần confidence ≥ 0.7 mới gán, dưới ngưỡng → fallback về chat/clarify bình thường.

Chỉ trả về JSON, không prose.
```

## Confidence rules

| Confidence | Action |
|---|---|
| ≥0.9 | Dispatch thẳng theo routing table |
| 0.7–0.9 | Dispatch + Discord ack kèm note *"Mình hiểu là {intent}: {slug}. Reply `không phải` trong 30s nếu sai."* |
| <0.7 | **KHÔNG dispatch.** Discord reply clarify: *"Mình chưa rõ ý. Bạn muốn (a) resume ticket (b) bulk op (c) query (d) chat / context push (e) meta-cmd? Reply rõ hơn nhé."* Lưu inbox file sang `processed/` với `job_g_outcome: low-conf-clarify`. |

## Routing table (per intent → next action)

| Intent | Next helper / action | Spawn mode |
|---|---|---|
| **ticket-resume** | `discord-resume-handler.md` (ticket-resume branch) — Agent subagent `resume-<KEY>` chạy `/jira-bug-analyzer <KEY> --resume-from-defer` (re-analyze + đề xuất plan, không tự fix) | Agent background subagent |
| **bulk-op** | `discord-safety-gate.md` — Discord confirm 60s TTL. Nếu `yes` → Agent subagent `bulk-<slug>` enumerate targets + act parallel | Agent background subagent (sau gate) |
| **query** | Agent subagent `query-<slug>` read-only — jira_search / gh pr list / ledger scan → reply Discord với kết quả | Agent background subagent (no gate — read-only) |
| **chat/context** | Inline xử lý: save attachments vào `.jira-bug/discord-attachments/<ticket_ref or _unassigned>/` + Jira comment nếu có `ticket_ref` + Discord ack *"📝 Đã lưu context."* | Inline (không spawn) |
| **meta-cmd** | Phân sub-type: destructive (stop/pause/cancel/clear) → `discord-safety-gate.md`; non-destructive (list/status/reconcile now) → inline execute + Discord reply | Inline hoặc inline-after-gate |
| **out-of-scope** (v1.15.1+) | Inline Discord reply explain lý do + đề xuất target đúng (xem `manager-discord-jobs.md` → "Job G out-of-scope branch"). KHÔNG dispatch, KHÔNG act. | Inline (không spawn) |

## Thread context loading

Khi `thread_id` present trong inbox file + env `LEARN_APP_DISCORD_BOT_TOKEN` set:

### Fetch rules
- REST call: `GET https://discord.com/api/v10/channels/{thread_id}/messages?limit=20`
- Header: `Authorization: Bot {LEARN_APP_DISCORD_BOT_TOKEN}`
- Timeout: 5s
- Response parse: array `[{author.username, content, timestamp}, ...]` reverse-chronological → reorder thành chronological

### Trim rule (~2K tokens)
- Cap tổng: 8K chars (~2K tokens @ 4 chars/token)
- Format mỗi line: `<author> [<timestamp>]: <content>`
- Vượt cap → giữ last-N messages (keep newest, drop oldest)

### Cache
- Dir: `.jira-bug/discord-thread-cache/`
- File: `<thread_id>.json` schema `{thread_id, messages: [{author, content, ts}], cached_at: ISO}`
- TTL: 300s. `now - cached_at < 300` → use cache. Else fetch + overwrite.
- Init: `mkdir -p` idempotent trong Job G init.

### Fallback cases
| Case | Fallback |
|---|---|
| Env `LEARN_APP_DISCORD_BOT_TOKEN` unset | `thread_context = ""` (classifier chạy không context) |
| REST 401/403 (bot không có quyền thread) | Log warn + `thread_context = ""` |
| REST timeout (>5s) | Log warn + `thread_context = ""` |
| REST rate-limit 429 | Exponential backoff (1s, 2s, 4s), max 3 retry → nếu vẫn fail: skip |
| `thread_id` missing nhưng `referenced_message_id` có | Fetch chỉ parent: `GET /channels/{channel_id}/messages/{referenced_message_id}` → `thread_context = "Reply vào: <author>: \"<content>\""` |

### Prompt inject rule
Khi fill `{thread_context}` placeholder trong classifier prompt:
- Có thread context: `"Thread history (last {N}):\n{formatted}"`
- Có referenced-only: `"Reply vào: {parent_author}: \"{parent_content}\""`
- Không có cả 2: empty string (prompt skip slot)

## Examples

### Example 1 — ticket-resume (strong signal)
```
content_stripped: "AAP729-3 fix"
ticket: "AAP729-3"
→ {"intent": "ticket-resume", "slug": "aap729-3-fix", "target_set": {"key": "AAP729-3"}, "confidence": 0.98, "reasoning": "Ticket key + verb fix explicit"}
```

### Example 2 — ticket-resume (reply-quote inherit)
```
content_stripped: "check lại giúp"
ticket: ""
referenced_ticket: "AAP729-3"
trigger_type: "reply"
→ {"intent": "ticket-resume", "slug": "aap729-3-recheck", "target_set": {"key": "AAP729-3"}, "confidence": 0.85, "reasoning": "Reply-quote inherit AAP729-3 + verb check-again"}
```

### Example 3 — bulk-op
```
content_stripped: "resolve conflict các PR"
ticket: ""
→ {"intent": "bulk-op", "slug": "resolve-conflict-prs", "target_set": {"query": "open PRs with conflicts", "verb": "resolve conflict"}, "confidence": 0.92, "reasoning": "Verb bulk resolve + set keyword các PR"}
```

### Example 4 — query (read-only)
```
content_stripped: "PR nào đang review?"
→ {"intent": "query", "slug": "prs-in-review", "target_set": {"question": "PR nào đang review?"}, "confidence": 0.95, "reasoning": "Interrogative nào + question mark"}
```

### Example 5 — query (status Vietnamese)
```
content_stripped: "còn bao nhiêu ticket defer trong AAP729?"
→ {"intent": "query", "slug": "defer-count-aap729", "target_set": {"question": "còn bao nhiêu ticket defer trong AAP729?"}, "confidence": 0.95, "reasoning": "Bao nhiêu + question structure"}
```

### Example 6 — chat/context
```
content_stripped: "đây là log cho AAP729-5"
attachments: [{"url": "https://cdn.discord.com/...log.txt"}]
→ {"intent": "chat", "slug": "aap729-5-log", "target_set": {"ticket_ref": "AAP729-5", "has_attachment": true}, "confidence": 0.88, "reasoning": "Attachment + ticket mention + không verb action"}
```

### Example 7 — meta-cmd (non-destructive)
```
content_stripped: "list running subagents"
→ {"intent": "meta-cmd", "slug": "list-subagents", "target_set": {"cmd": "list", "args": "subagents"}, "confidence": 0.9, "reasoning": "Imperative list + target subagents"}
```

### Example 8 — meta-cmd (destructive, cần gate)
```
content_stripped: "stop watcher"
→ {"intent": "meta-cmd", "slug": "stop-watcher", "target_set": {"cmd": "stop", "args": "watcher"}, "confidence": 0.95, "reasoning": "Imperative stop → destructive, cần safety gate"}
```

### Example 9 — low-confidence → clarify
```
content_stripped: "hmm"
→ {"intent": "chat", "slug": "clarify", "target_set": {"ticket_ref": "", "has_attachment": false}, "confidence": 0.3, "reasoning": "Content quá ngắn, không xác định intent"}
```
Job G: confidence < 0.7 → clarify branch (reply options, không dispatch).

### Example 10a — out-of-scope (project-mismatch, v1.15.1+)
Message: `dùng /claude-in-chrome vào đọc sheet này tab: 'Remote Config' và tạo remote config cho sản phẩm AAP927 cho tôi.`
Context: `current_board = "AAP729"`
→ `{"intent": "out-of-scope", "slug": "aap927-remote-config", "target_set": {"mentioned_project": "AAP927", "requested_action": "tạo remote config từ sheet", "reason": "project-mismatch"}, "confidence": 0.95, "reasoning": "Project AAP927 ≠ board AAP729 + yêu cầu non-jira task (Firebase remote config) + prefix /claude-in-chrome addressed khác target"}`

### Example 10b — out-of-scope (other-skill-target, v1.15.1+)
Message: `@claude /figma extract design tokens từ link này https://figma.com/...`
Context: `current_board = "AAP729"`
→ `{"intent": "out-of-scope", "slug": "figma-tokens-extract", "target_set": {"mentioned_project": "", "requested_action": "extract design tokens từ Figma", "reason": "other-skill-target"}, "confidence": 0.92, "reasoning": "Prefix /figma = skill khác, không thuộc jira-bug-analyzer manager scope"}`

### Example 11 — ambiguous (bulk vs query)
```
content_stripped: "các PR nào có conflict?"
→ {"intent": "query", "slug": "prs-with-conflict", "target_set": {"question": "các PR nào có conflict?"}, "confidence": 0.75, "reasoning": "Có từ nào + question → query (dù có keyword các). Nếu user muốn action: @claude resolve conflict các PR"}
```

## Idempotency

- Classify step read-only — không ghi state.
- Routing step mới ghi state (spawn subagent / inline execute / write pending-confirm).
- Classifier LLM crash → Job G log warn + treat as low-conf clarify branch + Discord reply *"Lỗi phân loại, xin thử lại rõ hơn."*

## Metrics tracking

Job G mỗi lần classify ghi vào `.jira-bug/active-resumes.json` row:
- `message_id`, `intent`, `confidence`, `slug`, `classified_at`, `token_estimate` (prompt + response).
- Để monitor Risk #2 (subagent-per-query token cost) → nếu overrun → v1.14.1 pivot query inline.

## Cross-refs

- `assets/discord-inbox-write.sh` — producer (schema v1.14)
- `discord-resume-handler.md` — ticket-resume branch (sau route)
- `discord-safety-gate.md` — bulk-op + destructive meta-cmd gate (sau route)
- `phase-manager-mode.md` → Job G — caller orchestrator
