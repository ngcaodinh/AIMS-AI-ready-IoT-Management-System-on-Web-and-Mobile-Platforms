# FEAT001 — dependency và kế hoạch runtime Web/backend

## Cập nhật hiện hành 2026-10-24

GNU Rust1.99.1 hiện chạy được64 workspace tests, fmt và clippy `-D warnings`.
Axum0.8.6 và dev-only Tower0.5.2 đã được pin/tải qua Cargo registry và lockfile;
HTTP adapter/auth-lab đã build. Không dùng đề nghị `subtle` hoặc migrate feature
khi code hiện tại không cần. DB đích của launcher là canonical
`iot_platform_lab`, không tạo DB mới. Chạy provider bị auto-review từ chối vì
role grants/fixture trên DB chung; chờ phê duyệt cụ thể, chưa có provider PASS.
Topology lab localhost5173→loopback3000 là cấu hình hiện thực, chưa là browser
evidence. [Handoff](../../docs/test-reports/FEAT-TN-001-runtime-handoff-2026-10-24.md)
ghi trạng thái hiện tại. Các đoạn thiếu GNU/linker/Docker bên dưới là nhật ký
lịch sử 2026-10-23, không phải inventory hiện hành.

## Đề xuất và nhật ký lịch sử 2026-10-23

Ngày: 2026-10-23. Theo chỉ đạo tiếp tục code FE/BE để chạy luồng thật.
Không coi chỉ đạo này là evidence owner review CP-01 hoặc nghiệm thu G1.

Dependency đề nghị cho backend Rust edition2024, toolchain thực có1.99.1:
`axum=0.8.6`, `tokio=1.48.0`, `sqlx=0.8.6` (PostgreSQL, runtime-tokio-rustls,
uuid, chrono, migrate), `serde=1.0.228`, `serde_json=1.0.145`, `uuid=1.18.1`,
`chrono=0.4.42`, `argon2=0.5.3`, `rand=0.8.5`, `sha2=0.10.9`, `hmac=0.12.1`,
`subtle=2.6.1`; dev-only `tower=0.5.2` cho request tests. Pin chính xác trong
manifest và sinh Cargo.lock sau khi được phép tải dependency. Web giữ React19.2,
TypeScript5.9.3/Vite7.3.7 hiện có, không thêm package.

Phạm vi DB đề nghị: PostgreSQL17 trong lab cô lập, chỉ bind loopback; image
digest xác nhận khi kéo image. Không kết nối DB hiện hữu bằng credential đoán.
Docker client có sẵn nhưng daemon chưa chạy trong lần kiểm tra hiện tại.
Không đọc environment hoặc secret file để tìm connection string.
`rustc --version`:1.99.1, `cargo --version`:1.99.1; target đã cài chỉ có
`x86_64-pc-windows-msvc`. Compile test thuần Rust thất bại vì thiếu `link.exe`;
`gcc.exe` có sẵn nhưng GNU Rust target chưa cài. Cần MSVC C++ Build Tools hoặc
GNU target tương thích đã kiểm chứng; chưa cài toolchain bổ sung và chưa claim
test Rust PASS. `--emit=metadata` chỉ xác nhận type-check, không chạy test.

## Các lát cắt, theo thứ tự

| Task | AC / evidence | File dự kiến (tối đa năm) / dependency |
| --- | --- | --- |
| R1 | Schema additive users/sessions/memberships/limiter/audit; hashing bounded, error envelope và strict JSON input; cargo test. | `backend/Cargo.toml`, `backend/src/lib.rs`, `backend/src/error.rs`, `backend/src/input.rs`, `backend/migrations/0001_auth.sql`; cần dependency được duyệt. |
| R2 | Login thật: Argon2id, 5 failures/15m shared DB lock, User fence, session+audit transaction; full/limited và cookie/context; provider tests. | `backend/src/auth.rs`, `backend/src/security.rs`, `backend/src/lib.rs`, `backend/tests/auth_flow.rs`; R1 + DB lab. |
| CP-R2 (partial) | Review login guard/CSRF/context và rate-limit; chưa đủ CP-02 vì /me/logout/password còn ở R3. | Contract0.2.1 và log provider. |
| R3 | /me/workspaces/detail có quyền hiện hành và cursor bound; logout/password để hoàn tất limited/recovery; seed synthetic tách khỏi server. | `backend/src/workspace.rs`, `backend/src/session.rs`, `backend/src/main.rs`, `backend/src/seed.rs`, `backend/src/lib.rs`; R2. |
| CP-02 | Sau R3: password/disable race, commit ACK UNKNOWN, audit failure không rollback limiter; sáu request trên hai instance; đo hash/queue/pool/lock và không leak secret. | R1–R3 + DB; đây mới là gate mở tích hợp client, không thay bằng CP-R2 partial. |
| R4a | Web API parser, auth coordinator, unit tests negative và recovery. | `web/src/features/auth/api.ts`, `web/src/features/auth/coordinator.ts`, `web/tests/auth.test.mjs`, `web/package.json`; có thể viết/test với mock ghi rõ trước provider; chưa là evidence E2E. |
| R4b | UI login/picker/limited/empty/error có label/focus; dùng API thật, không gắn mock vào ứng dụng. | `web/src/features/auth/AuthPage.tsx`, `web/src/features/auth/auth.css`, `web/src/main.tsx`; R4a; tích hợp sau CP-02. |
| R5 | Entry đăng nhập và Vite same-origin proxy; integration/browser thật, tester runbook và trạng thái. | `web/src/SiteHeader.tsx`, `web/vite.config.ts`, `backend/README.md`, feature001 và implementation-progress; R3/R4. |

Web Locks `nexa-auth-mutation` tuần tự hóa login/logout/password/accept/resets
giữa các tab; marker không phải mutex. Khi thiếu Web Locks hoặc storage lỗi,
fail closed. Browser tự nhả lock khi tab đóng; intent pending vẫn cần discovery
và xác nhận chủ động. Callback cũ phải qua intent/generation fence; server context
fence vẫn bắt cookie muộn ngoài khả năng kiểm soát của JavaScript.

Interface cấu hình dự kiến: host/port/public origin không secret qua CLI; dữ
liệu kết nối có secret nhận qua stdin của launcher hoặc secret manager đã được
duyệt, không qua argv/log/repository. Lab mới dùng DB riêng và synthetic data;
không tìm hoặc đoán credential của DB đang có. Key ký cursor/limiter/CSRF
được sinh CSPRNG một lần và giữ trong bảng auth_settings của DB được bảo vệ;
backup/quyền đọc phải giữ cùng boundary với session store, không export vào
evidence. Chưa provision hoặc đọc key/credential thật trong lượt này.

Production vẫn yêu cầu HTTPS public origin, Secure/HttpOnly/SameSite=Lax,
Path=/api/v1, không Domain, không CORS wildcard. Local lab có tùy chọn riêng
chỉ cho `http://localhost` với listener loopback; giữ nguyên Secure cookie,
dùng ngoại lệ localhost của browser. Origin lab khóa chính xác
`http://localhost:5173`; Vite strictPort, giữ Host/Origin tới API loopback.
Không tin X-Forwarded-* từ client. Thiếu Origin vẫn phải có HTTPS Referer
theo contract; HTTP lab không nới điều kiện fallback đó. Không bật tùy chọn này cho public origin.
Password/token không vào URL, log hoặc localStorage; marker chỉ gồm intent,
phase và context UUID không secret. Không thêm Redis/Kafka hoặc framework mới.

Rollback: dừng bản auth mới; giữ migration additive và dữ liệu. Không rollback
bằng cách bỏ guard/CSRF/context/limiter hoặc chuyển token sang plaintext.
Các thay đổi P1 và logout002 đang có được giữ lại; toàn feature chỉ READY_FOR_QA
sau kiểm runtime, CP-01/G1 và nghiệm thu độc lập vẫn cần evidence riêng.

Nguồn API đối chiếu: [Axum0.8.6](https://docs.rs/axum/0.8.6/axum/),
[SQLx0.8.6](https://docs.rs/sqlx/0.8.6/sqlx/),
[Argon2id0.5.3](https://docs.rs/argon2/0.5.3/argon2/),
[Vite server proxy](https://vite.dev/config/server-options.html#server-proxy),
[MDN Set-Cookie](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Set-Cookie).
