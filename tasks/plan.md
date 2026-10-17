# Kế hoạch khởi tạo nền tảng IoT

## Phạm vi đã hiểu

Khởi tạo bộ khung repository cho nền tảng IoT theo đặc tả bàn giao: Rust backend, React + TypeScript web, Flutter mobile Android, firmware C++ ESP-IDF, contracts, simulator, vận hành và tài liệu. iOS không nằm trong phạm vi triển khai hiện tại theo ADR-001 và bản cập nhật BA/handoff ngày 16/10/2026. Công việc này chỉ tạo cấu trúc và các chuẩn khởi đầu; không cài dependency, không tạo secret, không tạo dịch vụ chạy nền, và không tự chọn phiên bản SDK hoặc phần cứng chưa được quyết định.

## Quyết định kiến trúc giữ nguyên

- Giữ modular monolith Rust; không thêm microservice, Redis, Kafka hoặc dependency mới.
- Mọi contract dùng làm nguồn chung cho Web, mobile, backend và firmware; khi thay đổi phải có compatibility note và fixture.
- Môi trường chỉ dùng mẫu cấu hình không chứa giá trị bí mật. Credentials, khoá ký OTA, TLS, Wi-Fi và PoP không được tạo hay lưu trong repository.
- Chỉ pin toolchain sau PoC tương thích Rust/Flutter/ESP-IDF, BLE, OTA và iOS theo DEV-OQ-05.

## Kế hoạch công việc

### Pha 1 — Khung repository

#### Task 1: Tạo các thư mục cấp cao theo cây bàn giao

**Mục tiêu:** Tạo `backend/`, `web/`, `mobile/`, `firmware/`, `contracts/`, `simulator/`, `ops/`, cùng các nhánh tài liệu và kiểm thử cần thiết.

**Tiêu chí chấp nhận:**

- [x] Cây thư mục khớp phạm vi của đặc tả bàn giao.
- [x] Không có source code giả, dependency hoặc secret.
- [x] Mỗi vùng có README nêu trách nhiệm và ranh giới.

**Phụ thuộc:** Không.

**Bằng chứng hoàn thành:** Kiểm tra cây thư mục và nội dung README.

#### Task 2: Đặt chuẩn mô hình và contract chung

**Mục tiêu:** Tạo nơi lưu OpenAPI, schema thiết bị/dashboard/rule và shared fixtures; ghi quy tắc version, compatibility và workspace scope.

**Tiêu chí chấp nhận:**

- [x] Contract là điểm dùng chung duy nhất giữa bốn client/runtime.
- [x] Có quy ước version, fixture và compatibility note.
- [x] Không định nghĩa API/DTO mới ngoài tài liệu nguồn.

**Phụ thuộc:** Task 1.

**Bằng chứng hoàn thành:** Kiểm tra README chuẩn contract và các thư mục placeholder có chủ đích.

### Checkpoint: Foundation

- [ ] Không có secret hoặc dependency không được phê duyệt.
- [ ] Cấu trúc truy vết được tới cây bàn giao trong BA và handoff spec.

### Pha 2 — Hồ sơ môi trường và toolchain

#### Task 3: Tạo tài liệu môi trường không chứa secret

**Mục tiêu:** Tạo hồ sơ cho local/lab/CI với tên biến cấu hình, ownership, cách cấp secret ngoài repository và điều kiện lab hardware.

**Tiêu chí chấp nhận:**

- [x] Không lưu giá trị credential hoặc private key.
- [x] Phân tách rõ local, lab và CI; nêu TLS/MQTTS, PostgreSQL và Mosquitto là phụ thuộc vận hành.
- [x] Liệt kê các quyết định DEV-OQ còn cần chủ dự án xác nhận.

**Phụ thuộc:** Task 1.

**Bằng chứng hoàn thành:** Rà soát không có giá trị secret và đối chiếu DEV-OQ-02 đến DEV-OQ-08.

#### Task 4: Lập manifest pin phiên bản chờ PoC

**Mục tiêu:** Tạo decision record để chốt Rust, Node, Flutter, ESP-IDF, PostgreSQL và Mosquitto sau PoC thay vì dùng `latest`.

**Tiêu chí chấp nhận:**

- [x] Mỗi thành phần có chủ sở hữu, tiêu chí PoC và lockfile/config lock tương ứng.
- [x] Không ghi phiên bản bịa đặt hoặc tự động cập nhật latest.
- [x] Nêu điều kiện iOS, BLE và OTA trước khi khoá phiên bản.

**Phụ thuộc:** Task 3.

**Bằng chứng hoàn thành:** Decision record đầy đủ các trường quyết định và trạng thái chưa chốt.

### Checkpoint: Ready for implementation

- [ ] Chủ dự án xác nhận board/sensor, Firebase cho Android, domain/TLS và chủ sở hữu khoá OTA.
- [ ] PoC xác nhận toolchain trước khi sinh project framework hoặc cài dependency.

## Rủi ro và hướng xử lý

| Rủi ro | Ảnh hưởng | Hướng xử lý |
| --- | --- | --- |
| Pin SDK trước PoC | Không tương thích BLE/OTA/iOS | Chỉ lập manifest quyết định, chờ PoC. |
| Lưu cấu hình bí mật trong repo | Rò rỉ credential | Chỉ nêu tên biến và cách cấp ngoài repo. |
| Chọn board không đủ dual OTA | Chặn M5/G5 | Chốt model/flash/sensor trước firmware scaffold. |

## Câu hỏi cần xác nhận

1. Bạn muốn mình chỉ dựng scaffold tài liệu/thư mục an toàn trước, hay đồng thời khởi tạo các project khung Rust, React, Flutter và ESP-IDF sau khi toolchain được chốt?
2. Ai sẽ cung cấp/chốt DEV-OQ-02 đến DEV-OQ-08, đặc biệt board ESP32, macOS/iPhone signing và toolchain versions?
