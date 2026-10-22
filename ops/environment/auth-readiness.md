# FEAT-TN-001 — manifest sẵn sàng auth không chứa secret

Trạng thái: MISSING_INPUT. Bản ghi này phân biệt giả định thiết kế ADR-002 với môi trường đã chứng minh. Không có runtime auth để đo hoặc chạy provider/client test.

| Hạng mục | Điều đã xác minh trong repository | Còn phải chứng minh trước BUILD tương ứng |
| --- | --- | --- |
| API/Web origin | web/ có trang giới thiệu React chạy bằng Vite; backend/ mới có README/placeholder. Chưa có cấu hình reverse proxy hoặc ứng dụng auth chạy. | HTTPS same-origin thực tế; danh sách trusted proxy; Origin/Referer/Fetch Metadata và cookie Path qua browser thật. Khác giả định OQ-AUTH-002 thì sửa contract/plan trước Web BUILD. |
| Backend/toolchain | ops/toolchains/decision-record.md ghi Rust/PostgreSQL PoC pending; chưa có Rust workspace hoặc PostgreSQL migration. | Pin toolchain, DB image/driver và schema User/Session/limiter/audit sau PoC; chạy migration/isolation/restore. |
| Password/token | Plan yêu cầu protected password hash, dummy verify, token random và digest-only storage; chưa có dependency/benchmark được chứng minh. | Chọn dependency đã duyệt, đo cost/password hash worker, queue, pool/lock timeout, entropy/digest strategy; kiểm email canonical collision trên dữ liệu thật trước migration. |
| Limiter/audit | Contract cố định năm failure/15 phút và session+audit success atomic; chưa có DB implementation. | Sáu request sai đồng thời trên nhiều instance: năm 401, một 429; đo giữ khóa/pool/hasher, fault injection audit/commit unknown và quét redaction. |
| Web browser | web/ có manifest, lockfile và cấu hình Vite cho trang giới thiệu; chưa có Web login hoặc bằng chứng kiểm thử browser cho auth. | Xác nhận dependency sau PoC; kiểm Chrome/Edge/Firefox stable với cookie, CSRF, reload limited, lost response, focus/keyboard và responsive. Ghi version thực tế khi chạy. |
| Android | Chưa có pubspec.yaml, Android manifest, secure-storage plugin hoặc emulator/thiết bị được xác nhận. | PoC plugin đã duyệt, min OS, backup/key failure, restart/account switch trên emulator và một thiết bị thật được hỗ trợ. Không tự đoán API level. |
| Provider/client G1 | OpenAPI/fixture 0.1.0 có static check, không có implementation. | API/Web/Mobile owner review; producer/consumer compatibility test cùng fixture, kiểm header/error/limited/workspace scope trước CP-01/G1 PASS. |

Kế hoạch đo G1 security: pin môi trường local/lab không secret và clock UTC; chạy sáu login sai cùng normalized email từ hai backend instance; ghi status/Retry-After, p50/p95 giữ khóa, hash duration, pool wait/timeout và số audit outcome đã redaction. Inject lỗi DB/audit trước commit và mất ACK sau commit; quan sát không phát credential khi chưa có commit xác nhận. Không đặt ngưỡng tùy tiện trước baseline; owner chốt budget theo số đo và NFR của handoff. Chưa chạy ca nào trong bảng này.
