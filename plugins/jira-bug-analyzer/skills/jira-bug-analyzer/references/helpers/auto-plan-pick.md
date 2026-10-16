# Auto plan-pick — tiêu chí fix vs defer dưới `--auto` (Phase 3)

> `[AUTO]` decision file cho **Phase 3 approval**. Dưới `--auto` không hỏi dev — file này là tiêu
> chí tự quyết **fix luôn vs defer + report**, dựa trên scorecard. **Dùng** điểm từ
> `references/helpers/confidence-rubric.md` (không định nghĩa lại cách chấm).
> Rubric anh em: `auto-ticket-pick.md` (Phase 1), `auto-run-test.md` (Phase 5).

## Tiêu chí quyết định
- **Score `sum ≥ threshold`** → auto-approve → fix luôn (Phase 4). **Threshold tách theo `[REPRO_ON]` + modifier `--auto-low`:**
  - `[REPRO_ON]=true` (user opt-in qua `--repro` hoặc NL intent) → **threshold = 80** (quy tắc cũ).
  - `[REPRO_ON]=false` (mặc định — không có `--repro`) → **threshold = 90**. Lý do: không có điểm `deterministic_repro` (A7c), nâng ngưỡng để bù phần rigor đã mất.
  - **`--auto-low` present (modifier any `--auto` run)** → **threshold = 40** (floor) + **`[LOW-RISK-GATE]` ADDITIONAL check** (bên dưới). Dùng khi dev muốn giảm độ chặt — AI đang defer quá nhiều ticket có plan hợp lý nhưng score thấp. Mọi ticket fix dưới nhánh này đeo **cả hai** Jira label `auto-fixed` + `auto-fix-low` (Phase 6) để Manager Job D track reopen-rate riêng (metric chất lượng của low-conf fixes).
  - In rõ `[REPRO_ON]` + `[AUTO_LOW]` + threshold đã chọn vào scorecard khối Fix-6 để dev soi được.

### `[LOW-RISK-GATE]` — chỉ áp khi `--auto-low` (sau khi score ≥ 40)
Trước khi approve fix, dispatch `code-reviewer` agent (hoặc Phase 3 analyzer tự judge với prompt dưới) với **fix plan + Phase-3 analysis + related files** làm input. Agent trả **pass/fail** cho câu hỏi:

> *"Plan này có **reasonable** (giải thích đúng root cause, không guess) + **low-risk** (scope hẹp — ≤ vài file đã biết; blast-radius giới hạn — không đụng Clean-Arch layer boundary / design-system token / shared composable toàn app; không gây regression rõ) không?"*

- **Pass** → fix (Phase 4) như bình thường.
- **Fail** → **defer** với reason `low-risk-check-failed` (ghi lý do fail từ agent vào ledger row + report). KHÔNG retry — defer là final cho ticket đó trong turn này (dev reply `@claude fix` trên Jira sẽ trigger Job E re-analyze).
- **Agent `blocked` / error** → defer `low-risk-check-blocked` (an toàn hơn là fix mù).

Gate này tồn tại vì `--auto-low` hạ threshold xuống 40 — mất rào ngưỡng chính; LLM judge gate là rào thứ hai, chặn fix mù những bug thực sự nguy hiểm chỉ vì score tình cờ ≥ 40.
- **Không reproduce được on-device** — CHỈ áp khi `[REPRO_ON]=true` (`bug-analysis-rules.md` `[REPRO]` A7a/A10) → **defer** (`unreproducible` hoặc `no-device`); **dưới `--auto` + `--repro` device là BẮT BUỘC, không có static fallback** — không có máy / không lấy được device lock trong thời gian chờ / chạy hết ladder vẫn không repro → defer + report. `--auto --repro` KHÔNG BAO GIỜ auto-fix một bug chưa reproduce được trên máy. **`[REPRO_ON]=false`: KHÔNG defer vì không có repro** — mặc định là bỏ qua bước này; chỉ ngưỡng 90 bù lại.
- **Không phải bug code thật** (config/console · backend · stale build/env/device · works-as-designed · duplicate — A1/A2) → route Fix-9 (non-code comment) / defer; không tự chế fix.
- **Score `sum < threshold`** → **defer + report** (mark `deferred`, không fix), ghi lý do `score <threshold (sum=N, [REPRO_ON]=<true|false>, [AUTO_LOW]=<true|false>)`.
- **Còn câu hỏi chưa rõ** (SOT có, nhưng không trả lời được câu hỏi của ticket) → **defer** (`clarify-gap`); auto KHÔNG tự đoán.
- **KHÔNG có source-of-truth cho cả phase** (ladder §2.0 (`references/helpers/source-of-truth-discovery.md`) trả NONE, hoặc FUZZY không qua ngưỡng auto-adopt) → **defer** (**`no-sot`**) — lý do RIÊNG, đừng gộp vào `clarify-gap`. Khác nhau ở chỗ: `clarify-gap` là *thiếu 1 câu trả lời cho 1 ticket*, `no-sot` là *cả phase không có ground truth* → nó tác động MỌI ticket của phase, và cách gỡ là ở cấp phase chứ không phải cấp ticket. **Report BẮT BUỘC kèm rung trace + cách gỡ:** đã đi qua rung nào, mỗi rung trả gì, rồi nêu đích danh remedy. **Trace PHẢI bao gồm cả 3 rung project-level (L2d sweep toàn project · L2e fixVersion+Epic của phase · L2f project description)** — nếu chưa chạy chúng thì chưa được kết luận `no-sot`. Remedy thường gặp: thêm/sửa `@N` (mở khoá L2e + xếp hạng L2d theo fixVersion), hoặc override bằng `--spec <url> --figma <url>`. **Ghi trống `no-spec` mà không có trace là VI PHẠM** — chính nó làm lỗi này vô hình suốt thời gian qua (xem SKILL.md `[AUTO]`).
- **Mid-fix phát hiện plan sai** → **defer** (`mid-fix wrong-plan`); không auto re-plan.
- **Trùng** `root_cause_slug` ticket khác → **skip** (mark `commented`, ghi ticket gốc); không "fix anyway".

## Khi defer — chuyển sang "Request" rồi ĐI TIẾP (không dừng loop)
Mỗi khi một ticket bị defer (score <80 / clarify-gap / **no-sot** / mid-fix wrong-plan / **unreproducible / no-device**), dưới `--auto`:
1. **Transition ticket → `Request`** (REST, `jira_transition`) — đưa nó RA KHỎI `In Progress` và trả về pool triage mở để người (hoặc một lần chạy sau có thêm thông tin) tiếp nhận. **Giữ assignee = dev account** (người đã claim) để biết ai đã phân tích. Verify `now=Request` qua readback. (Nếu workflow không có transition tên `Request`, dùng status mở gần nhất; nếu thực sự không thoát được `In Progress` thì để nguyên + ghi chú trong report.)
2. Post 1 comment `[VN]` ngắn lên ticket: lý do defer + tóm tắt plan đã có (để người sau làm tiếp), kèm link ledger slug. (`[REST]`, verify 201.)
3. Giữ nguyên ledger row `analyzed-deferred` (root_cause_slug + summary + files) + thêm vào end-of-run report.
4. **ĐI TIẾP NGAY sang ticket/batch kế** — **defer KHÔNG BAO GIỜ là điều kiện dừng loop.** Loop chỉ dừng khi re-pull trả về 0 ticket (board rỗng) hoặc gặp `[AUTO-GATE]` do dev định nghĩa. **Vì `Request` NẰM TRONG pool pull, chống re-pick KHÔNG dựa vào status mà dựa vào DEDUP:** `.jira-bug/batch-progress.md` (cùng session) + ledger row `analyzed-deferred` (cross-session). `auto-ticket-pick.md` BỎ QUA mọi ticket đã `analyzed-deferred`. **Resume ticket deferred được xử lý CHỦ ĐỘNG bởi Job E** (`references/phase-manager-mode.md` → "Job E — Deferred-ticket comment watcher") — khi dev reply trên Jira với marker `@claude`/`@agent`, Job E xoá ledger row + re-analyze với comment làm clarify.

### Ledger row schema

Ledger row `analyzed-deferred` có các field sau (ví dụ):
```
TICKET: APDF1-2251
status: analyzed-deferred
date: 2026-10-15T10:30:00Z
reason: no-sot                  # score-lt-threshold | clarify-gap | no-sot | mid-fix-wrong-plan | unreproducible | no-device | low-risk-check-failed | low-risk-check-blocked
root_cause_slug: ...
summary: ...
files: ...
commentsCursor: 0               # per-ticket last-processed comment ID — maintained bởi Job E (phase-manager-mode.md)
review_requested_by_comment:    # optional/nullable — Job E Review branch set giá trị <commentId> khi dev chỉ đạo "không fix, cần review"
```

- `commentsCursor` init = `0` lúc defer. Job E advance monotonically mỗi khi xử lý xong comment có marker. Field thiếu trong ledger cũ → treat as `0` (backward-compat, Job E scan toàn bộ comment history lần đầu — marker + author filter chặn noise).
- `review_requested_by_comment` null/absent cho tới khi Job E Review branch set. Ticket có field này → đang ở status `Reviewing` (hoặc `Request` + label `needs-review` nếu transition fail).

> **Base build hỏng (vd `origin/develop` không compile) KHÔNG phải lý do dừng** — đây là case "try-and-decide" của Golden Rule `[AUTO]`: fold bản unbreak tối thiểu vào nhánh fix hiện tại (hoặc branch các fix kế off nhánh batch đã chứa unbreak), ghi vào report, đi tiếp. Đừng pause loop chờ người.

## Single mode
Cùng tiêu chí cho 1 ticket: `sum ≥ threshold` → fix; `<threshold` / clarify-gap → defer + report. Threshold matrix: `--auto-low` → 40 (+ `[LOW-RISK-GATE]`); else `[REPRO_ON]=true` → 80; else → 90. Defer cũng PARK sang `Request` như trên (single thì park xong là kết thúc, không có batch kế).
