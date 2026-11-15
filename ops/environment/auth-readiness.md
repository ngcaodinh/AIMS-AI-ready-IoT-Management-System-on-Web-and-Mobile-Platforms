# FEAT-TN-001 — manifest sẵn sàng auth không chứa secret

T1-C0 checkpoint2026-10-29: native SDK fixture RAM channel đã root/independent
PASS trên Android16/API36, host6protocol+4lifecyclePASS; Flutter3.47.5/Dart3.13.4
stable xác nhận trực tiếp. Mainrestoreexit0/reaped; AVD Pixel_7 mở, SDK idle.
Không DB/proxy/product API trong C0; C1/C2 còn NOT_RUN/HOLD theo oracle review.
[C0 handoff/evidence](../../docs/test-reports/FEAT-TN-001-native-control-2026-10-29.md).

Checkpoint2026-10-29 T1-B: source proxy HTTPS loopback8443→3000 đã BUILD,
root19/independent19actual TLS/CLI synthetic cases và T0 sixTLS regression PASS;
mutation cumulative cap bị bắt cả2hướng, không open Important/Blocker trong scope.
Native custom CA/canonical API chưa kiểm, tiếp T1-C.
[Proxy handoff và lệnh mở](../../docs/test-reports/FEAT-TN-001-local-https-proxy-2026-10-29.md).
Các dòng “proxy chưa có” bên dưới là snapshot trước T1-B.

T1-A2026-10-28: main debug đã nhận public CA riêng cho exact emulator origin.
Root6focused/134full/product-profile flag checks/analyzer/format và nativeconfig2PASS;
tester GPT-6.1/xhigh tự chạy6focused PASS ngoài sandbox, source SHA khớp.
T1-B proxy chưa có, chưa native HTTPS login; không coi compile-time mode tests
là profile/release APK acceptance. [Handoff](../../docs/test-reports/FEAT-TN-001-debug-lab-trust-2026-10-28.md).

Checkpoint mới2026-10-28: ngoài sandbox provider176assertions/cleanup readback0,
Pixel_7/API36 và2native configuration tests PASS; main thật đã build/cài/run.
Node/OpenSSL memory-only TLS probe6cases PASS root sau source finding được sửa;
chưa có proxy/Dart trust/native login HTTPS. CUA hiện mất native pipe/browser
host. [Runtime resume](../../docs/test-reports/FEAT-TN-001-runtime-resumed-2026-10-28.md),
[TLS plan/evidence](../../docs/test-reports/FEAT-TN-001-local-tls-plan-2026-10-28.md).
Các mô tả main Hello World/scaffold, SDK blocked và TLS NOT_RUN bên dưới là
snapshot lịch sử; không dùng thay trạng thái checkpoint hiện tại.

Trạng thái: PROVIDER_BASELINE_VERIFIED / CP-02_PARTIAL / BROWSER_BLOCKED_CONNECTION.

C1-W1 workspace/password transport READY_FOR_QA: root15focused/94full Flutter
PASS, analyzerNoissues3.9s/format41files0changed; source review GPT-6.1/xhigh
Safe to merge. Independent runtime retest PENDING vì tester usage limit, không
đổi model hoặc gán rootchecks thành độc lập. Main còn scaffold; tiếp W2 private
session capabilities rồi UI/main/native HTTPS. Không DB/provider/browser mới.
[Handoff/files/evidence](../../docs/test-reports/FEAT-TN-001-android-capability-2026-10-26.md).

C1-S1 Android repository: READY_FOR_QA/SCOPED_RETEST_PASS tại source boundary.
3files mới/untracked, dev@ba425ad dirty/chưa commit, docs local/ignored. Tester
GPT-6.1/xhigh final21focused/79full Flutter PASS, analyzerNoissues3.9s và
formatter38files0changed; review source cuối đóng material findings. Session
admission chờ secure-store ACK/server identity, quarantine không bypass,
resume generation và pendinglogout chỉ clear khi có serverproof+deleteACK;
corrupt storedtoken có recovery. Không API/native/browser mới. Main còn Hello
World; tiếp C1-W capabilities rồi C1-UI/main và C1-N HTTPS/native thật. Browser
inventory mới vẫn apps=[]/browsers=[]; không chặn source Android độc lập.
[Handoff/source/tester](../../docs/test-reports/FEAT-TN-001-android-session-2026-10-26.md).
Các mô tả S1 chưa triển khai bên dưới là snapshot trước checkpoint này.

C1-T Android transport: READY_FOR_QA/SCOPED_RETEST_PASS.4newsource/test files,
GPT-6.1/xhigh21focused/58full Flutter tests PASS, analyzerNoissues; formatter
35files0changed. HTTPS origin/defaultTLS/no redirects/direct proxy/token68,
response bounds/total deadline/method-specific failures/late-result fences.
Không API/native/browser mới; main vẫn scaffold, repository/W/UI/N chưa xong.
C1-S1 PLAN REVIEWED_READY_FOR_BUILD; quarantine/suspend/expiry AC đã sửa từ findings.
Không cần Web browser để tiếp tục source S/W/UI. App actual API còn HTTPS
endpoint/topology; local TLS feasibility là proposal NOT_RUN, chưa nới trust.
[Handoff/tester](../../docs/test-reports/FEAT-TN-001-android-transport-2026-10-26.md).

CP-02-MEASURE M4b-P:96isolated Rust/88host/16focused độc lập GPT-6.1/xhigh,
fmt/Clippy và176providerassertions PASS (163distinct IDs;15Punique). Actual
HTTP WEB/ANDROID503 khi cùng pool held8, haiPoolAcquireError5009419/5014308µs,
gen1→2/no-loss; committedunchanged/recovery cùng pool. GracefulSTOP/reap,
SELECT role/HBA/fixture0. READY_FOR_QA/SCOPED_RETEST_PASS cho P; production
budget/ownerreview/CP-02 tổng/C1/browser/SLO chưa đóng. Source6files untracked,
chưa commit; docs ignored/local. [P handoff](../../docs/test-reports/FEAT-TN-001-pool-budget-2026-10-26.md).
Các dòng pool còn thiếu và provider161 bên dưới là snapshot lịch sử trước P.

CP-02-MEASURE M4b-Q:90isolated Rusttests/6focused độc lập GPT-6.1/xhigh,
fmt/Clippy/2mutation PASS; chỉ2verify regression tests, runtime/helper/testcũ
normalizedfingerprints khớp baseline. Verifytimeout≥5s/outer8s và callerabort
giữworkerpermit/window tới explicitrelease/3uniqueCompleted. READY_FOR_QA
ởunitboundary, không provider/HTTP overload mới. Pool/CP-02/C1/browser/SLO
còn mở; provider161/cleanup0 bên dưới thuộc M4b-L.
[Q handoff](../../docs/test-reports/FEAT-TN-001-queue-budget-2026-10-26.md).

CP-02-MEASURE M4b-L:72host/8focused độc lập GPT-6.1/xhigh/3mutation và161provider
checks PASS. WEB/ANDROID actualwait+holder còn khóa sau503; AccountAcquireError
5005063/5005753µs, exact5stage, stateunchanged/recovery+1sessionaudit. Cleanup
role/HBA/fixture0. READY_FOR_QA/SCOPED_RETEST_PASS; pool/queue/SLO/browser/C1
còn mở. C1 thiếu HTTP/repository/coordinator/main composition, còn storage/
topology; browser Web không là dependency source Android độc lập. Snapshots
bên dưới là lịch sử của từng slice.
[M4b-L handoff](../../docs/test-reports/FEAT-TN-001-lock-budget-2026-10-26.md),
[C1 audit](../../docs/test-reports/FEAT-TN-001-android-c1-readiness-2026-10-26.md).

CP-02-MEASURE M4a:64host/7focused độc lập GPT-6.1/xhigh/3mutation và145provider
checks PASS. Repeated baseline60success/20windows/540Completed/36groups×15,
percentile audit khớp, cleanup role/HBA/fixture0. Hai Important cancellation/
coverage-test-hole đã sửa/retest. M4a READY_FOR_QA/SCOPED_RETEST_PASS; chưa
pool/lock/queue budget faults, SLO/browser/C1. Snapshots dưới là lịch sử slice.
[M4a handoff](../../docs/test-reports/FEAT-TN-001-measure-m4a-2026-10-26.md).

CP-02-MEASURE M3: hai tester GPT-6.1/xhigh độc lập 7Rust/12Python PASS;
strict-hex Nit và Important regression phân bố stage đã sửa/retest. Root88Rust/
57host tests, fmt/Clippy/3mutation và135provider checks PASS. Enabled smoke
đúng9Completed/process, valid/drop/stale/poison đúng; cleanup role/HBA/fixture0.
M3 READY_FOR_QA/SCOPED_RETEST_PASS; M4 repeated baseline/budget/browser/C1
vẫn chưa đạt. Snapshot M1/M2 bên dưới là lịch sử của từng lát cắt.
[M3 handoff](../../docs/test-reports/FEAT-TN-001-measure-m3-2026-10-26.md).

CP-02-MEASURE M2:81isolated Rusttests/3libtests độc lập GPT-6.1/xhigh,
fmt/Clippy/2mutation và132provider regressions PASS source cuối. Pool/BEGIN/
bucket/User/FencedWork/ACK boundaries READY_FOR_QA, default sink None; hai
test coverage/isolation findings đã sửa. Cleanup role/HBA/5fixture graph0.
Enabled provider samples, M3–M4/browser/C1 vẫn chưa đạt.
[M2 handoff](../../docs/test-reports/FEAT-TN-001-measure-m2-2026-10-26.md).

CP-02-MEASURE M1:79Rusttests/12libtests độc lập GPT-6.1/xhigh, fmt/Clippy/mutation
và132provider regressions PASS. Diagnostic port/recorder bounded/hasher stages
READY_FOR_QA, mặc định disabled. Cleanup role/HBA/5fixture graph0; chưa có
provider stage samples, M2–M4 còn mở; browser/C1 không đổi trạng thái.
[M1 handoff](../../docs/test-reports/FEAT-TN-001-measure-m1-2026-10-26.md).

CP-02-UF mới nhất:132provider checks/45host tests PASS source cuối. Password/
status ×WEB/ANDROID quan sát actual lock wait trước mutation COMMIT rồi401,
no issued session/success audit, counter+1/exact failure audit. Hai disabled
cases có correct-password/status precondition. Review/mutation PASS; cleanup
role/HBA/fixture/holder backends0. CP-02 còn hash/queue/pool/lock measurement;
browser inventory vẫn rỗng, C1/CP-03 chưa đạt.
[Handoff hiện tại](../../docs/test-reports/FEAT-TN-001-user-fence-2026-10-26.md).

QA độc lập GPT-6.1/xhigh2026-10-26: bốn coordinator races FAIL trước sửa,
retest4/4PASS; Web25tests/build42modules PASS sau generation fence, busy lúc
xếp hàng và ownership cả success/catch. Provider92/host30/Flutter37 và một
native mock API36 ngang200% PASS; role/HBA/fixture graph0. Browser inventory
vẫn rỗng, C1 và CP-02/03 chưa đạt. [QA](../../docs/test-reports/FEAT-TN-001-independent-testing-2026-10-26.md),
[fix handoff](../../docs/test-reports/FEAT-TN-001-coordinator-fixes-2026-10-26.md).

CP-02-ACK mới nhất:92provider checks/30host tests PASS, Web/App mất ACK sau
COMMIT thật→503/no credential, mỗi case1new session/audit TTL24h; BEGIN/COMMIT=1
trong window. Fresh-context review/mutation PASS, proxy worker join và cleanup
role/HBA/graph0. CP-02 còn User fence race/budget nội bộ, C1/browser vẫn chưa đạt.
[Handoff hiện tại](../../docs/test-reports/FEAT-TN-001-commit-ack-2026-10-26.md).

CP-02-AF mới nhất:84HTTP+PostgreSQL checks PASS,16host tests/mutation PASS.
Required audit permission denial thật→Web/App503/no credential/session rollback,
failure counter5vẫn commit và lần6trả429. INSERT audit restored/readback, cleanup
role/HBA/owned graph0. Còn DB commit ACK UNKNOWN/fence race/budget nội bộ.
[Handoff hiện tại](../../docs/test-reports/FEAT-TN-001-audit-fault-2026-10-26.md).

Cập nhật mới nhất CP-02-MI:69HTTP+PostgreSQL checks PASS qua2process/2listener,
6same-key wrong cho5×401+1×429/Retry-After,6multi-key success.11host tests,
fmt/Clippy và mutation PASS; cleanup role/HBA/owned graph0. Login error palette
Web/App đồng bộ surface/coral;18widgets/build/analyzer/1native profile PASS.
CP-02 còn fault/UNKNOWN/fence race/budget nội bộ; browser visual và C1 vẫn NOT_RUN.
[Handoff hiện tại](../../docs/test-reports/FEAT-TN-001-provider-concurrency-2026-10-26.md).

Snapshot baseline trước CP-02-MI:
User đã phê duyệt role1giờ/auth-workspace-audit/5accounts/2workspaces/cleanup.
Provider HTTP+PostgreSQL59checks PASS gồm password9/revoke Web+Android/relogin;
cleanup role/HBA/owned graph đọc lại0. Không hỏi lại quyền DB. Chrome/Edge/IAB
surface đều unavailable dù đã có quyền. Login hint đã bỏ Web/App; build42modules,
App9widgets/1native API36 landscape200% PASS.
[Handoff hiện tại](../../docs/test-reports/FEAT-TN-001-provider-password-2026-10-26.md).
Owner review CP-01, benchmark/runtime CP-02 và browser/Android CP-03 vẫn mở.

Các snapshot/blocker approval bên dưới là lịch sử trước phê duyệt và lượt
provider59checks mới; không dùng chúng để hỏi lại quyền hoặc phủ nhận evidence.

Password policy source checkpoint2026-10-26: user thay min12 bằng min9,
new/temporary9–128 có hoa/thường/số0–9; login9–128 giữ legacy composition,
current1–128. Web/App/backend/contract và lab-source đã đồng bộ; không chạy
launcher/DB cho task này.39contract/67Rust/17Web/37Flutter/4lab-spy tests PASS,
build/fmt/clippy/analyzer PASS.8native profiles login/password×API24/36×dọc/
ngang200% trên source cuối PASS với metrics/restore; login viewport0 có
regression/mutation và header responsive. Native và Tester hướng dẫn ghi tại
[policy handoff](../../docs/test-reports/FEAT-TN-001-password-policy-2026-10-26.md).
Không thay provider BLOCKED_APPROVAL. Whole-E2E goal sau password-policy progress
đã có3lượt resumed impasse mới, update_goal xác nhận BLOCKED; không dùng counter
lịch sử. [Audit resumed](../../docs/test-reports/evidence/auth-e2e-resumed-gate-audit-2026-10-26.json).
Các count
trong bảng dưới là snapshot lịch sử của từng lát cắt.

Gate audit2026-10-26 04:35UTC: sau C0d source/native progress, nhánh C1 thật
vẫn cần CP-02/storage/topology. Đã thử mở IAB trực tiếp: `Browser is not
available: iab`; không có DevTools tool. Web HTTP200 chỉ là availability.
Không có câu trả lời cho phê duyệt DB cụ thể; không retry launcher hoặc đi
đường vòng. Main Android hiện vẫn Hello World scaffold. Audit ghi các lượt
không còn bước BUILD đủ dependency. Sau3lượt liên tiếp, goal chuyển BLOCKED,
chưa whole-feature completion. Không tạo DB khác: runbook database hiện hành
chỉ cho canonical iot_platform_lab; rejection handoff cấm đổi DB/runner để vượt
quyết định. Chờ user/external state thay đổi trước tiếp tục.
[Audit](../../docs/test-reports/evidence/auth-e2e-gate-audit-2026-10-26.json).

Bảng dưới là snapshot lịch sử trước các slice provider/measurement ở đầu
file, không phải blocker DB hiện tại. Quyền DB đã resolved; không xin lại
phê duyệt từ các dòng cũ. C1 còn thiếu HTTP/coordinator/main wiring và gate
storage/topology; browser Web không là dependency của source Android độc lập.
[Audit C1 hiện tại](../../docs/test-reports/FEAT-TN-001-android-c1-readiness-2026-10-26.md).

| Hạng mục | Điều đã xác minh trong repository | Prerequisite trước BUILD tương ứng | Evidence tạo sau BUILD, trước checkpoint nghiệm thu |
| --- | --- | --- | --- |
| Android limited/password UI | R9-C0d1/2:35Flutter tests (9password mới), host9tests, analyzer7.8s/No issues, full format29files0changed.4native profiles API24/36 portrait/landscape200% PASS, restored; keyboard0 regression sửa bằng responsive header. | READY_FOR_QA mock/source; main vẫn scaffold, C1 sau CP-02/storage/topology. Provider DB permission còn chờ; browser inventory vẫn rỗng. | Không auth004/password/revoke/AT-WF acceptance; QA visual/TalkBack/IME thủ công/physical còn thiếu. [Current handoff](../../docs/test-reports/FEAT-TN-001-android-password-ui-2026-10-26.md) |
| Android full profile consumer | R9-D2 immutable MeProfile/default full,57cases và UUID policy chung3consumer; full26Flutter tests/analyzer8.6s/format24files0changed PASS. | Body parser không chứng minh identity/session admission hoặc provider. C1 vẫn sau CP-02/storage/topology; permission provider DB còn chờ. | READY_FOR_QA source; browser inventory vẫn rỗng. [Current handoff](../../docs/test-reports/FEAT-TN-001-android-full-profile-2026-10-26.md). Các count hàng dưới là snapshot lịch sử theo từng slice. |
| Android workspace consumer | R9-D1 defaultACTIVE parser72cases/shared fixture0.2.1 PASS, required-cursor mutation bị bắt/restored. Full Flutter25tests, analyzer No issues/9.0s, full-format21files0changed. | Chưa HTTP/API/session/UI mapping hoặc provider. C1 vẫn sau CP-02/storage/topology; permission cho provider lab cụ thể còn chờ. | Provider/client và positive authE2E không suy từ parser hoặc native mock. [Latest consumer](../../docs/test-reports/FEAT-TN-001-android-workspace-consumer-2026-10-26.md) |
| Android native display/update | R9-C0c3:8profiles login/picker×API24/36×portrait/landscape200% PASS, metrics đầu/cuối khớp và settings/policy restored. Host8tests/mutation/negative guard đã kiểm. R9-FMT1 format-only riêng đã sửa finding login: full19files0changed, Flutter24tests/analyzer8.7s PASS. | Không auth API/session thật; C1 vẫn cần CP-02/storage/topology. Source DTO WorkspacePage có thể chuẩn bị độc lập theo contract0.2.1. | Visual/TalkBack/rotation giữa input/request/physical/provider E2E vẫn chưa kiểm; không dùng mock thay acceptance. [Latest matrix](../../docs/test-reports/FEAT-TN-001-android-workspace-display-2026-10-26.md) |
| Android workspace presentation | C0c1/C0c2: state/screen+preview mock,9workspace tests; full Flutter24tests PASS, analyzer No issues/13.3s; scoped format5files0changed. API24/36 mỗi OS1native mock flow PASS. | C1 real API/session/navigation vẫn sau CP-02/storage/topology. Full-mobile format còn fail login_screen.dart ngoài slice và được giữ nguyên. | Còn native picker landscape/font2×/visual/TalkBack; không dùng login4displayprofiles hoặc mock selected thay provider/E2E. [Workspace runbook](../../docs/test-reports/FEAT-TN-001-android-workspace-ui-2026-10-26.md) |
| API/Web origin | Vite localhost5173 proxy `/api/v1` tới127.0.0.1:3000; HTTP state exact-origin, cookie Secure/HttpOnly/SameSite=Lax/Path=/api/v1. GET origin policy tách POST; ngoại lệ HTTP config chỉ localhost. | Production HTTPS/trusted proxy và browser Secure-cookie localhost cần xác nhận; lab không chứng minh production topology. | START-05/CP-03 kiểm origin, cookie/CSRF và Path bằng browser thật. |
| Backend/toolchain | GNU Rust1.99.1 đã build/test64/64; Axum0.8.6/Tower0.5.2 được pin cùng lock. Có HTTP handlers, SQL read projection và opt-in auth-lab. | Provider trên canonical DB bị auto-review từ chối role grants/fixture; chờ phê duyệt cụ thể. Không reset DB để vượt guard. | START-04/CP-02 chạy provider auth/isolation và đo timeout/race/budget; không suy từ compile. |
| Password/token | Argon2id0.5.3 policy19456KiB/t2/p1, semaphore2/wait5s, OS CSPRNG256bit và digest-only session từ core; crypto tests PASS. Đây là cấu hình, chưa là benchmark. | Deployment key custody/shared key qua restart và phép đo budget còn thiếu; launcher chỉ dùng key lab tạm qua stdin. Kiểm email canonical collision trước migration dữ liệu thật. | START-04/CP-02 đo hash cost, queue, pool/lock timeout và failure path; không suy số đo từ strategy. |
| Limiter/audit | Core/PostgreSQL implementation hiện có; unit atomicity/UNKNOWN tests PASS, chưa có HTTP+DB run hiện tại. | CP-01 và phép đo budget; provider runner chỉ có sequential limiter scenario, chưa thay multi-instance concurrency. | START-04/CP-02 gửi sáu request sai đồng thời trên nhiều instance để kiểm năm 401, một 429; đo khóa/pool/hasher, inject lỗi audit/commit unknown và quét redaction. |
| Web browser | Auth UI build PASS,16 coordinator mock tests PASS, Vite `/login` HTTP200. CUA inventory không có browser/app và IAB unavailable. | Kết nối browser để runtime verification; CP-02 vẫn cần evidence provider. | START-05/CP-03 kiểm Chrome/Edge/Firefox stable với cookie race, CSRF, reload limited, lost response, focus/keyboard và responsive; ghi version thực tế khi chạy. |
| Android | Flutter3.47.5/Dart3.13.4, storage11.2.0;15Flutter tests gồm8UI/6storage/1parser42cases và6host runner unit PASS. Base4+adapter4 native cases có cold boot, key-loss2OS, backup admission2OS PASS. UI mock4profiles API24/36 portrait+landscape200% PASS, analyzer No issues/12.5s. | B2/B3/B4a/C0a/display slice READY_FOR_QA, C0b tổng PARTIAL. Host handshake sau app-start xử lý policy reset API36; native thiếu host RED, mutation bị bắt và source restored. Settings/policy restored. Còn restore/OEM/D2D/physical, xoay trong input/request/TalkBack/visual và auth API/repository thật/CP-02. Main scaffold, preview không token/API thật. | START-06/CP-03 cần full flow/account switch thật; preview/mock/native PoC không thay E2E. [Latest handoff](../../docs/test-reports/FEAT-TN-001-android-display-handshake-2026-10-26.md) |
| Provider/client G1 | OpenAPI/fixture 0.2.1 draft sau FEAT002/L1; lần chạy đầy đủ ngày 2026-10-24 đạt 36/36 static checks. Web client draft không phải provider/client compatibility evidence. | CP-L1/CP-01 API/Web/Mobile owner review header/context/error/fixture; không đòi producer/consumer runtime. | START-05/06 và CP-03 chạy producer/consumer compatibility, browser cookie race và Android runtime trước G1 PASS. |

Kế hoạch đo G1 security: pin môi trường local/lab không secret và clock UTC; chạy sáu login sai cùng normalized email từ hai backend instance; ghi status/Retry-After, p50/p95 giữ khóa, hash duration, pool wait/timeout và số audit outcome đã redaction. Inject lỗi DB/audit trước commit và mất ACK sau commit; quan sát không phát credential khi chưa có commit xác nhận. Không đặt ngưỡng tùy tiện trước baseline; owner chốt budget theo số đo và NFR của handoff. Chưa chạy ca nào trong bảng này.
