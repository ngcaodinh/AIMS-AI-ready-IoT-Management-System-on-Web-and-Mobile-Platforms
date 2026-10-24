# DBeaver Community 26.2.0 — DB canonical

Kết nối đã tạo: **IoT Platform - Local Reader**, tới duy nhất `iot_platform_lab`. Server đã xác nhận các phiên JDBC DBeaver thật; [evidence](evidence/dbeaver-local.json) có tên ứng dụng, role/database và kết quả kiểm quyền, không có credential.

| Trường | Giá trị |
| --- | --- |
| Driver | PostgreSQL |
| Host | `127.0.0.1` |
| Port | `15432` |
| Database | `iot_platform_lab` |
| Username | `iot_dbeaver_reader` |
| Password | Mật khẩu local bạn đã chọn, nhập trực tiếp vào DBeaver; không ghi vào tài liệu/mẫu |
| Authentication | SCRAM-SHA-256 thật từ PostgreSQL |
| SSL mode | `disable` cho endpoint loopback này |

Role chỉ đọc các cột được cấp; password/verifier/token/proof/ciphertext/raw webhook body không được SELECT. Metadata bảng/cột vẫn xem được. `SELECT *` trên bảng có cột bị bảo vệ có thể bị từ chối; dùng [dbeaver-check.sql](dbeaver-check.sql) để xem công dụng từng cột qua catalog. Không có quyền DML/DDL trên schema nghiệp vụ, gọi worker hoặc SET ROLE owner. Quyền này không phải writer của backend ứng dụng.

## Khởi động lại

Docker Desktop và container `iot-postgres17-database` phải đang chạy. Bridge dùng Python stdlib và Perl đã có sẵn trong image, relay protocol nhị phân qua docker-exec tới Unix socket. Container giữ network none, không publish cổng; chỉ endpoint Windows loopback mở cho đúng role/database. TLS negotiation bị từ chối rõ ràng, không giả thành công. Query/lock timeout là 30s/5s. CancelRequest riêng chưa hỗ trợ; đóng kết nối hoặc chờ statement timeout.

```powershell
python -B ops/database/local_db_bridge.py serve
```

Bridge đang được chạy nền ẩn trong lượt thiết lập. Sau khi dừng/reboot Windows phải khởi động lại lệnh trên; không tự đăng ký service/task hệ thống. Nếu port đang bận, không chạy thêm bridge hoặc tự kill tiến trình không rõ nguồn gốc.

Đặt/đổi password bằng nhập kín, không đưa secret vào command line:

```powershell
python -B ops/database/local_db_bridge.py set-password
python -B ops/database/verify_local_connection.py
```

Password verifier lưu ở PostgreSQL bằng SCRAM. HBA chỉ thêm `local iot_platform_lab iot_dbeaver_reader scram-sha-256` trước local trust cũ; migrator/owner vẫn dùng đường nội bộ cũ. Reload không restart DB. Thay password không tự ngắt session đã xác thực; reconnect DBeaver rồi nhập password hiện hành khi cần.

## Mẫu cấu hình

Chỉ giữ [backend/.env.example](../../backend/.env.example). Hai file mẫu ở root đã xóa theo yêu cầu. Bạn tự tạo `backend/.env` và thay hai placeholder mật khẩu; công cụ không đọc/ghi env thật. Mẫu ghi đúng endpoint inspection hiện có, không giả backend runtime writer đã được triển khai. Không đưa `.env` thật vào Git.

## Quyền vận hành và restore

`setup` tạo role đã định danh và policy từ SQL trong `backend/migrations/lab/`; quyền này đã được người dùng cấp trong phiên. `verify_platform.py` chỉ tái dựng policy khi role có đúng provenance và không có đặc quyền/membership lạ. Clean/restore kiểm cả column/view ACL để không mất chính sách bảo vệ cột.

Nếu dựng lại container/cluster, role/HBA/password cần provision lại bởi người vận hành. Artifact schema không chứa password hoặc role verifier. Không dùng read-only DBeaver connection để chạy migration; dùng runner Unix socket theo [runbook canonical](../../backend/migrations/platform/README.md).

Tham chiếu giao diện và CLI: [DBeaver PostgreSQL](https://dbeaver.com/docs/dbeaver/Database-driver-PostgreSQL/), [DBeaver command line](https://dbeaver.com/docs/dbeaver/Command-Line/). Lệnh CLI đã dùng chỉ mang host/port/role/database, không truyền password trong argv.
