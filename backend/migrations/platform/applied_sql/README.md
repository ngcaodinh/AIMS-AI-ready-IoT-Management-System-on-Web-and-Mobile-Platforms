# SQL đã áp: bất biến theo checksum

Các file ở đây giữ đúng byte đã áp của migration 0001–0006. File cùng tên ở thư mục cha là bản có comment chi tiết để đọc trong IDE.

Runner luôn kiểm hai bản có cùng token SQL (bỏ comment/khoảng trắng, giữ literal và dollar-body), rồi thực thi bản ở đây bằng SHA-256 gốc. Thay đổi logic phải thêm forward migration. Không sửa archive hoặc cập nhật checksum trong ledger để hợp thức hóa drift.

Không chạy cả hai bản hoặc tự glob đệ quy thư mục migration; dùng `verify_platform.py` hay bundle `platform.sql` để giữ thứ tự và target guard.
