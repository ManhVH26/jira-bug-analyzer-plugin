# Discord safety gate — 60s confirm cho destructive ops (`[DISCORD-MULTIPURPOSE]` v1.14.0+)

> **Scope:** Chặn stakeholder lỡ tay. Trước khi Job G spawn Agent subagent cho destructive intent (bulk-op + meta-cmd stop/pause/cancel/clear) → post Discord confirm 60s TTL → chờ reply `yes`/`no`/timeout → act. Local file-based state ở `.jira-bug/pending-confirms/<message_id>.json` — không BGMEM sync (race acceptable, single confirm = single machine wins).

## Khi nào gate

Classifier (xem `discord-classifier.md`) trả về intent + Job G quyết định có gate không:

### Destructive (BẮT BUỘC gate)
| Intent | Sub-type | Example |
|---|---|---|
| **bulk-op** | ALL | `resolve conflict các PR`, `close hết defer AAP*`, `fix tất cả bugs sprint này` |
| **meta-cmd** | `stop`, `pause`, `cancel`, `clear`, `delete`, `kill` | `stop watcher`, `pause --manager`, `cancel resume-AAP729-3`, `clear active-resumes`, `delete pending-confirms` |

### Non-destructive (KHÔNG gate)
| Intent | Reason |
|---|---|
| **ticket-resume** | User intent đã rõ qua ledger `analyzed-deferred` + explicit verb |
| **query** | Read-only — không ghi state |
| **chat/context** | Chỉ save file + Jira comment — reversible |
| **meta-cmd** non-destructive (`list`, `status`, `reconcile now`, `show`) | Read-only hoặc expected ops |

## Pending file schema

Path: `.jira-bug/pending-confirms/<original_message_id>.json`

```json
{
  "schema_version": "v1.14",
  "original_message_id": "1561566668256186482",
  "author_id": "123456789",
  "author_name": "LinhMyx",
  "channel_id": "1560595714386567169",
  "thread_id": "",
  "intent": "bulk-op",
  "slug": "resolve-conflict-prs",
  "target_set": {"query": "open PRs with conflicts", "verb": "resolve conflict"},
  "action_summary": "resolve conflict trên 5 PR open",
  "target_count": 5,
  "target_preview": ["PR #15 AAP729-3", "PR #16 AAP729-7", "..."],
  "discord_confirm_message_id": "1561600111222333444",
  "created_at": "2026-10-19T04:15:00Z",
  "expires_at": "2026-10-19T04:16:00Z",
  "ttl_seconds": 60
}
```

## Confirm post flow (Job G caller)

```
1. Build action_summary + target_preview từ classifier target_set:
   - bulk-op: enumerate targets (jira_search / gh pr list) để count + preview top 3-5
   - meta-cmd destructive: parse args → describe side effect
2. Build Discord confirm content theo template (dưới).
3. POST Discord qua LEARN_APP_DISCORD_BOT_TOKEN:
   - POST /channels/{channel_id}/messages với body JSON {content, message_reference: {message_id: <original>}}
   - Capture returned message.id → discord_confirm_message_id
4. Write .jira-bug/pending-confirms/<original_message_id>.json với expires_at = now + 60s.
5. Return từ Job G (KHÔNG spawn subagent). Monitor loop sẽ bắt reply arrival.
```

### Confirm post template (VN)

**Bulk-op:**
```
⚠️ Mình chuẩn bị **{action_summary}** trên **{target_count} target**:
{target_preview_bulleted}

Reply `yes` trong 60s để tiến hành, `no` để huỷ. Timeout = huỷ.
```

Ví dụ:
```
⚠️ Mình chuẩn bị **resolve conflict trên 5 PR open**:
• PR #15 AAP729-3
• PR #16 AAP729-7
• PR #18 AAP729-11
• PR #22 AAP729-14
• PR #23 AAP729-18

Reply `yes` trong 60s để tiến hành, `no` để huỷ. Timeout = huỷ.
```

**Meta-cmd destructive:**
```
⚠️ Mình chuẩn bị **{action_summary}**.
Side effect: {side_effect_description}

Reply `yes` trong 60s để tiến hành, `no` để huỷ.
```

Ví dụ:
```
⚠️ Mình chuẩn bị **stop Discord inbox watcher**.
Side effect: `--manager` sẽ KHÔNG nhận Discord trigger realtime nữa (cron fallback vẫn chạy mỗi 10 min). Để re-arm phải Ctrl+C + re-invoke --manager.

Reply `yes` trong 60s để tiến hành, `no` để huỷ.
```

## Reply resolution (Job G khi nhận inbox file mới có `referenced_message_id`)

```
1. Check .jira-bug/pending-confirms/<referenced_message_id>.json tồn tại?
2. KHÔNG → không phải confirm reply. Classify bình thường (xem discord-classifier.md).
3. CÓ → đọc pending.
4. Check author filter: nếu env JIRA_BUG_GATE_SAME_AUTHOR=1 + reply.author_id ≠ pending.author_id → ignore + log + continue (reply xử lý như message thường).
5. Check expiry: now > expires_at → ignore reply + Discord ack *"Hết hạn, không thực hiện"* + mv pending sang .jira-bug/pending-confirms/processed/.
6. Parse reply.content_stripped (lower-case, strip whitespace):
   - Match ["yes", "y", "ok", "đồng ý", "ừ", "ừa", "được", "go", "proceed"] → ACCEPT branch
   - Match ["no", "n", "cancel", "huỷ", "huy", "không", "khong", "stop"] → REJECT branch
   - Khác → AMBIGUOUS branch
7. ACCEPT:
   - Spawn subagent theo original intent (bulk-op → `bulk-<slug>`; meta-cmd → inline execute)
   - Discord reply vào confirm message: *"✅ Đã bắt đầu. Theo dõi trong `--manager` agents panel."*
   - mv pending sang processed/
8. REJECT:
   - Discord reply: *"🚫 Đã huỷ."*
   - mv pending sang processed/
9. AMBIGUOUS:
   - Nếu first ambiguous → re-ask 1 lần: *"Mình chưa rõ. Reply `yes` hoặc `no` nhé."* + reset expires_at = now + 60s + update pending file.
   - Nếu already re-asked (metadata `reask_count >= 1`) → auto-cancel + Discord *"Không nhận confirm rõ, đã huỷ."* + mv pending sang processed/.
```

## Expiry sweep (/loop tick trong Job G)

```
1. ls .jira-bug/pending-confirms/*.json (loại trừ processed/)
2. Per file: parse expires_at
3. now > expires_at → Discord ack vào channel_id (reply vào discord_confirm_message_id):
     *"⏰ Hết hạn confirm cho \"{action_summary}\". Không thực hiện."*
   → mv file sang processed/<file>.json + append metadata {status: expired, closed_at: now}
```

## Multi-machine race safety

Scenario: 2 dev chạy `--manager` cho cùng board → cùng thấy pending file khi reply arrive.

- `mv` filesystem là atomic op. Máy A mv `pending-confirms/<id>.json → processed/` thành công, máy B thấy file mất → skip.
- Máy A tiếp tục spawn subagent + Discord ack. Máy B tiếp tục reconcile pass khác.
- Edge case: 2 máy cùng accept, spawn 2 subagents cho cùng bulk-op → `active-resumes.json` dedup phải chặn (check `slug` + `original_message_id` trước spawn).

## Env options

| Env | Default | Effect |
|---|---|---|
| `JIRA_BUG_GATE_SAME_AUTHOR` | unset | Nếu `=1`, chỉ `author_id` gốc của confirm message mới reply được. Khác → ignore. |
| `JIRA_BUG_GATE_TTL_SECONDS` | 60 | Override TTL. Min 30, max 300. |
| `JIRA_BUG_GATE_DISABLED` | unset | Nếu `=1`, SKIP toàn bộ gate (dangerous, chỉ dùng dev test local). |

## Discord POST error handling

| Error | Action |
|---|---|
| 401/403 (token invalid) | Log critical + abort Job G flow (không write pending file) + Discord KHÔNG reply được |
| 429 (rate limit) | Exponential backoff (1s, 2s, 4s), max 3 retry. Fail → log + abort |
| 5xx (Discord server) | Retry 1 lần sau 2s. Fail → log + abort |
| Timeout 10s | Treat as 5xx |

Khi POST confirm fail → KHÔNG write pending file → log vào `--manager` terminal → user thấy warning → có thể retry bằng cách gõ lại `@claude <action>`.

## Idempotency

- Pending file write-once (filename là `<message_id>.json` unique).
- Reply resolution kiểm pending tồn tại trước khi act → crash giữa chừng, tick sau retry từ cùng state.
- Expired sweep xoá file → không still-pending leaks.

## Cross-refs

- `discord-classifier.md` — intent taxonomy + routing (upstream caller)
- `discord-resume-handler.md` — non-gated path (ticket-resume branch)
- `phase-manager-mode.md` → Job G — orchestrator
- `assets/discord-roles.json` — `defer_channel_id` để verify POST đúng channel
