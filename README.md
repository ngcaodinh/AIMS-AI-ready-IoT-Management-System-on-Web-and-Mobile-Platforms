# AIMS-AI-ready-IoT-Management-System-on-Web-and-Mobile-Platforms
Xây dựng hệ thống quản lý thiết bị IoT trên Web và ứng dụng di động, có tích hợp trí tuệ nhân tạo (AIMS)

## Cấu trúc dự án

- `backend/`: backend Rust theo kiến trúc modular monolith; mã nguồn dự kiến đặt trong `crates/`, migration PostgreSQL trong `migrations/` và kiểm thử tích hợp trong `tests/`.
- `web/`: ứng dụng web React + TypeScript, dùng Tailwind CSS 4 để tạo giao diện. CSS riêng trong `src/styles.css` bổ sung theme và các hiệu ứng cho giao diện.
- `mobile/`: ứng dụng di động.
- `firmware/`: firmware cho thiết bị IoT.
- `contracts/`: hợp đồng HTTP/WebSocket dùng chung giữa các client và backend.
- `ops/`: cấu hình và tài liệu vận hành.
- `simulator/`: công cụ mô phỏng thiết bị.
- `docs/`: tài liệu phân tích, thiết kế và giao diện.

## Database PostgreSQL dùng chung

Toàn dự án dùng **một database `iot_platform_lab`** trên PostgreSQL **17.11**, trong container `iot-postgres17-database`. Web, Android, worker và các module backend dùng cùng database; workspace được cô lập bằng khóa và quyền, không tạo DB riêng cho từng module.

- [SQL tổng hợp đầy đủ](backend/migrations/platform.sql): dựng toàn schema và ledger, chạy lại kiểm checksum.
- [Hướng dẫn database](backend/migrations/platform/README.md): cách áp, kiểm và giới hạn vận hành.
- [Schema thực tế và ràng buộc](backend/migrations/platform/manifest.json), [báo cáo kiểm chứng](docs/test-reports/database-platform-2026-10-23.md).
- [Schema có chú thích từng bảng/cột](backend/migrations/platform/schema.sql), [report mới nhất](docs/test-reports/database-template-2026-10-24.md):151 engine checks,35 Python unit và51 Rust tests đạt;18 migration gồm audit retention, outbox clock fence và hai thuộc tính channel_kind/direction.
- [Kết nối DBeaver](ops/database/DBEAVER.md), [mẫu cấu hình duy nhất](backend/.env.example) và [đối chiếu đủ31 task](docs/plan/database/full-plan-status.md). [Runtime Clean Architecture](backend/ARCHITECTURE.md) đã có81 repository checks; các module còn lại, thiết bị, tải và production recovery giữ acceptance riêng.

```powershell
python -B ops/database/verify_platform.py apply
python -B ops/database/verify_platform.py verify
docker exec -it iot-postgres17-database psql -X -h /tmp -U iot_migrator -d iot_platform_lab
```

Lệnh trên thao tác PostgreSQL thật qua Docker; chạy với quyền truy cập Docker ngoài sandbox. `verify` chỉ dành cho DB chưa có dữ liệu ứng dụng: SQL fixture/dựng sạch/restore rollback trên cùng DB; fixture concurrency có identity riêng và được cleanup sau kiểm. Không sinh DB test mới. `iot_database_lab` cùng các DB restore cũ thuộc lịch sử thử nghiệm, không là database của ứng dụng và không bị tự xóa.
