# Auto run-test — tiêu chí verify dưới `--auto` (Phase 5)

> `[AUTO]` decision file cho **Phase 5 verify**. Dưới `--auto` không có người duyệt — thay bằng
> `code-reviewer` (Gate 1) + **bundled `android-self-verify` skill** (Gate 2). Skill drive bằng `adb`
> (screenshot quan sát real pixels, **không mobile-mcp**) theo `references/phase5-verify.md` (Device driver).
> Override `[VERIFY]` (bỏ user-verify tay — dev gõ `--auto` là đã waive).
> Rubric anh em: `auto-ticket-pick.md` (Phase 1), `auto-plan-pick.md` (Phase 3).

## Gate 1 — code-reviewer chấm diff (thay người duyệt)
- Chấm diff theo **`references/helpers/fix-code-rules.md` (`R1`–`R22`)** — surgical? đúng root-cause? đúng style/layer/design-system? không gây regression? sạch?
- **Không có lỗi `critical`** (clean / chỉ nit/style) → qua Gate 2.
- **Có lỗi `critical`** (sai logic, security, crash, sai scope, **hoặc vi phạm rule nghiêm trọng**: refactor ngoài scope R2, vá triệu chứng R5–R6, phá Clean-Arch/design-system R11–R13, rủi ro regression R14–R17) → re-fix (Phase 4). **Tính vào retry budget.**
- Nit/style → chỉ ghi vào PR body, không chặn.

## Gate 2 — verifier skill LÀ cổng verify (thay user-verify card)

> **[GATE 2 KHÔNG PHỤ THUỘC `--repro`]** Gate 2 chạy dưới `--auto` **BẤT KỂ `[REPRO_ON]`**. `[REPRO]` chỉ gate **Phase 3 Fix-5.5** (A4–A6 device repro). Verify ở Phase 5 là độc lập — `--auto --repro` và `--auto` (không `--repro`) **cùng** dispatch verifier subagent ở Gate 2. Cờ `not device-verified` mà Fix-6 emit khi `[REPRO_ON]=false` là **Phase-3 scoped** (= Phase 3 skip device repro), KHÔNG có nghĩa Phase 5 được skip verify. **Đường DUY NHẤT cho Phase 5 degrade sang static verify** là No-device fallback (phase5-verify.md Gate 2 step 1 — `free-serial` empty sau bounded wait). Skip Gate 2 chỉ vì không có `--repro` là BUG.

> **Chọn verifier theo scope ticket:** bug **UI** (layout/spacing, màu/theme, typography, canh lề, tràn/cắt chữ, element thiếu/sai chỗ, sai trạng thái hiển thị) → **`android-ui-verify`** (`references/android-ui-verify/SKILL.md`) — design-anchored: lấy Figma node của màn → chụp màn device → **vision-diff device ⟷ Figma theo 4 trục, CHẶN khi lệch material** (đây là cổng chặn reopen *"fix logic xong nhưng sai design"*) → **quét blast-radius** mọi thay đổi shared-UI (theme/token/dimens/shared composable/drawable) để bắt regression màn kế bên. Truyền thêm Figma `node-id` + acceptance tokens (Phase 3) + diff. Bug logic thuần → **`android-self-verify`** như cũ. Bug vừa logic vừa UI → chạy `android-ui-verify` rồi confirm thêm hành vi.
> **"Material deviation" = fail:** spacing lệch > ~4dp (hoặc nhìn rõ sai), sai màu (không khớp token), sai size/weight/family font, có truncation/overflow/overlap, hoặc element thiếu/sai chỗ. Nhiễu cosmetic dưới ngưỡng (±1–2px, anti-alias) → pass + ghi chú.
Gọi bundled **`android-self-verify`** skill (truyền change summary + repro steps + acceptance + variant `appDev`/debug + serial đang lock + worktree dir + **evidence dir** `.jira-bug/evidence/<TICKET>/`). Skill launch build từ worktree, re-drive repro + edge case, **lưu bằng chứng theo loại bug** — ảnh (`screencap`) cho bug tĩnh/visual; **video** (`screenrecord` → `pull`) cho bug động/flow/animation/scroll-jank/crash; cả hai nếu phân vân — quan sát real pixels từng state, trả verdict kèm **đường dẫn file bằng chứng đã lưu**:
- **pass** (đúng acceptance, không exception/jank, **có ít nhất 1 file bằng chứng đã lưu** — ảnh hoặc video tùy bug) → carry evidence path sang Phase 6 (PR body + Jira) → PR, không cần người xác nhận. **Pass mà không có file bằng chứng = không hợp lệ** (chụp lại hoặc trả `blocked`).
- **fail** (bug còn / regression) → re-fix (Phase 4). **Tính vào retry budget.**
- **blocked** (không tới được màn hình/đúng data state sau **5 lần retry** của skill: mất mạng, kẹt onboarding, không tìm được sách có chapter khóa…) → **defer + report** (`adb-blocked`); không bao giờ báo pass khi chưa quan sát được.
  - **Ngoại lệ — feature bị remote-config / feature-flag che (không phải lỗi nav/data-state):** trước khi báo blocked, áp dụng `[FEATURE-GATE]` ở Phase 5 Gate 2 — bật cờ về giá trị testing (sửa local, KHÔNG commit), rebuild `<BUILD_CMD>`, verify lại, rồi revert cờ trước `[1COMMIT]`. Chỉ khi vẫn không render được sau khi bật cờ → defer (`feature-gated`), ghi rõ cờ/giá trị QC cần bật để verify.
- **Không có máy** (device-lock không cấp được serial) → ticket **hành vi** (verifier = `android-self-verify`: mạng, vòng đời màn hình, xoay, quảng cáo, timing, hiệu năng) → **defer + report** (`no-device`), KHÔNG fail-open sang verify tĩnh. Chỉ ticket **UI thuần** mới được fail-open với cờ `not device-verified` (`references/phase5-verify.md` → Gate 2 bước 1). Lý do: nhóm hành vi bị reopen nhiều nhất khi tự sửa (AAP729, 16–22/10/2026).

> **Retry verify (`--auto`):** skill tự retry cả luồng verify tối đa **5 lần** (relaunch, tắt ad, đổi nội dung/data state, chụp lại) trước khi trả `blocked`. Đây là retry *quan sát*, KHÁC với retry budget re-fix = 2 lần (Gate-1-critical + Gate-2-fail).

> **Lưu ý screencap (quan trọng):** màn ad/onboarding/secure chụp ra **đen** — không phải fail; BACK để tắt ad rồi chụp lại màn app thật. Nội dung app (reader, list, bottom-sheet) chụp bình thường → **quan sát bằng screenshot, không bằng uiautomator text** (uiautomator không đọc được nội dung reader/WebView). Reader scroll dọc: swipe-up tránh thanh cuộn mép phải (`x≈450`). Git Bash: prefix `MSYS_NO_PATHCONV=1` cho path `/sdcard/...`.

## Retry budget (chặn loop vô tận)
- Tối đa **2 lần re-fix / ticket** (gộp cả Gate-1-critical + Gate-2-fail).
- Lần thứ 3 → **defer + report** (`retries-exhausted`).

## Granularity
- **Single** → 2 gate cho 1 ticket.
- **Multi/team** → Gate 1 chấm diff cả round; Gate 2 self-verify từng ticket; ticket fail/blocked bị
  kéo khỏi round (re-fix trong budget, hết thì defer), phần còn lại vẫn chạy.

## An toàn
Auto mở PR nhưng **không bao giờ merge** — người vẫn review ở GitHub PR trước khi merge.
