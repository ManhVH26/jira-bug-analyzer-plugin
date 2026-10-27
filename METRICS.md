# Chỉ số đánh giá — v1.15.2 → v1.15.3

Mỗi phase có chỉ số đo được, mốc baseline (v1.15.2, đo ngày 27/10/2026) và mục tiêu. Có hai loại:

- **Chỉ số tĩnh**: đo trên code, chạy `python3 scripts/metrics.py` (CI chạy mỗi PR). Đã đạt hết trừ S0.
- **Chỉ số khi chạy thật**: chỉ có sau khi fix bug thật. Đo bằng các script bên dưới, so với baseline.

## 1. Chỉ số tĩnh (`python3 scripts/metrics.py`)

| Phase | Chỉ số | v1.15.2 | v1.15.3 | Mục tiêu |
|---|---|---|---|---|
| P1 | Số chỗ chép ngưỡng `--auto` ngoài `constants.md` | 12 | 0 | 0 |
| P2 | Số file viết cứng `assembleAppDevDebug` | 9 | 0 | 0 |
| P3 | Lỗi lint | 27 | 0 | 0 |
| P3 | Có CI / số test tự động | không / 0 | có / 15 | có / ≥ 15 |
| P4 | `SKILL.md` (nạp mọi lần gọi) | 47 464 byte | 12 388 byte | ≤ 20 000 |
| P4 | Mô tả skill (nạp vào MỌI session, kể cả không dùng skill) | 1 177 ký tự | 397 | ≤ 400 |
| P5 | `golden-rules.md` | 34 666 byte | 27 456 byte | < baseline |
| P7 | `Agent(...)` không ghi model | 4 | 0 | 0 |
| P7 | Phiên chính ghim model | không | `sonnet` | có |
| S5 | Script không có strict mode và không ghi lý do | 8 | 0 | 0 |
| S0 | Phát hiện bảo mật của lint (đã báo riêng chủ repo) | 2 | 2 | 0 (**tạm hoãn**) |

## 2. Chỉ số khi chạy thật (đo sau khi fix bug thật)

| Phase | Chỉ số | Baseline (v1.15.2) | Mục tiêu | Cách đo |
|---|---|---|---|---|
| **R** | Tỉ lệ reopen của ticket `--auto` tự sửa (theo lịch sử trạng thái) | AAP729 **30,1 %** (25/83) | ≤ tỉ lệ của bug không-auto cùng project | `scripts/reopen_report.py --project <KEY> --since <ngày cài v1.15.3>` |
| R | Tỉ lệ reopen của bug không-auto (đối chứng) | AAP729 16 % (8/50) | — (thước đo so sánh) | cùng lệnh, dòng `baseline` |
| R2 | Ticket từng bị hoãn mà vẫn được tự sửa | 8 (8 bị reopen) | **0** | dòng `deferred before, fixed` |
| R3/R5 | Bug hành vi được `--auto` tự sửa | chưa đo | **0** (khi `AUTO_SCOPE=ui-only`) | ledger: lý do hoãn `behavioral-scope` / `no-device` |
| R1 | Số reopen mà nhãn bỏ sót | 12/31 | **0** | dòng `reopens the label missed` |
| R6 | Reopen có lý do (khác `unknown`) | 0 % | ≥ 80 % | ledger `reopen_reason`; dòng `reasons:` của Job D |
| R7 | Mốc đánh giá | — | sau ≥ 50 ticket auto mới | Job D in dòng `R7: …` |
| P7 | Token mỗi phiên, chia theo model | chưa đo (máy này chưa chạy skill) | giảm ≥ 30 % ở model `opus` | `scripts/token_report.py --since <ngày>` trên máy dev chạy skill, trước và sau |
| P7 | Tỉ lệ lượt manager dừng ở precheck | 0 % (chưa có precheck) | ≥ 70 % trên board yên | đếm dòng `manager: no change` trong log manager |
| P2 | App không có flavor `appDev` build được | lỗi ở Phase 4 | build sau đúng 1 câu hỏi, lần sau không hỏi | chạy single mode trên app đó |
| S1 | Comment `@claude` từ người ngoài danh sách được xử lý | có thể | **0** | dòng `job-e: ignored @claude …` |

Lưu ý thống kê: chênh lệch 30 % so với 16 % ở baseline có p ≈ 0,07 (mẫu nhỏ). `reopen_report.py` in p-value; chỉ kết luận "đã cải thiện" khi có ≥ 50 ticket auto mới.

## 3. Quy trình đánh giá sau khi fix bug thật

1. Ghi lại **ngày cài v1.15.3** (`--since`).
2. Chạy lô bug thật như bình thường (single / multi / `--auto`), rồi `--manager` để Job D theo dõi reopen.
3. Sau mỗi tuần, hoặc khi đủ 50 ticket auto mới:
   ```bash
   JIRA_PERSONAL_TOKEN=... python3 scripts/reopen_report.py --project AAP729 --since 2026-10-28
   python3 scripts/token_report.py --since 2026-10-28      # trên máy đã chạy skill
   ```
4. So với bảng mục 2. Đạt mục tiêu R thì mới cân nhắc `autoScope: "all"` cho project đó.
5. Các kịch bản hành vi cần kiểm bằng tay trước khi tin vào số liệu: `tests/SCENARIOS.md`.
