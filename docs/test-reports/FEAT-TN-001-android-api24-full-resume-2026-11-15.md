# FEAT-TN-001 Android API 24 full session rerun — 15/11/2026

**PASS_SCOPED_NATIVE_FULL_SESSION_AND_PRESELECTION_ORACLE / READY_FOR_QA cho main Android login, picker boundary, cold resume và logout. Toàn feature vẫn VERIFY_IN_PROGRESS.**

## Môi trường và lệnh

- Branch `dev`, HEAD `ba425ad9e5576ed3261f6df5b4a4731c96d98850`; worktree còn dirty/untracked từ trước lượt này. Không sửa production source/UI trong lượt kiểm; test harness được cập nhật riêng như nêu ở phần môi trường.
- AVD `Nexa_Auth_API24`, `emulator-5554`, Android API 24 x86_64; Flutter 3.47.5, Dart 3.13.4 stable.
- PostgreSQL canonical qua auth-lab fixture có ownership; App main debug đi qua HTTPS local proxy, không dùng preview/mock hoặc thiết bị vật lý.
- Lệnh thực chạy: `node ops/auth/run_native_e2e.mjs --full-session` (tiến trình nhận `ANDROID_AVD_HOME=C:\Users\LENOVO\.android\avd`). Lượt đầu trước khi thêm oracle exit0; lượt có oracle exit0.
- Test harness cập nhật: `ops/auth/run_native_e2e.mjs`, `ops/auth/test_native_e2e_protocol.mjs`, `mobile/integration_test/app_auth_e2e_test.dart`. Production source/UI không đổi.
- Lượt thử đầu trong sandbox kết thúc tại fixture vì Docker API bị từ chối. Kiểm tra khi đó không có listener backend/proxy hoặc journal mới. Cùng lệnh sau đó chạy ngoài sandbox và hoàn tất.

## Kết quả thực tế

- `NATIVE_INTEGRATION_TARGET_FULL_PASS`: main App login với API thật, picker A/Admin và B/User, chọn A rồi B.
- `NATIVE_PRESELECTION_REQUEST_ORACLE_PASS`: ngay sau khi đủ hai picker rows/roles và trước chọn workspace đầu tiên, request counters là login=1, profile≥1, workspace-list=1, password-change=0, logout=0, OTHER=0. Các API calls dùng client riêng và force-close sau mỗi request; observer phân loại request đầu tiên mỗi connection.
- `NATIVE_SDK_APP_STOP_CHILD_EXIT_PASS`: process đầu được dừng và terminal của child được xác nhận.
- `NATIVE_INTEGRATION_TARGET_RESUME_PASS`: process mới khôi phục session từ secure storage; không login lại.
- `NATIVE_ACTUAL_MAIN_FULL_RESUME_LOGOUT_ORACLES_PASS`: PostgreSQL snapshot xác nhận thêm đúng một session rồi logout revoke đúng session đó; profile được đọc lại trong process mới.
- `NATIVE_OWNED_PROXY_FIXTURE_CLEANUP_PASS` và `NATIVE_ACTUAL_MAIN_FIXTURE_CLEANUP_PASS`: proxy và fixture thuộc lượt này đã cleanup theo runner.
- Sau lượt chạy, AVD dừng; `adb devices -l` không còn thiết bị; không có listener ở cổng 3000/8443.
- GPT-6.1 Sol high read-only review: finding về allowlist dispatch đã được sửa; follow-up review xác nhận đã đóng, không còn finding trong scope.

## Giới hạn không thay acceptance khác

- Không seed device rows vào workspace A/B; exact preselection request oracle đã PASS nhưng scenario acceptance còn thiếu fixture devices. `E2E-AUTH-003` và `AT-WF-001-03` ở trạng thái `PARTIAL`, chưa PASS.
- Đây là App đơn lẻ, không phải Web+App cùng fixture; không đóng `E2E-AUTH-001`.
- Đây là cold resume/logout, không phải committed-login-response-loss; không đóng `E2E-AUTH-006`.
- Không kiểm delayed logout cookie, full Chrome process reopen, audit redaction của shared run, TalkBack/OEM/thiết bị vật lý.

## Tái chạy

1. Mở Docker Desktop và AVD API 24. Trong cùng PowerShell đặt `$env:ANDROID_AVD_HOME='C:\Users\LENOVO\.android\avd'` nếu `emulator -list-avds` không liệt kê AVD.
2. Từ repo root chạy `node ops/auth/run_native_e2e.mjs --full-session`.
3. Chỉ nhận PASS khi có đủ marker preselection request oracle, full, process-stop, resume/logout oracle và cả hai cleanup marker; command exit phải là 0. Không ghi credential hoặc token vào report.
