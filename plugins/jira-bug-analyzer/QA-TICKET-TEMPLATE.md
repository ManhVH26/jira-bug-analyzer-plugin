# Mẫu ticket bug cho QA (không bắt buộc)

Ghi được mục nào thì ghi mục đó. Ticket thiếu mục, viết lộn xộn hay chỉ có một ảnh thì plugin vẫn sửa như bình
thường; ghi càng đủ thì plugin tái hiện và sửa càng nhanh, càng đúng phạm vi. Không cần đúng thứ tự, không cần
in đậm; tiêu đề tiếng Việt hoặc tiếng Anh đều được.

```
Spec: <link Confluence, nếu có>
Figma: <link trang Figma là đủ; link đúng frame thì càng tốt>
Build: <bản build / version>
Thiết bị: <máy, Android mấy>
Trạng thái: <cần có gì trước: tài khoản, gói Premium, đã lưu từ, bài đang khoá…>
Mô tả bug: <thấy gì sai, một hai câu>
Tái hiện bug:
- Bước 1: <màn nào → bấm gì>
- Bước 2: …
Tần suất: <luôn luôn | thỉnh thoảng>
Thực tế: <ảnh / video>
Expect sau khi fix: <nói bằng lời thường là được>
```

## Ghi rõ màn / nguồn cụ thể

Trong bước tái hiện, ghi **đúng màn hoặc nguồn** nơi thao tác, không ghi chung chung. Một chữ là đủ.

| Nên ghi | Thay vì |
|---|---|
| vào **bài học video** và lưu 1 từ | vào một bài học và lưu 1 từ |
| tab **Phần thưởng** → Nhiệm vụ hằng ngày | vào phần nhiệm vụ |
| bấm **bài đang khoá** ở tab Bài học | mở bài học |

Vì sao: app thường có nhiều chỗ làm cùng một việc (ví dụ lưu từ từ roleplay, free talk, video, lỗi phát âm).
Không biết chỗ nào, plugin phải coi cả mọi chỗ là lỗi, bản sửa thành lớn, và chế độ tự động sẽ hoãn ticket thay
vì sửa (đã gặp ở AIP396-475: bước ghi "một bài học", trong khi bug chỉ ở bài học video).

## Expect: lời thường là được

Không cần viết kiểu "3 tab cách đều 16dp". Ví dụ "nghĩa của từ hiện theo ngôn ngữ app đang chọn" là đủ — plugin
tự đối chiếu với spec / Figma, và nếu Expect khác spec thì làm theo spec rồi ghi rõ trong comment cho QA.

## Sau khi sửa

Comment của plugin có dòng **"Ticket QA viết → plugin hiểu"**: mục nào lấy theo QA, mục nào plugin tự suy ra
(đánh dấu "suy ra"). Nếu thiếu mục, dòng **"Ticket thiếu"** nhắc mục nào lần sau nên ghi thêm.
