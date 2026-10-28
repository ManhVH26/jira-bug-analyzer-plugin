# Cách dùng `jira-bug-analyzer` ở từng chế độ

Tài liệu nhanh cho dev: gọi skill thế nào, mỗi chế độ làm gì, dùng khi nào. Chi tiết kỹ thuật xem `SKILL.md` + các `references/phase*.md`.

## Chế độ được quyết định từ THAM SỐ (không phải thư mục/repo)

| Bạn gõ | Chế độ | Ý nghĩa |
|---|---|---|
| `AIP686-179` (có `-<số>`) | **single** | Sửa MỘT ticket theo key |
| `AIP686` (không có `-<số>`) | **multi** | Kéo cả board `AIP686`, chọn & sửa nhiều ticket |
| *(không tham số)* | **multi** | Hỏi project key trước, rồi như trên |
| `--manager AIP686` | **manager** | Bảo trì board (KHÔNG sửa bug mới) |
| `--team AIP686` | **multi + team** | Multi chạy bằng Agent Team |

> `KEY-123` = ticket → single · `KEY` = project → multi. `--manager` luôn thắng suy luận (key đứng cạnh nó chỉ là board).

---

## 1) Single — sửa một ticket

```
/jira-bug-analyzer AIP686-179
```
- Dùng khi: đã biết đúng ticket cần sửa.
- Luồng: Tiếp nhận → Nguồn dữ liệu chuẩn (nền) → **Phân tích** (claim → nguyên nhân gốc → kế hoạch → **chờ duyệt**) → **Sửa + build** → **Kiểm thử** (review diff + cài APK + user kiểm thử) → **Commit & PR**.
- Bạn sẽ được hỏi: duyệt kế hoạch, xác nhận kiểm thử OK. **Link spec/Figma KHÔNG còn phải dán tay** — skill tự dò từ chính ticket (remote-link / link trong mô tả) và từ trong spec; chỉ hỏi khi dò không ra (hoặc cho chọn 1 chạm khi có nhiều ứng viên). Dò nhầm trang → chạy lại với `--rediscover`.

## 2) Multi — kéo board, sửa nhiều ticket

```
/jira-bug-analyzer AIP686
/jira-bug-analyzer AIP686 @3        # chỉ định phase 3
```
- Dùng khi: muốn dọn nhiều bug trên một board.
- Luồng lượt: **kéo** → danh sách nhóm theo lĩnh vực → **bạn chọn số** (≤4/nhóm/lượt) → claim tất cả → **phân tích song song** (nền, hàng đợi FIFO, duyệt từng cái) → mỗi ticket được duyệt có **fixer riêng** (worktree + build) → ticket nào xong trước thì **review + merge vào nhánh batch trước**, không chờ cái khác → mở/cập nhật **MỘT PR batch** → **kéo lại lượt sau** đến khi hết bug.
- Chọn cả nhóm = lấy hết bug trong nhóm và chạy luôn (không hỏi lại).

## 3) Manager — bảo trì board (chế độ thứ 3)

```
/jira-bug-analyzer --manager AIP686
/jira-bug-analyzer --manager AIP686 --auto
```
- Dùng khi: chạy **sau** một batch `--auto`/multi để dọn dẹp. KHÔNG phải pipeline sửa bug.
- 8 việc: **Job A** gom & xử lý PR review-comment · **Job B** dọn worktree khi PR merge/đóng · **Job C** KB-backfill cho ticket đã Done · **Job D** đo tỉ lệ reopen của ticket `--auto` tự sửa (theo lịch sử trạng thái Jira) · **Job E** theo dõi comment `@claude` trên ticket bị hoãn · **Job F–H** (chỉ khi bật Discord) báo Resolved, điều phối tin nhắn Discord, xác nhận lệnh.
- Với `--auto`: Job A tự áp dụng fix rõ ràng; Job C luôn tự động.

## 4) Team — multi chạy bằng Agent Team

```
/jira-bug-analyzer --team AIP686
/jira-bug-analyzer --team AIP686 --devs 3
```
- Dùng khi: muốn nhiều phiên cộng tác song song. Session này thành MainCharacter, khởi chạy team `jira-bugfix` (Lead + Devs + Tester + Observer).
- `--devs N` đặt số Dev. Không có `--team` → skill là worker đơn, không bao giờ tự lập team.

---

## Cờ phụ (kết hợp với mọi chế độ)

| Cờ | Tác dụng |
|---|---|
| `--auto` | **Vòng tự động hoàn toàn**: tự chọn ticket → tự tái hiện lỗi trên máy rồi fix nếu điểm tin cậy ≥80 (≥90 nếu tắt tái hiện bằng `--no-repro`, ≥40 nếu có `--auto-low`), thấp hơn thì hoãn; bug hành vi chỉ tự sửa khi verify được trên máy; ticket từng bị hoãn vì thiếu thông tin không bao giờ tự sửa → verify (code-reviewer + adb) → commit+PR ở subagent nền (Discord TẮT trừ khi có `--discord`, **mở PR nhưng KHÔNG merge**) → kéo lại đến khi board rỗng → ghi báo cáo. Mặc định TẮT = mọi cổng đều hỏi. |
| `--discord` | **Bật đăng review PR lên Discord** (kênh *Apero Mobile Developer / review-pr*, qua `pr-discord-review-request`, Phase-6 Bước 3) — dùng với mọi mode. Ở mode tương tác: biến câu hỏi *"Đăng Discord?"* thành tự-Yes (bỏ hỏi, luôn enqueue). Với `--auto`: đây là cách DUY NHẤT để đăng (mặc định `--auto` TẮT Discord); agent nền enqueue PR sau khi mở. Best-effort — cần `PR_DISCORD_CHANNEL_URL` (`.claude/.env`); thiếu khi `--auto` → ghi vào báo cáo + bỏ qua, không chặn vòng lặp. Không có cờ + tương tác: vẫn hỏi, mặc định Y. |
| `@N` | Chỉ định phase tường minh (vd `@3`) — thắng mọi suy luận; không có thì suy từ tiêu đề spec. |
| `--model opus\|sonnet\|haiku` | Ghi đè ma trận model theo từng bước. |
| `--resume` | Đồng bộ lại bộ theo dõi PR / trạng thái đang chờ (modifier, không phải mode). |
| `--recheck-env` | Buộc chạy lại env preflight, bỏ cache `env`. |
| `--prune <PROJ>` | Xóa bộ nhớ phiên (`session/` ledger) khi đóng giai đoạn; KB/setup giữ nguyên. |
| `--devs N` | (chỉ với `--team`) số Dev trong team. |
| `--pr-window` | **ĐÃ BỎ** — review giờ stream theo từng ticket, không có cửa sổ; cảnh báo + bỏ qua nếu truyền. |
| `--every` | **ĐÃ BỎ** — multi tự kéo lại mỗi lượt; cảnh báo + bỏ qua nếu truyền. |

---

## Quy tắc luôn đúng (mọi chế độ)

- **Hỏi duyệt kế hoạch trước khi viết code** — chế độ thường LUÔN hỏi bất kể điểm; chỉ `--auto` mới bỏ qua (đạt ngưỡng trong `references/constants.md` thì tự sửa, thấp hơn thì hoãn).
- **Luôn phân tích + tách nhánh trên code MỚI NHẤT** (`git fetch origin` → `origin/<BASE>`).
- **Không bao giờ PR trước khi review diff + user kiểm thử pass** (chỉ người, hoặc `--auto`, được bỏ qua).
- **Một commit mỗi ticket**, không squash khi multi.
- **Tiếng Việt** cho mọi nội dung hiển thị; PR & bộ nhớ giữ tiếng Anh.
- **Kiểm thử thiết bị chỉ bằng `adb`** (không mobile-mcp).

---

## Ví dụ nhanh

```
/jira-bug-analyzer AIP686-200            # sửa 1 ticket
/jira-bug-analyzer AIP686                 # mở board, chọn & sửa nhiều
/jira-bug-analyzer AIP686 @3 --auto       # phase 3, tự động hoàn toàn
/jira-bug-analyzer --team AIP686 --devs 3 # multi bằng team 3 dev
/jira-bug-analyzer --manager AIP686       # dọn dẹp sau batch
```

> Xem trực quan 6 giai đoạn: mở `assets/flow-preview.html`.
