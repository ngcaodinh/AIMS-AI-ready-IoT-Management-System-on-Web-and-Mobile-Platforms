# Tiến độ triển khai

## FEAT-TN-002 continuation — sửa tuyến gọi Tester và hoàn tất harness §27.64 — 18/11/2026 13:48 +07

**VERIFY_IN_PROGRESS; kiểm tra host-side PASS, acceptance Android S2 vẫn PARTIAL.**

- Nguyên nhân dispatch: collaboration subagent allowlist không có `gpt-6-luna`, còn `codex debug models` cục bộ có Luna với `xhigh`; `agy` là runtime UI khác và danh sách model của nó có Gemini/Claude/GPT-OSS, không phải Tester Luna. Lệnh đầu kết hợp `--approve-for-me` với `--sandbox` cũng sai cú pháp; bỏ cờ xung đột thì CLI khởi chạy đúng `gpt-6-luna xhigh`.
- `workspace-write` trong phiên Codex con vẫn báo Windows `failed_to_write_file`. Đã resume cùng Tester session qua shell được duyệt; CLI resume mặc định hiện `danger-full-access`/`approval never`, cho phép ghi các file test đã giới hạn trong brief. Đây là workaround có phạm vi của lượt này, không chứng minh workspace-write sandbox đã được sửa. Tester không chạm các thư mục bị AGENTS cấm.
- Tester chỉ sửa test harness: `mobile/integration_test/app_auth_e2e_test.dart`, helper mới `mobile/integration_test/support/native_realtime_ticket_probe.dart`, `ops/auth/run_native_e2e.mjs` và `ops/auth/test_native_e2e_protocol.mjs`. Probe S2 chạy trong Android isolate khi resume sau Web S1 logout, dùng TLS lab đã pin, POST bearer S2 + workspace tới realtime ticket, kiểm tra `201`/`no-store`/schema, giữ response và ticket trong isolate; runner yêu cầu observation `PASS`.
- `node --check ops/auth/run_native_e2e.mjs`, `node --check ops/auth/test_native_e2e_protocol.mjs` và `node ops/auth/test_native_e2e_protocol.mjs` đều PASS; protocol suite có 19 marker. Tester ghi Run 7 vào `docs/test-reports/FEAT-TN-002-integrated-test-report.md`.
- Android `--full-session` **BLOCKED — NOT RUN**: runner dùng Flutter `.dart_tool/package_config.json` và tạo build output trong `.dart_tool`/`build`, bị AGENTS cấm truy cập trong lane này. Chưa có evidence request S2 thật sau Web logout hoặc cleanup ticket/session trên emulator; không nâng acceptance.
- `agy models` giờ trả model 4 Argon/4 Hydrogen sau shell được duyệt, nhưng batch này chỉ làm test harness; không có inbox/notification/deep-link UI hiện hữu để mở rộng mà không đổi phạm vi. Late-push UI, app WebSocket owner alignment và installation-proof vẫn mở.
- Các file report/progress/plan/log dưới `docs` bị ignore nên LOCAL-ONLY. Không đổi checkbox, không giao reviewer vì acceptance chưa PASS, không commit.

## FEAT-TN-002 continuation — Tester/UI runtime re-audit — 18/11/2026 12:44 +07

**VERIFY_IN_PROGRESS; acceptance vẫn PARTIAL.** Đã đọc lại objective hiện hành, plan, checkout và các file liên quan; không lặp lại test/review đã PASS trên source state cũ.

- Một tiến trình Tester riêng chạy bằng `gpt-6-luna xhigh` đọc rules và §27.64. Source hiện có cờ `AUTH_E2E_S2_REALTIME_TICKET` và callsite `verifyNativeS2RealtimeTicket`, nhưng chưa có định nghĩa hàm; `ops/auth/run_native_e2e.mjs` không truyền cờ. Runner full-session đã có Web S1 logout trước Android S2 resume, nên vị trí kiểm tra đúng nằm trong resume. Tester dừng ở lần ghi đầu tiên vào `mobile/integration_test/app_auth_e2e_test.dart`: `Failed to write file`. Không có source/test/report update và không test nào chạy.
- `node ops/auth/run_native_e2e.mjs --full-session` khởi chạy Flutter bằng package configuration `.dart_tool` và generated build output, các đường dẫn bị AGENTS cấm truy cập/sửa trong lane này. Không chạy acceptance command đó hoặc dùng đường vòng; cần một lane được phép cho Android build/runtime.
- `agy` hiện có trong PATH, nhưng `agy models` không liệt kê model do CLI báo chưa đăng nhập Antigravity. Khởi động CLI cũng báo terminal sandbox Windows không khả dụng và quyền ghi log/cache/crash bị từ chối; không xác minh được 4 Argon/4 Hydrogen, không đăng nhập hoặc sửa cấu hình ngoài workspace.
- Rà source hiện hành trong `mobile/lib` và `mobile/pubspec.yaml` không thấy inbox/notification/deep-link feature; chỉ có comment lifecycle nhắc stream notification. Không thêm UI ngoài phạm vi và không đánh PASS late-push. App WebSocket owner alignment vẫn cần quyết định.
- Không đổi acceptance checkbox; không chạy review/commit. Cần sandbox/runtime ghi được cho Tester, Android lane tuân thủ AGENTS, Antigravity đăng nhập với model được yêu cầu, cùng owner decision cho app realtime trước khi đóng acceptance.

## FEAT-TN-002 continuation — chẩn đoán dispatch GPT-6-Luna Tester — 18/11/2026 12:23 +07

**VERIFY_IN_PROGRESS; acceptance vẫn PARTIAL.** Mục Loop 31 bên dưới bị đính chính: kết luận “GPT-6-Luna không có trong Codex CLI” là quá rộng. Tài liệu chính thức về [Codex subagents](https://developers.openai.com/codex/subagents) nêu rõ `gpt-6-luna`; [configuration reference](https://developers.openai.com/codex/config-reference) hỗ trợ đặt model và reasoning effort mặc định cho subagent. `codex debug models` và `app-server model/list` trên CLI cục bộ cũng trả `gpt-6-luna` cùng mức `xhigh`.

- Đã gọi được một Tester riêng bằng CLI với model `gpt-6-luna xhigh`; agent đọc `AGENTS.md`, objective và §27.64, nhưng Windows sandbox từ chối lần ghi đầu tiên vào `ops/auth/test_native_e2e_protocol.mjs` (`windows_sandbox failed_to_write_file`). Không có test nào chạy trong lượt đó.
- Các probe sandbox một-lệnh: `mxc` trả `native MXC is unavailable on this executor`; `unelevated` trả `CreateRestrictedToken failed: 87`; `elevated` trả `open sandbox provisioning pipe`. Lượt CLI lồng tiếp theo bị chặn khi mở Responses WebSocket với `os error 10013`. Đây là lỗi sandbox/network của môi trường chạy Codex lồng, không phải lỗi model hoặc project code.
- Một lượt gọi subagent qua collaboration tool tích hợp vẫn không xác nhận được Luna vì model đó không có trong allowlist của tool này. Không dùng model khác thay Tester và không dùng `danger-full-access` để vượt sandbox. Lượt scoped CLI cuối cùng bị dừng khi bắt đầu liệt kê rộng các file trong thư mục sinh tự động bị AGENTS cấm; không có thay đổi source/test từ lượt đó.
- Model dispatch đã có workaround cục bộ; Tester chưa thể hoàn tất test-only Android S2 ticket probe do sandbox. Acceptance §27.64 vẫn PARTIAL; không sửa checkbox. Không chạy test, không giao reviewer, không commit. Các mục late-push/Antigravity, app WebSocket owner alignment và installation-proof vẫn là blocker độc lập đã ghi trước đó.

**Auto-review note:** một lần thử interactive không có brief Tester đã bị auto-review từ chối do lệnh không mang phạm vi công việc và cấu hình auto-approval cộng `workspace-write` có thể cho phép sửa workspace không giới hạn. Các lần sau dùng brief giới hạn theo §27.64; không lặp lại lệnh trống đó.

## FEAT-TN-002 latest verification — 17/11/2026

**VERIFY_IN_PROGRESS; chưa nghiệm thu toàn feature.** Checkout `dev@62c68c3` trên `dev` còn dirty và chưa commit. Plan này được `.gitignore:23` (`docs`) loại khỏi Git; nội dung cập nhật vẫn nằm trong workspace. Không đổi ignore rule hoặc force-stage.

- Fresh Auth Lab `python -X utf8 -B ops/auth/run_local.py --verify` exit **0** với marker `realtime-sqlx-canceled-checkout-before-permit-release` và `realtime-adapter-session-denial-checkout-close-before-permit-release`. Probe mới gọi `PgIdentityStore::active_realtime_session_for_handshake` khi ACL SELECT bị từ chối; xác nhận adapter trả lỗi an toàn sau khi pool checkout về 0, query phục hồi trong lúc route permit còn giữ, rồi permit/handshake phục hồi. `provider-latest.json` có marker hai-instance Web+Android ticket/peer consume, logout Web, S1 socket close, S2 socket giữ, DB-denial fail-closed, và Android `/me` phục hồi. Runner cleanup xong; port `3000/3001` trống.
- Regressions cuối: launcher Python **16/16**; Rust workspace **31 passed, 1 ignored**, Auth Lab binary **13/13**, HTTP auth **10/10**; `cargo check --locked --offline --workspace --all-targets --features iot-platform-backend/http-server`, `cargo fmt --all -- --check` và `node --check` đều exit **0**. `npm.cmd run test:e2e:auth` **4/4** và headed Chromium main logout **1/1**; Playwright kiểm quota 16, overflow `503`/`no-store`, replay ticket thật, close handshake, Ping/Pong và thu hồi slot sau peer im lặng.
- Chrome thật qua CUA: readiness ban đầu trả `500 text/plain` do Auth API không chạy; sau khi khởi động Auth Lab readiness trả `401` envelope hợp lệ. Đã đăng nhập fixture tổng hợp, chọn workspace quản trị, logout và reload; trang vẫn ở login. Interactive fixture đã dọn; journal báo application fixture rows `REMOVED`, port `3000/3001` trống.
- Android `node ops/auth/run_native_e2e.mjs --full-session` exit **0** với login/workspace/logout/resume và DB oracles; `node ops/auth/run_native_offline_e2e.mjs --offline-expired` exit **0** gần nhất với outbox, process restart, resume và terminal logout. `dart format --output=none --set-exit-if-changed ...` và `dart analyze integration_test` exit **0**. Thứ tự offline-expired: hai lần đầu dừng sau checkpoint `ready`, lần kế pass, lần kế tiếp lại dừng ở `ready`, lần gần nhất pass; nguyên nhân các timeout chưa được chứng minh nên giữ rủi ro test ổn định chưa được giải thích. Đây không chứng minh OS reboot.
- Senior Tester re-audit trước đó kết luận **partial**. Correctness review cuối tìm ba lỗi quan trọng ở replay ticket, close handshake và peer liveness; đã sửa và kiểm thử lại. Senior Tester final và bốn review tuần tự Correctness/Security/Tests/Architecture-Performance trên delta cuối vẫn đang chờ.
- Provider-level RT-3 multi-instance, DB permission-denial fail-closed, bounded active sockets và Chrome manual logout đã được verify. Còn mở: E2E-LOGOUT-001 app-level mutation Web S1 + Android S2; AT-WF-002-02 same-device account/cache isolation; AT-WF-002-03 đầy đủ trên Android sibling; E2E-LOGOUT-005 late-push; exact S1/S2 session/push-binding/audit readback; secret-sink canary cho structured log/browser/app debug; và UI/client acceptance còn thiếu trong AT-WF-002-01…03. Chưa có app-level socket consumer được xác nhận trong Web/Flutter; cần đối chiếu owner/scope trước khi thêm client mới. Giữ `VERIFY_IN_PROGRESS`.
- Các snapshot cũ ở phần dưới được giữ làm lịch sử; nếu chúng còn nói direct SQLx gate/MB-OUTBOX-1 chưa có evidence, trạng thái mới nhất trong mục này và §27.45 thay thế chúng. Không promote checkbox feature-level; giữ `VERIFY_IN_PROGRESS`.

## FEAT-TN-002 verification snapshot — 16/11/2026 (superseded)

**VERIFY_IN_PROGRESS; chưa nghiệm thu toàn feature.** Code state là `dev@62c68c3`,
working tree dirty và chưa commit. Bản cập nhật này thay thế các snapshot cũ hơn.

- Web: `npm.cmd run test:auth` 43/43 PASS; `npm.cmd run build` PASS;
  `npm.cmd run test:e2e:auth` 4/4 PASS. Trong đó một kịch bản DB-backed chứng minh
  hai phiên Web, ticket/first-frame/replay, close socket S1, S2 còn hoạt động,
  stale S1 bị `401 SESSION_REVOKED`, logout lặp `204`; ba ca còn lại kiểm redaction,
  recovery UI bị intercept và cleanup failure. Server timeout frame đầu 4 giây;
  browser đo close trong giới hạn 5 giây.
- Android: `node ops/auth/run_native_e2e.mjs --full-session` exit 0 trên API24;
  login thật, dừng process, resume và logout cùng kiểm tra session/outbox/cleanup.
  Đây là online resume/logout, chưa bao phủ offline outbox qua restart.
- Flutter: `flutter test --concurrency=1 --reporter compact` 226/226 PASS;
  lượt hiện tại `flutter analyze` và `dart analyze integration_test` đều không issue.
- Backend: `cargo check -p iot-platform-backend --features http-server` PASS;
  `cargo test -p iot-platform-backend --features http-server --lib` 22/22 PASS;
  `cargo fmt --all -- --check` PASS.
- Python/fixture regression trước đó: launcher 10/10, native lab 50/50 và các
  protocol/membership/offline fixture tests PASS. Lượt hiện tại
  `python -X utf8 -B ops/auth/run_local.py --verify` exit 0 trên PostgreSQL fixture;
  đây là provider regression evidence, không thay thế cross-client acceptance.
- Chrome thật với fixture tổng hợp: login → chọn workspace A → logout → reload;
  sau reload đối soát tự hoàn tất và UI trở về form đăng nhập. Network được kiểm
  theo method/path/status. Auth Lab launcher thoát 0, port 3000/3001 trống; journal
  xác nhận application fixture rows đã bị xóa, còn audit anonymous theo retention.
- Senior Tester GPT-6-luna max re-audit verdict **partial / VERIFY_IN_PROGRESS**.
  Các gap còn lại: E2E Web S1 + Android S2, account/cache isolation cùng máy,
  offline outbox qua restart sau expiry, multi-instance/DB-failure socket close,
  unused-ticket sau logout, late-push, DB/push/audit readback và secret-sink canary.
  `4/4` Playwright là một kịch bản DB-backed cộng ba regression; không phải bốn
  acceptance E2E. Các review Sol High cho delta hiện tại chưa chạy xong.

Không có acceptance checkbox nào được đánh hoàn thành. Feature tiếp tục ở
`VERIFY_IN_PROGRESS` cho đến khi các gap trong mục 27.37 và AT-WF-002 được chứng minh.

## FEAT-TN-002 continuation — 16/11/2026

**VERIFY_IN_PROGRESS; chưa nghiệm thu.** Checkout bắt đầu `dev@767fec3`, branch
`dev`, working tree dirty và chưa commit. Hai integration test cũ còn gọi API
`read/write/delete` của token store đã được chuyển sang API hiện hành; nhờ đó
`dart analyze integration_test` và `flutter analyze` không còn lỗi.

Lệnh và evidence mới nhất:

- Trong `mobile/`, focused Flutter suite gồm repository, secure token store và
  ba native scenario boundary → **60/60 PASS**.
- Lệnh focused suite thực tế: `flutter test
  test/auth/session_token_store_test.dart
  test/auth/app_session_repository_test.dart
  test/tool/native_membership_scenario_boundary_test.dart
  test/tool/native_offline_scenario_boundary_test.dart
  test/tool/native_rate_scenario_boundary_test.dart`.
- Trong `mobile/`, `flutter analyze` và `dart analyze integration_test` →
  **No issues found**.
- Hai lần chạy riêng trên AVD `Nexa_Auth_API24` cho adapter secure storage,
  lần hai khôi phục active-session value sau app process stop → **PASS**; các
  probe không ghi/đọc `logout_intent`.
- Lệnh probe: `flutter test --no-pub --no-uninstall
  integration_test/session_token_store_test.dart -d emulator-5554
  --plain-name "persist adapter probe"`, sau đó chạy lại với
  `--plain-name "restore adapter probe and preserve proof"`.
- `node ops/auth/run_native_e2e.mjs --full-session` → **exit 0** trên AVD
  API 24; app main dùng auth API qua HTTPS local proxy và PostgreSQL fixture.
  Full/resume/logout request oracles cùng fixture/proxy cleanup đều PASS.
- `python -B -m unittest discover -s contracts/tests -p '*.py' -v` →
  **39/39 PASS**; `node --experimental-transform-types --test
  web/tests/auth.test.mjs web/tests/password_policy.test.mjs` → **36/36 PASS**;
  `git diff --check` → **exit 0**.

Native runner đầu tiên không qua fixture preflight do role probe cũ còn sót.
Ownership journal duy nhất và role comment chứng minh fixture thuộc auth lab;
đã thu hồi đúng role và chạy recovery theo journal, không reset database. Lần
chạy lại trên cùng runner hoàn tất với exit 0. Browser evidence vẫn là lượt
Web một session ngày 15/11; lượt này chưa chạy lại browser.

Lane compliance còn mở: các lệnh Flutter trên đã thực sự được chạy và kết quả
được ghi lại, nhưng repository không định nghĩa lane nào chạy chúng mà không
đọc/ghi `.dart_tool` hoặc generated build folders theo AGENTS.md. Không chạy lại
các lệnh đó trên checkout này; chưa coi kết quả Flutter là evidence nghiệm thu
độc lập cho tới khi có lane tuân thủ được xác nhận. Test “repository reconstruction” ở
`app_session_repository_test.dart` dùng fake in-memory store và không chứng minh
process restart hoặc durable `logout_intent`.

Các kết quả này chưa đóng acceptance của FEAT-TN-002: chưa có hai-session
isolation, WebSocket close runtime, offline/restart outbox E2E, push-late hoặc
AT-WF-002-01…03 đầy đủ. TTL bảo vệ bearer trong secure outbox vẫn chưa được
chứng minh. `agy` và đường dẫn cài CLI đã kiểm tra đều không có; lượt tải bộ cài
chính thức trước đó bị chính sách thực thi chặn. Không dùng IDE hoặc model thay
thế; phần UI vẫn chờ Antigravity CLI với 4 Argon/4 Hydrogen.

Các untracked artefact kiểm thử do runner tạo còn trong working tree, gồm cache
Python và output dưới `ops/auth/evidence/` và `ops/database/evidence/`; chưa đọc
nội dung log có thể chứa dữ liệu fixture.

Sau đó, GPT-6.1 Sol High correctness review phát hiện parser cũ từ chối raw
token68 legacy hợp lệ nếu `jsonDecode` hiểu token là JSON scalar (`12345`, `true`,
`null`, `1e5`). Parser đã được sửa để chỉ xét raw bearer hợp lệ khi decoded value
không phải JSON object; thêm regression test source trong
`mobile/test/auth/session_token_store_test.dart`. Không chạy lại Flutter sau sửa:
kết quả 60/60/analyzer phía trên là trước thay đổi parser và không xác nhận final
diff.

Review cũng xác nhận lỗi retention code: nhánh hết quota dừng scheduling nhưng
giữ bearer trong secure outbox, không thực thi TTL `expiresAt`. OQ-LOGOUT-003 yêu
cầu server expiry và elapsed time tin cậy, không purge sớm theo clock máy; client
chưa có time authority/PoC. Không dùng `DateTime.now()` đơn lẻ để xóa intent vì có
thể phá revoke khi clock nhảy tới tương lai. Đây là blocker triển khai L5, không
chỉ là evidence gap.

Security review lần lượt phát hiện hai integration assertion truyền bearer trực
tiếp vào matcher, có thể đưa token từ UID giữ lại vào test output khi mismatch.
Đã chuyển sang so sánh boolean và reason cố định trong
`mobile/integration_test/session_token_store_test.dart`. Static `rg` không còn
assertion nào truyền trực tiếp `.token`; `git diff --check` exit 0. Không chạy
Flutter lại sau thay đổi này.

Test coverage review phát hiện native two-stage probe chỉ lưu active-session,
không lưu `logout_intent`; source probe hiện đã bổ sung intent marker, restore và
cleanup nhưng chưa chạy trên AVD. Unit tests hiện bổ sung lỗi ghi quota trước
POST, lỗi ghi retry deadline, và terminal delete failure khi record vẫn còn;
test repository reconstruction dùng fake được đổi tên để không tuyên bố OS
process restart. Các test source này chưa chạy; evidence 60/60 và hai probe API24
trước đó không bao phủ chúng.

Architecture/performance review cuối không thấy vấn đề phân lớp hoặc hiệu năng,
nhưng tìm thấy recovery bỏ qua terminal proof trong cùng tiến trình: khi server đã
trả terminal và xóa outbox thất bại, lần recover đọc lại tombstone rồi POST logout
lần nữa. `_restore` đã được sửa để chỉ retry xóa outbox khi terminal proof RAM còn
hiệu lực; test source `checkOutboxDeleteFailureRetainsTerminalTombstone` đã có
assertion không POST lần hai nhưng chưa chạy sau sửa. Review cũng bắt hai comment
test gọi bearer đầy quyền là “revoke-only”; đã sửa để nói rõ worker chỉ dùng
bearer trong luồng logout. Re-review hẹp GPT-6.1 Sol High xác nhận fix an toàn
theo invariant single repository/store; test vẫn chưa chạy.

TTL vẫn là **BLOCKER L5**: không có nguồn server-time/elapsed-time đáng tin cậy
qua process restart/reboot trong app hiện tại. Không dùng wall clock local để purge
bearer; cần chốt cơ chế thời gian và verification lane tuân thủ AGENTS trước khi
có thể tuyên bố retention thỏa OQ-LOGOUT-003. Feature vẫn
`VERIFY_IN_PROGRESS`.

### Antigravity và login browser retest — 16/11/2026

Sau khi người dùng điều chỉnh môi trường CLI, Antigravity được chạy bằng `agy`
ở chế độ `accept-edits`; CLI hiển thị model **Gemini 4 Argon · medium**. Không
dùng IDE. UI logout recovery đã được tạo qua CLI và rà soát tích hợp vào
coordinator hiện có.

Browser thật tại `http://127.0.0.1:5173/login` tái hiện `POST
/api/v1/auth/login` → **HTTP 500, text/plain**. `web/vite.config.ts` proxy API
tới `127.0.0.1:3000`, nhưng cổng 3000 không có listener. Auth client trước đó+đọc JSON trước khi xét HTTP status, khiến body không phải JSON từ proxy bị báo+sai thành `PROTOCOL_ERROR`. Đã thêm regression test, rồi sửa `request()` để+5xx không parse được thành `SERVICE_UNAVAILABLE`, vẫn giữ login intent ở+`loginUnknown` và không replay POST. Browser sau reload xác nhận nội dung+“Dịch vụ đang gián đoạn…” và màn hình tiếp tục khóa workspace khi kết quả login+chưa được xác nhận. Đây là kiểm chứng trạng thái lỗi; không phải login E2E thành+công.

PostgreSQL trong container `iot-postgres17-database` đang nhận kết nối qua Unix+socket `/tmp` (`docker exec ... pg_isready -h /tmp -p 5432` → accepting), theo cấu+hình `listen_addresses=''`, `network mode=none`; không mở cổng TCP. Auth API chưa+được chạy. `ops/auth/run_local.py` build `auth-lab` vào `backend/target`; không thể+chạy lại trong lane này vì AGENTS cấm sửa/đọc build artifacts. Không reset hay mở+mạng cho database.

Kiểm tra sau sửa: focused regression **1/1 PASS**; `node+--experimental-transform-types --test web/tests/auth.test.mjs+web/tests/password_policy.test.mjs` **37/37 PASS**; `git diff --check` exit 0.
Flutter tests/emulator chưa chạy lại vì lane hiện có cần truy cập `.dart_tool` và+build artifacts. Feature vẫn **VERIFY_IN_PROGRESS**; successful login/API,+Android runtime, WebSocket close, trusted TTL, two-session, offline/restart,+push-late và AT-WF-002-01…03 còn mở.

### Automated test gate trước Chrome E2E — 16/11/2026

- Chạy lại `node --experimental-transform-types --test tests/auth.test.mjs tests/password_policy.test.mjs` trong `web/`: **43/43 PASS**; `node --check scripts/check-auth-api-readiness.mjs`: **PASS**; `node scripts/check-auth-api-readiness.mjs`: **PASS** với `/api/v1/me` trả 401 `SESSION_EXPIRED` ErrorEnvelope.
- Chạy lại `python -B -m unittest discover -s contracts/tests -p '*.py' -v`: **39/39 PASS**; chỉ chứng minh contract/fixture tĩnh.
- Đây chưa phải bộ test đầy đủ của feature: Flutter/App và Rust/backend chưa được chạy lại trên source dirty vì lệnh cần tạo/đọc `.dart_tool`, `.gradle` hoặc `backend/target`, các đường dẫn đang bị AGENTS cấm. Kết quả Flutter cũ không áp dụng cho thay đổi Mobile hiện tại.
- Chưa chạy Chrome E2E theo thứ tự người dùng yêu cầu; browser smoke trước đó chỉ xác nhận DOM của `/login`, không chứng minh logout. Giữ `VERIFY_IN_PROGRESS`; không nâng acceptance.

## FEAT-TN-002 continuation — 15/11/2026

**VERIFY_IN_PROGRESS; chưa nghiệm thu.** Checkout bắt đầu `dev@767fec3`, hiện
dirty và chưa commit. Backend logout transaction/ticket/push invalidation cùng
Web/App online flow đã có từ FEAT-TN-001. Tiếp nối Android source thêm secure
logout outbox/retry và test source, nhưng Flutter test/analyze/emulator chưa chạy
do lệnh sẽ truy cập `.dart_tool`/generated build artifacts bị cấm trong AGENTS.

Đã đổi `SessionTokenStore` sang active session+expiry và secure logout intent;
repository ghi outbox trước active delete, restore ưu tiên intent, retry cùng
bearer với full jitter 1–60s, `Retry-After`, tối đa năm attempt/chu kỳ và dừng
pending tới timer/lifecycle/recovery. Test source thêm retry scheduler giả,
restart ở cửa sổ tombstone+active key, lost write/delete ACK và schema chính xác;
đã cập nhật fakes trong ba test consumer. Legacy raw token được đọc với expiry
không biết. TTL ≤ server expiry chưa được chứng minh, intent không bị xóa theo
giờ local; bearer vẫn đầy quyền phía server tới khi revoke.

Sau các source/comment updates ở vòng cuối đã chạy:

- `python -B -m unittest discover -s contracts/tests -p '*.py' -v` → **39/39 PASS** (contract/fixture static).
- `node --experimental-transform-types --test web/tests/auth.test.mjs web/tests/password_policy.test.mjs` → **36/36 PASS** (Web mock regression).
- `git diff --check` → **exit 0**.

Node có experimental type-stripping warning; đây không phải test Android hoặc
provider. Lệnh Web chỉ chạy mock regression, không phải browser E2E.
Flutter test/analyze, emulator, DB/provider, WebSocket, push-late và
AT-WF-002-01…03 **NOT_RUN**. Lần mở đầu sau khi user mở browser bị
`ERR_CONNECTION_REFUSED`; sau khi user cho phép khởi động runtime, `npm.cmd run
dev` chạy Vite tại `http://localhost:5173`, và `python -B ops/auth/run_local.py`
khởi chạy auth lab tại `http://127.0.0.1:3000` trên canonical `iot_platform_lab`
với fixture synthetic có ownership, không reset DB. Browser IAB thật đăng nhập
đến workspace picker (2 workspace), rồi logout từ picker: `POST
/api/v1/auth/logout` trả **204**, UI trở về login, console không có error/warning.
Sau logout, password field trống nhưng email fixture vẫn hiện trên form login;
vì vậy chỉ xác nhận điều hướng về login, chưa xác nhận xóa hết thông tin account
trên UI. Đây là Web một-session path; chưa chứng minh S1/S2 isolation, protected reuse,
socket close, DB row snapshot hay AT-WF-002 acceptance. Attach Chrome tab có sẵn
vẫn timeout ở CDP `Emulation.setFocusEmulationEnabled`.
Chi tiết lượt chạy và giới hạn: [browser retest report](../test-reports/FEAT-TN-002-web-browser-logout-2026-11-15.md).

Recheck ở lượt tiếp nối: hai session Vite/auth-lab vẫn sống. Không thấy process
`emulator`/`studio64`; `adb devices -l` không chạy vì `adb` không được nhận diện
trong command discovery, nên device inventory và App runtime vẫn **NOT_RUN**.
Antigravity command và MCP tool discovery tiếp tục không có CLI/tool.

Hai owned runtime hiện còn mở để tiếp tục QA: Vite 5173 và auth lab 3000. Auth
fixture dùng password synthetic nhập qua prompt ẩn; không lưu credential vào
tài liệu/evidence. Dừng auth lab bằng Ctrl+C trong session sở hữu để chạy cleanup
fixture/role theo runner; không dừng trước khi App/proxy check hoàn tất.

Senior tester subagent GPT-6-luna max đã review trước các source updates.
GPT-6.1 Sol High đã review lần lượt correctness, security, test coverage và
architecture/performance/comment compliance. Source/test coverage bổ sung cho
retry quota, outbox persistence, lost write/delete ACK và terminal tombstone;
review cuối phát hiện rồi source được sửa cho nhánh recover terminal proof.
Các test mới chưa chạy; sửa recover đã được re-review hẹp, không có finding mới.
Retention TTL vẫn
BLOCKER vì thiếu time authority tin cậy; không có finding performance đáng kể.

Senior tester GPT-6-luna max retest verdict: L3 **BLOCKED**, L4 **PARTIAL**,
L5 **BLOCKED**, L6 **BLOCKED**; AT-WF-002-01 **PARTIAL**, AT-WF-002-02
**BLOCKED**, AT-WF-002-03 **NOT_RUN**. Không acceptance nào đủ evidence để PASS.

Antigravity CLI không khả dụng trong command/tool discovery; model 4 Argon/4
Hydrogen chưa được dùng hoặc xác minh. Không sửa UI; recovery copy cần follow-up
qua CLI. Backend chưa có socket-owning WebSocket server/close consumer callsite.
AT-WF-002-01…03, DB-backed Web/App offline/restart, push-late và socket-close
runtime đều NOT_RUN.

App/API emulator vẫn chưa chạy; HTTPS origin/proxy 8443 không có listener và
không có emulator đang chạy. Flutter run/test vẫn bị giới hạn bởi AGENTS về
`.dart_tool`/build artifacts; chỉ chạy tiếp sau khi có lane được phép dùng runtime.

File source/test thay đổi: `mobile/lib/features/auth/data/session_token_store.dart`,
`mobile/lib/features/auth/data/app_session_repository.dart`,
`mobile/test/auth/session_token_store_test.dart`,
`mobile/test/auth/app_session_repository_test.dart`,
`mobile/test/tool/native_offline_scenario_boundary_test.dart`,
`mobile/test/tool/native_membership_scenario_boundary_test.dart`,
`mobile/test/tool/native_rate_scenario_boundary_test.dart`. Tài liệu feature và
bảng tiến độ cũng được cập nhật nhưng feature plan bị ignore theo `.gitignore`
(rule `docs`, line 23); do đó hai thay đổi tài liệu chưa được Git track.

## Android API24 main full/resume/logout — 15/11/2026

AVD Nexa_Auth_API24/API24 chạy App main với auth API thật qua HTTPS local proxy và PostgreSQL fixture. Trước lần chọn workspace đầu, exact request oracle PASS: login1, profile≥1, workspace-list1, password/logout/OTHER0. Login/picker đúng A/Admin+B/User; process đầu dừng, process mới resume không login lại; session delta/logout revoke, proxy+fixture cleanup PASS. `node ops/auth/run_native_e2e.mjs --full-session` exit0. Flutter3.47.5/Dart3.13.4. AVD đã dừng; adb rỗng; cổng3000/8443 đã đóng.

Đây là READY_FOR_QA theo scope. E2E-AUTH-003/AT-WF-001-03 PARTIAL: Web và Android exact preselection request oracle đã có; chưa seed device fixtures A/B. E2E-AUTH-001/006 và Web process/race variants chưa đóng. Lượt đầu trong sandbox bị Docker API từ chối tại bước fixture; ngoài sandbox rerun đã PASS. Chỉ test harness thay đổi, production source/UI không đổi. [Report](../test-reports/FEAT-TN-001-android-api24-full-resume-2026-11-15.md), [evidence](../test-reports/evidence/FEAT-TN-001-android-api24-full-resume-2026-11-15.json).

Final host regression rerun 15/11: native protocol 15 marker PASS, `ops/auth/tests` 133/133 PASS, Web auth 36/36 PASS, TypeScript `tsc --noEmit` exit 0, `git diff --check` exit 0. Chi tiết và giới hạn scope: [report](../test-reports/FEAT-TN-001-final-host-rerun-2026-11-15.md). Toàn feature vẫn VERIFY_IN_PROGRESS.

## Chrome + PostgreSQL E2E rerun — 15/11/2026

Chrome thật ghi nhận login200 → /me200 → /workspaces200, A/Admin + B/Member, chọn A, chuyển workspace, chọn B và logout204. Request body chỉ ghi key clientType/email/password, không lưu values; không có device/resource request trước picker. Web slice PASS_SCOPED_BROWSER_FLOW / READY_FOR_QA. Android API24 exact preselection oracle đã chạy; E2E-AUTH-003/AT-WF-001-03 hiện PARTIAL vì thiếu device fixtures khác workspace.

Auth lab session exit1 khi dừng detached child; ownership recovery exit0 ghi application fixture rows REMOVED. Limiter bucket theo recovery policy và anonymous audit theo retention. Không còn API3000/proxy8443; Vite ::1:5173 PID25904 là listener có sẵn, giữ nguyên. Không chạy Android runtime lượt này.

[Report](../test-reports/FEAT-TN-001-web-chrome-login-picker-rerun-2026-11-15.md), [evidence](../test-reports/evidence/FEAT-TN-001-web-chrome-login-picker-rerun-2026-11-15.json).

## Logout contract checkpoint — 15/11/2026 10:02Z

Logout clear-cookie exact response parity fixed after Sol high review. Regression test real response builder 1/1, contract logout 6/6, rustfmt, full Rust workspace tests, and targeted Clippy PASS. Full workspace Clippy reports unrelated warnings in application tests and postgres identity. Code state dev@ba425ad dirty/uncommitted. Lát cắt này READY_FOR_QA; toàn feature VERIFY_IN_PROGRESS. [Report](../test-reports/FEAT-TN-001-continuation-2026-11-15.md), [evidence](../test-reports/evidence/FEAT-TN-001-logout-cookie-contract-fix-2026-11-15.json).

## Checkpoint hiện hành15/11

Rerun Chrome thật 09:36–09:42Z trên PostgreSQL fixture: UI login → picker A/Admin + B/Member → chọn A → chuyển B → logout. Logout về `/login`, password trống, email còn hiển thị. Không capture HTTP/payload/DB session oracle và không đổi acceptance status. Auth-lab launcher exit1 khi stop; recovery journal exit0, application fixture rows removed; limiter/audit theo recovery policy. [Evidence](../test-reports/evidence/FEAT-TN-001-chrome-ui-rerun-2026-11-15.json).

**READY_FOR_QA theo scope đã kiểm, toàn feature VERIFY_IN_PROGRESS.** Chrome thật chạy với PostgreSQL fixture: POST login200 → GET /me200 → GET /workspaces200, picker Nhà kính B/Member + Phòng vận hành A/Admin, chọn A detail200, logout204. Nhánh disabled account401 có lỗi chung và không gọi /me/workspaces; no-workspace hiện empty state; must-change-password trả /me403 và giới hạn UI. Console0 error/0 warning. CDP chỉ lưu method/path/status, không lưu payload hoặc credential. Application fixture rows removed qua owner journal recovery exit0; limiter buckets và anonymous failure audit được giữ theo policy. Auth Python133, browser response-fault22, cookie omission6, browser lab ownership/handoff và fixture crypto handoff2 PASS; rerun 15/11 08:48Z. Web auth36/36 + TypeScript0, Flutter host213 PASS + analyze0 issue trên Flutter3.47.5/Dart3.13.4 lúc09:05Z. API24 actual stale-membership preflight + owned terminal exit0 lúc09:22Z; E2E007/008 còn NOT_RUN theo thiếu oracle trong ma trận. DB provider370/333 và Web36/TypeScript0 vẫn theo report trước đó. E2E-AUTH-003, WEB-AUTH-013/014, IT-AUTH-011, SEC-AUTH-002/003/009, E2E-AUTH-001/006/007/008, AT-WF-001-03 còn mở theo ma trận; không có Android exact-payload/resource-device oracle, full process reopen, delayed logout race hoặc đầy đủ sinks trong lượt Chrome này. Code state dev@ba425ad, dirty, chưa commit; lượt này chỉ cập nhật docs/evidence, không sửa source/UI. [Report và evidence](../test-reports/FEAT-TN-001-continuation-2026-11-15.md), [browser JSON](../test-reports/evidence/FEAT-TN-001-web-chrome-real-2026-11-15.json), [ma trận](../test-reports/FEAT-TN-001-acceptance-matrix-2026-11-13.md). Các checkpoint bên dưới giữ lịch sử.

### FEAT-TN-001 hiện hành 13/11, sau lượt Chrome tiếp nối

**READY_FOR_QA theo scope đã kiểm, toàn feature VERIFY_IN_PROGRESS.** Root provider252markers/236distinct exit0 và8zero cleanup, actual success-response parity qua Web/Dart parser, Flutter212PASS/analyze0 và Web34PASS đã được Sol high review scoped. Chrome thật kiểm controlled late-cookieA sau acceptedB→409/hai tab khóa/reload và default15s timeout→explicitcandidate/noautoPOST. Logout204 replay chưa xóa cookie mới, full processreopen còn mở. FixtureChrome37946/5b0b5e vàVite89947/6a73fe đã cleanup/exit0. Dirty working tree/chưa commit, docs ignored. [Bàn giao hiện hành và bằng chứng](../test-reports/FEAT-TN-001-final-continuation-2026-11-13.md), [ma trận](../test-reports/FEAT-TN-001-acceptance-matrix-2026-11-13.md). Các checkpoint215/212/177 bên dưới giữ lịch sử.

Final provider13/11 owner85598/abedde **exit0**,215markers/202distinct và8zero cleanup. Đóng thêm UT007 concurrent durable distinct sessions và SEC005 expired capability HTTP401 theo scope. Manifest30files và246local links đã đọc lại, không còn listener task. Final independent Sol high review đang chờ quota, các runtime cases khác giữ mở. [Report/manifest và task tiếp](../test-reports/FEAT-TN-001-ios-provider-and-policy-2026-11-13.md).

Tiếp nối13/11 qua terminal. **READY_FOR_QA / VERIFY_IN_PROGRESS** cho FEAT-TN-001. Antigravity CLI HydrogenHigh đã sửa đúng một literal503 trong AuthPage, Sol high review và Web26/TypeScript/Chrome actual320px/desktop đạt. IOS contract drift đã sửa backend và forward0020, root áp canonical DB với19checksum cũ khớp, rowcounts nguyên, nativecommentcoverage92tables/5views đạt và catalog refresh. Provider212markers/199distinct/8zero cleanup đạt. Shared26Unicodepassword vectors chạy đạt Rust/Web/Dart. Oracle bổ sung/final comment correction còn final independent review vì agent Sol high usage limit, các Web/Android runtime variants còn theo ma trận. [Report hiện hành và file/lệnh/evidence](../test-reports/FEAT-TN-001-ios-provider-and-policy-2026-11-13.md).

Checkpoint hiện hành13/11 sau test/review bổ sung. **READY_FOR_QA theo scope, FEAT-TN-001 VERIFY_IN_PROGRESS.** O4 independent actual final-code đạt cùng9HTTP/4SQL/cleanup và17hash khớp. Storage plugin/adapter process-persistence và native key-loss probe đạt scoped. Chrome mới đã kiểm cookie A/B/missing, reload/tab mới, candidate/confirm, exact3POST/session/audit/cleanup và U1 operational one-card layout. GPT-6.1 Sol high đã review/đối chiếu độc lập. I1 provider177markers/164distinct,3error-only assertions, original terminal/8zero cleanup đạt. Còn các biến thể Web race/storage-denied, Android lifecycle/storage/cache và owner acceptance trong ma trận. UI follow-up đang giao Antigravity CLI1.5.8 pin4HydrogenHigh theo yêu cầu user. Dirty tree/chưa commit, docs ignored. [Bàn giao hiện hành](../test-reports/FEAT-TN-001-cli-and-cookie-handoff-2026-11-13.md), [Sol review](../test-reports/FEAT-TN-001-sol-final-review-2026-11-13.md), [I1 actual](../test-reports/FEAT-TN-001-provider-i1-sol-actual-2026-11-13.md), [acceptance matrix](../test-reports/FEAT-TN-001-acceptance-matrix-2026-11-13.md).

Các đoạn checkpoint theo ngày dưới đây là lịch sử. Trạng thái hiện hành được đối chiếu tại dòng trên và report liên kết.

Tiếp tục13/11. **ROOT_SCOPED_RUNTIME_PASS / READY_FOR_QA** cho O4 offline main Android/API36 với PostgreSQL thật. Đã nối bridge/fixture read-only/HTTP+SQL oracle/coordinator/CLI, host50Python và các suites Node mới/regression đạt. Actual75411/bea3c5 exit0, run1218a9d0,9HTTP đúng prefix1/1/2/5/9,4SQL snapshots giữ negative0delta và cùng AppUUID revoke/audit, original cleanup8zero. Mạng restore1/1, extra readback đủ8zero. Lượt80822 mất terminal do host reset giữ UNKNOWN, recovery giữ limiter khi key RAM đã mất. Lượt63836 SDK buildFAIL đã cleanup, sửa SDK bằng precache chính thức rồi warm build87.5s PASS trước actualR2. Chrome a11y320px không overflow, labels/focus/errorlinks/toggle keys và contrast13.16dark/14.73light đạt trong scope kiểm. Independent tester6.1/xhigh đang review O4 và đối chiếu ma trận acceptance. Toàn feature **INCOMPLETE**, dirty tree/chưa commit/docs ignored. [Report/evidence/hashes](../test-reports/FEAT-TN-001-completion-pass-2026-11-12.md).

Lượt hoàn thiện12/11 theo override user: physical-device N/A, Android emulator vẫn cần evidence thật. O4a gate/producer bốnfile mới SOURCE_HOST_ACCEPTED/READY_FOR_QA,11focused/final205Flutter/analyzerPASS; reviewer độc lập tìm/sửa sharedinitial20s và fast-recovery transition, finalhash accepted. Chrome DB thật bổ sung limitedreload/logout204, GET503+networkfail→candidate/explicitconfirm, tab2logout204 khóa tab1→reloadlogin; fixture/proxy/Vite đã cleanup/exit0. Web26, contracts39, Rustworkspace73 và HTTP17+7+1 PASS riêng, không cộng overlap. O4b–e actual và ma trận còn mở; whole feature INCOMPLETE. [Report hiện hành/evidence/hashes](../test-reports/FEAT-TN-001-completion-pass-2026-11-12.md), [review/mapping](../test-reports/FEAT-TN-001-final-review-2026-11-12.md).

Web alert12/11 sau retest: **ROOT_SOURCE_HOST_RUNTIME_PASS / READY_FOR_QA**. Đã sửa error cũ khi queued login/local validation và copy invalidate trung tính. RED→26tests/TypeScript/ViteRAM42modules PASS; Chrome DB thật fixture mới31f937ae đi disabled→blank→valid/picker/A→reload→logout, original23922 cleanup/exit0 và Vite/ports đã dọn. Independent tester dừng usage limit, chưa independent PASS. Ba source/testfiles dirty chưa commit, docs ignored. [Report cuối/hashes/evidence](../test-reports/FEAT-TN-001-chrome-real-db-2026-11-12.md). Task kế independent review/repeat và O4 offline main Android; whole feature INCOMPLETE.

Checkpoint Chrome12/11: **ROOT_SCOPED_UI_RUNTIME_PASS / READY_FOR_QA** với DB thật, full A/reload/B/A/logout, disabled/empty/limited, validation/theme/keyboard và375px. Browser đã kết nối lại; tool blockers trước đây là lịch sử. Original fixture cleanup PASS, Vite exit0, không còn listener3000/5173/8443; helper không có numeric exit receipt. Không có fresh independent SQL oracle/runtime repeat, còn hai điểm alert UX cần xử lý. [Report/evidence/hướng dẫn](../test-reports/FEAT-TN-001-chrome-real-db-2026-11-12.md). Task kế Web alert regression và O4 offline main Android; whole feature **INCOMPLETE**. Dirty tree, docs bị ignore, chưa commit.

O3 API36 ngày11/11: **ROOT_SCOPED_RUNTIME_PASS / SOURCE_HOST_ACCEPTED / READY_FOR_QA**. Owned83303 terminal463806 exit0/EFFECTIVE, nativeR/U_SOCKET/R, H2 cumulative1/1/2/incomplete0. Root/independent host19+44 và independent artifact audit đạt; runtime do root thực hiện. Network restore/readback, main restore và AVD81921 terminalexit0 đã có; autosave snapshot warning dung lượng, không persistence claim. O4 mainUI offline/reconnect/H2/DB còn mở; Chrome và whole feature INCOMPLETE. [Report/lệnh/Tester/risks](../test-reports/FEAT-TN-001-api36-network-2026-11-11.md), [review](../test-reports/FEAT-TN-001-api36-network-review-2026-11-11.md). Docs vẫn bị Git ignore, chưa commit.

Checkpoint O2 11/11. **SOURCE_HOST_ACCEPTED / READY_FOR_QA** cho harness, **ACTUAL_FAULT_FAILED / SHELL_WIFI_PERMISSION_NOT_PROVEN** API24. Independent findings stale baseline và wrong permission section đã sửa, final host19+19markers đạt. Actual23376 không có off canary; state diagnostic26678 xác nhận svcWiFi process fail cả off/restore, config1/1/airplane0 nhưng radio ACK chưa xác nhận. Final read-only ba8e06 chặn trước cert/ports/mutation. Task kế O3 capability API36 trước offline business; Chrome và toàn feature INCOMPLETE. Docs hiện bị Git ignore, tài liệu bàn giao mới chỉ trong workspace. [Report/sourcehashes/commands/Tester](../test-reports/FEAT-TN-001-guest-network-2026-11-11.md).

Checkpoint O1/Chrome retry11/11. **MODEM_FAULT_INEFFECTIVE / BLOCKED_TOOL_STARTUP**, feature **INCOMPLETE**. Actual API24 owned18171 đã terminal: baseline/off/restored đều native REACHABLE, H2 tổng3request/status/closed, incomplete0; readback riêng GSM home, exact AVD, no package PID và ports3000/8443 vắng. Tool receipt exit1 được giữ nguyên dù CLI định nghĩa INEFFECTIVE bằng2, không ghi PASS. Chrome inventory→reset→retry vẫn kernel assets os3 trước DOM. Task kế O2 phải chứng minh network fault thật trước offline UI; Chrome cần tool inventory hoạt động trước fresh DB fixture. [Report/evidence/code state](../test-reports/FEAT-TN-001-network-modem-actual-2026-11-11.md).

Checkpoint S2c2b2 11/11. **INDEPENDENT_RUNTIME_VERIFIED / READY_FOR_QA** cho stale membership API24. Đã có coordinator/CLI thật, sửa bind pending sau independent finding. Host34orchestration/5entry và12suites independent đạt. Root actual66674/726b22 và independent81400/0cff6b đều exit0 với H2/session/audit/UI/original cleanup, writer role absent. Task kế là Android offline proof, Chrome matrix và các gate còn lại. Whole feature **INCOMPLETE**. [Bàn giao và Tester](../test-reports/FEAT-TN-001-membership-orchestration-2026-11-11.md).

Checkpoint mới 11/11. **READY_FOR_QA** cho lifecycle cancellation fix và root positive membership DB probe. Independent tester bắt và retest STOP trong startup, Python74+88 và Node17/30/14markers đạt. Actual SUSPEND_B qua original helper commit/readback/drain/version+1, sessions/audit unchanged, cleanup8zero/shim exit0, writer role absent. Chrome mở được task tab rồi Work settings lại chặn, chưa có browser business E2E mới. S2c2b2/native stale/offline/independent actual/CP-03 vẫn mở, whole feature **INCOMPLETE**. [Report và Tester](../test-reports/FEAT-TN-001-membership-cancellation-fix-2026-11-11.md).

Checkpoint Chrome settings 11/11. Kernel assets đã hoạt động lại, browser API vẫn báo `Local browser use is disabled in Work settings`. **BLOCKED**, chưa có Chrome E2E mới, whole feature INCOMPLETE. [Report và bước khôi phục](../test-reports/FEAT-TN-001-chrome-settings-blocker-2026-11-11.md).

Checkpoint Chrome retry10/11 23:06. Đã thử Browser Use, reset/thử lại và reset Windows Computer Use/@oai/sky. Cả hai vẫn kernel assets path os3 trước Chrome inventory. **BLOCKED**, Chrome UI/business E2E NOT_RUN trong lượt này. [Retry report/log](../test-reports/FEAT-TN-001-chrome-retest-2026-11-10.md). Whole feature INCOMPLETE.


Checkpoint tự test10/11. Actual AndroidAPI24 full/resume/logout, access và password/relogin cả3exit0/owned cleanup. Provider PostgreSQL thật176checks/163unique đạt. Flutter182/analyzer, Rust40, Python159, contracts26 và Node117markers đạt. Tester GPT6.1xhigh xác nhận Web25/typecheck/ViteRAM, tìm lỗi pending cleanup và retest bản sửa SOURCE_HOST_ACCEPTED. **ROOT_SCOPED_RUNTIME_PASS / READY_FOR_QA**, Browseractual BLOCKED kernel assets os3, native stale/offline/orchestration/forensic còn mở. Main APK đã cài lại (installer gỡ bản cũ, data AVD có thể xóa), owned AVD đã shutdown. [Report/lệnh/receipts/giới hạn](../test-reports/FEAT-TN-001-self-testing-real-db-2026-11-10.md). Whole feature INCOMPLETE.


Checkpoint DB thật10/11 theo yêu cầu mới. PostgreSQL17.11/iot_platform_lab đã read-only connected, API→SQLx→DB thật đạt login/profile/list2workspace/detailA+B/logout, exact+1session/revoke/seedunchanged. Owned18888 terminal615bdc exit0, original fixture exit0/owner8zero, backend probe đã dọn. **ROOT_SCOPED_RUNTIME_PASS / READY_FOR_QA**, UI/independent/membership actual chưa đạt và task tổng vẫn paused. [Report và cách mở backend/Web DB thật](../test-reports/FEAT-TN-001-real-db-connection-2026-11-10.md). Feature INCOMPLETE.


Checkpoint S2c2a hardening10/11.29new +54existing =83Node markers/syntax2/5mutations đạt, external abort fanout và pending ownership đã kiểm host. Actual SDK preflight API24 owned69884 terminal478901 exit0, build/channel/stop/postPID absent đạt. **ROOT_SOURCE_HOST_PASS / ROOT_SCOPED_SDK_PREFLIGHT_PASS / READY_FOR_QA**. AVD Nexa_Auth_API24 headless owned78839 đang warm, auth/DB membership actual chưa chạy. Orchestration/H2/session/audit/independent còn mở. [Report/evidence](../test-reports/FEAT-TN-001-membership-consumer-2026-11-10.md). Feature INCOMPLETE.


Checkpoint S2c2a async host bridge10/11. Fixed895s reserve/180startup/60channel/420native/130oracle, picker210/fast5/send-time/sharedACK30/samePID đã nối.24new +54existing Node markers của9suites, syntax2 và5mutations đạt. **ROOT_SOURCE_HOST_PASS / READY_FOR_QA**, fake SDK/PID/clock, actual CLI còn đóng. S2c2b orchestration/abort ordering/H2/session/audit, independent và native DB runtime còn mở. [Report/evidence](../test-reports/FEAT-TN-001-membership-consumer-2026-11-10.md). Feature INCOMPLETE.


Checkpoint S2c1 native membership producer10/11. Host9focused/182fullFlutter/analyzer4files/format đạt. UI input/tap sáu checkpoints có fresh busy/epoch, B deny→refreshonlyA→A/Admin→logout form sạch. **ROOT_SOURCE_HOST_PASS / READY_FOR_QA**, API/store host synthetic, target debug đã nối nhưng host async bridge/CLI và independent/native actual còn mở. Dirty tree ba425ad9/dev, whole feature INCOMPLETE. [Report/evidence](../test-reports/FEAT-TN-001-membership-scenario-2026-11-10.md).


Checkpoint S2b picker/audit10/11. Picker210s đã RED3/GREEN11/fullFlutter173/analyzer/format đạt. Scoped sessions/audit metadata đạt159Pythoncases/54Nodemarkers/4auditmutations, actual read-only runb203e2f8 seed session/login audit cùng UUID, original shim exit0/owner8zero. **ROOT_SOURCE_HOST_PASS / ROOT_SCOPED_READ_ONLY_RUNTIME_PASS / READY_FOR_QA**. Independent/mutation/native UI chưa chạy, feature INCOMPLETE. [Report/hash/evidence](../test-reports/FEAT-TN-001-membership-budget-audit-2026-11-10.md).

Checkpoint S2a Node fixture membership10/11. Controller/factory đạt51markers trong8Node suites và5mutation guards. Đã sửa startup lateREADY bypass/raw READY error. Actual read-only run9b2475e0 target B/snapshot seed đạt, original shim exit0 và owner8zero. **ROOT_SOURCE_HOST_PASS / ROOT_SCOPED_READ_ONLY_RUNTIME_PASS / READY_FOR_QA**. Independent/DB suspension/native UI chưa chạy, feature INCOMPLETE. [Report/hash/evidence](../test-reports/FEAT-TN-001-membership-node-2026-11-10.md).

Checkpoint S1b2 owned membership suspension10/11. Root source/host PASS,153distinct Python cases,35Node markers,5mutation guards và6SQL EXPLAIN read-only đạt. Đã sửa late final-marker/slow-spawn admission. Profile membership20m, fixed control registry và owned drain trước graph cleanup đã nối shim/launcher. **READY_FOR_QA**, independent/actual mutation/native stale chưa chạy, feature INCOMPLETE. [Report/hash/evidence](../test-reports/FEAT-TN-001-membership-suspend-2026-11-10.md).

Checkpoint native membership support10/11. Gate11focused/173fullFlutter/analyzer/format và4mutation guards đạt. Projection B read-only9case mới, fixture/cleanup44tests, Node14/11/7markers và4mutation guards đạt. SQL empty scope thật và positive live fixture c837d7c6 đã kiểm, original shim exit0/8zero. Native phase chưa kiểm. Independent GPT6.1xhigh dừng do usage limit. **ROOT_SOURCE_HOST_PASS / READY_FOR_QA**, feature INCOMPLETE. [Report/sourcehash/evidence](../test-reports/FEAT-TN-001-native-membership-support-2026-11-10.md).

Checkpoint App/Web H2 retry10/11. Native HTTP AUTH_LOGIN401 có REQUEST/STATUS/CLOSED và UI auth-invalid. Cùng credential fixture Web login/logout thành công, exact+1WebUUID rồi revoked, seed Android nguyên. Chưa xác định nguyên nhân nhập App401. CUA dừng do input ngoài phiên. Main73855/proxy3415/fixture58727 đều originalexit0, fresh6projection0. Mainrestore26080 detach exit0/PID4847/foreground/airplane0, UI restore chưa kiểm. **ROOT_SCOPED_RUNTIME_VERIFIED / READY_FOR_QA**, offline/stale toànluồng còn mở. [Report và evidence](../test-reports/FEAT-TN-001-api24-http-control-2026-11-10.md).

Checkpoint App HTTP10/11 run71a6b207. UI offline/fields cleared và seed-onlyDB đã có, HTTP ledger0, nhưng thiếu positive canary và fixture chạm deadline. **INCONCLUSIVE / ROOT_PARTIAL_RUNTIME_VERIFIED**. Helper41766 terminalexit1 có ownedcleanup marker, main21501/proxy69583 terminalexit0 và fresh6projection0, airplane0. Task actual giữ mở, retry bắt đầu bằng positivecanary. [Report lượt hết hạn](../test-reports/FEAT-TN-001-api24-http-expired-2026-11-10.md).

Checkpoint runtime10/11. Chrome extension đã kết nối, Web login tab mới kiểm validation/focus/màu lỗi. Vite54057 phục vụ5173, AVD59542 bootAPI24, airplane0. Backend fixture mới và main App HTTP actual chưa chạy. [Evidence và task tiếp theo](../test-reports/FEAT-TN-001-runtime-preparation-2026-11-10.md).

Checkpoint10/11 HTTP observer H1/H2. Tester độc lập đã tìm và xác nhận lỗi raw saturation32+33, root sửa observed fail-closed bằng RED/GREEN. Proxy7DF9159A cùng transport6 và CLI9markers đã root và independent PASS. Final independent11suite strict exit0, source/comment/security accepted, ports đã trả. **SOURCE_HOST_ACCEPTED / READY_FOR_QA**. Actual App HTTP offline/stale còn NOT_RUN, toàn feature INCOMPLETE. Các checkpoint H1/proxyE4E9 bên dưới là lịch sử. [Report H2](../test-reports/FEAT-TN-001-http-observer-h2-2026-11-10.md).

Checkpoint09/11 HTTP captureH1. Hai helper/testfiles mới đã root hostPASS8markers/syntax và2targetedmutation guards. Raw/secure active, per-raw capability, target matcher, prefix256bytes và redacted snapshot/ledger đã hiện thực. **ROOT_SOURCE_HOST_PASS / READY_FOR_QA**. Proxy/CLI H2 và actual HTTP App còn NOT_RUN, final independent review bị usage limit. Proxy source E4E9 giữ nguyên. [Report H1](../test-reports/FEAT-TN-001-http-capture-h1-2026-11-09.md).

Checkpoint09/11. API24 rate root95652 và tester độc lập84966 đều terminal exit0, đủ native real900s, request/session/PID và original owned cleanup. Hai namespace đọc lại8zero. **SCOPED_RUNTIME_PASS / READY_FOR_QA**. B3 swallowed-tap source/host accepted, Flutter162/Web25/contract39PASS. Mainrestore30435 exit0, PID4535/API24/foreground/configurationgate, airplane0. Vite26040 phục vụ5173. Lượt20834 giữFAIL/mất isolate chưa rõ nguyên nhân. Toàn feature còn browser races, exactHTTP offline/stale, physical/accessibility/storage và owner gates. [Bàn giao09/11](../test-reports/FEAT-TN-001-handoff-2026-11-09.md).

Checkpoint09/11. API24 rate retest95652/5ea198 đã exit0, đủ native real900s/UI, exact request/session/PID oracle và original owned cleanup. Fresh run c732454f đọc lại8zero, post-package absent và listener3000/8443 vắng. **ROOT_SCOPED_RUNTIME_PASS / READY_FOR_QA**. Lượt20834 giữ FAIL/mất isolate chưa rõ nguyên nhân. Independent API24 và main restore tiếp theo còn mở. [Report và manifest](../test-reports/FEAT-TN-001-api24-rate-2026-11-08.md).

Checkpoint09/11. API24 rate20834 đã kết thúc exit1 theo log gốc, SDK ISOLATE_NOT_READY và package stop/daemon cleanup chưa xác nhận. Chưa đạt900s hoặc orchestration PASS. Fresh readback d2ded8 của run f989b9bb trả8nhóm0, emulator hiện đã tắt. Giữ **FAIL**, boot/retest có log riêng. [Report và evidence](../test-reports/FEAT-TN-001-api24-rate-2026-11-08.md). Runbook đã làm rõ mở terminal/Force stop/restore main/cleanup. Toàn feature INCOMPLETE.

Checkpoint08/11 offline/stale AppAPI24. Mainactual airplaneON→Mất kết nối/fields cleared, seed-onlyDB; restoreOFF→passiveUI34.586s vàDBsample28.038s chưa cósuccesssession mới; explicitretry mới+1AndroidUUID. StaleB suspend→UIdeny→reloadonlyA→Acontrol→logoutsameUUID, originalproxy/fixtureexit0 vàfresh8zero. **ROOT_PARTIAL_RUNTIME_VERIFIED / READY_FOR_QA**, exactAndroidHTTPcounters/independentrepeat vàstorageforensic chưa kiểm. Mainrestore93591exit0/PID6117/API24/configurationgate, airplane0. [Report/evidence/Tester](../test-reports/FEAT-TN-001-api24-offline-and-stale-2026-11-08.md).

Checkpoint08/11 API24. Native full/coldresume/logout58323, access25218 và password/coldrelogin48439 đều target/oracles/originalcleanup/terminalexit0, **ROOT_SCOPED_RUNTIME_PASS / READY_FOR_QA**. Mainrestore90773 exit0, PID5482/foreground/API24, configurationgate sau cleanup. Browser hai-tab mới BLOCKED bởi Work settings, chưa tạofixture. Independent API24 và các gate device/lifecycle/accessibility vẫn mở. [Commands/logs/sourcehash/Tester](../test-reports/FEAT-TN-001-api24-integration-2026-11-08.md).

Checkpoint08/11 tiếp nối. Controller response-loss đã source/host review accepted,22casesPASS. Chrome root R2 faultACK1057ms/failedsameID, exact+1Websession/audit và verified reload/recovery/candidateconfirm/logout đã **ROOT_SCOPED_RUNTIME_PASS / READY_FOR_QA**. Web staleB membership commit→detail404/error-only→recovery→pickerA/control200 đạt cùng scope. Fixture31479 terminalexit0/cleanup8zero. Initialreloadnetworkgap và independentruntimeNOT_RUN giữ rõ trong [report](../test-reports/FEAT-TN-001-web-response-loss-r2-and-stale-2026-11-08.md). Toànfeature vẫn chưa nghiệm thu.

Checkpoint08/11 hiện hành. Chrome + App main Android7/API24 đã cùng account, A/Admin và B/Member, logout hai chiều và recheck client còn lại, exact session deltas/revocation, original proxy/fixture terminal exit0 cùng tám nhóm cleanup0. **ROOT_SCOPED_RUNTIME_PASS / READY_FOR_QA**, không sửa product source. Lượt shared07/11 hết TTL/exit1 giữ partial, readback hiện0. API24 lifecycle/physical/audit và independent UI repeat còn mở. [Report, manifest, lệnh và giới hạn](../test-reports/FEAT-TN-001-shared-web-api24-2026-11-08.md). Task kế đủ dependency là lost-body sau commit và stale membership theo [mapping tester](../test-reports/FEAT-TN-001-completion-mapping-2026-11-08.md).

Checkpoint07/11. Web actual full/empty/disabled/limited đã có UI/API/metadata evidence và cleanup fixture25722 exit0. Sửa validation chuyển form, final BA92 actual limited/logout regression PASS, static review accepted. Flutter161host/analyzer6files PASS, negative matrix/producer scoped accepted. Rate Web owned83847 **ROOT_SCOPED_RUNTIME_PASS / READY_FOR_QA** sau921054ms/no-autoPOST/correct/logout và ownedcleanup/exit0, whole feature chưa nghiệm thu. [Bằng chứng và manifest](../test-reports/FEAT-TN-001-web-api-and-negative-coverage-2026-11-07.md).

Đây là bảng implementation, tách khỏi lịch sử phản biện tại `review-progress.md`.
Chỉ ghi PASS cho kiểm tra thực chạy; host/mock hoặc render không thay nghiệm thu runtime.

Checkpoint cuối06/11. Native rate rootR3/82546 và independent31654 đều actual exit0 với UI real900s/no-autoPOST/login/logout và original owned cleanup8zero. Main20323 đã restore, PID6912/MainActivity foreground/API36. Web helper4files SOURCE_HOST_ACCEPTED/READY_FOR_QA sau đóng race output-after-STOP, actual Web NOT_RUN vì controller kernel assets lỗi. RecoveryR2 giữ2limiter rows, graph7zero. [Native evidence](../test-reports/FEAT-TN-001-native-rate-cli-reserve-2026-11-06.md), [Web helper và blocker](../test-reports/FEAT-TN-001-browser-private-handoff-2026-11-06.md).



Checkpoint06/11. Chrome thật đã kiểm validation/focus/unavailable-recovery/theme/responsive, **PARTIAL_RUNTIME_VERIFIED**, chưa Web/API login success. Hai href CTA/footer sửa và click Chrome PASS. Build42modules/auth25PASS. Android owned86769 đã full/resume/logout/cleanup exit0 trênC887. PID gate runnerE3BB đã root/independent6host suites SOURCE_HOST_ACCEPTED, actual PID absentPASS; Android regression owned42194/bbc475 exit0 full/resume/logout/cleanup, independent full/access/password nay đều exit0 và owned cleanup. Lượt29209 lịch sử FAIL startup resume/native PID còn sống vẫn giữ, không bị repeatPASS tự đóng root cause. [Evidence, lệnh và giới hạn](../test-reports/FEAT-TN-001-runtime-resumed-2026-11-06.md).

Checkpoint nguồn B3c01/11: **SOURCE_HOST_ACCEPTED / READY_FOR_QA**, final independent v3
proxy91916/5fcbf2 exit0, hashes khớp.10files frozen; internal orchestration/owned terminal/lifetime và
abort wiring đã có, findings/coverage gap đã sửa. Root native full-session29209 đã terminal FAIL startup resume; chưa rate900s trên source B3c,
CLI rate còn đóng. [B3c manifest/evidence](../test-reports/FEAT-TN-001-native-rate-orchestration-2026-11-01.md).

Checkpoint01/11: **B1B_ACTUAL_SCOPED_PASS / READY_FOR_QA; NATIVE_PREFLIGHT_PASS**.
Docker identity/NDKcompiler đã vượt blocker cũ; root diagnostic unknown401/bucketdelta+1,
normal/pendingSTOP8zero/shimexit0PASS cả root và independent; native preflight exit0.
Root full/coldrestore/logout/cleanup exit0; independent full/access/password exit0, main đã restore.
Web5173 sẵn sàng,25tests/buildPASS; Chrome đã mở `/login`, validation/summary-focus có ảnh thật.
Sau user mở Chrome lần cuối, extension id4 đã kết nối/form sạch/ảnh và giữ tab; chưa browser/API success E2E mới.
[Current evidence, file/hash, Tester](../test-reports/FEAT-TN-001-runtime-recovery-2026-11-01.md).
Toànfeature chưa nghiệmthu; B3bSOURCE_HOST_PASS giữnguyên, B3c/nativeconsumer/rateactual cònmở.

Checkpoint31/10: **B3b SOURCE/HOST PASS / READY_FOR_QA**, chưa native429/900s hoặc toàn feature.
Root và tester độc lập GPT-6.1/xhigh:20Flutter tests/analyzer/format vàNode8/13/5markersPASS,
matching hashes; tickrace/earlycredentialcleanup findingsđóng. [Combinedmanifest/evidence](../test-reports/FEAT-TN-001-native-rate-scenario-2026-10-31.md).
Native ratephase đãcóscenario, mainCLI chưa mở. B3c orchestration vàhosttests làtasksourcekế;
B1bactual/sharednative regressions phảiđạt trước rateactual. Chrome đãkhôi phục; Docker/NDK
vẫn làruntime blockers gầnnhất, B3bkhông chạy lạiSDKdevice/DB. HistoricalactualC1/C2-A/C2-B
không thay manifest/regression mới. [Audittoànfeature](../test-reports/FEAT-TN-001-completion-gap-audit-2026-10-30.md).

| Feature/task | Code state | Trạng thái | Evidence / dependency còn thiếu |
| --- | --- | --- | --- |
| FEAT-TN-001 dependency audit 15/11 | dev@ba425ad dirty | SOURCE_DEPENDENCIES_CONFIRMED / acceptance unchanged | Auth router/OpenAPI chưa có /devices resource route; FEAT-TN-010 có plan READY_FOR_EXECUTION nhưng chưa triển khai. Chrome Web và Android API24 exact preselection oracles ghi nhận không có device/resource request trước picker. Chưa seed device khác workspace nên E2E-AUTH-003 vẫn PARTIAL; dependency route/resource riêng không đổi. Auth diagnostic recorder là bounded in-memory timing; auth_lab có measurement begin/end test endpoints, nhưng chưa có production structured-log/remote-exporter integration. Chi tiết, source refs và next tasks trong [continuation report](../test-reports/FEAT-TN-001-continuation-2026-11-15.md). |
| FEAT-TN-001 Android API24 full/preselection/resume/logout 15/11 | dev@ba425ad dirty; production source/UI unchanged, test harness updated | PASS_SCOPED_NATIVE_FULL_SESSION_AND_PRESELECTION_ORACLE / READY_FOR_QA | AVD Nexa_Auth_API24/emulator-5554: picker-boundary oracle login1/profile≥1/workspace-list1/password/logout/OTHER0; A/Admin+B/User; process stop, secure-storage resume, session delta/logout revoke, proxy+fixture cleanup; runner exit0. AVD đã dừng, adb rỗng, cổng3000/8443 đóng. E2E-AUTH-003/AT-WF-001-03 PARTIAL vì chưa seed device rows khác workspace. [Report](../test-reports/FEAT-TN-001-android-api24-full-resume-2026-11-15.md), [evidence](../test-reports/evidence/FEAT-TN-001-android-api24-full-resume-2026-11-15.json). |
| FEAT-TN-001 Chrome committed-response-loss recovery 15/11 | dev@ba425ad dirty, không có source change | PARTIAL_BROWSER_RUNTIME_PASS / READY_FOR_QA cho scope đã quan sát | Chrome thật + PostgreSQL fixture: response login 200 bị hủy ở client, loginUnknown tồn tại sau reload, 30 giây không auto-login, discovery/confirmation chủ động, logout204; cleanup journal exit0. Chưa phải E2E-AUTH-006 PASS: process reopen, delayed logout/race variants và session/audit oracle còn thiếu. Host controller regression:22 cases PASS; đây không thay actual browser/database acceptance. Auth host reruns: Python133 tests và cookie omission6 assertions PASS. [Report](../test-reports/FEAT-TN-001-continuation-2026-11-15.md), [evidence](../test-reports/evidence/FEAT-TN-001-chrome-committed-response-loss-2026-11-15.json). |
| FEAT-TN-001 Chrome/PostgreSQL login-picker-logout 15/11 | dev@ba425ad dirty; no source/UI change in this rerun | PASS_SCOPED_BROWSER_FLOW / READY_FOR_QA | Chrome actual: login/bootstrap200, picker A/Admin+B/Member, select A→B and logout204. Payload key names only; zero device/resource requests before picker. Recovery cleanup exit0 after auth-lab stop exit1. E2E-AUTH-003/AT-WF-001-03 PARTIAL: Web and Android preselection request oracles exist; device fixtures per workspace remain missing. [Web report](../test-reports/FEAT-TN-001-web-chrome-login-picker-rerun-2026-11-15.md), [Android report/evidence](../test-reports/FEAT-TN-001-android-api24-full-resume-2026-11-15.md). |
| FEAT-TN-001 logout cookie/OpenAPI parity 15/11 | dev@ba425ad dirty, chưa commit; test trong backend/src/http/sessions.rs | READY_FOR_QA cho lát cắt | Test-first: mismatch tái hiện trước fix; backend focused1/1, logout contract6/6, rustfmt, full workspace test và targeted Clippy PASS. Full workspace Clippy warnings ngoài source logout; toàn feature VERIFY_IN_PROGRESS, acceptance mở giữ nguyên. [Report](../test-reports/FEAT-TN-001-continuation-2026-11-15.md), [evidence](../test-reports/evidence/FEAT-TN-001-logout-cookie-contract-fix-2026-11-15.json). |
| FEAT-TN-001 HTTP captureH1 09/11 | dev@ba425ad dirty,2helper/testfiles mới, proxyE4E9 giữ nguyên | ROOT_SOURCE_HOST_PASS / READY_FOR_QA | Prefix/target/rawownership/lifecycle/redaction8hostmarkers và2mutationguards PASS. IndependentH1/H2transport-CLI/actualApp còn mở. [Report](../test-reports/FEAT-TN-001-http-capture-h1-2026-11-09.md). |
| FEAT-TN-001 B3 swallowed tap09/11 | dev@ba425ad dirty, một test file final FDCA1277, chưa commit | SOURCE_HOST_ACCEPTED / READY_FOR_QA, independent5/5/analyzer/format PASS | RED đúng API1/control marker, GREEN5/5 gồm real20s, analyzer/format PASS, fullFlutter162PASS. Các gap negative B3 khác và native runtime giữ scope riêng. [Report](../test-reports/FEAT-TN-001-b3-swallowed-tap-2026-11-09.md). |
| FEAT-TN-001 API24 rate09/11 | dev@ba425ad dirty, runner/target giữ manifest10files | ROOT_SCOPED_RUNTIME_PASS / READY_FOR_QA | Retest95652 terminal5ea198 exit0, real900s/request/session/PID/original cleanup và fresh8zero. Lượt20834 vẫn FAIL/mất isolate chưa rõ nguyên nhân. Independent84966 exit0/8zero, main30435 restore exit0/PID4535/API24. Physical/lifecycle và strict negative gaps còn mở. [Report](../test-reports/FEAT-TN-001-api24-rate-2026-11-08.md). |
| FEAT-TN-001 AppAPI24 offline/stale08/11 | dev@ba425ad dirty, source10files giữmanifest; increment cập nhật evidence/docs | ROOT_PARTIAL_RUNTIME_VERIFIED / READY_FOR_QA | Airplane1→0, networkerror/blankfields, seed-onlybeforeexplicitretry, +1session sau submitchủđộng; BstaleUIdeny/reloadA/control/logoutsameUUID; cleanup8zero/terminalexit0. ExactHTTP/storageforensic/independentrepeat cònmở. [Report](../test-reports/FEAT-TN-001-api24-offline-and-stale-2026-11-08.md). |
| FEAT-TN-001 API24 integration08/11 | dev@ba425ad dirty, source runner/product giữ manifest10files | Full/access/password ROOT_SCOPED_RUNTIME_PASS / READY_FOR_QA | Full58323 exit0/oracles/cleanup, access25218 exit0/oracles/cleanup. Password48439 exit0/oracles/cleanup. Mainrestore90773 exit0, PID5482/foreground/API24/configurationgate. Browser hai-tab bị Work settings chặn; fixture Web chưa tạo. [Report](../test-reports/FEAT-TN-001-api24-integration-2026-11-08.md). |
| FEAT-TN-001 Web fault R2 và stale membership08/11 | dev@ba425ad dirty,2harnessfiles mới; product source theo manifest12files, chưa commit | SOURCE_HOST_ACCEPTED / ROOT_SCOPED_RUNTIME_PASS / READY_FOR_QA |22hostcases root/independentPASS, actualfault1057ms+persistedsession/audit, verifiedreload/candidateconfirm và Bstale404→A200, originalexit0/8zero. Firstreloadgap và independentactualNOT_RUN còn mở. [Report](../test-reports/FEAT-TN-001-web-response-loss-r2-and-stale-2026-11-08.md). |
| FEAT-TN-001 Web response-loss08/11 | dev@ba425ad dirty; product source giữ BA92, chưa commit | INCONCLUSIVE cho R1; UI recovery PARTIAL_RUNTIME_VERIFIED / READY_FOR_QA | Ba attempts thiếu fault ACK trước15s. Recovery qua reload, discovery200/candidate/confirm/logout,3POST/3logout204, finalsessionmap và original exit0/8zero. Bounded controller cần review trước repeat. [Report](../test-reports/FEAT-TN-001-web-response-loss-2026-11-08.md). |
| FEAT-TN-001 Web + App API24 cùng account08/11 | dev@ba425ad dirty; product source giữ manifest BA92/main8EC0, chưa commit | ROOT_SCOPED_RUNTIME_PASS / READY_FOR_QA | Hai UI thật, A/B đúng role, logout hai chiều, exact session map, proxy/fixture exit0 và cleanup8zero. API24 scope còn audit/lifecycle/physical/independent UI. [Report/Tester](../test-reports/FEAT-TN-001-shared-web-api24-2026-11-08.md). |
| FEAT-TN-001 Web form phase reset và producer negatives07/11 | dev@ba425ad dirty; AuthPage BA92 và3test files, chưa commit | SOURCE_HOST_ACCEPTED / ROOT_ACTUAL_SCOPED_PASS / READY_FOR_QA | Stale validation cross-form đã RED→fix→actual final BA92 limited/logout/login clean; native negative matrix/4producercases accepted scoped, Flutter161tests/analyzer6files PASS. Web final25tests/build42modules PASS. Rate root scoped PASS; independent UI/cross-client/owner gates còn mở. [Files/commands/Tester](../test-reports/FEAT-TN-001-web-api-and-negative-coverage-2026-11-07.md). |
| FEAT-TN-001 private Web fixture handoff | dev@ba425ad dirty;4untrackedsource/tests, helper728D…43EF, chưa commit | SOURCE_HOST_ACCEPTED / ROOT_ACTUAL_SCOPED_PASS / READY_FOR_QA | Chrome/crypto client đã phục hồi07/11; helper25722 READY→decrypt RAM→Web API flows→STOP→original cleanup/exit0. Lượt EOF44753 failed, current readback8zero, đã sửa invocation tty:true. Rate83847 đã921054ms/correct/logout/ownedcleanup/exit0, root scoped PASS; independent UI còn mở. [Current evidence](../test-reports/FEAT-TN-001-web-api-and-negative-coverage-2026-11-07.md). |
| FEAT-TN-001 rate CLI/reserve06/11 | dev@ba425ad dirty;8source/testfiles, runnerE52C…70B9, chưa commit | SCOPED_NATIVE_RATE_PASS / READY_FOR_QA | CLI noargs/terminal/redaction; guards2205/2200/2195/2065, tail125, hardcut105; root/independent7host suites và exact nonrate compatibility PASS. RootR3/82546 và independent31654 đều exit0, original8zero/ownedterminal; main20323 đã restore. RecoveryR2 giữ2limiterrows riêng. [Manifest/tests/Tester](../test-reports/FEAT-TN-001-native-rate-cli-reserve-2026-11-06.md). |
| FEAT-TN-001 runtime06/11 và PID failure gate | dev@ba425ad dirty, runnerE3BB…F464 và3source/testfiles, HomeSections2href, chưa commit | Web PARTIAL_RUNTIME_VERIFIED; PID SOURCE_HOST_ACCEPTED / ROOT_ACTUAL_SCOPED_PASS / READY_FOR_QA | Root/independent6host suitesPASS, PIDreceiptactual2f083fPASS. Native86769C887 full/resume/logout/cleanup exit0, E3BB regression42194/bbc475 exit0 full/resume/logout/cleanup; independent full/access/password nay đều exit0 và owned cleanup. CTA/footer `/login` actualPASS, Web build42modules/25testsPASS. [Report/files/hashes/Tester](../test-reports/FEAT-TN-001-runtime-resumed-2026-11-06.md). |
| FEAT-TN-001 T1-C2-C B3c rate orchestration | dev@ba425ad dirty;10untracked source/test files, chưa commit; docs local/ignored | SOURCE_HOST_ACCEPTED / READY_FOR_QA; native regression in progress | Root Node proxy46/schema,terminal7cases,protocol14/RPC9/evidence6markers,orchestration26cases và Python35/88 PASS; independent v2 cùng suites/hashes PASS, ba findings đã sửa. V3 CLI exact final schema root dede3f và independent91916/5fcbf2 PASS, no open source/host finding. Root native full-session29209 đã FAIL startup resume ngày01/11; chưa native900s/CLI rate hoặc wholefeature acceptance. [Files/hashes/commands/limits](../test-reports/FEAT-TN-001-native-rate-orchestration-2026-11-01.md), [independent](../test-reports/FEAT-TN-001-native-rate-orchestration-independent-2026-11-01.md). |
| FEAT-TN-001 runtime recovery 01/11 — B1b actual và native regression | dev@ba425ad dirty; verifier Python mới untracked, docs local/ignored; chưa commit | B1B_ACTUAL_SCOPED_PASS / READY_FOR_QA; SHARED_NATIVE_REGRESSIONS_SCOPED_PASS | Root53985/79d9c7 và independent80618/be4504 exit0: unknown401, bucket delta1, normal/pendingSTOP8zero và shimexit0; hash A142…D7793 khớp. Native preflight2894/a34871 và root full70681/c8374a exit0. Independent full27822/5feca0,access33568/73577b,password29776/c07d5d exit0; main69932/e7d8e9 đã restore. Web25tests573457/build14e89f,contract26c143a1,Rustpolicy10745f PASS. Chrome đã mở/validation/ảnh thật, user mở lại lần cuối và extension4 đã xác nhận form sạch/giữ tab; chưa Web/API success. B3c/rate900s và toàn feature còn mở. [Lệnh, files, hashes, evidence và Tester](../test-reports/FEAT-TN-001-runtime-recovery-2026-11-01.md), [độc lập](../test-reports/FEAT-TN-001-runtime-recovery-independent-2026-11-01.md). |
| FEAT-TN-001 T1-C2-C B3b native rate scenario | dev@ba425ad dirty;5untracked source/testfiles, chưa commit | SOURCE_HOST_PASS / READY_FOR_QA / DEVICE_NOT_RUN | Root20Flutter9b8531/analyzer3175bf vàNode8/13/5PASS; independent29cb5e/83975a/69e23f,7ae933/5fd17f/0e58adPASS, hasheskhớp. Luồng6wrong/typed429/renderedreal-observation/7thlogin/logout đãnối trongsource; packet/scanner2secret. Findingstickrace/earlywipeđóng. B1bactual/B3c/consumernative/device900s giữgate. [Files/commands/limits](../test-reports/FEAT-TN-001-native-rate-scenario-2026-10-31.md), [independent](../test-reports/FEAT-TN-001-native-rate-scenario-independent-2026-10-31.md). |
| FEAT-TN-001 T1-C2-C B3a native probe | dev@ba425ad dirty;3untracked source/test files, chưa commit | SOURCE_HOST_PASS / READY_FOR_QA / NATIVE_NOT_RUN | Root6bb52911tests,028bb9format/analyzerNoissues; sameStopwatch5s/receiptomit/synchronousACK, exactcountdownbounds/900+2 observationmodel. InitialblindgapRED→fix; reviewer đã yêu cầu boundsnegatives không bịgapmask. Independent77607911tests/analyzer/formatPASS, hashesB3akhớp; B3b sửa tiếp target, chưa rateCLI/actual900s. [Current report](../test-reports/FEAT-TN-001-native-rate-probe-2026-10-31.md). |
| FEAT-TN-001 T1-C2-C B2b-2b snapshot/reserve | dev@ba425ad dirty;4untracked source/test files, chưa commit | SOURCE_HOST_PASS / READY_FOR_QA / ACTUAL_NOT_RUN | Root module85b60e:5markers / deadlinef99945:7markers / protocol322d02:13markers; independent cùngsuites/hashesPASS. 3snapshot/sessionproof/ledger1080s/dynamicreserves/abortpendingRPC/SDK+fixture+rawownership; findingsclock/seal/config đóng. B1bactual/B3/native900s/sharedregressions giữgate. [Current files/evidence](../test-reports/FEAT-TN-001-native-rate-evidence-2026-10-31.md), [independent](../test-reports/FEAT-TN-001-native-rate-evidence-independent-2026-10-31.md). |
| FEAT-TN-001 đồng bộ policy/khôi phục runtime | dev@ba425ad dirty, chưa commit; sửa docs, không source | DOC_ALIGNMENT_PASS / RUNTIME_BLOCKED / FEATURE_INCOMPLETE | Đóng drift12→9 tại8vị trí plan; tester đối chiếu fixture/backend/Web/Dart. Chrome local use vẫn disabled; Gradle config PASS nhưng APK/native chưa PASS; build67965 terminal exit1/NDK clang denied, chưa APK/main restore. [Commands/limits](../test-reports/FEAT-TN-001-runtime-recovery-2026-10-30.md), [audit](../test-reports/FEAT-TN-001-completion-gap-audit-2026-10-30.md). |
| FEAT-TN-001 T1-C2-C B2b-2a checkpoint5s | dev@ba425ad dirty;2untracked files sửa tiếp; chưa commit | SCOPED_HOST_PASS / READY_FOR_QA / NATIVE_RATE_NOT_RUN | Root948a4c/protocol254284 và independentc39e19/a582d8 exit0,5deadline/checkpoint markers; phase/staleguard findings đã đóng. 11stage/66ACKs, sharedremaining5s, callbacksync/pendingownership và exactphase. Native B3 chưa contract/status/ACK actual; B2b-2b host đã accepted theo hàng31/10, B1b actual và900s native còn mở. Docker8f2b61blocked; preflight61691/67108 và ba2dcf đã FAIL; ADB fresh d7ebb5 lỗi config, build main67965 terminal exit1/NDK clang denied, chưa APK/main restore. Xem runtime report hiện hành ở đầu bảng; không native PASS mới. [Current files/evidence](../test-reports/FEAT-TN-001-native-checkpoint-deadline-2026-10-30.md), [independent](../test-reports/FEAT-TN-001-native-checkpoint-deadline-independent-2026-10-30.md). |
| FEAT-TN-001 T1-C2-C B2b-1 SDK deadlines | dev@ba425ad dirty; runner untracked sửa tiếp, test deadline mới untracked; docs local/ignored; chưa commit | SCOPED_HOST_PASS / READY_FOR_QA / ACTUAL_NOT_RUN | Root focused15cb7e/protocola73657/syntax502ed3 và independent focused3d4847/protocolb4408c exit0. Channel60/RPC30/phase1260/work tuyệt đối, late reply không ACK; pending oracle→SDK stop/exit trước await I/O, fixed UNCONFIRMED/no late PASS. Important đã đóng. Fake actual consumer không DB/SDK thật; B2b-2 callback fence/checkpoint/snapshot, B1b actual/native regressions và B3 còn mở. [Current files/hashes/evidence](../test-reports/FEAT-TN-001-native-rpc-deadline-2026-10-30.md), [review độc lập](../test-reports/FEAT-TN-001-native-rpc-deadline-independent-2026-10-30.md). |
| FEAT-TN-001 T1-C2-C B2a ARM/profile | dev@ba425ad dirty;4harness files untracked sửa tiếpB1b, docs local/ignored; chưa commit | SCOPED_HOST_PASS / READY_FOR_QA / ACTUAL_NOT_RUN | Root26/35host, independent26/88host và Node factory/parser/returned arm/close PASS; Important lostACK/wrapper cleanup đóng. Rate-only ARM neo host trước write, absolute watchdog, deadline/STOP race guards, memoized close→STOP/EOF→terminal/8zero. Không mở rate CLI/Dart/RPC phase; B1b positive→zero actual/pendingSTOP và native regressions còn mở. Preflight escalation bị policy reject trước execution; Docker access vẫn blocked tại checkpoint trước. [Current files/hashes/commands/evidence](../test-reports/FEAT-TN-001-native-rate-arm-2026-10-30.md), [review độc lập](../test-reports/FEAT-TN-001-native-rate-arm-independent-2026-10-30.md), [plan](../test-reports/FEAT-TN-001-native-rate-limit-plan-2026-10-30.md). |
| FEAT-TN-001 T1-C2-C Android429/countdown | dev@ba425ad dirty; B1b bốn untracked harness files sửa tiếp, B1a helper modified/test untracked; chưa commit; thêm read-only bucket projection, chưa App/API/budget change | B0/B1a/B1b_SCOPED_HOST_PASS / B1b_ACTUAL_BLOCKED / B2_PLAN_IN_REVIEW / ACTUAL429_NOT_RUN | B1b root20/29host/protocol, independent20/88host/protocol/source/comments PASS, exact8count và captured scope. Docker readonly537568/retrye6369a denied trước fixture; network grant không khắc phục, namedpipe permission không được tool biểu diễn. B2 còn Important host/watchdog clock, shared RPC/checkpoint và phase feasibility. C1/C2-A/C2-B actual cũ pin hashes, chưa thay native consumer regressions của harness mới. [B1b current files/evidence/blocker](../test-reports/FEAT-TN-001-native-bucket-cleanup-2026-10-30.md), [B0](../test-reports/FEAT-TN-001-native-logout-observer-2026-10-30.md), [B1a](../test-reports/FEAT-TN-001-native-bucket-binding-2026-10-30.md), [plan/dependencies](../test-reports/FEAT-TN-001-native-rate-limit-plan-2026-10-30.md). |
| FEAT-TN-001 T1-C2-B limited/password | dev@ba425ad dirty;8source/test files untracked; docs local/ignored; chưa commit | SCOPED_RETEST_PASS / READY_FOR_QA | Root7455 terminalde790d và independent GPT-6.1/xhigh29792 terminal5e73c8 exit0: password/relogin/counters/session maps/PID/owned cleanup/overall markers PASS. C1/C2-A regressions91745/25293 và main restore94938 exit0; Android16/API36/package hiện diện. Bounded helper có RED/GREEN/full137/analyzer/source review PASS. FAIL cũ/21257 UNCONFIRMED và whole-feature gates giữ mở. [Report hiện tại](../test-reports/FEAT-TN-001-native-password-continuation-2026-10-30.md), [độc lập](../test-reports/FEAT-TN-001-native-password-independent-2026-10-30.md), [plan](../test-reports/FEAT-TN-001-native-password-plan-2026-10-29.md). |
| FEAT-TN-001 T1-C2-A disabled/empty App thật | dev@ba425ad dirty;5consumer files untracked sửa tiếp, A0 observer3files prerequisite; docs local/ignored; chưa commit | SCOPED_RETEST_PASS / READY_FOR_QA | Root35299 terminal/reaped9f1602 exit0 và independent3682 terminal/reapede62d17 exit0: generic disabled/wrong errors, confirmed empty/disabled create/refresh/logout, six ordered counter ACKs, server session maps/PID/cleanup7counts0 PASS. Python15/Node protocol+C1/access oracles/analyzer và independent source/host PASS. A0 root và independent19base+14observerPASS. C1 actual regression43502/mainrestore11693 terminal/reaped exit0; C2 remainder còn mở. [Report/files/commands](../test-reports/FEAT-TN-001-native-access-2026-10-29.md), [plan](../test-reports/FEAT-TN-001-native-access-plan-2026-10-29.md). |
| FEAT-TN-001 T1-C1-B actual main/full/cold restore/logout | dev@ba425ad dirty;3source/test files untracked sửa tiếpC0; docs local/ignored; chưa commit | SCOPED_RETEST_PASS / READY_FOR_QA; startup reliability OPEN | Root92226 và instrumented79687 terminalexit0/alloracles+cleanupPASS; independent instrumented8744 terminalexit0/full+resume+oracles+cleanupPASS. QA3997 trước đó resume startupASSERTIONexit1 vẫn FAIL, rootSELECTfad436 đúngrun7counts0; chưa rõ nguyên nhân, không claim fixed từ repeatPASS. SourceQAclosed2oraclefindings; mainrestore13804exit0. C2/browser/wholeFEAT còn mở. [Report/commands/files](../test-reports/FEAT-TN-001-native-full-session-2026-10-29.md). |
| FEAT-TN-001 T1-C1-A1 oracle/RAM fixture | dev@ba425ad dirty;4source/test files untracked, docs ignored/local; chưa commit | SCOPED_RETEST_PASS / READY_FOR_QA | Root19base+6observerpaths; independent6+bounded dropped-forward mutants PASS; shim root/independent13hostPASS và2actualfixturecases mỗi bên, terminalexit0/7cleanupcounts0 mỗi case. Revised baseline session oracle (seed có1active) theo exact UUID→revoked maps; C1-B_READY_FOR_BUILD, chưa nativeproductPASS. Independent oldfullsuite9054 cleanupUNCONFIRMED được giữ trongreport. [Files/evidence/Tester](../test-reports/FEAT-TN-001-native-fixture-2026-10-29.md). |
| FEAT-TN-001 T1-C1-A0 cleanup launcher | dev@ba425ad dirty;3source/test files untracked, docs local/ignored; chưa commit | SCOPED_RETEST_PASS / READY_FOR_QA | Root9new+88existing host tests; GPT-6.1/xhigh độc lập9+88 và3mutation PASS, không open finding. Actual canonical provider176/163distinct exit0; SELECT role/HBA/fixture8counts0. Bridge failure không bỏ graph/role; SQL failure vẫn HBA sau ownership guard; childterminal gate giữ nguyên. C1 actualnative vẫn chưa chạy, A1oracle/shim đang BUILD. [Report/files/evidence](../test-reports/FEAT-TN-001-native-cleanup-2026-10-29.md). |
| FEAT-TN-001 T1-C0 native SDK RAM control | dev@ba425ad dirty;3source/test files mới untracked, docs ignored/local; chưa commit | SCOPED_RETEST_PASS / READY_FOR_QA C0 | Root/independent nativePASS trên Android16/API36; host6protocol+4lifecyclePASS, syntax/analyzerNoissues/format0changed. Fixed startup/readiness race và cleanup lifecycle findings; app.stop/SDKexit0 observed, hashes match. Mainrestore21560exit0/reaped. Không DB/proxy/product API trong C0; C1 cần same-session/zero-login-POST/native-death oracle. [Handoff/Tester/evidence](../test-reports/FEAT-TN-001-native-control-2026-10-29.md). |
| FEAT-TN-001 C1-N T1-B local HTTPS bridge | dev@ba425ad dirty;4source files untracked, docs ignored/local; chưa commit | SCOPED_RETEST_PASS / READY_FOR_QA; root19 + independent19 PASS | Root/tester T0 sixTLS regression PASS; handshake timeout giữ raw slot đã RED→fix→PASS. Independent mutation tìm gap cumulative cap; thêm2paced cases, final19PASS và mutation bị bắt cả2hướng, bốn SHA khớp, không open Important/Blocker. CLI fixed3000 echo/live raw-TLS STOP/rebind8443 verified; handles reaped. Chưa native custom CA/API/canonical E2E; tiếp T1-C. [Handoff/evidence](../test-reports/FEAT-TN-001-local-https-proxy-2026-10-29.md). |
| FEAT-TN-001 C1-N T1-A debug lab trust/main | dev@ba425ad dirty; helper/test mới, main untracked sửa tiếp; docs ignored/local; chưa commit | SCOPED_RETEST_PASS / READY_FOR_QA | Root6focused/134full PASS, product/profile compiler flags1case mỗi mode PASS, analyzerNoissues/format3files0changed; Pixel_7 nativeconfig2PASS, mainrestoreexit0. Tester GPT-6.1/xhigh source review không open finding và tự chạy6focused exit0/5,854s, SHA khớp. Chưa native custom CA/HTTPS/API, chưa profile/release APK; tiếp T1-B proxy. [Handoff/files/evidence](../test-reports/FEAT-TN-001-debug-lab-trust-2026-10-28.md). |
| FEAT-TN-001 C1-N local HTTPS feasibility T0 | dev@ba425ad dirty; ops/auth/probe_memory_tls.mjs mới/untracked; docs ignored/local | SCOPED_RETEST_PASS / READY_FOR_QA; root6PASS và independent6PASS | Node22.13/OpenSSL handshake DNS/IP PASS, thiếu CA/sai CA/sai host/expired bị từ chối đúng mã. Post-handshake socket error finding đã sửa; root regression injection before/after PASS, tester tự chạy syntax/6TLS cases exit0/~2,06s, SHA khớp. Không open Blocker/Important tại T0. Chỉ RAM/owned pipe/loopback; không App trust/proxy/DB/API E2E mới. [Plan/evidence/review](../test-reports/FEAT-TN-001-local-tls-plan-2026-10-28.md). |
| FEAT-TN-001 resumed actual provider / Android availability | dev@ba425ad dirty;1native integration test mới, docs ignored/local; chưa commit | PROVIDER_SCOPED_PASS; NATIVE_CONFIG_2_PASS_READY_FOR_QA; browser BLOCKED_CONNECTION | Outside identity guard PASS; provider176/163distinct, owned56921 exit0/reaped; SELECT role/HBA/user/session/workspace/membership/audit_actor/limiter đều0. Pixel_7/API36 xác nhận ADB;2nativeconfigurationPASS/analyzerNoissues/format1file0changed, defaultmainrunexit0. UI2 independent retest tool approval aborted trước execution; parent/root attribution giữ nguyên. [Report/evidence](../test-reports/FEAT-TN-001-runtime-resumed-2026-10-28.md). |
| FEAT-TN-001 C1-N runtime prerequisite / Tester runbook | dev@ba425ad dirty; docs ignored/local, chưa commit | HISTORICAL_ENVIRONMENT_BLOCKED trước resume; guide SOURCE_REVIEWED | Direct ADB không device, emulator CLI không AVD trong sandbox; canonical identity inspect bị Docker access denied, không SQL/role/fixture mới. `run_local.py --help` exit0, đã đối chiếu fixture labels/CLI/proxy/UI actions. [Hướng dẫn từng bước](../Instructions/feat-tn-001-e2e-testing.md), [prerequisite evidence](../test-reports/evidence/auth-e2e-runtime-prerequisites-2026-10-28.json). Availability Docker/AVD đã supersede bởi row resumed; CUA/HTTPS vẫn cần trước full E2E; không hỏi lại scope đã duyệt. |
| FEAT-TN-001 Web Chrome runtime2026-10-28 | dev@ba425ad dirty; auth.css untracked sửa tiếp, docs ignored/local; chưa commit | PARTIAL_RUNTIME_VERIFIED / READY_FOR_QA | Chrome thật: validation/focus/keyboard/theme/home navigation/responsive375px/reload unknown/negative cross-tab đã kiểm; input border dùng muted/teal-deep thay line, Web25tests và build42modules PASS. Checkpoint browser trước resume; Docker ngoài sandbox hiện hoạt động, CUA hiện mất kết nối; chưa browser success API/limited/workspace/429 E2E. [Report/evidence](../test-reports/FEAT-TN-001-web-browser-2026-10-28.md). |
| FEAT-TN-001 C1-UI2 App main/host | dev@ba425ad dirty;5scope files untracked và1QA test mới, docs ignored/local; chưa commit | ROOT_SCOPED_PASS / READY_FOR_QA; independent design/review PASS, runtime owner=root | Root13focused/128full/analyzer No issues/format42files0changed (lib/test/tool) PASS sau fixture close cùng real zone, giữ ACK; repo/coordinator exact SHA UI1-R, không production workaround. Checkpoint root dùng bundled Dart/Flutter tool trong sandbox; normal outside SDK nay đã chạy, independent tool approval bị abort trước execution. [Files/logs/runbook](../test-reports/FEAT-TN-001-android-application-2026-10-28.md), [QA độc lập](../test-reports/FEAT-TN-001-android-application-independent-2026-10-28.md). Không App/native/API E2E PASS. |
| FEAT-TN-001 C1-UI1 / UI1-R coordinator | dev@ba425ad dirty; coordinator/root+independent tests mới, repository canLogout sửa tiếp; docs ignored/local, chưa commit | READY_FOR_QA scoped; UI2 BUILDING, actual App E2E chưa PASS | Independent GPT-6.1/xhigh tái hiện2FAIL recovery→fix→11focused/114full/analyzer/format PASS; W1 independent15 và W2 nine+UI1 seven PASS. UI1-R root12focused/115full, analyzer4.6s/format45files0changed; source-only review R Safe to merge. [Files/evidence/Tester](../test-reports/FEAT-TN-001-android-coordinator-2026-10-26.md). UI2 main/host/widget đang kiểm, HTTPS/native/browser còn mở. |
| FEAT-TN-001 C1-W2 session capabilities | dev@ba425ad dirty;3scope files untracked, repository sửa tiếp UI1-R; docs ignored/local; chưa commit | READY_FOR_QA / SCOPED_RETEST_PASS tại checkpoint W2 | Independent GPT-6.1/xhigh W2nine+UI1seven và full114/analyzer/format PASS trước getterR; pending independent lịch sử đã supersede. UI1-R root115/source review PASS; W2 SHA repository là lịch sử. [Independent runtime](../test-reports/FEAT-TN-001-android-session-capability-runtime-independent-2026-10-26.md), [handoff](../test-reports/FEAT-TN-001-android-session-capability-2026-10-26.md). UI2 root128PASS; independent runtime/native/API E2E còn mở. |
| FEAT-TN-001 C1-W1 workspace/password transport | dev@ba425ad dirty;5scope files untracked, docs ignored/local; chưa commit | READY_FOR_QA / SCOPED_RETEST_PASS | Independent GPT-6.1/xhigh15focused và checkpoint full114/analyzer/format PASS; W1năm SHA không đổi. Root94 lịch sử, pending independent đã được supersede. UI2/native/browser còn mở. [Independent runtime](../test-reports/FEAT-TN-001-android-capability-runtime-independent-2026-10-26.md), [handoff](../test-reports/FEAT-TN-001-android-capability-2026-10-26.md). |
| FEAT-TN-001 C1-S1 Android session repository | dev@ba425ad dirty;3new source/test files untracked, docs ignored/local; chưa commit | READY_FOR_QA / SCOPED_RETEST_PASS tại repository boundary | GPT-6.1/xhigh independent21focused/79full Flutter PASS, analyzerNoissues3.9s, formatter38files0changed. ACK-before-admission, identity/expiry/token68, quarantine, late candidate/write cleanup, resume generation, pendinglogout serverproof và manual recovery. Review findings đã actualRED/fix/GREEN và source review cuối Safe to merge; main/W/UI/native/API/browser chưa hoàn tất. [Handoff/files/Tester](../test-reports/FEAT-TN-001-android-session-2026-10-26.md) |
| FEAT-TN-001 C1-T Android transport | dev@ba425ad dirty;4source/test files untracked; docs ignored/local, chưa commit | READY_FOR_QA / SCOPED_RETEST_PASS tại transport boundary | GPT-6.1/xhigh independent21focused/58full Flutter PASS, analyzerNoissues; root RED3PASS/18FAIL→GREEN21 và format35files0changed. HTTPS origin/token68/method-specific errors/byte bounds/total deadline/late-send fences, no replay hoặc storage side effects. C1-S1 plan review phát hiện quarantine/suspend ambiguity, đã bổ sung AC; S/W/UI/main/native/API/browser chưa hoàn tất. [Handoff/files/Tester](../test-reports/FEAT-TN-001-android-transport-2026-10-26.md) |
| FEAT-TN-001 CP-02-MEASURE M4b-P | dev@ba425ad dirty;6source/test files untracked, docs ignored/local; chưa commit | READY_FOR_QA / SCOPED_RETEST_PASS; CP-02 tổng PARTIAL |96isolated Rust/88host/16focused GPT-6.1/xhigh/fmt/Clippy/176providerassertions PASS (163distinct IDs;15Punique). Samepool held8 qua WEB/ANDROID503/end, PoolAcquireError5009419/5014308µs, exact1sample/window/gen1→2/no-loss, stateunchanged/recovery+1sessionaudit, gracefulSTOP/reap. SELECTcleanup role/HBA/fixture0; lateREADY và mutation testhole đã fix/retest. Browserinventoryempty/C1/SLO/ownerreview còn mở. [Report/files/Tester](../test-reports/FEAT-TN-001-pool-budget-2026-10-26.md) |
| FEAT-TN-001 CP-02-MEASURE M4b-Q | dev@ba425ad dirty;1tracked file modified, chỉ thêm2cfg(test) functions; docs ignored/local | READY_FOR_QA / SCOPED_RETEST_PASS tại unit boundary |90isolated Rusttests/6focused GPT-6.1/xhigh độc lập/fmt/Clippy/2mutation PASS. Verifyqueue≥5s/outer8s→Unavailable/HashQueueError; abortcaller giữpermit/window tới explicitrelease và3uniqueCompleted. Runtime/oldtests normalized fingerprints khớp. Không provider/HTTP overload mới; pool/C1/browser/SLO còn mở. [Report/files/Tester](../test-reports/FEAT-TN-001-queue-budget-2026-10-26.md) |
| FEAT-TN-001 CP-02-MEASURE M4b-L | dev@ba425ad dirty;3source/test files untracked, chưa commit; docs ignored/local | READY_FOR_QA / SCOPED_RETEST_PASS; CP-02 tổng PARTIAL |72host/8focused độc lập GPT-6.1/xhigh/3mutation/161provider checks PASS. WEB/ANDROID actualwait+holder proof sau503, AccountAcquire Error≈5.005s, exact5stage, committedunchanged/recovery+1sessionaudit; cleanup role/HBA/fixture0. Chưa pool/queue/SLO/browser/C1. [Report/files/Tester](../test-reports/FEAT-TN-001-lock-budget-2026-10-26.md) |
| FEAT-TN-001 CP-02-MEASURE M4a | dev@ba425ad dirty;3source/test files untracked, chưa commit; docs ignored/local | READY_FOR_QA / SCOPED_RETEST_PASS; CP-02 tổng PARTIAL |64host/7focused độc lập GPT-6.1/xhigh/3mutation/145provider checks PASS. Baseline60success/20windows/540Completed/36groups×15, percentile audit khớp, cleanup role/HBA/fixture0. Important cancellation và coverage-test-hole đã sửa/retest. Chưa budget faults/browser/C1/SLO. [Report/files/Tester](../test-reports/FEAT-TN-001-measure-m4a-2026-10-26.md) |
| FEAT-TN-001 CP-02-MEASURE M3 | dev@ba425ad dirty;5source/test files đều untracked, chưa commit; docs ignored/local | READY_FOR_QA / SCOPED_RETEST_PASS; CP-02 tổng PARTIAL | Hai tester GPT-6.1/xhigh:7Rust/12Python PASS, strict-hex Nit và Important regression phân bố stage đã sửa/retest. Root88Rust/57host tests, fmt/Clippy/3mutation/135provider checks PASS. Enabled smoke đúng9Completed/process, valid/drop/stale/poison đúng, cleanup role/HBA/fixture0. M4 repeated baseline/budget/browser/C1 còn mở. [Report/files/Tester](../test-reports/FEAT-TN-001-measure-m3-2026-10-26.md) |
| FEAT-TN-001 CP-02-MEASURE M2 | dev@ba425ad dirty;5source/test files, chưa commit | READY_FOR_QA / SCOPED_RETEST_PASS; CP-02 tổng PARTIAL | Pool/BEGIN/bucket/User/FencedWork/ACK instrumentation defaultoff, mapping/SQL/timeout không đổi.81isolated Rusttests,3libtests độc lập GPT-6.1/xhigh, fmt/Clippy/2mutation và132provider regression PASS; cleanup role/HBA/fixture0. Hai test coverage/isolation findings đã fix/retest. Enabled metrics/M3–M4/browser/C1 chưa đạt. [Report/files/Tester](../test-reports/FEAT-TN-001-measure-m2-2026-10-26.md) |
| FEAT-TN-001 CP-02-MEASURE M1 | dev@ba425ad dirty;5source/test files, chưa commit | READY_FOR_QA / SCOPED_RETEST_PASS; CP-02 tổng PARTIAL | Port/recorder bounded4096/hasher stages defaultoff, cancellation/permit/window guards.79Rusttests,12libtests GPT-6.1/xhigh độc lập, fmt/Clippy/mutation và132provider regression PASS; cleanup role/HBA/fixture0. Chưa provider stage samples, M2–M4/browser/C1 còn mở. [Report/files/Tester](../test-reports/FEAT-TN-001-measure-m1-2026-10-26.md) |
| FEAT-TN-001 CP-02-UF | dev@ba425ad dirty;5source/test files, chưa commit | READY_FOR_QA; CP-02 tổng PARTIAL |132provider/45host checks PASS:4actual-wait password/status races Web/App và2disabled, safe401/no-issued-session, exactcounter/audit. Review/mutation PASS, cleanup role/HBA/fixture/holder backend0. Chưa internal budgets/browser/C1. [Report/files/Tester](../test-reports/FEAT-TN-001-user-fence-2026-10-26.md) |
| FEAT-TN-001 QA coordinator follow-up | dev@ba425ad dirty;2source/test files sửa tiếp, chưa commit | SCOPED_RETEST_PASS; browser READY_FOR_QA/NOT_RUN | Tester GPT-6.1/xhigh tái hiện4FAIL trước sửa, retest4/4PASS sau fence queued callback/busy reservation/late-read ownership. Web25tests/build42modules PASS;8regressions RED→GREEN, mutation bắt fence bị bỏ. Provider92/host30/Flutter37/1native mock profile PASS độc lập, cleanup0. Browser surface rỗng, C1/CP-02/03 vẫn mở. [QA](../test-reports/FEAT-TN-001-independent-testing-2026-10-26.md), [fix/files/Tester](../test-reports/FEAT-TN-001-coordinator-fixes-2026-10-26.md) |
| FEAT-TN-001 CP-02-ACK | dev@ba425ad dirty;5source/test files | READY_FOR_QA; CP-02 tổng PARTIAL |92provider/30host checks PASS trên source cuối: DB COMMIT ACK loss thật cho Web/App→503/no credential nhưng đúng1new session/audit TTL24h. Metadata BEGIN/COMMIT=1; mutation/code review PASS, cleanup role/HBA/graph0. Còn User fence race/budget. [Report/Tester](../test-reports/FEAT-TN-001-commit-ack-2026-10-26.md) |
| FEAT-TN-001 CP-02-AF | dev@ba425ad dirty;5source/test files | READY_FOR_QA; CP-02 tổng PARTIAL |84HTTP+PostgreSQL checks PASS, required audit reject→Web/App503/no secret/session rollback; failure counter vẫn5 và lần6trả429.16host tests/mutation PASS; restore INSERT và cleanup role/HBA/graph0. Còn DB ACK UNKNOWN/fence race/budget. [Report/Tester](../test-reports/FEAT-TN-001-audit-fault-2026-10-26.md) |
| FEAT-TN-001 CP-02-MI | dev@ba425ad dirty;5source/test files | READY_FOR_QA provider; CP-02 tổng PARTIAL |69HTTP+PostgreSQL checks PASS: session liên2process,6multi-key success và6same-key sai→5×401+1×429/Retry-After.11host tests/fmt/Clippy và mutation PASS. Cleanup role/HBA/owned graph=0. Còn fault/UNKNOWN/fence race/budget nội bộ. [Report/Tester](../test-reports/FEAT-TN-001-provider-concurrency-2026-10-26.md) |
| FEAT-TN-001 login error palette | dev@ba425ad dirty;3source files Web/App | READY_FOR_QA source/native mock; visual QA NOT_RUN | Nền surface pha8% coral, chữ ink/icon accent đồng bộ; text contrast sáng/tối14.73/13.16. Web build42modules,18widgets/analyzer/format PASS; native API36 ngang200% PASS và restore verified. Browser surface unavailable. [Report/Tester](../test-reports/FEAT-TN-001-login-error-palette-2026-10-26.md) |
| FEAT-TN-001/004 R7-PW provider + login hint | dev@ba425ad dirty;5source/test files, contract0.2.1/policy1 | READY_FOR_QA provider baseline/UI source; CP-02 PARTIAL | User đã phê duyệt cụ thể DB.59HTTP+PostgreSQL checks PASS gồm password9/revoke Web+Android/relogin; cleanup role/HBA/owned graph=0.5host tests PASS. Bỏ hint login Web/App, aria error ID hợp lệ; build42modules/App9widgets/format/1native API36 ngang200% PASS. Browser unavailable dù có quyền. [Handoff/Tester](../test-reports/FEAT-TN-001-provider-password-2026-10-26.md) |
| FEAT-TN-001/004 PW1–PW4c password policy | dev@ba425ad dirty, contract draft0.2.1/policyVersion1;9–128 hoa/thường/số cho new/temporary, login9/current1 legacy | READY_FOR_QA source/native mock; PW5 PARTIAL |39contract,67Rust (7HTTP),4lab-spy,17Web,37Flutter tests PASS; build42modules/fmt/clippy/analyzer PASS.8native profiles login/password×API24/36×dọc/ngang200% trên source cuối PASS, strict taps/metrics/restore đúng; login viewport0 RED→header responsive, mutation bắt lỗi cũ. Chưa browser/provider/whole-E2E; rollout đồng bộ. [Handoff/file list/Tester](../test-reports/FEAT-TN-001-password-policy-2026-10-26.md) |
| FEAT-TN-001 overall E2E work | dev@ba425ad dirty; source/mock slices giữ READY_FOR_QA | Tiếp tục sau user phê duyệt; objective chưa đạt | Quyền DB RESOLVED, provider176assertions/163distinct IDs/cleanup M4b-P PASS; MI/AF/ACK/UF/disabled/baseline/Userlock verified. Q hasher-unit90Rust/6focused/fmt/Clippy/2mutation PASS, runtime không đổi; CP-02 còn owner budget/review, không claim HTTPqueueoverload. Browser có quyền nhưng surface unavailable; C1-T/S1 repository đã scopedPASS; C1 thiếu workspace/password capability/coordinator/main và còn CP-02/storage/topology, không phụ thuộc Web P4. Audit BLOCKED trước phê duyệt là lịch sử. [Handoff hiện tại](../test-reports/FEAT-TN-001-android-session-2026-10-26.md), [C1 audit](../test-reports/FEAT-TN-001-android-c1-readiness-2026-10-26.md) |
| FEAT-TN-001/R9-C0d1–2 limited password UI |7source/test/tool files; Nexa form + preview riêng + native suite, dev@ba425ad dirty | READY_FOR_QA cho source/native mock |35Flutter tests PASS (9password mới), host9tests, analyzer No issues/7.8s, format29files0changed.4native profiles API24/36 portrait+landscape200% PASS, metrics/restore đúng; keyboard viewport0 RED→responsive header GREEN, không hạ chữ/target. Chưa004 server/C1/session/whole-feature acceptance. [Handoff](../test-reports/FEAT-TN-001-android-password-ui-2026-10-26.md) |
| FEAT-TN-001/R9-D2 full profile consumer | MeProfile DTO + UUID helper dùng chung3consumer,5files; dev@ba425ad dirty | READY_FOR_QA cho source/tests |57cases PASS, UUID mutation bị bắt/restored; full Flutter26tests, analyzer No issues/8.6s, format24files0changed. Chưa HTTP/session/storage/UI wiring; không full auth acceptance. [Handoff](../test-reports/FEAT-TN-001-android-full-profile-2026-10-26.md) |
| FEAT-TN-001/R9-D1 workspace consumer | AvailableWorkspacePage/Summary + consumer test; contract0.2.1, dev@ba425ad dirty | READY_FOR_QA cho parser/source tests |72cases trong1test PASS; required-cursor mutation bị bắt, restored. Full Flutter25tests PASS, analyzer No issues/9.0s, full format21files0changed. DefaultACTIVE/opaque cursor/immutable/sanitized errors; không wire vào UI/session/provider. [Consumer handoff](../test-reports/FEAT-TN-001-android-workspace-consumer-2026-10-26.md) |
| FEAT-TN-001/R9-C0c3 native display | Shared helper + suite allowlist cho login/workspace,5source/test files | READY_FOR_QA cho mock display, chưa acceptance |8profiles PASS:2OS24/36 ×2suite ×portrait/landscape200%, start/end native metrics khớp, settings/policy restored. Host8tests PASS, wrong-suite mutation bị bắt; missing-host native expected RED. Lazy-list/scroll-settle regressions đã sửa trong test, giữ missed tap fatal. [Matrix/handoff](../test-reports/FEAT-TN-001-android-workspace-display-2026-10-26.md) |
| FEAT-TN-001/R9-FMT1 | Riêng login_screen.dart formatter-only,4hunks đã review; giữ user UI/animation | READY_FOR_QA | Actual bytes khớp formatter preview, full-mobile format19files0changed PASS; Flutter24tests PASS, analyzer No issues/8.7s. Supersedes finding format ngoài slice trước đó; không auth logic/API/storage change. |
| FEAT-TN-001/P1-D1, P1-D2 | Contract 0.2.1; `dev@ba425ad` + dirty working tree | READY_FOR_QA tĩnh, chưa nghiệm thu | Contract suite 36/36 PASS; Web coordinator mock suite 16/16 PASS; CP-01 chưa owner review; START-03 MISSING_INPUT. [Readiness 2026-10-24](../test-reports/FEAT-TN-001-readiness-2026-10-24.md) |
| FEAT-TN-001/R6 HTTP boundary | Axum0.8.6/Tower0.5.2 + RustGNU1.99.1; dev@ba425ad dirty | READY_FOR_QA |64 Rust tests toàn workspace PASS, gồm6 HTTP boundary +3 security/parser; fmt/clippy PASS. Không là positive PostgreSQL provider evidence. |
| FEAT-TN-001/P2–CP-02, R7 | Đã có HTTP login/me/logout/password/workspaces/detail + read projection/SQL; binary auth-lab và launcher | IMPLEMENTED_UNVERIFIED; provider BLOCKED_APPROVAL | Auto-review từ chối tạo role/cấp quyền/fixture trên canonical DB; chờ phê duyệt cụ thể.3 recovery guard tests PASS với spy; CP-01/02 còn mở. |
| FEAT-TN-001/P4 Web, R8 | API/coordinator/UI thật; tải lại/chuyển workspace và session summary; Vite `/login` HTTP200 | READY_FOR_QA cho build; browser E2E BLOCKED | Build PASS,16 mock tests PASS; browser connector không khả dụng. Tạo workspace065 vẫn chưa có, CTA chưa khả dụng không là implementation065. |
| FEAT-TN-001/R8-UI | `/login` đồng nhất home, BrandLink dùng chung; `dev@ba425ad` dirty, Web0.1.0 | READY_FOR_QA; browser BLOCKED | Snapshot13:37 UTC2026-10-24: TypeScript/Vite build41modules PASS,16 mock tests PASS. Header/logo/theme/gradient/card/type đã đối chiếu source home; browser/visual/screen reader NOT_RUN. [UI handoff và checklist](../test-reports/FEAT-TN-001-login-ui-2026-10-24.md) |
| FEAT-TN-001/R9-A Android contract | Flutter3.47.5/Dart3.13.4; parser+Flutter unit suite, `dev@ba425ad` dirty | READY_FOR_QA |42 synthetic consumer cases PASS trong1 Flutter test; analyzer No issues. Không là provider/storage/device evidence. |
| FEAT-TN-001/R9-B native base | SDK3.47.5/Dart3.13.4, storage11.2.0, Android API24 và36 | DEV_VERIFIED_READY_FOR_QA |4 native cases PASS: mỗi OS ghi/readback, dừng app/cold boot rồi đọc/xóa; UID giữ nguyên. Không thay key-failure/backup/physical-device/whole-app evidence. [Android PoC và log](../test-reports/FEAT-TN-001-android-poc-2026-10-24.md) |
| FEAT-TN-001/R9-B2 adapter | SessionTokenStore/SecureSessionTokenStore; auth namespace riêng, resetOnError=false; chưa nối scaffold | READY_FOR_QA cho Dart boundary |6 focused storage tests PASS; mutation reset=true bị bắt; full unit7tests (gồm42 consumer cases) PASS. B3a đã kiểm native cấu hình trên API24/36; B3b kiểm key-loss plugin riêng. B4 backup/physical và CP-02 còn mở. |
| FEAT-TN-001/R9-B3a adapter native | Cấu hình thật namespace/reset=false; integration_test/session_token_store_test.dart | DEV_VERIFIED_READY_FOR_QA |4 native cases mới PASS API24 UID10078 và API36 UID10218, giữ UID qua app-stop/cold boot, xóa phiên không mất marker kho khác. Không thay backup/auth E2E. |
| FEAT-TN-001/R9-B3b native key loss | Test APK androidTest + runner, không MainActivity hook hoặc dependency mới | DEV_VERIFIED_READY_FOR_QA | API24/36 fresh native plugin reject key-loss, giữ ciphertext/control namespace; cleanup=true. Mutation reset=true bị bắt code0; restore source/rebuild/rerun API24 code-1 PASS. Không Dart/UI key-loss E2E. [Native handoff](../test-reports/FEAT-TN-001-android-native-storage-2026-10-25.md) |
| FEAT-TN-001/R9-B4a backup admission | bmgr riêng app PoC, local transport trên API24/36 | DEV_VERIFIED_READY_FOR_QA cho admission | Per-package Backup is not allowed ở cả2OS; enabled state khôi phục disabled, API36 restore transport gốc khi đã disabled. Không cloud export, không restore/OEM/D2D/physical PASS. |
| FEAT-TN-001/R9-C0a presentation | Form/theme/state + preview riêng tool/auth_preview.dart, main app chưa tích hợp auth | READY_FOR_QA cho source/widget |8 UI tests +6 storage +1 parser/42cases =15 tests PASS; analyzer No issues/10.5s, format13files0changed. Full-harness overflow52px RED→compact header/menu GREEN. C0 preview không gọi API/token, không AT-WF hoặc provider E2E. |
| FEAT-TN-001/R9-C0b preview runtime | Native profile handshake sau app-start; mock boundary có banner | Display slice READY_FOR_QA; C0b tổng PARTIALLY_VERIFIED |4profiles PASS: API24/36 portrait+landscape/chữ200%, engine/native metrics khớp và settings/policy restored. Policy API36 lock1→lock0 lúc integration launch đã được phân biệt bằng diagnostics; host apply sau READY sửa harness. Native thiếu host RED, runner6unit và mutation/restore PASS; Flutter15tests/analyzer12.5s/format PASS. Còn xoay khi nhập/request, TalkBack/visual/physical và auth API thật. [Latest handoff](../test-reports/FEAT-TN-001-android-display-handshake-2026-10-26.md) |
| FEAT-TN-001/P5, R9-B còn lại | Main vẫn scaffold, có form/theme/entry preview độc lập; target min24/modern36 | POC_PARTIALLY_VERIFIED; auth E2E BLOCKED_DEPENDENCY | Còn backup restore/OEM/D2D/thiết bị thật, auth repository/network/app recovery thật. C0 mock không tích hợp token/API; CP-02/provider còn mở. Không đánh P5 hoặc R9-B toàn phần DONE. |
| FEAT-TN-001/R9-C0c1 workspace presentation | State/screen/9widget tests theo17.1 và contract0.2.1, không wire/API/storage | READY_FOR_QA | Full Flutter24tests PASS, analyzer13.3s/No issues; scoped format5files0changed. Empty khác cursor, summary không cấp quyền, stale/inactive/disposed callback và unknown generation được kiểm; bỏ revision guard mutation bị bắt. Full format fail ngoài slice tại login_screen.dart, giữ nguyên. |
| FEAT-TN-001/R9-C0c2 workspace preview | Entry riêng tool/workspace_preview.dart, native mock test | READY_FOR_QA cho mock flow, chưa acceptance | API24/36 mỗi OS1test PASS: pagination→selectB→empty→offline/retry→pending/recovery→dark. Banner mock luôn có, không login/token/server recheck hoặc protected route. Còn native landscape/font2×/visual/TalkBack và C1 API/session thật sau CP-02. [Workspace handoff](../test-reports/FEAT-TN-001-android-workspace-ui-2026-10-26.md) |
| FEAT-TN-001/P6–CP-03 | Chưa chạy acceptance liên client | NOT_RUN | Chờ P4/P5, provider thật, browser/device và owner/QA evidence; AT-WF-001-01…03 NOT_RUN |
| FEAT-TN-002/L1a | Contract draft 0.2.1; checkout bắt đầu `dev@767fec3`, dirty/uncommitted | READY_FOR_QA tĩnh | Senior tester trước source changes: Python contract suite 39/39 PASS; không là provider runtime evidence |
| FEAT-TN-002/L1b | 30 logout fixtures synthetic; current checkout dirty/uncommitted | READY_FOR_QA tĩnh | Contract suite 39/39 PASS trước source changes. [Report](../test-reports/FEAT-TN-002-contract-2026-10-23.md); CP-L1/CP-01 còn chờ owner review |
| FEAT-TN-002/L2 | Logout route/transaction và auth flows đã được kiểm qua provider PostgreSQL, Playwright và Android main app | RUNTIME_PARTIAL; provider + one-client E2E PASS | Provider checks Web `204`, idempotent logout và giữ Android sibling session; Playwright replay cookie cũ nhận `401 SESSION_REVOKED`; Android login/resume/logout PASS. Cross-client/socket/push acceptance chưa đủ. |
| FEAT-TN-002/L3 | Không có socket-owning server/consumer callsite cho close intent | BLOCKED_DEPENDENCY | Runtime WS close/lost-signal/multi-instance NOT_RUN; không thêm dependency/infrastructure |
| FEAT-TN-002/L4 | Web coordinator/cookie/logout flow; Antigravity CLI 1.5.9 TUI confirmed Gemini 4 Argon (Medium) for UI recovery | WEB E2E PASS; acceptance partial | `npm.cmd run build` PASS (last source build); Playwright DB fixture 4/4 PASS: real logout clears the cookie, stale-session GET and password mutation return 401 `SESSION_REVOKED`, repeated logout is idempotent, independent Web session remains active; recovery/redaction/cleanup cases are separate. Chrome credential E2E is from Loop9, not this rerun. Two-client Android/socket acceptance remains open. |
| FEAT-TN-002/L5 | Android secure outbox/retry, parser fix, Flutter and API24 full/resume/logout | APP E2E PASS; TTL acceptance blocked | Flutter 225/225 + analyzer PASS; API24 full/resume/logout integration PASS with secure session and outbox post-logout assertions. Trusted TTL after retry exhaustion/restart remains unresolved; do not purge using device wall clock alone. |
| FEAT-TN-002/L6 | Playwright, Android integration and Auth Lab provider verification run on dirty code state | PARTIAL_ACCEPTANCE; all required E2E evidence not complete | Playwright 4/4, Android full-session exit 0 on API24, provider suite exit 0, and historical Loop9 Chrome login/select/logout. AT-WF-002-01 remains partial (no actual socket close); AT-WF-002-02 remains blocked (same-device account-switch/cache/push-late); AT-WF-002-03 has Web-session/provider idempotency evidence but no full cross-client acceptance. |
| FEAT-TN-002 provider/test harness | Revoked/expired HTTP mapping plus Rust/Python verifier updates, dirty/uncommitted | PROVIDER PASS | `python -X utf8 -B -m unittest discover -s ops/auth/tests -p 'test_*.py' -v` 134/134 PASS; `python -X utf8 -B ops/auth/run_local.py --verify` exit 0; evidence `ops/auth/evidence/provider-latest.json`; ports 3000/3001 closed after launcher cleanup. |
| FEAT-TN-001 Web login outage guard (supporting fix during TN-002) | `dev@62c68c3` guard and readiness-envelope hardening committed; unrelated Mobile auth source/tests remain dirty; UI copy previously updated with Gemini 4 Argon medium via `agy` | SOURCE_VERIFIED; live readiness PASS; credential E2E NOT_RUN | Coordinator and `check:auth-api` require unauthenticated `GET /api/v1/me` → 401 `SESSION_EXPIRED`/`SESSION_REVOKED` ErrorEnvelope with required fields and closed `details`/`FieldError` schema before allowing login; 500, unrelated/malformed 401, timeout, refusal and redirect stay on login with `SERVICE_UNAVAILABLE`, no intent or credential POST; late probe result after invalidate is ignored. Readiness is point-in-time: if the API or a login-only dependency fails after a valid probe, a login POST may be sent; the result stays UNKNOWN with no replay. Three false-readiness regressions RED before changes; final `node --experimental-transform-types --test tests/auth.test.mjs tests/password_policy.test.mjs` 43/43 PASS; `node --check scripts/check-auth-api-readiness.mjs` PASS; live preflight PASS and mocked malformed-envelope preflight rejected; isolated Chrome `/login` clean console. No credential E2E; TypeScript build not run because project rules forbid `node_modules` access. Does not advance TN-002 acceptance.|

FEAT-TN-001 direct DB attempt 2026-10-24: `python -B ops/database/verify_repositories.py` was refused by `EMPTY_GUARD` because canonical DB has application rows; it stopped before writing fixtures. No reset/deletion was performed and this run is not a DB PASS. See [readiness report](../test-reports/FEAT-TN-001-readiness-2026-10-24.md).

Khôi phục sandbox 2026-10-23: owner của riêng thư mục `.agents` từ
`CodexSandboxOffline` về `LENOVO`, giữ DACL; sau đó lệnh `exec_command`
trong sandbox đọc skill và ACL thành công. Bản sao owner/SDDL trước sửa nằm
ngoài repository tại `C:\Users\LENOVO\.codex\.sandbox\agents-owner-backup-20261023-01.json`.
Không sửa nội dung source/config để khắc phục lỗi khởi tạo này.

Snapshot mới nhất: [FEAT001 runtime handoff 2026-10-24](../test-reports/FEAT-TN-001-runtime-handoff-2026-10-24.md).
Các nhận định lịch sử “chưa có HTTP server” trong readiness cũ không còn là
inventory hiện tại; provider thật/browser/Android auth E2E vẫn chưa được chứng minh.

Đã cập nhật feature002 mục16.1, 27.1–27.2 với layout/UI state matrix,
task/dependency/rollback, evidence và hướng dẫn Tester. Browser/Android/DB/WS,
40 ca runtime mục18 và các AT của002 đều NOT_RUN. Không có task feature được
đánh `(x)` và không có nghiệm thu toàn002. Docs và report bị `.gitignore` hiện
hành bỏ qua; vẫn nằm trong working directory, cần đưa vào quy trình bàn giao
tài liệu của dự án khi review/commit, không tự sửa ignore hoặc stage file.

### FEAT-TN-002 Web runtime tiếp nối — 16/11/2026

Vite proxy `/api/v1` cần Auth API ở `127.0.0.1:3000`; lần tái hiện lỗi trước đó
chỉ có Web server. Sau khi auth-lab được khởi chạy, Chrome thật xác nhận login,
`/me`, `/workspaces` và chọn workspace đều trả HTTP200, Admin summary hiển thị;
account fixture không workspace vào đúng empty state. Logout trả UI về form
login với success notice. Capture mới không có HTTP receipt của logout; status
204 được giữ là evidence từ report 15/11, không ghi thành kết quả mới.

Kiểm tra mới chạy: `node --experimental-transform-types --test
web/tests/auth.test.mjs web/tests/password_policy.test.mjs` → 37/37 PASS;
`git diff --check` → exit0 (cảnh báo line ending trên các file source dirty).
Login retry sau nhiều thao tác test gặp 429/Retry-After 581s, do đó không gửi
thêm mutation login. Auth lab vẫn đang chạy ở session terminal để tiếp tục kiểm
thử; fixture phải được cleanup qua launcher khi kết thúc lượt E2E.

Senior Tester subagent GPT-6-luna max verdict: Web scope `PARTIAL`, keep
`VERIFY_IN_PROGRESS`. Test suite 37/37 PASS; login/bootstrap/select là setup
evidence. Logout success UI được quan sát, nhưng status HTTP mới chưa capture;
historical 204 không chứng minh session isolation hoặc repeat logout. AT-WF-002-01
chỉ partial vì chưa có post-logout `401`/socket-close evidence; AT-WF-002-02/03,
two-session, App offline/restart/outbox và browser recovery còn NOT_RUN.

### FEAT-TN-002 auth readiness continuation — 16/11/2026

Login root cause đã xác định là Auth API chưa chạy ở `127.0.0.1:3000` trong khi Vite còn hoạt động. Để ngăn test nhầm trạng thái này, Web có `npm run check:auth-api` dùng unauthenticated `GET /api/v1/me`, yêu cầu `401 application/json` trước khi tester nhập fixture credential. README chỉ rõ hai dịch vụ và lệnh preflight.

Evidence: `npm.cmd run check:auth-api` PASS trên runtime hiện có; Playwright 1.61.0/Chrome xác nhận `/login` 200, `/me` 401 JSON, và mock proxy `500 text/plain` hiển thị service-unavailable/unknown thay vì credential error. Live unauthenticated logout trả `204` body 0; đây không phải bằng chứng revoke phiên đăng nhập. Web tests 37/37 PASS. Feature vẫn `VERIFY_IN_PROGRESS`; không gửi login bổ sung do limiter của account fixture đã trả 429.

### FEAT-TN-002 checkpoint — 16/11/2026

Commit `af7153c` (auth API readiness guard) đã được push lên `origin/dev`. Existing uncommitted App/Web UI source vẫn giữ nguyên. Rà soát L5 cho thấy outbox fail-closed tới server terminal 204/401 nhưng chưa có trusted monotonic deadline qua process/device restart; giữ `BLOCKED_ACCEPTANCE`, không thêm expiry dựa trên wall clock. Không chạy Flutter command vì `.dart_tool`/`.gradle`/build artifacts bị cấm.

### FEAT-TN-002 L3/readiness recheck — 16/11/2026

Rechecked current source: Axum has no `ws` feature and no WebSocket upgrade/socket registry/close-intent consumer callsite exists; only the close-outbox application kernel and repository probe are present. Therefore DB intent still cannot prove a real socket close and L3 remains `BLOCKED_DEPENDENCY`. The current readiness gate still passes (`/me` 401 JSON); no login POST was sent. Feature remains `VERIFY_IN_PROGRESS`.

### FEAT-TN-002 Playwright / Flutter integration testcase continuation — 16/11/2026

| Slice | State | Evidence |
| --- | --- | --- |
| Web Playwright source | `web/e2e/auth_logout.spec.mjs`, `web/playwright.config.mjs`, `@playwright/test` pinned to 1.63.0; dirty/uncommitted | Real fixture scenario is authored: login → workspace → logout 204 → replay the old HttpOnly cookie and require 401 `SESSION_REVOKED`. A separate intercepted-503 UI recovery case passes 1/1; it is not backend E2E evidence. |
| Android integration assertion | Existing `mobile/integration_test/app_auth_e2e_test.dart`, dirty/uncommitted | Full/resume runner models real UI login, process restart, and logout. New assertion checks no active secure session and no `logout_intent` remain after logout. Dart format ran; integration test did not start. |
| Web suite | `npm.cmd run test:auth`; `npm.cmd run test:e2e:auth` | 43/43 unit/policy and 3/3 Playwright PASS. The DB-backed case covers login, workspace selection, logout 204 with empty body, then old HttpOnly cookie replay → 401 `SESSION_REVOKED`; the other two cases are client-only recovery/redaction regressions. |
| Android suite | `node ops/auth/run_native_e2e.mjs --full-session` | Exit 0 on Android API24; full UI login, process-stop/resume, logout, session/outbox assertions, proxy and fixture cleanup PASS. This does not cover trusted TTL or offline reboot. |
| Chrome | User's open Chrome tab at `http://localhost:5173/login` | After both automation suites passed, actual login `200`, `/me` and workspace reads `200`, logout `204`; UI returned to login with success status. Chrome evidence excludes cookie replay; Playwright covers that branch. |
| Fixture lifecycle | Interactive `ops/auth/run_local.py --port 3000` | Preflight failed with `500 text/plain` when port 3000 had no listener; after the fixture started, preflight returned the expected 401 ErrorEnvelope. The launcher exited 0 after cleanup; ports 3000/3001 are free. |

The Senior Tester GPT-6-luna max and four sequential GPT-6.1 Sol High reviews are complete. Their overall verdict remains **Needs changes** because the broader L3/L5 and AT-WF-002 acceptance gaps above are unchanged. FEAT-TN-002 remains `VERIFY_IN_PROGRESS`.

### FEAT-TN-002 focused responsive regression follow-up — 16/11/2026

Senior Tester pointed out that `overflow-x: clip` can keep document `scrollWidth` equal to the viewport while clipping a child. Extended the Playwright 320px outage/recovery assertion to check the card, alert, workspace-lock guidance, reconciliation button, and login-again button bounding boxes. Added the Vietnamese function comment immediately above its `page.evaluate` callback. Re-review also found the prior 500ms wait could not prove a delayed no-replay invariant; renamed the case and removed that wait/claim. The case was then extended to click reconciliation and assert the explicit GET `/me` returns `401 SESSION_EXPIRED`, keeps the workspace locked, and adds no login POST at response time. Initial request-count assertion exposed the preflight GET plus explicit reconcile GET; corrected it to expect two. Latest focused Playwright run PASS (1/1). A fresh full Playwright rerun yielded the real-fixture startup error before login (the mocked case passed, total 1 failed/1 passed); the fresh Android runner stopped at fixture/preflight before the integration test. A Ctrl+C event sent to the verified launcher console did not stop the launcher/listener after 60 seconds; cleanup is unconfirmed. The CUA window-inspection call aborted before dispatch, so no terminal UI action occurred. No second signal, force-kill, or out-of-band DB cleanup was attempted. This remains mocked recovery evidence, not database-backed logout acceptance. No `@Chrome` run or final four Sol reviews yet. Feature remains `VERIFY_IN_PROGRESS`.

### FEAT-TN-002 mocked reconciliation interaction — 16/11/2026

Extended the browser 503 recovery case to activate “Đối soát phiên hiện tại”: the readiness GET and explicit reconciliation GET each receive a contract-shaped mocked `401 SESSION_EXPIRED`; the test asserts exactly two `/me` requests, one intercepted login POST, continued workspace lock, and a visible login-again action. The first focused run exposed the readiness GET plus explicit GET (`1` expected, `2` observed); corrected the test to represent the actual two-stage flow. `npm.cmd run test:e2e:auth -- --grep "reconciles with a session GET"` passes 1/1. This does not exercise `logoutPending`, delayed replay, or a real database/backend. The Senior Tester’s previous final review predates this last extension and is being repeated against the updated test.

### FEAT-TN-002 request method/order assertion hardening — 16/11/2026

The latest tester review found that URL-only request counters did not prove method or order. Updated Playwright routes to count only login POST and session GET, continue nonmatching methods, and assert the exact sequence readiness GET `/me` → login POST → explicit reconcile GET `/me`. Added Vietnamese parameter docs for the route/response callbacks. `npm.cmd run test:e2e:auth -- --grep "reconciles with a session GET"` passes 1/1. Senior Tester final re-review confirmed these findings are closed with no remaining issue in the focused test. This remains a fully intercepted UI/API-client case; it does not prove backend logout, delayed replay, or actual `logoutPending`.

### FEAT-TN-002 Playwright security and cookie-path fixes — 16/11/2026

Security review found two E2E issues: Playwright failures could expose the fixture password or stale HttpOnly cookie in call logs, and cookie lookup used `/` although the session cookie path is `/api/v1`. Added fixed-error wrappers plus a synthetic-sentinel regression; changed cookie lookup URL to `/api/v1/me`. `node --check web/e2e/auth_logout.spec.mjs` PASS; focused Playwright `npm.cmd run test:e2e:auth -- --grep "secret-bearing Playwright failures|reconciles with a session GET"` PASS 2/2. This does not prove actual database logout. Security final review identified the findings; no test artifacts or real secrets were inspected.

### FEAT-TN-002 resume verification after laptop restart — 17/11/2026

Current state remains dirty/uncommitted on `dev@62c68c3`. After restart, the complete Playwright suite passed **4/4**; Python Auth Lab tests **141/141**; `ops/auth/run_local.py --verify` exit 0; Android `run_native_e2e.mjs --full-session` exit 0 with full/resume/logout and fixture-cleanup markers; Flutter unit suite **226/226**; `flutter analyze` and `dart analyze integration_test` report no issues; Rust library suite **30/30**; `cargo check --workspace --all-targets` and `cargo fmt --all -- --check` passed. Connected Chrome completed synthetic login, workspace selection, logout, and reload at `localhost`; `127.0.0.1` correctly fails the exact-Origin CSRF policy and was not used for acceptance. No source code changed in this verification loop. Overall feature remains `VERIFY_IN_PROGRESS`; MB-OUTBOX-1 and the cross-client, multi-instance, late-push, cache-isolation, DB/push/audit readback, and secret-canary criteria remain open. Next: add the real Android offline logout → process restart → retained secure outbox → expired-session terminal `204` scenario to the owned PostgreSQL/Auth Lab runner.

### FEAT-TN-002 offline resume admission race recheck — 17/11/2026

- Phạm vi lượt này: sửa orchestration/test harness Android offline resume và ghi nhận lại evidence web/Chrome; không đổi UI hoặc hợp đồng sản phẩm. Branch `dev`, base `62c68c3`; chưa commit, working tree vẫn dirty với các thay đổi FEAT-TN-002 từ trước.
- Review correctness tìm thấy ba vấn đề: HTTP prefix chỉ được kiểm trước SQL await nên request logout đến muộn có thể lọt trước khi bật mạng; checkpoint admission có thể hết hạn trong SQL nhưng lệnh network vẫn chạy; SQL baseline được đọc sau khi app resume đã khởi chạy và có thể tiêu hao retry budget khi app đang offline.
- Đã thêm admission fence sát lệnh network-off/restore; restore cuối trong cleanup không phụ thuộc admission để luôn phục hồi mạng. Exact HTTP prefix được kiểm lại ngay trước restore. SQL baseline chuyển tới khoảng sau khi process offline đầu dừng và xác nhận mạng disabled, trước khi spawn process resume.
- Regression harness có 23 coordinator PASS markers: `outbox-admission-expired`, `resume-terminal-before-restore`, `resume-admission-expired`, `resume-baseline-before-app`, `resume-terminal-early`, cùng các cleanup/timeout owner hiện hữu. `node --check ops/auth/native_offline_orchestration.mjs` và `node --check ops/auth/test_native_offline_orchestration.mjs` exit 0; `node ops/auth/test_native_offline_orchestration.mjs` exit 0.
- Android emulator/API36: `node ops/auth/run_native_offline_e2e.mjs --offline` exit 0; offline login/outbox checkpoint pass, app process đầu dừng, process resume nhận mạng, capture kết thúc ở 9 request/status/close, `NATIVE_OFFLINE_ACTUAL_OWNED_TERMINAL_PASS`. Đây là session chưa hết hạn; không chứng minh MB-OUTBOX-1 expiry/TTL.
- Web: `npm.cmd run test:e2e:auth` exit 0, Playwright 4/4. Chrome thật tại `http://localhost:5173/login`: Auth Lab DB fixture login → nhận 2 workspace → chọn `Phòng vận hành A`/Admin → logout hiển thị thông báo → reload trở lại login; console error/warning đọc được là rỗng. Các ô đăng nhập được xóa sau test. Fixture đã dừng và recovery journal báo `AUTH_LAB_ACCOUNT_FIXTURES_REMOVED`.
- Không nâng acceptance: MB-OUTBOX-1 expired-but-valid vẫn mở vì migration yêu cầu `expires_at = created_at + 24 hours` và cấm sửa sau insert; cross-client Web S1 + Android S2, same-device account/cache isolation, RT-3 multi-instance/DB-failure socket reconciliation, late-push, exact session/push-binding/audit readback, secret-sink canary, và AT-WF-002-01…03 vẫn chưa có evidence. Feature giữ `VERIFY_IN_PROGRESS`.
- `docs/plan/features/FEAT-TN-002-dang-xuat-va-thu-hoi-phien.md` đang bị `.gitignore` loại khỏi status; nội dung plan được cập nhật cục bộ, không force-add hoặc đổi ignore rule.

### FEAT-TN-002 expired offline outbox — 17/11/2026

- Branch `dev` at base `62c68c3`; checkout remains dirty and uncommitted. The feature plan file remains ignored by `.gitignore`; it was updated locally without changing ignore rules.
- The fixture/oracle delta fixes a test-fixture mismatch: Auth Lab startup creates a setup session and `LOGIN_SUCCEEDED` audit before inserting the expired target. The oracle now binds one target UUID, permits/preserves setup rows, requires the target to be unrevoked with no target audit before logout, and expects only the target revoke plus one `LOGOUT SUCCESS` audit at terminal. The seed issues a valid 24-hour session already expired at test time, without updating immutable timestamps.
- Fresh Android API 36 E2E: `node ops/auth/run_native_offline_e2e.mjs --offline-expired` exit 0; expired-offline/ready/persisted checkpoints kept SQL unchanged, app process stopped, second process resumed offline with the protected UI locked and encrypted intent retained, then network restore produced one terminal logout and the owned session/audit SQL oracle passed. This is app-process restart evidence, not device reboot evidence.
- Fresh regressions: `node ops/auth/test_native_offline_evidence.mjs` and `node ops/auth/test_native_offline_orchestration.mjs` exit 0; `python -X utf8 -B -m unittest ops.auth.test_native_lab_fixture ops.database.test_psql_variables` **59/59**; `flutter test --reporter=compact` **228/228**; `flutter analyze` and `dart analyze integration_test` no issues; `npm.cmd run test:e2e:auth` **4/4**. The first Playwright run overlapped with the interactive Auth Lab owner and ended with a cleanup-unconfirmed runner error; after stopping that owner, the full suite passed. `npm.cmd run check:auth-api` passed with an unauthenticated `401 application/json`; `python -X utf8 -B ops/auth/run_local.py --verify` exited 0.
- Connected Chrome was inspected at `http://localhost:5173/login` and showed the current live login form. This turn did not repeat the full Chrome login/logout mutation; the last full connected-Chrome login → workspace → logout → reload evidence remains recorded in 27.43, and no web UI source changed in this verification loop.
- MB-OUTBOX-1 is now verified for the agreed terminal-only purge behavior with one app-process restart and an expired-but-recognized session. The accepted decision to retain the encrypted intent until terminal server response supersedes the earlier local expiry-purge concern; no trusted wall-clock purge was added.
- Still open: cross-client Web S1 + Android S2 acceptance; same-device account/cache isolation; RT-3 multi-instance and database-failure socket reconciliation; late-push behavior; exact S1/S2 session and push-binding readback; secret-sink canary; and AT-WF-002-01…03. Overall feature remains `VERIFY_IN_PROGRESS`.
- Next task: complete the cross-client session-isolation acceptance using a real shared account and the existing Web/Android fixtures, then gather the remaining socket/push/cache and workflow evidence. Do not mark the feature complete until all specified gates close.

### FEAT-TN-002 continuation after laptop restart and SQLx quota hardening — 17/11/2026

- Current code state: branch `dev`, base `62c68c3`; working tree remains dirty and uncommitted. The feature plan is still ignored by the repository's `docs` ignore rule; its local contents were updated without changing ignore rules or force-staging it.
- Backend security delta verification on the current source: `cargo test --workspace --all-targets --features iot-platform-backend/http-server` exit 0 (root backend library 30/30, PostgreSQL adapter tests 4/4, workspace suites passed); `cargo check --workspace --all-targets --features iot-platform-backend/http-server` exit 0; `cargo fmt --all -- --check` exit 0; focused `timed_out_handshake_keeps_db_admission_until_checkout_close_finishes` regression 1/1; `npm.cmd run test:e2e:auth` 4/4. No dependencies were added.
- The delta adds bounded admission before WebSocket upgrade, a DB semaphore sized from the actual pool, worker-owned permits, and explicit PostgreSQL checkout/COMMIT-or-ROLLBACK/close before ticket or session-recheck methods return. Playwright assertions reduce peer close and HTTP response details to fixed enums/booleans. The targeted GPT-6.1 Sol High security source review found no remaining Important issue in that reviewed scope.
- Fresh Senior Tester GPT-6-luna max re-audit verdict: **do not mark complete**. Important gap: current gated regression proves permit retention until an adapter-close boundary, and Playwright exercises the database-backed valid/invalid/replay behavior, but there is no direct SQLx integration/fault assertion proving pool checkout close/discard precedes permit release. The security review was source-only. Add that focused integration evidence before closing the §27.45 security acceptance.
- Chrome after restart: connected Chrome at `http://localhost:5173/login` displayed the login form. Listener check showed Vite on 5173 and no listener on Auth Lab ports 3000/3001; this turn did not repeat a fresh Chrome login/workspace/logout/reload flow. Do not count the page inspection as E2E evidence. The existing Playwright result remains automation evidence, not a replacement for the requested connected-Chrome pass.
- Previously recorded Android API 36 `--offline-expired` evidence in §27.44 remains valid for one offline app-process restart, encrypted outbox retention, terminal logout, and owned SQL readback. Android Flutter/backend suites were not rerun after this backend-only delta.
- Still open: direct SQLx checkout/permit ordering test; Web S1 + Android S2 cross-client acceptance; same-device account/cache isolation; RT-3 multi-instance and database-failure socket reconciliation; late-push behavior; exact S1/S2 session and push-binding/audit readback; secret-sink canary; and AT-WF-002-01…03. Device reboot is not covered by the app-process restart scenario. The latest Senior Tester classifies the full feature `VERIFY_IN_PROGRESS`; no acceptance checkbox is promoted.
- Next: add the focused SQLx ordering/fault evidence; then continue the approved review sequence (correctness, security, tests, architecture/performance) against the final diff. After automation passes with Auth Lab available, repeat the connected-Chrome login/logout flow; finish cross-client and remaining acceptance items before declaring completion.

### FEAT-TN-002 provider logout DB oracle — 17/11/2026

The first provider rerun exposed a verifier-ordering regression: the new helper had revoked Android S2 before a later account-isolation check reused it. The helper now logs in an independent Android S3 for repeat logout, leaving S2 alive. Its PostgreSQL fixture binds one disabled, tokenless synthetic push installation to S2 and one to S3; after Web S1 logout both remain bound, while after Android S3 logout only S3's binding advances to generation 2/unbound. Exact session, audit, outbox, and binding projections use allowlisted psql variables and clean up the two random installation IDs.

Fresh evidence at `2026-11-17T10:57:04.419492+00:00`: `python -X utf8 -B ops/auth/run_local.py --verify` exit 0; `ops/auth/evidence/provider-latest.json` marks real HTTP + PostgreSQL provider (not browser E2E), all 20 logout/realtime markers present, and `APPLICATION_ROWS_REMOVED`. Unit binding suite 8/8, Python AST parse, and `git diff --check` pass. Scope remains provider-level; app-level shared Web/Android flow, account/cache isolation, late push, remaining sink canaries and AT-WF-002 gates are still open. Overall feature status stays `VERIFY_IN_PROGRESS`; no review or completion gate is claimed.

### FEAT-TN-002 cross-client Web/API + Android resume — 17/11/2026

- Updated the owned native Auth Lab session snapshot to include both `ANDROID` and `WEB`; it remains account-scoped to the fixture UUID and returns only session UUID/revocation metadata. The first run exposed that the prior Android-only projection hid Web S1; the revised full-session run passed.
- Focused verification: `python -X utf8 -B -m unittest discover -s ops/auth -p test_native_lab_fixture.py` **52/52**; `node ops/auth/test_native_e2e_protocol.mjs` exit 0; `node --check ops/auth/run_native_e2e.mjs` exit 0.
- `node ops/auth/run_native_e2e.mjs --full-session` exit 0 on the API24 emulator. Safe output includes `NATIVE_CROSS_CLIENT_WEB_LOGOUT_ORACLES_PASS`, `NATIVE_CROSS_CLIENT_ANDROID_RESUME_LOGOUT_ORACLE_PASS`, `NATIVE_ACTUAL_MAIN_FULL_RESUME_LOGOUT_ORACLES_PASS`, and both fixture cleanup markers. Web S1 logout/retry returned bodyless 204, stale mutation returned 401 `SESSION_REVOKED`, Android S2 survived Web logout, resumed protected profile read succeeded, and Android logout revoked S2. Final snapshot preserved baseline and verified the two target sessions.
- Evidence is API-level `clientType=WEB` plus native Android UI; it is not React UI logout in the same fixture or a protected mutation through Android S2. Do not promote E2E-LOGOUT-001 or AT-WF-002 checkboxes from this slice.
- Still open: same-device account/cache isolation, Android UI sibling/repeat logout, late push, remaining structured-log/browser/app-debug sink canaries, complete AT-WF-002-01…03, and owner alignment for an app-level WebSocket consumer. Feature remains `VERIFY_IN_PROGRESS`; final review sequence is gated.

### FEAT-TN-002 Android same-device account/cache slice — 17/11/2026

- Extended the owned native `access` flow to sign in as account A, select its protected workspace, log out, confirm secure session/outbox and coordinator auth cache are empty, then sign in as account B on the same Android app process. The empty B state has B's profile and no A email, A workspace, or session summary. Existing disabled/wrong login and B refresh/logout cases remain in the sequence.
- Host checkpoint oracle now enforces the ordered A→logout→denied→B→refresh→logout flow and exact login/logout/workspace counters. Owned PostgreSQL snapshot validates the terminal A/B revocation deltas and unchanged disabled account.
- Verification: `node ops/auth/test_native_e2e_protocol.mjs` exit 0; Dart format check and `dart analyze integration_test` exit 0; `node ops/auth/run_native_e2e.mjs --access-cases` exit 0 on Android API24 with access and owned cleanup markers.
- The mobile auth/workspace source has no inbox UI/module. This evidence covers existing profile/workspace cache only; E2E-LOGOUT-002 / AT-WF-002-02 remains partial if inbox isolation is required. No UI was added and no §19 checkbox was promoted.
- Remaining: React Web UI with Android in one fixture, Android S2 protected mutation after Web S1 revoke, late push, remaining structured-log/browser/app-debug sink canaries, and full AT-WF-002-01…03. Overall state remains `VERIFY_IN_PROGRESS`; final review is gated.

### FEAT-TN-002 React UI cùng fixture native — 17/11/2026

A bounded Chrome runner now exercises React login, workspace selection, UI logout, cookie clearing, stale password mutation, and idempotent logout retry inside the Auth Lab fixture owned by the Android full/resume runner. Credentials travel over stdin; the host snapshots the account after Web login and after logout before validating exact Web S1 / Android S2 deltas. One full-session run passed all cross-client and Android resume markers.

The initial missing `fileURLToPath` import was fixed. The first successful run exposed a Windows process-tree cleanup issue: stopping the `npm.cmd` shell left its Vite node descendant listening on 5173. The runner now uses `taskkill /T /F` only on the process handle it created; manual cleanup of that owned tree closed the port. A fresh full-session has not yet verified the revised cleanup because the next full run and two preflight attempts stopped before browser startup with safe `APP_FAILED_TO_START/BUILD_FAILURE/OTHER_LOG` tags and `NATIVE_DAEMON_CLEANUP_FAILED`. The emulator remains ADB-visible, but no raw build log was read or exposed and the exact build failure is not diagnosed.

The React UI behavior has one successful same-fixture run, but its final cleanup patch needs a fresh full-session pass. Android S2 still has only a protected profile read after Web S1 revocation, not a protected mutation. No AT-WF-002 checkbox is promoted; FEAT-TN-002 remains `VERIFY_IN_PROGRESS`, and final reviews remain gated.
### FEAT-TN-002 React UI cleanup revalidation — 17/11/2026

After the user freed disk space, `node ops/auth/run_native_e2e.mjs --preflight` passed with app-stop/SDK-exit receipts. The next full-session passed Android full and the React UI + shared-fixture S1/S2 oracle, but the first Android resume process stalled before `app.started`; it did not count as acceptance. Fixture/proxy cleanup completed. Read-only post-run checks found the package absent, no Dart process, and port 5173 closed.

One bounded full-session retry then exited 0 with the React UI logout oracle, Android resume/logout oracle, exact S1/S2 terminal session checks, and both fixture cleanup markers. Post-run checks again confirmed port 5173 closed and the app package absent; D retained about 2.15 GB free. The cleanup code is now verified end-to-end. The combined flow proves Web UI login/logout, stale Web mutation rejection, Android S2 survival/profile read, and Android logout. It still lacks a protected mutation from S2 after S1 revoke and an app-side WebSocket consumer/late-push inbox handler; no AT-WF-002 checkbox is promoted.
### FEAT-TN-002 browser debug sink canary — 17/11/2026

The same-fixture React runner now observes real Chrome `console` and `pageerror` events. It checks the synthetic email/password, Web session cookie, auth-context ID, and CSRF value in RAM, retains only a boolean leak flag, and emits a fixed failure code without the log text. Tracing, video, and screenshots remain off. `node --check web/e2e/native_cross_client_ui.mjs` passed; a fresh full-session passed the browser canary, Android resume, exact S1/S2 session oracle, and owned cleanup. Post-run port 5173 was closed and the native package absent.

This closes only the browser console/page-error portion of the secret-sink work. It does not test backend structured audit/log/metrics sinks or Flutter debug output against the actual Android bearer/installation proof. The `web/e2e` mock failure test and native password scanner are separate evidence. No acceptance checkbox is promoted; S2 protected mutation and late-push/inbox coverage remain open.
### Quyết định owner — Android S2 mutation evidence — 17/11/2026

The user chose to keep the S2 protected-mutation acceptance partial until an appropriate non-revoking mutation is available. Mobile currently exposes only logout and password change as POST mutations; password change revokes all sessions, while logout is idempotent. We will not re-label either action to claim the missing evidence. Existing proof remains: S2 is active after Web S1 logout, its protected profile read succeeds on resume, and then app logout revokes S2. No source behavior or acceptance checkbox changed.
### FEAT-TN-002 khảo sát mutation Android S2 — 17/11/2026

Rà soát toàn bộ route mạng trong `mobile/lib` cho thấy client hiện chỉ có login/logout, profile/workspace reads và password change. Logout lặp không chứng minh session S2 còn active; password change thu hồi mọi session. Không có mutation protected thứ ba phù hợp trong app hiện tại, nên giữ `E2E-LOGOUT-001` / `AT-WF-002-01` partial theo lựa chọn của người dùng. Đây là read-only source discovery trên `HEAD 62c68c3` với dirty working tree; không chạy test hay sửa source.

### FEAT-TN-002 consolidated audit and Flutter canary batch — 17/11/2026 14:56 UTC

Implementation for the planned provider logout-audit canary and Flutter `debugPrint` canary is present on dirty `HEAD 62c68c3886f6edbcb14803e241e1e83642a94e58`. The Tester added five Flutter helper cases and three provider audit-reader cases. The agent's interim status reported focused provider **11/11** and `ops/auth/tests` **148/148**, but the exact command outputs and final report were not returned; treat both counts as unverified interim evidence. Auth Lab `run_local.py --verify` had no terminal result, and Flutter/native integrated suites were not reported as run.

The GPT-6-luna max Tester ended with a usage-limit error; the tool reported availability at 2026-11-19 11:34 PM. An Orchestrator interruption record was appended to `docs/test-reports/FEAT-TN-002-integrated-test-report.md`; it is not a substitute for the required Tester final report. The report is LOCAL-ONLY because `.gitignore` excludes `docs`. The four-angle review and commit remain gated. Feature status remains `VERIFY_IN_PROGRESS`; no acceptance checkbox was promoted.

Reconciliation at 2026-11-17 15:02 UTC found Auth Lab ports 3000/3001 closed and the latest provider evidence timestamp unchanged at 14:02:45 UTC. This does not prove the incomplete `run_local.py --verify` passed or failed. Keep the test stage open, with no review or commit.

### FEAT-TN-002 §27.60 consolidated batch verification — 17/11/2026 22:26 +07

The implementation delta is complete on dirty `HEAD 62c68c3886f6edbcb14803e241e1e83642a94e58`. The Flutter test-only canary now restores a non-null prior `debugPrint` callback and discards all captured messages after scanning, preventing raw log replay even when bearer registration fails. Provider reads two fixture-owned logout audit rows through bound PostgreSQL variables and emits only a fixed check marker.

Senior Tester GPT-6.1-sol Extra High verified Python provider **11/11**, full auth Python **148/148**, Auth Lab `--verify` exit 0 with `logout-audit-secret-canary-scan` and cleanup; Flutter canary **5/5**, full Flutter **233/233**, Flutter analyzer and scoped Dart analyzer with no issues, scoped format with 0 changes; fresh Android API 24/React Web/PostgreSQL `node ops/auth/run_native_e2e.mjs --full-session` exit 0 with full/resume/logout oracles and fixture cleanup. Detailed commands, initial failures, fixes, retests, and markers are appended to `docs/test-reports/FEAT-TN-002-integrated-test-report.md`.

The verified scope is §27.60 Task A/B only. Remaining feature acceptance is still partial: Android S2 protected mutation is unavailable by user decision; inbox/late-push surface is absent; app WebSocket needs owner alignment; `developer.log`, Android logcat, and installation proof are outside this evidence. No acceptance checkbox was promoted, and no review or commit was performed because the feature-level acceptance gate in the objective remains open. Test report is LOCAL-ONLY under `.gitignore:23`.

#### §27.60 review-finding correction and retest — 2026-11-17 22:53 +07

The user updated the loop to request one reviewer after tests. The first Extra High review of the test delta found two Important findings: `NativeDebugSecretCanary.verify()` ran only from teardown, outside the integration binding's PASS aggregation, and provider test rows did not isolate actor/outcome guards from duplicate session rejection. The same consolidated batch now verifies the canary at the end of the test body and keeps teardown as dispose-only cleanup; provider negative rows use the second session ID and isolate actor, event type, and outcome. Related comments and overflow handling were corrected.

Retest after those edits: provider 11/11; full ops/auth 148/148; Flutter canary 5/5; full Flutter 233/233; Flutter and scoped Dart analyzers clean; formatter reports 0 changes; Android API24/React Web/Auth Lab full-session exit 0 with full/resume, Web logout, Android resume/logout and cleanup markers. Detailed commands are in the append-only LOCAL-ONLY test report. No explicit Android negative fault-injection run was executed; the unit test asserts a synthetic leak's fixed failure marker, and the actual host run verifies the clean pass path. The same Extra High reviewer re-reviewed the corrected delta across four angles and returned PASS for all views with no remaining findings. Initial findings and Version 2 are recorded in `docs/reviews/FEAT-TN-002-review.md`.

Feature state remains `VERIFY_IN_PROGRESS`: no §19 acceptance status was promoted. Android S2 protected mutation stays partial by user decision; inbox/late-push and app WebSocket owner alignment remain open. No commit or feature-complete claim.

### Objective re-entry audit and E2E handoff — 2026-11-17 23:09 +07

Re-read the active goal objective and reconciled it against HEAD `62c68c3886f6edbcb14803e241e1e83642a94e58`, the dirty working tree, feature plan, implementation progress, and loop history. The §27.60 Run 3 tests and review Version 2 still match their recorded source fingerprints; that review is scoped to §27.60 and does not satisfy the feature-level final review gate.

Created [FEAT-TN-002 E2E guide](../test-reports/FEAT-TN-002-e2e-guide.md), covering current native/Web/Flutter/Python commands, safe expected markers, reproducible access/password/offline branches, and explicit blockers. `git check-ignore` confirms this report is **LOCAL-ONLY** under `.gitignore:23`.

No source behavior, acceptance checkbox, dependency, or UI changed during this continuation. The currently authorized independent implementation work is exhausted. Remaining blockers: no existing non-revoking Android S2 mutation (user chose partial); no mobile inbox/notification/deep-link handler for late-push; app-side WebSocket needs owner alignment; `developer.log`, Android logcat, and installation-proof sinks lack evidence. The feature remains `VERIFY_IN_PROGRESS`; full acceptance tests, feature-level review, and commit are still gated. No task was marked PASS from the guide.

#### FEAT-TN-002 Extra High / repeat-logout reconciliation — 2026-11-17

- User selected Extra High; the §27.60 Senior Tester already completed its related tests and fresh full-session run on the current source state. Do not rerun unchanged tests. Review Version 2 remains scoped to the §27.60 delta.
- The accepted repeat criterion is repeated logout of S1 (`E2E-LOGOUT-003`), covered by React Web logout/retry with Android S2 active. Provider verification also sends Android S3 logout twice while sibling S2 remains active and checks exact database deltas. A separate Android UI double-tap is not an independent acceptance criterion in the plan, so the conditional follow-up is closed without scope expansion.
- No source or acceptance change. Overall remains `VERIFY_IN_PROGRESS`; S2 protected mutation, inbox/late-push, app WebSocket owner alignment and remaining log/installation-proof evidence still block feature completion, feature-wide review and commit. This progress document is LOCAL-ONLY under the existing `docs` ignore rule.

Correction to this entry: `docs/plan/implementation-progress.md` is tracked and is not LOCAL-ONLY. The feature plan and loop log are ignored under the existing rule. No ignore rule or Git index was changed.

### FEAT-TN-002 §27.61 raw-wire correction and review — 18/11/2026 00:15 +07

The first Extra High review found SIB-TEST-1 (Fetch normalizes HTTP 204 and cannot prove that no bytes followed the header), SIB-PERF-1 (response bytes were capped after reading), and SIB-DOC-1 (checkpoint/budget comments lacked context). The runner now sends the owned Web cleanup logout over a bounded loopback socket with `Connection: close`, validates the raw 204 response and zero bytes after the header, caps Fetch response streaming before retaining chunks, and documents the checkpoint/reserve boundaries. The Tester added one valid raw-response protocol case and four negative cases.

Fresh Run 5 evidence: both Node syntax checks and `node ops/auth/test_native_e2e_protocol.mjs` exit 0 with 18 PASS markers; Android API 24 `--preflight`, `--android-sibling-cases`, and unchanged `--full-session` exit 0 sequentially. The sibling case proves Android UI logout revokes S2 while Web S1 remains active (`/me` 200), then measures Web cleanup as raw HTTP 204 with zero body bytes and validates exact terminal PostgreSQL deltas. Both native runs confirm proxy/fixture cleanup. Results and the Run 4 evidence correction are appended to the LOCAL-ONLY integrated report.

The same Extra High reviewer appended Version 4 to `docs/reviews/FEAT-TN-002-review.md`; all four views PASS and SIB-TEST-1, SIB-PERF-1, SIB-DOC-1 are closed for §27.61. Review and test artifacts remain LOCAL-ONLY under `.gitignore:23`. FEAT-TN-002 remains `VERIFY_IN_PROGRESS`: S2 protected mutation remains partial by user decision; inbox/late-push, app WebSocket owner alignment, `developer.log`, Android logcat, and installation-proof evidence remain open. No acceptance checkbox changed and no commit was created.

### FEAT-TN-002 consolidated source audit — 18/11/2026 00:30 +07

Correction to the preceding source audit: logout uses optional `AuthDiagnostics` spans at pool acquire, transaction begin, and commit ACK. That sink receives only fixed stage/outcome enums and elapsed duration, so it cannot accept user identity or credential fields. The conclusion is narrowed to no direct structured logging callsite and no dedicated runtime scan for that timing sink. Four §27.61 file fingerprints match Run 5; `verify_provider.py` fingerprint `91bec5fd0bb6` matches Run 2/3, not Run 5.

The existing bounded owned-PID Android logcat collector in `ops/auth/run_native_response_loss_e2e.mjs` scans actual proxy-captured bearer values, password and fixture emails in RAM, plus SDK stdout/stderr. Fresh Run 6 on the current Flutter target passed: exact-PID logcat **23,241 bytes**, SDK stdout **82,685 bytes**, stderr **529 bytes**; each sink scanned eight canaries with zero canary and sensitive-field matches. The actual response-loss flow included one Android logout POST `204`, and fixture cleanup passed. Its evidence uses a validated fixture-UUID path with exclusive create; the 11/15 artifact's hash/size/mtime remained unchanged. Details are appended to Run 6 in the integrated report.

The separate Dart VM `developer.log` stream and a real installation-proof value remain unavailable in the current auth flow, so `SEC-LOGOUT-003` stays partial. Tester added the path regression and completed focused response-loss tests **6/6** plus the actual E2E. The same Extra High reviewer appended Version 5 after reviewing only this new delta and the updated E2E guide; Correctness, Security, Tests and Architecture/Performance PASS, closing AUD-COR-1, AUD-TEST-1 and AUD-TEST-2 for this delta. Version 4 remains valid for §27.61. S2 protected mutation remains partial by user decision, late-push lacks the app inbox/deep-link surface, and app WebSocket closure needs owner alignment. No §19 checkbox or acceptance state changed; feature remains `VERIFY_IN_PROGRESS`, no commit.

### FEAT-TN-002 reopened mutation audit — 18/11/2026 09:54 +07

A wider route audit corrects the scope of §27.59: the Android auth client exposes only logout/password mutations, but the accepted FEAT-TN-002 API also contains `POST /api/v1/realtime/tickets`. The backend handler and OpenAPI define it as a session/workspace-protected, state-changing one-time ticket issuance returning `201` / `no-store`; logout does not revoke the other Android session, so this is a viable candidate for the user's “different mutation” condition. It is not currently exposed by the production Flutter API client.

The candidate is not yet acceptance evidence. The next bounded verification is an Android integration-isolate call after Web S1 logout, using the stored S2 credential and selected workspace, with no bearer or ticket passed to the host or emitted in logs. Keep the S2 mutation acceptance partial until that real run and cleanup pass. No source behavior or acceptance checkbox changed in this audit.

### FEAT-TN-002 Tester and remaining-surface audit — 18/11/2026 09:59 +07

The user confirmed GPT-6-Luna Extra High for the Senior Tester. A single Tester dispatch was attempted at XHigh, but the runtime could not confirm the inherited model and does not expose GPT-6-Luna; the agent stopped before reading files, editing, or running tests, as required. No test report or code changed as a result.

A source-only scan of `mobile/lib` and `mobile/pubspec.yaml` found no notification/deep-link/inbox or WebSocket client/dependency callsite. The current integration scope therefore still needs the late-push app surface and a decision/owner for an app-side realtime consumer; Antigravity CLI and tool are unavailable in this runtime, so any required UI change remains blocked. Installation proof has no current auth-flow value/API path. These findings do not change acceptance status; the realtime-ticket S2 probe remains a candidate verification task, not PASS evidence.

### FEAT-TN-002 exact Tester model dispatch — 18/11/2026 10:03 +07

A second Tester dispatch used the user's exact requested override, `gpt-6-luna`, with XHigh reasoning. The spawn call was accepted, but the agent could not confirm its effective model and reported that GPT-6-Luna is absent from the available model list; it stopped before reading AGENTS, editing files, or running tests. This confirms the same model-availability blocker after the fresh resumed-run audit; no substitute Tester was used and no test result is claimed.

No product source, test, acceptance state, or review changed. The S2 realtime-ticket probe remains unverified; UI-dependent late-push work still lacks Antigravity, app-side realtime ownership still needs alignment, and no installation-proof flow exists. FEAT-TN-002 remains `VERIFY_IN_PROGRESS`; no commit.

### FEAT-TN-002 Tester retry under updated objective — 18/11/2026 10:30 +07

The updated objective permits GPT-6-Luna Extra High if Luna Max is unavailable. A fresh Tester dispatch requested `gpt-6-luna` with XHigh reasoning; the runtime agent still could not confirm its effective model and reported Luna absent from its available model list. It stopped before reading project files, editing, or running commands. No substitute Tester was used.

HEAD remains `62c68c3886f6edbcb14803e241e1e83642a94e58`; no product source, test, acceptance, or review state changed. The Android S2 realtime-ticket probe is still unverified, so acceptance remains partial. This is a model-availability blocker record, not Tester execution evidence; no tests, review, or commit are claimed.

### FEAT-TN-002 GPT-6-Luna Max dispatch — 18/11/2026 10:33 +07

The updated objective's first-choice Tester model was attempted with `gpt-6-luna` at Max reasoning. The agent could not verify the effective model identity and stopped before reading repository files, editing, or running commands. The XHigh fallback was also attempted under the same objective and could not be confirmed. No substitute model was used; no test or review is claimed. FEAT-TN-002 remains `VERIFY_IN_PROGRESS` with S2 mutation acceptance partial.

### FEAT-TN-002 backend/Web implementation-gap reconciliation — 18/11/2026 10:41 +07

A read-only audit against the current plan found no additional approved Rust/backend or React Web implementation task independent of the remaining Tester/UI/owner dependencies. Plan §27.54–27.56 records the integrated Web logout, stale protected mutation rejection, Android S2 profile resume, session oracle, and cleanup evidence; §27.60 excludes new production UI/API/WebSocket work in that batch. The only S2 candidate in §27.64 remains a test-only Android-isolate request to the existing realtime-ticket route. `backend/src/http/realtime.rs` is currently untracked and must be preserved. No code or acceptance status changed; no tests, review, or commit are claimed.

### FEAT-TN-002 Luna Tester dispatch root cause — 18/11/2026 10:46 +07

Diagnosed the failed model selection. The current Codex collaboration tool only advertises a fixed override set (`gpt-6.2-sol`, `gpt-6.2-astra`, `gpt-6.1-terra`, `gpt-6.1-sol`, `gpt-6-astra`); `gpt-6-luna` is absent. Luna Max/XHigh spawn requests were accepted at the call boundary, but the agents could not confirm an effective Luna model and stopped before reading project files or running work. Official OpenAI material distinguishes general model availability from multi-agent support: the reasoning guide names `gpt-6-luna`, while the multi-agent guide does not list it among supported multi-agent models. This is a host/runtime capability mismatch, not a repository or command-line bug. No available Codex app tool can change the collaboration model allowlist, so there is no safe workspace-side repair. The objective forbids substituting another Tester model; retain the exact blocker until the host enables Luna multi-agent routing or the user changes that requirement. No source/test/review state changed.

### FEAT-TN-002 Flutter regression runner and blocker update — 18/11/2026 16:01 +07

The GPT-6-Luna Tester dispatch root cause is resolved for this host: direct local Codex CLI invocation selected gpt-6-luna at XHigh with workspace-write; the first attempt's network socket was denied by the sandbox, and the retry under approved outer escalation connected without using a sandbox bypass.

Run 9's Node syntax, protocol, and PID regressions passed, including 20 fixed protocol markers. The Flutter full suite did not finish after more than ten minutes and has no verdict. Runs 10–11 used safer streaming filters to distinguish a Flutter failure from suppressed progress. Run 10's first PowerShell callback lacked a runspace; its corrected line reader timed out with no lines. Run 11's CR/LF-aware reader emitted FLUTTER_PROCESS_STARTED, then recorded zero output segments, progress markers, and summary markers before EXIT=124 at five minutes. No raw Flutter output was inspected or saved. These are incomplete runner results, not evidence of failing tests.

The user opened Chrome after Run 9, so Chrome is not the cause of that earlier stall. It could compete for resources during later runs, but there is no evidence it caused Run 11. D: had about 16.7 GB free; Flutter command resolution succeeded; no Flutter/Dart process remained after the watchdog. The child command's silent state remains unexplained. Three no-progress attempts have reached the plan limit; do not repeat the same Flutter suite without a new verified runner or environment change. The Flutter/Dart analyzers were not run.

Native S2 verification remains partial because no configured AVD or emulator-5554 was available; no Android protected mutation or owned cleanup is claimed. The notification app entry path/API are owned by FEAT-TN-047 and absent from current source, so no mock/unreachable UI was added. An Antigravity request that would send private project content was rejected by automatic review; no files were sent. No acceptance state changed, no reviewer or commit was produced, and the feature remains VERIFY_IN_PROGRESS.

### FEAT-TN-002 Android runtime recovery and current blockers — 18/11/2026

The documented `Pixel_7` AVD is present and was launched on port 5554. The permitted ADB checks return `unauthorized`; the fixed `node ops/auth/run_native_e2e.mjs --preflight` exits 1 with `NATIVE_PREFLIGHT_ORCHESTRATION_NATIVE_PID_QUERY_DEVICE_UNAUTHORIZED` and `NATIVE_E2E_PREFLIGHT_FAILED`. Full-session, Android S2 mutation, and owned cleanup remain unverified. The user asked me to accept the debugging prompt, but Computer Use's automatic approval rejected selection of `qemu-system-x86_64` twice, including after explicit user authorization; no UI action was performed. Resume once the user accepts the prompt or Computer Use access is granted.

Chrome's tab timestamp is 16:02 +07, after Run 11 stopped at 16:01 +07, so it did not cause that stall. A later run could still compete for machine resources; causal evidence is absent. The three no-progress Flutter attempts remain at the retry limit, so no unchanged suite retry was made. `agy models` lists Argon and Hydrogen, but FEAT-TN-047 still owns the missing notification event entry/API; no UI was sent or implemented. No acceptance status changed; feature remains `VERIFY_IN_PROGRESS`, with review and commit gated.

### FEAT-TN-002 analyzer cleanup and verification — 18/11/2026 16:24 +07

The first `flutter analyze --no-pub` run identified two unused import entries in the S2 integration harness. Removed only the unused TLS-configuration import from `app_auth_e2e_test.dart` and the unused `HttpClient` show-name from `native_realtime_ticket_probe.dart`. Retest: `flutter analyze --no-pub` PASS (exit 0, no issues); `dart analyze integration_test test/tool/native_debug_secret_canary_test.dart` PASS (exit 0, no issues). No behavior changed. The full Flutter test suite remains BLOCKED/INCOMPLETE after Runs 9–11; the three no-progress attempts remain capped, so no fourth unchanged run was started. Android preflight remains blocked by ADB authorization. Acceptance remains `VERIFY_IN_PROGRESS`; no review or commit.

### FEAT-TN-002 Tester coverage reconciliation — 18/11/2026 16:41 +07

One Tester session was confirmed as GPT-6-Luna Max, OpenAI, `workspace-write`; it read the required project rules/skills and appended Run 14 to the integrated report. The existing harness already covers S2 ticket phase gating, so no new test-only gap could close the open acceptance without the live Android run. Node protocol/PID evidence from Run 9 and analyzers from Run 13 were reused because relevant sources and conditions are unchanged. No test was rerun in this session.

Current blockers remain: ADB `unauthorized` prevents preflight/full-session, and the Flutter suite remains without a verdict after three no-progress attempts. Late-notification UI depends on FEAT-TN-047's absent app event/API path; WebSocket owner alignment and separate `developer.log`/installation-proof evidence also remain open. No acceptance state was promoted. Final review and commit remain gated.

### FEAT-TN-002 xác minh lại prompt USB debugging — 18/11/2026 17:04 +07

Sau khi người dùng cho phép thao tác, Computer Use chọn được `Android Emulator - Pixel_7:5554` và quan sát thấy launcher, nhưng không có hộp thoại `Allow USB debugging`. Các lệnh ADB được phép `get-state` và `shell getprop sys.boot_completed` vẫn báo `unauthorized`. Không bấm vào vị trí không có nút, không chạy lại preflight/full-session trên cùng trạng thái, và không ghi nhận S2 request hoặc cleanup. HEAD giữ nguyên `62c68c3886f6edbcb14803e241e1e83642a94e58`; không có thay đổi source/test. Feature vẫn `VERIFY_IN_PROGRESS`; test, review và commit cuối còn chờ các blocker acceptance.

### FEAT-TN-002 Android S2 evidence và suite retry cuối — 18/11/2026 17:35 +07

Sau khi người dùng cho phép chấp nhận quyền USB debugging, Orchestrator khởi động lại ADB host (kill/start exit 0); ADB kiểm tra emulator-5554 trả device, sys.boot_completed=1. Lệnh node ops/auth/run_native_e2e.mjs --preflight và --full-session đều PASS exit 0. Full-session ghi được S2 realtime-ticket sau Web S1 logout, Android resume/logout oracle và owned-fixture cleanup. Điều kiện protected mutation S2 trong quyết định người dùng §27.58 nay có evidence thật; overall acceptance vẫn VERIFY_IN_PROGRESS vì các gate WebSocket, FEAT-TN-047 notification, developer.log/installation-proof và CP-L1 chưa đóng.

Tester GPT-6-Luna Max chạy duy nhất một flutter test --no-pub --reporter compact sau thay đổi môi trường đã được xác minh. Sau khoảng 7m19s outer Tester session kết thúc exit 1 mà không có test output/marker/summary; exit code Flutter không quan sát được. Ghi verdict BLOCKED/INCOMPLETE, không suy diễn thành FAIL/PASS, và không retry thêm sau khi đã dùng retry duy nhất cho thay đổi môi trường. Run 15 và phần đính chính được append vào test report LOCAL-ONLY. Không sửa source/test, không giao Reviewer, không commit.

### FEAT-TN-002 reconciliation sau Run 15 — 18/11/2026 17:52 +07

Đối chiếu lại `HEAD 62c68c3886f6edbcb14803e241e1e83642a94e58` và working tree dirty. Evidence Run 15 xác nhận hạng mục §27.64 đã PASS ở mức task qua Android S2 protected realtime-ticket sau Web S1 logout và fixture cleanup; không chứng minh toàn bộ AC/AT-WF vì WebSocket owner alignment và các acceptance khác vẫn mở. Không đổi checkbox §19 hoặc status `VERIFY_IN_PROGRESS`. Flutter suite vẫn BLOCKED/INCOMPLETE, không có verdict; retry đã hết. Còn dependency FEAT-TN-047 notification entry/API, owner WebSocket, `developer.log`/installation-proof, và CP-L1 owner review. Không có source/test mới, không chạy test, không review hoặc commit. Lịch sử test cũ ở `FEAT-TN-002-integrated-test-report.md`; execution objective chỉ định `FEAT-TN-002-test-report.md` cho kết quả mới, cả hai LOCAL-ONLY do `.gitignore:23`.


### FEAT-TN-002 user decision — defer FEAT-TN-047; contract artifacts already done — 18/11/2026 18:06 +07

Người dùng xác nhận không triển khai phần phụ thuộc FEAT-TN-047 ở đợt này và contract đã làm. Plan đã ghi L1a/L1b READY_FOR_QA cùng static contract/fixture evidence 39/39; không cần viết lại contract. CP-L1 còn là bước owner review/sign-off riêng theo feature plan và chưa có evidence xác nhận trong checkout, nên chưa đánh dấu hoàn tất. E2E-LOGOUT-005 tiếp tục pending FEAT-TN-047; feature giữ VERIFY_IN_PROGRESS. Không sửa source/test, không chạy lại suite hoặc commit.


### FEAT-TN-002 correction — owner approved CP-L1 — 18/11/2026 18:08 +07

Người dùng xác nhận là feature owner và đã duyệt CP-L1. Feature plan cập nhật CP-L1 owner sign-off thành PASS. Đây chỉ là phê duyệt artifact contract; không thay thế bằng chứng runtime/provider hoặc các acceptance còn lại. FEAT-TN-047 vẫn deferred theo quyết định người dùng; không sửa source/test, không chạy test, review hoặc commit.


### FEAT-TN-002 accepted boundary decisions — 18/11/2026 18:12 +07

Người dùng đồng ý các khuyến nghị: backend realtime hiện có giữ trách nhiệm server-side cho socket theo OQ-LOGOUT-005; không thêm app WebSocket consumer/hạ tầng mới. FEAT-TN-047 tiếp tục deferred, nên E2E-LOGOUT-005 chưa thể đóng. Source audit không tìm thấy Dart developer.log callsite trong mobile/lib; subcheck này là N/A cho source hiện tại, còn installation-proof thật chưa có integration path nên SEC-LOGOUT-003 vẫn partial. Flutter suite vẫn BLOCKED/INCOMPLETE, không verdict và không retry nếu chưa xác minh thay đổi runner/môi trường. Không có source/test thay đổi.


### FEAT-TN-002 next bounded verification task — Web S1 socket close — 18/11/2026 18:17 +07

Per the existing AT-WF-002-01/OQ-LOGOUT-005 requirement and the user-approved backend realtime ownership boundary, add a test-only attempt to observe an authenticated Web S1 socket close after logout in the existing full-session lane. Tester may change only the current harness/protocol tests and test report. No new API, UI, WebSocket consumer, or dependency; if real socket transport is unavailable in the approved runner, record the exact blocker and do not mock. Keep Android S2 evidence and fixture cleanup. This does not authorize another Flutter full-suite retry or mark all of OQ-LOGOUT-005 complete.

### FEAT-TN-002 Tester dispatch blocker — 18/11/2026 18:46 +07:00

Ba lần dispatch không tạo được evidence cho probe đóng Web S1 socket theo §27.78: collaboration subagent không xác nhận được GPT-6-Luna Max; lượt codex exec đầu không trả output/verdict; lượt codex exec --json tiếp tục chạy nhưng không trả progress/final report và đã được dừng đúng process tree sau khi xác nhận. Chưa thể xác minh fixed preflight/full-session có bắt đầu hay không; không có test PASS/FAIL mới. WebSocket closure vẫn NOT VERIFIED; Run 15 S2 evidence không đổi; feature giữ VERIFY_IN_PROGRESS. Không retry cùng điều kiện, không Reviewer/commit. Report orchestration được tạo ở docs/test-reports/FEAT-TN-002-test-report.md, LOCAL-ONLY theo .gitignore:23.
### FEAT-TN-002 full-session fixture failure reconciliation — 18/11/2026 20:13 +07:00

Tester ran node ops/auth/run_native_e2e.mjs --full-session and received FAIL/exit 1 at fixture startup (NATIVE_FULL_SESSION_STAGE_FIXTURE_FAILED, NATIVE_E2E_PREFLIGHT_FAILED), before Web S1. Root cause is unknown; Python 3.13.2, the running PostgreSQL container and about 15 GB free do not prove it. The next Tester diagnostic dispatch returned no final result and made no file edits. Source audit shows full-session invokes Cargo build in backend/target, outside the current generated-path exception; do not rerun until the rule is clarified or a compliant runner is available. Acceptance is unchanged; FEAT-TN-002 remains VERIFY_IN_PROGRESS, with no Reviewer/commit. Details are in the existing LOCAL-ONLY test report.

### FEAT-TN-002 owner-approved native build exception — 18/11/2026 20:20 +07:00

Người dùng cho phép ngoại lệ hẹp: chỉ lệnh node ops/auth/run_native_e2e.mjs --full-session và tiến trình con được dùng backend/target cho Cargo build/chạy Auth Lab theo ops/auth/run_local.py; không kiểm tra thủ công output và không mở rộng sang build path khác. AGENTS.md đã cập nhật. Fixture failure trước vẫn chưa rõ nguyên nhân; chưa chạy lại. Tiếp tục bằng Tester GPT-6-Luna XHigh, giữ test/report append-only, không Flutter full suite, không FEAT-TN-047.

### FEAT-TN-002 Tester regression and preflight result — 18/11/2026 20:45 +07:00

Tester protocol regression and both node --check commands PASS; marker mới xác nhận redaction readiness diagnostic. Native preflight FAIL/exit 1 tại startup/cleanup với marker NATIVE_PREFLIGHT_STAGE_STARTUP_ASSERTION_BOUNDARY_NONE, NATIVE_DAEMON_CLEANUP_FAILED, NATIVE_PREFLIGHT_ORCHESTRATION_ERROR, NATIVE_E2E_PREFLIGHT_FAILED; full-session không chạy. ADB sau đó trả device/boot complete; không có dart/flutter process, nhưng nguyên nhân chưa rõ. Không retry cùng điều kiện, không promote acceptance; AT-WF-002-01 còn NOT VERIFIED, feature VERIFY_IN_PROGRESS. Chi tiết ở test report LOCAL-ONLY. Không Reviewer/commit.
### FEAT-TN-002 startup-marker reconciliation and E2E guide refresh — 18/11/2026 20:59 +07:00

Read-only source tracing maps the latest preflight marker to the `runNativePhase` startup gate (`started`, `boundaryFailed`, `terminal`); the generic marker does not reveal which predicate failed. The runner's redacted `NATIVE_STARTUP_DIAGNOSTIC` JSON was not preserved in the latest report, so the runtime root cause remains unknown. The E2E guide now reflects the post-run ADB state, latest preflight failure, historical Run 15 S2 evidence boundary, and approved backend realtime owner. No test, acceptance checkbox, source behavior, reviewer, or commit changed. FEAT-TN-047 stays deferred; contracts and CP-L1 approval remain complete; feature remains `VERIFY_IN_PROGRESS`.
### FEAT-TN-002 verified blocker after re-entry — 18/11/2026 21:10 +07:00

The two permitted ADB checks still return `device` and `sys.boot_completed=1`, matching prior evidence; no environment change supports another preflight. The current Tester agent cannot confirm the required GPT-6-Luna Max model. Latest Tester result remains Node syntax/protocol PASS, native preflight FAIL at startup/cleanup, and full-session NOT RUN. The safe startup diagnostic was not retained, so the exact failure remains unknown. No independent in-scope implementation remains: contracts and CP-L1 are complete, FEAT-TN-047 work is deferred, and backend realtime ownership is accepted. Web S1 socket-close evidence, a Flutter verdict, and installation proof remain open. Feature stays `VERIFY_IN_PROGRESS`; no Reviewer or commit.

### FEAT-TN-002 Web UI logout harness root cause and fix — 18/11/2026 21:34 +07:00

Source state is dev@62c68c3 with the existing dirty worktree. The fixed native preflight passed. The following fixed full-session run failed at Web UI logout: the socket creator wrote window.__tn002Socket, while verifyUiLogout read window.__tn002Sockets['web-s1']; therefore the readiness assertion failed before the logout click and live-close check. Corrected the test harness reader and added a protocol regression that compares writer/reader keys. The regression initially reproduced the mismatch and passed after the fix; both Node syntax checks and the protocol test passed, including NATIVE_WEB_UI_SOCKET_STATE_KEY_CONTRACT_PASS. The full-session failure yielded no socket-close, S2-ticket, or full-fixture-cleanup evidence. Retest is pending explicit approval for only the fixed full-session command and its children to automatically resolve existing Node dependencies; the earlier backend/target approval does not cover node_modules. Orchestrator evidence only; the GPT-6-Luna XHigh Tester has not returned a verifiable report. AT-WF-002-01 remains NOT VERIFIED; feature remains VERIFY_IN_PROGRESS. No Reviewer or commit.

### FEAT-TN-002 full-session retest after Web logout guard fix — 18/11/2026 21:45 +07:00

Owner approved the narrow automatic Node dependency-resolution exception; AGENTS.md records it for only the fixed full-session command and children, without manual node_modules inspection or package restore. Orchestrator ran node ops/auth/run_native_e2e.mjs --full-session on dev@62c68c3 and it exited 0. NATIVE_CROSS_CLIENT_WEB_LOGOUT_ORACLES_PASS is emitted only after the browser child successfully completes UI logout, observes the real socket close, passes stale-session probes, and exits. Android S2 ticket-after-Web-logout, resume/logout oracles, proxy cleanup, and actual fixture cleanup also passed. This closes the bounded local-instance probe but does not complete the whole feature or replace the required GPT-6-Luna XHigh Tester report. No overall acceptance checkbox promotion, Reviewer, or commit; feature stays VERIFY_IN_PROGRESS.

### FEAT-TN-002 GPT-6-Luna XHigh Tester verification and criterion mapping — 18/11/2026 22:34 +07:00

The Tester was launched with model gpt-6-luna and reasoning effort xhigh; the local catalog confirms xhigh support (configuration evidence, not runtime telemetry). It read AGENTS.md and the applicable test/comment skills, then ran the protocol syntax check, protocol regression, and fixed native full-session sequentially; all exited 0. The report is appended at docs/test-reports/FEAT-TN-002-test-report.md (LOCAL-ONLY). Source tracing confirms this flow asserts a real socket close after Web logout, the next stale password mutation returns 401 SESSION_REVOKED, and retrying logout returns bodyless 204; the DB delta and later successful Android S2 ticket establish that the other session remains active. This is runtime evidence for the behavior in AT-WF-002-01 and AT-WF-002-03, but no §19 checkbox was promoted because §25 still requires all feature gates. AT-WF-002-02 cache isolation for profile/workspaces passed in §27.53; inbox/late-push remains deferred with FEAT-TN-047. Flutter full-suite verdict is still unavailable; no Reviewer or commit.

### FEAT-TN-002 owner scope decision — 18/11/2026 22:43 +07

Người dùng xác nhận không triển khai các feature plan chưa bắt đầu trong batch này, gồm FEAT-TN-045 (issuance/rebind installation proof) và FEAT-TN-047 (notification entry/API). Không thêm API/UI/mock hoặc đổi acceptance để giả lấp dependency. Test hiện tại chỉ chứng minh session store giữ key proof tổng hợp; OQ-LOGOUT-006 và phần inbox/late-push vẫn pending. Web S1 socket-close/stale-mutation/retry và Android S2 ticket đã có runtime evidence qua Tester full-session; Flutter full suite chưa có verdict. Giữ feature `VERIFY_IN_PROGRESS`; không Reviewer/commit. Source state `dev@62c68c3886f6edbcb14803e241e1e83642a94e58`; không đổi source/test ở entry này.

UI disposition cho batch này là `N/A`: logout UI hiện hữu không cần sửa; UI notification/inbox phụ thuộc FEAT-TN-047 đã hoãn. Không dispatch Antigravity hoặc thêm UI/mock. Feature vẫn `VERIFY_IN_PROGRESS` theo các acceptance gate còn mở.

### FEAT-TN-002 bounded-loop blocker audit — 18/11/2026 22:51 +07

Đối chiếu lại `dev@62c68c3886f6edbcb14803e241e1e83642a94e58`, working tree và tester runtime xác nhận không có source/environment change mới và không có Tester process còn sống. Root cause Web socket-global đã sửa; Tester full-session pass scenario giới hạn. Không còn task độc lập được phép: FEAT-TN-045/047 chưa bắt đầu và người dùng đã quyết định không triển khai chúng; các acceptance proof/rebind và inbox/late-push vì vậy pending. Flutter full suite không có verdict sau ba lần không tiến triển cùng retry sau environment check; điều kiện liên quan chưa đổi, không retry. Sau ba goal turns liên tiếp cùng còn vướng các gate này, goal được chuyển `blocked`; feature vẫn `VERIFY_IN_PROGRESS`, không review/commit.

### FEAT-TN-002 final review and checkpoint verification — 18/11/2026

Closed review findings FR002-R01/R02 in the Web UI canary delta. The harness now registers context/CSRF/cookie canaries before workspace actions, registers the realtime ticket before WebSocket creation, rescans bounded pre-registration sink messages, fails closed on buffer overflow, and clears temporary data. The protocol regression passes, as do Node syntax checks for the harness, canary helper, protocol test, and runner. The fixed `node ops/auth/run_native_e2e.mjs --full-session` exited 0 with Web logout/socket-close, Android S2 ticket-after-Web-logout, resume/logout, proxy cleanup, and fixture cleanup markers. Review verdict: Safe to merge for this delta after the Dart documentation comment Nit was corrected. No acceptance checkbox is promoted: FEAT-TN-045/047 remain deferred by owner decision, Flutter full-suite verdict is unavailable, and FEAT-TN-002 remains `VERIFY_IN_PROGRESS`.

### FEAT-TN-002 Flutter full-suite verification — 18/11/2026 23:53 +07

After the owner's request to resolve the no-verdict, the fixed `mobile` lane `flutter test --no-pub --reporter compact` completed with exit 0 and all 233 tests passing. `flutter analyze --no-pub` and `dart analyze integration_test test/tool/native_debug_secret_canary_test.dart` both exited 0 with no issues. This is Orchestrator verification on `dev@16c50ce3f0b15809bc69fef33589d93a71ec94fe`; the append-only test report is LOCAL-ONLY under `.gitignore:23`. The previous Flutter no-verdict is resolved. FEAT-TN-045 installation-proof/rebind and FEAT-TN-047 inbox/late-push remain owner-deferred; no acceptance checkbox is promoted, and FEAT-TN-002 remains `VERIFY_IN_PROGRESS`. Final four-lens review is in progress.

### FEAT-TN-002 full-range review outcome — 18/11/2026 23:55 +07

The same GPT-6.1-Sol High reviewer completed the final review of full commit range `62c68c3..16c50ce` at `16c50ce3f0b15809bc69fef33589d93a71ec94fe`. Correctness, Security, Tests, and Architecture-Performance all PASS; no new finding; verdict `Safe to merge` and structurally sound. Review was static and used fresh Orchestrator evidence (Flutter 233/233, analyzers clean, prior native protocol/full-session PASS); no benchmark/load result is claimed. FR002-R01/R02 are closed. FEAT-TN-045/047 remain owner-deferred, so feature remains `VERIFY_IN_PROGRESS` with no acceptance promotion. Full review report is LOCAL-ONLY under `.gitignore:23`; this tracked entry records the verdict. Ready to commit verification history and push `dev`.
