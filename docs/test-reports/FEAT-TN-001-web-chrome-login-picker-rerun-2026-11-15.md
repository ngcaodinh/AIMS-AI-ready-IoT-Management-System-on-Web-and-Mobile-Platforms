# FEAT-TN-001 — Chrome + PostgreSQL login E2E rerun (15/11/2026)

**PASS_SCOPED_BROWSER_FLOW / READY_FOR_QA cho Web login, chọn/chuyển workspace và logout. Toàn feature vẫn VERIFY_IN_PROGRESS.** Không nâng E2E-AUTH-003 thành PASS.

## Môi trường và phạm vi

- Code state `dev@ba425ad`, dirty working tree, chưa commit; trước cập nhật docs có 98 mục dirty. Lượt này không sửa source/UI.
- Chrome thật qua extension, trang `http://localhost:5173/login`, backend auth lab ở port 3000, PostgreSQL `iot_platform_lab`.
- Fixture synthetic của auth lab: 5 accounts/2 workspaces; dùng account ordinal 0. Không tạo fixture device.
- Network observer bắt đầu trước submit. Evidence chỉ giữ method/path/status và tên key payload; không giữ giá trị, cookie, token, password, email hoặc raw response.

## Kết quả thực tế

| Bước | HTTP quan sát | UI/kết quả |
| --- | --- | --- |
| Đăng nhập | `POST /api/v1/auth/login` 200; `GET /api/v1/me` 200; `GET /api/v1/workspaces` 200 | Picker hiển thị Phòng vận hành A/Admin và Nhà kính B/Member. Login payload chỉ xác nhận các key `clientType`, `email`, `password`; values không được ghi. Không có request device/resource trước picker. |
| Chọn A | `GET /api/v1/workspaces/{workspaceId}` 200 | Màn xác nhận quyền quản trị viên của Phòng vận hành A. |
| Chuyển sang B | `GET /api/v1/me` 200; `GET /api/v1/workspaces` 200; `GET /api/v1/workspaces/{workspaceId}` 200 | Picker được tải lại; Nhà kính B hiển thị role thành viên và được xác minh. |
| Logout | `POST /api/v1/auth/logout` 204 | Trở về `/login`; password trống, email còn trong form. |

Trước luồng mới, tab localhost đang ở trạng thái `loginUnknown/recovery`; bấm rõ ràng **Đăng nhập lại** đưa form về trạng thái login. Không quan sát thấy request mạng trong thao tác bỏ intent cũ.

## Cleanup và trạng thái môi trường

- `run_local.py` session kết thúc exit 1: Ctrl+C không dừng child `auth-lab` tách cửa sổ. Đã xác minh child thuộc đúng lượt test, dừng child đó, rồi chạy recovery bằng ownership journal.
- `python -X utf8 -B ops/auth/run_local.py --cleanup-journal ops/auth/ownership/29b03b05-fe81-429e-abb8-66c59d221c35.json` exit 0; output `AUTH_LAB_ACCOUNT_FIXTURES_REMOVED`. Journal ghi application rows `REMOVED`; limiter bucket được giữ theo recovery policy và anonymous audit theo retention.
- Sau cleanup: không còn listener port 3000/8443. Một listener Web có sẵn `::1:5173`, PID 25904, được giữ nguyên; không thuộc lượt này.
- `adb devices -l` exit 0 nhưng không có device đang chạy. `emulator -list-avds` exit 0 liệt kê `Nexa_Auth_API24` và `Pixel_7`; không boot emulator trong lượt này.

## Lệnh và kiểm chứng đã chạy

- `docker ps --format '{{.Names}} {{.Status}} {{.Ports}}'` (ngoài sandbox theo quyền đã cấp): PostgreSQL container `iot-postgres17-database` đang Up.
- `npm.cmd run dev -- --host 127.0.0.1 --port 5173 --strictPort`: lần chạy sandbox bị EPERM ở Vite config temp; chạy lại với quyền ngoài sandbox khởi động Vite thành công. Process do lượt này mở đã dừng; listener PID 25904 là process có sẵn.
- `python -X utf8 -B ops/auth/run_local.py --port 3000`: auth lab báo backend sẵn sàng, sinh fixture test, thực hiện Chrome flow; teardown dùng ownership recovery như trên và session exit 1.
- `python -X utf8 -B ops/auth/run_local.py --cleanup-journal ops/auth/ownership/29b03b05-fe81-429e-abb8-66c59d221c35.json`: exit 0, fixture rows removed.
- Chrome CDP actual: login/bootstrap, picker, chọn A, tải lại picker/chọn B, logout; các status và UI được ghi trong evidence JSON.
- Không chạy lại host suite trong lượt này; các kết quả gần nhất được giữ ở checkpoint 15/11 trước đó.

## Phần còn mở

- `E2E-AUTH-003` và `AT-WF-001-03` giữ `NOT_RUN`: đã có Web oracle cho login payload keys và không query device/resource trước picker, nhưng chưa seed hai device khác workspace và chưa có exact Android request oracle.
- `WEB-AUTH-013/014` giữ `NOT_RUN`: full Chrome process close/reopen và delayed logout clear-cookie/race chưa chạy.
- `E2E-AUTH-001/006/007/008`, `IT-AUTH-011`, `SEC-AUTH-002/003/009` còn theo acceptance matrix. Protected-resource oracle của E2E-AUTH-007/008 cần FEAT-WF010 resource adapter; E2E-AUTH-003 không cần chờ FEAT-TN-010.
- Android runtime chưa chạy trong lượt này; đây không phải physical-device verification. Emulator AVD có sẵn nhưng chưa boot.
- Console error count không được thu trong lượt này; không kết luận 0 error.

## Task tiếp theo đủ dependency

1. Chạy E2E-AUTH-003 / AT-WF-001-03 bằng fixture sở hữu được, gồm hai device synthetic thuộc A và B; bắt request Web và Android từ trước submit đến lúc picker hiện, chỉ lưu method/path/status và payload key names. Dùng AVD Nexa_Auth_API24 hoặc Pixel_7, không cần thiết bị thật. Ca này không phụ thuộc FEAT-TN-010; auth-lab role hiện tại không có quyền device-table nên dùng fixture/provisioner device hiện hữu, không mở rộng quyền lặng lẽ.
2. Chạy WEB-AUTH-013/014 trên Chrome: full process close/reopen, delayed logout clear-cookie và race variants với cookie/request identity đã khử dữ liệu.
3. Chạy E2E-AUTH-007/008 sau khi FEAT-WF010 resource adapter sẵn sàng; kiểm protected-resource denial và stale/page-boundary cases.
4. IT-AUTH-011 và SEC-AUTH-002/003/009 cần failure injection cho exporter cùng structured-log sinks; auth diagnostics hiện chỉ là bounded in-memory recorder.
## Tester tái hiện

Dùng [runbook Web/App](../Instructions/feat-tn-001-e2e-testing.md), Terminal A–B. Terminal A chạy auth lab và chọn password TEST mới tại prompt kín; dùng email synthetic đầu tiên cho account có 2 workspace. Terminal B mở Web ở `http://localhost:5173/login`. Đăng nhập, chọn Phòng vận hành A, bấm Chuyển workspace, chọn Nhà kính B, rồi Đăng xuất. Không dùng lại email/password từ report; fixture chỉ sống trong lần chạy hiện tại. Nhánh disabled, no-workspace và limited/password-change có hướng dẫn riêng trong runbook.

## Tệp bàn giao

- [Evidence JSON đã khử dữ liệu](evidence/FEAT-TN-001-web-chrome-login-picker-rerun-2026-11-15.json)
- [Feature plan](../plan/features/FEAT-TN-001-dang-nhap-web-app.md)
- [Bảng tiến độ](../plan/implementation-progress.md)
- [Runbook Tester](../Instructions/feat-tn-001-e2e-testing.md)