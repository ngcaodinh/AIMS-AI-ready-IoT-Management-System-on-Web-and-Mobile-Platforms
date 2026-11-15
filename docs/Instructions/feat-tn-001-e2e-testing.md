# Hướng dẫn mở Web và App kiểm thử đăng nhập FEAT-TN-001

### Android API24 rerun — 15/11/2026

App main đã chạy trên AVD Nexa_Auth_API24/API24: login → A/Admin, B/User → exact request oracle trước chọn workspace (OTHER=0) → dừng process → resume từ secure storage không login lại → logout/revoke đúng session; PostgreSQL/session và runner cleanup PASS. `E2E-AUTH-003` vẫn PARTIAL vì lượt này chưa seed device rows khác workspace. [Report](../test-reports/FEAT-TN-001-android-api24-full-resume-2026-11-15.md), [evidence](../test-reports/evidence/FEAT-TN-001-android-api24-full-resume-2026-11-15.json).

Trong lượt này `HOME` không được set nên emulator không tự tìm thấy AVD. Nếu `emulator -list-avds` rỗng, đặt biến chỉ trong cửa sổ PowerShell đang dùng, trước khi mở AVD:

```powershell
$env:ANDROID_AVD_HOME = 'C:\Users\LENOVO\.android\avd'
```

Biến này không sửa cấu hình hệ thống. AVD phải dừng trước khi chạy lại fixture tự động.

### Chrome + PostgreSQL rerun 15/11 — actual Web flow

Chrome thật và auth lab PostgreSQL: login POST /api/v1/auth/login 200, /api/v1/me 200, /api/v1/workspaces 200; picker Phòng vận hành A/Admin + Nhà kính B/Member; chọn A, chuyển B, logout 204. CDP chỉ lưu method/path/status và login body key names (clientType, email, password), không lưu giá trị. Không có request device/resource trước khi chọn workspace.

E2E-AUTH-003 vẫn NOT_RUN vì lượt này không tạo device rows khác workspace và không chạy exact request oracle Android. Cleanup dùng ownership recovery exit0; auth-lab session ban đầu thoát exit1 do child detached. [Report](../test-reports/FEAT-TN-001-web-chrome-login-picker-rerun-2026-11-15.md), [evidence](../test-reports/evidence/FEAT-TN-001-web-chrome-login-picker-rerun-2026-11-15.json).

## Checkpoint hiện hành15/11

Rerun thực tế sau checkpoint: Chrome login → A/Admin → B/Member → logout đã đi hết luồng UI với PostgreSQL fixture. Password trống sau logout; email được giữ trong form. Không capture HTTP/payload/DB delta ở lượt này. Auth lab được thu hồi bằng recovery journal sau khi launcher stop lỗi; recovery exit0 và application rows đã xóa. [Evidence](../test-reports/evidence/FEAT-TN-001-chrome-ui-rerun-2026-11-15.json). Không dùng lượt này làm bằng chứng close WEB-AUTH-013/014.

**READY_FOR_QA theo scope đã kiểm, toàn feature VERIFY_IN_PROGRESS.** Provider DB thật370 markers/333 ID khác nhau; Web/Dart parser7/7; Web auth36/36 + TypeScript0; Flutter host213 PASS + analyze0 issue trên Flutter3.47.5/Dart3.13.4; auth host133PASS. Chrome thật với fixture DB bắt đầu CDP method/path/status trước submit: POST login200 → GET /me200 → GET /workspaces200, picker A/Admin + B/Member, chọn A detail200, logout204 về /login. Disabled account401 có lỗi chung; no-workspace hiện empty state; must-change-password bị gate ở /me403. Không có device/resource request trước picker; body/payload không được lưu nên E2E-AUTH-003 vẫn NOT_RUN. WEB-AUTH-013/014 còn full process reopen và delayed logout clear-cookie/race. Fixture đã cleanup qua owner journal/recovery; limiter giữ theo recovery policy, anonymous audit theo retention. Android API24 stale-membership rerun15/11 đạt preflight và actual owned-terminal, AVD đã dừng; [evidence](../test-reports/evidence/FEAT-TN-001-android-api24-stale-rerun-2026-11-15.json). Vite PID25904 là process có sẵn trước Chrome test và vẫn listen5173; API3000/3001 và proxy8443 hiện không nghe. Không dừng Vite đó; kiểm tra API/proxy và mở lượt mới bằng Terminal A/B/C/D bên dưới. [Browser evidence](../test-reports/FEAT-TN-001-continuation-2026-11-15.md), [JSON redacted](../test-reports/evidence/FEAT-TN-001-web-chrome-real-2026-11-15.json), [phần còn thiếu](../test-reports/FEAT-TN-001-remaining-checkpoint-2026-11-15.md), [capture report](../test-reports/FEAT-TN-001-backend-output-capture-2026-11-15.md). Các checkpoint bên dưới giữ lịch sử.

## Trạng thái hiện hành13/11

Lượt tiếp nối đạt provider252markers, actual success-response parser parity, Flutter212PASS và Web34PASS. Chrome đã kiểm controlled latecookieA sauacceptedB/mismatch409/reload và defaulttimeout/explicitcandidate. Fixture và Vite của lượt Chrome đã dừng/exit0, cần mở lượt mới theo Terminal A/B/C/D bên dưới. Fresh AVD rerun gặp thiếu dung lượng C và process crash, AVD tạm đã cleanup. [Report cập nhật, screenshot và giới hạn chính xác](../test-reports/FEAT-TN-001-final-continuation-2026-11-13.md). Các đoạn215/212/177 là checkpoint lịch sử.

Provider cuối đã chạy215checks trên DB thật và cleanup8zero. Backend hiện dùng schema20versions với IOS server bearer contract, Web/Android manual vẫn theo các bước dưới. [Code state, manifest, test receipts và phần chưa kiểm](../test-reports/FEAT-TN-001-ios-provider-and-policy-2026-11-13.md). Mọi listener3000/3001/5173/8443 của lượt báo cáo đã dừng, cần mở mới Terminal A/B/C/D.

Code bàn giao là `dev@ba425ad9e5576ed3261f6df5b4a4731c96d98850` với dirty working tree, chưa commit. Web, backend và AVD của các lượt báo cáo đã dừng. Hãy mở lượt mới bằng các bước bên dưới. Main APK đã được build/install lại sau native key-loss probe, nhưng API origin/certificate phải thuộc lượt đang chạy của bạn. Physical-device N/A theo user, dùng emulator API24/API36.

Antigravity CLI HydrogenHigh đã sửa copy lỗi503 của Web, Sol high review và Web26tests/TypeScript đạt. Chrome kiểm copy mới bằng503 injected, có recovery khóa workspace,320px không overflow. Chrome DB thật đã kiểm cookie A/B/missing, candidate/confirm/logout, có session/audit/cleanup. O4 có root và independent API36 actual với9HTTP/4SQL. [Bàn giao hiện hành và giới hạn](../test-reports/FEAT-TN-001-cli-and-cookie-handoff-2026-11-13.md), [I1 provider thực](../test-reports/FEAT-TN-001-provider-i1-sol-actual-2026-11-13.md), [ma trận acceptance](../test-reports/FEAT-TN-001-acceptance-matrix-2026-11-13.md).

### Mở nhanh một lượt manual

1. Mở Docker Desktop, chờ container PostgreSQL canonical sẵn sàng. Mở emulator Pixel_7/API36 đã có trong máy. Giữ bốn cửa sổ PowerShell riêng.
2. Terminal A chạy backend theo phần2. Tới prompt, chọn password TEST riêng và ghi nhớ. Chờ “Backend sẵn sàng”, lấy email synthetic của đúng lượt. Nhãn full có hai workspace dùng cho luồng chính.
3. Terminal B chạy Web theo phần3. Mở Chrome tại `http://localhost:5173/login`. Nhập email full/password TEST, bấm Đăng nhập, xác nhận picker có A/Admin và B/User, chọn A, quay lại picker chọn B, reload rồi làm explicit confirmation nếu được hỏi, cuối cùng Đăng xuất. Các action phải có loading rồi trạng thái rõ.
4. Terminal C chạy HTTPS proxy theo5a, copy public certificate mới. Terminal D chạy Flutter main với đúng emulator ID và certificate theo5a. Nhập cùng account, chọn A/B rồi Đăng xuất. Kiểm Web/App session riêng bằng phần7.
5. Chạy lỗi form trống và email sai, disabled, limited và empty bằng các nhãn tài khoản trong phần2/4/6. Lỗi form chỉ xuất hiện sau submit sai. Limited chỉ vào đổi mật khẩu, empty có giải thích rõ, các nhánh này đều cần ghi kết quả riêng.
6. Kiểm offline trên App theo phần11, GET failure/unknown trên Web theo W05. Giữ recovery khóa workspace tới khi đối soát và xác nhận thành công. Khi nối mạng lại, chờ ít nhất30s trước bấm thử lại để kiểm không tự gửi login.
7. Cleanup theo phần8, chờ terminal sở hữu báo kết thúc. Credential và certificate hết hiệu lực sau cleanup. Chỉ chạy lại test tự động sau khi các terminal manual đã dừng.

### Chạy tự động offline đã có evidence

Tại root, emulator API36 đúng target sẵn sàng và chưa có fixture/SDK job khác đang chạy, dùng lệnh sau. Runner tạo fixture riêng, điều khiển fault/restore mạng và tự cleanup.

```powershell
Set-Location 'D:\CODE\DO_AN\DO_AN_3'
node --unhandled-rejections=strict ops/auth/run_native_offline_e2e.mjs --offline
```

Đối chiếu original exit0, actual main/offline/quiet/recovery/picker/logout, HTTP prefixes1/1/2/5/9, SQL baseline/negative/live-mid/final và owned cleanup. Nếu SDK hoặc cleanup chưa terminal thì giữ trạng thái chưa xác minh. [Final actual/reference manifest](../test-reports/FEAT-TN-001-offline-final-review-2026-11-13.md). Các phần checkpoint theo ngày phía dưới giữ lịch sử.

**Sau fix12/11:** lỗi credential cũ không trộn lỗi field hoặc loading mới; reload/resume dùng câu “Cần xác nhận lại trạng thái đăng nhập”. Tester hãy thử disabled→xóa hai field/submit→full login→A→reload→logout.26hosttests/TypeScript/ViteRAM và Chrome DB thật đạt; independent review bị usage limit, vẫn READY_FOR_QA. [Report cuối và bằng chứng](../test-reports/FEAT-TN-001-chrome-real-db-2026-11-12.md). Cả fixture retest và Vite đã đóng/exit0, không có server live để dùng credential cũ. Mở lượt mới theo phần2/3 và App theo5a.

**Cập nhật12/11:** Chrome extension đã hoạt động và root kiểm lại full A/reload/B/A/logout, disabled/empty/limited gate, validation/theme/keyboard/375px với DB thật. [Report và screenshot mới](../test-reports/FEAT-TN-001-chrome-real-db-2026-11-12.md). Fixture và Vite lượt này đã dừng; các câu server/AVD “đang chạy” bên dưới là checkpoint lịch sử, không phải trạng thái live. Để tự thử, mở mới Terminal A/B theo phần2/3 và App theo5a, dùng credential/cert của lượt mới. Chưa nghiệm thu toàn feature; hạn chế oracle và hai điểm UX được ghi trong report.

Ngày đối chiếu 10/11/2026, `dev@ba425ad9e5576ed3261f6df5b4a4731c96d98850`, dirty working tree, chưa commit. Hướng dẫn này dành cho Tester thao tác trên giao diện và ghi kết quả của chính lượt thử. Toàn feature chưa nghiệm thu.

## 1. Bắt đầu từ đâu?

Địa chỉ Web local là `http://localhost:5173/login` sau khi bạn mở Terminal B. Để login thành công bằng tay, bắt đầu Terminal A rồi Terminal C/D theo các bước dưới đây. [Kết quả kiểm thử09/11 giữ làm lịch sử](../test-reports/FEAT-TN-001-handoff-2026-11-09.md).

Để kiểm bằng tay, thực hiện theo thứ tự sau. Mỗi terminal cần được giữ mở cho đến phần cleanup.

1. **Backend — Terminal A:** phần2 tạo dữ liệu thử và chọn mật khẩu TEST bằng prompt kín. Chờ thông báo backend sẵn sàng trước khi đăng nhập.
2. **Web — Terminal B:** phần3 mở Vite và `http://localhost:5173/login` bằng Chrome/Edge. Chạy các ca W01–W05 ở phần4.
3. **App — Terminal C/D:** mở emulator API24 hoặc API36, tạo HTTPS proxy và chạy main với public certificate mới theo5a. Chạy A01–A09 ở phần6. Không dùng preview làm App kiểm nghiệp vụ.
4. **Hai client cùng account:** giữ cùng Terminal A cho Web và App, thực hiện phần7. Kết thúc và cleanup theo phần8.
5. **Kiểm tự động Android:** phần5b–5f tạo fixture riêng và tự cleanup. Chạy tuần tự, sau khi đã dừng lượt manual. Không chạy chúng song song với Terminal A/C hoặc một job SDK khác.

Mỗi lượt backend tạo email synthetic mới. Dùng email được Terminal A của bạn in ra và mật khẩu TEST bạn vừa nhập. Credential, certificate và phiên từ report cũ không dùng lại được. Role có hạn1giờ vẫn phải được cleanup đúng phần8.

Bản main không có API origin hiển thị **Ứng dụng chưa sẵn sàng**. Đây là config gate, chưa phải lỗi đăng nhập. Muốn test App cần chạy lại main theo5a với backend/proxy đang sống và certificate của đúng lượt. Browser automation có thể bị Work settings chặn dù Chrome đang mở; Tester vẫn có thể tự thao tác trình duyệt bằng các bước dưới đây.

| Phạm vi đã thực chạy | Bằng chứng và giới hạn |
| --- | --- |
| Web UI/API | Root đã kiểm full A/B, reload/logout, empty/disabled/limited và form reset. Web rate có921054ms quan sát, explicit login/logout và cleanup. Independent UI repeat còn mở. [Report Web](../test-reports/FEAT-TN-001-web-api-and-negative-coverage-2026-11-07.md). |
| Web mất response và quyền stale | R2 có fault ACK dưới15s, same-request failure, DB/session/audit, recovery và explicit confirmation. Stale B có detail404 rồi A control thành công. Không thay toàn bộ cookie/tab/race matrix. [Report R2](../test-reports/FEAT-TN-001-web-response-loss-r2-and-stale-2026-11-08.md). |
| Android full/access/password | API36 đã root/independent scoped PASS. API24 đã root full/coldresume/access/password exit0; independent API24, lifecycle và physical-device gates còn mở. [Report API24](../test-reports/FEAT-TN-001-api24-integration-2026-11-08.md). |
| Android rate | API36 có root/independent real900s, request/session/PID oracle và original cleanup. Lượt API24 ngày08/11 FAIL với SDK isolate/cleanup error. Retest root09/11 đã đủ oracle/cleanup/exit0, fresh8zero. Independent API24 cũng PASS với terminal/cleanup riêng, main đã restore09/11. [Report API24 rate](../test-reports/FEAT-TN-001-api24-rate-2026-11-08.md). [Report API36](../test-reports/FEAT-TN-001-native-rate-cli-reserve-2026-11-06.md). |
| Web/App cùng account | Root API24 đã kiểm logout hai chiều, distinct sessions và cleanup. Independent UI repeat, audit/redaction và các giới hạn ordering còn trong [report shared](../test-reports/FEAT-TN-001-shared-web-api24-2026-11-08.md). |
| App offline/stale | Root đã kiểm UI, session metadata, airplane restore và cleanup trên main API24. Exact Android HTTP counter và independent repeat chưa có. [Report offline/stale](../test-reports/FEAT-TN-001-api24-offline-and-stale-2026-11-08.md). |

Các kết quả trên chỉ READY_FOR_QA trong phạm vi ghi trong report. Owner review, accessibility/TalkBack, thiết bị thật, storage restore và các nhánh race còn theo [feature plan](../plan/features/FEAT-TN-001-dang-nhap-web-app.md). Không điền PASS thay cho ca chưa chạy.

Mật khẩu login nhận9–128 Unicode codepoints. Mật khẩu mới khi đổi phải có9–128 codepoints, chữ hoa/thường Unicode và số ASCII0–9, không trim/normalize. Form login không có hint độ dài thường trực; validation xuất hiện sau submit sai.

## 2. Chuẩn bị và mở backend thử nghiệm

HTTPS lab debug đã được dùng trong scoped Android C1 actual test; xem [TLS plan](../test-reports/FEAT-TN-001-local-tls-plan-2026-10-28.md) và [C1 report](../test-reports/FEAT-TN-001-native-full-session-2026-10-29.md). Đây không phải cấu hình trust cho production hoặc máy Android thật.
`node ops/auth/probe_memory_tls.mjs` chỉ chạy sáu handshake rồi đóng listener;
không mở backend/proxy dùng cho login và không in credential/certificate.
Không lấy port tạm của probe làm `AUTH_API_BASE_URL` cho App.

Bạn cần một terminal PowerShell mở tại `D:\CODE\DO_AN\DO_AN_3`. Lệnh bên dưới dùng database lab canonical đã có; không tạo database thay thế và không yêu cầu sửa file cấu hình chứa secret.

1. Giữ riêng terminal này làm **Terminal A — Backend**.
2. Chạy:

```powershell
Set-Location 'D:\CODE\DO_AN\DO_AN_3'
python -X utf8 -B ops/auth/run_local.py --port 3000
```

3. Launcher kiểm identity/schema và build binary trước. Chỉ khi tới prompt chọn password thử, nhập một password mới có9–128ký tự, chữ hoa, chữ thường và số0–9. Dùng password riêng cho dữ liệu thử; không ghi password vào report hoặc command line. Lúc nhập, terminal không hiện ký tự là bình thường.
4. Chờ dòng **“Backend sẵn sàng”**. Không tiếp tục ca login success chỉ vì terminal đang mở. Nếu hiện `AUTH_LAB_FAILED`, ghi ca môi trường BLOCKED và giữ thông báo lỗi; không reset DB hay chạy nhiều launcher cùng lúc.
5. Giữ Terminal A mở. Launcher in email synthetic cho các nhãn dưới đây; dùng đúng email của lần chạy hiện tại, không dùng email từ report cũ.

| Nhãn được in | Dùng cho ca | Kết quả cần thấy |
| --- | --- | --- |
| `2 workspace (Admin A/User B)` | Full login, chọn/đổi workspace, Web/App song song | Picker có **Phòng vận hành A** quyền quản trị viên và **Nhà kính B** quyền thành viên |
| `disabled` | Tài khoản bị vô hiệu hóa | Lỗi đăng nhập chung; không lộ trạng thái tài khoản |
| `bắt buộc đổi password` | Limited session | Chỉ đổi password/đăng xuất, chưa mở workspace |
| `không có workspace` | Empty | Đăng nhập được nhưng có empty riêng, không chọn workspace giả |

Launcher tạo5tài khoản; tài khoản thứ5 dùng làm chủ workspace B trong graph fixture, không in như một account manual riêng. Bốn nhãn trên đủ cho các ca thao tác chính. Tất cả dùng password thử vừa nhập ban đầu; sau ca đổi password, riêng account đó dùng password mới.

Role DB hết hạn sau1giờ là giới hạn truy cập, **không thay cleanup**. Nếu lượt thử quá lâu, kết thúc theo phần8 rồi bắt đầu một lượt mới. Không dùng `--verify` để mở server manual: mode đó chạy provider checks rồi dọn fixture và thoát.

## 3. Mở Web

1. Mở PowerShell thứ hai, giữ làm **Terminal B — Web**.
2. Chạy:

```powershell
Set-Location 'D:\CODE\DO_AN\DO_AN_3\web'
npm.cmd run dev -- --host localhost
```

3. Chờ Vite báo sẵn sàng, mở **`http://localhost:5173/login`** trên Chrome hoặc Edge. Nếu đã có Vite chạy ở cổng5173, dùng server hiện có; không mở thêm một bản cùng cổng.
4. Giữ hostname `localhost`. Web proxy `/api/v1` tới backend loopback3000 và giữ Origin; không tự đổi sang hostname/IP khác.
5. Form mới phải có Email, Mật khẩu, nút hiện/ẩn password và Đăng nhập. Không có câu nhắc9–128ký tự thường trực; lỗi độ dài xuất hiện khi submit sai. Nhấn Trang chủ rồi Đăng nhập ở header phải quay lại đúng form.

## 4. Chạy các ca Web theo thứ tự

### W01 — Login full, chọn workspace, đổi workspace, logout

1. Dùng email nhãn `2 workspace` và password thử. Nhấn Đăng nhập một lần.
2. Khi đang gửi, không được tạo nhiều lần submit từ double-click. Không coi loading là thành công.
3. Chờ picker **Chọn workspace**. Phải thấy hai workspace; không được tự chọn một workspace hoặc mở dữ liệu thiết bị ngay.
4. Nhấn Chọn của **Phòng vận hành A**, chờ server kiểm lại quyền. Sau đó thấy summary đúng email/workspace/quyền quản trị viên.
5. Nhấn **Chuyển workspace**, chọn **Nhà kính B**, chờ summary hiển thị quyền thành viên. Đây là màn xác nhận phiên/workspace; dashboard thiết bị chưa thuộc kết quả FEAT-TN-001 này.
6. Nhấn **Đăng xuất**. Chỉ về form sau khi thao tác được xác nhận; nếu kết quả chưa rõ phải còn recovery, không logout giả.

### W02 — Tài khoản bắt buộc đổi password

1. Login bằng email nhãn `bắt buộc đổi password`, password ban đầu. Phải đến **Đổi mật khẩu để tiếp tục**, chưa có picker/workspace.
2. Tự nhập Mật khẩu hiện tại, Mật khẩu mới, Xác nhận mật khẩu mới. Password mới phải khác cũ, có9–128ký tự, hoa/thường/số. Lần đầu thử xác nhận không trùng để kiểm lỗi; sau đó sửa cho trùng.
3. Gửi đổi password và chờ kết quả. Thành công phải yêu cầu login lại. Không tự nâng limited session thành full trong cùng form.
4. Login lại bằng password cũ: bị từ chối. Login bằng password mới: được chấp nhận, sau đó có thể empty vì account limited fixture không được cấp membership. Empty đúng không phải lỗi đổi password.
5. Password ban đầu vẫn dùng cho các account fixture khác. Không chạy đổi password song song trên cùng account ở Web và App nếu đang kiểm ca full khác.

### W03 — Empty, disabled, validation và keyboard

1. Account `không có workspace`: login → **Không có workspace khả dụng**; Tải lại danh sách dùng được, không tự mở workspace. Nút Tạo workspace hiện chưa khả dụng và phải giải thích dependency; chức năng tạo workspace nằm ngoài ca này.
2. Logout rồi thử account `disabled`: chỉ thấy lỗi đăng nhập chung; không thấy danh sách workspace.
3. Form mới, submit trống: summary lỗi nhận focus. Enter link lỗi Email phải đến input Email; Tab tiếp đến Mật khẩu. Label, hiện/ẩn password và nút submit thao tác được bằng bàn phím.
4. Đổi sáng/tối, kiểm ở375px và màn thấp: đọc được lỗi, không cuộn ngang, input/reveal/nút submit vẫn tới được bằng cuộn dọc. Hover ô lỗi phải giữ màu lỗi.

### W04 — Rate limit

1. Chạy sau các ca login chính. Lấy email fixture của lượt hiện tại và thay hậu tố `-0@example.invalid` bằng `-unknown@example.invalid` để dùng một email synthetic không tồn tại; giữ nguyên phần run ID.
2. Dùng password sai dài ít nhất9ký tự để vượt client length validation. Gửi6lần liên tiếp trên email này trong cùng cửa sổ limiter.
3. Provider contract dùng5lần401 rồi lần6 là429. UI phải hiện thời gian thử lại, khóa submit trong countdown; hết giờ không tự gửi request và không tự đăng nhập.
4. Nếu không tái hiện được, ghi thời gian và số lần thực gửi, không đánh PASS chỉ vì đã nhấn6lần. Không reset limiter/database để ép kết quả; dùng lượt fixture mới sau cleanup khi cần.

### W05 — Backend mất kết nối, reload và đối soát

Root R2 ngày08/11 đã kiểm mất response bằng controller, có ACK dưới15s và bằng chứng request/session/UI theo [report R2](../test-reports/FEAT-TN-001-web-response-loss-r2-and-stale-2026-11-08.md). Ba lượt R1 trước đó vẫn INCONCLUSIVE do ACK trễ; giữ nguyên trong [report lịch sử](../test-reports/FEAT-TN-001-web-response-loss-2026-11-08.md). Các bước W05 dưới đây chỉ kiểm backend unavailable, không tự tạo fault sau commit.

1. Hoàn tất/đăng xuất các ca cần fixture trước. Dừng Terminal A bằng Ctrl+C; bước này cũng bắt đầu cleanup của launcher.
2. Submit hợp format trên Web khi backend đã dừng. Phải có lỗi/recovery, không login success giả. Reload không được tự replay POST login.
3. Action **Đối soát phiên hiện tại** phải có loading rồi kết quả rõ hoặc giữ recovery. Backend chưa chạy thì không thể đối soát thành công.
4. **Đăng nhập lại** cho nhập thông tin mới; hành động này không tự chứng minh server logout đã ACK.
5. Tắt backend trước submit chỉ kiểm unavailable. Muốn chứng minh request đã commit nhưng mất response cần fault harness riêng; thao tác này không đủ chứng minh commit-unknown hoặc retry safety toàn hệ thống.

## 5. Mở App Android main thật

App cần **HTTPS origin thật có chứng chỉ được thiết bị tin cậy**, cùng deployment/fixture phù hợp. Lab phần2 hiện chỉ listen HTTP loopback; URL của Web không phải HTTPS endpoint cho App. Endpoint App chưa được xác nhận thì dừng ca API Android ở BLOCKED. Không đổi cleartext policy hoặc bỏ certificate validation để làm ca test chạy.

1. Kết nối thiết bị Android hoặc mở AVD đã được dự án chuẩn bị. Từ PowerShell tại `mobile`, chạy:

```powershell
Set-Location 'D:\CODE\DO_AN\DO_AN_3\mobile'
& 'C:\src\flutter\bin\flutter.bat' devices --machine
```

2. Chọn đúng Android device ID trong output. `windows` hoặc `chrome` không thay Android. `emulator-5554` chỉ là ví dụ ID, không mặc định máy nào cũng có.
3. Khi đã có device và HTTPS origin được xác nhận, thay hai placeholder rồi chạy:

```powershell
& 'C:\src\flutter\bin\flutter.bat' run --no-pub -d YOUR_ANDROID_DEVICE_ID --dart-define=AUTH_API_BASE_URL=https://YOUR_API_ORIGIN
```

Origin chỉ gồm scheme/host/port cần thiết; không thêm `/api/v1`, path, query, fragment hoặc thông tin đăng nhập. Chạy **main mặc định**, không thêm `-t tool/...preview.dart`. Không truyền password/token qua `--dart-define`.

4. Thiếu hoặc dùng HTTP origin phải hiện **Ứng dụng chưa sẵn sàng**, chưa thực hiện auth I/O. Đây là negative config case, không phải login E2E success.
5. SDK ngoài sandbox đã chạy được sau cập nhật quyền: root và tester dùng Flutter wrapper bình thường, không đổi Git trust/owner/global environment. Các lỗi ownership trong sandbox ở report cũ là lịch sử context; nếu terminal của bạn còn gặp lỗi thì ghi lại, không sửa global trust để che lỗi.
6. Main hỗ trợ `AUTH_LAB_CA_CERT` là **public DER Base64**, chỉ bản debug và origin chính xác `https://10.0.2.2:8443`. Đây là trust riêng của App, không cài CA vào Android/Windows; SDK vẫn kiểm hostname/thời hạn. Actual Android C1 đã root/independent PASS với cert vừa sinh của mỗi lượt; xem phần5a để mở một lượt mới. Không lấy certificate fixture từ test hoặc port của T0 probe: private key của fixture đã bị hủy. Với endpoint HTTPS sản phẩm được SDK tin cậy, tiếp tục dùng lệnh ở bước3 và không thêm lab cert.
7. Certificate lab sai cấu trúc/origin hoặc build profile/release phải bị chặn cấu hình; chưa dùng các unit compiler-flag checks làm evidence APK release/profile. [Handoff TLS/main và giới hạn](../test-reports/FEAT-TN-001-debug-lab-trust-2026-10-28.md).

Checkpoint2026-10-29: C0 native test channel đã root/independentPASS trên
Android16/API36, main mặc định đã restore. C0 chỉ kiểm kênh fixture RAM/SDK,
không login/TLS/API; không dùng lệnh `--preflight` để thay các bước E2E dưới đây.
[C0 report](../test-reports/FEAT-TN-001-native-control-2026-10-29.md).

### 5a. Mở App qua HTTPS local dành cho Android emulator

Nếu `flutter devices` chưa thấy Android, mở PowerShell riêng tại root dự án để khởi động AVD đã có. Giữ cửa sổ này trong suốt lượt test.

```powershell
$env:ANDROID_AVD_HOME = 'C:\Users\LENOVO\.android\avd'
& 'C:\Users\LENOVO\AppData\Local\Android\sdk\emulator\emulator.exe' -avd Nexa_Auth_API24 -no-snapshot-load
```

Chờ máy ảo tới màn hình Android, rồi kiểm ở terminal khác.

```powershell
& 'C:\Users\LENOVO\AppData\Local\Android\sdk\platform-tools\adb.exe' devices -l
& 'C:\src\flutter\bin\flutter.bat' --suppress-analytics devices
```

Thiết bị phải ở trạng thái `device`, sau đó dùng đúng ID được in ở lệnh Flutter. Các ca harness5b–5f đã kiểm theo Pixel_7/API36 và emulator-5554. AVD `Nexa_Auth_API24` hiện cũng có trong danh sách, dành lượt minimum-OS riêng và cần evidence mới theo API thực tế. Ngày08/11 Nexa_Auth_API24 đã đạt root full/coldresume/access/password integration; main90773 đã restore. Để kiểm Android16/API36 dùng AVD Pixel_7 trong lệnh khởi động, giữ riêng evidence OS. Mỗi lượt manual vẫn kiểm lại devices/boot và không mở hai AVD cùngID mặc định.


1. Giữ **Terminal A backend** ở phần2 đang chạy tại127.0.0.1:3000. Ghi riêng email synthetic được launcher in và mật khẩu TEST bạn vừa nhập; không đưa password vào lệnh/file/report. Terminal Web ở phần3 có thể giữ mở để kiểm cùng phiên dữ liệu.
2. Mở **Terminal C proxy** tại root dự án:

```powershell
Set-Location 'D:\CODE\DO_AN\DO_AN_3'
node ops/auth/local_https_proxy.mjs
```

3. Chờ `LOCAL_HTTPS_PROXY_READY` rồi dòng `AUTH_LAB_CA_CERT=...`. Copy **chỉ giá trị sau dấu bằng**. Đây là certificate công khai, không phải mật khẩu/private key. Startup có thể mất tối đa60s; sau ready, proxy tự dừng trước50phút. Giữ terminal mở. `LOCAL_HTTPS_PROXY_FAILED` hoặc không có ready/cert thì chưa có endpoint: không kill process chiếm8443; kiểm terminal backend/port theo người vận hành.
4. Mở **Terminal D Flutter**. Xác nhận ID emulator bằng `flutter devices --machine`, rồi dùng ID thực tế (checkpoint gần nhất là `emulator-5554`, Pixel_7/API36):

```powershell
Set-Location 'D:\CODE\DO_AN\DO_AN_3\mobile'
$labPublicCertificate = Read-Host 'Dan gia tri public AUTH_LAB_CA_CERT vua sinh'
& 'C:\src\flutter\bin\flutter.bat' run --no-pub -d emulator-5554 --dart-define=AUTH_API_BASE_URL=https://10.0.2.2:8443 "--dart-define=AUTH_LAB_CA_CERT=$labPublicCertificate"
```

5. Chạy main debug mặc định. Certificate đổi mỗi lần restart proxy: dừng/run lại Flutter với cert mới, hot reload không thay compile define. Không dùng `--release`/`--profile` với cert lab, không thêm slash/path vào origin. URL10.0.2.2 dành emulator Android, không dùng cho máy Android thật.
6. Trên App, nhập account full và mật khẩu TEST từ Terminal A → Đăng nhập → chọn workspace A/B → Đăng xuất. Tiếp tục A02–A08 ở phần6; ghi kết quả actual từng ca. Nếu App báo lỗi trust/config thì ghi FAIL/BLOCKED; Node synthetic PASS không thay native handshake/API evidence.
7. Kết thúc: dừng Flutter bằng `q`, gõ `STOP` rồi Enter tại Terminal C, chờ `LOCAL_HTTPS_PROXY_STOPPED`; Ctrl+C Terminal A để launcher dọn role/fixtures. Dừng proxy không tự cleanup DB. Certificate/private key không cài vào store; không cần xóa trust hệ thống.

Nhánh lỗi: dừng backend giữ proxy để kiểm transport recovery; STOP proxy để kiểm offline; giữ cert cũ sau restart proxy để kiểm TLS rejection. Không chấp nhận màn hình success giả/autoPOST. Các nhánh lỗi này vẫn cần chạy và ghi kết quả riêng; C1 happy path PASS không thay chúng. [Proxy handoff/evidence](../test-reports/FEAT-TN-001-local-https-proxy-2026-10-29.md).

### 5b. Chạy tự động luồng Android full và cold restore

1. Dừng lượt manual trước bằng đúng terminal sở hữu (Flutter `q`, proxy `STOP`, backend Ctrl+C và chờ cleanup). Không chạy hai fixture/SDK jobs đồng thời. Giữ Docker canonical và Pixel_7/API36 `emulator-5554` sẵn sàng; không xóa dữ liệu App hoặc reset emulator.
2. Tại root dự án, dùng PowerShell có quyền chạy SDK/Docker đã được cấp:

```powershell
Set-Location 'D:\CODE\DO_AN\DO_AN_3'
node ops/auth/run_native_e2e.mjs --full-session
```

3. Runner tự tạo5tài khoản/2workspace và password ngẫu nhiên trong RAM; bạn không nhập hoặc chép password. App sẽ chạy login → chọn A/Admin → B/User → dừng process thật → mở process mới → khôi phục cùng phiên từ secure storage → chọn A/B → logout. Kiểm có API thật, không phát loginPOST khi restore, cùng UUID phiên bị revoke và cleanup8counts0 (gồm limiterBuckets).
4. Chỉ ghi scoped PASS khi có đủ `NATIVE_ACTUAL_MAIN_FULL_RESUME_LOGOUT_ORACLES_PASS`, `NATIVE_OWNED_PROXY_FIXTURE_CLEANUP_PASS`, `NATIVE_ACTUAL_MAIN_FIXTURE_CLEANUP_PASS` và lệnh kết thúc exit0. Full phase PASS riêng lẻ chưa đủ. Build có thể mất vài phút; không khởi chạy lệnh thứ hai chỉ vì cửa sổ chưa trả prompt.
5. Nếu FAIL/cleanup unconfirmed: lưu fixed stage/status và ownership journal, đợi process terminal; không kill theo port, không xóa journal. Một lượt independent đã FAIL resume startup, các repeat mới PASS; nguyên nhân vẫn mở. Lượt này không kiểm limited/password/429/offline hoặc Web.
6. Muốn quay về main bình thường sau test (target tự động không dùng để test tay), chạy tại `mobile`:

```powershell
Set-Location 'D:\CODE\DO_AN\DO_AN_3\mobile'
& 'C:\src\flutter\bin\flutter.bat' --suppress-analytics run --no-pub --no-resident -d emulator-5554
```

Main không có origin sẽ hiện configuration gate vì fixture đã dọn. Muốn thao tác login thật, mở lại backend/proxy và chạy main với public cert mới ở phần5a. [Evidence root](../test-reports/FEAT-TN-001-native-full-session-2026-10-29.md), [evidence independent](../test-reports/FEAT-TN-001-native-full-session-independent-2026-10-29.md).

### 5c. Kiểm tự động disabled và workspace rỗng

Chạy lượt riêng sau khi lượt5b hoặc manual đã terminal/cleanup; không chạy song song fixture/SDK. Giữ Docker canonical và Pixel_7/API36 sẵn sàng. Runner tự sinh account/password RAM như phần5b, bạn không cần nhập secret:

```powershell
Set-Location 'D:\CODE\DO_AN\DO_AN_3'
node ops/auth/run_native_e2e.mjs --access-cases
```

App sẽ thử account disabled/password đúng → lỗi chung, account empty/password sai → cùng lỗi chung, rồi password đúng → trạng thái không có workspace → tải lại → đăng xuất. Có fresh loading ở mỗi operation và checkpoint request counter riêng để không đọc lại màn cũ như một kết quả mới. Nút tạo workspace phải disabled kèm lý do dependency065.

Chỉ ghi scoped PASS khi có `NATIVE_ACTUAL_MAIN_ACCESS_ORACLES_PASS`, `NATIVE_OWNED_PROXY_FIXTURE_CLEANUP_PASS`, `NATIVE_ACTUAL_MAIN_FIXTURE_CLEANUP_PASS` và exit0. Root35299 và independent3682 đã đạt trên API36. [Files/commands/evidence và giới hạn](../test-reports/FEAT-TN-001-native-access-2026-10-29.md). Đây không phải test limited/password/429/offline. Sau test muốn mở main bằng tay, làm bước6 phần5b rồi cấu hình lượt backend/proxy mới ở5a; không dùng integration target làm App thao tác tay.

### 5d. Kiểm tự động đổi mật khẩu và đăng nhập lại

Root và tester GPT-6.1/xhigh đã chạy riêng trên Pixel_7/API36 ngày30 và đạt scoped password PASS. Đây là luồng dùng main/API/TLS/secure storage thật; toàn feature,429/offline và các gate thiết bị khác vẫn chưa nghiệm thu. [Report root và giới hạn](../test-reports/FEAT-TN-001-native-password-continuation-2026-10-30.md), [report độc lập](../test-reports/FEAT-TN-001-native-password-independent-2026-10-30.md).

1. Chờ lượt manual hoặc lệnh kiểm trước kết thúc, có cleanup; không chạy hai fixture/SDK jobs cùng lúc. Giữ Docker canonical và emulator `Pixel_7`/`emulator-5554` đã boot. Không reset dữ liệu App.
2. Mở PowerShell tại root rồi chạy:

```powershell
Set-Location 'D:\CODE\DO_AN\DO_AN_3'
node ops/auth/run_native_e2e.mjs --password-cases
```

3. Runner tự sinh hai mật khẩu mạnh trong RAM và5tài khoản/2workspace. Bạn không cần nhập, chép hoặc lưu mật khẩu của lượt tự động. Trên App, theo dõi tài khoản bắt buộc đổi mật khẩu tới form;8ký tự/thiếu hoa/thiếu thường/thiếu số/xác nhận khác nhau đều bị chặn. Sau đó sai mật khẩu hiện tại bị từ chối; nhập đúng sẽ đổi thành công và về login.
4. Runner dừng process App rồi mở process mới. Mật khẩu cũ phải bị từ chối; mật khẩu mới phải tới màn workspace rỗng rồi đăng xuất. Phần host kiểm request counters, phiên server và PID; nhìn màn hình riêng lẻ chưa đủ kết luận PASS.
5. Chỉ ghi PASS khi có đủ `NATIVE_ACTUAL_MAIN_PASSWORD_ORACLES_PASS`, `NATIVE_OWNED_PROXY_FIXTURE_CLEANUP_PASS`, `NATIVE_ACTUAL_MAIN_FIXTURE_CLEANUP_PASS` và lệnh kết thúc exit0. Marker `PASSWORD_PASS` đơn lẻ chưa đủ. Chờ cleanup kể cả khi FAIL; giữ journal nếu chưa xác nhận, không kill theo port hoặc xóa dữ liệu để làm xanh.
6. Để quay về App thao tác tay, làm bước6 phần5b. Bản main mặc định không có API origin sẽ hiện màn cấu hình vì fixture tự động đã dọn. Muốn nhập tài khoản bằng tay, tạo lượt backend/proxy mới theo2/3/5a, dùng mật khẩu TEST do bạn chọn tại terminal. Integration target không phải App để sử dụng tay.

### 5e. Tái hiện countdown429 bằng tay trên App

Chỉ thực hiện khi backend/proxy/main thật đã sẵn sàng theo2/3/5a. Nếu Docker hoặc build còn lỗi quyền, ghi **BLOCKED**, không thử bằng preview. Phần5f có CLI tự động riêng; các bước dưới đây dành cho main thao tác tay, ghi evidence riêng.

1. Dùng lượt fixture mới và account full của chính lượt đó, chưa từng thử password sai trong cửa sổ hiện tại. Giữ Terminal A/backend và proxy mở; App ở login. Không dùng account thật hoặc account từ report cũ.
2. Nhập cùng email và một password thử sai, khác password đúng, có ít nhất9ký tự để qua validation. Bấm Đăng nhập, chờ loading kết thúc rồi mới bấm tiếp. Lần1–5 phải cùng thông báo đăng nhập không hợp lệ; không được mở workspace. Không ghi password vào report.
3. Gửi sai lần6. Mong đợi card “Thử lại sau N giây”, không còn form submit khả dụng. Ghi giờ nhận429/card và số giây ban đầu, không chép response/token. Nếu chỉ có lỗi generic hoặc card không xuất hiện, ghi FAIL/UNKNOWN với bước cuối đã thấy.
4. Giữ App foreground, không bấm login/refresh/logout trong lúc quan sát. Countdown phải giảm, không tăng hoặc đứng lâu. Form có thể trở lại trước15phút kể từ lần6 vì cửa sổ server bắt đầu từ failure đầu; việc form xuất hiện chưa cho phép kết thúc phép kiểm này.
5. Chờ đến mốc muộn hơn giữa **15phút sau card429 xuất hiện** và **lúc form trở lại**, rồi thêm2giây. Trong khoảng đó không được tự chuyển thành đăng nhập thành công. Ghi thời điểm form trở lại và các mẫu countdown; không tua giờ máy/server hoặc sửa bucket để rút ngắn.
6. Sau thời gian quan sát, chủ động nhập password đúng của fixture và bấm Đăng nhập. Mong đợi picker đúng2workspace/roles, chưa tự chọn. Bấm Đăng xuất và chờ về login.
7. Đây mới là bằng chứng UI thủ công. Không tự ghi wholecasePASS hoặc “không autoPOST” chỉ bằng nhìn màn hình: còn phải có exact requestcounters/session/PID/owned cleanup và8zero readback trong harness khi B3c/B1bactual đủ dependency. Nếu thiếu, ghi UI_VERIFIED / ORACLES_NOT_VERIFIED. Cleanup theo phần8, giữ journal khi chưa xác nhận.

Muốn kiểm source ngay trong khi môi trường actual bị chặn: các lệnh20Flutter tests vàNode8/13/5 nằm trong [reportB3b](../test-reports/FEAT-TN-001-native-rate-scenario-2026-10-31.md). Chúng không thay các bước App ở trên.

### 5f. Kiểm thử rate limit tự động trên Android emulator

1. Chờ mọi lượt fixture/SDK trước terminal và cleanup. Chỉ giữ một AVD được chọn với đúng ID `emulator-5554`; dùng `Nexa_Auth_API24` cho Android7/API24 hoặc `Pixel_7` cho Android16/API36. Kiểm `adb devices -l` và `adb -s emulator-5554 shell getprop ro.build.version.sdk` bằng executable ở5a, ghi đúng OS của lượt. Docker canonical phải sẵn sàng.
2. Nếu main đang chạy, mở **Android Settings → Apps → Nexa IoT → Force stop → OK**. Giữ data, không chọn Clear data hoặc Uninstall. Harness yêu cầu package không còn process và sẽ từ chối nếu main vẫn sống; không tự kill theo port/PID hoặc bỏ gate. Dùng terminal SDK có quyền hiện hành.
3. Tại root dự án chạy đúng lệnh không thêm argument.

```powershell
Set-Location 'D:\CODE\DO_AN\DO_AN_3'
node ops/auth/run_native_rate_e2e.mjs
```

4. Runner tạo credential chỉRAM và fixture tạm, kiểm TLS/API/UI thật. Theo dõi sáu lần sai, card429 và countdown. Nó quan sát thời gian thực ít nhất900s theo plan rồi mới thử password đúng và logout. Giữ nguyên job trong lúc chờ.
5. Kết quả tổng cần `NATIVE_RATE_OWNED_TERMINAL_ORCHESTRATION_PASS` và exit0 sau exact counters/session/PID, SDK/proxy/fixture terminal cùng cleanup readback. Marker target/SDK riêng chỉ chứng minh từng bước. Deadline/failure vẫn phải chờ owned cleanup, giữ journal nếu chưa xác nhận.
6. Khi lệnh đã terminal và cleanup được xác nhận, khôi phục main bằng lệnh bên dưới. Màn **Ứng dụng chưa sẵn sàng** là kết quả đúng vì fixture/certificate của harness đã được dọn. Muốn test tay, mở backend/proxy mới theo2–5a.

```powershell
Set-Location 'D:\CODE\DO_AN\DO_AN_3\mobile'
& 'C:\src\flutter\bin\flutter.bat' run --no-pub --no-resident -d emulator-5554
```

7. Root và independent repeat có kết quả riêng, theo đúng OS/source manifest. Không dùng PASS API36 thay một lượt API24 hoặc máy thật chưa chạy.

## 6. Chạy các ca App khi phần5 đã sẵn sàng

| Ca | Thao tác | Kết quả cần thấy |
| --- | --- | --- |
| A01 full | Login account full → chờ → chọn A → Đổi workspace → chọn B → Đăng xuất | Sau lưu phiên ACK mới bootstrap; picker không tự chọn; mỗi selection phải đợi server; logout chỉ về login sau revoke/delete ACK |
| A02 limited | Login account limited → đổi password → login lại | Chỉ đổi password/logout trước thành công; không có workspace hoặc nút Back mở workspace. Dùng password mới sau đổi; ca này thay trạng thái fixture |
| A03 native Back | Từ summary bấm Back của Android; từ form đổi password full bấm Back | Full trở lại picker qua tải mới; không mở protected frame cũ. Với limited, Back không cấp quyền workspace |
| A04 cold restart | Login full → đóng ứng dụng → mở lại main | Phải kiểm phiên server trước protected UI; không dùng token local làm bằng chứng quyền hiện hành |
| A05 background/resume | Trong bootstrap hoặc summary, ra màn hình chính Android rồi mở App lại | Khóa/recheck trạng thái trước hiển thị lại protected content; không dùng callback cũ |
| A06 offline/unknown | Khi có lỗi mạng, dùng Kiểm tra trạng thái; nếu có Đăng xuất, thử đúng action đó | Recovery không coi offline là empty/logout, không tự lặp POST hoặc mở workspace khi password outcome còn unknown |
| A07 countdown | Tái hiện429 với account synthetic theo lượt riêng | Hiện countdown, không form submit trong thời gian chờ, hết giờ không autoPOST hoặc nâng limited scope |
| A08 accessibility | Keyboard mở/đóng, portrait/landscape, text200%, sáng/tối; TalkBack trên thiết bị | Không overflow/che control, label/reveal/error đọc và thao tác được; ghi actual OS/device/display |
| A09 disabled/empty | Disabled/password đúng → lỗi chung; account empty/password sai → cùng lỗi; password đúng → empty → Tải lại danh sách → Đăng xuất | Mỗi intent có loading và completion mới; empty chỉ khi danh sách được xác nhận rỗng, create chưa sẵn sàng phải disabled, không mở workspace giả. Có lệnh tự động phần5c |

Checkpoint đã có: A01 và A04 được kiểm actual tự động trên Pixel_7/API36, root và independent instrumented repeat PASS; startup reliability của lượt3997 vẫn mở. A02 có scoped root/independent password PASS theo5d. C1 có chuyển workspace qua UI, không thay ca bấm Back hệ thống A03. A03/A05–A08 vẫn cần actual verification riêng.

Làm trên cả API24 và API36 theo ma trận dự án khi thiết bị có sẵn. Máy thật là gate riêng. Widget tests PASS cho các trạng thái này không được điền thay actual device results. Lỗi secure storage/key loss/backup cần native fault suite riêng; không xóa dữ liệu ứng dụng thủ công rồi gọi đó là kiểm lost-ACK.

## 7. Web và App cùng hoạt động

1. Dùng cùng account full, login Web và App trong cùng deployment dữ liệu thử.
2. Chọn A ở Web, B ở App; xác nhận mỗi màn đang hiển thị scope được người dùng chọn, không lộ dữ liệu scope khác.
3. Logout Web, giữ App mở rồi resume/đối soát. Logout một session không được giả thành logout session khác. Làm ngược lại bằng một session Web mới để kiểm App logout.
4. Trường hợp **đổi password** có quy tắc revoke khác logout một phiên; không dùng ca đó làm bằng chứng session independence.
5. Hai tab Web cùng profile chia sẻ cookie. Thử marker invalidation cần đọc đúng hành vi recovery/active confirmation, không coi hai tab là hai session độc lập giống Web và App. Không mở DevTools để chép cookie/token vào report.

## 8. Kết thúc và cleanup

Các bước này dành cho lượt manual Terminal A/B/C/D. Harness5b–5f tự sở hữu cleanup của nó; vẫn phải giữ lệnh tới terminal và kiểm các marker tương ứng.

1. Đăng xuất trên Web và App nếu kết nối còn hoạt động. Ghi riêng trường hợp logout unknown, chưa coi màn login là server revoke đã ACK.
2. **Terminal D — Flutter:** nhấn `q` để dừng lượt `flutter run` tương tác và chờ trả prompt. Không chạy lượt SDK mới khi lượt này còn sống.
3. **Terminal C — HTTPS proxy:** gõ `STOP` rồi Enter. Chờ `LOCAL_HTTPS_PROXY_STOPPED` và terminal trả prompt. Proxy dừng không tự cleanup dữ liệu DB.
4. **Terminal A — Backend:** nhấn Ctrl+C một lần, chờ launcher dừng child và cleanup graph fixture/thu hồi role của chính lượt. Không đóng cưỡng bức terminal ngay sau khi nhấn. Role hết hạn1giờ không thay bước này.
5. Nếu launcher báo shutdown/cleanup chưa xác nhận, giữ ownership journal và ghi BLOCKED_CLEANUP. Không xóa journal, hàng loạt role/table hoặc audit chung để làm xanh. Manual E2E cần readback đúng ownership; chưa có readback thì ghi CLEANUP_NOT_VERIFIED, không tự điền8zero.
6. **Terminal B — Web:** Ctrl+C khi không cần xem Web nữa, rồi đóng các tab QA riêng. Nếu Vite là server đã có trước lượt của bạn thì chỉ dừng khi bạn là người sở hữu nó. Trả airplane mode, rotation/font scale về trạng thái ban đầu đã ghi ở đầu lượt.
7. Muốn để App ở main mặc định sau cleanup, dùng lệnh restore cuối5f. Main không có origin phải hiện config gate; lần manual tiếp theo cần certificate mới theo5a. Không đọc file token hoặc password để xác minh trạng thái.

## 9. Ghi báo cáo

Tạo report mới trong `docs/test-reports` hoặc bổ sung đúng report của lượt hiện tại. Ghi: HEAD + dirty files/SHA, thời gian, browser version, device/OS/API, HTTPS origin không secret, các terminal commands thực chạy, từng case PASS/FAIL/BLOCKED/NOT_RUN, expected/actual, evidence DOM/video/log đã lọc và cleanup status. Với FAIL, ghi bước cuối đã ACK để phân biệt lỗi UI, API, storage và outcome unknown. Không ghi password/token/cookie/authorization header hoặc raw request chứa credential.

Nguồn đối chiếu: [feature plan](../plan/features/FEAT-TN-001-dang-nhap-web-app.md), [tiến độ](../plan/implementation-progress.md), [Web runtime](../test-reports/FEAT-TN-001-web-browser-2026-10-28.md), [App handoff](../test-reports/FEAT-TN-001-android-application-2026-10-28.md), [QA design/review](../test-reports/FEAT-TN-001-android-application-independent-2026-10-28.md). Docs/reports hiện ignored/local theo `.gitignore`; chưa được commit cùng source.


Checkpoint controller06/11. Helper Web mã hóa credential đã source/host accepted, actual helper/Chrome API chưa chạy vì runtime CUA và JavaScript cùng lỗi kernel assets trước discovery. Các ca browser ngày06/11 trước gián đoạn vẫn gắn đúng scope trong report. [Current helper và technical blocker](../test-reports/FEAT-TN-001-browser-private-handoff-2026-11-06.md).

## 10. Ca mất response và quyền workspace thay đổi

Lượt08/11 root đã kiểm fault response200 và stale membership ở Web với API thật. Đọc [report scoped](../test-reports/FEAT-TN-001-web-response-loss-r2-and-stale-2026-11-08.md) để biết giới hạn và source/controller hash. Dừng backend trướcsubmit ởW05 chỉ kiểm unavailable. Muốn kiểm commit-loss phải chạy controller trong CUA, giữ đúngrequest/status/deadline và persisted DB oracle. Các thao tác sau dành cho Tester theo dõi UI trong lượt harness đã được dựng.

1. Khi response login bị cắt, chờ **Xác nhận trạng thái phiên**. Workspace chưa được mở. Reload vẫn cần xác nhận, không tự gửi loginPOST.
2. Bấm **Đối soát phiên hiện tại**. Nếu tìm được phiên, nút **Xác nhận tiếp tục phiên này** phải xuất hiện trước picker. Nhấn xác nhận rồi mới chọn workspace. Nếu không tìm được phiên, giữ recovery và dùng **Đăng nhập lại** chủ động.
3. Trong ca membership stale, harness chỉ suspend B của account synthetic sau khi picker đã tải. Chọn B cũ phải nhận thông báo không còn quyền, chưa mở summaryB. Đối soát/xác nhận lại, picker chỉ còn A. ChọnA phải thành công.
4. Đăng xuất và chờ form. Harness phải đối chiếu exactsession/revoke, cleanup và terminal, không đánh PASS chỉ từ ảnh. Independent runtime repeat và các nhánh A/Bcookie/tab/App vẫn cần lượt riêng.

## 11. Kiểm offline và reconnect trên App bằng tay

Main đã được khôi phục sau lượt tự động nên đang thiếu API origin. Trước khi thử, mở backend, HTTPS proxy và chạy main bằng certificate mới theo phần2 và5a. Dùng đúng email và mật khẩu TEST của Terminal A trong lượt hiện tại. [Báo cáo offline và stale membership](../test-reports/FEAT-TN-001-api24-offline-and-stale-2026-11-08.md).

1. Đợi App hiện form **Đăng nhập**. Mở bảng Quick Settings của emulator, ghi lại trạng thái airplane mode ban đầu. Chỉ dùng emulator dành cho kiểm thử.
2. Bật airplane mode, quay lại App. Nhập email và mật khẩu TEST hợp lệ rồi bấm Đăng nhập một lần. Chờ kết quả. Mong đợi thông báo **Mất kết nối**, form bị khóa và workspace chưa mở. Cần kiểm kết quả transport, vì riêng biểu tượng airplane chưa đủ chứng minh endpoint không truy cập được.
3. Tắt airplane mode về OFF, quay lại App và quan sát trong khoảng30giây, chưa nhập hoặc submit. App phải chờ thao tác chủ động, chưa tự mở workspace. Ghi thời gian và kết quả UI. Muốn kết luận không có POST phải có request counter hoặc network evidence riêng.
4. Nhập lại email và mật khẩu, chủ động bấm Đăng nhập. Mong đợi picker có A với quyền quản trị viên và B với quyền thành viên. Chọn workspace còn quyền, rồi Đăng xuất và chờ về form.
5. Khôi phục cài đặt mạng ban đầu và cleanup Terminal A/C theo phần8. Nếu kết quả hoặc cleanup chưa rõ, ghi UNKNOWN hoặc NOT_VERIFIED kèm bước cuối quan sát được. Giữ dữ liệu App để còn điều tra và tái hiện.

Ca quyền stale cần harness synthetic đã xác nhận ownership. Root đã thử suspend B sau khi picker tải, App từ chối lựa chọn B cũ, tải lại chỉ còn A và chọn A thành công. Lượt này có UI/session evidence, exact HTTP Android và lượt độc lập còn mở.

## 12. Instrumentation HTTP dành cho Tester

H1/H2 đã được nối proxy/CLI. Root đã sửa raw saturation theo review độc lập và kiểm lại transport/CLI. Independent final source/host review đã accepted ngày10/11 với11suite exit0. Main App H2 đã có HTTP401 và Web control trong cùng fixture, offline/stale full còn INCOMPLETE theo phần13. Để mở Web/App kiểm bằng tay, tiếp tục các phần2–8. Các bước dưới phục vụ lượt lấy HTTP evidence sau checkpoint review của plan. [Report H2, lệnh host và giới hạn](../test-reports/FEAT-TN-001-http-observer-h2-2026-11-10.md).

### 12a. Kiểm helper trước lượt actual

1. Dừng mọi lượt manual fixture/proxy bằng terminal sở hữu. Hai suite CLI dùng3000/8443, phải chạy khi port trống và tuần tự.
2. Tại root repo, chạy từng lệnh và chờ trả prompt với exit0.

```powershell
Set-Location 'D:\CODE\DO_AN\DO_AN_3'
node --unhandled-rejections=strict ops/auth/test_http_metadata_capture.mjs
node --unhandled-rejections=strict ops/auth/test_http_metadata_control.mjs
node --unhandled-rejections=strict ops/auth/test_observed_https_proxy.mjs
node --unhandled-rejections=strict ops/auth/test_local_https_proxy.mjs
node --unhandled-rejections=strict ops/auth/test_observed_proxy_cli.mjs
node --unhandled-rejections=strict ops/auth/test_proxy_terminal.mjs
```

3. Các suite lần lượt công bố8/6/6/24/9/2markers, suite default cuối cùng còn ghi19base/27observercases. Đây là host synthetic. Nếu port đang có listener, giữ FAIL/BLOCKED để kiểm ownership thay vì kill process đang chạy.
4. So hash manifest H2 trước review hoặc actual. [Manifest](../test-reports/evidence/feat-tn-001-http-h2-manifest-2026-11-10.json).

### 12b. Mở observed proxy cho lượt main mới

1. Sau final source acceptance theo plan, mở Terminal A backend mới theo phần2. Mở Web theo phần3 khi cần cùng dữ liệu. Dùng email và mật khẩu TEST của chính lượt này.
2. Với ca offline, tại Terminal C thay lệnh proxy ở5a bằng lệnh sau.

```powershell
Set-Location 'D:\CODE\DO_AN\DO_AN_3'
node ops/auth/local_https_proxy.mjs --observe-http
```

3. Chờ READY và AUTH_LAB_CA_CERT. Dùng public certificate mới để chạy main ở Terminal D theo5a. Không restart proxy giữa các snapshot, mỗi proxy có ledger/cert riêng.
4. Khi kiểm staleB, cần UUID B synthetic đã đối chiếu ownership từ fixture hiện tại. Khởi động đúng một proxy với target trước chạy main.

```powershell
$targetWorkspaceId = Read-Host 'UUID workspace B synthetic da xac nhan ownership'
node ops/auth/local_https_proxy.mjs --observe-http "--target-workspace=$targetWorkspaceId"
```

5. UUID target chỉ phục vụ matcher trong RAM. Bước suspend membership vẫn cần harness đã xác nhận run/account/workspace/revision và commit trước click. UUID truyền argv chưa phải quyền mutation. Target từ report cũ không dùng lại.
6. Tại Terminal C, gõ STATUS rồi Enter để lấy SNAPSHOT. Mỗi request có REQUEST/STATUS/CLOSED tự xuất khi transport thực sự đi qua proxy. Cùng requestId là một connection, sequence liên tục là thứ tự event trong cùng proxy.
7. Giữ original terminal/output tới STOP, FINAL và actual exit code. Mật khẩu TEST chỉ nhập trong prompt kín của backend hoặc form UI. Terminal C chỉ nhận STATUS và STOP.

### 12c. Ghi evidence offline, reconnect và stale

1. Trước thao tác, lấy STATUS. Fence dùng healthy=true, proxyAvailable=true, rawActive=0, active=0 và incomplete chưa tăng chưa rõ nguyên nhân. Giữ request totals/byKind/sequence/elapsedMilliseconds cùng thời gian thao tác UI.
2. Offline theo phần11 phải có kết quả Mất kết nối và session oracle. Lấy STATUS sau lỗi, restore mạng về trạng thái ban đầu, rồi lấy STATUS trước/sau cửa sổ quan sát30giây cùng UI. AUTH_LOGIN không được tăng khi chưa explicit submit, ledger không được có gap/reset hoặc proxy restart. Chỉ ảnh chụp và biểu tượng airplane chưa đủ.
3. Explicit retry mới phải có AUTH_LOGIN của đúng lượt, status/close và exact session/audit mới phù hợp UI. Missing status hoặc incomplete tăng cần ghi UNKNOWN và đối soát session, chưa suy thành login thất bại hay thành công.
4. StaleB cần snapshot sau picker, membership commit có chứng cứ trước click, rồi WORKSPACE_DETAIL matchesTarget=true với status từ API cùng UI denied. Reload picker chỉ A, chọn A còn quyền và logout đúng phiên. Generic detail hoặc target=false chưa đủ kết luận B.
5. STATUS là status line của upstream, CLOSED là transport terminal. Chúng cần được ghép với UI/session/membership của cùng run để kết luận nghiệp vụ.

### 12d. Kết thúc và nhánh lỗi

1. Logout trong UI nếu kết nối cho phép, rồi dừng Terminal D bằng q. Tại Terminal C gõ STOP và Enter.
2. Chờ FINAL có healthy=true, sealed=true, proxyAvailable=false, rawActive=active=0, rồi STOPPED và original command trả exit0. FINAL còn provisional tới stdout ACK và process terminal. Nếu có LOCAL_HTTPS_PROXY_FAILED hoặc exit1, giữ failure và kiểm owned cleanup.
3. Ctrl+C Terminal A, giữ launcher tới terminal và cleanup/readback8nhóm0 của chính lượt. Proxy STOP chưa cleanup DB. Restore main/cấu hình mạng theo phần8, ghi riêng trạng thái thiếu API origin sau cleanup.
4. Partial EOF, lệnh sai/quá dài, stdout backpressure/EPIPE, raw saturation và protocol unsupported làm observed CLI fail-closed. Khi đã lỗi, dùng lượt fixture/cert/evidence mới sau cleanup để tái hiện, không nối snapshot của hai proxy.
5. Kết quả App/Chrome mới chỉ được điền theo ca actual đã chạy. Independent repeat và các gate toàn feature vẫn theo feature plan.

## 13. Kết quả runtime H2 ngày10/11 và cách đọc

Lượt manual đầu có UI offline/seed-onlyDB và zero ledger, nhưng fixture hết20phút trước canary thành công nên giữ INCONCLUSIVE. Lượt retry ghi App AUTH_LOGIN401 qua TLS/H2 và UI auth-invalid. Cùng credential fixture Web login/logout thành công, có exactWebUUID/revoke riêng. Chưa xác định nguyên nhân nhập App401. CUA dừng do input ngoài phiên, các native actual offline/stale đầy đủ còn mở. [Report retry và evidence](../test-reports/FEAT-TN-001-api24-http-control-2026-11-10.md).

Main mặc định đã build/run rồi detach SDK sau cleanup, ADB xác nhận PID4847/MainActivity foreground/API24, airplane0. UI restore chưa quan sát lại. Để kiểm login bằng tay, vẫn mở fresh backend/proxy/main theo phần2/5a, dùng certificate/password của chính lượt. Build main không API origin là configuration gate.

Kịch bản integration mới cho stale/offline đang ở PLAN, chưa có CLI để Tester chạy. Các lệnh5b–5f hiện có giữ scope đã mô tả, chưa tự kiểm thêm membership suspend giữa picker hoặc route-offline. [Review dependency native integration](../test-reports/FEAT-TN-001-native-offline-stale-integration-plan-2026-11-10.md).

## 14. Native membership support checkpoint10/11

S1a checkpoint gate đã có11focused tests và fullFlutter173/173. S1b1 chỉ resolve target B read-only qua private fixture,9case mới trong regression44/44. Chưa có CLI membership-stale, SUSPEND_B hoặc native scenario/host gate hoàn chỉnh. Independent source review còn chờ quota tester, trạng thái READY_FOR_QA. [Report và lệnh kiểm](../test-reports/FEAT-TN-001-native-membership-support-2026-11-10.md).

1. Tại root repo chạy `python -X utf8 -B -m unittest ops.auth.test_native_lab_fixture ops.auth.test_native_cleanup -v`, expected44tests. Các case mới dùng fake SQL.
2. Tại mobile chạy `flutter test --no-pub test/tool/native_membership_probe_test.dart`, expected11tests. Kiểm gate là host tests, chưa xác nhận UI native stale.
3. Muốn mở Web/App thật, thực hiện lại phần2–8 từ fixture mới. Listener check09:39UTC10/11 không còn5173/3000/8443, nên không dựa vào trạng thái Vite của báo cáo trước. Dùng credentials/cert của Terminal A trong chính lượt mới.
4. Task kế là guarded SUSPEND_B/CAS/readback/drain, Node factory/host gate rồi native scenario và actual B404/A200/session/logout/8zero. Các residual gates ở feature plan vẫn áp dụng.

5. Projection B read-only đã được root kiểm qua fixture thật và cleanup8zero. Muốn lặp đúng scope này, tại root chạy `python -u -X utf8 -B docs/test-reports/evidence/feat-tn-001-membership-target-live-probe-2026-11-10.py`, giữ process tới `LIVE_MEMBERSHIP_TARGET_SCOPE_PASS` và exit0. Driver tạo fresh fixture rồi tự STOP/cleanup, không mở App hoặc chạy native stale. Nếu thiếu terminal/8zero thì giữ FAIL hoặc UNCONFIRMED.

## 15. Owned membership suspension S1b2,10/11

SUSPEND_B đã có trong private Python shim của profile membership-stale. Node factory và native phase tương ứng chưa được mở. Source đang READY_FOR_QA, independent review và mutation DB thật chưa chạy. [Report, scope và evidence](../test-reports/FEAT-TN-001-membership-suspend-2026-11-10.md).

1. Tại root chạy `python -X utf8 -B -m unittest discover -s ops/auth -p 'test*.py' -v`, expected65cases.
2. Chạy riêng `python -X utf8 -B -m unittest discover -s ops/auth/tests -p 'test*.py' -v`, expected88cases. Tổng153distinct hostcases, các dependency process/SQL là fake.
3. Case mới cần kiểm gồm wrong ownership/CAS shape/overflow, replay, thiếu commit/readback, STOP race, slow spawn/late marker, backend còn sống và launcher giữ graph khi drain thất bại.
4. Web/App test bằng tay vẫn theo phần2–8 với fresh fixture, không coi source SUSPEND_B là bằng chứng native stale đã đạt. Actual mới cần B404matchesTarget, A200, same session/logout, original terminal và8zero sau independent source gate.
5. Task kế là Node factory strict methods/frames/deadline và native scenario/host async oracle. Lệnh CLI membership-stale chưa có ở checkpoint này.


## 16. Node membership factory S2a,10/11

Node factory đã có membershipTarget/suspendMembershipB và strict profile membership-stale. Host51markers cùng actual read-only target/snapshot/close đã đạt root. SUSPEND_B PostgreSQL thật và native UI vẫn chờ independent source review, trạng thái READY_FOR_QA. [Report và evidence](../test-reports/FEAT-TN-001-membership-node-2026-11-10.md).

1. Tại root chạy `node ops/auth/test_native_membership_fixture.mjs`, expected14markers/exit0. Đây là host fake-boundary tests.
2. Scoped read-only thật có thể lặp từ root bằng `Get-Content -Raw -LiteralPath 'docs/test-reports/evidence/feat-tn-001-membership-node-read-only-driver-2026-11-10.mjs.txt' | node --input-type=module -`. Driver tạo fresh fixture rồi tự close, expected NATIVE_MEMBERSHIP_NODE_ACTUAL_READ_ONLY_PASS/exit0. Giữ terminal tới cuối, cổng3000 phải trống.
3. Driver chỉ đọc target B và seed session, chưa mở App hoặc gọi suspend. Không dùng kết quả này để đánh PASS native stale hoặc mutation/CAS/commit-loss.
4. Native CLI membership-stale vẫn chưa có. Task kế phải chốt budget/session oracle trước scenario, vì tổng snapshot130s/suspend20s/RPC30s/headroom20s vượt picker180s hiện tại.
5. Web/App mở bằng tay tiếp tục theo phần2–8 từ fresh fixture, dùng password/cert của chính lượt đó. Các residual gates trong feature plan vẫn giữ nguyên.


## 17. Picker budget và session/audit S2b,10/11

Picker test-only cap đã210s, fast pauses5s. Private factory có membershipSessionEvidence để đọc sessions/audit của account0 trong cùng SQL snapshot. Host/fullFlutter và actual read-only seed-login-audit đã đạt root, independent/native UI và actual suspension vẫn chờ, trạng thái READY_FOR_QA. [Report đầy đủ](../test-reports/FEAT-TN-001-membership-budget-audit-2026-11-10.md).

1. Tại mobile chạy `flutter test --no-pub test/tool/native_membership_probe_test.dart`, expected11cases, fullFlutter hiện173cases.
2. Tại root chạy hai Python discover paths như phần15, expected71+88cases, và `node ops/auth/test_native_membership_fixture.mjs`, expected17markers.
3. Scoped sessions/audit read-only thật có thể lặp bằng `Get-Content -Raw -LiteralPath 'docs/test-reports/evidence/feat-tn-001-membership-evidence-read-only-driver-2026-11-10.mjs.txt' | node --input-type=module -` từ root. Giữ terminal tới NATIVE_MEMBERSHIP_SESSION_AUDIT_READ_ONLY_PASS/exit0. Driver tạo fresh fixture rồi tự close, không cần nhập password.
4. Seed LOGIN_SUCCEEDED cùng UUID chưa chứng minh App login/logout hoặc native stale. Native CLI membership-stale chưa có. Task kế là native scenario/host async/session delta/audit/H2, rồi independent source gate trước actual suspend.
5. Web/App mở bằng tay vẫn theo phần2–8 từ fixture mới. Các runID/UUID trong report đã cleanup và không dùng lại làm quyền mutation.
## 18. Checkpoint native membership producer, 10/11/2026

Source S2c1 đạt ROOT_SOURCE_HOST_PASS/READY_FOR_QA, whole feature INCOMPLETE. Host suite dùng API/store synthetic, chạy UI/coordinator/repository sản phẩm. Chưa là emulator/DB acceptance. [Report và logs](../test-reports/FEAT-TN-001-membership-scenario-2026-11-10.md).

### Tái hiện host regression

1. Mở PowerShell tại `D:\CODE\DO_AN\DO_AN_3\mobile`.
2. Chạy `C:\src\flutter\bin\flutter.bat test --no-pub --reporter expanded test/tool/native_membership_scenario_boundary_test.dart`.
3. Kỳ vọng9tests PASS, gồm luồng UI positive và các ca bị producer chặn tại sai role, B mở sai, list refresh cũ, epoch đổi và phase timeout.
4. Chạy `C:\src\flutter\bin\flutter.bat test --no-pub --reporter expanded` để kiểm regression toàn mobile. Lượt root đã chạy182PASS.

### Luồng actual cần kiểm tiếp sau host bridge

1. Warm backend/SDK/AVD trước fresh fixture, xác minh đủ work budget. Chỉ account/workspaces synthetic thuộc owned run được mutation.
2. App mở login, form rỗng. Host kiểm baseline tại membership-before-login, ACK để App nhập synthetic email/password qua UI.
3. App render A/Quản trị viên và B/Thành viên. Tại membership-picker host lấy mid sessions rồi commit/readback membership B SUSPENDED. Chỉ ACK sau owned receipt đúng target/version và còn thời gian.
4. App tap B cũ. Kỳ vọng detail404RESOURCE_NOT_FOUND, màn “Không thể truy cập workspace”, không dữ liệu/cache B và có “Tải lại danh sách”. Host đối chiếu HTTP counters trước ACK membership-denied.
5. App tap tải lại, thấy duy nhất A cùng UUID/Admin. Checkpoint membership-only-a cần GET list đúng số lần và không login POST mới.
6. App tap A, summary đúng account/A/Quản trị viên. Checkpoint membership-a-opened cần detailA200 trong cùng App session.
7. App tap đăng xuất, form email/password rỗng và protected state hết. Checkpoint membership-logged-out cần đúng logout intent.
8. Host lấy final sessions/audit, kiểm đúng một AppUUID mới đã revoked, seed không đổi, LOGIN_SUCCEEDED và LOGOUT SUCCESS/ANDROID cùng AppUUID. SDK stop/original exit0, native PID absent, proxy và fixture original terminal/8zero mới cho phép scoped PASS.

CLI host membership-stale vẫn chưa được mở ở checkpoint này. Không chạy bằng cách tự sửa phase hoặc bỏ checkpoint. Async bridge/orchestrator và independent source review còn dependency trước actual mutation. Picker210s, năm pause5s, native420s là test budgets, không dùng làm UX SLA.


## 19. Checkpoint timed async host bridge, 10/11/2026

S2c2a đạt ROOT_SOURCE_HOST_PASS/READY_FOR_QA trên Node host. Chạy `node ops/auth/test_native_membership_consumer.mjs` tại repo để tái hiện24markers gồm budget và23modes. SDK/PID/clock ở suite đều synthetic. Không cần DB, không mở emulator hoặc Chrome. [Report,9suites và mutation evidence](../test-reports/FEAT-TN-001-membership-consumer-2026-11-10.md).

Host đã kiểm reserve895 trước SDK spawn, startup180/channel60/native420, picker210/fast5, shared ACK30 và final oracle130. Pending callback phải giữ consumer chưa return dù SDK fake đã terminal, stale admission không được phát late effect. Startup-late log APP_STOP_UNCONFIRMED/CLEANUP_FAILED là nhánh failure mong đợi, không đọc chữ PASS cuối mode như actual app cleanup.

CLI membership actual vẫn đóng. Task kế là S2c2b orchestration1165s admission, external proxy/fixture abort fanout/close ordering, H2 exact counters/status/close và session/audit oracle. Chỉ sau review mới chạy luồng actual của section18. Mọi mục actual PostgreSQL mutation, emulator stale/offline và independent final review còn mở.


### 19.1. External hardening và SDK preflight bổ sung

Focused consumer hiện29markers gồm28modes, tổng83markers của9Node suites. Năm ca external abort mới đều host fake. Actual node ops/auth/run_native_e2e.mjs --preflight trên API24 đã terminal478901 exit0 và app.stop/SDKexit0/postPID absent. Đây là build/channel/stop proof, chưa là login API hoặc stale membership.

AVD Nexa_Auth_API24 được khởi động headless, owned78839 còn giữ warm tại checkpoint này. Không có cửa sổ App để visual QA từ headless preflight. Native membership CLI vẫn đóng tới orchestration/review. Sau mọi actual run phải giữ ownership SDK/proxy/fixture tới original terminal, pending I/O hết và readback8zero trước mở fixture mới. [Report/hardening/preflight](../test-reports/FEAT-TN-001-membership-consumer-2026-11-10.md).


## 20. Self-test với DB thật, 10/11/2026

Root đã tự chạy actual API24 và PostgreSQL canonical bằng ba lệnh dưới đây. Giữ AVD Nexa_Auth_API24 ở emulator-5554, chờ mỗi lệnh cleanup/terminal rồi chạy lệnh kế.

~~~powershell
Set-Location 'D:\CODE\DO_AN\DO_AN_3'
node ops/auth/run_native_e2e.mjs --full-session
node ops/auth/run_native_e2e.mjs --access-cases
node ops/auth/run_native_e2e.mjs --password-cases
~~~

Các lượt root đều exit0 cùng original cleanup. Full kiểm A/B→coldresume→logout, access kiểm disabled/wrong/empty/refresh/logout, password kiểm limited/validation/currentwrong/change/coldreloginold-new/logout. Provider thật có176checks với163 ID khác nhau bằng lệnh dưới.

~~~powershell
python -X utf8 -B ops/auth/run_local.py --verify --port 3000
~~~

Host regression đạt Flutter182/analyzer, Rust40, Python71+88, contract26, Node117markers. Independent Web auth25/typecheck và Vite build RAM đạt, browser UI actual BLOCKED do kernel assets os3. Independent Node review đã bắt lỗi pending cleanup, root sửa và retest accepted scoped host. [Report đầy đủ, source version và terminal receipts](../test-reports/FEAT-TN-001-self-testing-real-db-2026-11-10.md).

Root đã restore main APK và shutdown owned headless AVD sau kiểm. Flutter install gỡ bản debug cũ trước cài lại nên App data trên AVD có thể đã xóa, storage forensic vẫn chưa xác minh. Các kết quả coldresume lấy trước bước đó. Listener lab hiện vắng, PostgreSQL canonical còn. Để test thủ công tiếp, thực hiện phần2–8 với fixture/password TEST mới. Native membership CLI và whole-feature acceptance vẫn chưa đạt.

## 21. Probe membership thật sau cancellation fix ngày11/11

Source operation/control đã có guard lifecycle live sau startup và sát admission UPDATE, independent review/retest đạt. Root đã chạy positive probe PostgreSQL thật và cleanup exit0. Probe này kiểm capability target→baseline→suspend→final→cleanup, chưa thực hiện UI stale/offline. Từ repo root, chạy lệnh dưới khi canonical Docker đang hoạt động và không có auth lab khác giữ role/port3000.

~~~powershell
Get-Content -Raw -LiteralPath 'docs/test-reports/evidence/feat-tn-001-membership-real-db-driver-2026-11-11.mjs.txt' | node --input-type=module
~~~

Chờ MEMBERSHIP_REAL_DB_POSITIVE_PROBE_PASS và MEMBERSHIP_ORIGINAL_CLEANUP_PASS/originalExit0 cùng command exit0. Driver tự sinh credential chỉ trong RAM và tự cleanup. Nếu FAILED hoặc cleanup chưa xác nhận, giữ log/stage và không replay cùng mutation outcome chưa rõ. STOP đã quan sát trước admission chặn UPDATE, STOP sau guard được xem là in-flight/unknown và vẫn phải drain. [Report/lệnh/hash/giới hạn](../test-reports/FEAT-TN-001-membership-cancellation-fix-2026-11-11.md).

## 22. Android stale membership E2E với DB thật

Lượt root và tester độc lập ngày11/11 đều đạt trên API24. Đây là automation nhập/tap trong main App cùng backend/SQLx/PostgreSQL và oracle HTTP/session/audit. Chọn AVD Nexa_Auth_API24, chờ boot và kiểm đúng emulator-5554 theo phần5a. Dừng các lab trước đó sau terminal/cleanup, đảm bảo port3000/8443 và writer role không bị một lượt khác giữ.

Tại repo root, chạy preflight để warm SDK, chờ exit0/App stop rồi chạy lệnh stale. Coordinator tự tạo certificate và fixture TEST, giữ password trong RAM, chốt đủ lifetime trước SDK và cleanup sau run.

~~~powershell
node ops/auth/run_native_e2e.mjs --preflight
node ops/auth/run_native_membership_e2e.mjs --stale
~~~

Luồng tự động đăng nhập, giữ picker có A/B, đình chỉ B ở DB, bấm B từ picker cũ, xác nhận không mở protected content, tải lại chỉ còn A, mở A và đăng xuất. Kết quả cần có NATIVE_INTEGRATION_TARGET_MEMBERSHIP-STALE_PASS, NATIVE_SDK_APP_STOP_CHILD_EXIT_PASS và NATIVE_MEMBERSHIP_ACTUAL_OWNED_TERMINAL_PASS cùng exit0. Budget thiếu, bind quá hạn hoặc oracle sai phải FAIL. Giữ process handle tới terminal khi có UNCONFIRMED, không suy từ timeout quan sát rằng process đã dừng. [Report, nhánh lỗi và evidence độc lập](../test-reports/FEAT-TN-001-membership-orchestration-2026-11-11.md).

Để kiểm bằng mắt, dùng App mở từ main theo phần5 và fixture/password TEST của runbook, thay vì lấy tài khoản automation đã được cleanup. Android offline và Chrome E2E matrix vẫn có checklist riêng.

## 23. Android network capability probe, chưa là offline acceptance

Tại repo root và đúng AVD `Nexa_Auth_API24`/emulator-5554 đã boot, đảm bảo3000/8443 chưa bị lab khác giữ, chạy:

~~~powershell
node ops/auth/run_native_network_probe.mjs --modem-feasibility
~~~

Giữ process tới terminal và restore readback. Không cần DB hoặc password; upstream là synthetic401, probe không mount main UI. Lượt actual11/11 cho cả ba route REACHABLE khi baseline/off/restored, cuối `NETWORK_MODEM_ROUTE_INEFFECTIVE`; không dùng modem off này để nghiệm thu device offline. [Report, lệnh, receipt và giới hạn](../test-reports/FEAT-TN-001-network-modem-actual-2026-11-11.md). Sau probe cần build/install main lại trước test bằng tay; installer có thể gỡ App cũ và xóa App data AVD. Chrome retry trong lượt này lỗi kernel assets trước inventory, chưa có login business evidence mới.

## 24. Guest Wi-Fi/data capability và preflight bị chặn trên API24

Hai bộ test host không cần DB/emulator, chạy từ repo root:

~~~powershell
node ops/auth/test_native_network_probe.mjs
node ops/auth/test_native_guest_network_control.mjs
~~~

Kỳ vọng mỗi suite19markers/exit0. Đây là fake SDK/settings/route, chưa là offline App. Khi đúng AVD API24 TEST đã boot, `node ops/auth/run_native_network_probe.mjs --guest-feasibility` hiện phải dừng `NETWORK_GUEST_ROUTE_PROBE_FAILED_STAGE_SHELL_WIFI_PERMISSION_NOT_PROVEN` và exit1, trước cert/listener/mutation. Đây là guard harness thiếu capability proof, không phải lỗi form đăng nhập. Không cấp quyền hoặc chạy driver fault lịch sử để vượt guard.

Actual cũ và diagnostic đều exit1. Data bit đổi được nhưng Wi-Fi command fail cả disable/enable; settings về1/1/airplane0, recovery native reachable, restore radio ACK chưa được chứng minh. [Report/evidence và source versions](../test-reports/FEAT-TN-001-guest-network-2026-11-11.md). Để test luồng chính bằng tay, khởi động main và fresh fixture/password theo phần2–8, stale automation theo phần22. Nhánh offline thực tế tiếp tục sau O3 capability API36 và source/actual review; không suy PASS từ việc API không chạy hoặc thiếu kết nối backend.

### 24.1. Cài main APK bằng ADB no-streaming khi cần

Lượt11/11 đã gặp streaming install treo ở staged transfer. Sau khi xác nhận installer/phiên cài cũ đã terminal và không có active install session của run khác, có thể cài main đã build bằng cách này từ thư mục mobile:

~~~powershell
& 'C:\Users\LENOVO\AppData\Local\Android\Sdk\platform-tools\adb.exe' -s emulator-5554 install --no-streaming -r -t 'build/app/outputs/flutter-apk/app-debug.apk'
~~~

Chờ Success/exit0, kiểm package `dev.nexa.nexa_iot` rồi mở App theo phần5 với cấu hình TEST của fresh fixture. Lệnh này đã khôi phục main trong lượt O2, AVD owned sau đó được đóng. Không lấy Session ID/PID trong report để hủy một lượt mới; ID/ownership phải được xác minh từ chính lượt đang chạy. Không chạy cài chồng lên installer chưa có kết quả, không xóa data để chữa timeout. Lần Flutter install trước đó có thể đã uninstall App và xóa data, nên dùng tài khoản/fixture mới theo runbook.

## 25. API36 network capability đã xác minh

O3 đã đạt R→UNAVAILABLE/socket→R qua native TLS cùng proxy/cert, sau tắt và khôi phục mạng guest. Đây là capability proof, login offline/reconnect main UI với DB thuộc O4. [Report/hash/evidence/giới hạn](../test-reports/FEAT-TN-001-api36-network-2026-11-11.md).

1. Mở PowerShell, khởi động đúng AVD `Pixel_7` ở5554. Dùng cold boot/no-snapshot vì lượt trước emulator không lưu được default_boot do dung lượng. Giữ terminal này và mở terminal thứ hai để chạy test:

~~~powershell
& 'C:\Users\LENOVO\AppData\Local\Android\Sdk\emulator\emulator.exe' -avd Pixel_7 -port 5554 -no-snapshot -no-audio
~~~

2. Chờ Android boot xong; xác nhận API36, wifi/data đều bật, airplane tắt, runtime Wi-Fi enabled. Không thay trạng thái ban đầu để vượt guard. Đảm bảo không lab khác giữ3000/8443. Lệnh feasibility tự kiểm name/API/permission/baseline trước fault.
3. Tại terminal thứ hai, từ repo root chạy:

~~~powershell
node ops/auth/test_native_network_probe.mjs
node ops/auth/test_native_guest_network_control.mjs
node ops/auth/run_native_network_probe.mjs --api36-guest-feasibility
~~~

4. Host suites cần19/44markers và exit0. Actual cần3native route observations, OFF/ENABLED confirmations, cuối `NETWORK_API36_GUEST_ROUTE_EFFECTIVE` và exit0. H2 tổng2request/status/closed,incomplete0; off không tăng request. Giữ process tới raw terminal kể cả quan sát timeout, không khởi động một run mới chồng lên run chưa có kết quả.
5. Sau test xác nhận mạng đã về baseline/runtime, App PID absent, ports và owned SDK/proxy đóng. Khôi phục main theo phần24.1 từ APK main đã build rồi mở UI theo phần5/fresh TEST fixture. Native probe target không nhập tài khoản hoặc mở màn login; synthetic401 khác với backend DB thật của các luồng phần2–8.

Wrong AVD/API, thiếu quyền, baseline đổi trong canary, malformed/unknown/duplicate radio, deadline, SDK/restore/cleanup chưa xác nhận đều phải dừng. INEFFECTIVE nghĩa là fault không cắt route và chưa đủ chạy offline business. Không tự thay URL API, tăng timeout, cấp quyền hoặc sửa host network để ép PASS. O4 sẽ kiểm recovery control thật trước explicit login, vì networkUnavailable hiện khóa submit.
