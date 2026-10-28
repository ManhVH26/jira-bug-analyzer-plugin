# Auto plan-pick — tiêu chí fix vs defer dưới `--auto` (Phase 3)

> `[AUTO]` decision file cho **Phase 3 approval**. Dưới `--auto` không hỏi dev — file này là tiêu
> chí tự quyết **fix luôn vs defer + report**, dựa trên scorecard. **Dùng** điểm từ
> `references/helpers/confidence-rubric.md` (không định nghĩa lại cách chấm).
> Rubric anh em: `auto-ticket-pick.md` (Phase 1), `auto-run-test.md` (Phase 5).

## Tiêu chí quyết định
- **Score `sum ≥ threshold`** → auto-approve → fix luôn (Phase 4). **Threshold tách theo `[REPRO_ON]` + modifier `--auto-low`:**
  - `[REPRO_ON]=true` (user opt-in qua `--repro` hoặc NL intent) → **threshold = `AUTO_THRESHOLD_REPRO`**.
  - `[REPRO_ON]=false` (mặc định — không có `--repro`) → **threshold = `AUTO_THRESHOLD_DEFAULT`**. Lý do: không có điểm `deterministic_repro` (A7c), nâng ngưỡng để bù phần rigor đã mất.
  - **`--auto-low` present (modifier any `--auto` run)** → **threshold = `AUTO_THRESHOLD_LOW`** (floor) + **`[LOW-RISK-GATE]` ADDITIONAL check** (bên dưới). Dùng khi dev muốn giảm độ chặt — AI đang defer quá nhiều ticket có plan hợp lý nhưng score thấp. Mọi ticket fix dưới nhánh này đeo **cả hai** Jira label `auto-fixed` + `auto-fix-low` (Phase 6) để Manager Job D track reopen-rate riêng (metric chất lượng của low-conf fixes).
  - Giá trị các ngưỡng: `references/constants.md`. In rõ `[REPRO_ON]` + `[AUTO_LOW]` + threshold đã chọn vào scorecard khối Fix-6 để dev soi được.
- **Phạm vi `--auto` (`AUTO_SCOPE`, R5 v1.15.3):** mặc định `ui-only` — ticket có scope Phase 3 là **hành vi** (cùng phân loại dùng để chọn verifier Phase 5: mạng, vòng đời màn hình, xoay, quảng cáo, timing/dữ liệu theo ngày, hiệu năng; kể cả UI + hành vi) → **chỉ được tự sửa khi đủ CẢ 4 điều kiện**: (1) `[REPRO_ON]=true` và đã **tái hiện được trên máy**; (2) `single_root_cause` đạt điểm; (3) `small_change` đạt điểm (`SMALL_CHANGE_MAX`); (4) Phase 5 verify trên máy là bắt buộc (không có máy → defer `no-device`, như hiện tại). Thiếu một điều kiện → **defer `behavioral-scope`** kèm comment `[VN]`: *"Bug hành vi — để dev sửa ở single mode (duyệt plan + kiểm thử trên máy)."* Fix hành vi được tự sửa đeo thêm Jira label `auto-fix-behavioral` (Phase 6) để Manager Job D đo reopen riêng. Lý do của luật: bug hành vi bị reopen nhiều nhất khi tự sửa (AAP729, 16–22/10/2026); nhưng ở A/B 28/10, AIP396-475 (đã tái hiện, 1 file, 80 điểm) bị hoãn trong khi bản fix tay giống hệt đã được QA Closed. **Phân loại làm TRƯỚC khi build/tái hiện** (Phase 3 Fix-5.5 bước 1b): ticket hành vi khi `[REPRO_ON]=false` không thể đủ điều kiện (1) → không build, không repro, defer ngay. Mở lại cho `--auto` bằng `setup.json` `autoScope: "all"` **chỉ khi** `scripts/reopen_report.py` cho thấy reopen của `--auto` ≤ mức của bug không-auto trong cùng project trên ≥ 50 ticket (R7).

### `[LOW-RISK-GATE]` — chỉ áp khi `--auto-low` (sau khi score đạt `AUTO_THRESHOLD_LOW`, `references/constants.md`)
Trước khi approve fix, dispatch `code-reviewer` agent (`model: opus` — rào thứ hai, không tiết kiệm ở đây) (hoặc Phase 3 analyzer tự judge với prompt dưới) với **fix plan + Phase-3 analysis + related files** làm input. Agent trả **pass/fail** cho câu hỏi:

> *"Plan này có **reasonable** (giải thích đúng root cause, không guess) + **low-risk** (scope hẹp — ≤ vài file đã biết; blast-radius giới hạn — không đụng Clean-Arch layer boundary / design-system token / shared composable toàn app; không gây regression rõ) không?"*

- **Pass** → fix (Phase 4) như bình thường.
- **Fail** → **defer** với reason `low-risk-check-failed` (ghi lý do fail từ agent vào ledger row + report). KHÔNG retry — defer là final cho ticket đó trong turn này (dev reply `@claude fix` trên Jira sẽ trigger Job E re-analyze).
- **Agent `blocked` / error** → defer `low-risk-check-blocked` (an toàn hơn là fix mù).

Gate này tồn tại vì `--auto-low` hạ threshold xuống `AUTO_THRESHOLD_LOW` — mất rào ngưỡng chính; LLM judge gate là rào thứ hai, chặn fix mù những bug thực sự nguy hiểm chỉ vì score tình cờ chạm `AUTO_THRESHOLD_LOW`.
- **Không reproduce được on-device** — CHỈ áp khi `[REPRO_ON]=true` (`bug-analysis-rules.md` `[REPRO]` A7a/A10) → **defer** (`unreproducible` hoặc `no-device`); **dưới `--auto` + `--repro` device là BẮT BUỘC, không có static fallback** — không có máy / không lấy được device lock trong thời gian chờ / chạy hết ladder vẫn không repro → defer + report. `--auto --repro` KHÔNG BAO GIỜ auto-fix một bug chưa reproduce được trên máy. **`[REPRO_ON]=false`: KHÔNG defer vì không có repro** — mặc định là bỏ qua bước này; chỉ ngưỡng `AUTO_THRESHOLD_DEFAULT` bù lại.
- **Không phải bug code thật** (config/console · backend · stale build/env/device · works-as-designed · duplicate — A1/A2) → route Fix-9 (non-code comment) / defer; không tự chế fix.
- **Score `sum < threshold`** → **defer + report** (mark `deferred`, không fix), ghi lý do `score <threshold (sum=N, [REPRO_ON]=<true|false>, [AUTO_LOW]=<true|false>)`.
- **Còn câu hỏi chưa rõ** (SOT có, nhưng không trả lời được câu hỏi của ticket) → **defer** (`clarify-gap`); auto KHÔNG tự đoán.
- **KHÔNG có source-of-truth cho cả phase** (ladder §2.0 trả NONE) → **chưa defer ngay** — xét từng ticket: analyzer phải ghi **nguồn của kết quả đúng** trong Fix plan (`Kết quả đúng lấy từ: …`):
  - `ticket` — mô tả/ảnh/video đã nói rõ trạng thái đúng (vd. "chữ không bị rơi lẻ dòng", "nghĩa đổi theo ngôn ngữ mẹ đẻ");
  - `tiền lệ code [File.kt:line](…)` — code đã có sẵn đúng thứ cần dùng cho cùng ý nghĩa ở chỗ khác (vd. AAP857-112 dùng `ic_tool_video` mà `TotalGenerationPopup` đã dùng cho credit video);
  - `chưa có` — bản sửa phải TỰ CHỌN một thiết kế mới mà ticket lẫn code đều không có (màu/icon/câu chữ/bố cục mới).
  Chỉ `chưa có` → **defer `no-sot`** (lý do RIÊNG, đừng gộp vào `clarify-gap`). `ticket` / `tiền lệ code` → chấm điểm và đi tiếp như có spec. Lý do: ở A/B 28/10, AAP857-112 và 113 bị hoãn `no-sot` trong khi dev sửa tay đúng như vậy, không cần spec, và QA đã Closed cả hai.
  - (Ghi chú cũ, vẫn đúng:) (ladder §2.0 (`references/helpers/source-of-truth-discovery.md`) trả NONE, hoặc FUZZY không qua ngưỡng auto-adopt) → **defer** (**`no-sot`**) — lý do RIÊNG, đừng gộp vào `clarify-gap`. Khác nhau ở chỗ: `clarify-gap` là *thiếu 1 câu trả lời cho 1 ticket*, `no-sot` là *cả phase không có ground truth* → nó tác động MỌI ticket của phase, và cách gỡ là ở cấp phase chứ không phải cấp ticket. **Report BẮT BUỘC kèm rung trace + cách gỡ:** đã đi qua rung nào, mỗi rung trả gì, rồi nêu đích danh remedy. **Trace PHẢI bao gồm cả 3 rung project-level (L2d sweep toàn project · L2e fixVersion+Epic của phase · L2f project description)** — nếu chưa chạy chúng thì chưa được kết luận `no-sot`. Remedy thường gặp: thêm/sửa `@N` (mở khoá L2e + xếp hạng L2d theo fixVersion), hoặc override bằng `--spec <url> --figma <url>`. **Ghi trống `no-spec` mà không có trace là VI PHẠM** — chính nó làm lỗi này vô hình suốt thời gian qua (xem SKILL.md `[AUTO]`).
- **Mid-fix phát hiện plan sai** → **defer** (`mid-fix wrong-plan`); không auto re-plan.
- **Trùng** `root_cause_slug` ticket khác → **skip** (mark `commented`, ghi ticket gốc); không "fix anyway".

## Khi defer — chuyển sang "Request" rồi ĐI TIẾP (không dừng loop)
Mỗi khi một ticket bị defer (score dưới ngưỡng / **behavioral-scope** / clarify-gap / **no-sot** / mid-fix wrong-plan / **unreproducible / no-device**), dưới `--auto`:
1. **Transition ticket → `Request`** (REST, `jira_transition`) — đưa nó RA KHỎI `In Progress` và trả về pool triage mở để người (hoặc một lần chạy sau có thêm thông tin) tiếp nhận. **Giữ assignee = dev account** (người đã claim) để biết ai đã phân tích. Verify `now=Request` qua readback. (Nếu workflow không có transition tên `Request`, dùng status mở gần nhất; nếu thực sự không thoát được `In Progress` thì để nguyên + ghi chú trong report.)
2. **Defer notification — Jira comment + Discord ping là MỘT BƯỚC ATOMIC, không được tách:**
   - **2.a (Jira, bắt buộc):** Post 1 comment `[VN]` ngắn lên ticket: lý do defer + tóm tắt plan đã có (để người sau làm tiếp), kèm link ledger slug. (`[REST]`, verify 201.)
   - **2.b (Discord, BẮT BUỘC khi `[DISCORD-DEFER]` opt-in bật):** Nếu `--discord-defer` present HOẶC env `JIRA_BUG_DISCORD_DEFER=1` → **PHẢI gọi** `references/discord/discord-notify-defer.md` NGAY SAU khi 2.a verify 201, trong cùng turn. Non-blocking về mặt **fail** (curl fail → log + đi tiếp), nhưng **KHÔNG non-blocking về mặt skip**: bỏ qua call này khi opt-in bật = **vi phạm spec**. Opt-in OFF (cả flag lẫn env đều không set) → skip hợp lệ. **Ghi thêm vào ledger row (v2a+): `discord_defer_enabled: true` + `discord_last_processed_message_id: 0`** để Job F (`discord-resolve-watcher.md`) biết ticket này eligible cho resolve post khi PR open.
   - **Khi delegate defer sang sub-agent (defer-handler):** prompt của sub-agent PHẢI liệt kê CẢ 2.a và 2.b — không được tóm tắt thành "post VN comment" rồi drop 2.b. Checklist bắt buộc trong sub-agent prompt: `[ ] 2.a Jira comment 201` + `[ ] 2.b Discord ping (nếu opt-in bật)`. Sub-agent báo cáo lại trạng thái từng cái.
3. Ghi ledger: `bash <skill-dir>/assets/ledger.sh upsert <PROJ> <PHASE> <TICKET> status=analyzed-deferred reason=<lý do>` (giữ root_cause_slug + summary + files đã ghi ở Phase 3) + thêm vào end-of-run report.
4. **ĐI TIẾP NGAY sang ticket/batch kế** — **defer KHÔNG BAO GIỜ là điều kiện dừng loop.** Loop chỉ dừng khi re-pull trả về 0 ticket (board rỗng) hoặc gặp `[AUTO-GATE]` do dev định nghĩa. **Vì `Request` NẰM TRONG pool pull, chống re-pick KHÔNG dựa vào status mà dựa vào DEDUP:** `.jira-bug/batch-progress.md` (cùng session) + ledger row `analyzed-deferred` (cross-session). `auto-ticket-pick.md` BỎ QUA mọi ticket đã `analyzed-deferred`. **Resume ticket deferred được xử lý CHỦ ĐỘNG bởi Job E** (`references/phase-manager-mode.md` → "Job E — Deferred-ticket comment watcher") — khi dev reply trên Jira với marker `@claude`/`@agent`, Job E xoá ledger row + re-analyze với comment làm clarify.

### Ledger row schema

Ledger row `analyzed-deferred` có các field sau (ví dụ):
```
TICKET: APDF1-2251
status: analyzed-deferred
date: 2026-10-15T10:30:00Z
reason: no-sot                  # score-lt-threshold | behavioral-scope | clarify-gap | no-sot | mid-fix-wrong-plan | unreproducible | no-device | low-risk-check-failed | low-risk-check-blocked
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
Cùng tiêu chí cho 1 ticket: `sum ≥ threshold` → fix; `<threshold` / clarify-gap → defer + report. Threshold matrix: `--auto-low` → `AUTO_THRESHOLD_LOW` (+ `[LOW-RISK-GATE]`); else `[REPRO_ON]=true` → `AUTO_THRESHOLD_REPRO`; else → `AUTO_THRESHOLD_DEFAULT` (`references/constants.md`). Phạm vi `AUTO_SCOPE` áp dụng như trên. Defer cũng PARK sang `Request` như trên (single thì park xong là kết thúc, không có batch kế).
