# FEAT-TN-001 — đề xuất dependency Android auth

Trạng thái: **APPROVED_FOR_POC** sau phản hồi “duyêt” của người dùng cho câu hỏi
dependency Flutter secure storage. Chưa nghiệm thu min OS/storage hoặc toàn app.
Ngày2026-10-24. Không thay CP-01/02/03 hoặc storage/device PoC bằng tài liệu.

## Evidence hiện tại

CLI cùng đường dẫn ở sandbox timeout20s; chạy ngoài sandbox trả exit0:
Flutter3.47.5 stable, revision6a19cca56475dbfba1478ee68d7bd0c2ef891da1,
Dart3.13.4, DevTools2.60.0. Không nâng cấp/cài Flutter trong lần probe.
`flutter devices --machine` exit0 thấy Windows/Chrome/Edge, không Android.
`flutter emulators` với wrapper UTF8 xác nhận AVD `Pixel_7` (Google/Android),
chưa biết OS thực tế cho tới khi khởi động. Flag `emulators --machine` không
hợp lệ và wrapper decode lỗi trước đó không được tính là evidence thành công.

## Phạm vi được duyệt cho PoC

- Dùng Flutter3.47.5/Dart3.13.4 đang có; không chạy upgrade.
- Dependency mới duy nhất ngoài Flutter SDK: pin `flutter_secure_storage: 11.2.0`.
  Lock transitive versions qua pubspec.lock sau resolve/review, không dùng caret.
  API networking dùng `dart:io`/`dart:convert`, state dùng ChangeNotifier, test
  dùng flutter_test/integration_test từ SDK; không thêm http/provider/freezed.
- Candidate minSdk24 dựa trên Flutter3.47 support matrix (plugin minimum23).
  Chưa coi là đã hỗ trợ min OS cho tới build/storage/restart/key failure PoC;
  không biết model/OS thiết bị thật nên giữ mục thiết bị là MISSING_INPUT.
- Storage dùng cấu hình Android mặc định RSA OAEP + AES-GCM, không yêu cầu
  biometric permission. Chỉ token/session metadata cần thiết; không password,
  email hoặc bản copy bearer trong preferences/log/clipboard/evidence.
- Tắt cloud backup và khai báo exclusion cho cả cloud/device transfer theo
  version Android; `allowBackup=false` riêng lẻ chưa đủ với một số OEM Android12+.
  Không đoán tên storage file: xác nhận với dependency source/API sau khi được
  duyệt. App mới không có migration từ encryptedSharedPreferences cũ.
- App phải fail closed khi storage write/read lỗi; không login complete trước
  write thành công; revoke token mới best effort, giữ kết quả unknown trung thực.

Nguồn kiểm ngày2026-10-24: [package chính thức](https://pub.dev/packages/flutter_secure_storage)
ghi11.2.0, API/cipher/minimum23; [Flutter supported platforms](https://docs.flutter.dev/reference/supported-platforms)
ghi Flutter3.47 hỗ trợ Android24–37; [Android Auto Backup](https://developer.android.com/identity/data/autobackup)
ghi caveat OEM/device transfer và rule theo OS. Đây là dữ liệu nguồn, chưa là PoC.

## Task theo dependency

| Task | AC tối đa ba mục | Dependency / file / rủi ro |
| --- | --- | --- |
| R9-A parser độc lập | Parse fixture Android full/limited; reject Web/malformed/mismatch; Dart test/analyze PASS, không log token. | Không plugin/DB/device; `mobile/lib/features/auth/data/app_login_response.dart`, `mobile/test/contracts/app_login_response_test.dart`; nhỏ. Chỉ contract consumer, không app hoặc provider evidence. |
| R9-B storage PoC | Scaffold Android theo SDK đang có; plugin/default ciphers + backup exclusions; write/read/delete/restart/key failure trên min OS và OS mới. | Sau phê duyệt dependency và targetAndroid; giới hạn scaffold/config, adapter, focused integration test thành slice≤5file. Không mở P5 storage thật trước PoC. |
| R9-C login thật | Form responsive48dp + repository/viewmodel/service; parse/store trước bootstrap; đủ error/offline/unknown/full/limited states. | R9-A/B, CP-02 và Android device; chia Login, limited/recovery, picker/context thành slice≤5file. API endpoint/TLS theo topology được duyệt, không bỏ TLS production. |
| R9-D acceptance | Cài/run APK, restore/logout/switch và hai session Web/App; tester tái lập, owner/QA review. | R9-C + provider thật + browser/device; CP-03 vẫn mở. |

Rollback R9-A: bỏ module/parser test mới, không đụng Web/backend/contracts.
Phê duyệt dependency không tự chứng nhận package an toàn hoặc storage PoC PASS.

## Cập nhật thực thi

Plugin11.2.0 đã resolve/lock; scaffold/analyzer PASS,42 consumer cases PASS.
APK native test đã build/cài; stage write/read thật trên API36 đạt1test PASS
sau lỗi ADB transport. Chưa có relaunch/read/delete PASS: phát hiện runner mặc
định uninstall sau mỗi lượt, đã sửa command thêm --no-uninstall và kiểm UID/PID.
NDK28.2.13676358, Platform35/36, CMake3.22.1 đã được SDK tools cài để build.
Image API24 Google APIs x86_64 revision27 đã cài; AVD Nexa_Auth_API24 tạo riêng,
không force/overwrite Pixel_7. Min OS/storage/backup/key evidence vẫn chưa đủ.
Chi tiết failure và tester commands: `docs/test-reports/FEAT-TN-001-android-poc-2026-10-24.md`.

Theo phản hồi “bạn tự chọn đi”, chọn ma trận tham chiếu Pixel_7/Android16/API36
và min OS Android7/API24 (AVD Nexa_Auth_API24). Máy thật mục tiêu là Pixel7/
Android16 hoặc cấu hình tương đương trong phạm vi hỗ trợ; chưa có thiết bị thật
kết nối nên không điền model/OS thực tế hoặc physical-device PASS từ lựa chọn này.
Không mua thiết bị, không coi AVD là hardware evidence thay thế.

Native base đã hoàn tất kiểm tự động trên cảAPI24/API36: hai stage riêng giữ
APK bằng --no-uninstall, dừng app/cold boot rồi đọc và xóa marker, UID giữ nguyên;
4cases PASS. Phần này READY_FOR_QA; R9-B tổng vẫn PARTIALLY_VERIFIED vì còn
fault/key/backup/physical device. Không lấy kết quả này làm app login/E2E PASS.

## R9-B2 — kế hoạch adapter lỗi an toàn đã rà soát

Phạm vi tiếp nối approval PoC: hai file adapter/interface và focused test dưới
`mobile/lib/features/auth/data/session_token_store.dart` và
`mobile/test/auth/session_token_store_test.dart`. Không network/UI hoặc token thật.
Dependencies: plugin11.2.0, SDK/test runner và native base đã có; không cần DB.

AC: (1) đọc/ghi/xóa đúng một key phiên, không cache/password/deleteAll; Future
ghi chỉ thành công sau ACK plugin; (2) mọi lỗi boundary thành lỗi cố định theo
operation, read lỗi không biến thành “không có phiên”, không giữ payload gốc;
(3) malformed token bị chặn, focused tests/analyzer PASS, fake channel chỉ là
unit evidence. Thứ tự: RED tests → adapter → GREEN/full unit/analyze → review.

Rà soát API11.2.0 phát hiện `resetOnError` mặc định true. Adapter chọn false để
không tự xóa dữ liệu khi key/storage lỗi, namespace riêng `nexa_auth_session_v1`
để không reset installation proof hoặc dữ liệu khác. Cipher mặc định giữ nguyên.
Nguồn: [AndroidOptions](https://pub.dev/documentation/flutter_secure_storage/latest/flutter_secure_storage/AndroidOptions/AndroidOptions.html),
[Flutter test channel boundary](https://api.flutter.dev/flutter/flutter_test/TestDefaultBinaryMessenger/setMockMethodCallHandler.html).
Rủi ro: write/delete lỗi có thể đã có side effect; adapter không retry/rollback
hoặc tuyên bố revoke. Repository tương lai phải đóng UI và xử lý unknown/generation.
R9-B3 phải kiểm native cấu hình namespace/reset này; PoC mặc định trước đó không
tự chứng nhận cấu hình mới. Rollback: bỏ hai file mới, không sửa dữ liệu thiết bị.
Checkpoint sau B2/B3: rà evidence rồi mới đi tiếp backup/restore; P5 vẫn chưa mở.

R9-B2 source review/verification: RED thiếu module, GREEN6 focused tests;
mutation đổi reset=false→true exit1 rồi restore và full unit7tests PASS (42cases
consumer trong1test), analyzer No issues, format6files0changed. Adapter và test
**READY_FOR_QA**; không app UI/bootstrap/revoke và chưa native configuration
evidence cho namespace/reset mới. Test fake chỉ chặn regression boundary Dart.

## R9-B3a — native cấu hình adapter trước fault injection

Kế hoạch đã rà: thêm `mobile/integration_test/session_token_store_test.dart`,
không sửa adapter/network/UI. Dùng chính SecureSessionTokenStore và một marker
proof tổng hợp ở namespace mặc định. AC: ghi/readback; app dừng/cold boot rồi
đọc/xóa cùng UID trên API24 và36; xóa phiên không mất marker proof riêng.
Mọi key phải rỗng trước stage ghi, nếu khác dự kiến thì dừng, không overwrite.
Chỉ synthetic marker, không deleteAll/clear-data, không đọc file chứa credential.
Evidence: hai filtered native commands --no-uninstall trên từng OS, metadata
OS/AVD/UID trước/sau, log exit code. Scope1testfile + evidence/docs; SDK/AVD/
plugin đã có. Đây chỉ là kiểm cấu hình bình thường; R9-B3b key/fault và B4 backup
vẫn mở. Rollback bỏ test; cleanup chỉ marker đúng giá trị thuộc PoC.

## R9-B3b — key loss native trong test APK riêng

Kế hoạch đã rà: Android Instrumentation chỉ trong `app/src/androidTest/java/`
và cấu hình runner ở `app/build.gradle.kts`, không thêm dependency. Không sửa
MainActivity, không hook phá key vào app debug/release. Native code gọi plugin
11.2.0 trong context target, namespace ngẫu nhiên prefix PoC do test tự sinh;
chỉ được tạo khi alias và ba preference stores tương ứng rỗng. Namespace auth
thật và key mặc định không bị xóa hoặc sửa.

AC: (1) plugin RSA-OAEP/AES-GCM roundtrip marker thành công trước fault;
(2) mất đúng alias test và fresh plugin instance phải báo lỗi, reset=false giữ
nguyên encrypted data, namespace control riêng vẫn đọc được; (3) cleanup chỉ
alias/ba preference stores đã tạo trong lượt sống, cố định theo namespace nội
bộ; output chỉ mã/boolean, không token/payload/exception detail. Mỗi OS chạy
một instrumentation case có các assertion này; đây là native plugin evidence,
không phải Dart/UI auth E2E. Options tương đương adapter trừ namespace PoC.

Thứ tự: thêm runner/test → build/install test APK → invoke scoped instrumentation
trên API36/API24 → đọc terminal result/cleanup → review. Scope2source files,
evidence/docs; dependency SDK/plugin/AVD đã có. Test failure giữ exception cố
định; không broad cleanup/global KeyStore wipe, không retry hay bypass assertion.
Nếu process chết thì ghi orphan namespace có thể còn, không recovery theo
marker do bên ngoài cung cấp. Rollback bỏ test và runner config, không thao tác
test data chưa có ownership evidence. B4 backup/physical vẫn còn gate riêng.
Nguồn exact tag: `FlutterSecureStorageConfig.java`, `NamespacedConfigSource.java`
và `ciphers/KeyCipherImplementationRSAOAEP.java` tại repo chính thức tag
`flutter_secure_storage-v11.2.0`; không đọc package cache. Android runner API:
https://developer.android.com/reference/android/app/Instrumentation.

Kết quả2026-10-25: B3a PASS4 native adapter cases API24/36, cùng UID qua cold
boot và giữ marker kho khác. B3b PASS2OS: fresh native plugin reject key loss,
ciphertext không reset, control namespace đọc được, cleanup=true/code-1.
Mutation reset=true bị bắt code0; source/installed test APK đã khôi phục và
API24 rerun PASS. B3a/B3b READY_FOR_QA, không app/UI/backup/physical acceptance.
Build offline mặc định fail do thiếu ARM engines; dùng target-platform=android-x64
đúng hai AVD build/install PASS, chưa xác minh máy ARM. Report hiện hành:
`docs/test-reports/FEAT-TN-001-android-native-storage-2026-10-25.md`.
Task đủ dependency kế tiếp B4a: quan sát backup policy/admission trên emulator
với marker tổng hợp, không bật cloud transport hoặc gửi dữ liệu ngoài lab.
Giữ B4b restore/physical và CP-02 riêng, không nới gate P5 bằng native PoC.

## R9-B4a — quan sát backup admission trên AVD local

Discovery API24: đúng AVD Nexa_Auth_API24, UID10078, gói app không có
ALLOW_BACKUP; Backup Manager đang disabled, transport đang chọn là built-in
`android/com.android.internal.backup.LocalTransport`. Chỉ đọc flag hoặc gọi
backup khi manager disabled không đủ chứng minh package bị policy chặn.

Kế hoạch đã rà: trên chính AVD lab này, xác nhận lại tên/OS/transport local và
enabled=false; tạm enable backup cho local transport, request chỉ package
`dev.nexa.nexa_iot`, ghi result rồi finally restore enabled=false và kiểm lại.
Không đổi transport, không cloud, không backup --all/restore/wipe, không đọc
archive hoặc credential/preferences. Scope runtime probe + evidence/docs,
không app code/dependency mới. Nếu transport hoặc precondition khác thì dừng.

AC: result per-package phải nói không được backup, không suy từ exit0/global
disabled; state manager sau probe bằng trước; không export dữ liệu ra ngoài
lab. Timeout/transport lỗi là NOT_VERIFIED, không thay assertion bằng success.
Rủi ro host/process chết có thể cần operator restore backup enabled state;
không bỏ qua finally/verification. Sau API24 kiểm inventory API36 trước khi
quyết định local probe tương ứng. Full restore/OEM/device transfer và máy thật
vẫn thuộc B4b, không dùng admission test này đóng gate toàn phần.

API36 discovery: inventory ngay sau boot tạm trả No transports; lần kiểm sau
có local transport `com.android.localtransport/.LocalTransport` và Google
transport đang được chọn, Backup Manager vẫn disabled. Không kết luận thiếu
transport từ probe quá sớm. Kế hoạch API36 đã rà: trong trạng thái disabled,
tạm chọn đúng local component từ allowlist trên; xác nhận star local trước
khi enable, request riêng package PoC, finally disable trước rồi restore
Google transport gốc và xác nhận cả hai state. Nếu không xác nhận local thì
không enable/request. Đây là ngoại lệ đổi transport cho AVD Pixel_7 lab, không
cho API24 hoặc thiết bị thật; không bật cloud backup, không cloud data export.

B4a kết quả: API24 và API36 request riêng app trên local transport đều trả
`Package dev.nexa.nexa_iot with result: Backup is not allowed`. Overall result
Success chỉ nói request xử lý xong, không có nghĩa app được backup. Enabled
state đều khôi phục disabled; API36 chọn lại Google transport gốc chỉ sau khi
đã disabled, API24 giữ nguyên LocalTransport. Evidence riêng hai OS nằm trong
`docs/test-reports/evidence/android-backup-admission-api24/36-2026-10-25.txt`.
Admission slice READY_FOR_QA; không full restore/OEM/D2D/physical PASS.
C0 presentation preview được tách khỏi token/API integration theo quyền user
cho phép mock thiết kế/test; plan/layout/state matrix ở feature001 mục18 UI
slice C0. Không đổi main scaffold hoặc gate C1/P5/CP-02.
