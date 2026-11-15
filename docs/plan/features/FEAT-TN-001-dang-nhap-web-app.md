# Kế hoạch chức năng FEAT-TN-001 — Đăng nhập Web/App

## Android main API 24 full-session rerun — 15/11/2026

**PASS_SCOPED_NATIVE_FULL_SESSION_AND_PRESELECTION_ORACLE / READY_FOR_QA cho App login, picker boundary, cold resume và logout; toàn feature VERIFY_IN_PROGRESS.**

- [x] Main Android chạy trên AVD `Nexa_Auth_API24`/API 24 với auth API thật qua HTTPS lab proxy và PostgreSQL fixture; picker xác nhận A/Admin, B/User.
- [x] Trước lần chọn workspace đầu: exact request oracle `AUTH_LOGIN=1`, `PROFILE_READ>0`, `WORKSPACE_LIST=1`, `PASSWORD_CHANGE=0`, `AUTH_LOGOUT=0`, `OTHER=0`.
- [x] Process đầu dừng có terminal ACK; process mới resume từ secure storage không login lại; DB session delta/logout revoke oracle PASS.
- [x] Proxy và fixture cleanup PASS; AVD dừng và `adb devices -l` rỗng sau lượt test.
- [x] Host rerun 15/11: native protocol 15 marker PASS, auth harness 133/133 PASS, Web auth 36/36 PASS, TypeScript `tsc --noEmit` exit 0, `git diff --check` exit 0. Đây là regression host, không thay cho E2E runtime hoặc acceptance còn thiếu.
- [ ] E2E-AUTH-003 / AT-WF-001-03 PARTIAL: chưa seed device rows khác workspace A/B; Web/App exact preselection request oracle đã PASS. WEB-AUTH-013/014, shared-run/audit và nhánh response-loss vẫn mở.

Report: [Android API24 run](../../test-reports/FEAT-TN-001-android-api24-full-resume-2026-11-15.md), [final host rerun](../../test-reports/FEAT-TN-001-final-host-rerun-2026-11-15.md), [redacted evidence](../../test-reports/evidence/FEAT-TN-001-android-api24-full-resume-2026-11-15.json).

## Chrome + PostgreSQL login/workspace/logout — 15/11/2026

PASS_SCOPED_BROWSER_FLOW / READY_FOR_QA cho Web login, chọn/chuyển workspace và logout; toàn feature VERIFY_IN_PROGRESS.

- [x] Chrome thật với PostgreSQL auth fixture: POST /api/v1/auth/login 200 → GET /api/v1/me 200 → GET /api/v1/workspaces 200. Picker A/Admin và B/Member; login payload xác nhận đúng key clientType, email, password (không ghi values).
- [x] Trước khi workspace được chọn không phát request device/resource. Chọn A và B đều nhận workspace detail 200; logout trả 204, trở về /login, password field trống.
- [x] Ownership recovery exit 0 ghi application fixture rows REMOVED; limiter buckets và anonymous audit giữ theo recovery/retention policy.
- [ ] E2E-AUTH-003 / AT-WF-001-03 PARTIAL: Chrome method/path và Android exact preselection oracle đã có; chưa seed device fixture khác workspace. WEB-AUTH-013/014 còn full process close/reopen và delayed logout clear-cookie/race.
- [ ] Android runtime không chạy trong lượt Chrome này; adb devices -l lúc đó không có thiết bị đang chạy. Android API24 đã được kiểm trong checkpoint mới phía trên.

Chi tiết: [Chrome E2E report](../../test-reports/FEAT-TN-001-web-chrome-login-picker-rerun-2026-11-15.md), [redacted evidence](../../test-reports/evidence/FEAT-TN-001-web-chrome-login-picker-rerun-2026-11-15.json). Không sửa source/UI lượt này.

## Chrome recovery sau khi mất response login đã commit — 15/11/2026 10:13–10:38Z

**PARTIAL_BROWSER_RUNTIME_PASS / READY_FOR_QA cho bằng chứng quan sát; toàn feature VERIFY_IN_PROGRESS.** Chrome thật chạy với auth fixture PostgreSQL. Luồng bình thường POST login 200 → GET /me 200 → GET /workspaces 200, chọn/chuyển workspace A/B thành công và logout 204. Trong fault injection, backend đã trả login 200 nhưng Chrome nhận net::ERR_ABORTED. Sau reload, UI giữ loginUnknown và khóa; không phát request auth tự động trong ba khoảng yên lặng 10 giây. Người dùng chủ động đối soát nhận GET /me 200, phải xác nhận candidate; chỉ sau xác nhận mới gọi /me và /workspaces. Logout 204 đưa cookie count về 0 và xóa intent marker. Không đọc/ghi cookie, credential, body hoặc email vào evidence.

- [x] Chrome thực tế: committed-response-loss → reload locked/loginUnknown → no auto-login trong 30 giây → explicit discovery → explicit confirmation → picker → logout; debug scan không có canary/field matches, error hoặc warning.
- [x] Existing browser response-fault controller regression rerun: node ops/auth/test_browser_login_response_fault.mjs — exit 0, BROWSER_LOGIN_RESPONSE_FAULT_22_CASES_PASS. Đây là host test cho controller CUA, không thay browser E2E hoặc mở acceptance mới.
- [x] Auth host reruns: python -B -m unittest discover -s ops/auth/tests -q — 133 tests PASS; node ops/auth/test_browser_cookie_omission.mjs — six assertions PASS. Không thay actual E2E.
- Source dependency audit (analysis only, no acceptance change): Auth router/OpenAPI hiện chưa có protected device endpoint; dependency FEAT-TN-010 đang READY_FOR_EXECUTION, chưa triển khai. Auth diagnostics hiện là bounded in-memory timing recorder; auth_lab có measurement begin/end test endpoints nhưng chưa có production structured-log/remote-exporter integration.
- [x] Auth-lab child thuộc run được dừng; cleanup journal exit 0 báo application fixture rows đã xóa. Limiter bucket giữ theo recovery policy và anonymous audit theo retention. Sau cleanup không còn listener ở các cổng auth/proxy/Web được kiểm.
- [ ] Chưa có full browser process close/reopen, delayed logout clear-cookie/race matrix hoặc DB session/audit delta cho run này.
- [ ] Android runtime không chạy lượt này: adb devices -l không có device và emulator -list-avds không có AVD. Evidence API24/API36 lịch sử giữ nguyên scope; chưa thay bằng một kiểm tra host. E2E-AUTH-006 và WEB-AUTH-013/014 cùng các acceptance liên client giữ nguyên trạng thái mở; không đổi matrix thành PASS.

Chi tiết và JSON đã khử dữ liệu: [report](../../test-reports/FEAT-TN-001-continuation-2026-11-15.md), [evidence](../../test-reports/evidence/FEAT-TN-001-chrome-committed-response-loss-2026-11-15.json), [runbook Tester](../../Instructions/feat-tn-001-e2e-testing.md). Không có source/UI change trong lượt kiểm này.

## Logout cookie contract fix — 15/11/2026 10:02Z

GPT-6.1 Sol high review phát hiện backend và OpenAPI dùng cùng thuộc tính clear-cookie nhưng thứ tự khác nhau, khiến exact contract equality lệch. Đã sắp thứ tự response logout theo OpenAPI và thêm test gọi response builder thật; test xác nhận Web cookie đúng tuyệt đối và Android không phát cookie. RED trước sửa, GREEN sau sửa. Follow-up Sol high: no findings.

- [x] Regression test logout/OpenAPI: 1/1 PASS; contract logout: 6/6 PASS; rustfmt --check: PASS.
- [x] Full Rust workspace test sau sửa/format: PASS; targeted backend Clippy: PASS.
- [ ] Các acceptance chưa chạy tiếp tục giữ trạng thái trong ma trận; không đổi PASS.

READY_FOR_QA cho lát cắt logout contract; toàn feature VERIFY_IN_PROGRESS. Full workspace Clippy còn báo warning ở các file ngoài source logout. [Báo cáo](../../test-reports/FEAT-TN-001-continuation-2026-11-15.md), [evidence](../../test-reports/evidence/FEAT-TN-001-logout-cookie-contract-fix-2026-11-15.json).

## Checkpoint hiện hành15/11

Chrome UI rerun 09:36–09:42Z với auth lab/PostgreSQL thật: login → picker A/Admin, B/Member → chọn A → chuyển B → logout về `/login`. Quan sát form giữ email nhưng xóa password; đây chỉ là hành vi được ghi nhận, không đổi yêu cầu. Launcher phải recovery sau exit1; lệnh recovery exit0, application fixture rows removed. Không capture HTTP/payload/session oracle lượt này, không đóng acceptance race/reopen/shared client. [Evidence](../../test-reports/evidence/FEAT-TN-001-chrome-ui-rerun-2026-11-15.json).

- [x] Provider four-workspace pagination, User fence hai thứ tự, limiter-window và timing verify — actual370/333, parser parity, lượt mới báo APPLICATION_ROWS_REMOVED; lượt này không đọc lại post-cleanup zero rows.
- [x] Backend output capture cho hai process provider, 166 canary/zero match; auth host suite133PASS và Sol high final review. Structured log vẫn NOT_RUN.
- [x] Android native backup/plain-preferences inspection và password main E2E trên API24. API24 stale-membership rerun15/11 đạt preflight + actual owned-terminal; emulator cleanup xác nhận. [Evidence](../../test-reports/evidence/FEAT-TN-001-android-api24-stale-rerun-2026-11-15.json).
- [x] Chrome thật với PostgreSQL fixture: POST login 200 → GET /me 200 → GET /workspaces 200; picker A/Admin+B/Member; chọn A gọi workspace detail200; logout204 về /login.
- [x] Chrome nhánh disabled-account 401 với thông báo chung, no-workspace empty-state, password-change-required403; console0 error/0 warning.
- [x] Fixture Chrome được thu hồi qua owner journal/recovery exit0; application fixture rows removed, limiter buckets và anonymous failure audit giữ theo policy.
- [ ] Acceptance còn thiếu giữ đúng trạng thái trong ma trận; không đổi thiếu evidence thành PASS.

**Checkpoint Chrome cũ — READY_FOR_QA theo scope đã kiểm; toàn feature VERIFY_IN_PROGRESS.** Chrome thật 15/11 ghi method/path/status và chỉ tên key login payload (clientType, email, password), không lưu values. Login/me/workspaces đều 200; không có device/resource request trước picker; chọn A/B và logout204 thành công. Tại checkpoint Chrome này Android exact request oracle chưa chạy; checkpoint Android API24 mới nhất ở đầu plan đã bổ sung oracle đó. E2E-AUTH-003 / AT-WF-001-03 hiện `PARTIAL` vì chưa seed fixture devices khác workspace A/B. WEB-AUTH-013/014 vẫn mở: chưa chạy process close/reopen đầy đủ, delayed logout clear-cookie và toàn bộ race variants. Còn IT-AUTH-011 exporter fault, SEC-AUTH-002/003/009 log sinks, E2E-AUTH-001/006/007/008 theo dependency ma trận. Browser evidence: [report](../../test-reports/FEAT-TN-001-continuation-2026-11-15.md), [redacted JSON](../../test-reports/evidence/FEAT-TN-001-web-chrome-real-2026-11-15.json). Host tests rerun 15/11 08:48Z: auth Python133 PASS; browser response-fault22 PASS; cookie omission6 assertions PASS; browser lab ownership/handoff và fixture crypto handoff PASS. Rerun 09:05Z: Web auth36/36, TypeScript0 error, Flutter host213 PASS và analyze0 issue (Flutter3.47.5/Dart3.13.4). API24 actual stale-membership preflight + run exit0 lúc09:22Z; E2E007/008 vẫn NOT_RUN vì thiếu resource/WF010 và page-cursor/only-suspended oracle. Code state dev@ba425ad, dirty working tree, chưa commit; checkpoint Chrome không thay source/UI. [Checkpoint tiếp nối và phần còn thiếu](../../test-reports/FEAT-TN-001-continuation-2026-11-15.md), [ma trận acceptance](../../test-reports/FEAT-TN-001-acceptance-matrix-2026-11-13.md).

- Mã task: `TASK-FEAT-TN-001`

### Checkpoint hiện hành 13/11, sau lượt Chrome tiếp nối

Provider root252markers/236distinct và actual success-response parity qua production Web/Dart parser đã exit0, cleanup8zero. FullFlutter212/212 và Web34/34 đã PASS, Sol high review scoped. Chrome thật kiểm controlled late-cookieA sau acceptedB →409/no data/hai tab khóa/reload, và default-timeout→explicit candidate/no autoPOST. Delayed logout clear-cookie và full browser process reopen vẫn mở. UI Antigravity CLI4Hydrogen giữ đúng scope. [Bàn giao, lệnh, screenshot và giới hạn](../../test-reports/FEAT-TN-001-final-continuation-2026-11-13.md), [ma trận hiện hành](../../test-reports/FEAT-TN-001-acceptance-matrix-2026-11-13.md). **READY_FOR_QA theo scope đã kiểm, toàn feature VERIFY_IN_PROGRESS.** Các đoạn215/212/177 phía dưới là checkpoint trước lượt này.

- [x] Android remaining composed-test matrix, sevennewcases, final212PASS/analyze0 và independent Sol high review.
- [x] Web remaining consumer matrix,34PASS và independent34PASS, scoped API doubles ghi rõ trong report.
- [x] Provider security/picker extensions252actual với provenance/cleanup và independent Sol high review.
- [x] Actual successful provider response → Web/Dart parser runtime, missing/null/type/extension/cross-transport policy có RAM-only probe và independent source review.
- [x] Chrome controlled late-A-cookie mismatch/reload/candidate và default15s timeout, có HTTPidentity/status và screenshot. Giới hạn faultinjection ghi rõ, không đóng toàn WEB014.
- [x] SessionINSERT/limiterwrite DB faults và shared email vectors đã kiểm, actual/provider/parser/cleanup và Sol high review có report15/11. Các acceptance khác giữ theo ma trận.
- [ ] Các acceptance NOT_RUN còn lại giữ nguyên tiêu chí và bằng chứng thiếu trong ma trận.

### Checkpoint hiện hành 13/11, sau lượt Chrome tiếp nối

Provider root252markers/236distinct và actual success-response parity qua production Web/Dart parser đã exit0, cleanup8zero. FullFlutter212/212 và Web34/34 đã PASS, Sol high review scoped. Chrome thật kiểm controlled late-cookieA sau acceptedB →409/no data/hai tab khóa/reload, và default-timeout→explicit candidate/no autoPOST. Delayed logout clear-cookie và full browser process reopen vẫn mở. UI Antigravity CLI4Hydrogen giữ đúng scope. [Bàn giao, lệnh, screenshot và giới hạn](../../test-reports/FEAT-TN-001-final-continuation-2026-11-13.md), [ma trận hiện hành](../../test-reports/FEAT-TN-001-acceptance-matrix-2026-11-13.md). **READY_FOR_QA theo scope đã kiểm, toàn feature VERIFY_IN_PROGRESS.** Các đoạn215/212/177 phía dưới là checkpoint trước lượt này.

- [x] Android remaining composed-test matrix, sevennewcases, final212PASS/analyze0 và independent Sol high review.
- [x] Web remaining consumer matrix,34PASS và independent34PASS, scoped API doubles ghi rõ trong report.
- [x] Provider security/picker extensions252actual với provenance/cleanup và independent Sol high review.
- [x] Actual successful provider response → Web/Dart parser runtime, missing/null/type/extension/cross-transport policy có RAM-only probe và independent source review.
- [x] Chrome controlled late-A-cookie mismatch/reload/candidate và default15s timeout, có HTTPidentity/status và screenshot. Giới hạn faultinjection ghi rõ, không đóng toàn WEB014.
- [x] SessionINSERT/limiterwrite DB faults và shared email vectors đã kiểm, actual/provider/parser/cleanup và Sol high review có report15/11. Các acceptance khác giữ theo ma trận.
- [ ] Các acceptance NOT_RUN còn lại giữ nguyên tiêu chí và bằng chứng thiếu trong ma trận.

Final provider13/11 đạt215markers/202distinct, original85598/abedde exit0 và8zero cleanup. UT007 concurrent durable sessions và SEC005 expiry HTTP đã actual PASS. [Report/manifest30files](../../test-reports/FEAT-TN-001-ios-provider-and-policy-2026-11-13.md). Trạng thái toàn feature giữ VERIFY_IN_PROGRESS, các task/code đã kiểm giữ READY_FOR_QA tới final independent Sol high review và các acceptance còn mở.

Checkpoint tiếp nối13/11 qua terminal. Antigravity CLI1.5.8/Gemini4HydrogenHigh đã hoàn tất copy503 của Web, Sol high review độc lập và Chrome320px/desktop đạt scoped. Sol high tìm/sửa IOS bearer contract drift, root đã áp0020 vào DB canonical, refresh schema metadata và chạy provider212markers/199distinct với cleanup8zero. Shared26password vectors đạt Rust/Web/Dart. [Report hiện hành](../../test-reports/FEAT-TN-001-ios-provider-and-policy-2026-11-13.md). Các agent Sol high chạm usage limit trước final re-review của oracle/comment/fixture bổ sung, giữ **READY_FOR_QA / VERIFY_IN_PROGRESS**. Các biến thể chưa chạy trong ma trận vẫn mở.

Checkpoint hiện hành13/11. O4 root và independent final-code actual đã đạt, có17filemanifest, exact9HTTP/4SQL và original terminals/cleanup. Chrome cookie A/B/missing, reload/tab mới, explicit candidate confirmation và U1 actual đã được Sol high đối chiếu. I1 provider mới177markers/164distinct và8zero cleanup đạt. **READY_FOR_QA theo các scope đã kiểm, toàn feature VERIFY_IN_PROGRESS.** [Bàn giao hiện hành](../../test-reports/FEAT-TN-001-cli-and-cookie-handoff-2026-11-13.md), [I1 actual](../../test-reports/FEAT-TN-001-provider-i1-sol-actual-2026-11-13.md), [ma trận acceptance](../../test-reports/FEAT-TN-001-acceptance-matrix-2026-11-13.md). Các checkpoint phía dưới giữ lịch sử theo ngày.

Theo chỉ đạo mới13/11, phần viết UI/UX được giao Antigravity **CLI**, pin model4Hydrogen hoặc4Argon. Review mới dùng **GPT-6.1 Sol high**. Primary quản lý scope, diff, test và bằng chứng. CLI1.5.8 đã xác minh checksum và models qua terminal, task copy/error-feedback bounded đang được thực thi.

### Phạm vi hoàn tất theo yêu cầu user12/11

User yêu cầu triển khai toàn bộ phần thiếu và một vòng test/review cuối; **không yêu cầu thiết bị thật**. Các gate physical-device chuyển `N/A — USER_SCOPE_OVERRIDE_2026-11-12`, không chuyển PASS. Chrome thật, Android emulator, security/negative/session/storage/accessibility phần kiểm được trên emulator và acceptance evidence vẫn giữ. Các checkpoint physical bên dưới là yêu cầu lịch sử trước override này.

O4 triển khai theo [design hiện hành](../../test-reports/FEAT-TN-001-offline-login-design-2026-11-11.md). Tách O4a thành các phần nhỏ để thực thi ngay, không thay acceptance:

- [x] O4a1 SOURCE_HOST_ACCEPTED/READY_FOR_QA (2files): gate5stage fixed `offline-ready/result/quiet/picker/logged-out`, caps110/110/170/170/5s, global675s. Root34tests, independent static+11adverse đạt; independent Flutter invocation bị interrupt/exit1 giữ riêng, không actual admission.
- [x] O4a2 SOURCE_HOST_ACCEPTED/READY_FOR_QA: same-engine canary, UI gestures, quiet30s và wrapper;11focused/final205Flutter/analyzer4files PASS. Independent review tìm/sửa initial20s reset và fast-recovery observation, finalB8A43ED8/C9C44D30 accepted. [Report và lệnh](../../test-reports/FEAT-TN-001-completion-pass-2026-11-12.md). Đây là producer/host scope, chưa emulator actual.
- [x] O4b–e SOURCE_HOST_ACCEPTED và SCOPED_RUNTIME_PASS / READY_FOR_QA. Final coordinator đã sửa SDK-exit ownership, host18modes đạt. Independent API36 actual owner62977/691e64 exit0 có exact9HTTP/4SQL, original SDK/proxy/fixture terminal và cleanup. Sol high đã kiểm17/17finalhash khớp. [Final review, manifest và actual](../../test-reports/FEAT-TN-001-offline-final-review-2026-11-13.md).
- [x] O4 actual root API36 — ROOT_SCOPED_RUNTIME_PASS / READY_FOR_QA. Run1218a9d0, owner75411/bea3c5 exit0, main-engine offline/reconnect/quiet30s/explicitlogin/A-B/logout, exact9HTTP và baseline/negative/live-mid/finalSQL, original cleanup8zero. Extra readback8zero đạt, mạng1/1 đã restore. [Log](../../test-reports/evidence/native-offline-actual-2026-11-13-r2.log), [manifest17files](../../test-reports/evidence/native-offline-manifest-2026-11-13.json), [report và giới hạn](../../test-reports/FEAT-TN-001-completion-pass-2026-11-12.md).

O4b BUILD scope đã root review: entry Dart + shared Node consumer + existing fake-runtime adapter + offline consumer tests (≤4files). `offline-login` fixed phase; native675s, pre-ARM240s neo trước SDK spawn, native waiter240s, valid packet không reset pre-ARM. Before-packet async callback chỉ offline, không gửi private packet khi baseline còn pending; pin phase/PID/native remaining, drain original callback sau SDK stop trước return. Generic phases giữ channel60s và protocol cũ. Local caps110/110/170/170/5 và sharedACK30 theo gate. Để proxy/hostNoCA sẵn sàng trước SDK, ledger bảo thủ hiện hành dành TLS10 riêng: READY35+TLS10+preARM240+native675+finalSQL130+cleanup105=1195s, còn5s trong1200; reserve trước SDK1150, trước ARM910, trước final235. Baseline SQL bắt đầu cùng pre-ARM SDK, không tăng TTL hoặc bỏ negative/live/final oracle. Source/host/independent review và actual CLI vẫn là các checkpoint riêng, không mở actual từ constant ledger.
O4c BUILD scope đã root review gồm5files fixture Python, controller Node hiện có, shared startFixture và hai tests offline mới. Profile `offline-login` neo TTL1200 trước spawn và cho phép fixed read-only sessions/audit/workspace A/B trong một MVCC snapshot. UUID selector lấy config live của original launcher, kiểm run/provenance/role marker, user0/owner4 và grants active. Node chỉ expose read evidence ở offline profile, mutation SUSPEND_B chỉ membership profile. Query giữ control lock tới raw terminal, STOP đặt latch rồi join lock trước graph cleanup qua operation_holders. Bounded rows16/32/2, không nhận raw SQL hoặc UUID selector từ host. Kiểm packet/profile, read scope, wrong owner/schema/duplicate/overflow/STOP và existing fixture regressions trước actual.

O4d/O4e BUILD scope đã root review. Reuse HTTP oracle bằng preset offline fixed9requests, prefixes1/1/2/5/9, chỉ B-detail matchesTarget. Scoped DB giữ baseline và negative nguyên vẹn, live-mid thêm đúng một AppUUID, final revoke cùng UUID và đúng login/logout audit. Negative SQL bắt đầu tại result trong lúc restore, phải join original operation trước quiet ACK. Baseline SQL bắt đầu cùng SDK pre-ARM, sau baseline mới biết UUID B để bind proxy và hostNoCA trong10s, trước valid packet. Đây là điều chỉnh thứ tự kỹ thuật của ledger1195s phía trên, TLS nằm trong nhánh prepare song song, giữ nguyên reserve bảo thủ và TTL. Coordinator giữ restore mạng khi failure, fixture/proxy/SDK/SQL original terminals, chỉ CLI `--offline` fixed trên emulator API36 đã pin. Host tests kiểm temporal HTTP, DB delta/audit/negative, pending owners và cleanup trước actual.

Provider projection follow-up I1 đã root review trước BUILD. Bổ sung assertion error-envelope-only cho limited `/devices` và denied workspace detail, cùng empty-account gọi known workspace A để kiểm access-denied thật. Reuse original5users/2workspace fixture và provider verifier, không thêm principal/grants/data. Host test verifier với synthetic HTTP phải bắt status đúng nhưng body chứa data, sau đó actual provider chạy riêng khi offline independent đã terminal. Case chỉ chuyển PASS sau actual assertion và original cleanup.

Web cookie variant W1 đã root review. Test-only one-shot Vite proxy observer bỏ duy nhất Set-Cookie của một POST login200 sau ARM fixed, giữ body/context nguyên vẹn. Kết hợp controller mất response hiện có để tạo committed login B nhưng jar còn cookie A, kiểm discovery chỉ candidate và explicit confirmation mới được nhận phiên. Hai source/testfiles mới, host negatives cho wrong method/path/status/header và replay trước actual. Không chỉnh Vite config production hoặc đọc/log cookie value. Browser missing-cookie variant dùng CDP xóa đúng cookie iot_session của localhost fixture, không đụng origin khác. Report phải giữ riêng variant cookieB tự áp dù Fetch.fail response và variant cookieA do proxy omission.

UI follow-up U1 từ Chrome runtime đã root review. AuthPage và auth.css (2files) chỉ dùng split showcase ở form login. Loading, limited/password-change, picker/empty, selected, recovery/offline/error dùng card tác vụ một cột, giữ header/home/theme và các token design-system. Navigation và state authority vẫn do coordinator hiện có. Không thêm heading hoặc copy quảng cáo vào màn nghiệp vụ. Verify TypeScript/26hosttests, actual selected→picker→logout/login qua API thật, kiểm showcase vắng/có theo phase và responsive320px/desktop. Hai truy vấn UI skill không tìm thấy guidance trực tiếp về task layout, nên quyết định dựa yêu cầu user cùng design-system hiện có.

- [ ] Final test/review: dùng evidence manifest theo code hash, sửa finding và retest phần ảnh hưởng; đồng bộ bảng acceptance hiện hành thay vì tick checklist lịch sử. Physical N/A phải ghi rõ trong báo cáo cuối.

### Lát cắt Web alert sau Chrome12/11 — ROOT_SOURCE_HOST_RUNTIME_PASS / READY_FOR_QA

Root cause đã đối chiếu: `signIn` chỉ đặt busy khi xếp hàng Web Lock, giữ error của lần POST trước; `AuthPage` ghép error đó với validation local. `invalidate` còn được gọi khi resume/StrictMode cleanup nên câu chữ “tab khác” không luôn đúng.

| State hiện hành | UI cần có | Guard giữ nguyên |
| --- | --- | --- |
| Local validation sau AUTH_INVALID/VALIDATION_ERROR | Chỉ lỗi field hiện tại và summary liên kết focus | Không gửi POST khi field sai |
| Login mới đã xếp hàng Web Lock | Loading/controls khóa, xóa error POST cũ ngay | Một intent/POST, generation và marker fence |
| Rate/storage/unknown/recovery | Giữ thông báo và action đối soát tương ứng | Không reset cooldown, logoutPending, marker hoặc tự replay |
| Invalidate do resume/tab/cleanup | Thông báo trung tính cần xác nhận lại trạng thái phiên | Protected UI khóa, restore/confirmation vẫn thật |

- [x] BUILD giới hạn `AuthPage.tsx`, `coordinator.ts` và regression `auth.test.mjs`; giữ layout/navigation/tokens theo design system hiện hữu. Không thay API/DB/mobile hoặc broaden auth authority.
- [x] Root host RED9d6410/GREEN26tests05f891; queued retry sạch error trước nhả lock, một POST mới; TypeScript b426ba và ViteRAM42modules8c8dff exit0.
- [x] Root Chrome DB thật run31f937ae: disabled→submit trống chỉ local errors→valid full/picker/A→reload/message trung tính→logout. Original23922 cleanupPASS/exit0, Vite55715 exit0 và ports absent. [Report/hashes/evidence/Tester](../../test-reports/FEAT-TN-001-chrome-real-db-2026-11-12.md).
- [ ] Independent source/runtime review: tester GPT6.1/xhigh audit dừng usage limit, chưa có independent PASS. O4 Android và whole feature vẫn INCOMPLETE.

Lượt Chrome trước fix12/11: **ROOT_SCOPED_UI_RUNTIME_PASS / READY_FOR_QA** với DB thật. Full A/Admin→reload→B/Member→A→logout, disabled/empty/limited gate, validation/theme/keyboard và375px đã thực chạy. Fixture cleanup PASS, Vite exit0 và ports absent; helper lượt đầu không có numeric exit receipt. Hai điểm alert tìm thấy ở lượt này đã được sửa/retest theo lát cắt phía trên. [Report/evidence/Tester](../../test-reports/FEAT-TN-001-chrome-real-db-2026-11-12.md). Chrome BLOCKED bên dưới là lịch sử; toàn feature vẫn **INCOMPLETE**.

O3 checkpoint11/11 tiếp nối O2: **ROOT_SCOPED_RUNTIME_PASS / SOURCE_HOST_ACCEPTED / READY_FOR_QA**. API36 capability EFFECTIVE: nativeR→U_SOCKET→R, H2 cumulative1/1/2/incomplete0, same AVD/proxy/cert và ba SDK invocations riêng. Root owned83303 terminal463806 exit0; source/host independent19+44markers và audit artifact đạt, independent actual repeat chưa chạy. Main đã restore, AVD81921 terminalexit0; snapshot autosave có warning dung lượng, chưa chứng minh snapshot persistence. [Report/code state/lệnh/giới hạn](../../test-reports/FEAT-TN-001-api36-network-2026-11-11.md), [review độc lập](../../test-reports/FEAT-TN-001-api36-network-review-2026-11-11.md). O4 main UI offline/reconnect/H2/DB, Chrome và toàn feature INCOMPLETE.

Checkpoint mới nhất O2 ngày11/11: **SOURCE_HOST_ACCEPTED / READY_FOR_QA** cho harness, **ACTUAL_FAULT_FAILED / SHELL_WIFI_PERMISSION_NOT_PROVEN** trên API24. Root/independent host19+19markers đạt; guest fault thật chưa có off canary, Wi-Fi command/restore ACK không xác nhận, final settings1/1/airplane0 và recovery native reachable. Đã thêm preflight chặn trước cert/ports/fault khi thiếu proof quyền, không grant. Stale membership có root+independent runtime checkpoint S2c2b2 riêng bên dưới. Chrome, offline UI/H2/DB và các gate acceptance khác vẫn mở; toàn feature INCOMPLETE. [Report hiện hành và code state](../../test-reports/FEAT-TN-001-guest-network-2026-11-11.md).
- Trạng thái kế hoạch: `VERIFY_IN_PROGRESS / FEATURE_INCOMPLETE`. Các lát cắt đã triển khai được bàn giao theo scope READY_FOR_QA ở checkpoint hiện hành. CP-01/02/03, owner review và ma trận acceptance vẫn theo tiêu chí gốc.
- Quyết định hiện hành: [ADR-002](../../adr/adr-002-freeze-implementation-baseline.md). Các đáp án thiết kế mục22 và sửa đổi R2 đã chốt; protocol Web auth-context bổ sung theo REV-AUTH-001/002 ở mục13.1 là addendum chờ API/Web/Mobile owner review CP-01, chưa coi là quyết định wire đã duyệt. Artifact G1, dữ liệu môi trường và PoC vẫn phải kiểm chứng; không đổi task/test thành hoàn thành. Điểm bắt đầu và điều kiện dừng: [implementation-start.md](../implementation-start.md).
- Trạng thái triển khai: Web Chrome có root UI/API full/empty/disabled/limited/rate và response-loss R2 scoped PASS. Android API36 có root/independent full/access/password/rate, API24 có root full/access/password/rate scoped PASS. App offline/stale và Web/App session independence có evidence một phần. Flutter162tests PASS ngày09/11. Các nhánh browser race, exact HTTP App offline, storage/physical/accessibility và owner acceptance còn mở. Xem checkpoint mới và bảng tiến độ, chưa nghiệm thu toàn feature.
- Lịch sử checkpoint backend/UI ngày28/10 sau phê duyệt DB cụ thể: quyền nghiệp vụ DB RESOLVED; provider176assertions/163distinct IDs và cleanup readback M4b-P PASS tại checkpoint trước. Pool held8 qua hai503/metrics-end, PoolAcquire/Error WEB5009419/ANDROID5014308µs, state unchanged/recovery cùng pool;96isolated Rust/88host/16focused độc lập/fmt/Clippy PASS. Baseline60login/540stages/36groups và lock budget regressions vẫn chạy trong suite. Q chỉ hasher unit, chưa HTTP queue overload/production SLO. Ngày2026-10-28 Chrome thật đã kiểm validation/theme/responsive/keyboard/recovery backend-unavailable và negative cross-tab; [Web runtime](../../test-reports/FEAT-TN-001-web-browser-2026-10-28.md). Sau execution policy mới: canonical provider176/cleanup readback0 PASS ngoài sandbox; Pixel_7/API36 và2native configuration cases PASS; CUA hiện unavailable. UI2 root13focused/128full/analyzer/format PASS sau test fixture zone fix; [UI2 files/logs/Tester](../../test-reports/FEAT-TN-001-android-application-2026-10-28.md). Normal SDK đã chạy ngoài sandbox theo policy mới; không đổi Git trust/owner/dependency. [Resume runtime](../../test-reports/FEAT-TN-001-runtime-resumed-2026-10-28.md). Independent design/review PASS; runtime owner=root, native/storage/topology còn mở. Không coi provider hoặc widget PASS là đóng toàn gate. [Audit trước phê duyệt](../../test-reports/evidence/auth-e2e-resumed-gate-audit-2026-10-26.json) là lịch sử.
- Mức ưu tiên: `Must`
- Loại lát cắt: `Vertical feature slice`
- Nền tảng áp dụng: `Rust backend`, `React + TypeScript Web`, `Flutter/Dart Android`
- Không áp dụng: `iOS`

## 1. Mục tiêu bàn giao

Checkpoint actual10/11 sau H2. App API24 có AUTH_LOGIN401/REQUEST-STATUS-CLOSED, Web cùng credential login/logout và exactWebsession/revoke đã kiểm. Offline/stale toànluồng còn mở. Lượt trước hết20m, CUA retry dừng do input ngoài phiên. Original cleanup đã kết thúc và main defaultSDKrestore/PID4847/foreground/airplane0, UI restore chưa kiểm lại. [Actual evidence và next native integration](../../test-reports/FEAT-TN-001-api24-http-control-2026-11-10.md).

Checkpoint10/11 HTTP observer H1/H2. Tester độc lập đã tìm và xác nhận lỗi raw saturation32+33, root sửa observed fail-closed bằng RED/GREEN. Proxy7DF9159A cùng transport6 và CLI9markers đã root và independent PASS. Final independent11suite strict exit0, source/comment/security accepted, ports đã trả. **SOURCE_HOST_ACCEPTED / READY_FOR_QA**. Actual App HTTP offline/stale còn NOT_RUN, toàn feature INCOMPLETE. Các checkpoint H1/proxyE4E9 bên dưới là lịch sử. [Report H2](../../test-reports/FEAT-TN-001-http-observer-h2-2026-11-10.md).

Checkpoint09/11 HTTP captureH1. Hai helper/testfiles mới đã root hostPASS8markers/syntax và2targetedmutation guards. Raw/secure active, per-raw capability, target matcher, prefix256bytes và redacted snapshot/ledger đã hiện thực. **ROOT_SOURCE_HOST_PASS / READY_FOR_QA**. Proxy/CLI H2 và actual HTTP App còn NOT_RUN, final independent review bị usage limit. Proxy source E4E9 giữ nguyên. [Report H1](../../test-reports/FEAT-TN-001-http-capture-h1-2026-11-09.md).

Checkpoint09/11. API24 rate root95652 và tester độc lập84966 đều terminal exit0, đủ native real900s, request/session/PID và original owned cleanup. Hai namespace đọc lại8zero. **SCOPED_RUNTIME_PASS / READY_FOR_QA**. B3 swallowed-tap source/host accepted, Flutter162/Web25/contract39PASS. Mainrestore30435 exit0, PID4535/API24/foreground/configurationgate, airplane0. Vite26040 phục vụ5173. Lượt20834 giữFAIL/mất isolate chưa rõ nguyên nhân. Toàn feature còn browser races, exactHTTP offline/stale, physical/accessibility/storage và owner gates. [Bàn giao09/11](../../test-reports/FEAT-TN-001-handoff-2026-11-09.md).

Checkpoint09/11. API24 rate retest95652/5ea198 đã exit0, đủ native real900s/UI, exact request/session/PID oracle và original owned cleanup. Fresh run c732454f đọc lại8zero, post-package absent và listener3000/8443 vắng. **ROOT_SCOPED_RUNTIME_PASS / READY_FOR_QA**. Lượt20834 giữ FAIL/mất isolate chưa rõ nguyên nhân. Independent API24 và main restore tiếp theo còn mở. [Report và manifest](../../test-reports/FEAT-TN-001-api24-rate-2026-11-08.md).

Checkpoint09/11. API24 rate20834 đã kết thúc exit1 theo log gốc, SDK ISOLATE_NOT_READY và package stop/daemon cleanup chưa xác nhận. Chưa đạt900s hoặc orchestration PASS. Fresh readback d2ded8 của run f989b9bb trả8nhóm0, emulator hiện đã tắt. Giữ **FAIL**, boot/retest có log riêng. [Report và evidence](../../test-reports/FEAT-TN-001-api24-rate-2026-11-08.md). Runbook đã làm rõ mở terminal/Force stop/restore main/cleanup. Toàn feature INCOMPLETE.

Checkpoint08/11 offline/stale AppAPI24. Mainactual airplaneON→Mất kết nối/fields cleared, seed-onlyDB; restoreOFF→passiveUI34.586s vàDBsample28.038s chưa cósuccesssession mới; explicitretry mới+1AndroidUUID. StaleB suspend→UIdeny→reloadonlyA→Acontrol→logoutsameUUID, originalproxy/fixtureexit0 vàfresh8zero. **ROOT_PARTIAL_RUNTIME_VERIFIED / READY_FOR_QA**, exactAndroidHTTPcounters/independentrepeat vàstorageforensic chưa kiểm. Mainrestore93591exit0/PID6117/API24/configurationgate, airplane0. [Report/evidence/Tester](../../test-reports/FEAT-TN-001-api24-offline-and-stale-2026-11-08.md).

Checkpoint08/11 API24. Native full/coldresume/logout58323, access25218 và password/coldrelogin48439 đều target/oracles/originalcleanup/terminalexit0, **ROOT_SCOPED_RUNTIME_PASS / READY_FOR_QA**. Mainrestore90773 exit0, PID5482/foreground/API24, configurationgate sau cleanup. Browser hai-tab mới BLOCKED bởi Work settings, chưa tạofixture. Independent API24 và các gate device/lifecycle/accessibility vẫn mở. [Commands/logs/sourcehash/Tester](../../test-reports/FEAT-TN-001-api24-integration-2026-11-08.md).

Checkpoint08/11 tiếp nối. Controller response-loss đã source/host review accepted,22casesPASS. Chrome root R2 faultACK1057ms/failedsameID, exact+1Websession/audit và verified reload/recovery/candidateconfirm/logout đã **ROOT_SCOPED_RUNTIME_PASS / READY_FOR_QA**. Web staleB membership commit→detail404/error-only→recovery→pickerA/control200 đạt cùng scope. Fixture31479 terminalexit0/cleanup8zero. Initialreloadnetworkgap và independentruntimeNOT_RUN (tester usage limit trước thực thi) giữ rõ trong [report](../../test-reports/FEAT-TN-001-web-response-loss-r2-and-stale-2026-11-08.md). Toànfeature vẫn chưa nghiệm thu.

Checkpoint08/11 hiện hành. Chrome + App main Android7/API24 đã cùng account, A/Admin và B/Member, logout hai chiều và recheck client còn lại, exact session deltas/revocation, original proxy/fixture terminal exit0 cùng tám nhóm cleanup0. **ROOT_SCOPED_RUNTIME_PASS / READY_FOR_QA**, không sửa product source. Lượt shared07/11 hết TTL/exit1 giữ partial, readback hiện0. API24 lifecycle/physical/audit và independent UI repeat còn mở. [Report, manifest, lệnh và giới hạn](../../test-reports/FEAT-TN-001-shared-web-api24-2026-11-08.md). Task kế đủ dependency là lost-body sau commit và stale membership theo [mapping tester](../../test-reports/FEAT-TN-001-completion-mapping-2026-11-08.md).

Checkpoint07/11 hiện hành. Web API thật **SCOPED_RUNTIME_PASS / READY_FOR_QA** cho full A→B/reload/logout, empty, disabled401 và limited200/me403/password-only. Actual đã phát hiện và sửa stale validation giữa form đổi mật khẩu/login. Final AuthPage BA92 có static review render guard và actual limited→blank→logout→login sạch. Flutter161tests/analyzer6files PASS, producer4cases cùng Node negative matrix accepted scoped. Web rate **ROOT_SCOPED_RUNTIME_PASS / READY_FOR_QA** owned83847 đã921054ms/no-autoPOST/correct200/A-B/logout204, DB exact session/revoke và original cleanup/exit0. Independent UI repeat/cross-client vẫn mở. Hai checkbox B3/checkpoint vẫn mở theo strict mapping. [Report/files/commands/limits/Tester](../../test-reports/FEAT-TN-001-web-api-and-negative-coverage-2026-11-07.md).

Lịch sử checkpoint bàn giao06/11, được checkpoint07/11 phía trên thay thế. **Native rate API36 SCOPED_PASS / READY_FOR_QA** sau rootR3/82546 và independent31654 đều exit0, real900s/no-autoPOST/7thcorrect/logout cùng original8zero/shim/proxy terminal. Main20323 đã restore lib/main.dart, foregroundPID6912/API36 tại28339e. [Native manifest/logs/recovery](../../test-reports/FEAT-TN-001-native-rate-cli-reserve-2026-11-06.md).

Tại checkpoint06/11, Helper Web4files đã **SOURCE_HOST_ACCEPTED / READY_FOR_QA**, race output-after-STOP và comment nit đã đóng, hai host suites root/independentPASS. Actual Web **NOT_RUN** vì cả CUA và JavaScript controller hiện lỗi khởi tạo kernel assets sau reset. Chưa tạo helper fixture thật hoặc private key trong controller ở phiên tiếp tục. [Source/manifest/tests/blocker/Tester](../../test-reports/FEAT-TN-001-browser-private-handoff-2026-11-06.md).

R1 rate RESULT_UNCONFIRMED do mất terminal. R2 FAILED_LAUNCHER đã recovered role/HBA/account/workspace graph7zero, còn2limiter rows được giữ theo recovery policy. Các successful scoped8zero sau đó áp dụng namespace của từng lượt. Toàn feature tiếp tục các gate Web/API/cross-client/races, API24/physical/accessibility và owner review.




Checkpoint06/11. Chrome đã kết nối lại, Web dev5173 đã khởi động, build42modules exit0 và auth25/25 PASS. Browser thật đã kiểm submit trống/summary-focus/link-focus, unavailable→recovery, quay lại login, theme sáng và responsive375px. Hai link CTA/footer Đăng nhập đã sửa `/login` và click thật PASS. Đây là **PARTIAL_RUNTIME_VERIFIED**, chưa browser/API login success. Android owned86769 đã terminal2dcdec exit0 full/resume/logout/cleanup trênC887. PID gate mới runnerE3BB đã SOURCE_HOST_ACCEPTED, root actual regression owned42194/bbc475 đã exit0 full/resume/logout/cleanup, independent full/access/password nay đều exit0 và owned cleanup. Lượt29209 bên dưới thực tế đã FAIL startup resume ngày01/11, proxy/fixture cleanup PASS nhưng native PID còn sống lúc readback. [Evidence và Tester hiện tại](../../test-reports/FEAT-TN-001-runtime-resumed-2026-11-06.md).

PID gate06/11 **SOURCE_HOST_ACCEPTED / ROOT_ACTUAL_SCOPED_PASS / READY_FOR_QA**. Đã sửa oracle để chỉ công nhận absent khi shell đúng device/package trả receipt rõ, fail closed với transport/timeout/malformed. Shared entrypoint gate trước SDK spawn và sau actual SDK terminal trên cả success/failure, vẫn cleanup fixture/proxy độc lập và giữ failure gốc. Root/independent6host suites PASS, docs Nit đóng; actual PID absent2f083f PASS, full/resume/logout regressionE3BB42194/bbc475 exit0. Tiếp theo là access/password và independent native repeat rồi rate theo prerequisite. Không auto force-stop hoặc tăng timeout. Toàn feature vẫn chưa nghiệm thu.

Navigation UI06/11 **SCOPED_RUNTIME_PASS**. Đã sửa đúng hai href Đăng nhập CTA/footer trong `HomeSections.tsx`, header đã dùng `/login`. Chrome xác nhận ba href `/login`, click footer và CTA tới heading/form thật, đã lưu ảnh; build42modules và25tests PASS, independent source review không finding. Bố cục/tokens/state matrix hiện hữu, phạm vi này chưa chứng minh login API hoặc chức năng tạo workspace.

Checkpoint nguồn B3c01/11: **SOURCE_HOST_ACCEPTED / READY_FOR_QA**, final independent v3
proxy91916/5fcbf2 exit0, không còn Blocker/Important source/host. Internal orchestration đã nối READY/proxy/ARM/noCA/ratephase/owned
terminal, lifetime guards và external abort. Ba finding độc lập đã sửa; source frozen10files,
không UI/Dart/DB/SDK changes trong slice này. CLI rate còn đóng. Các native PASS checkpoint
recovery bên dưới thuộc manifest B3b trước B3c; cần regression sau source acceptance rồi mới
root/independent actual429/900s. Root full-session29209 đã terminal exit1 ở startup resume, xem checkpoint06/11.
[B3c files/hashes/commands/limits](../../test-reports/FEAT-TN-001-native-rate-orchestration-2026-11-01.md),
[kiểm độc lập](../../test-reports/FEAT-TN-001-native-rate-orchestration-independent-2026-11-01.md).

Checkpoint01/11 sau khởi động lại ChatGPT: Docker canonical identity và NDK compiler đã truy cập được.
Root và independent B1b actual diagnostic PASS: unknown401 → exactquery bucketdelta+1 → normal/pendingSTOP
exact8zero và shimexit0. Native preflight và root full/coldrestore/logout/cleanup exit0;
Tester độc lập đã đạt full/access/password và cleanup exit0 trên manifest B3b giữ nguyên.
Main mặc định đã build/install/launch exit0, API36/Android16 và MainActivity topResumed.
Web dev đã mở cổng5173,25tests/buildPASS; Chrome extension đã kết nối lại, mở `/login`
và kiểm empty submit/summary focus, có ảnh thật; sau lần mất kết nối, user đã mở lại Chrome,
extension id4/tab1462331326 đã xác nhận form sạch và giữ tab/lưu ảnh bàn giao.
Chưa browser/API login success E2E mới; setup fixture browser chưa tới spawn.
B3b source manifest giữ nguyên.
[Current runtime/evidence/Tester](../../test-reports/FEAT-TN-001-runtime-recovery-2026-11-01.md).
Không dùng checkpoint này để đóng rate900s hoặc toànfeature; B3c/consumerregressions còn mở.

Checkpoint hiện hành31/10: **B3b SOURCE/HOST PASS / READY_FOR_QA**, chưa native rate actual.
Root và tester GPT-6.1/xhigh đã kiểm20Flutter host tests, analyzer/format vàNode8/13/5markers,
matching hashes; findings tickrace vàearlycredentialcleanup đãđóng. Target đãnối6wrong/429,
realStopwatch observation rồi7thcorrect/logout trongmã; hostprivatepacket/scanner2secrets đồngbộ.
Không lấy source/mockclock/widgetPASS thay cho900s device. MainCLI vẫnđóngratecase chođến
B1bactual/sharednative regressions vàB3c orchestration đạtprerequisite.
[Combined files/hashes/commands/limits](../../test-reports/FEAT-TN-001-native-rate-scenario-2026-10-31.md),
[review độc lập](../../test-reports/FEAT-TN-001-native-rate-scenario-independent-2026-10-31.md).
B3a11primitive tests cũng đã independentPASS; target/runner manifests cũ làlịch sử.
Chrome đãkhôi phục; runtime blockers gầnnhất vẫn Docker pipe vàNDKclang permission denied,
chưa chạy lại device/DB ở B3b. [Runtime notes](../../test-reports/FEAT-TN-001-native-rate-evidence-2026-10-31.md).
Không đủmục25 đểđánh toàn feature100%; UIWeb validation chỉ scope đãghi ởbrowserreport.

Lịch sử checkpoint ngày30 (manifest/runtime cũ): B2b-2a source/host accepted; finding phase/staleguard đóng.
Đã sửa8vị trí plan còn ghi password12–128 theo override user: login9–128,
current1–128, new9–128 kèm hoa/thường/số ASCII; tester GPT-6.1/xhigh đã đối chiếu
fixture và validator ba stack, DOC_ALIGNMENT_PASS; UT/CT/runtime gates không tự đóng.
Browser vẫn trả **Local browser use is disabled in Work settings** sau user @Chrome.
Android Gradle help exit0; build integration87494 exit1 vì tải ARM artifacts bị chặn,
preflight ba2dcf exit1, ADB fresh d7ebb5 lỗi thư mục cấu hình. Build main owned67965
đã terminal b78e69 exit1, NDK clang.exe Permission denied; chưa APK/main restore mới.
Docker vẫn blocked; mọi SDK job lượt này đã terminal, không có native PASS mới.
[Runtime hiện hành, command outcomes và limits](../../test-reports/FEAT-TN-001-runtime-recovery-2026-10-30.md),
[audit acceptance/gap và independent document review](../../test-reports/FEAT-TN-001-completion-gap-audit-2026-10-30.md).
Không dùng boot/package/build hoặc host tests để đánh toàn feature100%.

C2-C429: B0 exact logout counter, B1a bounded binding và B1b bucket cleanup source/host PASS
với tester GPT-6.1/xhigh độc lập; B1b20/88host/protocol/source review accepted. Actual B1b bị
Docker named pipe denied trước fixture, retry sau network grant vẫn BLOCKED. Chưa SDK/DB
fixture hoặc actual429 mới. B2a ARM/profile source/host đã accepted: root26/35host,
independent26/88host và Node returned-factory cleanup PASS, Important đã đóng. Escalated
preflight bị policy tự động từ chối trước execution vì sandbox_approval=false. B2b RPC/phase
deadline B2b-1 đã root/independent host/source PASS, Important pending-oracle đóng: timeout
dừng SDK nhưng vẫn giữ I/O ownership tới completion, late result không PASS. B2b-2a checkpoint5s
root/independent host/source PASS, phase mismatch/staleguard findings đóng. B2b-2b snapshot/feasibility và callback fence host đã accepted31/10 theo report đầu mục;
B3 vẫn chưa mở rate CLI/native scenario;
chưa đủ prerequisite để chạy rate scenario. Các native PASS C2-B bên dưới thuộc frozen
baseline trước B0; harness mới cần consumer regressions sau implementation.
[B0 report/files/evidence](../../test-reports/FEAT-TN-001-native-logout-observer-2026-10-30.md),
[B1a report/files/evidence](../../test-reports/FEAT-TN-001-native-bucket-binding-2026-10-30.md),
[B1b current files/evidence/blocker](../../test-reports/FEAT-TN-001-native-bucket-cleanup-2026-10-30.md),
[B2a current combined manifest/review/blocker](../../test-reports/FEAT-TN-001-native-rate-arm-2026-10-30.md),
[B2b-1 current manifest/commands/review](../../test-reports/FEAT-TN-001-native-rpc-deadline-2026-10-30.md),
[B2b-2a current manifest/commands/review/runtime](../../test-reports/FEAT-TN-001-native-checkpoint-deadline-2026-10-30.md),
[plan/dependencies](../../test-reports/FEAT-TN-001-native-rate-limit-plan-2026-10-30.md).

Thứ tự đóng toàn feature theo mục18–25, giữ nguyên acceptance:

| Gate còn mở | Bằng chứng phải có trước khi đóng |
| --- | --- |
| Môi trường actual hiện tại | Gradle build/SDK preflight terminal thành công; Docker canonical identity, fixture owned và cleanup positive→zero; browser connector hoạt động |
| `AT-WF-001-01`, `TS-TN-001`, `E2E-AUTH-001` | Root Web+AppAPI24 cùng fixture và logout hai chiều đã scoped PASS08/11. Audit/redaction cùng fixture, independent repeat và acceptance review còn mở |
| `AT-WF-001-02/03`, `E2E-AUTH-002/003/004` | Limited guard/no resource trước workspace/disabled generic trên API và UI thật; baseline provider/native phải được đối chiếu manifest mới |
| `E2E-AUTH-005` | Native API36 root/independent real900s và Web root921054ms đã scoped PASS theo manifest06–07/11. API24 root/independent09/11 cũng scoped PASS. Independent Web UI, physical matrix và strict negative mapping B3/checkpoint vẫn mở |
| `E2E-AUTH-006…008`, `WEB-AUTH-012…015` | Browser races/reload/two tabs/lost response/recovery và workspace permissions đổi trong luồng, đúng request/context/data boundary |
| Mobile/storage/accessibility | Native recovery/offline/lifecycle/account switch, minimum supported API/physical targets và keyboard/semantics/TalkBack/rotation theo scope; preview/host không thay actual |
| Contract/security/review/handoff | Map từng case mục18 tới PASS/FAIL/BLOCKED/NOT_RUN và evidence, đóng P0/P1, redaction/correlation/header compatibility, review cùng code state và runbook tái hiện |

Đây là checklist phần còn mở. B3c orchestration/host và native API36 rate đã có evidence scoped theo checkpoint mới. Task kế là Web lost-response và stale membership với commit/ownership oracle, không nới acceptance.

C2-B limited/password ngày30: SCOPED_RETEST_PASS / READY_FOR_QA.
Root7455 terminal/reapedde790d và tester GPT-6.1/xhigh29792 terminal5e73c8 exit0:
hai native phases/password session/request/PID oracles, owned proxy/fixture cleanup và
overall markers PASS trên bounded hit-test helper có RED/GREEN/full137tests/analyzer/source review.
C1/C2-A regressions91745/25293 và main restore94938 exit0; Android16/API36/main app hiện diện.
Whole-feature chưa nghiệm thu; C2-C429/C2-Doffline/browser/device/owner gates còn mở.
Các lượt FAIL trước và lượt21257 mất handle/outcome UNCONFIRMED được giữ trong report;
fresh DB readback0 không thay exit/proxy evidence của lượt đó. Browser actual chưa kết nối.
[Report hiện tại](../../test-reports/FEAT-TN-001-native-password-continuation-2026-10-30.md),
[lịch sử/files/evidence](../../test-reports/FEAT-TN-001-native-password-2026-10-29.md),
[plan/budget ledger](../../test-reports/FEAT-TN-001-native-password-plan-2026-10-29.md).

C2-A disabled/empty2026-10-29: reviewed plan và source/host review PASS trước runtime.
Root35299terminal9f1602exit0: generic disabled/wrong denial, confirmed empty/create disabled/
refresh/logout, six ordered counter ACKs/exact session maps/PID/cleanup7counts0 PASS.
Independent3682terminale62d17exit0 đạt cùng actual oracles/cleanup. SCOPED_RETEST_PASS/
READY_FOR_QA; C1 actual regression43502 trên consumer mới và mainrestore11693 exit0;
C2 remainder còn mở.
[Report/files/evidence](../../test-reports/FEAT-TN-001-native-access-2026-10-29.md),
[plan/checkpoints](../../test-reports/FEAT-TN-001-native-access-plan-2026-10-29.md).

C1-B actualmain/full/cold restore/logout2026-10-29: rootnative92226 và
instrumented79687exit0; independent instrumented8744exit0. UI/API/TLS/securestorage,
oldnativePIDdeath/newPID, exactserverUUIDdelta, globalLOGIN1/resume0/profileGETpositive
và7cleanupcounts0 PASS. Hosttests/analyzer/format/C0native regressionPASS;
independent sourcefinding2đãđóng. SCOPED_RETEST_PASS/READY_FOR_QA, giữ open startup
reliability: QA3997 trước đó resume startupASSERTIONexit1, rootreadback7counts0;
repeat PASS chưa chứng minh nguyên nhân đã được sửa. Main mặc định restore13804exit0.
C2/Web/requirednativegates còn mở, chưa nghiệm thu toàn feature.
[Handoff/Tester/evidence](../../test-reports/FEAT-TN-001-native-full-session-2026-10-29.md).

C1-A1 request oracle/RAM fixture2026-10-29: root25TLSpaths và13shimhosttests
PASS; observer independent6+mutation/reviewPASS, shim independent13source/fakePASS.
Root và independent mỗi bên2actualfixturecases có7readbackcleanupcounts0/exit0.
Cold restore oracle đã sửa theo seed baseline và exact UUID→revoked delta, không
đổi provider/seed. SCOPED_RETEST_PASS/READY_FOR_QA; C1-B actualmain/login được cập nhật ở checkpoint trên.
[Handoff/files/evidence](../../test-reports/FEAT-TN-001-native-fixture-2026-10-29.md).

C1-A0 cleanup launcher2026-10-29: tester phát hiện hai nhánh bỏ qua cleanup,
đã fix bounded bridge/independent role-HBA cleanup và giữ childterminal gate.
Root9new+88existing, independent9+88/3mutation PASS; provider176assertions
và canonical SELECT8counts0 sau terminal exit0. SCOPED_RETEST_PASS/READY_FOR_QA,
chưa actualnative C1 acceptance. [Files/evidence/Tester](../../test-reports/FEAT-TN-001-native-cleanup-2026-10-29.md).

T1-C0 native SDK RAM-control preflight2026-10-29: root và tester GPT-6.1/xhigh
tự chạy trên Android16/API36 PASS; host6protocol+4lifecyclegroupsPASS,
analyzerNoissues/format0changed, mainrestoreexit0. Đây là kênh dữ liệu test
cho C1, chưa product main/TLS/API/login. [Handoff/files/evidence](../../test-reports/FEAT-TN-001-native-control-2026-10-29.md).
C1 còn oracle same-session/zero login POST/native-death cần review trước DB;
C2limited/errors chưa chạy. CUA re-probe vẫn unavailable. Không COMPLETE FEAT.

T1-B2026-10-29: proxy HTTPS loopback đã BUILD; root19actual TLS/CLI cases với
upstream synthetic PASS, T0 regression6PASS; independent19PASS và mutation cap
bị bắt cả request/response, SHA khớp; không open Important/Blocker trong scope.
SCOPED_RETEST_PASS/READY_FOR_QA, chưa native custom CA/API E2E.
[Handoff/files/commands](../../test-reports/FEAT-TN-001-local-https-proxy-2026-10-29.md),
[runbook mở backend/proxy/App](../../Instructions/feat-tn-001-e2e-testing.md#5a-mở-app-qua-https-local-dành-cho-android-emulator).
Task kế tiếp T1-C: native actual TLS/API trên fixture có cleanup; không đóng C1-N/FEAT.

T1-A debug lab trust đã SCOPED_RETEST_PASS/READY_FOR_QA: main nhận public
`AUTH_LAB_CA_CERT`, chỉ debug/exact emulator origin; private SecurityContext,
không global trust/TLS bypass. Root6focused/134full, product/profile compiler
flag1case mỗi mode, analyzer/format và2native configuration regression PASS;
tester GPT-6.1/xhigh tự chạy6focused PASS, source review không open finding.
Native custom CA/API handshake chưa chạy; proxy T1-B được cập nhật ở checkpoint trên.
[Handoff/code/evidence](../../test-reports/FEAT-TN-001-debug-lab-trust-2026-10-28.md).

Dependency HTTPS local2026-10-28: Node/OpenSSL probe memory-only đã PASS6cases
root và6cases tester GPT-6.1/xhigh tự chạy (trusted DNS/IP;
no-trust/wrong-CA/wrong-host/expired rejected), sau sửa
post-handshake socket error boundary theo tester GPT-6.1/xhigh. Không file key,
cert store hoặc TLS bypass; nhánh SslStream hủy trước BUILD vì hạn chế Schannel.
Root regression injection trước/sau fix PASS; source T0 không open Blocker/Important,
SCOPED_RETEST_PASS/READY_FOR_QA. Chưa fault-inject riêng timeout/stalled child.
Đây là feasibility trên host, chưa là App origin/proxy/native HTTPS/API E2E.
[Plan/evidence/review](../../test-reports/FEAT-TN-001-local-tls-plan-2026-10-28.md).

Resume sau execution policy mới2026-10-28: **ACTIVE / provider scoped PASS**.
Docker identity guard và provider176assertions/163distinct PASS ngoài sandbox;
cleanup readback role/HBA/fixture selector đều0. Pixel_7 đã connected/API36.
Native main configuration integration2cases đã PASS/exit0; analyzer sạch,
formatter1file0changed, main thật đã build/cài/run --no-resident exit0. CUA native pipe/browser host hiện unavailable;
trusted App HTTPS origin vẫn chưa có. [Runtime mới](../../test-reports/FEAT-TN-001-runtime-resumed-2026-10-28.md).
Không coi provider là browser/App login acceptance. Blocked audit bên dưới là
lịch sử của execution policy trước, không phải trạng thái goal hiện tại.

Goal audit2026-10-28 trước resume: **BLOCKED tại bước actual API/native E2E** sau ba goal
turns gặp cùng prerequisite; không đánh hoàn thành feature. [Live revalidation](../../test-reports/evidence/auth-e2e-blocked-audit-2026-10-28.json)
vẫn xác nhận Docker access denied và SDK Android không có device/AVD khả dụng
trong sandbox. Trusted App HTTPS origin chưa được xác nhận. Scope DB/SDK đã
được user cho phép; cần execution context và deployment/device sẵn sàng,
không hỏi lại quyền nghiệp vụ. Source/test và guide đã bàn giao READY_FOR_QA scoped.

[Hướng dẫn Tester mở Web/App và chạy từng ca E2E](../../Instructions/feat-tn-001-e2e-testing.md)
đã đối chiếu launcher/source UI hiện tại. Ngày2026-10-28 tái kiểm prerequisite:
Docker canonical `LOCAL_DOCKER_ACCESS_DENIED`; direct Android SDK `adb devices -l`
không có device và `emulator -list-avds` rỗng trong sandbox. Không suy ra AVD
của tài khoản owner đã bị xóa. [Evidence runtime prerequisite](../../test-reports/evidence/auth-e2e-runtime-prerequisites-2026-10-28.json).
Runbook tách test UI có thể làm ngay, Web/API cần backend và App cần trusted HTTPS/device;
không coi các bước chưa chạy là acceptance. Quyền nghiệp vụ DB/SDK đã được user duyệt,
execution policy/ACL thực tế và topology vẫn phải sẵn sàng.

### E2E006-Web-R1 — mất response login đã commit, PLAN08/11

Checkpoint runtime08/11. Ba attempts giữ response200 đều **INCONCLUSIVE** vì thiếu fault ACK trước15s; lần3 DB readback đã trước deadline nhưng round-trip ACK trễ. Recovery/reload/no-observed-replay/candidate-confirm/logout đã root PARTIAL_RUNTIME_VERIFIED, original fixture exit0/8zero. Giữ cả4checkbox mở. Cần bounded controller có reviewed supported channel/freshness/ownership trước repeat, không tăng timeout sản phẩm. [Timing, sessions, cleanup và giới hạn](../../test-reports/FEAT-TN-001-web-response-loss-2026-11-08.md).

Lát cắt runtime này chỉ kiểm Web full account trong fixture synthetic mới, không có cookie phiên cũ sau logout đã ACK. Reuse helper20phút và CDP response-stage interception của đúng POST `/api/v1/auth/login`, không sửa production hook hoặc timeout15s. Dependency là browser/Vite/backend owned sẵn sàng và read-only DB oracle UUID đã allowlist.

- [ ] Chốt baseline session metadata, giữ response200 của đúng login request. DB readback phải chứng minh thêm đúng1WEB UUID đã commit, seed nguyên vẹn, trước khi fault ACK. Ghi monotonic elapsed từ trước click đến failRequest ACK, bắt buộc dưới15s. Nếu gate không đạt, ghi INCONCLUSIVE và cleanup, không tăng timeout hoặc suy cause từ timeout. Không xuất raw CDP header/body/postData/cookie.
- [ ] Fault request đã pause, UI về recovery/loginUnknown, không protected profile/workspace; reload không auto replay POST hoặc tự accept session. Request identity/status và finite observation được giữ, không gọi đó là toàn bộ cookie-race matrix.
- [ ] Người dùng chủ động đối soát. Nếu `/me`200 thì chỉ candidate chờ nút xác nhận, explicit confirm mới picker rồi logout/revoke đúng UUID. Nếu `/me`401 thì giữ recovery không authority, explicit Đăng nhập lại và submit mới được tạo session2, logout chỉ revoke session2. Session1 orphan được ghi rõ và chờ owned cleanup. Không giả định response-stage interception đã lưu Set-Cookie.
- [ ] Finally giải phóng đúng paused request còn sống và disable Fetch, giữ original cleanup tới terminalexit0/eightzero, không để browser bị interception sau lượt. Source/QA review và report/progress/runbook cập nhật trước READY_FOR_QA.

Review đầu đã yêu cầu tách discovery200/401 và gate15s. Revised plan giữ cả hai và không coi helper Web có SNAPSHOT RPC. CookieA/B đến muộn, browser reopen/tab khác, App token loss và các nhánh E2E006 còn lại là lượt riêng.

### E2E006-Web-R2 — fault ngay sau response200, PLAN08/11

R2 giữ yêu cầu session đã commit nhưng client không nhận kết quả, no replay và explicit recovery. Source đã review cho thấy Pg transaction commit ACK → IssuedSession → handler200. Vì vậy DB readback sau fault dùng đối chiếu persisted delta, còn thứ tự commit-before-fault là suy luận từ source frozen + response200 quan sát được. Không ghi SQL đã đọc trước fault. Ba attempts R1 giữ INCONCLUSIVE. [Review độc lập](../../test-reports/FEAT-TN-001-web-response-loss-r2-plan-review-2026-11-08.md).

- [x] R2a SOURCE_HOST_ACCEPTED / READY_FOR_QA,22cases root/independentPASS. Tạo controller/test riêng `ops/auth/browser_login_response_fault.mjs` và `test_browser_login_response_fault.mjs`, không dependency mới. Chỉ được invoke actual trong CUA với CDP capability/submit callback. Exact Fetch response-stage URL, mộtPOST, status200/networkId, failRequestConnectionClosed ACK<15s và loadingFailed đúng request, clear patterns finally. Fake tests phủ wrong method/url/status/id, duplicatePOST, truncate, noevent, submit/fail/clear errors, late ACK/deadline. Publicreceipt không header/body/postData/cookie/credential. Source review trước actual.
- [x] R2b ROOT_SCOPED_RUNTIME_PASS / READY_FOR_QA theo report08/11. Fixture owned mới/canonical backend được build từ hashes đã ghi, Vite origin/proxy đúng, không mock hoặc service-worker path. Baseline trướcsubmit chỉ seed. Controller fault ngay cùng CUA call, query read-only sau fault exact+1WEB active, seed nguyên vẹn, bind run/email/provenance và không concurrent actor. ACK/failed không khớp hoặc deadline sai thì FAIL/INCONCLUSIVE, không nới timeout.
- [ ] R2c UI recovery khóa workspace qua reload, no observed POST replay. Discovery200 chỉ candidate → explicitconfirm → picker → logout exactUUID. Discovery401 giữ recovery, explicitnewlogin mới tạoUUID khác, session1 orphan được ghi tới ownedcleanup. Không giả định cookie đã lưu. Runtime/independent artifact review, original fixture exit0/eightzero và report/progress/runbook trước READY_FOR_QA. E2E006/cookieA-B/tab/browser reopen/App token loss vẫn cần case riêng.

### E2E007-WebDetail — membership B bị suspend sau picker, PLAN08/11

Checkpoint root actual08/11 đã đạt các assertion UI/detail/membership/cleanup, READY_FOR_QA. Independent artifact/runtime còn mở, resource/native case vẫn cần evidence riêng. [Report/evidence](../../test-reports/FEAT-TN-001-web-response-loss-r2-and-stale-2026-11-08.md).

Reuse cùng fixture owned của R2 sau explicitconfirm đã mở pickerA/B. Đây là fault mutation synthetic của harness, không UI quản lý membership. Source provider đã có expectation detail404 cho membership suspended; Web choose chuyển recovery. Không suy ca detail thay device/resource endpoint khác.

- [ ] Lưu pickerA/Admin và B/USER trước mutation. Snapshot và mutation chỉ đúng B/USER của full fixture account, bind UUID và khóa bằng run/email/activation provenance, role marker owned cùng run, workspaceB tạo bởi fixture owner index4. Requireexact1ACTIVE row, revision/authz tăng1 trong transaction, không đổi Admin hoặc grants. Dữ liệu hiện hữu ngoài fixture giữ nguyên; cuối lượt original ownedcleanup.
- [ ] Click B cũ sau mutation commit. Network detail404 đúngB và UI không công bố selectedB/protectedsummary. Recovery giữ đúng session, explicitreconcile/confirm tải list mới chỉA, chọnA/Admin→detail200 làm control. Không dùng chỉ404 hay screenshot làm toàn bộ proof.
- [ ] Logout ACK cùng WebUUID của R2, exactrevoke/seedunchanged, original fixture exit0/8zero. Report request identity/status, membership snapshots, UI trace và giới hạn. Root runtime đủ thì READY_FOR_QA, independent UI/native/resource case vẫn mở.

### E2E006-Web-Tabs — loginUnknown qua tab mới, PLAN08/11

Reuse controller R2 đã source/host review và root actual, không sửa source. Fixture mới và cùng Chrome profile lab, không đọc cookie/storage auth material. Tab1 login bị response fault, tab2 được mở sau khi UI tab1 đã recovery. Case này kiểm trạng thái bền qua tab mới và invalidation khi explicitconfirm/logout, không thay lateA/Bcookie hoặc browser-process reopen.

- [ ] Trướcsubmit tab1 lưu exact baseline session/audit synthetic, fault R2 ACK<15s/failedsameID/clear. DB sau fault+1WEB active. Tab1 recovery, chỉ explicitdiscovery mới candidate.
- [ ] Mở tab2 vào login, thu network bằng stream từ trước navigation để không mất buffer. Tab2 recovery khóa workspace, không tự accept hoặc loginPOST. Reload tab2 theo cùng streaming guard, không autoPOST. Chụp UI trace hai tab, không dùng screenshot thay request/session proof.
- [ ] Tab2 explicitdiscovery/confirm tới picker. Tab1 phải xóa candidate/authority và giữ recovery khi nhận storage intent. Tab2 logout204, tab1 phải còn protectedUIabsent, reloadtab1 về login khi marker đã clear. DB chỉ revoke WebUUID mới, seed/audit không đổi, originalfixtureexit0/8zero. ReportrootREADY_FOR_QA scoped, independentruntime cùng matrix rộng hơn vẫn mở.

### API24 actual integration — full/resume/access/password, PLAN08/11

AVD Nexa_Auth_API24/emulator5554 đã boot SDK24. Reuse các runner/target đã review, serialize từng lượt và không đổi source, budget hoặc oracle. Main đã dừng qua Settings/Appinfo/ForceStop, giữ data để runner tự kiểm packageabsent trước spawn. Browser hai tab hiện BLOCKED do Work settings; chưa tạo fixture Web mới.

- [x] ROOT_SCOPED_RUNTIME_PASS / READY_FOR_QA tại58323/923ccd. Full-session runner trên API24 phải đủ full login A/B, nativeprocess stop/newPID coldresume, noextraLoginPOST, logout exactsession/revoke và ownedproxy/fixture/8zero/terminalexit0.
- [x] ROOT_SCOPED_RUNTIME_PASS / READY_FOR_QA tại25218/059396. Access-cases riêng trên API24 phải disabled/genericdenial/empty/reload/logout, exactcounters/session/PID và cleanupterminal.
- [x] ROOT_SCOPED_RUNTIME_PASS / READY_FOR_QA tại48439/3414a8. Password-cases riêng trên API24 phải validation/success/oldreject/newlogin/coldprocess và exactoracles/cleanupterminal.
- [x] MAIN_RESTORED tại90773/3556fb, CUAconfigurationgate vàPID5482/API24. Restore lib/main.dart mặc định sau lượt cuối, ghi actual OS/commands/hash/evidence và updateprogress/runbook. Root PASS chỉ scope của lượt thực chạy, independent/minimumOS/accessibility/rate/device gates còn theo ma trận. Failure/startup hoặc cleanupunknown phải giữ FAIL/UNCONFIRMED, không tự tăng budget hoặc coi process quan sát hết hạn là terminal.

### MB-AUTH-002 — offline trên main API24, PLAN08/11

Checkpoint rootmanualUI/session đã đạt các quan sátnegative/reconnect/explicitretry/cleanup. Giữ checklist tổng mở vì exactHTTP/noqueuedPOST và independent còn thiếu. [Report/limits](../../test-reports/FEAT-TN-001-api24-offline-and-stale-2026-11-08.md).

Root kiểm main cấu hình HTTPS fixture thật và private-debug trust đã review. Native CUA điều khiển airplane mode của chính AVD, ghi baselineOFF và restoreOFF trong finally. Không mặc định airplane mode cắt routehost emulator; cần quan sát transport/UI/DB. Nếu route vẫn truy cập API thì fault injection không đạt, ghi INCONCLUSIVE cho offline và logout đúng session đã tạo, không gọi đó lỗi sản phẩm.

- [ ] Fresh fixture5accounts/2workspaces, root main thật với publiccert của lượt, baseline seed-only session map và airplaneOFF. Chuyển airplaneON trước validlogin. Khi transport lỗi, UI phải network/pending/recovery rõ và không render workspace, DB không thêm usable session của request không tới server. Không đọc filetoken/password để làm oracle.
- [ ] Restore airplaneOFF, quan sát finite window không auto login/queue. User bấm recovery khi cần rồi submit chủ động; đúng một session mới được tạo, picker A/B và logout/revoke. Nếu chỉ kiểm được negative transport, ghi scope partial và giữ reconnect/noqueue assertion mở.
- [ ] Dọn originalproxy/fixture tới terminal/cleanup, restoremain khôngorigin/cert sau lượt, ghi đúng OS/state/commands/session/UI evidence. Root chỉREADY_FOR_QA scoped, independent/device storage forensic và lifecycle race khác vẫn mở.

### MB-AUTH-010 — stale membership App API24, PLAN08/11

Checkpoint rootmanualUI/session đã denyB/reloadA/control/logout/cleanup, ROOT_PARTIAL_RUNTIME_VERIFIED/READY_FOR_QA. ExactAndroidHTTPstatus/counters/nativeindependent vàresourcecase vẫn mở. [Report/limits](../../test-reports/FEAT-TN-001-api24-offline-and-stale-2026-11-08.md).

Reuse fixture offline sau explicitonline login và pickerA/B, giữ sourceAPI/repository hiện có. Fault mutation USER membershipB theo cùng ownership/version guards của WebDetail đãreview. DirectSQLsynthetic là bước harness, chưa kiểm workflow admin UI.

- [ ] Chốt App pickerB/Member +A/Admin, snapshot membershipB ACTIVE, exactuser0/owner4/run/provenance/live-role và revision/authz. Suspend đúng1row, freshreadback trước clickB cũ.
- [ ] App không mở selectedB sau denial; hiển thị error/recovery dùng được, explicitreload/recover tải quyền mới chỉA, chọnA/Admin thành công. UI screenshots/DB scope riêng, chưa có exactAndroidHTTPcounter/status evidence thì chỉ ROOT_PARTIAL_RUNTIME_VERIFIED/READY_FOR_QA. Không dùng Web404 thay AndroidHTTP404actual.
- [ ] Logout sameAppUUID, seed giữ nguyên, restore airplaneOFF/main, originalproxy/fixtureterminalcleanup và8zero. E2E007resource/physical/independentnative/lifecycle-mid-bootstrap còn mở.

### C1 — Android API/session/main integration (PLAN tiếp nối M4b-P)

Current discovery2026-10-26: main vẫn Hello World; có ba DTO, secure store và
ba presentation components. Provider176assertions/cleanup0 đã có; native
storage normal/key-loss API24/36 có evidence, full restore/OEM/D2D/máy thật
còn mở. C1-T/S1/W1/W2/UI1-R đã kiểm scoped; UI2 main/host root13focused/128full
và analyzer/format PASS, independent design/review PASS (execution=root); C1-N chưa kiểm actual API. Không dùng
preview, unit transport hoặc provider làm App E2E.
User đã cho phép hoàn thiện feature và tester GPT-6.1/xhigh; các checkpoint
dưới là development integration, không tự ký CP-01/CP-02/CP-03/production SLO.

Đường đi cuối phải là mở main App→kiểm token an toàn→login thật→lưu ACK→
bootstrap server→limited đổi password hoặc full picker→recheck workspace→
session summary→logout/cold restart. Không dừng ở transport/parser unit.
Không thêm package. Networking theo proposal đã duyệt dùng dart:io/convert;
state ChangeNotifier, store adapter11.2.0, SDK hiện có.

| Slice/thứ tự | AC và files/checkpoint |
| --- | --- |
| C1-T — HTTP login/profile/logout |4files mới: `mobile/lib/features/auth/data/app_auth_failure.dart`, `app_auth_api.dart`, `mobile/test/contracts/app_auth_failure_test.dart`, `mobile/test/auth/app_auth_api_test.dart`. Interface AppAuthApi login/getProfile/logout; HttpAppAuthApi dùng origin-only HTTPS URI cố định/injected (host/authority hợp lệ, path rỗng hoặc `/`, không userInfo/query/fragment; paths `/api/v1/...` literal). Bearer kiểm nonempty/HTTP token68, không whitespace/control, trước openUrl và trước trả login DTO. Exact status/transport/no-store/JSON/body bound; DTO cũ parse success; error allowlist không giữ raw data. Total15s như Web UX, Stopwatch+fresh deadline sau await/trước firstwrite-close/trước trả DTO, không chỉ Future.timeout. Body128KiB/request64KiB, redirect off, proxy off, cookies/context/CSRF không nhận/gửi. Không TLS bypass/custom untrusted roots, log/replay hoặc storage side effects. Mỗi operation sở hữu client, timeout force-close và late connect không được gửi mutation. Test RED/GREEN về status/headers/byte bounds/timeout/lateresponse/one-call, late open không send, late body/parse/timer trễ không success; independent review trước tiếp C1-S. |
| C1-S — session admission/restore |Sau T, ≤5files cho immutable session state, repository và tests. Serialize store/network intents; generation fence/dispose. Chỉ admit sau write ACK + getProfile đúng identity, limited không gọi full bootstrap. Read/write/delete lỗi khóa UI; lost write ACK cleanup riêng token và revoke best effort đúng token trong RAM; không xóa kho khác hoặc báo server logout giả. Restore/resume kiểm server trước render; offline không thành empty/logged-out. Test races/late storage/lost ACK/account switch. |
| C1-W — full/limited API capabilities |Sau T, ≤5files mỗi slice để thêm workspace page/detail và password operation trên cùng API. Opaque cursor encoded, defaultACTIVE, no auto selection, server067 recheck; workspace detail immutable và versions đúng. Password204 chỉ logout/relogin, unknown giữ khóa/chủ động đối soát; không tự nâng full. Test shared contracts/negative transport. |
| C1-UI — coordinator/main thật |Sau S/W, ≤5files mỗi slice cho coordinator + composition + focused tests, rồi main thay scaffold. Reuse Login/Password/Workspace components và Nexa tokens. Rate limit/cooldown từ Retry-After, không giữ password/retry. Lifecycle lock trên resume và recheck; full/limited/empty/error/offline/pending/storage/permission/stale có navigation rõ. Layout/state matrix bên dưới; widget tests rồi native API24/36 actual API run. |
| C1-N — endpoint/native E2E |Endpoint HTTPS của App chưa có trong metadata; đã hỏi base URL không secret. Lab hiện HTTP loopback, ngoại lệ Web không tự áp cho App. Không đổi manifest cleartext hoặc bỏ TLS để vượt gate. Có URL/topology được xác nhận mới nối real device/AVD vào API; sở hữu đúng child/fixture/tunnel, cleanup sau test. API24/36 cold boot/login/limited/picker/logout/offline/429, cả Web/App session độc lập và các race theo18.7. Browser thật vẫn cần connection riêng. |

Checkpoint C1-T2026-10-26: **SCOPED_RETEST_PASS / READY_FOR_QA** cho4files
source/test; behavior RED21tests(3PASS/18FAIL)→GREEN21PASS, full58PASS,
analyzerNoissues và formatter35files0changed. Hai tester GPT-6.1/xhigh đã
review/test độc lập, không còn material finding trong slice. [Handoff/root](../../test-reports/FEAT-TN-001-android-transport-2026-10-26.md),
[test/retest độc lập](../../test-reports/FEAT-TN-001-android-transport-test-design-2026-10-26.md),
[Security/Architecture](../../test-reports/FEAT-TN-001-android-transport-code-independent-2026-10-26.md).
Không có API/native/browser runtime mới, không nhận main Hello World là auth.

- [x] C1-T source/test và independent scoped review/retest.
- [x] C1-S1 source/test admission/restore/quarantine và independent scoped checks — READY_FOR_QA; native/UI chưa chạy.
- [x] C1-W1/W2 source và scoped independent checks — READY_FOR_QA; W1 focused15 và W2nine+UI1seven/full114 PASS tại checkpoint trước UI2.
- [ ] C1-UI coordinator/main/lifecycle và widget tests.
- [ ] C1-N HTTPS topology/native actual API và Web browser E2E.

#### Layout/navigation/state matrix C1

Reuse UI mục17.1 và `docs/UI web/design-system.md`, `home (2).html`:
navy/teal/amber/coral theo vai trò, error surface nhẹ và ink text đã sửa, không
thêm landing page. Bootstrap màn trung tâm progress + nhãn; login form hiện
có; limited password screen; full picker list/empty/pagination; selected session
summary chỉ thông tin workspace đã recheck, không giả dashboard/device data.
App bar có quay lại picker/logout, không dùng role client cấp quyền. Text≥16,
touch≥48dp, keyboard/focus/semantics và200% text/small landscape giữ usable.

| State | UI/action và admission |
| --- | --- |
| boot/loading/submitting |Progress có semantics, khóa intent trùng; không render protected cache. |
| ready/rejected |Form login; copy cố định, focus trường lỗi, không hiện length hint thường trực. |
| rateLimited |Nhãn thời gian chờ, khóa submit tới hết; không auto submit hoặc giữ password. |
| full/limited |Full load profile/picker sau store ACK; limited chỉ password/logout, không list workspace. |
| empty |Chỉ khi list confirmed rỗng/hết trang; create065 chưa có thì CTA không giả đã triển khai. |
| offline/error |Giữ UI đóng theo quyền đã kiểm; retry chủ động đúng operation, không replay mutation. |
| permission/stale/conflict |Xóa selection/cache đã lỗi, tải lại/recheck server trước route. |
| pending/unknown |Không replay POST; kiểm phiên bằng token đã biết hoặc bỏ intent rõ ràng rồi submit mới. Mất login token không nhận phiên khác. |
| storageFailure |Khóa protected UI, cleanup riêng auth key/revoke đúng token; không plaintext fallback. |
| success/logout |Session summary đúng identity/workspace; logout chờ server hoặc pending, local cleanup có ACK, không tự nhận account khác. |

Checkpoint từng slice: reviewed PLAN trước source edits, RED/GREEN meaningful
negative tests, full Flutter suite/analyzer/formatter sau change, independent
tester report trong docs/test-reports, source SHA/dirty files/actual commands.
Không downgrade gate hoặc ghi acceptance bằng screenshot. Rollback theo từng
slice; main chỉ chuyển khi composition đầy đủ, legacy previews giữ nhãn mock.
Rủi ro chính: timeout không hủy Future gốc, storage completion tới muộn, 503
không chứng minh rollback, cookie hoặc redirect làm sai channel, endpoint TLS
chưa xác nhận. Tests phải chứng minh fail closed và không side effect muộn.
T source không phụ thuộc endpoint thật để phát triển/test với injected client;
native/API evidence chờ C1-N. Full release backup/physical/owner review còn mở.

C1-S admission clarification: getProfile200 matching identity áp dụng cho full
login. Login DTO limited không gọi full `/me`/list trước password flow; restore
token không rõ scope có thể probe `/me`,403PASSWORD_CHANGE_REQUIRED được xử lý
như limited signal, không parse thành full profile hoặc suy userId. Không dùng
discovery đó tự nhận identity của login intent khác. Profile API T trả typed
failure cho403 để repository sau phân biệt giới hạn này.

#### C1-S1 — session repository nối API và secure store (PLAN trước BUILD)

Dependency C1-T source/review21focused và58full Flutter PASS, analyzerNoissues;
storage adapter/PoC đã có. Scope3files mới: `features/auth/data/app_session_state.dart`,
`features/auth/data/app_session_repository.dart`,
`test/auth/app_session_repository_test.dart` (trong mobile/lib hoặc mobile/test
tương ứng). Không main/UI/API method mới. Composition sau chỉ tạo một repository
cho một store, giữ ownership suốt app lifetime; không tái tạo repo khi đổi account.

1. Immutable state chỉ phase/profile/failure/generation, không bearer/password;
   repository giữ token private và publish qua broadcast stream. State gồm
   signedOut/checking/submitting/full/limited/loggingOut/pending/storageFailure/
   offline. Mỗi intent lấy generation, khóa busy trước publish; duplicate intent
   không queue password hoặc gọi API thêm. Dispose/suspend làm stale completion
   không publish/admit; không giả hủy I/O native.
2. Login chỉ từ signedOut, clear auth key và await ACK trước intent mới. Gọi
   API đúng một lần; kiểm DTO email khớp input theo trim/lowercase ASCII của
   provider, expiry và token cùng intent; write token await ACK. Full bootstrap
   getProfile phải khớp id/email từ DTO rồi mới publish full; limited không
   gọi full profile/list. Failure sau token issuance khóa UI, cleanup riêng auth
   key và best-effort revoke chính token mới trong RAM, không revoke token khác.
   Write mất ACK có thể đã lưu: delete cần ACK; cleanup lỗi giữ quarantine.
   Quarantine là latch trong repository suốt lifetime: restore/recover không
   được admit full/limited kể cả đọc ra token và server trả200/403. Token đó
   chỉ được dùng revoke; chỉ cleanup own auth key có delete ACK mới gỡ latch
   để signedOut/login mới. Không tái tạo repository để bypass latch.
3. Restore khóa cache/UI trước read. Null thật→signedOut; read error→storageFailure;
   có bearer→server getProfile,200→full,403PASSWORD_CHANGE_REQUIRED→limited không
   profile,401SESSION_EXPIRED/REVOKED→delete ACK/signedOut. Mạng lỗi→offline khóa,
   protocol/unknown→pending khóa; không lấy cache làm quyền. Suspend khóa ngay
   và tăng generation; resume restore phải đợi intent cũ/cleanup kết thúc, không
   chen storage write mới qua completion cũ. Phân biệt suspend khi token đã
   admit (giữ private token để resume recheck server) với suspend giữa login:
   token mới về muộn hoặc write đang chạy phải chờ hoàn tất, cleanup own key
   và revoke chính token đó; không chỉ bỏ publish rồi thả busy. Recheck
   expiresAt của login DTO ngay trước publish full/limited, kể cả limited write
   ACK trễ. Restore dùng kết quả server `/me`, không tự bịa expiry không có.
   Resume lặp cùng chu kỳ phải chờ cùng Future/ACK. Nếu suspend lần nữa trong
   lúc resume `/me` đang pending rồi nhận resume mới, drain intent cũ trước
   rồi chạy restore cho generation được resume mới nhất. Chỉ suspend không
   kèm resume mới vẫn giữ khóa, không tự mở app trong background.
4. Logout chỉ private token hiện tại; full/limited data đóng ngay khi bắt đầu.
  204 rồi delete ACK mới signedOut. Failure/unknown giữ pending, không replay.
   Recover là action chủ động: restore/recheck token đã biết hoặc cleanup riêng
   intent chưa nhận token; không gọi lại login/password. Quarantine từ mục2
   luôn ưu tiên hơn restore/recheck, recover chỉ cleanup cho tới delete ACK.
   App mất login token
   không tự nhận bearer/profile của account cũ. Known-token logout retry chỉ
   theo action người dùng và luôn chính token cũ, không auto đổi sang session mới.
   Pending logout giữ latch riêng qua lifecycle: resume có thể probe server,
   nhưng200/403 vẫn pending và không render protected data.401 rồi delete ACK
   mới signedOut. Chỉ recover/retry chủ động mới quyết định tiếp tục phiên còn
   sống hoặc gửi lại logout đúng token, không auto replay logout khi resume.
   Public restore mặc định cũng giữ pending logout; chỉ recover chủ động mới
   có thể chọn dùng lại phiên sau server recheck. Nếu read storage lỗi trong
   pending logout, cleanup local không được bỏ private token hoặc dùng delete
   ACK thay server204/401. Giữ khóa và cho retry logout chủ động đúng token kể
   cả quarantine; chỉ có server resolution rồi delete ACK mới signedOut.
5. Tests RED→GREEN với fake API/store/Completers: storage ACK trước full,
   limited skip profile, restore expiry/offline/limited, write side-effect rồi
   throw, delete failure, mismatched identity/email/expired DTO, overlapping
   login/logout/restore, suspend/dispose và late network/storage. Verify call
   order/count/không publish token/không late admission; thêm oracle write
   side-effect→throw→delete fail→restore200/403 vẫn khóa, rồi delete ACK mới
   signedOut; suspend token đã admit→resume recheck, suspend giữa login→late
   token/write→cleanup/revoke cùng token trước intent mới, limited expiry
   trong lúc chờ write ACK không được admit. Không chờ store bằng
   Future.timeout rồi thả busy cho write muộn chen vào intent mới. Full suite,
   analyzer/format và independent review trước composition S2/W/UI.
   Stored bearer phải hợp token68 trước gán private token hoặc gọi profile;
   dữ liệu hỏng thành storageFailure/quarantine để recover cleanup own key,
   không rơi vào vòng protocol→recheck mãi mà không có action xóa an toàn.

Checkpoint C1-S1 cuối2026-10-26: **SCOPED_RETEST_PASS / READY_FOR_QA** tại
repository boundary,3files mới/untracked, dev@ba425ad dirty/chưa commit. Root
RED5FAIL→core5PASS; negative13PASS/3FAIL→16PASS; lifecycle16PASS/2FAIL→18PASS;
recovery18PASS/3FAIL→21PASS. Final independent21focused/79full Flutter PASS,
analyzerNoissues3.9s, format38files0changed; Security/Architecture review cuối
đóng material findings. [Handoff/files/Tester](../../test-reports/FEAT-TN-001-android-session-2026-10-26.md),
[independent tests](../../test-reports/FEAT-TN-001-android-session-test-independent-2026-10-26.md),
[source review](../../test-reports/FEAT-TN-001-android-session-code-independent-2026-10-26.md).
Những AC lifecycle/recovery bổ sung ở trên xuất phát từ finding đã tái hiện,
không đổi ownership một repository/store hoặc thêm dependency. Main vẫn
Hello World, C1-W/UI/N và App/browser actual API E2E chưa nghiệm thu. Source
S1 không phụ thuộc browser connection để hoàn thành scoped checks.

Rollback riêng3files. Lỗi native storage thật, app cold boot/lifecycle, TLS và
main UI vẫn cần runtime C1-N; fake tests không thay bằng chứng đó. Không đánh
storage transaction atomic/ACK chắc chắn nếu adapter chỉ trả unknown. Nếu
state/ownership cần boundary khác, review checkpoint trước mở scope, không
thêm global lock/mutex hoặc queued password để che race.

#### C1-W1 — workspace/password transport cho session thật (PLAN trước BUILD)

Dependency: C1-T/S1 source và independent21/79 đã scopedPASS; DTO workspace
page/provider routes/contract0.2.1 hiện có. Mục tiêu là cung cấp capability API
thật để repository/coordinator nối picker/recheck/password, không kết thúc C1
ở parser. Không đổi wire contract/backend/DB/dependency hoặc main trong slice.

Scope5files: sửa `mobile/lib/features/auth/data/app_auth_api.dart`,
`app_auth_failure.dart`; thêm `mobile/lib/features/workspaces/data/workspace_access_detail.dart`,
`mobile/test/auth/app_capability_api_test.dart`,
`mobile/test/contracts/workspace_access_detail_test.dart`.

PLAN status2026-10-26: **REVIEWED_READY_FOR_BUILD** sau khóa UUID case,
URI encoding/deadline và timestamp compatibility subset. [Independent review](../../test-reports/FEAT-TN-001-android-capability-plan-independent-2026-10-26.md).
Đã lưu baseline2transport files không secret để rollback/review tại
`docs/test-reports/evidence/auth-android-capability-before-source-2026-10-26.json`;
W1 đã implementation: core RED2PASS/8FAIL→10PASS; root negative15focused và
94full Flutter PASS, analyzerNoissues3.9s, format41files0changed. Source review
độc lập Safe to merge; independent runtime retest chưa chạy do test agent quota.
**READY_FOR_QA**, không native/main/E2E acceptance. [Handoff/files/Tester](../../test-reports/FEAT-TN-001-android-capability-2026-10-26.md).
URI encoding theo [Uri.replace](https://api.dart.dev/dart-core/Uri/replace.html)
và [queryParameters](https://api.dart.dev/dart-core/Uri/queryParameters.html),
không nối raw cursor thành URL. Dart docs3.13.7; compile/tests SDK3.13.4 là gate.

1. Giữ AppAuthApi hiện tại để không ép session/login fakes triển khai capability
   không dùng. Thêm AppWorkspaceApi và AppPasswordApi trong cùng API module;
   HttpAppAuthApi implement cả3, dùng chung client/deadline/codec guards hiện có.
   Interfaces: listWorkspaces(token,{String? cursor})→AvailableWorkspacePage;
   getWorkspace(token,workspaceId)→WorkspaceAccessDetail;
   changePassword(token,currentPassword,newPassword)→Future<void>.
   List GET `/api/v1/workspaces` mặc định ACTIVE, không gửi historical/status
   override; cursor opaque được encode bằng Uri queryParameters, kể cả empty
   string không tự thành null. Detail GET literal prefix và UUID path đã kiểm
   trước factory, không gửi X-Workspace-Id override. Password POST literal
   `/api/v1/auth/password`, JSON chỉ currentPassword/newPassword nguyên chuỗi;
  204 phải no-store/zero bytes/no Web credential metadata như logout.
2. WorkspaceAccessDetail kiểm đủ required keys/types/enums/UUID/version dương
   và timestamp có timezone parse UTC nghiêm cho createdAt/archivedAt nullable; không tự
   normalize name/timezone/id hoặc giữ raw map. Snapshot immutable đủ workspace
   revision/authzVersion và membershipRevision/membershipAuthzVersion riêng,
   không hoán đổi hai version. Cho phép enums inactive theo schema; getter
   isOperational chỉ true khi workspace và membership ACTIVE, chưa là server
   authorization. Adapter detail đối chiếu response id với UUID đã request
   không phân biệt hex case, giữ nguyên string trong DTO; không exact-string
   reject UUID hợp lệ khi provider canonicalize lowercase.
   Missing nullable key khác null; ignored compatible extensions không cấp quyền.
   Timestamp theo subset hiện hành của AppLogin: calendar hợp lệ, timezone
   bắt buộc, giây00–59; leap second60 của RFC3339 không được hỗ trợ và phải
   reject thay vì DateTime normalize sang phút sau. Đây là limitation client,
   không tuyên bố parser bao phủ toàn bộ RFC3339 hoặc thay đổi schema chung.
3. Method-specific error allowlist theo OpenAPI: list400 CURSOR_INVALID hoặc
   VALIDATION_ERROR,401session,403PASSWORD_CHANGE_REQUIRED/FORBIDDEN,
  409context,422validation,503; detail400validation/401session/403password hoặc
   forbidden/409context/404RESOURCE_NOT_FOUND/503; password401AUTH_INVALID
   khác SESSION_*,403CSRF_INVALID,400/413/415/422validation,409context,
  429Retry-After,503. Thêm sanitized failure kinds cursorInvalid/resourceNotFound
   cho hai code mới; không nhận chúng ở login/profile/logout cũ. Password
  401 sai currentPassword không xóa session tại transport;503/network sau send
   hoặc malformed ACK giữ unknown, không auto POST lại hoặc tự nâng limited.
   Password transport không tự validate policy/composition/length, chỉ cap
   wire và bearer; giữ nguyên cả legacy currentPassword ngắn để backend quyết.
   Uri cuối được cap64KiB UTF-8 bytes trước factory như request body để query
   opaque lớn không tạo request không giới hạn; timeout15s/response128KiB,
   direct/defaultTLS/redirectoff/no cookies/context/CSRF/storage/retry giữ nguyên.
   Stopwatch phải bắt đầu trước cả URI build/encode/cap và serialization body,
   không build cursor URI ngoài request budget rồi mới đếm15s.

Verification trước checkpoint: tester độc lập author meaningful RED rồi root
implementation GREEN; consumer dùng fixtures workspace-scenarios khi áp dụng,
negative required/null/types/enums/timestamps/UUID/version identity, shared
failure mapper mới, operation-specific allowlist giữ3operations cũ. Network
tests kiểm exact URL/query/bearer/body/method, password raw9/legacycurrent,
GET không body,204 không body, no-store/forbiddenWebmetadata, cap/deadline/late
send/no-replay kế thừa được kiểm ở operation mới. Test file mới được reuse các
Recording HTTP fake public trong app_auth_api_test.dart chỉ như test helpers,
không gọi main của test đó hoặc coi fake socket là native. Full Flutter suite,
analyzer/format và independent review/SHA trước bước W2.

Rollback5files theo scope, giữ T/S1 contracts/tests cũ. Rủi ro: mở rộng enum làm
accept sai error của endpoint khác; dynamic URI/query lách origin hoặc mutate
cursor; DTO lịch tự normalize;204 của password bị parse JSON; GET không được
gán unknown như POST. Không đổi policy password9–128/new hoa-thường-số.

Bước W2 sau W1: repository giữ private bearer để gọi workspace/password dưới
cùng busy/generation/lifecycle, chỉ full mới list/select và server recheck;
limited chỉ password/logout. Password204 hoặc401SESSION_EXPIRED/REVOKED rồi
delete ACK→relogin;401AUTH_INVALID cho currentPassword sai giữ phiên/form để
user sửa input. Unknown không replay và không tự promote. Phải có PLAN ≤5files được review
trước BUILD, rồi C1-UI/main và native HTTPS E2E; W1 chưa là user flow hoàn tất.

#### C1-W2 — session capabilities nối picker và password (PLAN trước BUILD)

Checkpoint2026-10-26: root9focused/103full Flutter PASS, analyzerNoissues4.7s,
format42files0changed. Independent PLAN/source review GPT-6.1/xhigh kết luận
Safe to merge, SHA ba file khớp. **READY_FOR_QA**, independent runtime retest
PENDING do quota; chưa main/native/browser E2E. [Handoff](../../test-reports/FEAT-TN-001-android-session-capability-2026-10-26.md).

Dependency W1 source root15focused/94full/analyzer/format PASS và source review
độc lập Safe to merge; W1 runtime retest độc lập còn READY_FOR_QA do tester quota.
S1 giữ ownership một repo/store. Scope3files: sửa `app_session_state.dart`,
`app_session_repository.dart`, thêm `mobile/test/auth/app_session_capability_test.dart`.
Không main/UI/transport/store adapter/DB/dependency trong slice này.

1. Constructor nhận optional AppWorkspaceApi/AppPasswordApi riêng, composition
   thật sau truyền cùng HttpAppAuthApi; base auth tests không bị ép implements
   capability. Thiếu dependency trả locked typed protocol khi gọi capability,
   không mock success. State thêm immutable list workspaces, nextWorkspaceCursor,
   workspacesLoaded và selectedWorkspace; chỉ full mới có, không bearer/cursor
   persist. Không serialize DTO ngược về JSON chỉ để merge list. API methods loadWorkspaces({bool
   loadMore=false}), selectWorkspace(String id), changePassword(current,new).
   Chỉ full mới list/select, full/limited mới password; busy/suspend/dispose/
   quarantine/unknown không khởi intent mới. Mỗi call dùng _start ownership và
   capture đúng private token, phase/profile trước khi đóng protected data.
   Không callback cho UI cầm bearer và không repo thứ hai bypass latch.
2. List mặc định trang đầu clear selection, gọi server rồi publish full/page
   chỉ khi generation hiện hành. loadMore chỉ khi page cũ có cursor, giữ cursor
   opaque, merge immutable theo UUID case-insensitive, duplicate/cursorloop hoặc
   accumulated>1000items/100pages→locked protocol thay endless loading. Empty
   chỉ list tích lũy confirmed không items và không cursor: trang1 cóA/cursorX,
   trang2[]/null vẫn giữA, không thành empty. Refresh manual reset ledger.
   Test exact1000/+1items và100/+1pages, cursorloop kể cả empty string.
   Chọn id chỉ từ page hiện hành và UUID, mỗi chọn gọi detail server, kiểm
   identity/operational trước publish selected; không auto chọn workspace.403/
   404/409/cursorInvalid xóa selection/page và trả full với failure cho reload
   chủ động; offline/protocol fail closed, không dùng stale page làm empty.
   Session401→deleteACK/signedOut; PASSWORD_CHANGE_REQUIRED→limited/no page;
   network/unavailable/protocol→offline/pending locked và recover server trước
   tải lại. Suspend/dispose xóa page/selection và late result không publish.
3. Password chỉ một POST nguyên input, không persist/queue/replay; khóa ngay
   UI/profile/page.204 hoặc401SESSION_* là server resolution, clear own key
   có ACK mới signedOut/relogin.401AUTH_INVALID/validation/429/permission denial
   hợp lệ giữ phase full/limited cùng safe failure, không promote hoặc xóa
   session; pre-send network không unknown cho retry manual. OutcomeUnknown
   hoặc raw unexpected exception giữ private passwordPending latch xuyên
   restore/recover/resume: server200/403 vẫn pending không mở form/quyền;
   server401 hoặc logout chủ động đúng token rồi204/401+deleteACK mới kết thúc.
   Không dùng GET200 làm proof POST trước đó chắc chắn không commit. Native
   read lỗi/mấtkey không bỏ token cần đối soát. Cho manual logout qua quarantine
   khi known pending token; raw errors không giữ detail/secret. Latch process-
   lifetime, không cam kết persisted unknown intent qua process death.
   Response password đến sau suspend/dispose vẫn xử lý effect trước stale
   publish guard:204/401 phải deleteACK/drain; unknown/raw giữ latch/token đúng
   intent trước resume restore. Wrongcurrent/429 chỉ kết thúc intent, không
   publish captured full/limited của generation cũ. Không giả cancel POST.

Tests meaningful RED trước implementation: limited không list/select; đúng
token/full page/cursor+merge/empty/noauto selection; duplicate/cursorloop/cap,
detail inactive/403/404/409 khôngselected; late list/detail qua suspend/dispose
không stalepublish; password204/401deleteACK order, wrongcurrent/429 giữscope,
unknown→restore/resume200/403 vẫn khóa rồi manual logout đúng token/401cleanup;
rawfailure/storeerror preservepending; duplicatebusy không thêm POST/giữinput.
Root tự chạy TDD khi test subagent unavailable, không nhận là độc lập. Full
suite/analyzer/format, independent source review nếu còn khả dụng, runtime
retest QA giữ mở rõ ràng. Rollback3files; không hạ S1 ACK/quarantine/lifecycle
guards hoặc đổi password policy/backend error semantics. Giới hạn1000items/
100pages là UI memory budget, không quota workspace server; fail explicit,
không giả đã hết danh sách. Sau W2 phải nối coordinator/main/UI và native/API
E2E, không dùng DTO/repository tests thay user flow cuối.

#### C1-UI — coordinator rồi App composition

Giữ dependency C1-S/W và layout/state matrix trên. [UI1 concrete PLAN](../../test-reports/FEAT-TN-001-android-coordinator-plan-2026-10-26.md)
được [GPT-6.1/xhigh review](../../test-reports/FEAT-TN-001-android-coordinator-plan-independent-2026-10-26.md)
REVIEWED_READY_FOR_BUILD trước source; root7behaviorRED→7GREEN, independent
runtime/review đang chạy và sẽ ghi findings/retest, chưa nhận UI1 nghiệm thu.
Scope coordinator+tests, không token/password trong state, epoch/page/busy
admission, cooldown từ Retry-After và latest resume giữa bootstrap cũ.

Cập nhật2026-10-28: UI1 recovery finding full/limited đã độc lập RED2→fix→
11focused/114full/analyzer/format PASS. UI1-R canLogout dùng đúng guard repo,
root12focused/115full/analyzer/format PASS và source-only review. [Handoff UI1](../../test-reports/FEAT-TN-001-android-coordinator-2026-10-26.md).
UI2 main/host/API composition root13focused/128full/analyzer/format PASS sau
fixture lifetime fix: tạo và quan sát close trong cùng real zone, vẫn chờ ACK.
Production repository/coordinator restored đúng SHA UI1-R; không auth logic
workaround. Independent QA5cases đã kiểm unknown-password, stale callbacks,
framework back,429 và cleanup failure; root thực thi13focused/128full PASS. [UI2 files/logs/Tester](../../test-reports/FEAT-TN-001-android-application-2026-10-28.md).
User đã cho phép SDK ngoài sandbox; execution policy vẫn từ chối. Bundled Dart/
Flutter tool snapshot đã chạy trong sandbox với quyền đích danh, không đổi
Git trust/SDK/OS hoặc đi vòng tool. Default wrapper còn Git ownership error.
[UI2 concrete PLAN](../../test-reports/FEAT-TN-001-android-application-plan-2026-10-26.md)
nối main+host/widgets sau checkpoint UI1; cần PLAN review trước BUILD, không
đợi endpoint để hoàn thiện source. UI2 layout/navigation/state matrix đã khóa
business screens/safe scroll/200% text, countdown không autoPOST, recovery
riêng và native-back/summary/logout. C1-N actual HTTPS/native/browser vẫn mở.

- [x] UI1 source/retest và source review độc lập — independent114PASS trước getterR; R root115PASS/source review scoped, không E2E.
- [ ] UI2 composition/main/widget interactions, dark/light/responsive — ROOT_SCOPED_PASS/READY_FOR_QA; independent design/review PASS, root execution; [handoff/evidence/runbook](../../test-reports/FEAT-TN-001-android-application-2026-10-28.md).
- [ ] C1-N actual API/native/browser, không dùng fake tests thay E2E.

Official API refs (Dart docs hiện3.13.7, SDK local3.13.4; compile/tests local là
gate tương thích): [HttpClient](https://api.dart.dev/dart-io/HttpClient-class.html),
[redirect](https://api.dart.dev/dart-io/HttpClientRequest/followRedirects.html),
[Future.timeout](https://api.dart.dev/dart-async/Future/timeout.html). Docs khuyến
nghị package:http; project đã duyệt dart:io và cấm thêm dependency không duyệt,
nên giữ boundary injectable. Proxy mặc định có thể đọc environment: set
findProxy=null rõ ràng, không inspect env. Future.timeout chỉ ngừng chờ:
client phải được force-close, late continuation phải bị fence trước send.

### Login error palette — yêu cầu sửa màu2026-10-26

PLAN đã rà theo screenshot và token trang chủ; user cho phép tự chọn chi tiết.
Slice3source files: `web/src/features/auth/auth.css`,
`mobile/lib/ui/nexa_auth_theme.dart`, `mobile/lib/features/auth/presentation/login_screen.dart`.
Thứ tự: auth-local palette → icon/text/border App → build/widget/analyzer và đo
contrast sáng/tối → cập nhật evidence/progress. Không có dependency mới.
AC: nền lỗi pha8% coral vào surface, accent75% coral/25% ink, text dùng ink;
text≥4.5:1, icon/focus≥3:1 trong cả2theme. Giữ liên kết lỗi/focus/live region,
lỗi tại field và validation; không khôi phục hint login thường trực. Không đổi
layout/navigation/state matrix hiện hành: lỗi vẫn là banner trong form, không
chặn nhập lại; loading/empty/offline/pending/conflict/success giữ nhánh hiện có.
Checkpoint source READY_FOR_QA chỉ sau kiểm tra; browser visual/keyboard vẫn
phải xác minh runtime. Rủi ro browser connector chưa có; phép đo source không
thay browser E2E. Rollback riêng palette và cách tô icon, không đổi auth logic.

Kết quả **READY_FOR_QA**: Web build42modules,18Flutter widgets/analyzer/format
PASS; native login API36 ngang200% PASS, restore verified. Text contrast nguồn
sáng/tối14.73/13.16, icon5.04/5.29. Browser CUA vẫn không có surface, visual QA
NOT_RUN. [Handoff/Tester/evidence](../../test-reports/FEAT-TN-001-login-error-palette-2026-10-26.md).

### Provider continuation — phê duyệt cụ thể2026-10-26

### CP-02-MEASURE — chi phí nội bộ (PLAN trước BUILD)

M4b-P **READY_FOR_QA / SCOPED_RETEST_PASS**: actual HTTP WEB/ANDROID khi giữ8
leases đúng pool, hai503/no credential/PoolAcquireError≈5s/gen1→2/no-loss;
committed session/audit/counter không đổi, recovery cùng pool rồi graceful
STOP/reap.176assertionchecks (163distinct IDs;15P IDs mới unique), SELECT
cleanup role/HBA/fixture0.96Rust/88host/16focused độc lập/fmt/Clippy PASS;
tester GPT-6.1/xhigh phát hiện lateREADY và test mutation hole, đã fix/retest.
Không tự ký owner budget/CP-02/SLO/C1/browser/whole-feature acceptance.
[P report/files/Tester/evidence](../../test-reports/FEAT-TN-001-pool-budget-2026-10-26.md).
Các câu pool còn thiếu trong snapshot M1–Q bên dưới là lịch sử, đã được P này
bổ sung; không lấy chúng làm blocker pool hiện hành.

M4b-Q **READY_FOR_QA / SCOPED_RETEST_PASS tại hasher unit boundary**:
chỉ2verify regression tests, runtime/TestObserver/testcũ normalizedsource
khớp baseline.90isolated Rusttests/6focused độc lập GPT-6.1/xhigh, fmt/Clippy/
2mutation PASS. Verify timeout thật≥5s trong8s; abortcaller không nhả worker
permit/window, explicitrelease rồi3uniqueCompleted/no-loss. Không DB/provider
mới hoặc HTTP overload claim; pool/CP-02/C1/browser/SLO còn mở.
[Report/files/Tester/evidence](../../test-reports/FEAT-TN-001-queue-budget-2026-10-26.md).

M4b-L **READY_FOR_QA / SCOPED_RETEST_PASS**:72host/8focused độc lập
GPT-6.1/xhigh/3mutation và161provider checks PASS. WEB/ANDROID giữ User lock
qua response503, AccountAcquire Error5005063/5005753µs, exact5stage/window,
committed state unchanged và recovery+1session/audit; cleanup role/HBA/fixture0.
Chưa pool/queue fault, production SLO/browser/C1/whole-feature acceptance.
[Report/files/Tester/evidence](../../test-reports/FEAT-TN-001-lock-budget-2026-10-26.md).

M4a **READY_FOR_QA / SCOPED_RETEST_PASS**:64host tests,7focused độc lập
GPT-6.1/xhigh,3mutation và145provider checks PASS. Baseline60successful logins
cho20unique windows/540Completed/36groups×15, percentile audit riêng khớp;
cleanup role/HBA/fixture0. Hai Important cancellation/coverage-test-hole đã
sửa/retest. Chưa M4b budget faults, production SLO, browser hoặc C1 E2E.
[M4a report/files/Tester/evidence](../../test-reports/FEAT-TN-001-measure-m4a-2026-10-26.md).

M3 **READY_FOR_QA / SCOPED_RETEST_PASS**: hai tester GPT-6.1/xhigh độc lập,
7Rust/12Python focused tests PASS; strict-hex Nit và Important về độ mạnh
regression phân bố stage đã sửa/retest. Root88Rust/57host tests, fmt/Clippy,
3mutation và135provider checks PASS. Hai process mỗi bên đúng9Completed,
valid/drop/stale/poison đúng; cleanup role/HBA/fixture0. Chưa repeated
baseline/pool-lock budgets M4 hoặc nghiệm thu CP-02/Web/App tổng.
[M3 report/files/Tester/evidence](../../test-reports/FEAT-TN-001-measure-m3-2026-10-26.md).

Các checkpoint M1/M2 dưới đây ghi evidence tại thời điểm từng slice; phần
"chưa enabled samples" được cập nhật bởi checkpoint M3 phía trên.

M1 **READY_FOR_QA / SCOPED_RETEST_PASS**:79Rust tests,12lib tests độc lập
GPT-6.1/xhigh, fmt/Clippy/mutation và132provider regressions PASS. Cleanup
role/HBA/đúng5fixture graph0. Default sink vẫn None; chưa có provider stage
samples/p50/p95. M2–M4 và CP-02 tổng vẫn mở.
[M1 handoff/files/Tester/evidence](../../test-reports/FEAT-TN-001-measure-m1-2026-10-26.md).

M2 **READY_FOR_QA / SCOPED_RETEST_PASS**:81Rust tests trong isolated runner,
3libtests GPT-6.1/xhigh độc lập, fmt/Clippy/2mutation và132provider regression
PASS; cleanup role/HBA/fixture0. Hai finding test coverage/isolation đã sửa
và retest. Chưa có enabled provider samples, không đánh M2 acceptance/CP-02
DONE. [M2 report/files/Tester/evidence](../../test-reports/FEAT-TN-001-measure-m2-2026-10-26.md).

Tiếp nối132provider checks; không dùng HTTP wall time hoặc timeout cấu hình
làm số đo nội bộ. Không thêm crate/package/schema/grant/fixture, không nới
timeout hoặc bỏ User/bucket fence để đạt số đẹp. Câu hỏi cần trả lời: thời gian
đợi slot/worker so với hash work; pool acquire so với BEGIN; thời gian lấy
bucket/User fence và phần công việc sau fence tới COMMIT ACK; khi hết budget
có fail closed và giữ đúng permit/transaction hay không.

| Task / thứ tự | AC và verification | Files tối đa5 / checkpoint |
| --- | --- | --- |
| M1 diagnostic port + hasher | Port chỉ enum stage/outcome/Duration/window generation, không identity/credential/SQL; recorder root bounded4096samples/window, không I/O trong record, dropped/poison/old-window phải hiện rõ. Default disabled, cancellation khác error/completed; đo riêng semaphore queue, spawn_blocking queue và work trong closure, permit vẫn sống tới closure xong. Unit RED/GREEN, cancellation/window isolation/overflow, Rust tests/fmt/clippy. | application `auth_diagnostics.rs`, application `lib.rs`, root adapters `auth_diagnostics.rs`, `mod.rs`, `security.rs`; review source READY_FOR_QA, chưa provider measurement. |
| M2 PostgreSQL stage boundaries | Store nhận optional sink; pool.acquire timed riêng rồi owned Transaction::begin(connection,None) theo đúng SQLx0.8.6 pinned; giữ error/rollback semantics. Bucket acquire bao gồm upsert+FOR UPDATE/round trips; User acquire đo quanh SELECT FOR UPDATE; fenced_work từ sau bucket lock trả về tới COMMIT ACK. Drop/rollback queue chỉ Abandoned, không gọi nó là server lock đã nhả. Không đổi SQL policy hoặc transaction ownership. Build/tests và provider132regressions. | postgres `lib.rs`, `identity.rs`, `device.rs`, `audit_retention.rs`, `template.rs` (các initializer ngoài auth dùng None); M1. Cận dùng constructor doc(hidden) phải có source/version note và compile gate, không thêm SQLx API giả. |
| M3 lab measurement windows | Auth-lab verify-only recorder + metrics control route chỉ gắn ở binary loopback khi launcher truyền cờ; không thêm route vào auth_router sản phẩm. Control chỉ begin/end metrics, không đổi quyền/session/DB hoặc giữ pool. HttpState constructor nhận sink từ composition; launcher bật cho verify, gọi begin/end hai process quanh từng batch HTTP thật, không có traffic khác trong window. End trả bounded numeric/enum observations và dropped=0 mới dùng evidence; default interactive không có route này. | HTTP `mod.rs`, bin `auth_lab.rs`, `ops/auth/run_local.py`, `ops/auth/verify_measurements.py`, `ops/auth/tests/test_measurements.py`; M1/M2. Review endpoint scope/redaction/old-window rồi real provider, cleanup. |
| M4 baseline/budget failure evidence | Hai process cùng key:5batch×6success account0; nhiều key:5batch×6success account0/3/4, trước UF/MI/AF để không đụng limiter exhausted. Lưu samples/p50/p95/max theo stage/outcome/process, kiểm sample/drop counts và outcome HTTP. Thử queue timeout/cancellation bằng unit barrier/permit thật, pool timeout bằng pool test kiểm acquire thật và lock timeout bằng owned holder; mọi lỗi503/no credential/no session, không giả AUTH_INVALID. Không suy production SLO từ local samples; budget runtime hiện có slot2/wait5s,pool8/acquire5s,lock5s/statement30s vẫn giữ. | Chốt path của từng fault subtask sau baseline, mỗi subtask≤5files; không làm production fault endpoint. Chỉ mở gate tiếp sau review evidence còn thiếu; owner chốt production budget theo NFR/số đo, không tự gán đã ký. |

Root recorder dùng Mutex chỉ cho append/copy dữ liệu bounded, không giữ qua
await, không log request hoặc metric label unbounded. Window generation bảo
vệ span cũ hoàn tất sau reset; inactive không ghi sample. Sink lỗi/poison chỉ
làm evidence invalid, không được thay outcome auth. Các sample chứa stage,
outcome và elapsed microseconds, không chứa timestamps/UUID/query hoặc PHC.
Port start_span/finish_span đếm active_spans theo generation; end_window từ
chối khi còn span và không reset state để che work đang chạy. Start cũng từ
chối window đang active. Overflow/stale/poison phải làm snapshot invalid, không
tự bỏ sample rồi vẫn PASS. M1 đã review độc lập REVIEWED_READY_FOR_BUILD với
contract này; M2/M3 còn checkpoint riêng sau khi kiểm source/path thực tế.
Unit tests phải chứng minh cancellation không bị tính Completed và bounded
overflow không bị bỏ qua. Rollback: dừng đo/khôi phục riêng instrumentation;
không rollback auth guard/crypto policy/DB. CP-02 vẫn PARTIAL trong các
checkpoint M1/M2; chưa có số đo thì không đánh M3/M4 hoặc C1 đạt.

#### M2 — checkpoint PostgreSQL trước BUILD

M1 phải có test/review nguồn cuối và regression mặc định disabled trước khi
chạy M2. Scope đúng5file ở bảng trên, không thêm query/policy/timeout/grant.
Thứ tự: optional sink trên store → tách pool acquire/BEGIN của IdentityStore
→ bucket/User/commit boundaries → sửa3initializer ngoài auth thành disabled
→ compile/test/lint → provider132checks. Không sửa SQL hoặc các resolver khác.

- PoolAcquire bắt đầu trước `pool.acquire().await`; TransactionBegin dùng
  owned connection và bắt đầu trước khi kết thúc PoolAcquire để không có
  khoảng trống giữa hai stage. Lỗi Result ghi Error, future bị drop ghi
  Abandoned; không đưa SQLx error vào sink. SQLx0.8.6 `Pool::begin` vốn gọi
  `Transaction::begin` với owned pool connection; cách tách này phải compile
  bằng bản lock hiện có, không nâng dependency.
- BucketAcquire bao gồm upsert và SELECT FOR UPDATE tới khi nhận row; không
  gọi nó là thời gian lock server thuần. Ngay khi row về mở FencedWork trước
  khi đóng BucketAcquire; clock_timestamp/decode và toàn bộ phần auth sau đó
  nằm trong FencedWork. Clock vẫn là statement riêng sau lock như hiện tại.
  AccountAcquire bao gồm SELECT FOR UPDATE cùng decode snapshot; None cũng
  là Completed vì truy vấn hoàn tất, không phải xác nhận credential hợp lệ.
- PgUnitOfWork giữ optional sink và optional FencedWork guard. CommitAck đo
  quanh physical commit; Result quyết định Completed/Error cho ACK và cho
  FencedWork nếu có. CommitUnknown vẫn giữ nguyên mapping. Drop trước commit
  chỉ ghi FencedWork Abandoned; SQLx queue rollback không phải bằng chứng
  server đã nhả khóa. Không thêm Drop impl cho UoW để tránh đổi move semantics.
  Constructors device/template/retention dùng None và không sinh auth metrics.

Verification: unit observer kiểm default disabled và cùng sink qua clone;
full Rust tests/fmt/clippy; provider132checks xác nhận error/UNKNOWN/fence
không đổi khi diagnostics disabled. Source metrics enabled trên PostgreSQL
phải đợi M3 composition và M4 exact-count windows; không suy từ unit test.
Review test phát hiện `PgConnectOptions::new()` tự đọc PG environment/passfile;
lazy/closed pool không chặn side effect lúc constructor. Không chạy tiếp bản
test này. Cách sửa cần review: test cha chỉ nhận diện marker trong own argv,
re-exec đúng current test binary với exact test filter và marker harness hợp
lệ; `env_clear` + SystemRoot literal như launcher Windows hiện có. Chỉ test
con mới tạo options bằng `new_without_pgpass` với environment rỗng, min0/lazy,
đóng pool trước begin. Không đọc giá trị env, không sửa environment cha, không
unsafe/generic-store/new dependency. Owned child startup/run/shutdown dùng
chung deadline5s, lỗi/timeout FAIL; không reset deadline hoặc kill global PID.
Nếu không chứng minh được isolation thì giữ AC chưa đạt, không đổi test để
che limitation. Fix isolation đã được review nguồn và3libtests độc lập PASS;
root chạy81workspace tests qua isolated target runner, fmt/Clippy và provider
regression cuối PASS; không dùng lượt pre-isolation làm evidence tuân thủ.
Rủi ro doc(hidden) SQLx API được khóa bằng compile gate và source/version note;
nguy cơ nhãn nhận credential chặn bằng enum-only port; span drop không được
diễn giải là rollback confirmed. Rollback riêng instrumentation5files, giữ
nguyên SQL/auth policy. Checkpoint review kế hoạch trước source edits; reviewer
kiểm chính xác ranh giới/scope và dependency này.

#### M3 — composition lab và window control (PLAN đã review, BUILD scoped retest PASS)

Dependencies: M1/M2 nguồn cuối qua review/tests và132provider regression
disabled; stage measurements enabled chưa có nên chưa đánh DONE M2/CP-02.
Scope5files trong bảng M3, tests Rust đặt ngay trong bin hiện có, không thêm
package/schema/grant/production endpoint. Ordered tasks và AC:

1. `HttpState::new` giữ API và behavior disabled; constructor opt-in riêng
   nhận cùng sink vào PasswordService/PgIdentityStore trước CryptoService::new.
   Sink bắt đầu inactive nên dummy hash startup không vào window. Không thêm
   field identity vào metric hoặc thay transport/session policy.
2. Binary auth-lab nhận flag measurement và khóa control ngẫu nhiên256bit
    qua stdin từ launcher verify, giữ trong RAM, không serialize vào response/
    evidence, không log/Debug; stdin config là transport nội bộ được phép.
   Interactive default không bật route. Router control riêng của binary chỉ
   merge khi enabled, bind loopback; không thêm vào auth_router sản phẩm.
   POST begin/end tại `/__auth_lab/measurements/begin` và `/end`; yêu cầu đúng
   một header control `x-auth-lab-measurement`, so sánh khóa không early-exit
   theo nội dung; kiểm key/Origin trước khi await body và trước mutation window.
   Body chỉ được rỗng: giới hạn đọc1byte để phát hiện nonempty, deadline đọc
   toàn body1s; nonempty/over-limit trả413, body chưa kết thúc trong1s trả408
   generic. Header/key/Origin invalid trả403 ngay, không chờ body; không nhánh
   reject nào được begin/end/reset window. Không CORS, không cookie,
   cache-control no-store mọi response; không có fault/hold-pool/reset endpoint.
3. Begin trả window generation số; begin khi window mở hoặc end khi span còn
   chạy trả409 và giữ nguyên state, sai key trả403 generic. End trả snapshot
   bounded gồm valid/drop/stale/poison và sample `{stage,outcome,elapsedUs}`;
   enum literals/numeric only, không timestamp/user/request/error string/SQL.
   Có thể trả snapshot invalid nhưng verifier bắt buộc FAIL; không coi200 là
   evidence đủ. Giữ buffer max4096 và serialize sau khi nhả mutex.
   Wire proof được chốt: header64hex của HMAC-SHA256(controlKey32byte,
   ASCII `auth-lab-measurement-v1`); verify_slice dùng constant-time equality
   từ HMAC crate hiện có. Proof/key chỉ trong RAM/stdin/header loopback,
   không log/serialize vào evidence, không dùng signing key/session token.
4. Launcher chỉ verify mới cấp cùng control key cho hai process và nối sink.
   Verifier mở window cả hai trước batch, chờ toàn bộ HTTP responses kết thúc
   rồi end cả hai; không traffic khác trong window. Không retry login hoặc
   reset limiter. Validation key/schema/state/sample strict; sau lỗi dùng
   finally/lifecycle hiện có để dừng process trước fixture cleanup, không
   tuyên bố end thành công nếu409 còn work. Client control dùng URL loopback
   tuyệt đối của binary, không dùng helper request tự thêm `/api/v1`. Response
   JSON cap1MiB (đọc thêm1byte để reject vượt cận), toàn exchange deadline3s
   từ trước connect, không chỉ socket timeout được tính lại theo mỗi read.
   Có watchdog shutdown đúng owned TCP socket để ngắt cả header/body trickle;
   kiểm monotonic deadline lại trước khi nhận kết quả để response muộn không
   thành PASS dù watchdog chưa được scheduler chạy.
   cleanup đóng response/connection, cancel+join watchdog trong1s riêng trước
   khi bàn giao window/cleanup fixture. Không retry control mutation mù khi
   response mất; kết quả pending làm phép đo FAIL và dừng process sở hữu.
5. Smoke enabled: một successful Android login ở mỗi process với account0
   trước UF/MI/AF. Mỗi process phải đúng9stages×1Completed, valid=true,
   drop/stale/poison0, generation khớp; không sample từ seed/startup. Test
   negative parser phải bắt unknownstage/outcome, bool thay số, missing/extra
   samples/window mismatch/dropped/stale/poison/Abandoned/Error. Raw token/body
   login chỉ giữ trong RAM. Smoke không thay M4 repeated baseline/budget faults.

Rust router tests không DB: default route absent, key thiếu/sai/trùng hoặc
Origin/body bị chặn trước đọc/mutation, body nonempty413 và chunked/stalled
body408 theo1s dù connection chưa EOF; window giữ nguyên trong mọi rejection.
Kiểm begin/end empty window, active span409 rồi finish/end
thành công, no-store/no cookie; Python unittest strict parser/negative samples.
Client negative tests bắt oversized JSON, header/body trickle vượt total3s,
đúng path ngoài `/api/v1`, watchdog join và connection close cả khi lỗi.
Full Rust/Web unaffected; chạy Rust tests/fmt/clippy, host suite, real provider
132checks+smoke rồi SELECT cleanup. Report riêng smoke samples và source SHA;
không tự ký production SLO/browser/C1. Rollback riêng opt-in routing/wiring;
diagnostics mặc định tắt và auth core vẫn giữ nguyên. Rủi ro loopback control
bị browser/caller khác can thiệp giảm bằng random key + no Origin + bounded
body/no CORS; verifier counts còn là integrity gate. Review GPT-6.1/xhigh vòng2
**REVIEWED_READY_FOR_BUILD**: finding M3-PLAN-001 về body/client deadline đã
đóng ở mức PLAN trước BUILD. Sau BUILD, hai tester độc lập và root regression
đã đạt checkpoint scoped M3 ở đầu mục; không đánh M4/CP-02 tổng DONE.
[Review hai vòng](../../test-reports/FEAT-TN-001-measure-m1-independent-2026-10-26.md).

#### M4a — repeated baseline trước budget faults (PLAN reviewed, BUILD scoped retest PASS)

Dependencies: M1–M3 scoped review/tests và135provider checks/cleanup PASS.
Scope3files: `ops/auth/verify_measurement_baseline.py`,
`ops/auth/tests/test_measurement_baseline.py`, `ops/auth/run_local.py`.
Không đổi Rust/auth/SQL/quyền/fixture/timeout. Không UI mới trong slice này.

1. Viết test RED cho orchestrator và percentile. Dùng control/client/parser
   M3 cùng `concurrent_batch` hiện có, không tạo scheduler/socket client mới.
   Nhận generation cuối mỗi process từ M3; begin tiếp phải tăng đơn điệu.
2. Chạy sau M3 trước UF/MI/AF: same_key5batch×6success account0, rồi
   multi_key5batch×6success account0/3/4. Mỗi batch3request/process, barrier6;
   begin cả hai trước batch, chờ cả6responses rồi end cả hai. Không retry/
   discovery/query/reset limiter giữa window. Status200, token nonempty,
   limited=false và không cookie là điều kiện bắt buộc.
3. Mỗi snapshot phải generation đúng, valid=true/drop=stale=0/poison=false,
   đúng27samples=9stages×3Completed. Reuse strict parser, không bỏ lỗi/thiếu
   mẫu để tạo percentile. Mỗi topology/process/stage có15samples qua5batch;
   tính p50/p95 nearest-rank và max từ integer microseconds, giữ raw numeric
   windows để tái tính. Xuất chỉ topology/process/stage/outcome enum, batch/
   generation/count/duration; không raw HTTP body/header/credential/identity.
   Tổng phải đúng20unique windows phủ2topologies×5batch×2process,540samples,
   36summary groups×15samples. Không chấp nhận duplicate/missing coverage;
   generation theo mỗi process tăng xuyên cả hai topology. Vector15duration
   phân biệt phải cho p50=orderstat8, p95=orderstat15=max.
4. Host suite và mutation bắt sai percentile/index hoặc stage distribution;
   tester GPT-6.1/xhigh review/retest độc lập. Real provider kỳ vọng145checks
   (135+10batch invariants),540baseline stage samples; SELECT cleanup riêng
   role/HBA/fixture0, report vào docs/test-reports với source SHA. Không chạy
   đồng thời lab/Cargo khác; rollback riêng3file M4a, giữ M3 smoke và guards.
   Hủy verify bằng KeyboardInterrupt phải cleanup rồi propagate lỗi để main
   trả nonzero; không ghi report success từ partial checks. Interactive Ctrl+C
   vẫn kết thúc thường. Regression thực thi handler thật trong AST sandbox,
   không gọi nó là full process/DB cancellation test. Duplicate coverage test
   phải giữ fresh generation/count để guard khác không che invariant identity.

Rủi ro máy local jitter hoặc timeout: ghi FAIL và giữ số đo/lỗi an toàn,
không nới timeout/concurrency hoặc đổi policy để PASS. Đây là baseline local
có warm-up M3, không benchmark production/SLO hay đủ budget fault evidence.
M4b pool/lock/queue fault còn checkpoint riêng sau M4a; CP-02 tổng chưa DONE.
Checkpoint PLAN cần review trước source edits; findings phải được sửa/review
trước BUILD. Sau code chỉ READY_FOR_QA nếu đúng AC, không tự nghiệm thu E2E.
Review PLAN GPT-6.1/xhigh: **REVIEWED_READY_FOR_BUILD**, không còn Blocker/
Important trong scope; [review](../../test-reports/FEAT-TN-001-measure-m4a-independent-2026-10-26.md).
Checkpoint BUILD hiện tại đạt source/provider scoped như phần kết quả đầu mục;
không đổi AC của M4b hoặc đóng toàn CP-02.

#### M4b-L — User lock timeout thật (PLAN reviewed, BUILD scoped retest PASS)

Dependencies: M4a145provider/cleanup và M3 control/source đã scoped retest.
Scope3files: `ops/auth/verify_lock_budget.py`,
`ops/auth/tests/test_lock_budget.py`, `ops/auth/run_local.py`. Reuse nguyên
`UserFenceHolder`, HTTP login helper và audit-fault read_snapshot; không sửa
holder/SQLx/core/timeout/quyền hoặc thêm production fault route.

1. Viết test RED cho oracle503/snapshot và orchestration. Chạy sau M4a trước
   UF/MI/AF, target account3 ACTIVE/seed/no membership, counter0. Mỗi WEB và
   ANDROID có control login thành công đúng identity/client trước giữ khóa;
   đọc snapshot committed (session/actor audit/counter) trước request lỗi.
2. Append holder vào registry trước start; holder chỉ SELECT FOR UPDATE trên
   fixture3, không mutation/commit. Mở primary measurement window từ generation
   cuối M4a. Gửi đúng1login qua worker, quan sát actual pg_blocking_pids bằng
   holder.wait_for_blocked(), pending chưa xong. Giữ khóa tới khi HTTP kết thúc
   (accepted-result deadline8s tính từ trước submit; wait observation dùng
   cùng phần ngân sách, future.result nhận phần còn lại và kiểm monotonic
   lại khi nhận response), không stop/commit để tạo response. Đây không phải
   tổng shutdown deadline; worker dùng HTTP helper timeout20s hiện có, holder
   stop5s trước executor join khi lỗi để không tự treo request dưới khóa.
   Generation primary carry-forward từ M4a qua WEB rồi ANDROID, không dùng
   lại generation M4a cho case thứ hai.
3. Sau response và trước stop, qua stdin holder gửi SELECT marker
   FENCE_STILL_HELD chỉ khi pg_locks có granted RowShareLock trên public.users
   của pg_backend_pid(); đọc marker trong1s. Query literal, không input SQL.
   READY đã khóa row, không có lệnh thay row/nhả transaction giữa hai marker;
   marker sau response chứng minh không dùng early release/idle expiry giả
   timeout. Finally stop holder trước join worker nếu wait/HTTP/proof lỗi;
   registry launcher vẫn kiểm backend gone trước fixture cleanup.
   SQL proof cố định: `SELECT 'FENCE_STILL_HELD' WHERE EXISTS(SELECT 1 FROM
   pg_locks WHERE pid=pg_backend_pid() AND relation='public.users'::regclass
   AND mode='RowShareLock' AND granted);` Không COMMIT/savepoint/rollback
   giữa READY và proof.
4. HTTP phải503/SERVICE_UNAVAILABLE với error schema/message/correlation hợp
   contract, no-store/no credential/cookie/context/CSRF. Sau holder stop đọc
   audit-fault snapshot scoped correlation: session/actor audit/counter không
   đổi, exact request audit0. Healthy login sau nhả khóa phải200 đúng identity,
   tăng session/audit đúng1 và counter giữ nguyên. Không gọi span Abandoned là
   bằng chứng rollback; committed readback và recovery là evidence riêng.
5. End primary window sau request/holder cleanup, trước recovery. Snapshot
   exact5samples: pool_acquire/transaction_begin/bucket_acquire Completed,
   account_acquire Error, fenced_work Abandoned; không hash/commit ACK stage.
   generation đúng/valid true/drop=stale0/poisonfalse; enum/numeric only,
   account_acquire4.9–7s theo budget lock5s đã có (gateway statement30s).
   Đây là cận kiểm harness, không nới timeout sản phẩm. Holder idle10s giữ
   nguyên. Không retry/reset bỏ lỗi hoặc xuất raw SQL/HTTP/credential/UUID.
6. Mỗi client8invariants (control,freshbucket,actualwait,held-after-response,
   safe503,committedunchanged,stages,recovery): kỳ vọng161provider checks
   (145+16). Host suite/mutation/tester GPT-6.1/xhigh review/retest, provider
   thật và SELECT cleanup role/HBA/fixture0. Reports/SHA vào docs/test-reports.

Rủi ro scheduler/container chậm làm không quan sát waiter/proof: FAIL và
cleanup, không đổi idle/lock/time budget để PASS. Rollback riêng3file slice,
giữ M4a/guards. M4b pool exhaustion và queue timeout/cancellation chưa được
thay bằng case lock này; CP-02/C1/browser/SLO vẫn mở. Review PLAN trước BUILD.
Review PLAN GPT-6.1/xhigh trước BUILD: **REVIEWED_READY_FOR_BUILD**; checkpoint
source/provider hiện tại ở đầu mục đạt scoped retest, chưa đóng CP-02 tổng;
[report](../../test-reports/FEAT-TN-001-lock-budget-independent-2026-10-26.md).

#### M4b-Q — verify queue/cancellation evidence (PLAN reviewed, unit scoped retest PASS)

Dependencies: diagnostic M1/crypto source và M4b-L scoped provider161 PASS.
Discovery: security.rs đã có hash queue timeout5s, queued-hash cancellation
và worker-permit cancellation tests. Không viết lại các case này hoặc đổi
production behavior. Login gọi verify có closure riêng; bổ sung đúng hai
regression để kiểm chính nhánh verify, scope1file
`backend/src/adapters/security.rs` (chỉ cfg(test) diagnostic_tests).

1. Verify queue timeout: giữ đủ2permit thật, mở recorder rồi gọi verify với
   input synthetic; mong Unavailable sau ít nhất5s nhưng trong outer8s,
   đúng1HashQueue/Error, không BlockingQueue/HashWork. Nhả permits sau assert,
   test không đọc env/DB hoặc đổi policy5s. PHC có thể synthetic invalid vì
   timeout phải xảy ra trước worker/PHC parsing; không dùng nó làm evidence
   credential validation.
2. Verify caller cancellation: tạo PHC synthetic hợp lệ trước khi gắn observer/
   mở window, dùng barrier worker thật hiện có. Abort caller tại HashWork
   barrier, window vẫn từ chối end, chỉ1permit available; release worker rồi
   acquire đủ2permit trong5s để chứng minh closure đã xong. Snapshot cuối đúng
  3distinct stages Completed, valid/no-loss; không suy auth request/session
   thành công từ CPU stage. Barrier cũ bounded2s giữ nguyên, không sleep race.
3. Independent GPT-6.1/xhigh review/test; mutation đổi verify closure thành
   drop permit sớm và đổi queue timeout thành tức thời phải bị assertion bắt,
   restore đúng SHA/không DB. Focused source/tests, Rust fmt/Clippy và full
   isolated workspace; không rerun provider chỉ vì thêm unit tests khi runtime
   bytes/config không đổi. Lưu logs/SHA/report/progress, rollback riêng hai
   test; không đổi hasher/core/security policy để tạo regression giả.
   Window phải trả đúng SpansActive trước và sau abort, không chỉ is_err.
   Snapshot3stage cuối phải mỗi stage xuất hiện đúng1lần/Completed/valid/
   dropped=stale0/poisonfalse. Timeout dùng cả Instant thật và sample.elapsed
   ≥5s trong outer8s. Barrier2s là failsafe, không dùng việc barrier tự hết
   hạn làm tín hiệu release thành công.

Checkpoint chỉ xác nhận bounded hasher queue/permit tại unit boundary.
HTTP503/no-session mapping có source/provider evidence khác; không gọi unit
queue là real HTTP overload test hoặc pool exhaustion. Pool timeout vẫn mở,
CP-02/C1/browser/SLO chưa DONE. PLAN review trước chỉnh test source.
Review GPT-6.1/xhigh: **REVIEWED_READY_FOR_BUILD**; [report](../../test-reports/FEAT-TN-001-queue-budget-independent-2026-10-26.md).
Checkpoint hiện tại: source tests/review/mutation/isolated workspace đã PASS
như phần kết quả đầu mục; không đóng pool hoặc CP-02 tổng.

#### M4b-P — actual HTTP dưới pool exhaustion (PLAN trước BUILD)

Kết quả checkpoint: **READY_FOR_QA / SCOPED_RETEST_PASS** theo
[report](../../test-reports/FEAT-TN-001-pool-budget-2026-10-26.md), chưa nghiệm thu
CP-02 tổng. Checklist scoped:

- [x] Real TCP hai client503 trong khi đủ8leases vẫn held tới sau metrics-end;
  exact1PoolAcquire/Error mỗi generation, acquire gần5s và không stage sau đó.
- [x] Scoped committed state không đổi; release sau cả hai proof, healthy
  recovery cùng pool; STOPPED sau reader/server/pool drain và parent reap.
- [x] TDD/review độc lập,96Rust/88host/fmt/Clippy/176providerassertions,
  SELECT cleanup0; files/version/evidence/manual Tester đã ghi. Source chưa commit.

Phần dưới giữ thiết kế đã review trước BUILD để đối chiếu AC.

Dependencies: M4b-L161provider/cleanup và Q90Rusttests scoped PASS. Không dùng
core-only PoolClosed/Unavailable thay actual acquire timeout/HTTP503. Scope
đúng5files: `backend/src/bin/auth_lab.rs`, module riêng
`backend/src/bin/auth_lab/pool_budget.rs` (không binary mới),
`ops/auth/run_local.py`, `ops/auth/verify_pool_budget.py`,
`ops/auth/tests/test_pool_budget.py`. Rust protocol tests inline module mới.
Không thêm dependency/schema/grant/fault endpoint hoặc đổi pool8/acquire5s.

1. Special child opt-in bằng own argv literal `--pool-budget`; không có
   secret trong argv. Normal mode giữ stdin read-to-EOF/config và router cũ.
   Special mode cần measurement flag/key hợp lệ, cấu hình JSON một dòng≤16KiB
   qua stdin, rồi command frames≤16bytes; một owned reader xuyên suốt giữ
   buffered input, không trộn read_to_string đợi EOF với kênh điều khiển sống.
   Reader chỉ parse literal HOLD/CHECK_HELD/RELEASE/STOP, không nhận SQL/URL.
   Config/key chỉ RAM; không Debug/log/serialize vào observations.
2. Owned std::thread sở hữu stdin, kênh bounded1 đưa command sang async actor.
   Initial config receive5s; command idle30s; invalid/EOF/oversize/wrong-order
   phải FAIL child nonzero, không tự nhả rồi vẫn PASS. Không dùng abort một
   blocking stdin read làm bằng chứng đã dừng thread. Reader thoát ngay sau
   gửi STOP, không đọc frame kế/đợi EOF; failure drop receiver trước cleanup.
   STOP hợp lệ join reader
   và owned server trong cận riêng; failure timeout làm main exit1 và parent
   stop/reap đúng Popen trước fixture cleanup (kể cả reader còn đợi input).
3. Actor states Ready→Held→Released; HOLD chỉ Ready, CHECK_HELD chỉ Held,
   RELEASE chỉ Held, STOP cleanup từ mọi state. HOLD acquire đúng8leases từ
   chính PgPool của HttpState trong total10s; trước ACK kiểm len8/size8/idle0.
   Lease vector không drop/auto-release giữa HOLD và RELEASE. CHECK_HELD sau
   mỗi response/metrics-end kiểm lại cùng8leases/size8/idle0, chỉ ACK literal.
   RELEASE drop vector rồi ACK; không đóng pool. STOP nhả leases rồi join reader,
   server và pool.close trong total5s (abort owned task nếu quá cận, không tuyên bố
   graceful PASS), xác nhận pool closed/drained trước STOPPED. Parent phải
   wait/reap≤5s sau ACK trước mở primary/peer.
4. Launcher verify chạy special child ĐẦU TIÊN, seed đúng5account/2workspace
   bằng code cũ; registry ownership trước fault. Test hoàn tất STOP/reap rồi
   primary/peer normal dùng skipFixtureSeed=true, cùng graph/key. Không có
   third8pool cùng primary/peer vì role connectionlimit16. Interactive không
   bật mode/protocol. Startup/command failure giữ cleanup/journal hiện có.
5. Python verifier control login WEB/ANDROID account3 đúng identity/full và
   đúng credential channel trước HOLD; scoped committed baseline sau control.
   HOLD ngoài measurement window. Mỗi client mở window riêng trên special
   process, đúng1HTTPlogin thật (Origin cho WEB), nhận503safe/no credential,
   end snapshot rồi CHECK_HELD. Snapshot exact1PoolAcquire/Error4.9–7s,
   generation carry-forward/valid/no-loss; không TransactionBegin/hash/commit.
   Accepted response deadline8s từ trước request và fresh check; không retry.
   Scoped snapshot session/actor-audit/counter không đổi, request audit0.
6. Sau BOTH response/end/proof mới RELEASE, rồi healthy WEB/ANDROID recovery
   trên CHÍNH pool/router cũ; mỗi recovery tăng đúng1session/audit, counter giữ
   nguyên. Không chuyển recovery sang peer mới để che pool còn hỏng. Report
   chỉ enum/numeric/flags; reuse503/healthy oracle và audit-fault read_snapshot.
   Không stdout body/header/token/config/digest/UUID hoặc raw SQL error.
7. Host controls chỉ qua owned stdin/stdout, ACK schema/literal chính xác,
   HOLD wait12s (child acquire total10s), STOP wait8s (child shutdown total5s),
   command khác wait5s từ trước write/read và fresh check, không reset deadline
   vì marker lạ. Parent đóng stdin khi STOP. Python reader phải được join/
   thu hồi qua child lifecycle khi lỗi, không αφή thread giữ stdout child sống.
   STOP/reap là invariant riêng trước khi normal suite bắt đầu.

Verification checkpoints: Rust unit protocol/state-order/oversize/EOF/flag
default-off và lease-count policy; host negative fixtures có503sai/earlyrelease/
missingproof/snapshotgeneration/count/lateACK/deadline/state/recovery/stop.
Mutation phải bắt bỏheldproof hoặc chấp nhậnlateACK. Full isolated Rust/host,
fmt/Clippy, GPT-6.1/xhigh review/retest trước evidence thật. Provider dự kiến
176checks=161+15 (mỗi client6control/safe503/stage/heldproof/state/recovery,
global HOLD/RELEASE/STOP-reap3); SELECT cleanup role/HBA/fixture0, source SHA
và report vào docs/test-reports. Check count chỉ là một AC; không dùng nó thay
raw phase/timing/state evidence. Không tăng timeout hoặc bỏ lease khi fail.

Rủi ro owned stdin reader không abortable đã nêu ở bước2; không để runtime
shutdown đợi thread vô hạn, failure kết thúc owned child nonzero. Không dùng
FIFO file/env/productionroute để truyền command. Rollback riêng5files của
mode/harness, giữ normal auth/fixtures/guards. Q vẫn unit evidence, P chỉ
pool timeout; CP-02 owner budget/C1/browser/SLO/E2E chưa tự đóng theo176checks.

Checkpoint P-host-test (cập nhật sau BUILD): test peer-start-failure hiện hữu
trong `ops/auth/tests/test_launcher.py` giả định child đầu là primary. Special
child mới làm assumption lỗi; tách microtask2files launcher/test hiện hữu để
patch verifier bằng fake và giữ kiểm primary-stop-before-DB-cleanup, đồng thời
kiểm special-stop-before-normal. Không xóa/skip hoặc giảm assertion cũ. Đây là
file thứ6 của toàn nhánh P, không mở rộng runtime scope5files; tester review
và full host suite phải đạt trước provider. GPT-6.1/xhigh review/test lại.
Checkpoint PLAN cần review trước source edits.

### CP-02-UF — disabled và User fence provider

Kết quả **READY_FOR_QA**:132provider checks/45host tests PASS source cuối,
bốn password/status races ×Web/App có actual blocker wait→mutation commit→401,
không phát session/audit success, counter và failure audit đúng. Hai static
disabled cases có correct-password/status precondition. Role/HBA/fixture/holder
backend cleanup0. PLAN và code review mỗi loại2cycles, mutation PASS. CP-02
tổng còn internal hash/queue/pool/lock budget, không mở C1 hoặc ký E2E.
[Report/evidence/file list/Tester](../../test-reports/FEAT-TN-001-user-fence-2026-10-26.md).

PLAN dưới đây đã review trước BUILD; không thay runtime evidence phía trên.

Scope tối đa năm source/test files: `ops/auth/verify_user_fence.py`,
`ops/auth/user_fence_holder.py`, `ops/auth/tests/test_user_fence.py`,
`ops/auth/tests/test_user_fence_holder.py`, `ops/auth/run_local.py`.
Dependencies:92provider checks đã có, user đã duyệt role1giờ/5accounts/2workspaces
và cleanup. Không thêm grant/schema/account/dependency hoặc auth fault endpoint.
Baseline đổi password account2 trước UF; account1 disabled không có membership,
account4 còn PHC seed dùng làm nguồn phục hồi bên trong SQL, không xuất verifier.

1. Kiểm disabled account1 qua HTTP WEB/ANDROID:401 AUTH_INVALID generic,
   no-store/no cookie/token/context/CSRF; session/success audit không tăng,
   failure audit đúng correlation/client và limiter counter tăng. Không coi
   account disabled chỉ có trong seed là evidence. Negative harness phải bắt
   response lộ credential hoặc session vẫn commit.
2. Dùng psql holder riêng đã kiểm canonical container/owned role và exact
   fixture provenance. Transaction chỉ khóa target `FOR UPDATE`; cấp PID và
   marker phi bí mật. Password race dùng account1; status race dùng account2
   sau khi baseline password flow đã xong. Cả hai không có membership. Chuẩn
   bị target ACTIVE với PHC seed bằng SQL từ account4,
   HTTP control phải200 trước mỗi case. Phát một login có credential seed;
   quan sát probe backend đang chờ Lock do chính holder PID chặn qua
   `pg_blocking_pids`, không đọc query text/PHC/token. Khi wait đã xác nhận,
   holder đổi PHC từ account2 (hai password cases chạy trước) hoặc status
   DISABLED rồi COMMIT. Bốn case:
   password/status × WEB/ANDROID; pending request phải401/no credential,
   không có session/success audit mới, failure audit đúng request và counter
   tăng. SQL readback xác nhận mutation đã commit. Trước static disabled phải
   restore account1 về DISABLED +PHC seed từ account4 và boolean readback cả
   status/hash-equality, để401 không bị nhận nhầm từ credential sai. Mỗi control
   trước race cũng đòi ACTIVE/seed-equality và HTTP200 đúng target/client.
   Đây là controlled fixture
   transition để kiểm fence, không tự nhận đã kiểm admin-disable HTTP workflow.
3. Budget harness: startup5s, observe wait3s (<provider lock_timeout5s), mỗi
   metadata SQL query timeout1s, holder idle transaction10s, shutdown5s; mọi
   lỗi/không wait/timeout đều FAIL, không đổi thành race PASS. Dừng/join request
   và holder trước fixture restore/launcher cleanup; xác nhận holder backend
   đã biến mất qua metadata trước khi tiếp tục. Cuối suite restore account1
   disabled và account2 ACTIVE, dùng seed PHC chỉ trong fixture; không reset
   limiter. Account1 có2password-race+2static=4failure; account2 có2failures từ
   baseline(current sai +login password cũ)+2status-race=4. Hai static disabled cases chạy sau password race,
   trước status race. Không dùng account3 vì AF cần bucket sạch hoặc account4
   vì MI sẽ kiểm boundary5; không thêm account để né dependency.

Lifecycle bổ sung: launcher giữ registry holder trước start và finally dừng
HTTPchildren→holder process/reader joined +metadata backend gone→proxy/gateway
→fixture cleanup. Mỗi holder có application_name UUID riêng từ startup conninfo;
chưa nhận PID vẫn nhận diện đúng backend sở hữu để xác nhận gone. Không kill
PID đọc từ metadata; chỉ terminate/kill đúng Popen do launcher tạo. Lỗi shutdown
giữ journal, không cleanup dưới holder sống. Metadata chỉ count/PID/wait relation,
SQL statement_timeout1s và client subprocess timeout hữu hạn, không dùng mặc định
120s của adapter chung cho observe3s. stdout chỉ marker/PID, stderr không xuất.

Checkpoint: harness RED/GREEN + mutation, real provider và cleanup count0,
review độc lập rồi report/progress READY_FOR_QA; CP-02 vẫn PARTIAL nếu budget
hash/queue/pool/lock chưa đo. Risk: false race do chưa thực chờ, limiter che
status/password, psql process chết nhưng backend còn giữ khóa, trigger last-admin.
Không dùng account0/4 làm target vì còn invariant capable Admin. Rollback chỉ
harness/launcher trong scope và fixture restore có ownership, không hạ guard.

### QA follow-up — Web coordinator race, 2026-10-26

PLAN đã rà với reproducer độc lập của tester GPT-6.1/xhigh: bốn ca FAIL trên
source trước sửa (queued login sau invalidate, duplicate queued submit, lỗi
choose/loadMore cũ ghi đè picker mới). Scope BUILD chỉ
`web/src/features/auth/coordinator.ts` và `web/tests/auth.test.mjs`; không đổi
wire, cookie, password policy hoặc layout. Đây là sửa invariant intent đã có.

1. Giữ bản RED độc lập, thêm regression vào runner Web hiện có. AC: barrier
   xác định, không sleep để tạo race; không log credential, không thay mock
   thành bằng chứng browser/provider.
2. Fence callback chờ Web Lock theo generation; khóa submit ngay khi xếp hàng;
   chỉ response còn sở hữu generation/intent được sửa state ở cả success/error.
   AC: invalidate trước lock không phát POST/ghi marker; hai submit cùng form
   chỉ một POST; response workspace cũ không xóa hay thay picker/marker mới.
3. Chạy repro nguyên bản, toàn bộ `npm.cmd run test:auth`, Web build; tester
   retest độc lập và ghi report vào `docs/test-reports`. Checkpoint chỉ ghi
   DEV_FIXED_READY_FOR_QA trước retest, không đóng CP-02/03 hoặc browser E2E.

Dependencies: source/runner hiện có, bốn reproducer đã được root chạy xác nhận
FAIL; user đã giao tester rồi sửa. Risk: khóa busy bị kẹt hoặc bỏ nhầm callback
hiện hành; kiểm cả luồng thường và response cũ thành công/lỗi. Rollback chỉ
phần sửa hai file trên; giữ evidence RED và không bỏ guard/test để đạt PASS.

Kết quả: ba nhóm lỗi coordinator (IND-AUTH-001…003), bốn ca được tester
GPT-6.1/xhigh tái hiện FAIL trước sửa,
retest nguyên bản4/4PASS sau sửa. Web25tests/build42modules PASS độc lập;
tám regression gồm cả restore cùng intent/generation mới, mutation bắt fence
bị bỏ. **SCOPED_RETEST_PASS / READY_FOR_QA cho browser**, không đóng P4/CP-03.
Tester còn xác nhận provider92checks/host30/Flutter37 và một native mock profile
API36 ngang200% PASS, cleanup0. [Báo cáo độc lập](../../test-reports/FEAT-TN-001-independent-testing-2026-10-26.md),
[file sửa và runbook](../../test-reports/FEAT-TN-001-coordinator-fixes-2026-10-26.md).

CP-02-ACK **READY_FOR_QA**:92provider checks/30host tests PASS trên source cuối,
Web/App mất DB ACK đã xác nhận nhưng HTTP503/no credential, mỗi case đúng1new
session/audit TTL24h; BEGIN/COMMIT=1 trong window, proxy worker join và cleanup
role/HBA/owned graph0. Mutation và fresh-context code review PASS sau sửa3finding.
CP-02 tổng còn User fence race/budget, không mở C1 hoặc nghiệm thu whole E2E.
[Report/Tester](../../test-reports/FEAT-TN-001-commit-ack-2026-10-26.md).

CP-02-AF **READY_FOR_QA**:84HTTP+PostgreSQL checks/16host tests PASS. Required
audit denial thật rollback session và trả503/no secret cảWeb/App;5wrong vẫn
commit failure_count5 và lần6trả429. INSERT audit restore/readback, rồi cleanup
role/HBA/graph0. Không phải commit UNKNOWN hoặc metrics/race evidence.
[Report/Tester](../../test-reports/FEAT-TN-001-audit-fault-2026-10-26.md).

CP-02-ACK PLAN trước BUILD đã **REVIEWED_READY_FOR_BUILD**; source/runtime
hiện **READY_FOR_QA** theo evidence92checks phía trên.
Fresh-context adversarial review3cycles đã chốt contract, không còn substantive
finding trên proposal; [record/sources/reconciliation](../../test-reports/FEAT-TN-001-commit-ack-design-review-2026-10-26.md).
Claim đã phản biện trước BUILD:
proxy lab chỉ cắt ACK sau PostgreSQL xác nhận COMMIT, vì cắt trước commit không
chứng minh UNKNOWN và cắt HTTP response không kiểm boundary DB→SQLx.
Sources: PostgreSQL17 protocol Query/CommandComplete/ReadyForQuery và source
SQLx0.8.6 transaction/executor, không dựa chunk TCP hoặc text query log.
Scope≤5files: `ops/auth/commit_ack_bridge.py`,
`ops/auth/tests/test_commit_ack_bridge.py`, `ops/auth/verify_commit_ack.py`,
`ops/auth/tests/test_commit_ack.py`, `ops/auth/run_local.py`.
Đề xuất sau adversarial review1: verify-only loopback proxy giữa backend và
InspectionServer đã xác thực role/DB; giữ startup/SCRAM, frame typed có cận1MiB,
không log packet. Mỗi arm có generation/connection riêng, chỉ chạy sau seed và
toàn bộ check trước đó đã kết thúc, không request đồng thời trong window fault.
Controller nội bộ RAM, không HTTP/control endpoint. Chỉ claim exact COMMIT khi
connection đang có ReadyForQuery=T; khóa/gate downstream **trước khi** forward
COMMIT để response nhanh không lọt. Chỉ C(COMMIT) rồi Z(idle) của cùng generation/
connection mới atomically mark confirmed rồi shutdown/close cả2socket ngay,
vẫn giữ suppression; successful path phải cho503trước timeout. E/EOF/malformed/
no-fire/timeout FAIL, không chuyển timeout thành confirmed.
Deadline tường minh: startup/frame completion/arm completion/worker shutdown;
timeout đóng cả2socket sở hữu, không dựa daemon/listener close để coi worker xong.
Case Web/App tuần tự trên account0 còn seed password; HTTP503/no credential/
no-store, dùng correlationId response để JOIN đúng LOGIN_SUCCEEDED audit với
session/account/clientType mới, đúng1cặp/case, expires-issued=24h. Không khẳng
định retention xóa sau24h: graph fixture được cleanup ngay sau suite bằng ownership.
Trong window cô lập, đếm metadata BEGIN/target COMMIT đúng1, cho phép cleanup
ROLLBACK riêng, HTTP caller không retry; record giới hạn quan sát thay vì suy
không replay chỉ từ delta count. Không lưu query/bind/PHC/token/digest/packet.
Dependencies: CP-02-AF restore INSERT thành công,84baseline provider checks;
không thêm grant/fixture/schema/dependency, không thay core để giả commit lỗi.
Thứ tự: nguồn chính thức + adversarial review → PLAN chốt → framer/controller
RED/GREEN → real proxy/provider → owned process/socket cleanup/readback → report.
AC: fragmentation/length bound/error-vs-COMMIT/one-shot race đều được kiểm;
server đã commit nhưng backend nhận503 mà không secret;2orphan có TTL24h được
cleanup ngay theo ownership, transaction-attempt count không replay trong request
window. Shutdown HTTPchildren→proxy active sockets/workers joined→bridge→fixture/
revoke. Test immediate response lúc forward, bare COMMIT ngoài transaction,
late prior-generation event, partial header/body, missing Z và cancellation.
CP-02 tổng vẫn PARTIAL sau ACK nếu fence race/budget chưa kiểm.

CP-02-AF PLAN đã rà trước code: kiểm audit sink hỏng qua HTTP thật, không thêm
hook production. Scope≤5files `ops/auth/verify_audit_faults.py`,
`ops/auth/tests/test_audit_faults.py`, `ops/auth/run_local.py`; sửa comment
`verify_concurrency.py` để nói đúng success không reset fixed-window còn hiệu lực.
`ops/database/verify_database.py` thêm3tên psql variable UUID/hex hữu hạn để
snapshot dùng bind/quote `:'name'`, không nối selector vào SQL. Không đổi quyền
connection hoặc các caller hiện có; unit negative kiểm selector injection bị chặn.
Dependencies:69provider checks PASS, role ownership và5fixture/2workspace đã
được user duyệt. Không DDL, thêm role, account/workspace hoặc quyền mới.
Thứ tự: harness RED → scoped REVOKE INSERT audit trên đúng owned role → valid
Web/App login và failed-login boundary → finally khôi phục INSERT ban đầu →
đọc privilege/provider/cleanup → evidence/progress. AC:
(1) valid Web/App login khi required audit bị PostgreSQL từ chối trả503/no-store,
không token/cookie/context/CSRF, session/audit committed count không đổi;
(2)5wrong trên account3 còn fresh vẫn401, lần6là429/Retry-After, failure_count=5
đã commit dù audit sink hỏng, không session/audit mới;
(3) ownership guard trước revoke/grant, finally khôi phục quyền kể cả check FAIL,
probe role/fixture/HBA được cleanup đọc lại0 sau suite. Report không SQL/body/
credential/hash/digest. Harness giả kiểm restore/fail-closed, provider thật mới
được PASS. Rủi ro chỉ giảm tạm quyền của principal sở hữu; không tác động reader/
runtime hoặc audit retention. Rollback helper/callsite; restore INSERT là về
đúng quyền đã duyệt, không cấp quyền rộng hơn. Checkpoint READY_FOR_QA sau
evidence; CP-02 tổng vẫn PARTIAL vì ACK UNKNOWN/fence race/budget còn thiếu.

CP-02-MI **READY_FOR_QA**:69HTTP+PostgreSQL checks PASS trên2process thật,
6same-key requests cho5×401+1×429;11host tests/fmt/Clippy PASS, mutation bắt
assertion nới sai, cleanup role/HBA/owned graph đọc lại0. HTTP duration chỉ là
quan sát6samples, chưa budget hash/queue/pool/lock. CP-02 tổng PARTIAL.
[Report/Tester/evidence](../../test-reports/FEAT-TN-001-provider-concurrency-2026-10-26.md).

CP-02-MI PLAN đã rà trước code, tiếp tục quyền DB đã cấp. Scope≤5files:
`backend/src/bin/auth_lab.rs`, `ops/auth/run_local.py`,
`ops/auth/verify_concurrency.py`, `ops/auth/tests/test_concurrency.py`,
`ops/auth/tests/test_launcher.py`. Dependencies: baseline59checks PASS, canonical
schema và5accounts/2workspaces hiện hành; không thêm quyền/dependency/fixture.
Thứ tự: harness RED → peer lab skip seed + lifecycle owned processes →6request
barrier qua2listener cùng DB/key → host tests/build/provider/cleanup readback.
AC: session primary dùng được tại peer;6login hợp lệ đa key đều200;6login sai
cùng key phân3request/instance cho đúng5×401+1×429/Retry-After, không Set-Cookie;
cả2process dừng trước cleanup/revoke kể cả peer startup fail. Lưu p50/p95/min/max
HTTP duration không email/token/body;6samples chỉ quan sát, chưa là load gate
hoặc tách hash/queue/pool/lock. Checkpoint READY_FOR_QA sau real provider và
cleanup độc lập; CP-02 tổng vẫn PARTIAL vì fault/UNKNOWN/race/budget còn thiếu.
Rủi ro cổng peer bận phải fail và dọn process sở hữu, không terminate server
khác; validate port pair trước DB. Rollback riêng harness/peer opt-in, core auth
và policy limiter giữ nguyên. User đã cho phép tiếp tục scope này, không hỏi lại.

R7-PW **READY_FOR_QA provider baseline**:59HTTP+PostgreSQL checks và5host tests
PASS; password9/revoke Web+Android/relogin đã kiểm, cleanup graph fixture/role/
HBA đọc lại0. Chưa CP-02/03. [Report/evidence](../../test-reports/FEAT-TN-001-provider-password-2026-10-26.md).

User đã cho phép role tạm1giờ, quyền auth/workspace/audit,5accounts/2workspaces
và cleanup; blocker quyền DB trước đây **RESOLVED** cho đúng launcher/scope đó.
Docker Desktop đã khởi động sau khi daemon pipe missing. Lượt provider thực
đầu đã PASS36checks; độc lập đọc lại role/user/HBA scoped=0/0/0. Không reset DB,
không đọc env, anonymous failure audit giữ retention. Browser quyền đã cho phép
nhưng CUA vẫn không có Chrome/Edge/IAB, không có DevTools tool; đây là blocker
kết nối, không còn là câu hỏi permission.

Lát cắt tiếp theo **R7-PW** (reviewed PLAN trước code,≤2source/test files):
`ops/auth/verify_provider.py` thêm helper kiểm nhánh004 bằng chính account
limited fixture. Dependencies: provider36PASS, contract draft0.2.1/policy1,
quyền user hiện có; không thêm fixture/privilege/dependency. AC:
(1) new8/thiếu hoa/thường/số/same trả422 đúng code, current sai401 và CSRF thiếu
403 không revoke phiên; (2) mật khẩu mới9ký tự hợp lệ trả204, old Web và Android
session cùng account đều401, old password bị401, new login full và đúng profile;
(3) các check cũ vẫnPASS và role/fixture/HBA cleanup đọc lại0, không log password/
cookie/token/body. New password chỉ là synthetic fixture, không tài khoản thật.
Thứ tự: helper kiểm HTTP thật→gọi trong limited branch trước empty branch→
full provider suite→cleanup readback→review/evidence/update004/progress/readiness.
Rollback riêng helper/callsite, không đổi core/wire/DB schema hoặc nới guard.
Checkpoint R7-PW không tự đóng CP-02: race đa instance, fault/UNKNOWN, budget
và independent review còn phải có evidence; không lấy36provider checks thay
browser/Android UI E2E hoặc các ca chưa chạy.

### Password policy addendum — user yêu cầu2026-10-26, PLAN đã rà trước code

UI refinement do user yêu cầu sau provider run: bỏ hint độ dài thường trực
trong login Web/App; validation và lỗi sau submit giữ policy hiện hành. Slice
≤3source files: AuthPage, login_screen, CSS riêng của hint nếu thành orphan.
AC không còn copy hint hoặc aria-describedby trỏ ID đã xóa, Web build/App
widget checks PASS; hint của màn tạo/đổi password không thuộc thay đổi này.
Kết quả **READY_FOR_QA**: Web build42modules, App9login widgets/scoped format,
1native login profile API36 landscape200% PASS/restore verified. Browser vẫn
BLOCKED_CONNECTION.8native profiles policy bên dưới là snapshot trước hint,
không giả source hint cuối đã được kiểm lại8/8.

Yêu cầu mới thay baseline12–128 ở phần password: “nhiều hơn8” nghĩa là tối
thiểu9, giữ tối đa128 Unicode codepoints; mật khẩu mới có Unicode chữ hoa,
Unicode chữ thường và ít nhất1số0–9. Không bắt buộc ký tự đặc biệt, không trim/
normalize/cắt input. Đồng bộ Web/App/backend/contract. Login kiểm9–128 và xác
thực credential đã lưu, không áp thành phần mới lên account cũ; currentPassword
đổi mật khẩu giữ1–128 theo contract hiện có. New/temporary password luôn dùng
quy tắc mới. Đây là thay đổi validation do user yêu cầu, không tự tuyên bố
backward compatible; wire fields giữ draft0.2.1, thêm policy fixture version1.
BA/handoff12–128 là baseline cũ, addendum này ghi rõ override thay vì sửa ngầm.

Thứ tự task/AC/dependency (mỗi slice≤5source files):

1. **PW1a contract**: shared `password-policy.json`, OpenAPI, static policy
   tests, validator assertion và compatibility README. AC fixture rõ8/9/128/129,
   từng thành phần thiếu, Unicode/space; new policy có mô tả/error FORMAT,
   login min9/current min1. Không credential thật/dependency.
2. **PW1b login boundaries**: login-validation fixture và test từ11/12 sang8/9;
   password-change fixture dùng strong synthetic newPassword để CSRF/same/success
   không bị chặn bởi validation mới. AC static suite PASS, không giả provider.
3. **PW2a backend**: domain input, application session, HTTP session,
   root password_policy test và HTTP negative test. AC dùng chung policy, chặn
   weak newPassword trước DB/hash/revoke, lỗi an toàn; login/current vẫn đúng
   boundary và same-as-current dùng code contract. RED→GREEN rồi full workspace.
4. **PW2b generated passwords**: IdentitySecurity default issue_temporary_password,
   member_creation, password_reset và focused test. AC prefix thành phần không
   thay256bit CSPRNG suffix, không đổi session token; validate trước hash, không
   log giá trị. **PW2c lab config**≤3files: launcher/auth-lab/provider synthetic
   password mới cùng rule; chỉ source/tests, không chạy DB launcher khi chưa phép.
5. **PW3 Web**: passwordPolicy.ts, AuthPage, policy test, package test command
   và coordinator test dùng strong synthetic newPassword.
   AC fixture parity, helper/error đúng9–128/hoa/thường/số; current/new/confirm
   đúng vai trò, keyboard/error semantics giữ, build và test thực chạy.
6. **PW4a App**: password_policy.dart, login_screen, password_change_screen,
   policy fixture test, login widget test. **PW4b**: password widget/native test
   đổi dữ liệu tổng hợp hợp lệ và login native đúng9. AC cùng fixture, error/hint đồng bộ, focus và
   không double-submit/trim/password retention. Full tests/analyzer/format PASS.
7. **PW5 verify/handoff**: Rust tests/fmt/clippy, contract suite, Web tests/build,
   Flutter suite và native login/password2OS×2display profiles khi AVD sẵn;
   browser thật vẫn cần connector, provider DB vẫn BLOCKED_APPROVAL. Không lấy
   mock hoặc compile thay provider/E2E. Update001/004/progress/runbook và SHA.

Checkpoint sau contract/backend và sau UI/native; review changed scope/comments.
Native follow-up **PW4c login keyboard** (≤3files): runtime valid9 ở landscape
font200% bắt missed tap reveal/submit. Trước sửa product phải capture geometry
và tái hiện bằng widget harness đầy đủ banner+IME. Nếu viewport không đủ target,
ẩn tạm header khi không gian sau IME quá thấp như password screen, giữ brand
khi keyboard đóng, background/animation/text scale/48dp targets/banner. AC RED→
GREEN widget, full suite/analyzer/format và4native login profiles trên source
cuối; không nới strict taps hoặc gọi policy/E2E PASS từ screenshot.
Rủi ro: client cũ cònmin12 hoặc không composition; triển khai đồng bộ, không
retroactively khóa login account cũ. Không đổi DB data/hash/rate limit/session
storage/topology; rollback source policy/fixtures/UI cùng phiên bản trước, giữ
token/credentials/dữ liệu nguyên trạng. Chỉ READY_FOR_QA sau actual verification;
CP-02/03/goal E2E chưa được unblock bởi task policy này.

Checkpoint source2026-10-26: PW1a/b, PW2a/b/c, PW3, PW4a **READY_FOR_QA**:
39contract tests,67Rust workspace tests (7HTTP),4lab spy tests,17Web tests và
Web build42modules,37Flutter tests PASS; Rust fmt/clippy và App analyzer/format
PASS. PW4b/PW4c **READY_FOR_QA source/native mock**:8profiles login/password
×API24/36×portrait/landscape200% trên source cuối PASS, strict taps và restore
đã kiểm. PW5 **PARTIAL** vì browser inventory rỗng, provider vẫn
BLOCKED_APPROVAL; không whole-feature acceptance. [Policy handoff,
file list và Tester steps](../../test-reports/FEAT-TN-001-password-policy-2026-10-26.md).

Cho phép một account hợp lệ đăng nhập độc lập từ Web hoặc Android App, nhận đúng loại session, tải profile và danh sách membership đang hoạt động, sau đó buộc chọn workspace trước khi tải dữ liệu workspace hoặc mở realtime/control.

Chức năng phải:

- không tiết lộ account có tồn tại hay không khi xác thực thất bại;
- không tin `role` hoặc `workspaceId` do client tự khai trong request login;
- giới hạn account có `mustChangePassword=true` vào đổi mật khẩu/logout;
- tạo session riêng cho từng client;
- ghi audit kết quả đăng nhập nhưng không ghi password/token;
- không trả hoặc tự tải resource của workspace chưa được chọn.

## 2. Truy vết nguồn yêu cầu

Nguồn phạm vi/workflow/acceptance: [`BA_IOT_PLATFORM_ANALYSIS_AND_DESIGN (1).md`](../../documents/BA_IOT_PLATFORM_ANALYSIS_AND_DESIGN%20%281%29.md). Nguồn contract/bàn giao/gate: [`IOT_PLATFORM_DEV_HANDOFF_SPEC.md`](../../documents/IOT_PLATFORM_DEV_HANDOFF_SPEC.md), theo AGENTS.md hiện hành. Quy tắc “BA duy nhất” trong chỉ mục đã được đồng bộ về hai nguồn này trong vòng review tiếp theo. Quyết định bổ sung tại mục 22 là thiết kế của lần review này, không gán ngược thành yêu cầu nguồn; G1 phải đưa vào OpenAPI/fixtures trước BUILD.

| Loại | Mã/nguồn | Nội dung áp dụng |
| --- | --- | --- |
| Feature | `FEAT-TN-001` | Đăng nhập Web/App |
| Functional requirement | `FR-TN-001` | Xác thực account và tạo session riêng theo client |
| Use case | `UC-TN-001` | Đăng nhập và quản lý phiên |
| Workflow | `WF-TN-001` | Đăng nhập Web/App |
| Acceptance | `AT-WF-001-01…03` | Session/membership, limited session, không tải dữ liệu workspace chưa chọn |
| Baseline test | `TS-TN-001` | Đăng nhập cùng account trên Web và App tạo session riêng |
| Business rules | `BR-TN-001`, `BR-TN-002`, `BR-TN-011` | Workspace scope, account/membership state, Web/App dùng chung backend |
| Validation | Core contract 23 + Password policy addendum (mục 1) | Email/password; login 9–128 Unicode codepoints, current 1–128, new 9–128 kèm chữ hoa/chữ thường/số ASCII; login rate limit |
| API contract | Core contract 35 và contract-auth | `POST /auth/login`, `GET /me`, `GET /workspaces` |
| Security/NFR | `NFR-TN-008…010`, `TH-TN-004` | Scope, session/secret protection, revoke behavior |
| UI | `WB-01`, `MB-01`, `WB-13/MB-11` | Login, đổi mật khẩu tạm, chọn workspace |

### Sai khác tài liệu đã xử lý

- `AT-WF-001-01` lịch sử còn ghi Web/Android/iOS. Theo cập nhật phạm vi 16/10/2026, acceptance của task này chỉ áp dụng Web và Android. Giá trị enum `IOS` trong hợp đồng nguồn chưa tự mất hiệu lực; cách backend xử lý giá trị đó là `OQ-AUTH-007`.
- Email normalization, cookie/CSRF, rate-limit key và wire DTO được trả lời tại mục 22; giả định hạ tầng tách khỏi bằng chứng đã kiểm chứng.
- Core mục 35 còn mô tả `/me` có role/preferences; contract-auth v3.0 chuyển role sang Membership. Không phát global role. Profile tối thiểu trong login không cho phép xóa preferences của `/me`; G1 phải hợp nhất với FEAT-TN-041.
- WF001 bước 5 bootstrap chung không ghi đè bước 3 giới hạn account tạm: Web limited gọi `/me` chỉ để đối soát context bằng 403 `PASSWORD_CHANGE_REQUIRED` sau login và khi reload; response không có profile/membership. Android limited dùng bearer và đi thẳng đổi mật khẩu, không có handshake Web.

## 3. Phạm vi trong task

- Contract request/response/error cho login và bootstrap sau login.
- Backend authentication, rate limit, password verification và session creation.
- Limited session khi bắt buộc đổi mật khẩu.
- Web login form, session bootstrap và điều hướng chọn workspace.
- Android login form, secure session storage và điều hướng chọn workspace.
- Audit/log/metrics có redaction.
- Unit, contract, integration, security, Web UI, Flutter widget và E2E tests cho chức năng đăng nhập.

## 4. Ngoài phạm vi task

- Logout/revoke session đầy đủ: `FEAT-TN-002`.
- Admin tạo/suspend membership: `FEAT-TN-003`, `FEAT-TN-066`.
- Đổi mật khẩu: `FEAT-TN-004`; task này chỉ tạo limited session và điều hướng đúng.
- Tạo workspace mới: `FEAT-TN-065`; task này chỉ điều hướng khi không có membership.
- Chuyển workspace khi đã đăng nhập: `FEAT-TN-067`.
- Cấp WebSocket ticket/realtime implementation; task này chỉ yêu cầu không mở realtime trước khi chọn workspace và đồng bộ snapshot.
- Social login, self-registration, email verification, forgot-password/email reset, SSO, MFA và iOS.

## 5. Actor và quyền

| Actor | Quyền/hành vi |
| --- | --- |
| Người dùng chưa đăng nhập | Được gọi `POST /auth/login` với email/password/clientType hợp lệ |
| Account `ACTIVE`, `mustChangePassword=false` | Nhận full session; được gọi `/me`, `/workspaces` |
| Account `ACTIVE`, `mustChangePassword=true` | Chỉ nhận limited session; chỉ được đổi mật khẩu hoặc logout |
| Account `DISABLED` | Không được tạo session; nhận lỗi xác thực chung |
| Client Web | Nhận session qua cookie HttpOnly theo security decision được duyệt |
| Client Android | Nhận session token theo contract và lưu trong secure storage |

Không có role `ADMIN/USER` trong request login. Role được lấy từ `Membership` sau khi account đã xác thực và workspace được chọn.

## 6. Tiền điều kiện và phụ thuộc

### Phụ thuộc bắt buộc trước khi code

- `( )` OpenAPI/error envelope đã có version và compatibility rule.
- `( )` Data model `User`, `Session`, `Workspace`, `Membership` và constraint cơ bản đã được duyệt.
- `( )` Password hashing/session digest strategy đã được quyết định; không hardcode secret.
- `( )` Web cookie/CSRF strategy và Android secure storage boundary đã được duyệt.
- `( )` `OQ-AUTH-007…011` đã chốt; response DTO, limited guard và workspace list fixture được duyệt cùng hai client.
- `( )` Hai workspace và account fixtures tối thiểu đã được định nghĩa, không chứa secret thật.
- `( )` Clock server/DB UTC và correlation ID convention đã được định nghĩa.

### Dữ liệu fixture tối thiểu

| Fixture | Trạng thái mong đợi |
| --- | --- |
| `user_active_multi_workspace` | ACTIVE, full session, membership ACTIVE ở workspace A và B |
| `user_active_no_membership` | ACTIVE, đăng nhập được nhưng chỉ thấy empty/create-workspace path |
| `user_password_change_required` | ACTIVE + `mustChangePassword=true`, limited session |
| `user_disabled` | DISABLED, không tạo session |
| `membership_suspended` | Không được trả như membership active để tải resource |

## 7. Khu vực/file dự kiến tác động

Đây là đường dẫn dự kiến; developer phải đối chiếu repository thực tế trước khi code.

- `contracts/openapi.yaml`
- `contracts/fixtures/auth/`
- `backend/migrations/` nếu schema session chưa tồn tại
- `backend/src/iam/`
- `backend/src/http/auth/`
- `backend/src/http/middleware/`
- `backend/tests/iam/`
- `web/src/features/auth/`
- `web/src/features/workspace/`
- `web/src/features/auth/__tests__/`
- `mobile/lib/features/auth/`
- `mobile/lib/features/workspace/`
- `mobile/test/features/auth/`
- `docs/test-reports/`

## 8. Hợp đồng API

**Quy ước đọc:** `Nguồn` là yêu cầu BA/handoff; serialization và quyết định bổ sung được trả lời tại mục 22. Nhãn đề xuất trong ví dụ phân biệt thiết kế plan với contract artifact phải khóa ở G1. Ví dụ JSON dưới đây là fixture **đề xuất**, chưa phải bằng chứng API đã triển khai. Mọi route có tiền tố `/api/v1`; request/response JSON không chứa dữ liệu thiết bị của workspace.

### 8.0 Ma trận input → xử lý → output theo boundary

| Boundary | Input cụ thể | Xử lý/quyền | Output quan sát được |
| --- | --- | --- | --- |
| Form Web/Android → client | `email`, `password` người dùng nhập | Kiểm tra required/format để hỗ trợ UX; giữ nguyên chuỗi password; gắn `clientType` từ ứng dụng, không cho người dùng sửa | Một JSON `LoginRequest`, trạng thái `submitting`; không ghi password vào URL, storage, analytics |
| Client → `POST /auth/login` | JSON ba field; HTTPS; không cần workspace header | Validate body, limit, rate limit, tìm `User`, verify hash, kiểm `status`/`mustChangePassword` | 200 và session transport đúng client, hoặc lỗi chuẩn; audit outcome; không trả membership resource |
| Backend → DB | `emailNormalized` do server tính, password chỉ ở bộ nhớ xử lý | Đọc `User`; ghi `Session(sessionId,userId,tokenDigest,clientType,expiresAt,revokedAt)` khi hợp lệ | Một session mới 24 h, không lưu token plaintext; không tạo session khi xác thực thất bại |
| Full session → `GET /me` | Cookie Web hoặc bearer Android từ phiên đã cấp | Kiểm session còn hiệu lực và account `ACTIVE` | Profile global của chính user; không role global, không password hash/digest |
| Full session → `GET /workspaces` | Cookie/bearer; `cursor?`, `limit?` | Tìm Membership của user hiện tại với status `ACTIVE`; lọc theo workspace còn khả dụng theo contract workspace | `{items,nextCursor}` gồm membership/workspace summary; không có device/dashboard/resource |
| Kết quả bootstrap → UI | Profile, danh sách workspace, limited flag | Limited đi màn đổi mật khẩu; full + list rỗng đi tạo workspace; full + list có item đi chọn workspace | Không query resource, mở realtime hoặc control trước khi chọn workspace và kiểm lại membership |

Không dùng `X-Workspace-Id` cho ba route toàn cục này. Nếu client gửi `role`, `workspaceId`, `userId`, `permissions` trong body login, server từ chối unknown field theo quy tắc input boundary của BA; tuyệt đối không dùng chúng làm authority.

### 8.1 `POST /api/v1/auth/login`

#### Input wire và validation

| Field | Kiểu | Bắt buộc | Quy tắc và test biên |
| --- | --- | --- | --- |
| `email` | JSON string | Có, không `null`/rỗng | Server kiểm email hợp lệ rồi tính `emailNormalized` bằng **cùng quy tắc** đã chốt cho DB unique key; không trả account existence. Max length/Unicode/case-fold/whitespace là `OQ-AUTH-001`. |
| `password` | JSON string | Có, không `null` | Login 9–128 Unicode codepoints theo Password policy addendum ở mục 1; không áp composition mới khi verify credential cũ. Mật khẩu mới 9–128, có chữ hoa, chữ thường và số ASCII 0–9; current password 1–128. Giữ nguyên chuỗi nhập, gồm khoảng trắng đầu/cuối; không trim/normalize/coerce. Không echo vào field error. |
| `clientType` | JSON enum | Có | Web gửi `WEB`, Android gửi `ANDROID` từ client code; giá trị `IOS` có trong enum nguồn nhưng iOS client nằm ngoài scope, chính sách backend với `IOS` là `OQ-AUTH-007`. |

Request `Content-Type: application/json`, body tối đa 64 KiB theo quy tắc REST chung. Không nhận JSON sai cú pháp, sai kiểu, thiếu field, `null` hoặc unknown field; không tự chuyển số/boolean thành chuỗi. `password` không xuất hiện trong query/path/header. Mapping 400/415/413/422 và field-error path theo OQ-AUTH-008; cả backend và client phải dùng cùng OpenAPI đã duyệt.

```json
{"email":"member@example.test","password":"<synthetic-9-128-codepoint-secret>","clientType":"WEB"}
```

Fixture chỉ minh họa tên field; password trong test phải là giá trị tổng hợp, không sao chép credential thật.

#### Output thành công và side effect

| Client | HTTP/transport theo nguồn | Body tối thiểu đề xuất chốt | Không được xuất hiện |
| --- | --- | --- | --- |
| Web | `200`, `Set-Cookie` phiên `Secure; HttpOnly; SameSite` theo deployment decision | `me{id,email,mustChangePassword}`, `expiresAt`, `limited` | Token/session secret trong JSON, URL, JavaScript storage |
| Android | `200`, bearer token trả qua HTTPS một lần | Cùng `me`, `expiresAt`, `limited`, thêm `token` | Cookie Web, password hash, token digest |

`expiresAt` là UTC RFC3339, bằng mốc tạo session theo clock server/DB cộng 24 giờ; `limited=true` khi `mustChangePassword=true`. Tên `me`, `limited`, `token` và requiredness `expiresAt` trên Web là **đề xuất serialization** vì BA chỉ nói “me summary”, “limited flag”, “App token/expiresAt”; chốt tại `OQ-AUTH-009` và đóng băng trong OpenAPI/fixture trước code. Không thêm `sessionMode` enum vì nguồn không định nghĩa. Response có `Cache-Control: no-store` theo kiểm soát bảo mật đề xuất; headers cụ thể kiểm trong contract test.

Ví dụ body Web sau khi schema được duyệt (giá trị tổng hợp):

```json
{"me":{"id":"11111111-1111-4111-8111-111111111111","email":"member@example.test","mustChangePassword":false},"expiresAt":"2026-10-18T00:00:00Z","limited":false}
```

Android cùng semantic output và thêm `token` là secret chỉ xuất trong response thành công. Client parse runtime, không suy thành công chỉ từ status. JavaScript không đọc được HttpOnly cookie/Set-Cookie: Web full xác minh `/me` cùng ID/context với login body; Web limited gọi `/me` kèm context vừa cấp và chỉ nhận 403 `PASSWORD_CHANGE_REQUIRED` có response context trùng, rồi mới mở màn đổi mật khẩu. Browser E2E kiểm cookie attributes. Android limited đi thẳng đổi mật khẩu sau khi lưu bearer an toàn; không gọi `/me` để làm handshake Web. Backend tạo session riêng cho mỗi login hợp lệ; audit result `SUCCESS`, `AUTH_INVALID` hoặc `RATE_LIMITED` không chứa credential. `POST /auth/login` không dùng `Idempotency-Key`/cache response bí mật.

Ví dụ Android `limited=true` (token chỉ là placeholder trong tài liệu, không dùng làm credential):

```json
{"me":{"id":"22222222-2222-4222-8222-222222222222","email":"temporary@example.test","mustChangePassword":true},"expiresAt":"2026-10-18T00:00:00Z","limited":true,"token":"<synthetic-token>"}
```

#### Output thất bại

- Sai email/password hoặc `User.status=DISABLED`: `401 AUTH_INVALID` với cùng public code/message/shape, không `Set-Cookie`/token, không insert `Session`.
- Vượt 5 lần sai trong 15 phút: `429 RATE_LIMITED`, có `Retry-After`; không tự gửi lại login.
- Body không hợp lệ: `VALIDATION_ERROR`; field error chỉ nêu path/code an toàn, không lặp email/password value.
- DB/auth dependency lỗi trước khi phát credential: `503 SERVICE_UNAVAILABLE`; không báo login thành công và không phát credential của transaction chưa commit.

### 8.2 `GET /api/v1/me`

Input: không body, không workspace header bắt buộc; credential từ cookie Web hoặc bearer Android. Server xác minh `Session.expiresAt/revokedAt`, user hiện tại `ACTIVE`, trả chính chủ. `200` profile toàn cục giữ `{id,email,mustChangePassword}`; khi tích hợp041, bổ sung required `displayTimezone,preferencesRevision` theo mặc định UTC/1 và policy041; không có global `role`, `Membership`, `passwordHash`, `tokenDigest`. Login me summary vẫn ba field; GET /me projection tích hợp041 gồm năm field trên theo OQ-AUTH-009; chuyển thành schema đầy đủ ở G1. Web limited sau login gọi `/me` kèm `X-Auth-Context-Id` vừa cấp: chỉ `403 PASSWORD_CHANGE_REQUIRED` với response context trùng mới xác nhận phiên để mở màn đổi mật khẩu/logout; không trả profile/membership. `/me` Web không header chỉ là discovery khi UI khóa, không xác nhận login intent. Android limited không cần handshake Web và đi thẳng đổi mật khẩu sau khi lưu bearer. Chưa có credential/expired: `401 SESSION_EXPIRED` hoặc mã 401 đã chuẩn hóa theo OpenAPI; không trả profile. `Cache-Control: no-store`.

### 8.3 `GET /api/v1/workspaces`

Input: full session; query `cursor?` và `limit?` (`limit` mặc định 20, hợp lệ 1–100; cursor ký và bound scope/filter/sort theo BA). Không cần `X-Workspace-Id`. Client phân trang theo nhu cầu, được chọn item đã tải có recheck server; không buộc tải toàn bộ. Chỉ kết luận rỗng khi request thành công có `items=[]`, `nextCursor=null`; lỗi/trang rỗng còn cursor không phải empty state.

Output `200` theo envelope list chung `{items:[],nextCursor:null}`. Mỗi item là summary từ `Membership` `ACTIVE` của account và `Workspace`; DTO tối thiểu **đề xuất chốt** `{id,name,status,role,revision}` (trong đó `id` là workspace UUID, `role` thuộc membership, `revision` của workspace). Chốt tên `id` theo OQ-AUTH-009; không thêm membershipStatus trong picker chỉ có ACTIVE, không để từng client tự đoán. Không chứa thiết bị, dashboard, command hoặc workspace khác. Với 0 membership: chính xác `{"items":[],"nextCursor":null}`; UI hiển thị đường tạo workspace. Membership `SUSPENDED/REMOVED` không là quyền vận hành; admin historical view cần filter riêng ngoài flow login.

Ví dụ một trang list theo DTO đề xuất (UUID và tên tổng hợp):

```json
{"items":[{"id":"33333333-3333-4333-8333-333333333333","name":"Workspace A","status":"ACTIVE","role":"USER","revision":1}],"nextCursor":null}
```

Nếu membership bị đổi sau khi list nhưng trước khi chọn, route workspace kế tiếp resolve lại `Membership` và `authzVersion`; list chỉ để chọn, không cấp quyền. Cursor sai/hết hiệu lực trả `400 CURSOR_INVALID` theo contract chung; session expired trả 401; limited session trả `403 PASSWORD_CHANGE_REQUIRED` theo guard chung. Mapping danh sách với `Workspace.status=SUSPENDED/ARCHIVED` theo OQ-AUTH-010, không âm thầm hiển thị như workspace vận hành.

### 8.4 Error envelope

```json
{
  "error": {
    "code": "AUTH_INVALID",
    "message": "Thông tin đăng nhập không hợp lệ.",
    "details": {},
    "correlationId": "corr_example"
  }
}
```

`correlationId` nằm **bên trong** `error` theo Core contract 36. `details.fieldErrors[]` dùng `path/code` cho validation; không chứa giá trị input. Không trả stack trace, password reason chi tiết, account existence, password hash, session digest hoặc secret configuration. Cùng public auth error shape/message cho unknown email, sai password và DISABLED; correlation ID có thể khác vì là request khác.

## 9. Data model và invariant

### `User`

- `status`: `ACTIVE` hoặc `DISABLED`.
- `mustChangePassword`: boolean.
- Password chỉ lưu protected hash theo decision được duyệt.
- Email uniqueness và normalization phải nhất quán với unique constraint.

### `Session`

- Mỗi lần login thành công tạo một session riêng.
- BA chốt các field `sessionId,userId,tokenDigest,clientType,expiresAt,revokedAt`; trạng thái limited phải được suy ra từ `User.mustChangePassword` hiện tại hoặc persistence được duyệt tại `OQ-AUTH-011`, không tự thêm `sessionMode` vào schema.
- Chỉ lưu `tokenDigest`/verifier, không lưu raw token có thể dùng lại.
- Session 24 giờ theo baseline.
- Limited session không được nâng quyền chỉ bằng request client.

### `Membership`

- Khóa nghiệp vụ `(workspaceId, userId)`.
- Chỉ membership `ACTIVE` được trả trong bootstrap workspace.
- Role `ADMIN/USER`, `authzVersion` và `revision` không lấy từ request login.

### Invariant bắt buộc

1. Login thành công không đồng nghĩa đã chọn workspace.
2. Chưa chọn workspace thì không query resource workspace.
3. Full session không vượt quyền membership hiện tại.
4. Limited session không được gọi device, rule, dashboard, command hoặc realtime.
5. Hai login đồng thời tạo hai session riêng, không ghi đè session còn lại.
6. Audit đăng nhập không chứa credential.

## 10. Luồng chính

### 10.1 Web

1. Người dùng nhập email/password; form chỉ kiểm required/format hỗ trợ UX.
2. Web gửi `POST /auth/login` qua HTTPS với `clientType=WEB`.
3. Backend áp dụng rate limit, chuẩn hóa email theo decision, tìm account và verify password hash.
4. Backend không trả lỗi khác nhau giữa account không tồn tại, sai password và account disabled.
5. Account ACTIVE và password đúng tạo **đúng một** session 24 giờ: limited khi `mustChangePassword=true`, ngược lại full; audit cùng commit.
6. Không chạy tiếp nhánh full sau nhánh limited; recheck account/password tại điểm commit theo mục 14.1.
7. Web gọi `/me` kèm context từ login 200 ở cả hai nhánh. Limited chỉ khi nhận 403 `PASSWORD_CHANGE_REQUIRED` với response context trùng mới ghi `accepted` và mở màn đổi mật khẩu; không gọi `/workspaces` hay resource. Full chỉ khi nhận 200, `me.id` và response context trùng mới ghi `accepted` và gọi `/workspaces`. Response thiếu/sai context, 401, network/503 hoặc 200 ở nhánh limited giữ UI khóa và đi recovery theo mục 13.1.
8. Nếu có membership, Web hiển thị workspace picker; chưa tải resource.
9. Sau khi người dùng chọn workspace, client mới bắt đầu bootstrap snapshot của flow khác.

### 10.2 Android

1. Người dùng nhập email/password; App không ghi input vào log/analytics.
2. App gửi `POST /auth/login` qua HTTPS với `clientType=ANDROID`.
3. Backend xử lý cùng policy account/session/limited như Web; App dùng bearer và không có bước đối soát cookie/context Web.
4. App lưu credential trong secure storage sau response thành công.
5. Nếu session limited, App đi thẳng tới màn đổi mật khẩu, không gọi `/me`/`/workspaces`; nếu full session, App gọi `/me` và `/workspaces`.
6. App hiển thị yêu cầu đổi password, workspace picker hoặc create-workspace empty state phù hợp.
7. App không mở control/realtime trước khi workspace được chọn và snapshot được đồng bộ.

## 11. Luồng thay thế, lỗi và phục hồi

| Mã | Trường hợp | Hành vi bắt buộc | Retry |
| --- | --- | --- | --- |
| `E1` | Email/password sai hoặc account DISABLED | `401 AUTH_INVALID`, message chung; không tạo session | Chỉ do người dùng chủ động |
| `E2` | Quá 5 lần sai/15 phút | `429 RATE_LIMITED` + `Retry-After` | Không tự động lặp |
| `E3` | `mustChangePassword=true` | Tạo limited session; route nghiệp vụ trả `403 PASSWORD_CHANGE_REQUIRED` | Đi tới đổi password |
| `E4` | Không có membership ACTIVE | Login thành công; `/workspaces` rỗng; hiển thị create-workspace path | Không fallback cache cũ |
| `E5` | Backend/DB lỗi trước commit session | Không phát credential usable; trả 503 theo error model | Retry có chủ đích |
| `E6` | Login commit thành công nhưng response mất hoặc Set-Cookie đến muộn | Web giữ `loginUnknown` qua reload trong marker không secret mục 13.1; không tự nhận cookie A/B là kết quả intent. Người dùng chỉ được chủ động xác nhận phiên hiện tại sau `/me` discovery hoặc submit mới. Có body hợp lệ thì Web đối soát `me.id` và `X-Auth-Context-Id` qua `/me` trước khi mở UI; limited cũng kiểm context qua 403 đúng code. Android mất token vẫn ở login. | Không auto retry login; response cũ không mở protected flow |
| `E7` | App/Web giữ cache account trước | Không hiển thị protected cache trước khi xác định account/context hiện tại | Sync lại |
| `E8` | Membership đổi giữa login và chọn workspace | Resolve lại membership khi bootstrap workspace | Không dùng summary cũ làm quyền |

## 12. Validation và error mapping

| Điều kiện | HTTP | Code | UI/Client behavior |
| --- | --- | --- | --- |
| JSON hỏng/duplicate key; sai Content-Type; quá 64 KiB; field không hợp lệ | 400; 415; 413; 422 tương ứng | `VALIDATION_ERROR` | Mapping/path cụ thể OQ-AUTH-008; không echo input |
| Sai credential/account disabled | 401 | `AUTH_INVALID` | Message chung, không phân biệt nguyên nhân |
| Session hết hạn ở `/me` | 401 | `SESSION_EXPIRED` | Xóa trạng thái phiên và về login |
| Limited session gọi resource | 403 | `PASSWORD_CHANGE_REQUIRED` | Điều hướng đổi password |
| Rate limit | 429 | `RATE_LIMITED` | Tôn trọng `Retry-After` |
| Dependency không sẵn sàng | 503 | `SERVICE_UNAVAILABLE` | Cho retry thủ công; không báo thành công |

## 13. Bảo mật và quyền riêng tư

### Trust boundary và quyền

| Boundary / nguy cơ | Kiểm soát bắt buộc | Bằng chứng cần có |
| --- | --- | --- |
| Form/JSON không tin cậy → backend: injection, coercion, payload quá lớn | JSON strict schema; body ≤64 KiB; validate type/required/length; unknown fields reject; query DB dùng bound parameter; password giữ nguyên, email chuẩn hóa một chỗ | Contract tests thiếu/null/sai kiểu/unknown/oversize; test không thể tự gán role/workspace |
| Unknown email/sai password/DISABLED → public error: dò tài khoản | Cùng `401 AUTH_INVALID` và cùng thông điệp công khai; không nêu trạng thái account; rate limit 5 sai/15 phút; không log email plaintext | So body/code/status; thử request đồng thời, hết cửa sổ và proxy spoof |
| Backend → DB: đánh cắp session | Password chỉ lưu hash hiện đại có cost được duyệt; session chỉ lưu token digest; tạo token bằng nguồn ngẫu nhiên mật mã; không emit trước commit | DB fixture và log scan không có plaintext token/password; token khác nhau mỗi lần login |
| Web browser → backend: cookie theft/CSRF | HTTPS; cookie `Secure`, `HttpOnly`, `SameSite` theo origin đã duyệt; phạm vi `Domain/Path` tối thiểu; CSRF token cho mutation dùng cookie; CORS allowlist origin thật, credentials policy tương ứng; không đưa token Web vào JavaScript/localStorage | Inspect `Set-Cookie`, preflight/origin/CSRF tests trên môi trường mục tiêu |
| Android → backend: token lộ qua thiết bị/log | HTTPS kiểm certificate; lưu token vào OS secure storage; không ghi vào plain preferences, backup, URL, crash/analytics/debug log; không giữ password để retry | Test storage failure, app restart, backup/debug/log scan |
| Full/limited session → workspace routes: vượt quyền | Guard session/current account; limited chỉ đổi mật khẩu/logout; full vẫn phải resolve Membership `ACTIVE` và workspace scope ở server, kiểm lại sau chọn | Limited `/devices` = `403 PASSWORD_CHANGE_REQUIRED`; cross-workspace request không trả data; membership stale bị chặn |

Không tin `X-Forwarded-For` hoặc header định danh client từ Internet; chỉ dùng IP do trusted proxy đã cấu hình cung cấp cho rate limit. Mọi cookie/bearer/API output bí mật dùng `Cache-Control: no-store` ở nơi phù hợp. Chặn response body/log chứa stack trace, SQL, raw request, password, token, cookie, `Authorization` header, hash/digest. Audit retention theo baseline 30 ngày; retention của application log/metric chưa có trong tài liệu và không tự đặt số mới.

### Ma trận quyền tối thiểu

| Principal | Login | `/me` | `/workspaces` | `/auth/password`, `/auth/logout` | Resource workspace |
| --- | --- | --- | --- | --- | --- |
| Anonymous | Được, có rate limit | 401 | 401 | Theo contract từng route, không cấp quyền mặc định | 401 |
| Full session còn hạn + User ACTIVE | Không cần login lại | Chính chủ | Chỉ ACTIVE memberships | Chính chủ | Chỉ sau khi server xác minh workspace/membership/resource |
| Limited session | Không cần login lại | Web: 403 `PASSWORD_CHANGE_REQUIRED` kèm context/CSRF để đối soát hoặc discovery khi UI khóa, không profile; Android: không cần gọi trong login flow | 403 `PASSWORD_CHANGE_REQUIRED` | Được | 403 `PASSWORD_CHANGE_REQUIRED` |
| Expired/revoked/disabled | Có thể login lại nếu account ACTIVE | 401 | 401 | Không dựa vào phiên cũ | 401 |

`/auth/password` và `/auth/logout` thuộc feature khác; hàng trên chỉ mô tả guard cần giữ tương thích. `/me` limited trả 403 PASSWORD_CHANGE_REQUIRED, không profile/membership; metadata CSRF phục hồi hai hành động được phép theo mục 13.1.

### 13.1 Cookie, CSRF và phục hồi limited

Thiết kế bổ sung theo giả định Web/API cùng HTTPS origin (OQ-AUTH-002):

- Cookie `iot_session`: `Secure; HttpOnly; SameSite=Lax; Path=/api/v1`, không Domain, Max-Age không quá thời gian phiên còn lại (tối đa 86.400 giây). DB expiry/revoke là authority; không sliding refresh. Logout xóa đúng name/path theo 002.
- Server cấp CSRF token bound session qua response header `X-CSRF-Token` khi login Web thành công và GET /me có session hợp lệ. Full trả 200; limited trả 403 PASSWORD_CHANGE_REQUIRED không profile, nhưng có header này để reload vẫn đổi password/logout được. Token CSRF không phải bearer credential, chỉ giữ memory, không log; response no-store.
- Mutation cookie, kể cả password/logout, cần exact same-origin và CSRF header hợp lệ; sai/thiếu trả 403 CSRF_INVALID trước side effect. Login chưa có phiên nên dùng JSON strict + Origin đúng origin Web; nếu thiếu Origin chỉ chấp nhận Referer HTTPS cùng origin, thiếu cả hai thì WEB login bị chặn.
- Browser request có Origin/Fetch Metadata chịu origin policy kể cả khai ANDROID/IOS. clientType không là chứng thực platform. App bearer không dùng ambient cookie; mixed cookie + bearer trả 400 VALIDATION_ERROR, không chọn ngầm identity. App login không phát cookie. Không bật credential CORS cho origin ngoài Web được cấu hình.
- Reload/cold start ưu tiên `logoutPending` của002, rồi `loginPending/loginUnknown`, sau đó mới xét context `accepted` theo protocol bên dưới. Chỉ context `accepted` khớp cookie qua GET /me mới tự bootstrap; khi không có context đã chấp nhận, 200/403 chỉ là phiên hiện tại cần người dùng xác nhận, 401 về login, network/503 giữ UI khóa. `/me` discovery không chứng minh login intent mất response đã thành công.
- Return URL chỉ route nội bộ allowlist và vẫn chọn/recheck workspace. Không lưu password để tiếp tục sau reload.

#### Protocol Web chung cho login, logout và đổi account (REV-AUTH-001/002)

- IAM tạo `authContextId` UUID ngẫu nhiên mới cho từng Session Web, tách khỏi cookie secret và DB `sessionId`. `X-Auth-Context-Id` trên login Web thành công và GET /me full/limited là định danh đối soát **không phải credential hay quyền**. Client có thể giữ ID này trong marker cùng origin; không lưu cookie, bearer, CSRF, email hoặc password. Backend vẫn xác thực cookie, trạng thái User/Session và membership độc lập với ID do client gửi.
- Sau khi resolve cookie, trước limited/workspace/resource guard và trước side effect, middleware so `X-Auth-Context-Id` request với Session hiện tại trên mọi Web protected request, kể cả GET và mutation. Thiếu/khác trả `409 AUTH_CONTEXT_MISMATCH`, no-store, không profile/resource/side effect; App bearer không dùng header Web. Ngoại lệ duy nhất: GET /me **discovery** không gửi header khi UI đang khóa, để biết cookie hiện tại; response không tự mở protected UI. GET /me có header thì phải kiểm như request khác. Mutation Web vẫn cần Origin và CSRF bound cùng session.
- Web auth coordinator do FEAT001 sở hữu; FEAT002 dùng cùng coordinator cho logout và `logoutPending`. Trước login/logout/account switch, ghi marker cùng origin không secret gồm `intentId`, `state=pending` và context đã chấp nhận nếu có; sau đó báo các tab khóa protected UI, hủy/loại response resource cũ và tăng generation. Không dùng broadcast/generation/AbortController để suy cookie chưa đổi. Khi storage hoặc điều phối tab không khả dụng, không bắt đầu auth mutation mới; hiển thị lỗi phục hồi và giữ UI khóa. Không ghi secret vào marker hoặc kênh liên tab.
- `logoutPending` có ưu tiên cao nhất: đối soát đúng context của phiên cần logout theo002 trước khi login account mới; context khác thì không gửi logout cũ bằng cookie mới. Với login response mất/timeout/commit UNKNOWN, giữ `loginUnknown` bền qua reload, không auto retry POST. Một submit mới chỉ do người dùng chủ động; callback cũ không được xóa marker intent mới. Người dùng có thể chọn “Tiếp tục phiên hiện tại” sau GET /me discovery và nhìn rõ account full hiện tại (limited chỉ nêu phiên đổi mật khẩu), hoặc chọn đăng nhập lại; xác nhận chỉ ghi context nhận từ `/me`, không giả intent cũ đã thành công.
- Với login 200 đã parse, Web giữ `authContextId` và CSRF trong RAM, gọi GET /me kèm header context; full phải khớp `me.id` trong body login và response context, limited chỉ xác nhận khi nhận 403 PASSWORD_CHANGE_REQUIRED cùng response context. Thiếu/sai response context, 200 ở nhánh limited, 401, 409 hoặc network/503 đều giữ UI khóa/recovery, không ghi marker `accepted`. Chỉ sau đối soát hợp lệ mới ghi `accepted` và mở picker/đổi mật khẩu; limited tuyệt đối không gọi `/workspaces` hoặc resource. Sau reload, marker `accepted` dùng GET /me kèm context; mismatch/401/409/503 khóa UI, xóa protected cache, không tự chấp nhận account khác. Không có marker thì GET /me discovery chỉ đưa tới bước xác nhận chủ động. Android bearer không dùng handshake này.
- Response A đến sau B có thể ghi đè cookie dù callback A bị bỏ. Khi B đã accepted, request tiếp theo mang context B nên cookie A bị server từ chối 409 trước dữ liệu; tab khóa UI/cache và yêu cầu phục hồi. Các tab khác cũng khóa khi nhận marker/broadcast đổi intent, kiểm context khi focus/resume và trước request bảo vệ. Nếu thông báo liên tab bị trễ, server fence vẫn chặn request dùng cookie khác context; dữ liệu đã hiển thị trước sự kiện được xóa khi phát hiện mismatch. Không tự revoke các session Web/App độc lập của account.
- Marker được xóa/chuyển `accepted` chỉ khi intent hiện tại đã đối soát; 401/429/422 chắc chắn không cấp credential vẫn giữ UI login và cần xác nhận lại phiên cũ nếu muốn resume. `loginUnknown` không hết hạn theo timer để tự bật UI; user có thể chủ động bỏ intent, nhưng mỗi lần resume phải đối soát context/cookie. FEAT002 giữ quy tắc không replay logout cũ bằng cookie của phiên khác. API/Web/Mobile owner review header/error/fixture mới ở CP-01; browser race evidence ở START-05/CP-03.

### 13.2 Chống dò account và abuse

Unknown email dùng dummy hash cùng thuật toán/cost với account thật; account DISABLED cũng verify tương đương trước lỗi chung. Không early return tạo đường phản hồi nhanh rõ rệt; đo phân bố latency unknown/wrong/disabled, không hứa thời gian mạng bằng nhau. Hash worker có concurrency/queue/timeout hữu hạn, không chặn async executor.

Rate-limit chính gắn normalized email digest, không ghép IP làm guard duy nhất; dùng cả email chưa có account. Đổi IP/clientType không reset budget. Trusted IP phục vụ kiểm soát abuse/tải ingress, không tin X-Forwarded-For do Internet tự khai. Giới hạn account vẫn có nguy cơ khóa tạm do kẻ khác thử sai; cửa sổ hữu hạn và không gia hạn khi bị chặn, không tự thêm MFA/captcha/unlock ngoài scope.

## 14. Concurrency, idempotency và transaction

- Login không dùng `Idempotency-Key`; mỗi submit hợp lệ là một login intent mới và có thể tạo session riêng. Không cache response chứa token/cookie theo idempotency chung.
- Client khóa double-submit trong lúc request đang xử lý; backend vẫn phải an toàn khi nhận concurrent requests.
- Session row và audit result có transaction boundary rõ; nếu cùng DB thì ghi nhất quán theo thiết kế. Khi insert session thất bại không phát credential; audit thất bại không được làm lộ password và phải có quy tắc fail-open/fail-closed chốt tại `OQ-AUTH-012`.
- Rate-limit update phải atomic và dùng nguồn trạng thái dùng chung giữa các instance nếu triển khai nhiều instance; không dùng bộ đếm process-local làm hàng rào bảo mật. Không thêm Redis khi chưa được duyệt; cách lưu trong nền tảng hiện có là `OQ-AUTH-004`.
- Hai login Web/Android đồng thời không revoke hoặc ghi đè nhau.
- Không dùng membership summary cache làm authorization cho request sau.

### 14.1 Điểm tuần tự hóa và lỗi commit

- PostgreSQL hiện có giữ counter theo keyed digest email canonical, không email/IP thô. Cửa sổ cố định 15 phút từ failure đầu; failure 1–5 trả 401; request khi đã đủ 5 trả 429 trước verify, kể cả password đúng. Retry-After là số giây nguyên làm tròn lên tới cuối cửa sổ, tối thiểu 1. Success không xóa failure trong cửa sổ; validation/503 không tính sai password; 429 không gia hạn. Tại thời điểm hết cửa sổ cho thử lại.
- Serialize check → verify → update failure/session decision theo key bằng DB lock chung các instance; khóa counter trước User theo cùng thứ tự, không khóa toàn bảng. Thiết kế đơn giản dùng transaction/row lock theo key với hash worker, DB pool và lock timeout hữu hạn. Sáu request sai đồng thời cho năm 401 và một 429 khi không lỗi hạ tầng. Timeout/overload trả 503, không giả AUTH_INVALID. G1 đo thời gian giữ khóa và budget; nếu không đạt, reservation design thay thế phải được review và giữ invariant.
- Sau verify, khóa/recheck User trong transaction cấp phiên: status, password hash và mustChangePassword vẫn khớp bản đã dùng. Password vừa đổi/reset hoặc account disabled thì không cấp phiên từ credential cũ. FEAT004/vận hành phải khóa cùng User trước update/revoke: login commit trước thì phiên bị revoke sau; thay đổi commit trước thì login cũ bị từ chối. Không tự retry với password cũ.
- Session + audit success cùng transaction, chỉ phát cookie/token sau commit xác nhận; audit success fail thì rollback/503, không credential. Với login bị từ chối, counter limiter phải commit trước401/429 nhưng audit failure là ngoại lệ WF040 E2: ghi operational metric khi sink unavailable, vẫn deny authentication, không rollback counter đã ghi chỉ vì audit. Nếu audit cùng DB, transaction/savepoint boundary phải bảo vệ counter khỏi audit insert failure; DB/limiter không thể commit thì503 fail-closed, không giả đã đếm failure. Exporter log/metric lỗi không đảo transaction đã commit hoặc cấp quyền.
- Mất ACK commit DB là kết quả chưa biết: 503/đóng request, không emit secret, không tự tạo phiên thứ hai. Có thể tồn tại orphan hết hạn trong 24 h; không khẳng định mọi 503 đều có 0 session.
- Audit login là global, không gán workspace tùy ý và không cho Admin workspace xem login history global người khác. Success có actorId đã xác thực; failure chỉ correlation/outcome chung. Dọn counter hết hạn theo batch; không tự thêm session cap/revoke phiên độc lập.

## 15. Quan sát hệ thống và audit

Mục tiêu vận hành: từ `correlationId` truy được login thất bại thuộc validation, credential, rate limit hay DB; biết session có được tạo không; đo được tỉ lệ lỗi và latency mà không xem payload bí mật. Dùng cơ chế log/metric hiện có trong dự án, không thêm dịch vụ quan sát mới.

### Event log cấu trúc đề xuất

| Event name | Mức | Thời điểm | Field cho phép | Field cấm |
| --- | --- | --- | --- | --- |
| `auth.login.received` | INFO | Sau khi tạo/đọc correlation ID và phân loại client | `timestamp`, `correlationId`, `entryPoint=http`, `route=/auth/login`, `clientType` nếu enum hợp lệ | Body, email, password, header raw, IP raw |
| `auth.login.rejected` | INFO/WARN | Validation, credential hoặc rate limit | Field chung + `reasonCode` bounded (`VALIDATION_ERROR`, `AUTH_INVALID`, `RATE_LIMITED`), `httpStatus`, `durationMs` | Phân biệt unknown email/sai password/DISABLED qua public log reason có thể lộ; không log giá trị field lỗi |
| `auth.login.succeeded` | INFO | Session commit thành công | Field chung + `limited` boolean, `durationMs`; userId/sessionId chỉ ở audit được bảo vệ theo OQ013 | Token/cookie/tokenDigest/passwordHash/email |
| `auth.login.dependency_failed` | ERROR | DB/hasher/session store lỗi | Field chung + `component` từ allowlist, `reasonCode=SERVICE_UNAVAILABLE`, `durationMs` | SQL text có parameter, stack chứa payload, connection secret |
| `auth.bootstrap.rejected` | WARN | `/me`/`/workspaces` bị chặn | `correlationId`, `route`, `reasonCode`, `httpStatus` | Cookie/bearer, membership list, email |

`correlationId` được tạo server-side nếu thiếu; nếu nhận từ client thì validate format/length trước khi đưa vào log hoặc echo trong error. Dùng một ID xuyên HTTP handler/service/repository và audit; không gắn nó vào URL chứa secret. Không log mỗi bước password hash riêng để tránh vô tình tạo timing side channel. Với `AUTH_INVALID`, log/audit reason công khai gộp chung; nếu cần reason nội bộ để điều tra, quyền truy cập và retention phải được security owner chốt trước (`OQ-AUTH-013`).

### Audit nghiệp vụ

Ghi `LOGIN_SUCCEEDED`, `LOGIN_REJECTED`, `LOGIN_RATE_LIMITED` (tên event **đề xuất**; map vào catalog audit hiện có trước code), timestamp UTC, `clientType`, result/reason code và `correlationId`. `actorId` chỉ ở success đã xác thực; failure để null; không lưu email/password/token/raw body. Nếu audit ghi cùng DB với session, commit nguyên tử khi đăng nhập thành công; lỗi audit trước commit làm gì là `OQ-AUTH-012`. Kiểm retention audit 30 ngày theo tài liệu nguồn, không xóa evidence sớm hơn policy được duyệt.

### Metrics và cảnh báo

| Metric đề xuất | Kiểu | Label bounded | Ý nghĩa kiểm chứng |
| --- | --- | --- | --- |
| `auth_login_attempts_total` | counter | `clientType=WEB/ANDROID/IOS/UNKNOWN`, `outcome=SUCCESS/AUTH_INVALID/RATE_LIMITED/VALIDATION_ERROR/DEPENDENCY_ERROR` | Tỷ lệ lỗi và rate limit theo client |
| `auth_login_duration_seconds` | histogram | `clientType`, `outcome` | p95/p99 và thay đổi sau release |
| `auth_session_create_failures_total` | counter | `clientType`, `reasonCode` allowlist | DB/session store đang hỏng |
| `auth_bootstrap_failures_total` | counter | `route` thuộc `/me` hoặc `/workspaces`, `reasonCode` allowlist | Login thành công nhưng bootstrap lỗi |

Không dùng email, userId, sessionId, IP, workspaceId hay correlationId làm metric label. Cảnh báo cần gắn với hiện tượng có hành động: tăng `DEPENDENCY_ERROR`, session creation failure hoặc bootstrap failure; threshold chỉ chốt sau baseline đo thật, không đặt số tùy ý. Runbook ghi cách tra correlation ID, kiểm DB/session store và kiểm redaction; telemetry mất cũng phải có tín hiệu kiểm tra. Test phải chứng minh event/metric phát đúng một lần theo outcome và quét để chứng minh không có secret.

## 16. Yêu cầu UI Web

### Input → output UI chung cho Web/Android

| Input/kết quả API | Output trên màn hình | Request tiếp theo |
| --- | --- | --- |
| Form thiếu email/password hoặc sai format email | Field error an toàn, giữ email; password chỉ ở bộ nhớ form đến khi sửa/gửi, không đưa vào log | Chưa gửi login |
| `401 AUTH_INVALID` | Một thông báo chung “Thông tin đăng nhập không hợp lệ”; không tiết lộ unknown/disabled | Chờ người dùng sửa và submit lại |
| `429 RATE_LIMITED` + `Retry-After` | Thông báo phải đợi; disable submit theo giá trị server, không tự đếm thay server | Không auto retry |
| `503 SERVICE_UNAVAILABLE` hoặc network offline | Thông báo dịch vụ/kết nối; không báo đã đăng nhập | Chỉ retry khi người dùng chủ động |
| `200 limited=true` | Web giữ màn loading/khóa protected UI đến khi `/me` kèm context trả 403 đúng code và context trùng, rồi mới mở màn đổi password; Android mở sau khi lưu bearer an toàn | Web chỉ gọi `/me` để đối soát, sau đó `/auth/password` hoặc logout; Android không có handshake Web; không gọi workspace/resource |
| Web limited `/me` 409, 401, network/503, thiếu/sai response context hoặc trả 200 | Khóa protected UI, thông báo lỗi bootstrap/phục hồi; không ghi `accepted`, không hiển thị profile/membership | GET retry chỉ theo thao tác người dùng và cùng intent/context còn hợp lệ; không tự POST login |
| `200 limited=false`, `/me` thành công, `/workspaces` list rỗng | Màn trống có đường tạo workspace | Không gọi resource của workspace cũ |
| `200 limited=false`, list có A/B | Màn chọn workspace, tên/role đúng từng item | Chỉ sau lựa chọn mới bootstrap resource và recheck quyền |
| Body sai schema/thiếu token Android, hoặc full Web `/me` trả 401/khác ID | Lỗi bootstrap, không protected UI; Web không tự đọc HttpOnly cookie | Phục hồi E6/secure-storage policy |

UI không tự suy role hoặc workspace từ email, cache hay giá trị request login. Copy thông báo là đề xuất UX; nếu catalog message hiện có khác, giữ cùng semantic và chốt trong fixture client.

### Trạng thái bắt buộc

- `idle`
- `submitting`
- `validationError`
- `authenticationError`
- `rateLimited` có thời gian chờ
- `serviceUnavailable`
- `passwordChangeRequired`
- `loadingProfile`
- `loadingWorkspaces`
- `workspaceEmpty`
- `workspaceSelectionRequired`

### Hành vi

- Disable submit khi đang gửi; không tự retry login.
- Không hiển thị “email không tồn tại” hoặc “account disabled”.
- Có label, focus, keyboard submit và error association phù hợp accessibility.
- Không render dashboard/device cache trước khi session và workspace bootstrap hoàn tất.
- 401: xóa state/cache về login; Web 403 PASSWORD_CHANGE_REQUIRED chỉ đi đổi password sau khi `/me` confirmation có response context trùng intent, Android limited theo bearer đã lưu; network/503: giữ credential trong transport an toàn, ẩn protected UI, retry GET theo thao tác người dùng. Không biến lỗi mạng thành logout hoặc tự POST login lại.
- Auth intent có generation phía client; callback cũ sau logout/đổi account không được ghi storage/cache/route. Với Web, generation không ngăn browser xử lý Set-Cookie cũ: mọi protected request phải qua context fence mục 13.1. Nhiều tab dùng chung cookie jar, không hứa phiên độc lập theo tab; đổi identity khóa UI và reset context ở các tab.

### 16.1 Bố cục, thành phần và điều hướng Web để BUILD

- `/login`: một form tác vụ trong `main`, rộng tối đa khoảng 28rem, căn giữa vùng nội dung; logo Nexa IoT và tiêu đề ở trên, email, password, thông báo lỗi, nút Đăng nhập theo thứ tự đọc. Không đưa hero, số liệu thiết bị hoặc preview từ landing page vào màn xác thực. Desktop có khoảng trống cân đối; dưới 760px form chiếm chiều rộng còn lại với lề tối thiểu 24px, không cuộn ngang ở 320px.
- Dùng token `--bg`, `--surface`, `--ink`, `--muted`, `--line`, `--teal`, `--amber`, `--coral` của [`design-system.md`](../../UI%20web/design-system.md); tiêu đề Bricolage Grotesque, nội dung Be Vietnam Pro, card bo 24px, field và nút có vùng thao tác tối thiểu 44px. Cả theme sáng/tối giữ contrast và focus ring amber 3px; giảm chuyển động theo `prefers-reduced-motion`.
- Component dự kiến: `LoginForm` (label hiển thị, `autocomplete=email/current-password`, cho paste/password manager, nút hiện mật khẩu có tên truy cập), `FormFieldError`, `AuthStatus` (`role=alert` cho lỗi, `role=status` cho tiến trình), `WorkspacePicker` (danh sách tên/role có nút Chọn riêng từng item, không tự chọn), `WorkspaceEmpty` (CTA tạo workspace theo065), `BootstrapRecovery` (retry GET chủ động). Không hiển thị giá trị password trong lỗi/telemetry.
- Điều hướng: `/login` → `POST /auth/login` → GET /me với context vừa cấp; `limited` sau đối soát đi màn đổi mật khẩu004, `full` khớp ID/context mới tải `/workspaces` → `/workspaces/select` hoặc `/workspaces/new` theo065. Chỉ khi người dùng chọn item và GET /workspaces/{id} kiểm lại membership theo067 mới vào workspace shell. Back/refresh kiểm marker `logoutPending`/`loginUnknown`/`accepted` theo mục 13.1; khi chưa có accepted context, `/me` chỉ dẫn tới màn xác nhận tiếp tục phiên, không vào picker. Logout/đổi account khóa protected view trên các tab.
- Sau submit lỗi, focus tới error summary và liên kết `aria-describedby` tới lỗi field; Enter gửi form một lần, Tab đi theo thứ tự thị giác, nút disabled thực sự khi đang gửi/Retry-After. Khi chuyển màn, focus vào `h1`; thông báo async phải được đọc mà không đánh cắp focus đang nhập. Kiểm tra 320/768/1024/1440px, keyboard, zoom 200%, theme sáng/tối.

| Trạng thái Web | Vùng hiển thị và thao tác | Điều kiện rời trạng thái / kiểm chứng |
| --- | --- | --- |
| Idle/validation error | Form; lỗi field sát input và summary có focus, giữ email, password chỉ ở RAM | Sửa field/submit; chưa gọi API nếu input client sai |
| Loading/pending | Nút gửi khóa, chữ “Đang đăng nhập”; bootstrap có tiến trình riêng, ẩn protected UI ở mọi tab | Marker intent được ghi trước request; chỉ callback đúng intent được xử lý, chưa tin cookie |
| Auth error/permission denied | 401 credential dùng cùng copy; Web limited 403 từ `/me` chỉ đi đổi mật khẩu khi context trùng, Android limited theo bearer; không vào picker | Người dùng sửa credential hoặc hoàn tất004; context thiếu/sai giữ khóa/recovery |
| Offline/service error | Thông báo kết nối/dịch vụ và nút thử lại cho GET bootstrap; login POST chỉ submit lại chủ động | Không tự suy logout/thành công và không tự lặp POST |
| Unknown outcome | Mất body/commit chưa biết: nêu “Chưa xác nhận đăng nhập”; marker sống qua reload; ẩn protected UI | Người dùng xác nhận phiên cookie hiện tại sau `/me` discovery hoặc chủ động đăng nhập lại; không tự nhận A/B |
| Stale/conflict | Response cũ, 409 context mismatch hoặc membership đổi: khóa UI, xóa protected cache; thông báo lỗi và hướng phục hồi | Không render workspace/data từ context khác; đối soát lại trước GET tiếp theo |
| Permission denied/storage | Không ghi/đọc được marker điều phối: báo “Không thể xác minh trạng thái phiên”; giữ form và protected UI khóa | Thử lại khi storage dùng được; không gửi auth mutation mới trong trạng thái không kiểm chứng |
| Empty | `items=[]` và `nextCursor=null` sau GET thành công: copy “Không có workspace khả dụng”, CTA tạo workspace | Chỉ route create065 với full session |
| Success | Danh sách workspace với tên/role và phân trang; một item vẫn cần nút Chọn | Recheck server rồi mới tải resource/realtime theo067 |

## 17. Yêu cầu UI Android

### Trạng thái bắt buộc

- Tương đương Web, thêm `networkUnavailable` và `secureStorageFailure`.

### Hành vi

- Không queue login vô hạn khi offline.
- Không lưu password để tự gửi lại.
- Lưu token chỉ sau response thành công và kiểm tra lỗi secure storage.
- Khi account khác login trên cùng thiết bị, không hiển thị cache/inbox/workspace của account trước.
- Không mở background socket/control trước bootstrap.
- Vùng bấm, semantics/labels và error text phải đọc được; không chỉ dùng màu.

### 17.1 Bố cục, thành phần và điều hướng Android để BUILD

- `LoginScreen`: `Scaffold` có safe area và vùng cuộn khi bàn phím mở; cột logo/tiêu đề, email, password, lỗi, nút gửi. Điện thoại dùng một cột với lề 16–24dp; tablet/landscape giới hạn chiều rộng form, không kéo giãn toàn màn. Cùng màu/chữ Nexa theo vai trò, nhưng control và focus/semantics theo Flutter/Android; mục tiêu chạm tối thiểu 48dp.
- `PasswordChangeScreen` thuộc004, `WorkspaceSelectionScreen` là danh sách nghiệp vụ có tên/role, CTA tạo workspace và phân trang, không phải landing page. Dùng component trạng thái riêng cho loading, empty, offline, error và secure-storage failure; nút back không mở lại nội dung account cũ sau logout/switch.
- Điều hướng tương đương Web; chỉ chuyển khỏi login sau khi token Android parse hợp lệ **và** ghi secure storage thành công. Khi ghi lỗi, xóa state dở dang và xử lý revoke best effort theo OQ-AUTH-003; không tuyên bố đã đăng nhập. Trên resume, kiểm session và account generation trước khi hiện cache. TalkBack đọc label/lỗi/trạng thái; bàn phím có next/done và submit một lần. Kiểm tra font scale lớn, portrait/landscape và safe area trên emulator/thiết bị sau PoC Mobile.
- Ma trận trạng thái Web mục16.1 áp dụng cùng semantics cho App; bổ sung `networkUnavailable` (không queue POST login), `secureStorageFailure` (không mở protected UI) và `sessionRestorePending` (màn chờ/unknown, không hiện cache tới khi guard xác nhận). Không áp dụng Web cookie/CSRF cho bearer Android.

## 18. Test suite chi tiết

### UI slice C0 — thiết kế presentation Android độc lập

Phạm vi được user cho phép: mock chỉ cho thiết kế/test và phải ghi rõ. C0 xây
component có thể tái sử dụng sau này, không kết nối provider/storage, không ghi
credential hoặc mở protected route; không đổi gate START-06/CP-02/P5. Dùng
layout mục17.1 và token Nexa từ design-system/home, không dựng landing page.
UI source có callback do host/ViewModel cung cấp; API/session/revoke ở C1 sau
gate. `main.dart` không chuyển thành app auth giả. Entry preview riêng ở tool/.

| Task | AC tối đa3mục | Dependency / file / checkpoint |
| --- | --- | --- |
| R9-C0a form presentation | (1) Form Nexa sáng/tối, max width480dp, safe-area/scroll, control≥48dp, keyboard next/done, label/reveal/autofill/paste; (2) validate email và login9–128 Unicode codepoints theo Password policy addendum mục1, password không trim và được xóa trước callback, khóa double-submit/unknown, không leak error; (3) focused widget/full tests và analyzer, preview ghi rõ mock, chưa E2E thật. | User scope +17.1 +SDK, không DB/storage.5files: presentation/login_view_state.dart, login_screen.dart, ui/nexa_auth_theme.dart, test/auth/login_screen_test.dart, tool/auth_preview.dart. RED→minimal form→GREEN→states/theme→verify/review. Không package/font download mới; font hệ thống là fallback trong design system. |
| R9-C0b preview device | Chạy/tương tác component thật trên emulator; kiểm submit/reveal/keyboard/scroll, portrait/landscape/font scale/theme; evidence chỉ là UI mock, không auth backend. | C0a; integration test≤2files +evidence, không fake provider ghi thành E2E. Checkpoint trước C1: storage gate/CP-02/actual topology, không bỏ gate bằng preview. |
| R9-C0c1 workspace presentation | (1) Danh sách tên/role, chọn chủ động, phân trang và empty đúng điều kiện items=[]/hasMore=false; (2) state matrix dưới đây, callback một intent, stale callback không mở selection, error không lộ detail; (3) widget responsive/semantics/matrix PASS và analyzer. | 17.1, WorkspaceSummary/Page0.2.1, Nexa theme có sẵn;3files presentation/workspace_selection_state.dart, workspace_selection_screen.dart, test/workspaces/workspace_selection_screen_test.dart. Không JSON/network/storage/repository hoặc main app. |
| R9-C0c2 workspace preview device | (1) Entry riêng banner mock, sample từ fixture; (2) UI mock interactions trên API24/36, ghi đúng evidence; (3) cập nhật runbook/progress, source snapshot, không gọi là auth E2E. | C0c1 READY_FOR_QA; tool/workspace_preview.dart + integration_test/workspace_preview_test.dart. Không package/font mới. |

#### C0d limited-password UI — PLAN review2026-10-26

C0d1/C0d2 kết quả: READY_FOR_QA cho source/native mock.7files theo hai task;
35Flutter tests PASS (9password mới),9host runner tests PASS, analyzer No issues/
7.8s, full format29files0changed.4native profiles API24/36×portrait/landscape200%
PASS trên source sau sửa keyboard viewport0; logical/native start/end khớp,
display restored. Không API/storage/main wiring hoặc004 revoke acceptance.
[Handoff/SHA/Tester và các lượt FAIL giữ lại](../../test-reports/FEAT-TN-001-android-password-ui-2026-10-26.md).

Nhánh limited của001 dẫn tới004, không được mở workspace. Đã đọc17.1,
FEAT004 mục16/17, BA/handoff WF-TN-004 và ChangePasswordRequest0.2.1.
Chỉ chuẩn bị presentation có thể dùng lại, không triển khai toàn004 hoặc vượt
C1/CP-02. Dependency đã có: Nexa theme/brand, Flutter SDK/test; không DB.

Task C0d1 (4files): presentation/password_change_state.dart,
password_change_screen.dart, test/auth/password_change_screen_test.dart,
tool/password_change_preview.dart. Thứ tự test RED → state/form → GREEN →
preview đầy đủ trạng thái → full tests/analyzer/format/review. AC: (1) Nexa
appbar72dp/logo/theme48dp, form max480dp/cuộn/safe-area/gutter24, current/new/
confirm có label/reveal/next/done/paste, font200% và landscape dùng được;
(2) current1–128/new9–128 Unicode codepoints theo Password policy addendum mục1; new có chữ hoa,
chữ thường và số ASCII0–9, không trim, new khác current,
confirm khớp, xóa cả3input trước callback và khi host đổi state, một intent,
exception giữ unknown tới generation mới, không log/retry credential;
(3) state matrix/test/preview banner mock, success chỉ mời login lại, không
thể cấp session/workspace từ UI. Scope không sửa main, source Web hoặc token.

Layout: màn nghiệp vụ một cột, tiêu đề “Đổi mật khẩu”, lời nhắc limited chỉ
đổi mật khẩu/đăng xuất; ba ô mật khẩu và helper tường minh; thông báo live
region trước form, CTA “Đổi mật khẩu”, nút đăng xuất riêng. Không hero/landing.
Empty áp dụng cho field validation, không màn danh sách. Keyboard focus tới
field lỗi đầu; mật khẩu không autocorrect/suggestions, autofill current/new.

| Phase | Hiển thị / thao tác | Boundary |
| --- | --- | --- |
| ready/rejected/networkUnavailable | Form + submit chủ động; rejected không tiết lộ internals, offline không queue | Host quyết định outcome, không tự retry POST |
| submitting | Form khóa, trạng thái chờ; reduced-motion dùng icon tĩnh | Không callback thứ hai hoặc logout cạnh tranh |
| rateLimited/serviceUnavailable | Ẩn form, thông báo + kiểm tra lại | Host kiểm Retry-After/tình trạng trước tạo generation mới |
| pending/conflict/permissionDenied/storageFailure | Ẩn form, chỉ đối soát; không hiển thị raw exception | Callback recovery không tự bỏ unknown fence |
| success | Không form; “Đăng nhập lại”, không token/full session/picker | Host phải dọn local session sau204, không suy từ preview |

Risk: outcome unknown hoặc dispose còn callback; test giữ fence/mounted và
không giữ secret trong harness. onLeave thuộc host: logout/cleanup rồi về
login khi known; không dùng nó để vượt unknown. Rollback chỉ4files mới và
task docs. Checkpoint C0d1 READY_FOR_QA source; C0d2 native preview sau đó
≤3files test/runner allowlist, có metrics thật trên API24/36 và cleanup display.
Native/visual/TalkBack và auth004 acceptance vẫn chưa kiểm cho tới evidence.

C0d2 PLAN review: sau C0d1 source suite/analyzer/format PASS, thêm
`integration_test/password_change_preview_test.dart`, thêm suite password vào
allowlist `tool/run_auth_display_test.py`, thêm host routing test trong
`test/tool/test_auth_display_runner.py` (3files). RED routing → allowlist đúng
target → host GREEN → native validation/reveal/submit/recovery/theme/success
→ login preview, giữ banner mock và missed tap fatal. Dùng helper handshake
hiện có, không fake surface/MediaQuery hoặc đổi main/app orientation. Kiểm
portrait/landscape200% trên2AVDs24/36 theo đúng identity/API; save/restore/readback
3settings/WM policy như runner có sẵn. Nếu session preview còn sống, dừng đúng
runner/app của lab trước install test; không restart AVD sống vì timeout.
AC: flow kết thúc exit0, metrics start/end thật khớp profile, evidence ghi đúng
suite/testTarget và restorationVerified=true. Còn visual/TalkBack/physical,
rotation trong request và004 server acceptance không được tự đánh PASS. Rollback
chỉ3files của C0d2 và display settings capture tại đúng AVD; không DB/dependency.

C0d follow-up layout PLAN sau native evidence: landscape có lúc keyboard làm
viewport0, settle focus chỉ sửa sequencing nhưng không đủ nếu IME chiếm chỗ.
Regression full harness800×375/chữ200%/IME240dp đã RED viewport0. Chỉ mở lại
screen/test C0d1: LayoutBuilder đo chiều cao parent thực trừ IME; nếu không đủ
72toolbar+48target+48gutter=168dp thì tạm ẩn appbar, trả lại khi đóng keyboard.
Banner mock vẫn hiện, không giảm text scale/target hoặc tắt resizeToAvoidBottomInset.
AC: regression viewport≥48 và tap reveal/submit PASS với inset, UI bình thường
vẫn brand/theme72dp; native4profiles chạy lại trên source sau sửa, không dùng
lượt portrait cũ hoặc một lần landscape keyboard0 thay nhánh IME cần kiểm.

#### C0c screen layout/navigation/state matrix — chi tiết

Nguồn:17.1, BA/handoff WF-TN-001/AT-WF-001-03 và contract WorkspaceSummary/Page.
Nexa brand/header72dp, nền sáng/tối/theme đang có; body danh sách một cột,
gutter24dp/max720dp, header tiêu đề28sp và mô tả tác vụ, row card tên/role
với nút native≥48dp, footer tải thêm/tải lại/đăng xuất. Danh sách dựng lazy,
chữ dài wrap và200% text, không hero/dashboard/device giả. Create CTA chỉ
empty thật; khi callback065 chưa sẵn sàng phải disabled kèm lý do, không link
chết. Menu/scenario mock nằm ngoài component trong entry tool riêng.

| State | Hiển thị / action | Điều kiện |
| --- | --- | --- |
| loading | Progress bằng chữ, không item/cache cũ | Host xác nhận session/account trước khi cấp list |
| ready | Tên/role từng item, không tự chọn kể cả1item; load more nếu hasMore | Chỉ active row được chọn, callback nhận đúng id/revision hiện hành |
| empty | Không có workspace khả dụng; refresh/create capability | Chỉ ready + items rỗng + hasMore=false; cursor còn thì là chưa tải đủ, không empty/create |
| loadingMore | List hiện tại không tương tác, progress và control khóa | Không phát intent song song, host sở hữu cursor opaque |
| offline/error | Copy an toàn, ẩn list, retry GET chủ động | Không auto retry, không suy thành empty/logout |
| permissionDenied/stale | Ẩn list, tải lại trước lựa chọn | Summary/role không cấp quyền; C1 phải recheck server067 |
| pending/storageFailure | Ẩn list, chỉ recovery riêng/exit phù hợp | Không retry select hoặc route protected; callback exception vào local unknown |
| selected | Thông báo đã chọn, không dựng nội dung tài nguyên | Chỉ presentation host cung cấp; preview ghi rõ giả, không tự navigation/data fetch |

UI nhận immutable typed row/state và callbacks từ host, không parse wire.
Host C1 chịu session/account generation, secure storage, API/revoke và guard;
key/generation mới sau đối soát được xác nhận, không reset unknown chỉ vì
callback trả về. Event row cũ kiểm lại phase/id/revision trước dispatch; mọi
intent một lần khi đang await và bỏ setState khi disposed. Inactive summary
không được dispatch dù host cung cấp; không thêm API/filter historical.

Thứ tự C0c1: widget contract RED → state/screen tối thiểu → matrix/async/stale
callbacks → responsive375×667/800×375, text2×, sáng/tối/reduced motion/semantics
→ full Flutter/analyzer/format → review. C0c2 sau đó mới native mock flow và
entry mở được. Rollback chỉ file slice mới, giữ main scaffold và các thay đổi
người dùng. Risk: lộ cache account cũ, nhầm page rỗng thành empty, callback
đến muộn và dependency065/CP-02 chưa đủ; các guard/test trên không thay server
authorization hay mở gate tích hợp. Không đóng P5/AT-WF-001 từ UI mock.

C0c1 kết quả:3files presentation/test đã code,9workspace tests PASS; full
Flutter24tests PASS, analyzer No issues/10.2s. Regression scroll offset cũ giấu
loading status RED→key tách list/status GREEN; mutation bỏ revision guard bị
bắt exit1, source restore byte-for-byte. Scope snapshot immutable/duplicate,
empty/cursor, stale/inactive/disposed callbacks, double intent, unknown/recovery,
keyboard/semantics và375×667/800×375/chữ2×/hai theme/reduced motion đã kiểm.
C0c1 READY_FOR_QA, chưa native hoặc provider E2E; C0c2 tiếp tục2files preview/
integration như bảng. Preview chọn summary chỉ hiện selected giả, không data;
logout/recovery giả reset generation, không revoke session. Native test dùng
fixture2rows, pagination→selection→empty→offline/recovery, menu mock/banner
luôn hiển thị, kiểm engine thật trên API24/36. Không thay main hoặc plugin.

C0c2 kết quả2026-10-26: API24 và API36 mỗi OS1native UI mock flow PASS trên
source cuối. API24 engine411.43×683.43/text16=16, API36 engine411.43×914.29/
text16=16. Full Flutter24tests PASS, analyzer No issues/13.3s, format scope5files
0changed PASS. Full-mobile format exit1 tại login_screen.dart ngoài slice đã
đổi hash so snapshot cũ, giữ nguyên không tự sửa hoặc báo full-format PASS.
C0c1/C0c2 READY_FOR_QA cho presentation/mock, chưa native workspace landscape/
font2×/visual/TalkBack hay login→picker/server E2E; login4displayprofiles không
chứng nhận picker. Source/state/screen/widget/preview/integration tổng5files,
không API/storage/main/dependency mới. [Workspace UI runbook](../../test-reports/FEAT-TN-001-android-workspace-ui-2026-10-26.md)
ghi SHA11files, mutation/RED→GREEN, source hiện hành và Tester steps. Task đủ
dependency kế tiếp: kiểm native display/accessibility của picker; C1 thật vẫn
sau CP-02/storage gate/topology. Không đóng P5/AT-WF-001 từ các preview.

R9-C0c3 PLAN review2026-10-26: native display của picker dùng host handshake
đã được chứng minh ở C0b;5files scope: runner Python + host unit, hai integration
test login/workspace và helper chung integration_test/support/native_display_profile.dart.
Tách wait/log metrics nguyên semantics từ login, không đổi20s/two matchingframes,
không setSurfaceSize/MediaQuery giả; workspace cũng phát READY sau app-start.
Runner thêm suite allowlist login|workspace (default login để tương thích lệnh
cũ), JSON ghi suite/testTarget riêng; unknown suite từ chối trước launch/ADB
mutation. Không input/API/storage/main hook/dependency. UI/layout giữ17.1/C0c.
AC: (1) host RED unknown/route suite→GREEN, guard cleanup cũ còn PASS; (2) mỗi
OS24/36 chạy cả login và picker ở portrait và landscape/chữ2×, metrics engine
khớp và finally3settings/WM policy restored; (3) full Flutter/analyzer + format
scope PASS, ghi đúng full-format ngoài slice còn fail nếu chưa đổi. Negative
không host apply vẫn phải fail profile; không gọi native display là visual/
TalkBack/providerE2E. Checkpoint sau API36 rồi API24; test terminal trước đổi
AVD, không restart từ observation timeout. Rollback đúng5files/settings đã
capture, giữ preview/banner/guard sản phẩm và thay đổi người dùng. Sau READY_QA
native slice, C0c vẫn còn independent visual/TalkBack và C1 sau CP-02.

R9-FMT1 PLAN review riêng2026-10-26: full format finding tại login_screen.dart
được rà read-only bằng dart format --output=show;4hunks chỉ wrap expression/
argument và trailing comma, không đổi callback/layout/token/animation. Scope
1file sản phẩm, tách C0c3 test-only; áp đúng formatter preview đã review, so
bytes output với preview và ghi diff, không reset user UI. AC: full-mobile
format PASS, analyzer/widget suite giữ PASS; native login cuối trên API36 chạy
source đã format. Rollback chỉ diff formatter, không dùng git checkout/reset
với file dirty. Việc sửa format thuộc quality bar đã được user cho phép, không
API/session/DB/dependency. Snapshot mới ghi rõ source sau formatting và các
native runs trước đó; không giả binary reproducibility.

R9-C0c3/R9-FMT1 kết quả:8native display profiles PASS (login/picker ×API24/36
×portrait/landscape200%), suite/testTarget đúng, metrics logical/native đầu/
cuối khớp và3settings/WM policy restored ở mọi lượt. Native thiếu host apply
expected RED, host8tests PASS và wrong-suite mutation bị bắt. Hai regression
lazy-list và scroll/animation tap đã sửa trong harness, không tắt missed-tap
guard. FMT1 riêng review4hunks/actual bytes khớp preview; full-mobile format
19files0changed, Flutter24tests và analyzer No issues/8.7s PASS. READY_FOR_QA
cho các slice, chưa AT-WF/CP-02/03/P5 acceptance. [Latest matrix/runbook](../../test-reports/FEAT-TN-001-android-workspace-display-2026-10-26.md)
ghi16source hashes, source6file scopes (5test/tool +1formatter-only), fail
history và lệnh tester. Runtime khi handoff phải revalidate: runner preview
cũ52599 missing/ADB device absent/Web5173 không phản hồi sau continuation;
đã xác minh qemu/emulator missing và no5173listener rồi mới relaunch, không
restart process còn sống từ timeout. Provider approval cụ thể còn chờ.

R9-D2 kết quả2026-10-26: READY_FOR_QA cho consumer/source, không session
admission. Đúng5files theo plan;57cases từ2success/6error fixtures và malformed
body PASS. Nới UUID version guard bị test bắt exit1, source restore byte trước
full Flutter26tests PASS (42login+72workspace+57profile cases trong3tests),
analyzer No issues/8.6s, full format24files0changed PASS. Không wire UI/main,
network hoặc storage; không thay native evidence cũ thành run mới. CP-02/03
vẫn mở. [Handoff/evidence/Tester steps](../../test-reports/FEAT-TN-001-android-full-profile-2026-10-26.md).

R9-D2 PLAN review2026-10-26 — full `/me` consumer Android:

Phụ thuộc: contract0.2.1 `MeProfile`, shared getMe fixtures và R9-A/D1 parser
đã có. Đã đối chiếu read-only: body200 trực tiếp, required5fields,
mustChangePassword=false; discovery200 không chứng minh login intent được nhận.
Scope5files: mới `core/validation/uuid_validation.dart`,
`features/auth/data/full_session_profile.dart`,
`test/contracts/full_session_profile_test.dart`; thay đúng UUID guard trong
AppLoginResponse và AvailableWorkspaceSummary để ba consumer cùng policy.
Không đổi wire, fixture, dependency, transport, storage, UI hoặc main scaffold.

Thứ tự: (1) test shared2success/6error envelopes và malformed body phải RED
vì thiếu factory; (2) helper UUID giữ nguyên version1–8/variant8–b, immutable
full profile và hai parser dùng helper; (3) focused GREEN, mutation nới UUID
version phải bị bắt rồi restore byte; full Flutter/analyzer/formatter.
AC: đủ5fields đúng kiểu, revision integer≥1, false strict; lỗi cố định không
giữ payload; extension không cấp quyền, giữ email/timezone nguyên bản. Parser
chỉ kiểm cấu trúc email/timezone như consumer Web, không chứng nhận địa chỉ
email hoặc IANA catalogue. Caller vẫn phải kiểm status, transport, identity và
generation/session admission. Rủi ro: nhầm DTO thành phiên đã xác nhận; giảm
bằng tên full profile và doc/test discovery riêng. Không có provider proof.
Checkpoint: review diff5files, regression42login/72workspace cases và full
suite trước READY_FOR_QA; rollback chỉ5files của slice, không đụng user UI.
Evidence: red/green/mutation/full/analyze/format logs, source SHA và handoff.
Plan được rà dependency/AC/risk theo phạm vi E2E đã được user cho phép; chưa
đánh hoàn thành CP-02/03 hoặc whole feature.

R9-D1 PLAN review2026-10-26 — available workspace page consumer:
scope2files `mobile/lib/features/workspaces/data/available_workspace_page.dart`
và `mobile/test/contracts/available_workspace_page_test.dart`. Dependency:
WorkspaceSummary/Page0.2.1, shared workspace fixtures và SDK hiện có; không
phụ thuộc provider runtime để kiểm consumer, không mở C1/CP-02. AC: (1) parsed
DTO bất biến cho default ACTIVE bootstrap, id UUID cùng policy Web/login,
name string không trim/normalize, roleADMIN/USER và revision integer≥1; reject
thiếu/null/sai kiểu/enum/duplicate UUID case-insensitive bằng PROTOCOL_ERROR
không giữ raw source; (2) required nextCursor string|null, opaque không giải mã,
không normalize; items=[] + cursor còn (kể cả string rỗng theo schema hiện có)
không empty cuối; extension fields tương thích được bỏ qua; (3) shared fixture
consumer RED→GREEN, mutation required cursor, full tests/analyzer/format PASS.
Không thêm toJson/toString chứa cursor; không HTTP, mapping vào UI, token/
storage, navigation hoặc historical filter. Schema có historical statuses
nhưng consumer này dành riêng default route ACTIVE như Web hiện hành; không
claim generic WorkspacePage historical đã hỗ trợ. Caller phải kiểm HTTP status
trước factory, transport/raw JSON parsing sau này không được suy từ DTO này.
Thứ tự fixture test→minimal factory/immutable copy→negative matrix/mutation→
verify/review/handoff. Rollback chỉ2files mới; không sửa wire/fixtures để làm
test xanh, không dùng summary/cursor làm quyền hoặc tự chọn workspace.

R9-D1 kết quả:2files consumer mới, focused1test chứa72cases từ3shared success
fixtures +error/negative/compatibility PASS. Initial missing-module RED;
mutation bỏ required nextCursor guard bị bắt exit1, source restore byte-for-
byte. Analyzer bắt inference của empty-list fixture, sửa annotation không
suppression; cuối No issues/9.0s, full Flutter25tests và format21files0changed
PASS. READY_FOR_QA cho consumer, chưa provider/client hoặc app runtime. Không
wire/main/API/session/storage change; cursor/name nguyên bản, factory sanitize
errors và reject duplicate UUID case-insensitive. [Consumer handoff](../../test-reports/FEAT-TN-001-android-workspace-consumer-2026-10-26.md)
ghi SHA7files, compatibility limits/defaultACTIVE và Tester commands. Sau
continuation đã mở lại Vite5173 và Pixel_7 khi listener/process cũ missing;
preview là mock, không biến availability thành authE2E. Provider approval cụ
thể được hỏi lại để mở positive DB suite, chưa có câu trả lời, không tự chạy.

Layout C0a: app bar72dp có logo Nexa và theme control48dp; form card bo24dp,
lề24dp, chiều rộng tối đa480dp; tiêu đề28sp, body16sp, input có label và icon
outline. Gradient CTA/logo theo home, chữ CTA navy đậm để đủ contrast; lỗi có
text/icon và semantics live region, không chỉ màu. Không hero/marketing/test
controls trong component; chọn scenario/banner chỉ nằm trong tool preview.

| State form | UI/action | Guard trong component |
| --- | --- | --- |
| ready / rejected | Form và CTA, rejected có lỗi chung | Validate submit; một callback đang chạy; không tự retry |
| submitting | Spinner/nhãn đang gửi, khóa input và CTA | Không callback mới; password đã xóa khỏi controller |
| networkUnavailable | Thông báo kết nối, recovery riêng | Không queue/login callback khi offline |
| storageFailure | Chưa thể bảo vệ phiên, recovery riêng | Không mở UI đã đăng nhập |
| pending / conflict | Cần kiểm trạng thái phiên trước khi tiếp tục | Khóa submit, chỉ recovery callback của host |
| permissionDenied | Thông báo không thể tiếp tục, recovery | Không tạo quyền từ UI state |
| confirmed | Notice xác minh xong, chờ host điều hướng | Không workspace/resource; host thật chỉ cấp sau guard |
| empty input / callback exception | Field errors hoặc unknown an toàn | Exception không lộ detail; khóa submit tới host tạo widget generation mới sau reconciliation |

Rủi ro: preview không kiểm provider, autofill service/TalkBack/thiết bị thật;
success state mô phỏng không là session thực. Rollback C0 bỏ5files mới, không
đụng API/token/DB hoặc component Web. Gate nghiệm thu toàn feature giữ nguyên.

Tất cả case bắt đầu `NOT_RUN`. Khi thực thi phải ghi `buildId`, môi trường, client/browser/device/OS, fixture, expected, actual, status, evidence path và defectId.

### 18.0 Fixture đầu vào/đầu ra chung

| Fixture | Input/setup tối thiểu | Output/side effect phải assert |
| --- | --- | --- |
| `valid_web` | `User ACTIVE`, đúng password, `clientType=WEB`, 2 Membership ACTIVE A/B | `200` + cookie bảo vệ; `limited=false`; đúng một Session mới; `/me` đúng user; `/workspaces` chỉ A/B; login không có device data |
| `valid_android` | Cùng user/password, `clientType=ANDROID` | `200` + token/expiresAt; Session ID/digest khác Web; cùng membership A/B; token chỉ trong secure storage |
| `temporary_user` | `ACTIVE`, `mustChangePassword=true`, đúng password | `200`, `limited=true`; `/devices` 403 `PASSWORD_CHANGE_REQUIRED`; không gọi bootstrap resource |
| `unknown_or_disabled` | Unknown email, sai password hoặc User DISABLED | Cùng public `401 AUTH_INVALID`; 0 Session mới; 0 token/cookie; audit outcome đã redaction |
| `no_membership` | `ACTIVE`, đúng password, 0 Membership ACTIVE | Login thành công; `/workspaces` `items=[]`, `nextCursor=null`; UI tạo workspace, không đọc cache cũ |
| `cross_scope` | User có A ACTIVE, B SUSPENDED hoặc không có Membership B | B không nằm trong picker vận hành; request workspace B bị chặn ở server; không trả resource B |
| `rate_limited` | 5 password sai trong cùng 15 phút theo rate-limit key đã chốt | Attempt kế tiếp `429 RATE_LIMITED` + `Retry-After`; không tạo Session, không retry tự động |

Mọi fixture dùng UUID/email/password tổng hợp riêng cho test; không chụp response token vào report. Với mỗi API case, assert đồng thời HTTP, header, body schema, side effect DB/audit và sự vắng mặt của field nhạy cảm. Test chỉ dùng mock không chứng minh provider; contract gate phải serialize handler thật rồi parse bằng client thật ở môi trường kiểm thử được phép.

### 18.1 Backend unit tests

| Test ID | Given/When | Expected |
| --- | --- | --- |
| `UT-AUTH-001` | Password có khoảng trắng đầu/cuối | Không trim trước verify |
| `UT-AUTH-002` | Login password dài 8, 9, 128, 129 Unicode codepoints; current 0/1/128/129; new cùng biên login và thiếu hoa/thường/số | Login chỉ 9–128; current 1–128; new 9–128 và đủ composition theo Password policy addendum mục1; không trim/normalize |
| `UT-AUTH-003` | Account không tồn tại và password sai | Cùng public mapping `AUTH_INVALID` |
| `UT-AUTH-004` | Account `DISABLED` | Không tạo session; không tiết lộ trạng thái |
| `UT-AUTH-005` | `mustChangePassword=true` | Login output có `limited=true`; guard chỉ cho đổi mật khẩu/logout, không phát role/workspace privilege |
| `UT-AUTH-006` | Account bình thường | Login output có `limited=false`; session hết hạn sau 24 giờ theo clock server/DB |
| `UT-AUTH-007` | Hai concurrent login intents | Hai session riêng, không ghi đè |
| `UT-AUTH-008` | 5 failure trong cửa sổ rồi attempt tiếp | Attempt tiếp theo bị rate-limit |
| `UT-AUTH-009` | Rate-limit window hết | Cho phép attempt mới theo policy |
| `UT-AUTH-010` | Client gửi role/workspaceId | Validation reject unknown field; không ảnh hưởng principal/session authority |
| `UT-AUTH-011` | Email khác case/whitespace/Unicode theo quy tắc được duyệt | Lookup và unique key cho cùng một account nhất quán, không lộ account qua lỗi |
| `UT-AUTH-012` | Session vừa hết hạn hoặc user chuyển DISABLED sau login | Guard từ chối request mới, không dựa riêng vào claim/cached profile |
| `UT-AUTH-013` | JSON có `null`, number/boolean, unknown field, password chứa khoảng trắng | Không coerce; password giữ nguyên; field error không lặp giá trị nhạy cảm |

### 18.2 Repository và transaction tests

| Test ID | Given/When | Expected |
| --- | --- | --- |
| `IT-AUTH-001` | Session insert thành công | Digest/metadata đúng, không raw secret |
| `IT-AUTH-002` | DB lỗi chắc chắn trước commit; mất ACK commit | Trước commit rollback; mất ACK có thể có orphan nhưng không emit credential/không tự retry; expiry hữu hạn |
| `IT-AUTH-003` | Login success và audit cùng transaction boundary | Audit/session nhất quán theo thiết kế |
| `IT-AUTH-004` | Membership ACTIVE/SUSPENDED/REMOVED | `/workspaces` chỉ trả ACTIVE |
| `IT-AUTH-005` | User ở A/B với role khác nhau | Summary giữ đúng role theo membership |
| `IT-AUTH-006` | 6 password sai đồng thời từ cùng rate-limit scope | Update đếm atomic; attempt vượt ngưỡng bị 429, không race vượt guard |
| `IT-AUTH-007` | Audit insert fail, session insert fail, transaction rollback | Không phát usable credential của transaction thất bại; audit/session khớp quyết định `OQ-AUTH-012` |
| `IT-AUTH-008` | Membership A ACTIVE, B SUSPENDED, C REMOVED, D ACTIVE | Chỉ A/D; fixture ổn định phân trang không lặp/bỏ item; quyền đổi thì restart |

### 18.3 API contract tests

| Test ID | Request | Expected |
| --- | --- | --- |
| `CT-AUTH-001` | Login Web hợp lệ | 200, cookie/session metadata đúng schema |
| `CT-AUTH-002` | Login Android hợp lệ | 200, token/session metadata đúng schema |
| `CT-AUTH-003` | Thiếu/null/rỗng/sai kiểu từng field; JSON hỏng; unknown field; body >64 KiB | Validation/size error đúng HTTP, `error.details.fieldErrors[].path/code`; không echo input; không tạo session |
| `CT-AUTH-004` | `clientType=IOS` | Assert đúng chính sách đã chốt tại `OQ-AUTH-007`; không suy từ việc iOS client out-of-scope rằng enum server bị xóa |
| `CT-AUTH-005` | Sai credential/disabled/unknown email | Cùng 401/code/message công khai |
| `CT-AUTH-006` | Quá rate limit | 429 có `Retry-After` |
| `CT-AUTH-007` | Limited session gọi `/devices` | 403 `PASSWORD_CHANGE_REQUIRED` |
| `CT-AUTH-008` | Full session gọi `/me`, `/workspaces` | `/me` đúng profile schema; `/workspaces` `{items,nextCursor}` đúng schema, ACTIVE memberships, không resource data |
| `CT-AUTH-009` | Không có membership | 200 `{"items":[],"nextCursor":null}`, không fallback workspace |
| `CT-AUTH-010` | Login Web/Android response serialization | Web có `Set-Cookie` bảo vệ và `X-Auth-Context-Id` UUID không secret, không raw token trong body; Android có token/expiresAt, không context Web; cả hai có limited flag theo OpenAPI được duyệt |
| `CT-AUTH-011` | 401/403/409/429/503 và validation | `error.code/message/details/correlationId` cùng nằm trong `error`; context thiếu/sai trả 409 `AUTH_CONTEXT_MISMATCH` không profile/resource/side effect; `Retry-After` chỉ nơi cần; không stack/secret |
| `CT-AUTH-012` | `/workspaces?limit=1&cursor=...` hợp lệ, invalid, hết hạn | Fixture ổn định không lặp/bỏ item; cursor bound user/filter/sort; quyền đổi thì CURSOR_INVALID/restart; limit 1–100/default 20 |
| `CT-AUTH-013` | Provider response qua Web/Android parser runtime | Hai client parse fixture thật; thiếu/null/sai kiểu/extra field theo compatibility policy bị xử lý rõ, không chỉ compile types |
| `CT-AUTH-014` | Limited session thử `/me`, `/workspaces` | Cùng 403 PASSWORD_CHANGE_REQUIRED khi context đúng, không profile/membership; `/me` Web có CSRF và context header để phục hồi password/logout |

### 18.4 Security tests

| Test ID | Vector | Expected |
| --- | --- | --- |
| `SEC-AUTH-001` | Account enumeration qua code/message/body | Không phân biệt public response |
| `SEC-AUTH-002` | Credential trong structured log/audit | Không xuất hiện |
| `SEC-AUTH-003` | Cookie/token trong browser/app debug output | Không xuất hiện ngoài boundary cần thiết |
| `SEC-AUTH-004` | Client tự khai `ADMIN`/workspace khác | Không ảnh hưởng principal/membership |
| `SEC-AUTH-005` | Dùng session hết hạn | 401 `SESSION_EXPIRED` |
| `SEC-AUTH-006` | CSRF trên Web login/session bootstrap | Bị xử lý theo cookie/CSRF decision |
| `SEC-AUTH-007` | Proxy/IP header giả để né rate limit | Không bypass trusted-proxy policy |
| `SEC-AUTH-008` | Android backup/plain storage inspection | Không có raw session/password |
| `SEC-AUTH-009` | Raw `Authorization`, `Cookie`, `Set-Cookie`, password, token, email canary trong log/audit/metric/evidence | Scan có tên field và canary, không xuất hiện; correlation ID vẫn tra được outcome |
| `SEC-AUTH-010` | JSON extra `role=ADMIN`, `workspaceId=B`, `expiresAt` giả | Reject body; không tạo session có authority/scope từ client |
| `SEC-AUTH-011` | Full session của user A gọi resource workspace B không có ACTIVE membership | Server chặn trước query resource, không trả 1 byte data B |
| `SEC-AUTH-012` | `X-Forwarded-For` giả, hai request đồng thời, nhiều backend instance nếu môi trường có | Không né rate limit, không dùng process-local counter làm guard |
| `SEC-AUTH-013` | Cookie Web, CORS origin sai, CSRF thiếu/sai trên mutation, context thiếu/sai trên GET/mutation | Header/policy đúng deployment decision; cookie A + context B bị 409 trước dữ liệu, không revoke/đổi account khác; request cross-origin/CSRF bị chặn |

### 18.5 Web component/integration tests

| Test ID | Thao tác | Expected |
| --- | --- | --- |
| `WEB-AUTH-001` | Submit hợp lệ | Loading, một request, rồi bootstrap profile/workspace |
| `WEB-AUTH-002` | Double-click submit | Không tạo nhiều request từ UI |
| `WEB-AUTH-003` | 401 | Message chung, form vẫn dùng được |
| `WEB-AUTH-004` | 429 | Hiển thị retry time, không auto-submit |
| `WEB-AUTH-005` | Limited session | Sau `/me` confirmation 403 đúng code/context mới điều hướng đổi password; không tải workspace/resource |
| `WEB-AUTH-006` | Hai workspace | Hiển thị picker, không tự tải device A/B |
| `WEB-AUTH-007` | Không membership | Empty/create-workspace path |
| `WEB-AUTH-008` | Keyboard/screen reader | Label, focus và error association đúng |
| `WEB-AUTH-009` | Login response 200 thiếu cookie/body sai schema; `/me` lỗi | Không render protected UI; hiển thị lỗi bootstrap và cho retry an toàn |
| `WEB-AUTH-010` | Login result `limited=true`; gọi `/me` kèm context từ login | 403 `PASSWORD_CHANGE_REQUIRED` + response context trùng mới ghi `accepted` và điều hướng đổi mật khẩu; không nhận profile/membership, không gọi `/workspaces`/`/devices`. Context request sai nhận 409; response thiếu/sai context, 401, network/503 hoặc 200 giữ UI khóa/recovery, không ghi `accepted`. Discovery `/me` không header là case riêng, không chứng minh confirmation. |
| `WEB-AUTH-011` | `/workspaces` có `nextCursor` | Nạp trang kế tiếp theo nhu cầu, dedupe ID, không tự chọn; không coi lỗi/trang rỗng còn cursor là empty; chọn item phải recheck server |

### 18.6 Flutter widget/integration tests

| Test ID | Thao tác | Expected |
| --- | --- | --- |
| `MB-AUTH-001` | Submit hợp lệ | Token lưu secure storage, rồi bootstrap |
| `MB-AUTH-002` | Offline | Lỗi kết nối, không lưu password/queue login |
| `MB-AUTH-003` | Secure storage ghi lỗi | Không coi login hoàn tất; phục hồi an toàn |
| `MB-AUTH-004` | Account B login sau A | Cache protected của A không hiển thị |
| `MB-AUTH-005` | Limited session | Điều hướng đổi password, không mở control |
| `MB-AUTH-006` | Hai workspace | Picker trước snapshot/realtime |
| `MB-AUTH-007` | App background/resume giữa bootstrap | Recheck session/context trước render |
| `MB-AUTH-008` | Login response 200 thiếu token/expiresAt/sai schema | Không lưu phiên lỗi hoặc báo thành công giả; hiển thị recoverable error |
| `MB-AUTH-009` | Login result `limited=true` | Không gọi `/me`/`/workspaces`/`/devices`, không mở realtime/control |
| `MB-AUTH-010` | `/workspaces` phân trang, membership đổi khi chọn | Nạp list đúng; request sau chọn kiểm lại quyền server, cache cũ không render |

### 18.7 End-to-end acceptance tests

| Test ID | Kịch bản | Expected/Evidence |
| --- | --- | --- |
| `E2E-AUTH-001` | Cùng account ACTIVE login Web và Android | Hai session riêng; cùng active memberships; audit không secret |
| `E2E-AUTH-002` | Account tạm login rồi gọi `/devices` | 403 `PASSWORD_CHANGE_REQUIRED`; không data payload |
| `E2E-AUTH-003` | Account có workspace A/B chứa device khác nhau | Login không trả/render device trước lựa chọn |
| `E2E-AUTH-004` | Account DISABLED với credential đúng | 401 chung; không session/cookie/token |
| `E2E-AUTH-005` | Sáu lần sai trong cửa sổ | Rate limit có timestamp/`Retry-After` evidence |
| `E2E-AUTH-006` | Response mất sau commit; cookie A/B đến muộn, reload/tab khác | Không auto replay; `loginUnknown` còn sau refresh/browser reopen, `/me` discovery chỉ gợi ý xác nhận; accepted context B + cookie A trả 409 trước workspace/resource; App mất token đợi submit chủ động. Ghi cookie jar bằng harness đã redaction, request identity, UI/cache và reload. |
| `E2E-AUTH-007` | Membership bị suspend sau list, trước resource request | Resource bị chặn dù picker còn item cũ; không trả data workspace đó |

### 18.8 Ca bổ sung từ phản biện (đều NOT_RUN)

| Test ID | Kịch bản | Expected |
| --- | --- | --- |
| `IT-AUTH-009` | Dừng login sau verify; đổi password/reset/disable rồi resume | Hai thứ tự commit đúng 14.1; không usable session bằng password cũ sau fence |
| `IT-AUTH-010` | Failure thứ 5, password đúng, đổi IP/clientType và chạm cuối cửa sổ | Đủ ngưỡng luôn 429; đổi IP không reset; 429 không kéo dài; hết cửa sổ mới verify |
| `IT-AUTH-011` | Limiter/session-success-audit DB lỗi, commit ACK mất, exporter lỗi | Fail closed trước secret; orphan không bị giả là rollback chắc chắn; exporter không đảo success |
| `IT-AUTH-012` | Wrong password, chỉ rejection-audit insert lỗi nhưng limiter commit được; so với limiter commit lỗi | Case đầu401/429 + counter đúng + operational metric, không credential; case sau503 fail-closed, không fake count; cùng nguồn WF040 E2 |
| `SEC-AUTH-014` | Unknown/wrong/disabled cùng cost/input hợp lệ | Không bỏ qua verify; latency evidence không có early return hệ thống |
| `SEC-AUTH-015` | Cross-origin login khai App; WEB thiếu Origin/Referer; cookie+bearer | Không bypass origin/CSRF; mixed credential bị reject; không token/cookie sai transport |
| `SEC-AUTH-016` | Admin workspace đọc login audit global của thành viên | Không lộ lịch sử login global, quyền audit đúng boundary |
| `WEB-AUTH-012` | Reload limited mất CSRF memory rồi đổi password/logout | Marker `accepted` gửi `/me` kèm context, nhận 403 + context trùng + CSRF; không profile/membership/redirect loop. Không có accepted marker thì discovery không header chỉ đưa tới xác nhận chủ động; mutation kiểm CSRF và context. |
| `WEB-AUTH-013` | Login B mất body khi cookie còn A, đã thành B hoặc mất hẳn; refresh, tab mới, đóng/mở browser | Marker `loginUnknown` giữ UI khóa; GET /me không tự nhận A/B, người dùng phải xác nhận phiên hiện tại hoặc submit mới; storage lỗi cũng khóa và báo phục hồi. |
| `WEB-AUTH-014` | Giữ response A rồi thả sau khi B bootstrap; hai tab chung jar, thêm timeout và delayed logout clear-cookie | Cookie có thể đổi dù callback A bị bỏ; request kế mang context B phải 409/no data, cả hai tab khóa cache/UI khi mismatch hoặc nhận intent, reload không tự nhận A. Harness kiểm cookie jar/identity/status trước và sau response muộn; không hứa mỗi tab phiên riêng. |
| `WEB-AUTH-015` | /me hoặc /workspaces network/503 sau login hợp lệ | Giữ credential an toàn, ẩn protected UI; retry GET, không tự login/logout |
| `MB-AUTH-011` | Storage lỗi hoặc login response đến sau logout/đổi account | Không ghi token cũ; cleanup local; revoke best effort đúng token mới còn memory |
| `CT-AUTH-015` | Login/new password Unicode/emoji ở biên 8/9/128/129, current ở biên 0/1/128/129; new thiếu hoa/thường/số ASCII; email case/space/Unicode | Backend/TS/Dart cùng code-point count và policy fixture hiện hành; password giữ nguyên; login không áp composition mới cho credential cũ; email theo OQ001 |
| `CT-AUTH-016` | Duplicate JSON key/content type/oversize/unknown key | Mapping OQ008; không echo key/value attacker vào fieldErrors |
| `E2E-AUTH-008` | Quyền đổi giữa hai trang hoặc chỉ có workspace suspend | Restart khi cursor stale, không dùng quyền cũ; không gọi live resource bị khóa |

## 19. Tiêu chí chấp nhận

### Acceptance bắt buộc từ tài liệu

- `( )` `AT-WF-001-01` đã điều chỉnh scope: account hợp lệ đăng nhập Web và Android tạo session riêng, cùng membership hiện hành.
- `( )` `AT-WF-001-02`: account tạm gọi `/devices` trước đổi password nhận `403 PASSWORD_CHANGE_REQUIRED`.
- `( )` `AT-WF-001-03`: account có hai workspace không nhận dữ liệu workspace chưa chọn trong login/bootstrap.
- `( )` `TS-TN-001`: với account ACTIVE và credential đúng, Web và Android tạo session riêng.

### Acceptance bổ sung để developer không phải tự đoán

- `( )` Sai password, unknown email và account disabled có public response không tiết lộ nguyên nhân.
- `( )` Rate limit 5 lần sai/15 phút hoạt động atomic và client tôn trọng `Retry-After`.
- `( )` Login request không thể tự cấp role/workspace/permission.
- `( )` Web secret không lộ cho JavaScript khi dùng cookie; Android secret chỉ ở secure storage.
- `( )` Không có password/token/raw request body trong log, audit, metric hoặc evidence.
- `( )` Không có resource query trước workspace selection.
- `( )` UI có loading/error/rate-limited/password-change/workspace-empty/workspace-picker states.
- `( )` Contract tests Web/Android dùng cùng error/DTO semantics.
- `( )` `POST /auth/login`, `GET /me`, `GET /workspaces` khớp OpenAPI/fixture đã duyệt ở cả header, field type, requiredness, pagination và error envelope.
- `( )` Web limited chỉ dùng `/me` để nhận 403 + context/CSRF đối soát hoặc discovery khi UI khóa, không lấy profile/membership; `/workspaces` và resource vẫn bị guard 403. Android limited không gọi `/me` trong login flow.
- `( )` Auth events/metrics có correlation và bounded labels; canary scan chứng minh không có credential/PII bị cấm.
- `( )` Mỗi case trong test suite có kết quả `PASS`/`FAIL`/`BLOCKED`/`NOT_RUN` và evidence; không coi checklist văn bản là test pass.

### Execution checkpoint 15/11/2026 — backend output capture

**READY_FOR_QA cho capture harness; toàn feature `VERIFY_IN_PROGRESS`.** `python -B ops/auth/run_local.py --verify` exit0 với PostgreSQL thật, 370 check markers/333 ID khác nhau và `APPLICATION_ROWS_REMOVED`. Stdout primary/peer được scan từ đúng process đến EOF: mỗi stream 15 byte, 166 canary, không có canary/named-field match; stderr rỗng và structured log `NOT_RUN`. Sau khi run kết thúc, `python -B -m unittest discover -s ops/auth/tests -q` đạt133 tests và GPT-6.1 Sol high review không còn P0/P1/Important trong scope capture. [Report, hashes và giới hạn](../../test-reports/FEAT-TN-001-backend-output-capture-2026-11-15.md), [provider evidence](../../../ops/auth/evidence/provider-latest.json).

Output-capture DB run lúc `2026-11-15T06:13:52Z` có `structuredLog=NOT_RUN` và kết thúc trước sửa semantics test; regression sau sửa xác nhận event chứa secret không thể được báo structured-log PASS. Provider DB run riêng lúc `2026-11-15T07:56:01Z` chạy sau fix, đạt provider scope 370/333; run đó cũng không có structured log event để chứng minh sink. Không có remote exporter hoặc structured log event để fault-inject trong backend hiện tại. `IT-AUTH-011`, `SEC-AUTH-002/009`, Chrome/E2E tổ hợp và acceptance owner vẫn theo ma trận; checklist mục19 không được tick từ run này.

## 20. Evidence bắt buộc

- OpenAPI/fixture version và compatibility result.
- Backend unit/integration/contract/security test reports.
- Web component/integration test report và accessibility evidence.
- Flutter widget/integration test report trên Android target.
- E2E trace gồm correlationId, session IDs đã che, client types và membership result.
- Audit sample đã redaction.
- Log scan chứng minh không có password/token/cookie.
- Bản chốt `OQ-AUTH-*` kèm người duyệt; OpenAPI và fixtures versioned trước khi backend/client code.
- Ma trận provider serialization → Web parser → Android parser cho success, validation, auth failure, rate limit và limited session.
- Kết quả header inspection (`Set-Cookie`, `Cache-Control`, `Retry-After`, CORS/CSRF theo deployment), DB row/digest và cross-workspace query guard.
- Screenshot/video chỉ là bằng chứng bổ sung; không thay API/test log.

Mỗi evidence record phải có `buildId`, môi trường, browser/device/OS, fixture/input, expected, actual, status, evidence path và defect ID.

## 21. Rủi ro và biện pháp

| Mã | Rủi ro | Tác động | Biện pháp |
| --- | --- | --- | --- |
| `R-AUTH-001` | Email normalization khác DB unique rule | Login sai account/duplicate | Chốt một normalization contract trước code |
| `R-AUTH-002` | Deployment khác giả định cùng origin | Cookie/CSRF không hoạt động hoặc kém an toàn | G1 kiểm topology, policy 13.1 và OQ002 trước client BUILD |
| `R-AUTH-003` | Rate limit theo IP sai sau proxy | Bypass hoặc khóa nhầm | Chốt trusted proxy/composite key policy |
| `R-AUTH-004` | Client dùng membership summary làm quyền | Stale privilege | Request luôn resolve membership server-side |
| `R-AUTH-005` | Cache account trước hiện trong bootstrap | Rò dữ liệu | Isolate/clear cache theo account/context |
| `R-AUTH-006` | Response login mất sau commit | Session mồ côi/UX không rõ | Chốt recovery UX và session limits |
| `R-AUTH-007` | DTO login, profile, workspace list chưa có wire schema đầy đủ | Backend/Web/Android tự đoán khác nhau | Duyệt JSON schema và fixtures trong `OQ-AUTH-009` trước code |
| `R-AUTH-008` | Audit/log vô tình ghi credential/PII | Lộ bí mật, khó thu hồi | Allowlist fields, canary scan, phân quyền xem log và review retention |
| `R-AUTH-009` | `mustChangePassword` đổi trong lúc session còn sống | Limited guard sai, nâng quyền ngoài ý muốn | Chốt nguồn trạng thái hiện hành và test session stale |

## 22. Trả lời câu hỏi và quyết định thiết kế

Đã trả lời 13 câu hỏi để có một phương án thực thi cụ thể. ADR-002 chốt phương án để thực thi theo yêu cầu người thực hiện; runtime và artifact G1 vẫn phải được kiểm chứng. Giả định môi trường được tách riêng; giữ mã OQ để truy vết. Những đoạn trước dùng chữ “đề xuất/chờ chốt” trỏ tới câu trả lời tại bảng này, không phải 13 quyết định còn bỏ ngỏ.

| Mã | Câu trả lời áp dụng trong plan | Gate/owner kiểm chứng |
| --- | --- | --- |
| `OQ-AUTH-001` | Email trim ASCII whitespace hai đầu, lowercase ASCII toàn địa chỉ; baseline hỗ trợ ASCII email tối đa 254 ký tự, local ≤64; từ chối Unicode email, không tự bỏ dấu chấm/+tag. Validate sau canonicalize; login/create/invitation dùng cùng unique rule. Password theo Password policy addendum mục1: login 9–128 Unicode scalar/codepoints, current 1–128, new 9–128 có chữ hoa, chữ thường và số ASCII0–9. Login verify không áp composition mới cho credential cũ. Không trim/normalize; surrogate không hợp lệ bị từ chối. Công bố cùng policy fixture version1; baseline12–128 chỉ còn là lịch sử. | IAM/API: G1 kiểm collision và email hiện hữu ngoài tập hỗ trợ trước áp dụng; không tự merge/xóa account hoặc migration phá dữ liệu. Password: đối chiếu fixtures/tests ba stack; cập nhật trace này không tự đóng gate runtime hoặc compatibility. |
| `OQ-AUTH-002` | Baseline giả định Web/API cùng HTTPS origin qua reverse proxy; cookie/CSRF theo mục 13.1. Nếu deployment khác origin, review lại policy trước build Web; không mở credentials CORS mặc định. | Backend/Web: ghi origin và trusted proxy không secret; browser test thực tế. |
| `OQ-AUTH-003` | Android Authorization Bearer, không Cookie; OS secure storage, không backup plaintext. Write storage lỗi thì không login complete, xóa local state dở dang, revoke best effort đúng token mới còn memory theo 002; thất bại không giả đã revoke server. Không giữ password retry. | Mobile: reuse dependency được duyệt; PoC storage/restart/backup/key failure trên min OS. Thiếu plugin phù hợp là gate, không tự cài. |
| `OQ-AUTH-004` | PostgreSQL atomic theo email digest, không email+IP làm hàng rào duy nhất; 5 failure/15 phút fixed window, thứ tự/reset/Retry-After tại 14.1. Account lockout hữu hạn vẫn là risk phải ghi nhận. | Backend/security: sáu concurrent request, nhiều instance, đo pool/hasher/lock budget tại G1. |
| `OQ-AUTH-005` | Không auto retry login. Mất body giữ `loginUnknown` qua reload; `/me` discovery chỉ cho người dùng xác nhận phiên hiện tại. Body đã parse thì Web kiểm /me cùng ID và `X-Auth-Context-Id`; mọi Web protected request dùng context fence mục13.1. App mất token chờ submit chủ động. Orphan expiry 24 h/cleanup; không thêm session cap trái kỳ vọng phiên độc lập. | E6/E2E-AUTH-006, WEB-AUTH-013/014, fault injection commit unknown và browser cookie race. |
| `OQ-AUTH-006` | Ma trận Web: Chrome, Edge, Firefox desktop stable tại thời điểm test. Android: minimum OS tương thích SDK/plugin đã pin và một thiết bị thật OS dự án hỗ trợ. Không đoán API level khi chưa có manifest/PoC; G1 ghi số phiên bản/min OS/device cụ thể. | QA/Mobile: thiếu manifest thì chưa qua G1 Mobile/không nghiệm thu; task contract độc lập vẫn làm được. |
| `OQ-AUTH-007` | Giữ enum WEB/ANDROID/IOS của nguồn. IOS theo App bearer contract và fixture server; không build/test iOS UI/signing/push/BLE. clientType chỉ metadata/transport, không chứng thực platform/quyền. | API: CT-AUTH-004; metrics có IOS, enum lạ map UNKNOWN. |
| `OQ-AUTH-008` | JSON hỏng/duplicate key: 400 VALIDATION_ERROR; >64 KiB: 413 VALIDATION_ERROR; không JSON: 415 VALIDATION_ERROR; JSON đúng nhưng thiếu/null/type/length/enum/unknown field: 422 VALIDATION_ERROR. fieldErrors path là JSON Pointer /email,/password,/clientType; lỗi toàn body/unknown key dùng path rỗng. Code allowlist REQUIRED/TYPE/FORMAT/LENGTH/ENUM/UNKNOWN_FIELD/MALFORMED_JSON/DUPLICATE_FIELD/BODY_TOO_LARGE/CONTENT_TYPE; không echo key/value tùy ý. Mixed credential 400 VALIDATION_ERROR; CSRF 403 CSRF_INVALID. | API: G1 khóa fixture cả framework/proxy errors; field-error order theo schema. |
| `OQ-AUTH-009` | Login Web {me:{id,email,mustChangePassword},expiresAt,limited} kèm response header `X-Auth-Context-Id`; App thêm token và không dùng context Web. GET /me Web full/limited cũng trả context header; `/me` có ít nhất ba field profile khi full, không global role. Workspace item {id,name,status,role,revision}, envelope items/nextCursor. UUID ID, integer revision, UTC RFC3339 expiry; limited khớp mustChangePassword. Request strict; clients kiểm required/type/invariant, bỏ qua response field bổ sung và không dùng làm authority. Token Web bị cấm cả khi response có extension; context ID cũng không là quyền. | API/Web/Mobile: /me tích hợp041 thêm displayTimezone/preferencesRevision (UTC/1 khi missing theo041), login me summary giữ ba field; sửa OpenAPI/fixture và review ở CP-01 trước BUILD. |
| `OQ-AUTH-010` | Picker vận hành mặc định Membership ACTIVE + Workspace ACTIVE, không tự chọn dù một item. Empty copy “Không có workspace khả dụng”, không khẳng định chưa từng có membership; tạo workspace theo 065/quota. Admin historical view explicit thuộc 068; không đưa live data suspend/archive vào bootstrap. | Workspace/API: thống nhất default filter với 065–068 tại G1. Cursor bound user/filter/sort; quyền thay đổi thì restart; không hứa snapshot bất biến giữa trang. |
| `OQ-AUTH-011` | Guard đọc User hiện hành và session revokedAt/expiresAt; mustChangePassword=true là limited. /me và /workspaces 403 PASSWORD_CHANGE_REQUIRED không dữ liệu; /me metadata CSRF theo 13.1. Đổi password revoke mọi phiên, login lại theo WF004; không tự nâng limited cũ thành full. | IAM: stale session và password/disable race test. |
| `OQ-AUTH-012` | Session/audit success atomic, fail503 trước credential; limiter failure fail-closed. Rejection audit unavailable theo WF040 E2 được operational metric, không rollback limiter đã commit và vẫn deny auth. Boundary/savepoint theo14.1; commit unknown không giả rollback. | Backend/security: IT-AUTH-011/012 fault injection, đồng bộ040. |
| `OQ-AUTH-013` | App log chỉ correlation/clientType/public outcome/duration, không email/IP raw/userId/sessionId hoặc reason unknown/disabled. Audit được bảo vệ có actorId/sessionId nội bộ chỉ ở success; failure actorId null, không phân biệt existence. Audit login global không tự cấp quyền cho Admin workspace. | Security/operations: audit retention 30 ngày; G1 ghi access/retention log vận hành, canary scan, bounded labels. |

### Gate theo thời điểm tạo evidence, cùng thứ tự `implementation-start.md`

| Checkpoint | Evidence cần có trước khi đi tiếp | Evidence chỉ có sau BUILD tương ứng |
| --- | --- | --- |
| `CP-01` artifact, trước `START-04` | OpenAPI/fixture versioned, validation log, context header/error và trạng thái recovery mục13.1 được API/Web/Mobile owner review; `/me`041 và workspace filter đã đồng bộ. | Không yêu cầu handler/client runtime để bắt đầu backend; provider-client compatibility vẫn NOT_RUN. |
| `START-03` prerequisite, trước backend/Web/Android liên quan | Actual repo paths/runner, dependency pin được duyệt, topology origin/proxy, hash/token/storage strategy, budget và phép đo cho hash/queue/lock/pool; email collision assessment. Android secure-storage/min OS PoC trước storage thật. | Số đo concurrency/lock/pool thật tạo khi có backend, không gán PASS từ kế hoạch. |
| `START-04 → CP-02` backend | P2/P3 dựng full/limited session, limiter, CSRF/context fence, password/disable race, audit/commit UNKNOWN; chạy IT/SEC/CT trên provider + DB, đo cùng key/nhiều key và pool/lock/hash thực tế. | `CP-02` cần no-secret/no-bypass và evidence, rồi mới mở Web integration. |
| `START-05/06` clients | Web sau `CP-02` + topology; Android sau `CP-02` + storage PoC. Tạo provider-client compatibility, browser cookie race và Android storage/restart evidence ở đây. | Không dùng fixture/mock làm bằng chứng UI hoặc integration thật. |
| `CP-03` acceptance | Tổng hợp G1 liên client, G3 isolation phần áp dụng, AT-WF và negative/security; owner/QA review, không P0/P1 mở. | Chỉ sau evidence này mới xét nghiệm thu FEAT, không hạ gate cuối. |

`G1-AUTH-CONTRACT/ENV/SECURITY` giữ nguyên chất lượng nhưng được chia đúng thời điểm: artifact contract ở CP-01, prerequisite của đường chạy ở START-03, provider/security measurement ở CP-02, client compatibility và acceptance ở CP-03. Không giả owner đã ký duyệt, phiên bản SDK/OS, PoC hay benchmark PASS; không hardcode secret hoặc tự thêm dependency.

## 23. Checklist triển khai

Các mục code đã kiểm được ghi READY_FOR_QA theo report15/11. Approval và acceptance tổng thể giữ mở theo đúng evidence còn thiếu.

### Contract và data

- `( )` OpenAPI/fixtures được duyệt.
- [x] READY_FOR_QA — Error codes/messages ổn định.
- [x] READY_FOR_QA — User/Session/Membership migrations và constraints sẵn sàng.
- [x] READY_FOR_QA — Compatibility note phân biệt iOS UI ngoài scope và IOS bearer server theo OQ007, đã có provider/contract test.
- `( )` `OQ-AUTH-001…013` có quyết định/owner rõ; mục có ảnh hưởng wire/security đã duyệt trước khi code.

### Backend

- [x] READY_FOR_QA — Boundary validation.
- [x] READY_FOR_QA — Password verification và rate limit.
- [x] READY_FOR_QA — Full/limited session creation.
- [x] READY_FOR_QA — `/me` và `/workspaces` bootstrap.
- `( )` Audit/log/metrics redaction.

### Web

- [x] READY_FOR_QA — Login form và states.
- [x] READY_FOR_QA — Cookie/session bootstrap.
- [x] READY_FOR_QA — Password-change/workspace routing.
- [x] READY_FOR_QA — Accessibility tests.

### Android

- [x] READY_FOR_QA — Login form và states.
- [x] READY_FOR_QA — Secure storage/session bootstrap.
- [x] READY_FOR_QA — Password-change/workspace routing.
- [x] READY_FOR_QA — Cache isolation theo account.

### Verification

- `( )` Toàn bộ test suite liên quan đã chạy và evidence hợp lệ.
- `( )` Không còn defect P0/P1.
- `( )` P2/P3 nếu có đã ghi owner/impact/workaround/acceptance.

## 24. Đầu ra bàn giao

- Contract/fixtures của login/bootstrap.
- Backend IAM/session implementation và tests.
- Web login/bootstrap UI và tests.
- Android login/bootstrap UI và tests.
- Security/redaction evidence.
- Acceptance report truy vết `FEAT/FR/UC/WF/AT-WF/TS`.

## 25. Điều kiện hoàn thành

Chỉ đổi **trạng thái triển khai** sang `(x)` khi đồng thời; trạng thái review kế hoạch ở đầu file không thay thế các điều kiện này:

1. Dependency/DoR không còn bị chặn.
2. Contract, implementation và UI Web/Android khớp cùng semantics.
3. Acceptance bắt buộc đã `PASS` với evidence thật.
4. Negative/security/cross-scope cases đã chạy, không chỉ happy path.
5. Không có P0/P1 mở.
6. Không có secret trong repository/log/evidence.
7. Code, contract và QA review hoàn tất.
8. File được cập nhật đường dẫn evidence/trạng thái thực tế; không đánh `PASS` chỉ vì tài liệu đã viết.

## 26. Tóm tắt bàn giao cho developer

- Dùng câu trả lời OQ-AUTH-001…013 tại mục 22; bắt đầu P1 mục 27 để tạo artifact/evidence G1. Thiết kế đã được chốt tại ADR-002; implementation và evidence G1 chưa hoàn tất.
- Sau khi contract được duyệt, triển khai backend authentication/session trước, rồi Web và Android trên cùng fixture.
- Test tối thiểu: `UT-AUTH-*`, `IT-AUTH-*`, `CT-AUTH-*`, `SEC-AUTH-*`, `WEB-AUTH-*`, `MB-AUTH-*`, `E2E-AUTH-*` và `AT-WF-001-01…03` cho Web + Android; iOS UI không áp dụng theo ADR-001.
- Không tự thêm self-registration, forgot-password, social login, MFA, SSO hoặc iOS.
## 27. Thứ tự thực thi và checkpoint

Tháo phụ thuộc vòng: WF001 cần model Workspace/Membership của 065/066, nhưng mutation 065/066 cần auth. Chốt schema/contract/fixture nền trước; không chờ toàn bộ UI 065/066 để làm login và không dùng seed bypass quyền trong bản chạy thật. Audit writer tối thiểu là nền 040, không đợi UI audit. Contract 002/004 phải tương thích và có integration logout/password trước nghiệm thu account tạm; không chờ push/realtime hoàn chỉnh của 002 để kiểm session cơ bản.

| Task/trạng thái | Lát cắt, đầu ra và nghiệm thu | Phụ thuộc | Vùng dự kiến/quy mô | Evidence/checkpoint |
| --- | --- | --- | --- | --- |
| `P1 ( )` | Khóa contract/fixture mục 22 và 13.1, manifest hạ tầng/test; đồng bộ 002/004/041/065/066/067 | BA/handoff | contracts/tài liệu auth; tách nếu >5 file | `CP-01` artifact + `START-03` prerequisite; không đòi provider/client runtime trước BUILD |
| `P2 ( )` | Backend Session/User/audit + full/limited login handler với limiter, CSRF và auth-context fence trong đường xử lý đầu tiên; không có Web form ở lát cắt này | `CP-01` + phần backend `START-03` | IAM schema/repository/service/handler/tests; chia nhóm ≤5 file sau khi chốt actual path | CT/IT success+failure; chưa tích hợp client/chưa coi security thiếu là đủ dùng |
| `P3 ( )` | Backend negative path: password/disable fence, limited, commit UNKNOWN, audit fault, concurrency/lock/pool/hash measurement | P2 + boundary002/004/040 | IAM guards + IT/SEC/CT; chia theo boundary ≤5 file | `CP-02`: no bypass/no secret, measurement và fault evidence; P2/P3 là một backend gate không phát hành riêng |
| `P4 ( )` | Web login full/limited, shared auth coordinator001/002, cookie/context recovery, picker/empty/pagination/recheck | `CP-02` + topology Web + model/fixture065/066/067 | Web API/state/UI/tests; chia ≤5 file | Browser thật: WEB012–015, response A tới sau B, reload/two tabs; AT-WF-001-03 |
| `P5 ( )` | Android full/limited/storage/picker/restart/account switch theo cùng contract | `CP-02` + storage/min OS PoC + model/fixture workspace; không phụ thuộc Web UI P4 | mobile auth/workspace/tests; chia ≤5 file | MB tests Android; phiên Web/Android riêng ở CP-03, AT-WF-001-01/02 |
| `P6 ( )` | Ma trận mục 18–20, redaction/accessibility/fault injection, acceptance report/review | P4 + P5 + integration 002/004/065/067 | evidence và defect đúng phạm vi | `CP-03`: G1 liên client/G3 isolation phần áp dụng, không P0/P1; trạng thái test thật |

Đồ thị phụ thuộc duy nhất: `P1/CP-01 + START-03 backend → P2/P3/CP-02 → P4 Web và P5 Android → P6/CP-03`; Android storage PoC trước P5, topology Web trước P4. `implementation-start.md` chỉ là điểm vào của đúng các task này. Trước khi giao subtask BUILD, START-03 phải xác nhận actual file paths/runner từ checkout hiện tại, tối đa 5 file/subtask và ghi AC, verification, rollback vào ngay mục này; hiện Rust workspace, domain/application/PostgreSQL crates và migrations đã có nhưng chưa có HTTP auth server/handler, Web có auth draft nhưng chưa có browser evidence, Android chưa có pubspec. Không giả tên file/runner auth chưa tồn tại. Giữ checklist chưa hoàn thành đến khi có evidence. Rollback dùng migration additive và contract tương thích; nếu auth mới lỗi, dừng rollout/khôi phục bản an toàn, không bỏ guard/CSRF/context fence/limiter hay phục hồi token plaintext.

### 27.1 Nhật ký lịch sử trên nhánh dev — contract 0.1.0

Đây là snapshot trước review REV-AUTH-001…004; trạng thái hiện hành ở mục27.3.

P1 tổng vẫn ( ) vì chưa có owner review, provider/client test, topology/dependency pin và benchmark bảo mật; P2–P6 vẫn ( ). Phần contract P1-A/P1-B ở trạng thái READY_FOR_QA cho review artifact tĩnh, không phải nghiệm thu chức năng. START-03 là MISSING_INPUT theo manifest; CP-01/G1-AUTH-* là NOT_RUN.

Code state bàn giao: nhánh dev từ main tại a9400ad, chưa commit; bảy file contracts/ops được stage để review, gồm test QA mới. Ba file docs/plan giữ thay đổi cục bộ, không đưa vào index trong lần bàn giao này vì .gitignore của repository bỏ qua toàn bộ docs. Working tree vẫn dirty; các thay đổi chưa stage ở `.gitignore`, `web/public/.gitkeep` và `web/src/.gitkeep` nằm ngoài bản sửa QA này và được giữ nguyên.

| Lát cắt | Artifact và phạm vi | Kiểm chứng hiện có / điều còn thiếu |
| --- | --- | --- |
| P1-A READY_FOR_QA (contract tĩnh) | OpenAPI auth 0.1.0: login Web/App full/limited, GET /me, logout002, đổi mật khẩu004, error/header/CSRF; fixture synthetic, compatibility note. | Python unittest 9/9 PASS cho static suite gốc và QA coverage sau sửa QA-AUTH-001/002. Chưa có provider, client parser hay browser chạy. |
| P1-B READY_FOR_QA (contract tĩnh) | GET /workspaces default ACTIVE, empty/multiple/cursor/limited; GET detail để recheck chọn workspace; POST create065 tối thiểu, summary/detail DTO, quota/idempotency fixture. | Trong 9/9 static checks có fixture workspace; chưa review historical filter với owner065–068 hoặc chạy DB authorization. |
| P1-C MISSING_INPUT | Manifest không secret tại ops/environment/auth-readiness.md ghi actual/unknown và kế hoạch đo. | Rust/PostgreSQL/Web/Android toolchain, reverse proxy, hash/storage PoC và số đo chưa có; không tự pin/cài dependency. |

File artifact: contracts/openapi/auth.v1.json; contracts/fixtures/auth/scenarios.json và workspace-scenarios.json; contracts/tests/validate_auth_contract.py và test_auth_qa_coverage.py; contracts/README.md; ops/environment/auth-readiness.md. Mục16.1/17.1 bổ sung layout, component, navigation và state matrix theo design system. Các giá trị credential/token trong fixture chỉ là chuỗi tổng hợp/marker không hoạt động.

Evidence thực chạy tại lát cắt này: lệnh python -B -m unittest discover -s contracts/tests -p '*.py' -v trả exit 0, 9 test OK; JSON parse 3 artifact trả exit 0. Hai QA test đã FAIL trước khi thêm fixture và PASS sau sửa. Đây là kiểm tra nội bộ contract, không là OpenAPI conformance đầy đủ hoặc CT provider/consumer. Browser Web, Android emulator/thiết bị, backend integration, bảo mật đồng thời/fault injection, AT-WF-001-01…03 đều NOT_RUN vì chưa có ứng dụng/runtime và các gate trong manifest.

Tester tái hiện hiện tại: dùng working tree nhánh dev này và chạy static suite ở trên; đối chiếu CT-AUTH-WEB/ANDROID-FULL/LIMITED, CT-AUTH-BODY-TOO-LARGE, CT-AUTH-UNSUPPORTED-CONTENT-TYPE, CT-AUTH-ME-LIMITED, CT-AUTH-INVALID/WRONG-PASSWORD/DISABLED, CT-AUTH-RATE-LIMITED, CT-AUTH-COMMIT-UNKNOWN và CT-BOOTSTRAP-EMPTY/TWO-WORKSPACES/CURSOR-STALE trong fixture với OpenAPI. Khi backend/Web/Android có runtime, dùng account synthetic ACTIVE và temporary, hai workspace A/B có role khác nhau; thử login Web/App độc lập, limited gọi /me và resource bị 403, 5 lần sai rồi 429, mất response, logout/reload, list empty/cursor stale, membership đổi trước chọn. Chỉ ghi PASS sau khi lưu request/status/UI/network evidence đã redaction; không dùng screenshot tĩnh để kết luận luồng hoạt động.

Task đủ dependency tiếp theo: API/Web/Mobile owner review contract 0.1.0 và fixture (CP-01 phần artifact); xác nhận topology HTTPS/proxy, chọn và pin Rust/PostgreSQL/hash/session dependency sau PoC, đo budget theo manifest; sau đó tách P2 thành User/Session/audit transaction và handler/login Web trong mỗi lát cắt tối đa năm file. Web browser flow bắt đầu sau backend CP-02 và toolchain Web; Android storage/UI sau PoC plugin/min OS. Nếu owner phát hiện lệch wire, cập nhật contract/fixture trước BUILD.

### 27.2 Sửa phát hiện QA retest 2026-10-22 trên contract 0.1.0

Báo cáo QA gốc tại `docs/Test reports/FEAT-TN-001-qa-retest-2026-10-22.md` ghi 7 PASS/2 FAIL trên code state cũ; giữ kết quả đó làm bằng chứng lịch sử. Trên code state hiện tại, hai QA test tái hiện FAIL trước sửa và 9/9 static tests PASS sau sửa. Trạng thái dưới đây là **DEV_FIXED_READY_FOR_QA**, chưa phải QA đóng defect hay CP-01/G1 PASS.

| Defect | Sửa trong phạm vi artifact | Kiểm chứng và giới hạn |
| --- | --- | --- |
| `QA-AUTH-001` | Thêm fixture login limited Web và Android; giữ `mustChangePassword=true`, Web cookie/CSRF không body token, Android bearer không cookie. | QA coverage kiểm bốn tổ hợp full/limited và transport; chưa có provider/client runtime. |
| `QA-AUTH-002` | Thêm fixture 413 cho body JSON hợp lệ dài đúng 65.537 byte và 415 cho JSON gửi với `text/plain`; error field code tương ứng, không session/cookie/credential. | QA coverage dựng body 413 từ generator, kiểm status/error/no-store; nhánh thiếu/null/sai kiểu/biên/unknown cần fixture và provider test bổ sung trước CP-01. |
| `QA-AUTH-003` | Chuyển documentation comment tiếng Việt lên ngay trên tất cả function definition trong `validate_auth_contract.py`, kể cả hàm lồng và `setUpClass`. | Cần QA review độc lập vị trí comment; hành vi test không đổi. |

Không sửa OpenAPI wire hoặc version 0.1.0; README mô tả fixture và cách tạo raw body 413. Không có backend/Web/Android runtime nên AT-WF-001-01…03, browser và emulator vẫn NOT_RUN. Ba file plan và báo cáo QA trong `docs/` giữ cục bộ theo yêu cầu không đưa toàn bộ docs vào commit.

### 27.3 Snapshot phản hồi review vòng 1 REV-AUTH-001…004 — contract 0.2.0 draft

Review tại `docs/reviews/FEAT-TN-001-login-plan-review-2026-10-22.md` là bằng chứng lịch sử `REQUEST CHANGES` trên plan cũ. Bản sửa này là **DEV_FIXED_READY_FOR_QA** ở mức plan/contract tĩnh, chờ reviewer và API/Web/Mobile owner xác nhận; không tự đổi verdict của báo cáo cũ, không đánh CP-01/G1 hoặc toàn feature PASS.

| Finding | Thay đổi đã làm | Checkpoint còn phải chứng minh |
| --- | --- | --- |
| `REV-AUTH-001` | Mục13.1 đặt Web `authContextId` không secret, response/request header và server fence trước dữ liệu/side effect; login/logout/account switch dùng một coordinator. Contract 0.2.0 có 409 và fixture mismatch `/me`, workspace, logout. WEB-AUTH-014 kiểm cookie A đến sau B. | CP-01 owner duyệt wire; START-05/CP-03 browser thật đo cookie jar, hai tab, timeout, reload và protected request sau response muộn. |
| `REV-AUTH-002` | Marker không secret bền qua reload có ưu tiên `logoutPending → loginPending/loginUnknown → accepted`; `/me` không header chỉ là discovery khi UI khóa, cần xác nhận chủ động. E6, E2E-AUTH-006 và WEB-AUTH-013 bao phủ cookie A/B/mất cookie, reload, tab mới và browser reopen; storage lỗi fail closed. | CP-01 review state policy; START-05/CP-03 test browser với pending/unknown, limited và storage denied. |
| `REV-AUTH-003` | Mục22/27 và implementation-start dùng cùng graph CP-01 artifact → START-03 prerequisite → P2/P3 backend/CP-02 → P4/P5 clients → CP-03 acceptance. P2 đã có limiter/fence/CSRF; Web form thuộc P4. | CP-01 owner review và START-03 xác nhận actual paths/runner/AC/verification/rollback trước giao BUILD; CP-02/03 mới tạo runtime evidence. |
| `REV-AUTH-004` | Tóm tắt acceptance mục26 ghi Web + Android; iOS UI ngoài phạm vi. | Reviewer đối chiếu với mục19 và ADR-001. |

Code state tại snapshot vòng 1: nhánh `dev`, chưa tạo commit cho lần sửa review này. Các thay đổi tracked gồm OpenAPI, hai fixture, hai static test, `contracts/README.md` và `ops/environment/auth-readiness.md`; tài liệu `docs/` là thay đổi local bị `.gitignore` bỏ qua và không đưa vào commit theo yêu cầu. Web chỉ có trang giới thiệu, không có provider auth hoặc Android runtime. Contract `0.2.0` draft đổi wire so với `0.1.0`; static suite 11/11 PASS nội bộ, JSON parse PASS tại snapshot này. Provider/client compatibility, browser race, emulator/thiết bị, fault injection và QA review độc lập đều NOT_RUN.

Tester hiện tại: chạy `python -B -m unittest discover -s contracts/tests -p '*.py' -v`; kiểm fixture `CT-AUTH-ME-DISCOVERY`, `CT-AUTH-ME-CONTEXT-MISMATCH`, `CT-BOOTSTRAP-CONTEXT-MISSING/MISMATCH` và `CT-AUTH-LOGOUT-CONTEXT-MISMATCH` với OpenAPI. Khi backend/Web sẵn sàng, harness giữ response login A đến sau B đã được xác nhận; ghi cookie jar, status 409 của GET bảo vệ mang context B, UI/cache khóa, reload/two-tab và xác nhận phục hồi chủ động. Lặp với login B mất body nhưng cookie A/B/mất cookie, và storage denied. Chỉ ghi PASS sau khi có request/network/UI evidence đã redaction; screenshot tĩnh không chứng minh nghiệp vụ.

Task tiếp theo đủ dependency: API/Web/Mobile owner review contract/fixture 0.2.0 và ADR-002 addendum tại CP-01; hoàn thiện START-03 backend dependency/topology/runner/chi phí đo cùng vùng file thực tế và AC. Sau CP-01 + prerequisite backend mới giao P2/P3, rồi CP-02 trước Web/Android. Nếu owner đổi wire, cập nhật contract/fixture/test và plan trước BUILD.

### 27.4 Phản hồi review round 2 — limited confirmation và timing gate

Báo cáo round 2 tại `docs/reviews/FEAT-TN-001-login-plan-review-2026-10-22.md` ghi `Needs changes` với 1 Important/1 Nit trên snapshot cũ. Bản sửa này là **DEV_FIXED_READY_FOR_QA** ở mức plan/fixture; verdict của reviewer, CP-01, G1 và toàn feature chưa được tự đổi thành PASS.

| Finding | Bản sửa và bằng chứng tĩnh | Phần còn chờ |
| --- | --- | --- |
| `R2-AUTH-001` Important | Mục 8.1/8.2, 10.1, 13.1, 16/16.1 và `WEB-AUTH-005/010/012` cùng yêu cầu Web limited gửi `/me` kèm context sau login, chỉ nhận 403 đúng code + response context trùng mới ghi `accepted`/mở đổi mật khẩu. Discovery không header tách khỏi confirmation; fixture `CT-AUTH-ME-LIMITED-CONFIRMATION` và `CT-AUTH-ME-LIMITED-CONTEXT-MISMATCH` cùng static assertion mới. Android limited vẫn dùng bearer và đi thẳng đổi mật khẩu. | Web/IAM/QA owner duyệt tại CP-01; browser kiểm response thiếu/sai context, 200 bất thường, 401, 409, network/503 và reload tại START-05/CP-03. |
| `R2-AUTH-002` Nit | Manifest readiness tách prerequisite trước BUILD với measurement/evidence sau BUILD theo CP-02/03; README đặt owner review ở CP-01, không yêu cầu producer/client runtime tại đây. | START-03 vẫn MISSING_INPUT; benchmark/backend/browser/device evidence phải được tạo ở checkpoint tương ứng. |

Code state bàn giao round 2: nhánh `dev`, HEAD và dirty working tree xác nhận bằng `git status` khi bàn giao; không commit hoặc stage `docs/`. File tracked liên quan: `contracts/fixtures/auth/scenarios.json`, `contracts/tests/validate_auth_contract.py`, `contracts/README.md`, `ops/environment/auth-readiness.md` cùng các thay đổi draft 0.2.0 từ vòng 1. Static suite 12/12 PASS và JSON parse 3/3 PASS nội bộ; provider/client, browser, Android và security runtime vẫn NOT_RUN.

Tester chạy `python -B -m unittest discover -s contracts/tests -p '*.py' -v`, đối chiếu ba fixture limited discovery/confirmation/mismatch với `GET /me` trong OpenAPI. Khi có runtime, dùng account tạm login Web và giữ màn khóa cho đến khi `/me` kèm context trả 403 + context trùng; inject 409, 401, network/503, thiếu/sai response context và 200, rồi xác nhận không có `accepted`/picker/resource. Thử Android limited riêng: lưu bearer và điều hướng đổi password, không gửi Web context. Bước tiếp theo đủ dependency là owner review artifact 0.2.0 tại CP-01 và hoàn thiện START-03 trước P2/P3.

### 27.5 Lát cắt tiếp tục ngày 2026-10-23 — chuẩn bị kiểm thử trên draft 0.2.1

Phạm vi được yêu cầu là hoàn thiện001 để kiểm E2E. Discovery trên `dev@61b78dd`
xác nhận backend chỉ có README/placeholder, Web chỉ có trang giới thiệu và
Android chưa có `pubspec.yaml`. Contract hiện hành là **0.2.1 draft** từ002;
không dùng lại số test lịch sử trong27.3/27.4 làm kết quả hiện tại. Baseline
thực chạy: 30/30 static tests PASS; provider/browser/Android chưa chạy.

Tiếp tục P1 đã được phép theo ADR-002; review kế hoạch này đối chiếu mục8,
13.1, 18, 22 và dependency graph27. Không mở P2–P5 khi CP-01/START-03 chưa
đạt; không cài dependency, không viết UI giả để thay bằng chứng E2E.

| Task / trạng thái ban đầu | Mục đích và AC (tối đa ba điều kiện) | Phụ thuộc / vùng file / quy mô | Rủi ro, kiểm chứng, rollback |
| --- | --- | --- | --- |
| `P1-D1 READY_FOR_QA` | Bổ sung fixture validation login thiếu/null/sai kiểu từng field, biên password/email và field giả authority; khóa status/path/code/no-credential; có input hợp lệ tại biên password và ASCII email normalization. | P1-A hiện có, OQ001/008 đã chốt; `contracts/fixtures/auth/login-validation-scenarios.json`, `contracts/tests/test_login_contract.py`, `contracts/tests/validate_auth_contract.py`; M, ba file. | Fixture là yêu cầu, chưa phải provider observation. Static suite đã chạy 36/36 PASS; chờ review độc lập tại CP-01. Không đổi wire/version 0.2.1. |
| `P1-D2 READY_FOR_QA` | Ghi runbook có setup/reset/steps/expected/evidence cho E2E001–008 và các nhánh UI; đồng bộ feature/progress/readiness về trạng thái thực; ghi rõ CP-01/START-03 còn thiếu và task tiếp theo. | D1; feature001, `docs/plan/implementation-progress.md`, `docs/test-reports/FEAT-TN-001-readiness-2026-10-24.md`, `contracts/README.md`, `ops/environment/auth-readiness.md`; M, năm file. | Node coordinator tests 16/16 PASS với mock; runbook và manifest đã cập nhật. Runtime browser/API/Android chưa có nên acceptance nghiệp vụ vẫn NOT_RUN/BLOCKED. |

Checkpoint sau D1/D2: artifact bổ sung chỉ `READY_FOR_QA` khi static checks
thực chạy PASS; không đóng P1 tổng/CP-01/CP-02/CP-03, không đánh nghiệm thu
feature. UI giữ layout/component/navigation/state matrix16.1/17.1, token từ
`docs/UI web/design-system.md` và `home (2).html`; kiểm error summary phải
focus được, có link tới field và lỗi inline theo `ui-ux-pro-max`. Browser thật
và Android emulator/thiết bị là evidence sau P4/P5, không thay bằng screenshot.

Definition of Done của lượt này: fixture được cả runner chung và focused
suite kiểm; không thêm dependency hoặc secret; ghi lệnh/kết quả và file bàn
giao; liệt kê blocker runtime và hướng dẫn Tester. Owner review CP-01 và PoC
dependency ở START-03 là việc tiếp theo có thể thực hiện độc lập; backend chỉ
được bắt đầu sau hai gate tương ứng.

### 27.6 Tình trạng thực thi ngày 2026-10-24

Snapshot lịch sử ngày2026-10-24, không phải source/runtime hiện tại. HTTP lab,
Android pubspec/PoC và provider evidence đã bổ sung sau đó; dùng checkpoint
đầu feature plan và implementation-progress để điều phối tiếp. C1 vẫn chưa
có HTTP/coordinator/main composition thật; [audit hiện tại](../../test-reports/FEAT-TN-001-android-c1-readiness-2026-10-26.md).

P1-D1 và P1-D2 ở `READY_FOR_QA` cho artifact tĩnh, không đóng P1 tổng, CP-01,
START-03, CP-02 hoặc feature. Trên checkout `dev@ba425ad` có dirty working tree,
`python -B -m unittest discover -s contracts/tests -p '*.py' -v` chạy 36/36
PASS và `node --experimental-transform-types --test tests/auth.test.mjs`
trong `web/` chạy 16/16 PASS. Bộ Node kiểm tra coordinator/parser với mock; không
phải provider, browser hoặc E2E evidence.

Rust domain/application/PostgreSQL có session và identity code, nhưng checkout
chưa có HTTP server/handler để cung cấp `/api/v1/auth/login`, `/me` và
`/workspaces`. Web auth API/coordinator/UI và test mock hiện có trong working
tree nhưng chưa có browser runtime evidence; P4 vẫn chờ CP-02 và topology. Android
chưa có Flutter scaffold (`pubspec.yaml`), vì vậy P5 chưa thể bắt đầu. Không có
AT-WF-001-01…03 hoặc E2E-AUTH nào được đánh PASS.

Direct runner attempt on 2026-10-24 12:04 UTC: `python -B ops/database/verify_repositories.py` exited 1 at `EMPTY_GUARD` because canonical `iot_platform_lab` has application rows. It stopped before temporary role/fixture provisioning; do not reset application data to bypass the guard. The 89-check report at 10:52Z is historical and is not this run or FEAT-TN-001 E2E. See the [readiness report](../../test-reports/FEAT-TN-001-readiness-2026-10-24.md).

Review UI hiện có: mục 16.1 đã có bố cục và state matrix, nên không cần thêm
layout vào plan. Trước khi P4 được QA, cần thêm CTA tạo workspace cho empty state
theo FEAT-TN-065 (`web/src/features/auth/AuthPage.tsx:225`); màn thành công sau
chọn workspace hiện vẫn là placeholder (`AuthPage.tsx:242`). Các finding này
chưa được sửa trong lượt P1 vì CP-02 chưa mở.

Lệnh, kết quả, trạng thái công cụ, hướng dẫn tester và dependency tiếp theo nằm
trong [báo cáo readiness 2026-10-24](../../test-reports/FEAT-TN-001-readiness-2026-10-24.md).
Task tiếp theo: API/Web/Mobile owner review artifact tại CP-01 và hoàn tất
START-03 manifest (topology/proxy, toolchain/dependency, hash/session budget và
phép đo). Sau đó thực hiện P2/P3 đến CP-02; chỉ khi CP-02 đạt mới mở P4, còn P5
cần thêm Android storage/min-OS PoC.

### 27.7 Lát cắt runtime tiếp tục 2026-10-24

Yêu cầu hiện tại cho phép thực hiện phần còn thiếu để mở Web/App kiểm thử thật.
Áp dụng baseline 0.2.1 và đề xuất runtime đã ghi trong
`ops/toolchains/auth-runtime-proposal.md`; không dùng phê duyệt triển khai thay
cho owner review CP-01 hoặc nghiệm thu. Discovery mới: Rust GNU 1.99.1 đã chạy
được toàn workspace offline; Web build bằng `npm.cmd run build` PASS. Các nhận
định lịch sử thiếu linker không còn đúng với checkout này. Browser connector
hiện không có browser và tạo tab IAB bị từ chối; đây là blocker kiểm browser,
không phải lý do bỏ qua triển khai provider.

| Task | Mục tiêu / AC | Dependency / file / quy mô | Kiểm chứng / rủi ro / rollback |
| --- | --- | --- | --- |
| R6 — HTTP boundary | Strict JSON theo fixture; cookie/bearer không lẫn; origin/context/CSRF fail closed và error envelope/no-store. | Core identity/session hiện có; `backend/Cargo.toml`, lock, `src/http/mod.rs`, `src/http/security.rs`, `tests/http_auth.rs`; M. Axum 0.8.6 và tower 0.5.2 theo proposal, trong phạm vi cho phép hoàn thiện runtime. | Test request thật vào Router, negative boundary không đụng DB; PoC compile trước handler. Tắt transport mới nếu lỗi; không nới core guard. |
| R7 — Provider bootstrap | Nối login, /me, logout/password, picker/detail vào PostgreSQL/core; thông tin trả về allowlist; cursor ký và bound current identity/rights. | R6; read projection application/port/PostgreSQL và HTTP handlers, chia mỗi lần tối đa năm file. | Provider tests và DB scope evidence; không suy test fake là DB integration, không xóa dữ liệu canonical để chạy fixture. |
| CP-R7 | Kiểm security/core/transport trước Web integration; liệt kê rõ phần CP-02 chưa có evidence (race đa instance, ACK unknown, budget). | R6/R7. | Review độc lập kỹ thuật không giả owner sign-off; giữ CP-02 mở khi chưa đủ AC. |
| R8 — Web usable | Điều hướng sau chọn có workspace context, state/error phục hồi; empty CTA trỏ chức năng thật khi dependency065 sẵn sàng. | R7 + dependency065/067 tương ứng; không biến thiếu feature thành link chết hoặc success giả. | Build, coordinator regression, browser thật khi connector có sẵn. |
| R9 — Android prerequisite | Xác minh Flutter/Android toolchain và storage PoC; sau đó scaffold/UI/API thật theo mục17.1. | Toolchain/plugin/min OS được chứng minh. | Không đánh PASS nếu CLI treo, thiếu emulator hoặc thiết bị; không cài plugin chưa duyệt. |

Checkpoint sau R6/R7; Definition of Done: exact commands/outcomes và changed
files được ghi trong report/progress; code xong còn independent QA là
READY_FOR_QA. Không đóng toàn feature, G1, CP-01/02/03 bằng unit test.
Layout/component/navigation/state matrix mục16.1/17.1 và design system hiện có
được giữ làm nguồn UI; mọi thiếu layout của màn mới phải bổ sung trước code.

R8 bổ sung bố cục điểm đến sau chọn (phạm vi auth001): breadcrumb Workspaces →
tên workspace; heading tên workspace, thông báo quyền hiện hành, khối hồ sơ
đang đăng nhập và CTA “Chuyển workspace”/“Đăng xuất”. Không dựng dashboard số
liệu giả hoặc mở route feature chưa có. Picker có “Tải lại danh sách” qua
bootstrap hiện hành; empty state giải thích quyền và nút tạo workspace được
đánh chưa khả dụng cho đến dependency065. State loading/offline/error/conflict
tiếp tục qua coordinator, chuyển scope phải khóa nội dung trước GET. Dưới
480px các action xếp dọc, heading có focus, semantic breadcrumb; dùng token
design system. Browser evidence còn BLOCKED, không đánh R8 nghiệm thu.

### 27.8 Bằng chứng runtime slice và phần còn mở

#### R8-UI — thiết kế lại `/login` theo yêu cầu tiếp tục

Phạm vi được yêu cầu: UI Web auth, giữ contract/coordinator/API thật hiện có.
Plan review đối chiếu16.1 và design system: form tác vụ một cột, không thêm
hero/metrics, social login, đăng ký hoặc quên mật khẩu chưa có dependency.

- Layout: header logo Nexa + về trang chủ + theme toggle có tên; main đặt card
  tối đa khoảng30rem với icon trạng thái/heading/copy ngắn, email/password52px,
  toggle hiện mật khẩu và CTA đầy chiều rộng; hướng dẫn tài khoản ở dưới form.
  Nền mint/đường lưới rất nhẹ, card trắng/teal theo token, footer tối giản.
- Component: tái dùng SVG sprite nét1.8, bổ sung mail/lock/eye; các control có
  focus44px+, error summary và lỗi inline; loading có skeleton trang trí và
  status bằng chữ. Picker/recovery/limited dùng cùng shell, không hiện cache
  trước xác nhận phiên. Navigation vẫn qua coordinator; về trang chủ là link.
- State matrix16.1 giữ nguyên: offline không queuePOST, error/permission dùng
  copy phục hồi, unknown/stale khóa nội dung; success/empty không giả backend.
  Visual success dùng teal, error coral, pending amber và luôn có nhãn/icon.
- Responsive:320/768/1024/1440px, card co theo viewport, không chiều cao cố định,
  safe-area, keyboard/200%zoom, light/dark/reduced-motion. Không thêm dependency.
- Ordered slice: (1) shell/sprite/visual form (3files); (2) build + coordinator
  regression + browser nếu connector có sẵn; (3) cập nhật evidence/progress.
  AC: build PASS,16 existing coordinator tests PASS, UI không đổi wire/auth
  policy; browser chưa chạy thì READY_FOR_QA, không đánh nghiệm thu.
  Rollback: chỉ hoàn nguyên presentation slice, giữ API/coordinator.

Kết quả R8-UI lúc13:32 UTC 2026-10-24: **READY_FOR_QA**. Đã hiện thực shell,
form/icon/theme/status theo plan tại `AuthPage.tsx`, `auth.css`, `IconSprite.tsx`.
`npm.cmd run build` PASS và `npm.cmd run test:auth`16/16 PASS; ứng dụng vẫn dùng
API thật, không thêm package. Browser inventory vẫn rỗng; responsive/focus/
screen reader/visual và nghiệp vụ chưa được kiểm trên browser. Không đánh R8
nghiệm thu. [Bàn giao UI, log và checklist Tester](../../test-reports/FEAT-TN-001-login-ui-2026-10-24.md).

R8-UI tiếp tục theo yêu cầu đồng nhất với trang chủ: đối chiếu trực tiếp
`SiteHeader.tsx` và CSS thực tế; logo phải là biểu tượng radio trắng trên
gradient34px, wordmark nguyên bản; dùng chung `BrandLink` để tránh hai logo
khác nhau. Header72px/container1200px/lề24px, theme button44px và ghost link,
nền chấm26px, gradient CTA/card/heading theo home. Giữ single task card và
state matrix hiện có. Slice: BrandLink + hai nơi dùng + CSS; build/coordinator
regression, kiểm source contrast CTA, QA browser khi connector khả dụng.
Chữ CTA gradient dùng navy để giữ tương phản; không sao chép chữ trắng tương
phản thấp của CTA home sang form. Không thay logic đăng nhập hoặc dependency.

Snapshot13:37 UTC: slice đồng nhất home đã code; build41modules PASS,
16/16 coordinator mock tests PASS. BrandLink dùng chung hai trang; contrast
chữ CTA trên các điểm gradient tối thiểu5.05:1. R8-UI **READY_FOR_QA**,
browser verification vẫn BLOCKED; log/hash hiện hành trong bàn giao UI.

#### R9-A — contract consumer Dart độc lập trước app storage

Điều tra toolchain mới: cùng CLI trong sandbox timeout, ngoài sandbox trả
Flutter3.47.5/Dart3.13.4 exit0. Device discovery chưa có Android. Được phép
làm schema/fake adapter độc lập theo START-03; không dùng việc này để bỏ gate
secure storage hoặc CP-02. Kế hoạch review: parse JSON login Android theo
contract0.2.1, immutable DTO, không Web context handshake, không persistence.
Hai file `mobile/lib/features/auth/data/app_login_response.dart` và
`mobile/test/contracts/app_login_response_test.dart`; nhỏ, không dependency
mới. AC: shared Android full/limited parse đúng; Web/missing/type/mismatch/
invalid datetime bị từ chối với lỗi không chứa body/token; Dart test/analyze
PASS. RED trước module, GREEN sau; không tính là APK/UI/provider evidence.
Proposal dependency/storage/min OS và task B–D:
`ops/toolchains/android-auth-proposal.md`, chưa cài plugin chưa được duyệt.

Kết quả R9-A: RED thiếu module, GREEN42 consumer cases với fixture tổng hợp;
chuyển sang Flutter test runner phát hiện/sửa cwd fixture và inference List.
Runner hiện1test/42cases PASS, analyzer No issues; **READY_FOR_QA**, chưa là
provider/client runtime hoặc storage/app Android evidence.

R9-B được người dùng duyệt qua câu trả lời “duyêt” cho đề xuất plugin11.2.0/
PoC và candidate minSdk24. Đã tạo scaffold33file bằng CLI --empty/--no-pub,
bỏ dependency flutter_lints chưa duyệt trước pub get; chỉ pluginstorage mới
và test packages từ Flutter SDK, có lockfile. Bổ sung backup exclusions cloud/
device transfer, INTERNET permission, minSdk24, không release-sign bằng debug
key; hai stage native test dùng đúng key PoC tổng hợp. Pixel_7 đã chạy Android16/
API36. Build test đầu fail vì thiếu NDK28.2.13676358 và CLI mới tách đường dẫn
semicolon; cài đúng `ndk/28.2.13676358` exit0, đang retry. Main app vẫn scaffold,
không đóng P5 bằng parser/analyzer hoặc emulator chỉ khởi động.

Cập nhật native PoC: đã build/cài APK, một stage persist/readback API36 PASS;
stage persist với --no-uninstall tiếp tục PASS. Runner mặc định uninstall đã
làm đổi UID giữa các lượt nên không dùng hai lệnh cũ làm evidence persistence.
Đã sửa runbook; packageUID10218 được giữ, PID app đã dừng sau stage ghi. Đang
cold boot đúng Pixel_7 để đọc/xóa marker ở process mới. ImageAPI24r27 đã cài,
AVD riêng Nexa_Auth_API24 tạo thành công, chưa test. R9-B vẫn POC_IN_PROGRESS;
[log/handoff Android](../../test-reports/FEAT-TN-001-android-poc-2026-10-24.md).

Kết quả kế tiếp: API24 cũng xác nhận Android7.0/SDK24 thật qua Flutter CLI,
persist PASS, UID10078 giữ qua cold boot, restore/delete PASS; API36 UID10218
giữ qua cold boot và restore/delete PASS. Tổng4 native cases trong ma trận
hai OS, dùng --no-uninstall, không đọc/log token. Native base slice ở
**DEV_VERIFIED_READY_FOR_QA**; R9-B toàn phần **POC_PARTIALLY_VERIFIED** vì
key/storage failure, backup/restore và physical-device chưa kiểm. Main vẫn
scaffold; chưa triển khai UI/session repository thật, không đóng P5/CP-03.
Task kế tiếp R9-B2: adapter lưu/đọc/xóa session có lỗi an toàn, kiểm write/read/
delete failure bằng adapter tests và native fault PoC; sau đó backup/key matrix
trước tích hợp token thật. Giới hạn≤5file/slice, không thêm package mới.

R9-B2 PLAN review: hai file adapter/interface + focused channel-boundary tests,
không nối app/token thật. AC và thứ tự RED→adapter→GREEN/full unit/analyze→review
ở `ops/toolchains/android-auth-proposal.md`. Một key trong namespace auth riêng,
`resetOnError=false` để lỗi key không tự xóa storage; lỗi read/write/delete có
mã cố định, không body/token/cause; write Future phải chờ plugin ACK. Fake test
không là native key-failure evidence; B3 phải kiểm cấu hình mới trước P5.

R9-B2 kết quả: **READY_FOR_QA** cho adapter Dart, chưa native configuration/
app integration. Hai file mới `session_token_store.dart` và
`test/auth/session_token_store_test.dart`; không nối `main.dart`, không token thật.
RED thiếu module; GREEN6 focused tests; mutation resetOnError false→true bị
test bắt exit1, khôi phục source rồi full `flutter test --no-pub` PASS7tests
(gồm42 consumer cases). Analyzer No issues; Dart format6files0changed PASS.
Đọc lỗi không thành null; ghi/xóa lỗi có operation cố định, không retry/cause/
plaintext fallback/deleteAll; test có ACK mất sau ghi và ACK đang chờ. Chưa
chứng minh trạng thái UI authenticated, server revoke hoặc key/backup thật.
Native base4cases cũ dùng options mặc định, không tự chứng nhận namespace auth
và reset=false của adapter mới. R9-B3 là task tiếp theo đủ SDK/device dependency.

R9-B3a đã kiểm cấu hình thật: thêm
`mobile/integration_test/session_token_store_test.dart`, chạy chính adapter và
marker proof riêng. API24 UID10078 và API36 UID10218 giữ qua app-stop/cold boot;
hai stage riêng --no-uninstall trên mỗi OS đều PASS, tổng4 native cases mới.
Xóa phiên không mất marker kho khác, sau kiểm đã xóa đúng hai key PoC. Slice
**DEV_VERIFIED_READY_FOR_QA**, chưa KeyStore fault/backup hoặc auth app E2E.
Log `android-adapter-api24/36-2026-10-24.txt` trong test-reports/evidence.

R9-B3b PLAN đã rà tại Android proposal: runner và test APK instrumentation
riêng (2source files), không hook vào Activity hoặc app phát hành. Native test
dùng namespace PoC ngẫu nhiên, xác nhận alias/stores rỗng trước tạo; mất đúng
alias test rồi fresh plugin phải báo lỗi, giữ ciphertext/reset=false và sibling
namespace đọc được; cleanup chỉ tài nguyên lượt sống. Đang build/install test
APK; chưa ghi native key-loss PASS trước terminal result. B4 và CP-02 còn mở.

Cập nhật2026-10-25 R9-B3b: API36 và API24 đều trả native key-loss rejected,
stage=verified, cleanup=true, instrumentation code-1. Test APK build/cài bằng
`-Ptarget-platform=android-x64 --offline` PASS; attempt đầu không cờ target fail
do engine ARM chưa cached, không tính PASS hoặc giả máy ARM đã kiểm.
Mutation native reset=false→true bị bắt (code0, stage fresh_instance_rejects);
source khôi phục, test APK rebuild/cài lại và API24 rerun code-1 PASS.
R9-B3a/B3b **DEV_VERIFIED_READY_FOR_QA**; chưa owner/QA acceptance. Backup/
restore, máy thật, Dart/UI key-loss recovery và CP-02 vẫn mở.
[Native report/runbook](../../test-reports/FEAT-TN-001-android-native-storage-2026-10-25.md)
ghi source/evidence/cleanup limits và task B4a kế tiếp.

R9-B4a: local transport request riêng package app bị từ chối Backup is not
allowed trên API24 và36. Global Success không có nghĩa app được backup.
Enabled=false khôi phục ở cảhai; API36 chỉ restore Google transport gốc sau
khi đã disabled. Admission slice READY_FOR_QA, không restore/OEM/D2D/device
acceptance. Inventory API36 rỗng ngay sau boot là transient, đã kiểm lại trước
probe, không restart hoặc fake kết quả từ manager disabled.

R9-C0a: form presentation theo plan C0 đã code5files, không đổi main scaffold
hoặc gate tích hợp token/API. Full Flutter suite14tests PASS (7UI/6storage/
1parser chứa42cases), analyzer No issues/10.7s. Regression event recovery cũ
sau transition submitting từng fail calls1thay0; đã thêm state guard và suite
GREEN, không xóa assertion. C0a READY_FOR_QA. C0b native UI mock flow API36
PASS1test, API24 đang chạy; chưa native rotation/font scale/TalkBack/visual
QA hoặc luồng provider. Preview luôn có banner mock, submit giả luôn từ chối,
không dữ liệu workspace hoặc token thực.

C0b kết quả kế tiếp: API24 cũng PASS1 UI mock test. Hai OS đã kiểm interaction
portrait/theme/recovery trên engine thật, boundary vẫn giả. Chưa native rotation/
system font scale/TalkBack/visual QA nên C0b PARTIALLY_VERIFIED. Lượt mở riêng
preview sau test fail vì emulator đã terminal; relaunch khi xác nhận process
missing, sau đó wait-for-device timeout nhưng emulator/qemu còn sống. Không
launch trùng hoặc tuyên bố app preview đang mở. Handoff và Tester steps:
[Android login preview](../../test-reports/FEAT-TN-001-android-login-preview-2026-10-25.md).

Availability cập nhật: cùng AVD sau đó boot xong, adb xác nhậnSDK24 và đúng
Nexa_Auth_API24, không relaunch trùng. Preview target đã build/install/sync,
appPID3622 và foreground MainActivity được kiểm; runner23158 để chạy. Web
Vite90731 ready, `/login` HTTP200. Đây là startup/availability, không visual
hoặc auth/provider E2E. C0b vẫn PARTIALLY_VERIFIED theo các mục còn thiếu.

C0b native display QA PLAN review: scope≤3files (preview harness, widget
regression, integration test). Trước sửa layout, mô phỏng full harness ở
landscape/chữ2× và kiểm viewport chứa được CTA. Nếu lỗi, giảm phần điều khiển
preview, không thu nhỏ font hoặc bỏ banner mock. Sau GREEN widget, dừng đúng
app preview của lab, lưu riêng3display settings hiện hành, kiểm native portrait
và landscape/chữ2× trên API24/36; metadata kích thước/text scale từ engine phải
khớp profile đang kiểm. Finally khôi phục font/rotation/accelerometer và kiểm
lại; không đọc toàn bộ settings hoặc môi trường, không đụng thiết bị thật.
Không restart AVD sống vì timeout. AC: interaction test và layout invariant
PASS, settings restored, source/analyzer PASS; visual/TalkBack/physical/backend
acceptance vẫn riêng. Không thêm dependency; rollback chỉ3files và display
settings đã ghi từ cùng target. Frame/viewport test không thay screenshot hoặc
screen-reader review; app/template vẫn mock có nhãn.

C0b điều chỉnh harness sau observation: API36 đọc lại user_rotation=1 nhưng
engine vẫn portrait; host metadata assertion đã fail, không tính landscape
PASS từ dòng Flutter All tests passed. Thử giao diện WindowManager chính thức
`wm user-rotation lock 1` cho display0, lưu/readback policy gốc `free` trước
mutation và khôi phục policy cùng3settings trong finally. Không thay fixed-to-
user-rotation hoặc ignore-orientation-request; không ép orientation của app
hay sửa assertion. Cùng3source/test files, không dependency mới. Nếu engine
vẫn portrait, giữ NOT_VERIFIED cho profile này và ghi rõ lỗi harness/platform.

C0b bàn giao display slice: widget RED overflow52px → compact banner/menu
GREEN; full15tests (8UI/6storage/1parser42cases), analyzer No issues/10.5s và
format13files0changed PASS. Native source cuối: API24 portrait411.43×683.43/
text16=16 và landscape683.43×411.43/text16=32 PASS; API36 portrait411.43×914.29/
text16=16 PASS. Hai lượt API36 yêu cầu landscape qua settings và WM lock1 vẫn
engine portrait/text16=32 nên host assertion FAIL; C0b PARTIALLY_VERIFIED,
không gọi4profiles PASS. Ba settings đã restore/readback; WM policy free
khôi phục. Còn debug profile API36, xoay giữa input, visual/TalkBack/physical
và provider acceptance. Preview mới Pixel_7/API36 appPID4894, topResumedActivity/
currentFocus MainActivity đã kiểm, runner58118 để chạy; Web `/login` HTTP200.
Đây là availability của mock/UI, không auth E2E. [Display QA/handoff](../../test-reports/FEAT-TN-001-android-display-qa-2026-10-25.md)
ghi đúng3source/test files, source hash, các attempt fail/cancel và Tester steps.

C0b follow-up PLAN review: preview thật đang foreground trên API36 xoay native
được mRotation=1 ở4samples rồi restore1/0/1.0+free, vì vậy cần phân biệt race
lúc launch integration với lỗi layout. Chỉ bổ sung diagnostic trong
`mobile/integration_test/auth_preview_test.dart`: ghi logical/native physical
metrics lúc bắt đầu và kết thúc, không input hoặc secret. Dừng đúng preview
runner58118 trước cài test; giữ AVD sống, capture/restore3settings+WM free.
Đối chiếu WindowManager tại thời điểm engine log; không set surface size giả
hoặc ép orientation app. AC: xác định boundary sai từ evidence; nếu cần sửa
harness, test phải fail khi không nhận profile đúng và full suite/analyzer
vẫn PASS. Không gọi CP-03/E2E PASS. Rollback chỉ diagnostic/test diff mới và
cấu hình display đã capture; dependency native SDK/AVD hiện có, không DB.

C0b follow-up evidence: preview native mRotation=1; trong integration launch,
WM policy thực tế đổi lock1→lock0 trước engine-start, và giữ tới engine-end;
logical/physical đều portrait. Chưa quy nguyên nhân cho thành phần cụ thể.
PLAN sửa harness được rà:3files (`integration_test/auth_preview_test.dart`,
`tool/run_auth_display_test.py`, `test/tool/test_auth_display_runner.py`).
Test nhận profile qua compile-time define (không đọc process/system env),
phát READY sau pump app, chờ tối đa20s cho metrics thực khớp profile rồi mới
chạy interaction. Host runner stdlib xác nhận đúng2AVDs/API, lưu3settings/WM,
chỉ set display sau READY, parse metrics và kiểm finally restore/readback.
Không MediaQuery/surface giả, không API/storage hoặc main app hook. Test runner
guard target và cleanup/error bằng fake boundary; native profile không có
host phải RED, host phối hợp phải GREEN. Default current flow vẫn dùng được.
AC: native landscape API36 thực có width>height/text16≥25, negative profile
không được xanh, unit/analyze/format PASS. Rollback đúng3files/settings; nếu
runner lỗi giữ log và trạng thái chưa kiểm, không tự restart AVD/process sống.

C0b follow-up kết quả2026-10-26: host handshake sau app-start đã PASS đủ
4profiles native API24/36 portrait và landscape/chữ200%; MediaQuery/native
physical cùng khớp, không override surface. Negative không host apply RED
exit1 sau deadline;6host unit PASS; mutation `>`→`<` bị bắt exit1, source
restore byte-for-byte rồi GREEN. Full Flutter15tests, analyzer No issues/12.5s
và Dart format13files0changed PASS. Mỗi lượt native đều restore/readback đúng
3settings, API36 cả WM free. Display slice READY_FOR_QA, C0b tổng vẫn PARTIAL
vì visual/TalkBack/rotation giữa input/request và máy thật chưa kiểm. Không
đóng P5/CP-02/03/AT-WF-001. Preview API24 hiện appPID4228/currentFocus
MainActivity, runner26625 để chạy; Web `/login` HTTP200/text/html, chỉ
availability. [Latest runbook/evidence](../../test-reports/FEAT-TN-001-android-display-handshake-2026-10-26.md)
có source SHA14files và lệnh runner lặp lại được; không xóa evidence fail cũ.

Code state `dev@ba425ad` + dirty working tree, không commit/stage. Contract giữ
0.2.1. Đã có `backend/src/http/`, binary opt-in `auth-lab`, application read
projection và PostgreSQL adapter; không còn đúng nhận định lịch sử “chưa có HTTP
handler” của mục27.6. Web nối API thật, không gắn mock vào ứng dụng.

| Task | Trạng thái hiện tại | Evidence / phần còn thiếu |
| --- | --- | --- |
| R6 strict transport/security | READY_FOR_QA | 6 HTTP boundary tests và3 parser/security tests PASS; suite Rust toàn workspace64/64 PASS, fmt/clippy PASS. Boundary dùng pool lazy, không phải positive DB/provider evidence. |
| R7 /me/session/picker/detail | IMPLEMENTED_UNVERIFIED | Core/SQL/Router đã nối và compile; chưa chạy thành công với PostgreSQL. Cần provider suite và kiểm race/timeout/ACK unknown/budget trước CP-02. |
| R7 lab runner/recovery | READY_FOR_QA cho source/guard; DB run BLOCKED_APPROVAL |3 recovery spy tests PASS. Auto-review từ chối role grants + fixture mutation trên canonical DB; câu hỏi phê duyệt cụ thể đang chờ, không tự đi đường vòng. Recovery không xóa limiter theo journal thiếu độc lập ownership; anonymous audit giữ retention, journal giữ lại. |
| R8 Web, R8-UI | READY_FOR_QA cho source/build; browser E2E BLOCKED | Redesign Nexa task form/sáng-tối/responsive đã code; build mới13:32 UTC PASS,16 coordinator/parser mock tests PASS. Vite `/login` HTTP200; chưa có browser connector nên chưa kiểm DOM/visual/focus. Tạo workspace vẫn là dependency065. |
| R9 Android | R9-A/base/B2/B3a/B3b/C0a/display slice READY_FOR_QA; R9-B/C0b tổng PARTIALLY_VERIFIED | Unit/widget15tests gồm8UI+6storage+1parser42cases và6host tests PASS. Native base4cases và adapter4cases PASS API24/36 có cold boot; key-loss2OS và backup admission2OS PASS. UI mock4profiles API24/36 portrait+landscape200% PASS sau handshake; native thiếu host RED, settings/policy restored. Còn restore/OEM/D2D/physical, visual/TalkBack/rotation giữa input và auth app API/recovery, không phải P5/CP-03 PASS. |
| CP-01/02/03; AT-WF-001-01…03 | Chưa đóng | Review kỹ thuật cùng model không thay owner/QA;64 Rust tests không thay DB/browser/Android/E2E. |

Chi tiết file, lệnh thực chạy, hạn chế và hướng dẫn mở Web/App/test nhánh lỗi:
[runtime handoff](../../test-reports/FEAT-TN-001-runtime-handoff-2026-10-24.md).
Task tiếp theo có prerequisite khả dụng là chạy provider sau phê duyệt cụ thể;
toolchain Android và kết nối browser có thể được chuẩn bị độc lập. Không đánh
toàn feature hoàn thành khi hai nền tảng chưa có luồng thật/evidence.

## 28. Kết quả phản biện và giới hạn kết luận

| Mức | Lỗi/khoảng trống bản trước | Sửa/kiểm chứng |
| --- | --- | --- |
| Blocker | E6 có thể nhận cookie A làm thành công login B; JS phải biết cookie đã lưu | E6, 13.1; WEB013/E2E006 |
| Blocker | Reload limited không có CSRF token trong khi /me bị cấm | 403 không profile + metadata CSRF; WEB012 |
| Blocker | Verify/commit không fence với password change/disable | 14.1; IT009 |
| Important | Atomic increment đơn lẻ không chặn concurrent verify, key/window/reset chưa rõ | OQ004/14.1; IT006/010 |
| Important | Web flow có thể tạo cả limited/full; hiểu nhầm phiên riêng từng tab | Nhánh duy nhất, cookie jar chung; WEB014 |
| Important | Gộp rollback chắc chắn với commit chưa biết; audit global thiếu boundary | IT002/011, SEC016 |
| Important | Thiếu dependency graph/checkpoint và còn 13 câu hỏi | Mục 22/27; evidence G1 chưa có thì chưa BUILD |
| Important | BA-only trong chỉ mục, /me role/preferences, historical workspace có nguy cơ lệch nguồn | Mục 2/OQ009–010, đồng bộ ở G1; không tự sửa nguồn |

Phạm vi: plan 001 đối chiếu phần auth/workspace/API trong BA/handoff và ranh giới feature liên quan; không chứng nhận code hiện có. Chưa chạy test ứng dụng/chưa nghiệm thu feature. Plan có phương án kỹ thuật và trình tự để bắt đầu P1; BUILD runtime còn gate G1, release còn evidence mục 19–25.

Nguồn kỹ thuật đã kiểm tra: [MDN Set-Cookie](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Set-Cookie) về giới hạn JavaScript đọc cookie/header; [OWASP Authentication](https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html) về generic error/timing/throttling; [OWASP CSRF](https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html) về token binding/origin checks. Numeric policy/cấu hình cụ thể trong mục 22 là thiết kế dự án, không gán thành yêu cầu của các nguồn này.
### E2E-AUTH-005 — Android API24 rate limit, PLAN 08/11

Prerequisite đã có root API24 full/access/password exit0 trên runner E52 và target 3A3E. Main PID6117 đã Force stop qua Android Settings, không xóa data; gate 6e4ce9 xác nhận package absent, SDK24, airplane0 và canonical Docker sẵn sàng. Reuse CLI đã root/independent review và actual API36, không đổi source, timeout, limiter hoặc clock.

- [x] ROOT_SCOPED_RUNTIME_PASS / READY_FOR_QA95652. Chạy `node ops/auth/run_native_rate_e2e.mjs` đúng emulator-5554/API24, giữ owned handle và log tới terminal. Cần native typed401 năm lần, typed429 lần sáu, quan sát real Stopwatch ít nhất900s và không autoPOST, submit đúng chủ động rồi logout. Exact proxy counters, session snapshots và PID là oracle, không lấy tổng wall time thay Stopwatch.
- [x] Original terminal5ea198 exit0 và fresh8zero. Chỉ root READY_FOR_QA khi target/UI, SDK stop/exit, host oracle, original proxy/fixture cleanup và orchestration terminal đều PASS/exit0. Failure/timeout/handle mất phải ghi đúng FAIL hoặc UNCONFIRMED, không mở lượt trùng khi handle còn sống.
- [x] MAIN_RESTORED30435/6f23db, CUA14:52:31.766 và PID4535/API24. Sau terminal, fresh package-absent readback, restore main mặc định và kiểm CUA configuration gate/API24. Ghi manifest, lệnh, log hash, cleanup scope và giới hạn vào report/progress/runbook. Independent API24, physical/lifecycle và strict negative mapping vẫn mở.

### B3 producer — valid form nhưng tap bị nuốt, PLAN09/11

Gap từ review07/11 còn thiếu generic no-op tap khi input hợp lệ. Phạm vi một test file `mobile/test/tool/native_rate_scenario_boundary_test.dart`. Reuse real App/coordinator/repository/producer và synthetic API/store hiện có. Test-only RawGestureDetector với EagerGestureRecognizer được filter chỉ đúng pointer CTA sau khi hai input synthetic đã khớp, enabled/hit-testable và không summary. Listener giữ pointer down/up cùng ID. Input/scroll khác được bỏ qua. Nguồn Flutter API chính thức mô tả recognizer giành gesture arena ngay, phù hợp fault injection này. Không sửa production hoặc target đang chạy API24, không thêm package.

- [x] SOURCE_HOST_ACCEPTED / READY_FOR_QA. Case mới phải có email/password synthetic hợp lệ, `auth-submit` enabled và hit-testable tại pointer down, không validation summary. Tap bị nuốt nên API/login/profile/logout đều0, checkpoint chỉ `rate-before`, last stage `rate-wrong-1`, producer throw đúng `NATIVE_RATE_UI_TIMEOUT` trước ACK tiếp.
- [x] Root RED e0f217/controlAPI1 và GREEN73976d5/5, independentadfafd5/5. Dùng real Stopwatch cho case swallowed-tap và chờ operation20s kết thúc. Sau tap/up, producer phải đi vào wait loading và timeout trước checkpoint tiếp. Chạy RED bỏ recognizer chiếm gesture, yêu cầu request đầu đã nhận typed response và API1 trước fixed control error, rồi GREEN với recognizer và full focused suite. Giữ riêng kết quả host với native900s. Review plan độc lập yêu cầu filter CTA và tránh clock jump che busy-wait, đã tiếp thu.
- [x] FullFlutter162/analyzer/format và finalQA trênFDCA đã đạt. Chờ SDK native95652 terminal/cleanup trước mọi lệnh Flutter test/format/analyze. Focused tests/analyzer/format, review source/comment/security độc lập và hash phải đủ trước READY_FOR_QA. B3/checkpoint tổng vẫn mở theo các gap countdown/network/ACK khác. Rollback chỉ hunks test mới, giữ4case cũ.

[Report cuối B3 swallowed tap](../../test-reports/FEAT-TN-001-b3-swallowed-tap-2026-11-09.md) ghi sourcehash, lệnh và scope. Hai checkbox B3/checkpoint tổng ở native rate plan vẫn mở theo residual cases.

### MB-AUTH-002/010 — HTTP metadata observer local, PLAN09/11

Cần trả lời ba câu hỏi của lượt main manual. Login POST có tới proxy trong offline/reconnect window không, workspace detail cũ nhận status nào, và có request đang dở khi đọc counter không. Existing proxy có byte cap/TLS/ownership và request enum observer nội bộ. Native API dùng HttpClient riêng mỗi request, persistentConnection=false và force-close trong finally. Reuse proxy với capture opt-in cho client một request mỗi connection này.

Phạm vi tối đa4source/test files gồm `ops/auth/http_metadata_capture.mjs` mới, `test_http_metadata_capture.mjs` mới, `local_https_proxy.mjs`, `test_observed_https_proxy.mjs` mới. Default runner observer giữ interface function6enum hiện có. Capture mới được truyền như trusted runtime.httpMetadata, CLI bật bằng đúng `--observe-http`. Không đổi API/auth/session/schema/dependency hoặc native timeout. Module mới chỉ là công cụ lab.

- [x] SOURCE/HOST ACCEPTED / READY_FOR_QA. Capture bounded first request/status line256bytes mỗi hướng, classify allowlist AUTH_LOGIN/PROFILE_READ/WORKSPACE_LIST/WORKSPACE_DETAIL/PASSWORD_CHANGE/AUTH_LOGOUT/OTHER. Emit REQUEST/STATUS/CLOSED với ordinal requestId local, kind và status200–599, sequence/timestamp ở CLI. Wipe prefix trước callback và destroy. Header/body/reason text/URL/email/UUID/cookie/token không được emit hoặc buffer sau first line. STATUS là quan sát status line, không khẳng định body thành công. Request giữ nguyên bytes. Unsupported protocol/interim1xx/oversize/invalid callback phải làm capture failed và proxy cleanup fail-closed, không báo proof khỏe.
- [x] SOURCE/HOST ACCEPTED / READY_FOR_QA. CLI opt-in có STATUS stdin bounded16bytes để xuất cumulative request/status/active/closed/failed cùng last sequence, STOP/EOF/signal theo ownership hiện hữu. Tổng1024secure connections cho capture lab, active bounded bởi proxy32. Complete ledger có đủ request/status/closed hoặc ghi chưa có status rõ, không suy từ UI. First-line observer chỉ áp source client một request mỗi connection, không claim arbitrary keep-alive/pipelining/chunked body verification. Host RED/GREEN cho split/coalesced bytes, zero output secret sentinels, line bounds, partial close, status order, callback failure, count caps, stdout shape và copy snapshot; transport tests verify TLS/bytes/owned close + existing default host suites.
- [ ] Independent source/comment/security review và regression default proxy/runner trước actual. Source hash proxy đổi thì record manifest mới và ghi scope compatibility, giữ actual900s cũ theo manifest của nó. Lượt manual main sau source acceptance dùng fresh fixture/public cert, giữ action/UI/session/membership + STATUS snapshots/status line records cùng run, cleanup và restore main. Chỉ đóng phần HTTP của offline/stale khi actual đạt, resource/device/lifecycle/physical và toàn feature còn gate riêng. Rollback chỉ observer module/flag và guarded pipe branch, giữ path mặc định cũ.

#### HTTP observer — tiếp thu review và chia checkpoint

Review thiết kế09/11 yêu cầu active raw TLS + secure exchange, matched target B và temporal fences. Capture constructor nhận targetWorkspaceId UUID synthetic đã được harness xác nhận qua RAM, chỉ emit matchesTarget boolean. Chưa cấu hình target thì chỉ có kind detail, chưa đủ đóng staleB. Snapshot không-inflight cần rawActive=0 và active=0, healthy=true, unknown=0, counters/sequence được chốt đồng bộ trong finite window. CLOSED chỉ transport terminal, STATUS chỉ upstream first line. Fault sau byteforward giữ outcomeunknown và cần session oracle.

Thực hiện theo hai checkpoint phụ thuộc nhau. H1 gồm helper `http_metadata_capture.mjs` và host tests trước. Theo dõi raw/open/close và exchange/request/status/close độc lập, tổng raw tối đa1024 và concurrent32. H1 chưa nối proxy/CLI và chưa actual main. H2 mới nối raw events/stream terminal vào proxy và CLI, serialized bounded writer/backpressure/EPIPE, frame STATUS/STOP/reset-buffer/split/multiple/CRLF/EOF. Sau H2 source review/default regressions mới actual. Hai checkpoint giữ nguyên mục tiêu HTTP proof đầy đủ của task cha. Nếu reviewer bị giới hạn công cụ, root vẫn xây host evidence H1 và giữ SOURCE_HOST_ONLY/READY_FOR_QA tới review độc lập.

H1 checkpoint09/11. [Source/commands/hash/evidence](../../test-reports/FEAT-TN-001-http-capture-h1-2026-11-09.md).

- [x] ROOT_SOURCE_HOST_PASS / READY_FOR_QA cho helper và hosttests H1,8markers/syntax và2mutation guards. Raw capability mỗi connection đã được thêm theo review.
- [x] Independent H1 source/comment/security review trên final hash, accepted10/11 cùng H2.
- [x] H2 source/host accepted10/11 cho proxy/TLS mapping, transport terminal và bounded stdout/CLI. Actual còn mở.
- [ ] Main actual offline/stale HTTP proof cùng fresh fixture, original cleanup và main restore.

#### H2 transport và CLI — thứ tự BUILD09/11

H2a nối runtime.httpMetadata vào proxy, giữ callback observer6enum mặc định. Raw admission được gắn với remotePort duy nhất trong listener loopback và lưu capability trong Map thuộc listener. Secure callback đọc cùng endpoint đã validate để lấy đúng capability, raw close chỉ xóa entry nếu vẫn là cùng owner. Chưa map hoặc duplicate là fail-closed. Mỗi secure exchange chờ đủ socket/upstream/limit/capture pipes close trước ledger CLOSED. Proxy terminal chờ capture closures rồi seal. Snapshot bổ sung proxyAvailable để fence còn kiểm cả trạng thái listener. Tests TLS thực + synthetic upstream kiểm bytes/raw handshake/inflight/partial response/error/close và default regressions trước mở CLI.

H2b tách controller stdout/stdin thành module/test riêng tối đa3files ở slice đó, tái dùng capture đã nối. Tổng task cha có thêm2file controller/test để tránh dồn parser/backpressure vào proxy. CLI `--observe-http` và optional `--target-workspace=UUID` chỉ nhận UUID synthetic không secret để matcher trong RAM, chưa cấp quyền mutation. Frame STATUS/STOP bounded16bytes, nhiều frame/split/CRLF/EOF/invalid phải có host tests. Stdout serialized allowlist, fail-closed ngay khi write bị backpressure/error hoặc limit, queue riêng không tăng vô hạn. STOP giữ output pending tới callbacks settled rồi final snapshot/terminal theo scope. Default CLI giữ noargs và output hiện có. Actual main sau final independent/source regression H2 mới mở.

H2c kiểm CLI observed bằng child process thật trong một slice test riêng `ops/auth/test_observed_proxy_cli.mjs`. Synthetic upstream chỉ bind3000 khi trống, TLS CLI chỉ bind8443 khi trống và không kill listener ngoài ownership. Cases phải đọc public cert để verify TLS, gửi STATUS split/coalesced, kiểm REQUEST/STATUS/CLOSED + target matcher và FINAL sealed/idle sau original child terminal. EOF sạch, partial EOF, malformed/oversize command, invalid argv trước readiness và bind collision đều có exit/output assertions. Mỗi case giữ owned child tới close và rebind8443 để xác nhận nhả listener. Không dùng kết quả host synthetic để điền actual App offline/stale. Dependency actual vẫn là final independent source review H1/H2 cùng default regressions.
H2 review10/11 phát hiện raw cap32 có thể reject peer thứ33 trước capture mà vẫn tạo healthy fence sau close. Task sửa gồm observed-only failMetadata khi saturation, transport test32held+33 và child CLI test exit1/noFINAL, giữ cleanup từng raw client. Test phải RED trên source F783 rồi GREEN sau fix, chạy default regression và independent re-review trên hash mới. Trong thời gian sửa, H1/H2 trạng thái NEEDS_FIX, chưa mở actual App.
#### H2 checkpoint10/11 sau finding saturation

Checkpoint10/11 HTTP observer H1/H2. Tester độc lập đã tìm và xác nhận lỗi raw saturation32+33, root sửa observed fail-closed bằng RED/GREEN. Proxy7DF9159A cùng transport6 và CLI9markers đã root và independent PASS. Final independent11suite strict exit0, source/comment/security accepted, ports đã trả. **SOURCE_HOST_ACCEPTED / READY_FOR_QA**. Actual App HTTP offline/stale còn NOT_RUN, toàn feature INCOMPLETE. Các checkpoint H1/proxyE4E9 bên dưới là lịch sử. [Report H2](../../test-reports/FEAT-TN-001-http-observer-h2-2026-11-10.md).

- [x] Root triển khai runtime raw/TLS mapping, closure6handles, seal và bounded controller/CLI.
- [x] Root baseline09/11 có11suite exit0, syntax7files và4mutation guards, scope hashF783 được giữ trong manifest.
- [x] Root tái hiện RED saturation và sửa observed-only fail-closed, transport6/CLI9markers exit0 trên proxy7DF9159A.
- [x] Independent final H1/H2 source/comment/security và post-fix default/runner regression10/11.11suite exit0, terminal038d3f/postports4c2bce.
- [ ] Actual main offline/stale HTTP + session/membership/UI cùng fresh fixture, original cleanup8zero và main restore.
- [ ] Independent actual repeat cùng các gate browser/storage/physical/accessibility/owner còn lại.

CLI snapshot dùng healthy cho parser và proxyAvailable cho endpoint. Saturation làm proxyAvailable=false, closed=false và CLIexit1, parser có thể còn healthy=true vì chưa nhận first line. Fence actual cần cả healthy=true và proxyAvailable=true, rawActive=active=0, incomplete không tăng chưa được giải thích, ledger/counter/sequence đồng bộ. FINAL chỉ được công nhận sau original CLI terminalexit0 và write ACK, không thay business oracle.


Checkpoint runtime10/11. Chrome extension đã kết nối, tab login mới và validation/focus/màu lỗi được kiểm thật. Vite54057 đang chạy5173, AVD59542 bootAPI24, airplane0. Fresh backend/main HTTP actual chưa chạy. [Evidence chuẩn bị runtime](../../test-reports/FEAT-TN-001-runtime-preparation-2026-11-10.md).


Checkpoint App HTTP10/11 run71a6b207. UI offline/fields cleared và seed-onlyDB đã có, HTTP ledger0, nhưng thiếu positive canary và fixture chạm deadline. **INCONCLUSIVE / ROOT_PARTIAL_RUNTIME_VERIFIED**. Helper41766 terminalexit1 có ownedcleanup marker, main21501/proxy69583 terminalexit0 và fresh6projection0, airplane0. Task actual giữ mở, retry bắt đầu bằng positivecanary. [Report lượt hết hạn](../../test-reports/FEAT-TN-001-api24-http-expired-2026-11-10.md).


Checkpoint App/Web H2 retry10/11. Native HTTP AUTH_LOGIN401 có REQUEST/STATUS/CLOSED và UI auth-invalid. Cùng credential fixture Web login/logout thành công, exact+1WebUUID rồi revoked, seed Android nguyên. Chưa xác định nguyên nhân nhập App401. CUA dừng do input ngoài phiên. Main73855/proxy3415/fixture58727 đều originalexit0, fresh6projection0. Mainrestore26080 detach exit0/PID4847/foreground/airplane0, UI restore chưa kiểm. **ROOT_SCOPED_RUNTIME_VERIFIED / READY_FOR_QA**, offline/stale toànluồng còn mở. [Report và evidence](../../test-reports/FEAT-TN-001-api24-http-control-2026-11-10.md).

### MB-AUTH-010/002 — Native integration sau H2, PLAN10/11

Đã có review read-only độc lập về existing test target, privatefixture và deadline. Root đối chiếu source và chọn triển khai từng bước trong integration target gọi product.main. Manual App401 giữ nguyên chưa rõ nguyên nhân nhập, CUA đã dừng. Phạm vi kiểm tiếp ưu tiên staleB có WidgetTester input chuẩn, sau đó offline/reconnect khi capability mạng đã được chứng minh. Cả hai mục tiêu HTTP/UI/session gốc vẫn giữ mở. [Review thiết kế và source references](../../test-reports/FEAT-TN-001-native-offline-stale-integration-plan-2026-11-10.md).

Không có phase existing đáp ứng trọn vẹn. Full phase tự chọnA/B, checkpoint access chỉ5s và callback host sync. Cần pause owned riêng cho membership commit, chưa được đưa SQL130s vào callback5s hoặc bỏ await Promise.

#### Thứ tự và acceptance

1. **Native checkpoint membership**. Tối đa2files mới gồm support probe và focused Dart test, reuse semantics của NativeRateCheckpoint làm mẫu. Fixed ordered stages cho before-login/picker/denied/only-A/A-opened/logout, monotonic one-shot ACK và sticky cancellation. Pause picker cần chứa owned DB boundary có budget chốt riêng trước BUILD, các pause nhanh giữ budget ngắn. Không mở numeric timeout từ packet/CLI. Test wrong stage/replay/overlap/late ACK/clock rollback/remaining/receipt sau complete và clear/cancel. Đây là task source kế đủ dependency, chưa mở phase actual.
2. **Fixture B capability**. Dùng NativeFixtureControl live config/owned child để resolve đúng user0, creator4, role marker/run/provenance trước trả UUID B synthetic cho owner RAM. Projection và SUSPEND_B là literal command, không nhận SQL/UUID tùy ý. SUSPEND_B dùng capability đã chốt, optimistic USER/ACTIVE/revision/authz guard, transaction exact1row, readback commit trước ACK, không replay khi unknown. Cần kiểm server statement/lock bounds và drain owned operation trước backend/role cleanup. Giữ direct fault injection scope riêng với Admin workflow. Chia Python implementation/test và Node factory/protocol regression thành các slice≤3files khi cần.
3. **Native scenario integration**. Tối đa3files mỗi slice gồm scenario support, existing integration target và boundary test. Chỉ integration target nhận phase membership-stale qua private packet4fields cũ, product.main giữ entry hiện hành. Reuse tester.enterText/tapNative/waitForNative, fresh loading và protected-state checks. Picker pause chỉ release sau verified commit/readback. DenyB→reloadonlyA→A/Admin→logoutsameAppUUID. Packet/replay/status/PID/secret boundaries và existing phases phải hồi quy.
4. **Host gate và H2**. Tối đa3files mỗi slice gồm run_native_e2e.mjs, scenario owner/oracle và Node tests. Callback sync cũ giữ contract, phase mới dùng owned async operation explicit để host đợi actual terminal. Bind fresh B trước tạo capture, snapshot raw/secure/healthy/availability/sequence/incomplete và exact status association. Native pause cap phải chứa SQL bounded operation, phase/work deadline cùng cleanup reserve phải được kiểm trước admission. Timeout chưa phải operation terminal. Native test phase budget chọn từ ledger thực tế và không đổi product API timeout15s.
5. **Actual staleB**. Sau independent source/default regression, fresh canonical fixture20m, actual main integration target/API24. Native PASS + fixed checkpoints + B404matchesTarget + A200 + exactAndroidsession/seed/audit + originalSDKstop/PID + proxyseal/terminal + fixture8zero/shimexit là toàn bộ criteria. Instrumented integration và standalone manual là hai scope riêng. API36/independent repeat còn gate riêng.
6. **Offline capability và phase**. SDK emulator-console GSM data là candidate, không được suy từ ACK/status rằng10.0.2.2 unreachable. Cần full HTTP/TLS probe thực từ native target, cùng route/cert/proxy healthy, trước/trong/sau fault, restore đúng modem state ban đầu. Nếu Wi-Fi/route còn đi được, ghi INCONCLUSIVE. Endpoint đóng chỉ là endpoint-unavailable slice. NoCA probe hiện chạy trước product.main nên fault chỉ sau noCA và sau positivecanary. Reconnect foreground window/lifecycle phải được xác định đúng scope, không dùng injected lifecycle để tự đóng gate OS lifecycle.

#### Checkpoint source và rollback

- [x] Read-only discovery và review đề xuất, chưa sửa product/test source trong checkpoint này.
- [x] Root chốt stage budget và API support probe sau đối chiếu source, RED/GREEN task1 đã đạt10/11. Independent review còn chờ.
- [ ] Fixture/protocol và host async owner đã có negative/replay/STOP/lateACK/timeout terminal tests.
- [ ] Native UI scenario/counters/secret regressions, final independent review trên hash mới.
- [ ] Actual staleB và offline từng scope, cleanup/restore và independent repeat.

Budget phải neo vào thời gian owner trước spawn khi dùng default20m, không cộng lại20phút sau READY muộn. DB boundary chưa có ACK phải giữ native pause và owned SQL operation tới raw terminal, trạng thái commit unknown dừng business proof. Chia hai lượt focused khi conservative worstcase + cleanup reserve không đủ. Rollback giới hạn support probe/scenario, test-only phase, lab fixture protocol và host guarded branch, các manifest actual cũ tiếp tục theo hash lịch sử.

#### S1a — Native membership checkpoint, BUILD scope10/11

Review thiết kế độc lập đã chấp nhận triển khai hai file mới `mobile/integration_test/support/native_membership_probe.dart` và `mobile/test/tool/native_membership_probe_test.dart`. Fixed stages là membership-before-login/picker/denied/only-a/a-opened/logged-out. Mỗi stage chỉ dùng một lần nên ACK stage + pending state đủ chống replay cùng instance. Bridge S2 vẫn phải bind đúng isolate/owned phase.

Picker local cap180s được tách từ130s fixture operation +30s RPC allowance +20s headroom. Năm stage khác cap5s. Đây là giới hạn local pause, host chưa được coi cap này là SQL/RPC terminal hoặc tổng phase/fixture budget. Source mới dùng Stopwatch pinned và state ACK đồng bộ, receipt biến mất ngay sau commit, clock throw/lùi hoặc invalid begin/overlap/premature end/cancel làm failed sticky. ACK sai schema/stage không tiến hoặc reset deadline. Commit đúng hạn vẫn ổn định khi native pump tới muộn, global phase admission do S2 kiểm riêng.

RED/GREEN và mutation cần cover5s/180s floor boundary, second clock sample ngay trước ACK, throw/rollback/lateACK, copy receipt, schema/replay/order/overlap/cancel và default advancing Stopwatch. S1a chưa mở phase trong integration target hoặc CLI. Existing rate gate không có khả năng cấp pause180s qua public constructor, source rate giữ theo manifest cũ trong slice này.

#### S1b1 — Resolve B owned cho native stale, PLAN/BUILD10/11

Dependency S1a local gate đã root11/11 và fullFlutter173/173. Independent tester GPT6.1xhigh không chạy được vì usage limit, nên S1a giữ READY_FOR_QA. S1b1 là projection read-only, chưa cần mở native phase hoặc mutation.

Phạm vi hai file existing `ops/auth/native_lab_fixture.py` và `ops/auth/test_native_lab_fixture.py`. Thêm literal `MEMBERSHIP_TARGET` để resolve một lần B của live config, không nhận UUID/SQL từ channel. Dùng cùng control lock/owned child/provenance đã handoff, tuple run/user0/creator4 từ config được validate trước spawn. SQL bind qua auth_fault_correlations đã có, xác minh role marker, hai user ACTIVE/email namespace/provenance, B ACTIVE/creator4/description, creator4 ADMIN và user0 USER ACTIVE cùng current grant chưa revoked. Kết quả chỉ workspaceId/revision/authorizationVersion/grantGeneration, schema canonical UUID và positive bounded integers, một row duy nhất.

Acceptance tối đa ba mục.

- [ ] Chỉ read sau READY/owned live child, chưa STOP, rate phải ARM còn hạn. Một attempt, copy result, không retry sau SQL/schema failure hoặc lấy target từ journal.
- [ ] SQL read-only transaction có statement20s/lock5s/idle25s, check=False và fixed error giữ stderr/raw exception ngoài output. STOP đến trong SQL phải ngăn publication, owned operation kết thúc rồi mới nhả lock. Docker120s observer không được hiểu là DB terminal proof.
- [ ] RED/GREEN focused + existing Python fixture/cleanup regressions, schema/ownership/bounds/STOP-during-SQL/replay/command injection tests và source/comment review. Actual DB/phase/Node protocol vẫn mở, SUSPEND_B theo slice sau.

Rủi ro còn lại gồm Docker timeout có thể để psql/server chưa terminal và budget default hiện neo sau READY. S1b1 không mở mutation nên giữ riêng việc server application-name ownership, bounded mutation/readback/drain, phase budget neo trước spawn và cleanup reserve cho S1b2/S2. Rollback giới hạn method/field/command và tests mới.



#### S1a/S1b1 checkpoint10/11

**ROOT_SOURCE_HOST_PASS / READY_FOR_QA**. S1a gate11focused/173fullFlutter, analyzer2files noissues/format0changed và4mutation guards đạt. S1b1 MEMBERSHIP_TARGET chỉ read-only đã nối private shim,9case mới cùng fixture/cleanup44/44, Node protocol14/RPC11/rate-evidence7markers và4mutation guards đạt. SQL thật trên canonical lab với empty synthetic scope trả[] và fixed rejection, positive live fixture chưa kiểm. Tester GPT6.1xhigh đã gọi nhưng dừng do usage limit, independent source review còn chờ. Toàn feature INCOMPLETE. [Report và manifest](../../test-reports/FEAT-TN-001-native-membership-support-2026-11-10.md).

- [x] Root chốt/hiện thực/test S1a monotonic checkpoint và cap180s/5s, existing rate source giữ hash.
- [x] Root hiện thực/test S1b1 read-only B target, pinned scope/copy/one-attempt và STOP-during-read guards.
- [ ] Independent final source/comment/security và repeat cho hai slice mới.
- [x] S1b1 positive fresh fixture projection và SELECT đối soát trên SQL thật, original shim exit0/8zero. Từng negative ownership predicate chưa kiểm.
- [ ] S1b2 SUSPEND_B transaction/CAS/commit/readback/unknown drain, Node factory và native scenario/host gate.
- [ ] Actual stale/offline + independent repeat/cleanup/restore đầy đủ theo task cha.

Task1 ở danh sách native integration đã đạt root source/host, chưa đạt independent review hoặc native actual. Task2 mới xong projection read-only, mutation và owned operation terminal vẫn mở. S1b1 nhận literal riêng và targetmetadata, existing Node factory không tự gửi command mới. Chưa có CLI membership-stale.



S1b1 positive fixture10/11 đã đạt root scoped. Run c837d7c6, target B f6eae341, hai projection cùng metadata1/1/1 và SELECT riêng workspace/user/creator đều true. Original shim55855 exit0 và STOPPED8zero, terminal1f8f63. **ROOT_SCOPED_FIXTURE_PASS / READY_FOR_QA**. Independent review và actual native stale/offline còn mở. [Evidence](../../test-reports/FEAT-TN-001-native-membership-support-2026-11-10.md).



#### S1b2 — Owned suspension và drain trước fixture cleanup, PLAN10/11

Claim cần kiểm là SUSPEND_B chỉ đổi membership USER của pinned B một lần, ACK chỉ sau COMMIT/readback và owned psql/backend terminal. Timeout hoặc mất ACK không được replay. Mutation dùng đúng role1h/5accounts/2workspace đã được duyệt. Đây là fault injection cho stale test, chưa là acceptance Admin suspend workflow.

Source discovery cho thấy lab.sql có Docker timeout120s nhưng không sở hữu psql/backend sau timeout. Existing UserFenceHolder đã có application_name sinh trước spawn, private stdin/marker, query/idle bounds, Popen stop/reader join và metadata backend-gone trong stop. Reuse lifecycle này bằng NativeMembershipOperation subclass, không tạo executor tổng quát. Launcher.run đã drain fence_holders sau stop backend và trước graph cleanup, cần nhận optional registry do shim sở hữu để cả backend chết ngoài ý muốn vẫn đi qua drain.

Phạm vi năm source/test files chia hai bước cùng dependency.
1. Module `ops/auth/native_membership_operation.py` mới và test `ops/auth/test_native_membership_operation.py` mới. Fixed typed constructor run/user0/creator4/B và metadata CAS được chốt từ S1b1, không SQL/UUID từ command. Registry phải giữ object trước execute. Reuse UserFenceHolder lifecycle, startup5s/commit5s/stop5s, serverstatement2s/lock2s/idle10s. Kiểm role marker + exact namespace/provenance, lock User rồi Workspace rồi creator/member, update roleUSER/statusACTIVE/revision/authVersion/grant exact, statusSUSPENDED và tăng hai version1, readback cùng target sau COMMIT.
2. `ops/auth/run_local.py`, `native_lab_fixture.py`, `test_native_lab_fixture.py`. Optional operation_holders registry giữ default callers. Chỉ profile mới membership-stale cho literal SUSPEND_B, cần MEMBERSHIP_TARGET trước, one-shot attempt và lifecycle còn admission. Emit MEMBERSHIP_SUSPENDED metadata sau execute+drain. Default/password/rate không nhận mutation. Profile20m neo control trước spawn, host S2 vẫn phải neo trước child spawn và cleanup reserve.

Acceptance tối đa ba mục.

- [ ] RED/GREEN operation tests cho ownership/CAS/markerorder/commit-loss/readback/clockdeadline/cleanup/backend còn sống và registry-before-execute. Invalid args trước I/O, integer overflow guard, fixed errors không raw diagnostics.
- [ ] Shim/launcher regression giữ existing profiles/ARM/snapshot/STOP/cleanup, new command không selector/replay, STOP giữa operation không late ACK, backend death vẫn drain registry trước graph/role cleanup.
- [ ] Root source/comment/security và Python/Node regressions, independent final review trước actual mutation. S1b1 positive read-only giữ theo manifest trước. Source mới giữ READY_FOR_QA khi tester còn quota blocker.

Rollback chỉ module/test mới và guarded shim/registry paths. Chưa mở Node factory/native CLI membership-stale trong slice này. Nếu reuse holder không đạt lifetime contract thì dừng actual và ghi rõ boundary thiếu, không suy metadata_count timeout là backend-gone. Cross-model review đang chờ tester GPT6.1 đã chỉ định do usage limit, root RED/GREEN chỉ là evidence behavioral, independent còn mở.



#### S1b2 checkpoint10/11 — Source/host, chưa actual mutation

**ROOT_SOURCE_HOST_PASS / READY_FOR_QA**. NativeMembershipOperation reuse owned psql/backend lifecycle của UserFenceHolder, typed CAS target, commit/readback và drain trước receipt. Shim profile membership-stale20m neo trước build/spawn, literal SUSPEND_B một attempt và registry control cố định trước launcher.run. Launcher optional registry giữ default callers, graph cleanup bị chặn nếu owner drain chưa xác nhận.

Root đã tái hiện/sửa late final-marker và SQL admission sau slow inspection/Popen bằng RED/GREEN. Final13operation +8shim/launcher cases mới, targeted81cases, top-level65 +nested88 distinctcases đều exit0. Node14/11/7/2/1markers exit0,5mutation guards bắt assertion failures. Sáu SQL statements đã compile qua EXPLAIN read-only, chưa execute UPDATE/row locks. Independent và actual DB/native còn NOT_RUN. [Report/hash/lệnh/evidence](../../test-reports/FEAT-TN-001-membership-suspend-2026-11-10.md).

- [x] Root operation/shim/launcher code và host tests, deadline regression, registry/backend-gone failure guards.
- [x] Root source/comment review,153distinct Python cases,5Node suites và5mutation guards, read-only SQL compile.
- [ ] Independent final source/comment/security và regressions trên hash S1b2.
- [ ] Actual mutation PostgreSQL với ownership/CAS/unknown commit/server drain, fresh fixture/original8zero.
- [ ] Node factory/native scenario/host async H2-session oracle và actual stale/offline đầy đủ.

Registry design dùng control cố định từ trước run, object cụ thể được lưu dưới control lock trước execute. Không dựa vào append list muộn vì backend có thể chết trước append. Main membership finally vẫn drain control khi launcher lỗi trước registry stage. Node factory hiện chưa nhận profile/frame mới, CLI membership-stale chưa được mở. S1b1 actual positive c837d7c6 tiếp tục thuộc source hash trước, chưa là actual S1b2.



#### S2a — Node fixture membership protocol, PLAN10/11

Đã đối chiếu WF-TN-001 và UC-TN-001. Membership hiện hành phải được xác minh trước mở workspace, session Web/App riêng và logout đúng phiên. Private fixture methods dưới đây là dependency để kiểm các invariants đó, chưa mở public API hoặc native CLI mới.

Phạm vi ba files `ops/auth/native_membership_fixture.mjs` mới, `ops/auth/test_native_membership_fixture.mjs` mới và `ops/auth/run_native_e2e.mjs`. Reuse startFixture/closeNativeFixture/waitFrame/secret scanner và nativeSessionMap. Profile membership-stale có work deadline20m neo trước spawn, startup15m bị cắt bởi work deadline. Default/password/rate giữ path hiện có.

Controller mới chỉ giữ schema/sequence/deadline cho READY, MEMBERSHIP_TARGET, MEMBERSHIP_SUSPENDED và SNAPSHOT của profile này. READY strict5users/emails trong namespace run, immutable copy. Target/suspend exactfields canonicalUUID và safe integer, receipt suspend phải cùng B/grant, revision/authVersion tăng đúng1/statusSUSPENDED. Snapshot reuse bounded16session schema. One pending command, one-shot target/suspend, snapshot không chồng operation. Chặn partial buffer/closed/failed/exit/unsolicited/duplicate receipt. Commit public receipt chỉ sau await đúng deadline và owned child vẫn available.

Target/snapshot cap130s, suspend cap20s gồm startup5/commit5/drain5/IPC5, đều absolute và chỉ admission khi work còn đủ cap. Timeout/invalid/overlap/unknown phải fail sticky và await original fixture close, không retry hoặc xem observer timeout là terminal. Wait raw SQL vẫn thuộc Python control registry và closeNativeFixture original terminal/8zero. Pure controller có trusted clock injection cho host boundary tests, factory dùng performance.now, không thêm CLI timeout/config.

Acceptance tối đa ba mục.

- [ ] Host RED/GREEN strict schema/sequence/clone, pre/post clock expiry/rollback/throw, overlap/replay/late ACK, secret/partial buffer/unknown và owned close đang pending.
- [ ] Factory fake child đi qua parser/send/close thật, preserve existing rate/ARM/snapshot/default Node regressions, syntax/source/comment review trên finalhash.
- [ ] Independent source review và actual canonical mutation vẫn chờ gate S1b2. Task này chưa có native UI/H2/session acceptance, giữ READY_FOR_QA.

Budget dependency cho S2b/native scenario cần chốt trước BUILD. Nếu vừa snapshot130s vừa suspend20s trong picker thì cộng RPC30/headroom20 thành200s, vượt S1a cap180s. Không dùng cap180 hiện tại cho tổng này. Chọn giảm số operation trong pause hoặc cập nhật fixed cap có ledger/test/version mới trước integration. Final session oracle và cleanup reserve phải đối chiếu source semantics của work deadline/close18m, không suy từ READY+20m hoặc reset thời gian. Rollback chỉ controller/test mới và guarded factory branch.



#### S2a checkpoint10/11 — Node factory và actual read-only

**ROOT_SOURCE_HOST_PASS / ROOT_SCOPED_READ_ONLY_RUNTIME_PASS / READY_FOR_QA**. Controller/new factory methods đã nối,8Node suites51markers và5mutation guards đạt, syntax3files đạt. Đã tái hiện/sửa lateREADY startup bypass và raw READY dependency error. Source helper E7D17025, runner BA16FCA5. [Report/lệnh/hash/evidence](../../test-reports/FEAT-TN-001-membership-node-2026-11-10.md).

Fresh fixture9b2475e0 trả B2a8a8822 metadata1/1/1, snapshot đúng seed Android dbdeaa2b chưa revoked. Node owner ghi original shim exit0, close resolve strict8zero, driver13463 terminalda04b7 exit0. Đây là actual read-only target/snapshot/close, chưa gọi SUSPEND_B hoặc native UI.

- [x] Root controller/parser/factory methods và host negative tests, current default/rate/protocol regression.
- [x] Root actual read-only qua current Node/Python profile, original exit0 và owner8zero.
- [ ] Independent final source/comment/security trên current hashes.
- [ ] Actual SUSPEND_B PostgreSQL/unknown/CAS/drain sau review.
- [ ] S2b budget/session oracle, native scenario và host async/H2/session/audit/native actual.

Native CLI membership-stale vẫn chưa mở. Picker cap180s không chứa chuỗi130+20+30+20=200s, phải giải quyết trước scenario BUILD. Work deadline của Node được trả qua getter neo trước spawn, host không lấy READY làm anchor mới. Whole feature INCOMPLETE.



#### S2b — Budget picker và session/audit oracle, PLAN10/11

Session AppSessionState/FullSessionProfile không công khai sessionId. Reuse server snapshot baseline/mid/final và validateSessionDelta để bind đúng Android UUID, không đọc bearer từ secure storage. Baseline trước SDK, mid ở picker trước suspend, final sau UI logout. Cần audit LOGIN_SUCCEEDED/LOGOUT cùng AppUUID, outcomeSUCCESS/clientANDROID. Snapshot hiện chỉ có sessions nên bổ sung read-only evidence trước native BUILD.

**S2b1**, hai file Dart support probe và test hiện có. Picker cap cố định210s gồm snapshot130 +suspend20 +shared ACK RPC30 +headroom20 +margin10. Năm stage nhanh vẫn5s. Đây là thay đổi test-only dependency do scope pause có thêm snapshot, chưa mở native phase hoặc thay product API timeout15s. RED unit đổi expected210 trước source, rồi GREEN/fullFlutter/analyze/format. Không áp phase cũ vào native thực với cap180 khi operation ledger cần200.

**S2b2**, tối đa5files gồm Python shim/test và Node controller/factory/test. Thêm literal MEMBERSHIP_SESSION_EVIDENCE của profile membership-stale, chỉ resolve account0 đã pin trong live config. Một SELECT read-only có server bounds trả sessions≤16 và audit metadata bounded≤32 cho LOGIN_SUCCEEDED/LOGOUT, sessionId/eventType/outcome/clientType. Scope cùng run/user provenance/role marker, không token/email/verifier/payload tự do hoặc selector từ command. Node strictschema/copy/onepending/130s như snapshot, original close ownership giữ nguyên. Test schema/duplicate/audit count/foreignsession/STOP/deadline và regression, actual read-only được phép kiểm riêng, actual suspend chờ independent.

Ledger dự kiến cho **S2c** phải có code/negative tests khi nối runner. Work20m neo trước spawn. Pre-SDK proxy/hostNoCA10s +target130 +baseline130=270s, native phase reserve895s gồm warm SDK startup180 +channel60 +native420 +final readback130 +SDKstop95 +postPID10. Cần ít nhất1165s sau fixture READY trước prework, không sửa TTL. Điều kiện này yêu cầu backend/Flutter/AVD warm trước fresh fixture, slow fixture phải từ chối admission và cleanup. Native cap420 bao picker210,5fast pauses và UI operations, không dùng nó như SLA sản phẩm.

**Làm rõ source semantics thay cho giả định plan trước.** Python work deadline20m dừng backend admission. Launcher cleanup/STOPPED có thể hoàn tất sau work deadline. closeNativeFixture quan sát18m, nếu chưa terminal vẫn giữ raw exit và báo UNCONFIRMED. Vì vậy host không cấp thêm18m business work, cần chừa SDK stop/final oracle trước work cap và tiếp tục sở hữu cleanup tới terminal. Không khẳng định bound tuyệt đối20+18 khi raw exit chưa được xác nhận.

Acceptance S2b tối đa ba mục.

- [ ] S2b1 fixed210/5s boundary/clock/replay/cancel/defaultclock tests và fullFlutter/analyzer/format trên hash mới.
- [ ] S2b2 scoped sessions/audit metadata qua original Python/Node owner, host negatives, source/comment/security và fresh read-only evidence.
- [ ] Independent final review trước native mutation, S2c ledger có budget admission/RPC/cleanup failure tests trước actual. Feature và native stale/offline vẫn INCOMPLETE.

Rollback giới hạn cap/test và private read-only protocol additions. S2b1 chưa thêm phase mới vào nativePhaseBudget hoặc CLI vì integration target/runner chưa có consumer membership. Các numbers180/420/895/1165 là ledger cho S2c, chưa phải runtime bound đã hiện thực.



#### S2b checkpoint10/11 — Picker210 và session/audit metadata

**ROOT_SOURCE_HOST_PASS / ROOT_SCOPED_READ_ONLY_RUNTIME_PASS / READY_FOR_QA**. S2b1 fixed picker210s đã RED3/GREEN11/fullFlutter173/analyze/format đạt. Năm fast pauses vẫn5s. S2b2 Python/Node read-only sessions/audit projection đã nối,159Pythoncases/54Nodemarkers và4auditmutation guards đạt. [Report/lệnh/hash/evidence](../../test-reports/FEAT-TN-001-membership-budget-audit-2026-11-10.md).

Actual read-only runb203e2f8 trả Bdbcbef2d và seed sessionc38ef330 chưa revoked, LOGIN_SUCCEEDED/SUCCESS/ANDROID cùng UUID. Original shim exit0, owner.close strict8zero, driver51320 terminal280572 exit0. Chưa gọi SUSPEND_B, chưa chạy UI/App login/logout hoặc LOGOUT audit actual.

- [x] Root S2b1 cap210/5s boundary regression và fullFlutter/analyze/format.
- [x] Root S2b2 scoped read-only metadata schema/ownership/deadline/STOP host tests và fresh runtime seed-audit evidence.
- [ ] Independent source/comment/security trên current hashes.
- [ ] S2c budget admission/async bridge/native scenario + session/audit/H2 actual.
- [ ] Actual PostgreSQL suspend/unknown/drain và native stale/offline sau review.

Picker cap gap180→210 đã giải quyết ở support. Native runner/target/CLI membership-stale vẫn chưa mở. S2c ledger180/60/420/130/95/10 và1165s admission mới là proposal, không giả làm source runtime đã thực hiện. Work20m/close18m semantics đã được làm rõ theo source, không cộng lại timebusiness sau READY hoặc từ cleanup observer. Whole feature INCOMPLETE.


#### S2c1 — Native membership producer, PLAN10/11

Phạm vi bốn files Dart gồm support scenario mới, host boundary test mới, target integration hiện có và helper UI của rate scenario. Reuse helper monotonic input/tap/hit-test với default rate1260s giữ nguyên, membership dùng fixed420s. Không đổi layout sản phẩm. State matrix hiện có được kiểm qua loading → picker ready → permissionDenied/resourceNotFound → refresh loading → ready chỉ A → summary A/Admin → logout loading → login sạch.

Producer chỉ enterText/tap các key UI sản phẩm, đọc coordinator public snapshot và widget đã mount. Sáu checkpoint fixed theo S1a, picker210s và năm pause5s. Mỗi operation UI có absolute20s gồm input/scroll/IME/tap/busy/completion. Snapshot/epoch trước intent phải giữ nguyên tới pointer, completion phải mới và có busy được quan sát. Sau ACK picker kiểm lại cùng snapshot/epoch trước chọn B để bắt lifecycle hoặc intent chen ngang. B bị từ chối phải bỏ list/selected/protected UI, refresh chỉ A cùng UUID và role ADMIN, summary phải có email/A/nhãn vai trò đúng, logout phải xóa protected state. Không gọi trực tiếp coordinator action để thay UI gesture.

Target nhận phase membership-stale chỉ trong debug integration, không mở CLI host chưa có consumer. Clock420s neo valid fixture packet trước ACK, status/ACK dùng NativeMembershipCheckpoint. Wrapper bỏ password reference cả khi TLS/main/producer/teardown lỗi. Framework8m chỉ là backstop, không chứng minh I/O terminal.

- [ ] Host boundary RED missing producer, GREEN actual AppAuthApplication/coordinator/repository với API/store synthetic được ghi rõ. Positive sáu stage, sai role, B được mở sai, stale refresh, epoch chen sau ACK và phase timeout phải chặn stage tiếp.
- [ ] Target source wiring, fullFlutter/analyzer/format và regressions rate default1260s trên current hashes.
- [ ] Root source/comment review, independent review pending theo quota tester. Native PostgreSQL mutation/H2/session/audit actual và host async bridge thuộc S2c2, chưa được đánh đạt từ host mock.

Rollback giới hạn bốn files test-only, production main/API/security policy giữ theo source hiện có. Work20m/1165s admission/895s reserve vẫn chờ S2c2 runtime implementation. Whole feature INCOMPLETE.


#### S2c1 checkpoint10/11 — Native membership UI producer

**ROOT_SOURCE_HOST_PASS / READY_FOR_QA**. Producer đã đi qua UI input/tap thực trên host, sáu fixed checkpoints, exact roles, fresh busy, generation/epoch guard, B denied không cache, refresh chỉ A, summary A/Admin và logout form sạch. Target debug nhận membership-stale/clock420s và gate210/5s, wrapper dọn password reference cả lỗi sớm. Rate helper default1260s giữ regression.

- [x] Root host RED/GREEN9focused,182fullFlutter, analyzer4files và format0changed trên source S2c1.
- [x] Root đọc lại source/comment và giữ synthetic API/store boundaries trong report.
- [ ] Independent review final hashes, quota tester chưa mở lại.
- [ ] S2c2 host async bridge/895s reserve +1165s admission, H2/session/audit oracle.
- [ ] Android actual DB suspend và stale/offline final acceptance.

Chưa mở native CLI membership, chưa có actual SUSPEND_B/App run cho source này. HEAD ba425ad9/dev, dirty/untracked. [Report/lệnh/hash/evidence](../../test-reports/FEAT-TN-001-membership-scenario-2026-11-10.md). Whole feature INCOMPLETE.


#### S2c2a — Timed async membership host bridge, PLAN10/11

Phạm vi hai files Node, runner hiện có và fake-SDK consumer regression mới. Reuse runNativePhase ownership/parser/RPC/secret scanner/shutdown path, giữ sync-only callback rate cũ. Membership có startup180s/channel60s/native420s/final oracle130s/SDKstop95s/postPID10s, reserve895s kiểm trước SDK spawn. Native target/producer S2c1 đã có consumer. CLI actual membership vẫn đóng tới khi H2/session orchestration hoàn chỉnh.

Host membership nhận sáu stage fixed và cap210s ở picker,5s các stage khác. Deadline checkpoint neo status request send time + native remaining, cắt bởi work/native cap. Callback membership được await bằng pending ownership và polling deadline. Hết hạn/SDK terminal/boundary lỗi đóng capability, dừng SDK trước rồi vẫn giữ pending Promise tới settled thật, không xem timeout là cancel SQL. Chỉ valid callback completion còn active mới gửi ACK, sáu ACK RPC chia sẻ thêm fixed30s window trong checkpoint cap. Bind native PID từ initial status và giữ cùng PID/phase ở mọi status kể cả PASS.

- [ ] Fake SDK đi qua runNativePhase thật, positive async picker150s, fixed895s admission trước spawn, startup180/channel60/phase420 và exact210/5 stage bounds.
- [ ] Negative stage/schema/foreign phase/PID, async failure/late/pending callback ownership, shared ACK30s, final oracle130s; pending cleanup phải xong SDK trước nhưng consumer chưa return tới callback settled.
- [ ] Existing Node consumer/RPC/rate/protocol suites preserve, syntax/comment/security root review. Independent actual H2/session/DB mutation vẫn pending, source/host READY_FOR_QA.

Prework1165s admission và membership session/audit/H2 orchestration thuộc S2c2b. Không dùng reserve895 như bằng chứng whole fixture đủ lifetime, không mở CLI actual trước khi có prework consumer.


#### S2c2a checkpoint10/11 — Timed async host bridge

**ROOT_SOURCE_HOST_PASS / READY_FOR_QA**. Runner đã nhận fixed membership reserve895s/startup180/channel60/native420/final130 và six-stage async pause. Picker210/fast5, deadline từ status send time, shared ACK30s, same native PID/phase xuyên PASS. Pending callback được giữ tới completion thật sau SDK cleanup, không lấy timeout làm cancel.

- [x] Root RED/GREEN24markers mới,54regressionmarkers của8suites, syntax2 và5mutation guards.
- [x] Root source/comment review và fake-SDK/PID/clock boundaries được ghi rõ, source S2c1 Dart giữ manifest riêng.
- [ ] S2c2b orchestration1165s admission, external abort/fixture-close ordering và H2/session/audit final proof.
- [ ] Independent final hashes và actual PostgreSQL/native stale/offline.

Startup-late negative giữ APP_STOP_UNCONFIRMED/CLEANUP_FAILED, không ghi cleanup PASS. Native CLI membership vẫn đóng tới orchestration/review. [Report/lệnh/hash/evidence](../../test-reports/FEAT-TN-001-membership-consumer-2026-11-10.md). Whole feature INCOMPLETE.


#### S2c2a hardening — External abort fanout, PLAN10/11

Read-only discovery thấy fixture close hook chỉ cho đồng bộ và membership command lỗi có thể tự gọi close. Không thêm barrier chờ whole runNativePhase trước STOP vì runner còn await chính callback SQL đó, dễ tạo vòng chờ. Chốt hướng S2c2b là hook đóng admission/phát abort đồng bộ trước STOP, cleanup SDK/proxy/fixture được sở hữu đồng thời, chỉ cho lượt mới sau tất cả original terminal và readback. Whole feature không được PASS khi một owner chưa xác nhận terminal.

Bổ sung trong cùng hai files runner/consumer hiện có trước khi orchestration dùng. Membership nhận trusted externalSignal/assertExternalActive, kiểm trước spawn và mỗi native timing guard, abort đánh thức pending business RPC, async checkpoint/final oracle đóng fence ngay khi external abort nhưng giữ pending Promise tới settled sau SDK cleanup. Remove listener lúc finally. Rate behavior giữ evidence signal hiện có. Fake tests thêm pre-spawn/startup/channel-RPC/checkpoint-pending/oracle-pending abort, preserve all78markers và5mutations. Actual source review/fixture terminal vẫn pending, CLI membership đóng.


#### S2c2a hardening checkpoint10/11 — External abort và actual SDK preflight

**ROOT_SOURCE_HOST_PASS / ROOT_SCOPED_SDK_PREFLIGHT_PASS / READY_FOR_QA**. Consumer final29new +54existing =83Node markers, syntax2 và5mutations đạt. External pre-spawn/startup/channel RPC/checkpoint pending/final oracle pending đã được kiểm bằng fake SDK, không ghi thành actual auth proof.

Actual API24 owned69884 terminal478901 exit0, build/install/private fixture ACK/malformed/replay/framework PASS/app.stop/SDKexit0/postPID absent đạt cho preflight. AVD Nexa_Auth_API24 headless được khởi động từ inventory trống, owned78839 đang giữ warm cho task kế. Chưa tạo fixture/proxy/DB mới và chưa actual membership login/suspend/logout.

- [x] Root external abort fanout và pending ownership host tests, preserve rate/default regressions.
- [x] Actual SDK preflight API24 trên integration target import mới.
- [ ] S2c2b sync abort trước STOP và cleanup concurrent ownership tới mọi original terminal, H2/session/audit +1165s admission.
- [ ] Independent final source hashes sau quota19:08 local và actual native stale/offline.

Barrier đợi whole native phase trước fixture STOP chưa được thêm vì có thể tạo vòng chờ với callback SQL pending. Lựa chọn concurrent owned cleanup vẫn cần independent review trước actual. [Report cập nhật](../../test-reports/FEAT-TN-001-membership-consumer-2026-11-10.md). Whole feature INCOMPLETE.


#### S2c2b1 — HTTP/session/audit evidence và phase wrapper, PLAN10/11

Phạm vi tối đa bốn source files Node gồm evidence module mới, focused test mới, consumer fake fixture hiện có và phase wrapper trong evidence module. Reuse runNativePhase, validateSessionDelta, nativeSessionMap, fixed fixture methods và H2 metadata schema. Không mở CLI actual hoặc thêm product hook.

HTTP oracle nhận strict bounded REQUEST/STATUS/CLOSED metadata, exact ordered7requests login200/profile200/list200/Bdetail404/list200/Adetail200/logout204. matchesTarget chỉ true ở B. Từng checkpoint cần cumulative prefix0/3/4/5/6/7, mọi raw/secure active0, incomplete0, healthy/proxyAvailable, same counters/sequence và only2rawTLSnegative ngoài7HTTP. Baseline hostNoCA raw1, native noCA thêm1. Cho poll idle trong pause hiện có, không tự cấp deadline mới.

Phase wrapper nhận baseline/target owned đã pin, H2oracle/readSnapshot và fixture capabilities. Picker giữ snapshot→validateSessionDelta→SUSPEND_B/readback trước valid ACK, guard trước/sau mọi await/effect, xác nhận counter không tăng trong SQL pause. Final sau UI logout dùng sessionEvidence cùng AppUUID, seed unchanged và exact LOGIN_SUCCEEDED/LOGOUT SUCCESS ANDROID audit, preserve baseline audit multiset. Sau SDK stop kiểm HTTP không phát muộn. Failure giữ fixture close/raw SDK exit/pending callbacks tới terminal, cleanup concurrent sync abort trước STOP được đối chiếu S2c2a decision.

- [x] RED/GREEN pure H2 schema/order/status/target/prefix/idle/sticky and session/audit negatives, preserve duplicate audit semantics.
- [x] Wrapper qua runNativePhase consumer thật + fake SDK/fixture/H2 metadata, positive/suspend failure/audit wrong/late HTTP/cleanup pending boundaries, ghi rõ mocks.
- [x] Root comment/security/syntax +current consumer/rate regressions, independent review trước actual. Orchestration1165s/certificate/proxy/fixture original8zero và CLI vẫn task S2c2b2.

Test fake SDK factory được export có direct-entry guard, thêm observer hook đồng bộ cho status metadata để tái sử dụng private pipe/ownership consumer. Không sao chép SDK driver. Rollback giới hạn hai module mới và test-only factory export/hook, runner timing S2c2a giữ nguyên.


#### Kết nối DB thật10/11 — API → SQLx → PostgreSQL canonical

**ROOT_SCOPED_RUNTIME_PASS / READY_FOR_QA**. PostgreSQL17.11/iot_platform_lab đã được kiểm identity và truy vấn read-only thật. Fresh API fixture run22817835 login/me/list2workspace/detailA/detailB/logout đều status đúng, PostgreSQL snapshot exact+1session rồi revoke, seed unchanged. Owned18888 terminal615bdc exit0, original shim exit0 và owner strict8zero.

- [x] Kết nối/truy vấn PostgreSQL canonical thật và auth/workspace API persistence scoped.
- [x] Cleanup original fixture/temporary writer role sau probe.
- [ ] Web/Android visual E2E mới, independent repeat và membership stale/offline final acceptance.

Lượt probe đã dừng backend thử, DB canonical còn. Tester mở launcher run_local.py --port3000 để giữ backend live và tự nhập password TEST theo runbook. Task lớn vẫn paused theo người dùng, whole feature INCOMPLETE. [Report/lệnh/trạng thái môi trường](../../test-reports/FEAT-TN-001-real-db-connection-2026-11-10.md).


#### S2c2b1 fix sau independent testing10/11 — Cleanup pending I/O

Tester GPT6.1 xhigh tái hiện wrapper chờ runNativePhase, trong khi phase sau SDKstop chờ callback fixture pending và wrapper chưa gọi fixture.close. Repro chỉ fake capabilities, chưa quan sát deadlock PostgreSQL thật. [Independent finding/repro](../../test-reports/FEAT-TN-001-independent-membership-evidence-2026-11-10.md).

Phạm vi tối đa4files runner/evidence module và hai focused Node tests. Thêm trusted runtime.onPhaseClosing(phasePassed) đồng bộ trong phase finally trước SDK shutdown/pending drain. Wrapper failure hook khởi động memoized fixture.close trực tiếp, không await trong hook, gắn rejection handler ngay. Wrapper giữ cùng close observer và raw SDKexit tới terminal. Success không đóng fixture sớm để tránh external abort phá PASS. Nếu SDKcleanup/postPID lỗi sau phasePASS thì wrapper finally vẫn cleanup và giữ FAIL. Hook throw/async/giá trị khác undefined không được bỏ SDKcleanup hoặc cho PASS.

- [x] RED/GREEN pending mid/suspend/final callback chỉ settle khi close bắt đầu, kiểm close trước SDK shutdown, consumer chưa return tới fixture/SDK/callback settled, late receipt không đổi FAIL.
- [x] RED/GREEN invalid closing-hook return/throw và sync hook success, preserve consumer/rate/default/regressions.
- [x] Independent retest final hashes trước actual membership. Actual full/access vừa đạt trên runner CFF129D9 trước fix, password và regression sau fix ghi hash riêng. CLI membership vẫn đóng tới orchestration.


#### Self-test10/11 — Actual Android và PostgreSQL, independent fix/retest

**ROOT_SCOPED_RUNTIME_PASS / SOURCE_HOST_ACCEPTED / READY_FOR_QA**. Root tự chạy API24 full/coldresume/logout, access disabled/wrong/empty và password/coldrelogin, cả3commands exit0/original cleanup. Full/access runner CFF129D9, password final0F66BE42, target Dart57A0B1E7 giữ nguyên. Provider HTTP/PostgreSQL thật176checks/163unique đạt, application rows removed và anonymous failure audit giữ theo canonical policy.

Flutter182/analyzer sạch, Rust40, Python71+88, contract26, Node10suites117markers đạt. Tester GPT6.1xhigh chạy Web25/typecheck/ViteRAM và review/retest cleanup độc lập. Đã sửa missing export và pending-fixture-close ordering, RED/GREEN +independent retest accepted scoped host. Browser actual BLOCKED bởi kernel assets os3 ở cả Browser/Computer Use.

- [x] Root actual Android ba CLI và provider DB thật, cùng terminal/cleanup đúng scope.
- [x] Host regressions và independent review/retest bốn hash closing-hook final.
- [ ] Browser UI actual, native stale/offline exactH2 và S2c2b2 orchestration/CLI.
- [ ] Storage forensic, physical/accessibility và các owner gates còn mở.

Main APK đã build/install lại, installer gỡ bản debug cũ nên data AVD có thể đã xóa. Coldresume proof đã thu trước restore, forensic không được suy từ data sau install. Original owned headless AVD đã shutdown exit0, listener lab vắng. [Report/lệnh/limits/receipts](../../test-reports/FEAT-TN-001-self-testing-real-db-2026-11-10.md). Whole feature INCOMPLETE.


#### Chrome retry10/11 lúc23:06 — Tool startup BLOCKED

Root thử Browser Use, reset kernel và thử lại, sau đó reset Windows Computer Use/node_repl và khởi tạo @oai/sky. Cả hai runtime vẫn failed to write kernel assets / path specified / os error3 trước inventory Chrome. Lượt này **BLOCKED**, chưa có UI/business E2E evidence mới.

- [x] Thử lại và reset hai runtime theo recovery path, lưu exact tool error.
- [ ] Chrome actual validation/login/A-B/reload/logout/negative branches sau khi tool khởi tạo được.

[Report retry và log](../../test-reports/FEAT-TN-001-chrome-retest-2026-11-10.md). Whole feature INCOMPLETE.



## Checkpoint Chrome settings 11/11/2026

### S2c2b2 — Orchestration membership, BUILD11/11

### MB-AUTH-002/O1 — Feasibility modem fault, PLAN11/11

O2 PLAN11/11: SDK37.2.12/API24 đọc baseline guest wifi1/data1/airplane0, help svc hỗ trợ disable/enable. Chọn guest runtime fault qua SDK svc, không dùng ADB input/UI hoặc host network/security. Chỉ baseline cả hai bật mới admission; disable data+wifi rồi restore1/1 trong owned lifecycle, settings enum và native canary cùng origin bắt buộc. Source/host/pending/partial-restore review trước actual; capability feasibility chưa là offline login acceptance. [Plan O2, dependencies và tiêu chí](../../test-reports/FEAT-TN-001-guest-network-plan-2026-11-11.md).

O2 actual/source checkpoint sau PLAN: đã sửa baseline stale qua canary và parser grant sai section theo independent findings. Host final19+19markers root/independent đạt. Actual23376 exit1 không có off confirmation; diagnostic26678 exit1 xác nhận Wi-Fi command fail cả disable/enable, final settings baseline nhưng restore ACK chưa xác nhận. Guard mới preflight actualba8e06 chặn SHELL_WIFI_PERMISSION_NOT_PROVEN trước mutation. Không chạy lại fault API24 này hoặc tick offline acceptance. O3 bắt đầu read-only capability API36/plan rồi mới source/actual; không bỏ compatibility API24. [Report/lệnh/evidence/giới hạn](../../test-reports/FEAT-TN-001-guest-network-2026-11-11.md).

O2 actual/source checkpoint sau PLAN: đã sửa baseline stale qua canary và parser grant sai section theo independent findings. Host final19+19markers root/independent đạt. Actual23376 exit1 không có off confirmation; diagnostic26678 exit1 xác nhận Wi-Fi command fail cả disable/enable, final settings baseline nhưng restore ACK chưa xác nhận. Guard mới preflight actualba8e06 chặn SHELL_WIFI_PERMISSION_NOT_PROVEN trước mutation. Không chạy lại fault API24 này hoặc tick offline acceptance. O3 bắt đầu read-only capability API36/plan rồi mới source/actual; không bỏ compatibility API24. [Report/lệnh/evidence/giới hạn](../../test-reports/FEAT-TN-001-guest-network-2026-11-11.md).

Actual11/11: **MODEM_FAULT_INEFFECTIVE**. Owned18171 đã terminal, ba canary baseline/off/restored đều REACHABLE qua product native TLS, H2 mỗi lượt tăng đúng1request/status/closed, incomplete0. Modem được restore HOME và readback riêng xác nhận. Giữ MB-AUTH-002 offline mở; task O2 là capability thực sự chặn route cùng origin rồi mới business UI. Chrome retry inventory/reset vẫn kernel assets os3, chưa có Web business evidence mới. [Report và nguyên trạng exit receipt](../../test-reports/FEAT-TN-001-network-modem-actual-2026-11-11.md).

Trước offline business run, kiểm capability gsm data off trên đúng AVD owned. Phạm vi ba files gồm native probe integration target, host runner và host test. Native probe không credential/DB/main hook, reuse product createAuthHttpClientFactory exact origin10.0.2.2:8443 và public lab certificate. Upstream synthetic GET/me trả401 cố định, không tạo session. Baseline và restored cần HTTP/TLS/status/body hoàn chỉnh, H2request/status/close và raw idle cùng proxy. Off phase chỉ nhận SocketException hoặc TimeoutException làm route observation, TLS/parser/status lỗi phải FAIL riêng. Nếu off vẫn HTTP401 thì ghi MODEM_FAULT_INEFFECTIVE, không chạy login hoặc đóng MB-AUTH-002.

Host lưu baseline gsm data enum qua SDK console, chỉ thay gsm data off rồi restore đúng enum trong finally, kiểm ACK/readback/command terminal. Không đổi Wi-Fi/firewall/security host hoặc dùng ADB input. SDK probe từng lần giữ raw child exit, không lấy timeout làm terminal. Proxy/upstream cùng owner còn healthy xuyên ba lượt, không dùng capture zero đơn độc làm reachability proof. H2scope/probe là synthetic backend, không auth business E2E. Source/host independent review trước actual, restore main và AVD sau xong. Nếu modem ineffective, lập task capability mạng khác và giữ offline acceptance mở theo báo cáo thiết kế10/11.

Checkpoint11/11. **INDEPENDENT_RUNTIME_VERIFIED / READY_FOR_QA** cho stale membership. Root owned66674 terminal726b22 và tester owned81400 terminal0cff6b cùng exit0, separate fresh fixture/cleanup. H2 exact7request/status/close, UI stale B404→list A→open A→logout và scoped session/audit oracle đều chạy qua consumer thật trên API24. Independent postcleanup writerLabActive=false. [Report, commands và evidence](../../test-reports/FEAT-TN-001-membership-orchestration-2026-11-11.md).

- [x] Orchestration admission1165s, warm certificate trước fixture, proxy/hostNoCA10s và native reserve895s.
- [x] Setup deadline chủ động close cả owners, bind AbortSignal, raw pending/late owner/late events và no premature terminal host regressions.
- [x] Independent source/retest final hashes, actual root và independent Android/API/DB stale membership với original cleanup.
- [ ] Android offline H2/session/UI actual, Chrome matrix, storage/physical/accessibility và toàn CP-03 còn mở.

Independent review phát hiện deadline post-await chưa chủ động đóng bind pending. Prerequisite riêng gồm local_https_proxy.mjs và regression entry test. Dùng once listening có AbortSignal của original proxy để close đánh thức bind, catch vẫn chờ raw terminal. Coordinator có setup timer10s phát abort/close cả owners, giữ pending setup tới late settlement. Certificate factory sync với OS timeout60s được warm trước cấp fixture, public validity vẫn kiểm qua toàn run. Do đó fixture ledger10s áp dụng proxy/hostNoCA, không bắt event loop preempt synchronous certificate factory. Cần test bind never-listens, late onOwned/settle/error, timer cleanup và regression rate/proxy.

Reuse original fixture membership-stale20phút, TLS factory/proxy metadata capture, H2 oracle và runNativeMembershipPhase. Phạm vi tối đa5source/test files gồm orchestrator riêng, focused host tests, entry riêng và export hostNoCA helper hiện có. Ledger giữ prework270s và native reserve895s. Sau READY admission1165s trước target130, baseline130 và proxy/hostNoCA10. Reserve giảm theo phần prework đã tiêu, không gia hạn fixture deadline. Kiểm lifetime certificate/proxy bằng monotonic và wallclock hiện hành. Không tăng TTL hoặc dùng READY làm mốc mới.

Fixture close hook phát external abort đồng bộ trước STOP. Proxy abort khóa SDK admission, bắt đầu owned fixture close và vẫn giữ phase/callback pending, SDK/proxy/fixture terminals tới completion thật. Chốt owner proxy ngay trước async bind qua onOwned. Secrets chỉ RAM, PFX xóa sau handoff TLS. PASS chỉ sau phase/H2/session/audit/PID và cả hai cleanup owners xác nhận. Host tests phải kiểm slow READY, insufficient reserve mỗi prework boundary, wall/monotonic expiry, abort trước/during phase, delayed bind handoff, pending fixture+proxy terminal, failure/reentrant cleanup và no secret output. CLI actual chỉ sau independent final review.

Kernel assets đã khởi tạo lại được, native inventory nhận diện Chrome. Browser API vẫn trả `Local browser use is disabled in Work settings`. Chưa có API hỗ trợ bật setting trong phiên này. **BLOCKED**, Chrome actual trong lượt này NOT_RUN, whole feature INCOMPLETE. Cần bật local browser trong Settings để chạy fresh real-DB Web E2E. [Report và hướng dẫn khôi phục](../../test-reports/FEAT-TN-001-chrome-settings-blocker-2026-11-11.md).


## Checkpoint tiếp tục 11/11/2026 — Cancellation và positive membership DB

Chrome extension đã hoạt động trở lại và mở được task tab mới với Web login. Sau fresh fixture READY, browser API lại báo Work settings disabled. Root đã đóng Vite14102 và browser fixture14397, cả hai terminal exit0, original cleanup PASS. Chrome business E2E còn mở. [Chrome retry](../../test-reports/FEAT-TN-001-chrome-real-db-retry-2026-11-11.md).

Tester độc lập phát hiện STOP/deadline/backend-death trong startup operation vẫn có thể admission UPDATE. Bản sửa bốn files Python cấp lifecycle guard live từ control cho operation, kiểm trước/sau startup, sát send và trước receipt sau drain. STOP sau guard được phân loại in-flight/unknown, không replay, vẫn giữ drain ownership. Source đã review/retest độc lập trên final hashes.

- [x] Regression RED cho STOP/expired/dead trong startup, GREEN guard live, pre-send lost authority và in-flight STOP/drain/no-retry.
- [x] Python top74/nested88 và Node membership fixture/evidence/protocol17/30/14markers, source review/retest độc lập.
- [x] Root positive canonical SUSPEND_B probe qua original factory/control/operation, commit/readback/drain, version +1/grant unchanged và baseline/final session/audit unchanged. Owned67646 terminalae049e exit0, original8zero, post-cleanup writer role absent.
- [ ] Independent actual repeat, DB negative CAS/unknown/drain theo toàn bộ tiêu chí task S1b2.
- [ ] S2c2b2 orchestration1165s/certificate/proxy/abort cleanup và native stale/offline H2/session/audit cùng run, CLI sau review.
- [ ] Chrome actual matrix, storage forensic, physical/accessibility/owner và CP-03 còn mở.

**ROOT_SCOPED_RUNTIME_PASS / SOURCE_REVIEWED / READY_FOR_QA**, whole feature INCOMPLETE. Manifest self-test10/11 giữ source checkpoint lịch sử, bốn hash mới thuộc report11/11. [Report, driver Tester và evidence](../../test-reports/FEAT-TN-001-membership-cancellation-fix-2026-11-11.md), [review độc lập](../../test-reports/FEAT-TN-001-membership-probe-review-2026-11-11.md).
