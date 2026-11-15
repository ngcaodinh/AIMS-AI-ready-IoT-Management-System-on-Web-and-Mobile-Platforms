# FEAT-TN-001 — Ma trận acceptance theo test ID, 13/11/2026

**INCOMPLETE; không phải owner sign-off.** Bảng gốc là audit tài liệu/source và artifact read-only; các host tests chạy sau đó được ghi riêng ở bổ sung cuối báo cáo. Không chạy DB, SDK, browser hoặc test sản phẩm thực trong audit. User đã miễn thiết bị vật lý `USER_SCOPE_OVERRIDE_2026-11-12`; emulator đủ cho phạm vi đó, miễn không có nghĩa các ca emulator chưa chạy thành PASS. iOS UI ngoài scope. `NOT_RUN` dưới đây nghĩa là **toàn bộ tổ hợp đúng câu chữ của ID chưa có bằng chứng được đối chiếu đủ**, không có nghĩa mọi phần của ca chưa từng chạy. `PASS` là đúng phạm vi ghi trong dòng; không suy một tổng suite hoặc một screenshot thành toàn bộ acceptance. Không thấy FAIL sản phẩm mới trong audit này. Những giá trị historical có source/manifest tương ứng, không tự trở thành kết quả trên mọi source dirty hiện tại.

## Index bằng chứng

Android13/11 được đối chiếu lại đúng §18.6 Flutter widget/integration. [Mapping và7composed tests](FEAT-TN-001-android-remaining-mapping-2026-11-13.md) có root00d37c exit0 trên6ECDEB66…BE4ED27 sau sửa attempt-counter finding. [Sol independent review](FEAT-TN-001-sol-independent-final-2026-11-13.md) chấp nhận scope. Các yêu cầu emulator riêng từng ca component ở bảng cũ được bỏ, actual server/native có evidence riêng theo §18.7. Password-forensic không được thêm vào MB002 như điều kiện ngoài câu chữ, SEC008/009 vẫn giữ nguyên.

Final provider13/11 đạt215markers/202distinct, owner85598/abedde exit0,8zero cleanup. Bổ sung same-account concurrent durable distinct sessions và expired capability HTTP401. [Report, failures đã sửa và giới hạn review](FEAT-TN-001-ios-provider-and-policy-2026-11-13.md).

Provider sau sửa IOS đã có actual212markers/199distinct, original22125/f89b27 exit0 và8zero cleanup. Shared password fixture26vectors chạy đạt Rust/Web/Dart. [Report hiện hành, code state, lệnh và giới hạn review](FEAT-TN-001-ios-provider-and-policy-2026-11-13.md). Independent review bổ sung bị usage limit, các PASS dưới đây thể hiện execution scope và vẫn READY_FOR_QA.

Cập nhật13/11 sau audit gốc. Root đã hoàn tất Chrome cookie A/B/missing và U1 actual. O4 có independent actual trên final coordinator, storage có plugin/adapter process-persistence và native key-loss probe. [Bàn giao Chrome/CLI và giới hạn](FEAT-TN-001-cli-and-cookie-handoff-2026-11-13.md), [Sol high review đối chiếu độc lập](FEAT-TN-001-sol-final-review-2026-11-13.md), [O4 final review](FEAT-TN-001-offline-final-review-2026-11-13.md), [storage](FEAT-TN-001-independent-storage-2026-11-13.md). Các dòng NOT_RUN vẫn giữ nếu còn biến thể đúng tiêu chí chưa thực thi.

- **P** — [provider HTTP/PostgreSQL root 10/11](evidence/feat-tn-001-self-test-real-provider-2026-11-10.log), build `ba425ad-dirty`, fixture synthetic, 176 markers/163 ID khác nhau, `APPLICATION_ROWS_REMOVED`, anonymous audit retained. [Thông tin lệnh, terminal và giới hạn](FEAT-TN-001-self-testing-real-db-2026-11-10.md); [audit độc lập marker](FEAT-TN-001-independent-auth-testing-2026-11-10.md). Independent audit đọc artifact, không replay provider. Marker được nêu theo tên chính xác; xem `ops/auth/verify_provider.py`, `verify_concurrency.py`, `verify_user_fence.py`, `verify_commit_ack.py` để biết assertion. `foreign-workspace-not-found-no-data` thực tế assert status 404, không tự chứng minh zero bytes hoặc một workspace B đã biết.
- **H** — [root host/contract/Rust/Flutter 12–13/11](FEAT-TN-001-completion-pass-2026-11-12.md); [independent Web host 10/11](FEAT-TN-001-independent-auth-testing-2026-11-10.md). `web/tests/auth.test.mjs` dùng API/lock giả; Flutter repository/coordinator/widget tests dùng fake. Host không chứng minh UI/native/provider thực.
- **C** — [Chrome thực 12/11](FEAT-TN-001-chrome-real-db-2026-11-12.md), [Web API và rate thực 07/11](FEAT-TN-001-web-api-and-negative-coverage-2026-11-07.md), [ledger GET failure/limited/cross-tab 12/11](evidence/chrome-final-safe-ledger-1112.json), và [independent artifact review](FEAT-TN-001-final-review-2026-11-12.md). Chrome runs là root, independent review chỉ đọc. GET503/connection failure inject trong browser, không phải lỗi server tự nhiên; ledger bật sau limited reload nên không chứng minh headers của reload. [Ảnh accessibility 13/11](evidence/chrome-login-accessibility-1113.png) SHA256 `C90FDAA2287C4947D91B2AFAB35648E8D97BD8C4EC0A0A851E6EB5AAF5E949E7`; root quan sát labels/focus/error links/toggle keys, 320px, contrast 13.16 dark/14.73 light; không phải screen-reader run.
- **N** — [Android actual 10/11](FEAT-TN-001-self-testing-real-db-2026-11-10.md), [shared Web/API24 actual 08/11](FEAT-TN-001-shared-web-api24-2026-11-08.md), [stale membership independent actual 11/11](FEAT-TN-001-membership-independent-actual-2026-11-11.md), [native API24 rate independent](FEAT-TN-001-api24-rate-independent-2026-11-09.md), [API36 rate independent](FEAT-TN-001-native-rate-evidence-independent-2026-10-31.md). Root actual và independent actual/review phân biệt theo report; không thay source hashes bằng manifest hiện tại.
- **O4** — [manifest source offline 13/11](evidence/native-offline-manifest-2026-11-13.json), [actual API36 log](evidence/native-offline-actual-2026-11-13-r2.log) SHA256 `35BA7700ECA4DD7A9C39F6B8F190C257B283D834BB2402BFCA120F3BFB6D1D11`. Root báo same-run R→UNAVAILABLE→R, quiet 30s, explicit login, A/Admin, B/User, logout, exact 9 HTTP và baseline/negative/live-mid/final SQL; log lưu checkpoints request 1/1/2/5/9, target và owned terminal PASS. Root báo original 8-zero cleanup và additional readback 8-zero; audit này chưa tái thực thi SQL. Manifest ghi `ba425ad...` dirty, scope source/host offline, không phải binary reproducibility hay independent actual repeat.
- **R2** — [lost Web response 08/11](FEAT-TN-001-web-response-loss-r2-and-stale-2026-11-08.md), [independent artifact review](FEAT-TN-001-web-response-loss-r2-independent-2026-11-08.md). Một response fault + reload/recovery là partial, không phải cookie matrix.

## 18.1 Backend unit

| ID | Status | Bằng chứng và phần còn lại |
| --- | --- | --- |
| UT-AUTH-001 | PASS | Root receipt 13/11 `login_passes_password_whitespace_unchanged_to_verifier` cho credential synthetic có whitespace đầu/cuối, fake verify chỉ đồng ý đúng chuỗi gốc, login tạo một session fake. Không phải crypto/DB thật. |
| UT-AUTH-002 | PASS | Sol host mapping104tests và final Rust policy2tests aea6fa kiểm từng login/current/new boundary, Unicode scalar và decomposed9/composed8 không normalize. Shared26vectors có Web/Dart execution riêng. |
| UT-AUTH-003 | PASS | Provider212 `public-auth-invalid-projection-equivalent` so known-wrong/unknown/disabled exact401 AUTH_INVALID message/details; correlation UUID riêng từng request. |
| UT-AUTH-004 | PASS | P `disabled-web/disabled-android-invalid`, `-no-credential`, `-no-issued-session` sau fence; generic AUTH_INVALID. |
| UT-AUTH-005 | PASS | Provider212 exact limited login không role/workspace field, IOS limited me/workspaces/devices403 error-only, logout204 rồi token401. Web limited cùng account vẫn403. Password change allowlist tiếp tục đạt qua verify_password_flow. |
| UT-AUTH-006 | PASS | I1 Sol actual177markers normal account0 WEB/ANDROID full limited=false. `commit-ack-{web,android}-exact-committed-pair` đối chiếu persisted expires_at=issued_at+24hours cùng client/user/correlation/newUUID. [Mapping chính xác](FEAT-TN-001-provider-i1-sol-actual-2026-11-13.md). |
| UT-AUTH-007 | PASS | Provider215 `concurrent-same-account-distinct-durable-sessions` đối chiếu6rows đúng digest/user/metadata/TTL cho6barrier-released success qua2processes/3accounts,6UUID khác nhau. Hai intents cùng account đều durable. |
| UT-AUTH-008 | PASS | P `shared-limiter-attempt-1` đến `-6`, lần 1–5 401, lần 6 429; cùng input synthetic. |
| UT-AUTH-009 | PASS | C Web real rate chờ 921054ms, sau countdown chủ động submit thành công; N có 900s API24/API36. Đây không phải kiểm mọi clock/race variant. |
| UT-AUTH-010 | PASS | Host 13/11 `negative_shared_login_fixtures_match_http_provider` chạy handler/router thật với pool lazy: fixture `CT-LOGIN-UNKNOWN-ROLE` và `CT-LOGIN-UNKNOWN-WORKSPACEID` đều 422/UNKNOWN_FIELD, không Set-Cookie; request bị từ chối trước khi cấp session. Đây là host boundary, không phải DB fixture mới. |
| UT-AUTH-011 | PASS | Shared14email host vectors/canonical lookup và provider actual274 kiểm uppercase/ASCII-edge variants cùng userUUID, distinct sessions, duplicate canonical email đúng users_email_normalized_key trong rollback/savepoint. Root closeout numeric receipt và cleanup8zero trong report15/11. [Closeout15/11](FEAT-TN-001-closeout-2026-11-15.md). |
| UT-AUTH-012 | PASS | Host 13/11 `session_authorization_checks_current_authority_and_context_before_limited` chạy guard domain với session vừa tới expires_at và account chuyển Disabled sau khi session được tạo; cả hai `SessionInvalid`. P `user-fence-status-*` kiểm riêng fence ở provider. |
| UT-AUTH-013 | PASS | Host router `negative_shared_login_fixtures_match_http_provider` kiểm null/number/unknown với path/code và không cookie; root receipt 13/11 `login_boolean_and_unknown_authority_fields_do_not_echo_input` kiểm true/false từng field, unknown, no-echo canary; UT001 kiểm whitespace đến verify. Scope host/fake, không thay DB provider. |

## 18.2 Repository/transaction

| ID | Status | Bằng chứng và phần còn lại |
| --- | --- | --- |
| IT-AUTH-001 | PASS | Provider212 `*-session-protected-digest-metadata-ttl` đối chiếu row WEB/ANDROID/IOS với SHA256 digest của capability trong RAM, user/client/limited/contextUUID, no raw secret, issued+24h và expiry đúng response. Không xuất row/token ra evidence. |
| IT-AUTH-002 | PASS | I1 Sol actual177markers có audit-fault rollback/no-credential trước commit và commit-ACK-loss đúng một BEGIN/COMMIT, đúng một session/audit mới, persisted24h expiry cho WEB/ANDROID, không internal retry. Client replay có criteria riêng. [Exact assertions và SQL predicate](FEAT-TN-001-provider-i1-sol-actual-2026-11-13.md). |
| IT-AUTH-003 | PASS | P `commit-ack-*-exact-committed-pair` so số session/audit tăng một và matched session ID sau commit, cả Web/Android; chỉ transaction fixture này. |
| IT-AUTH-004 | PASS | Provider252 actual owner32577/8d1932 exit0 kiểm ACTIVE list và sequential SUSPENDED/REMOVED exclusion của owned USER membership, active workspace còn lại vẫn trả về, detail deny error-only. Independent Sol source/assertion review đạt. Four-membership fixture riêng thuộc IT008. |
| IT-AUTH-005 | PASS | P `picker-current-membership-roles`: hai memberships role ADMIN/USER trong page, HTTP200; fixture P. |
| IT-AUTH-006 | PASS | P `concurrent-shared-limiter-counts` asserts sorted 5×401 + 429; `concurrent-shared-limiter-safe-response` checks 429 Retry-After and no cookie. |
| IT-AUTH-007 | PASS | Actual owned-role audit INSERT rollback và session INSERT denial WEB/ANDROID/IOS503, exact error/no credential, session/audit/counter unchanged, finally restore/readback. Provider270/274 và root15/11 kiểm lại, cleanup8zero. [Closeout15/11](FEAT-TN-001-closeout-2026-11-15.md). |
| IT-AUTH-008 | PASS | Provider thật368/331: fixture bốn memberships ACTIVE A/D, SUSPENDED B, REMOVED C; limit1 trả đúng A/D không lặp/không bỏ, terminal empty, B/C detail404, đổi B làm cursor stale rồi restart trả đúng A/D. Cleanup hai workspace bổ sung trước tiếp tục verifier. [Checkpoint15/11](FEAT-TN-001-remaining-checkpoint-2026-11-15.md). |
| IT-AUTH-009 | PASS | Provider thật368: tám interleavings có pg_blocking_pids; password/status/reset login-first giữ User fence qua verify→commit rồi mutation revokes đúng UUID; mutation-first deny/no session. Reset là protocol credential-reset dưới User fence, không claim workflow/quota FEAT004. [Checkpoint15/11](FEAT-TN-001-remaining-checkpoint-2026-11-15.md). |
| IT-AUTH-010 | PASS | Provider thật368 kiểm đúng password vẫn429, WEB/ANDROID/IOS, hai process và source IP thật127.0.0.2 dùng chung email key; timestamp không kéo dài. Backdate owned window899s→RetryAfter1, 900s→200 durable session/window clear. Exact boundary kết hợp domain unit, không sửa production clock. [Checkpoint15/11](FEAT-TN-001-remaining-checkpoint-2026-11-15.md). |
| IT-AUTH-011 | NOT_RUN | Limiter/session/success-audit faults và commit ACK loss actual PASS. Provider rerun 15/11 07:56Z xác nhận repeated measurement-export-control rejection 409 không đảo cùng committed session; remote exporter outage chưa được fault-inject nên tổng ID vẫn NOT_RUN. [Evidence mới](FEAT-TN-001-continuation-2026-11-15.md). |
| IT-AUTH-012 | PASS | Actual rejection-audit fault giữ401/429/counter5 và không credential. New limiter counter/window UPDATE denied thật trả503/no fakecount. Operational metric có historical repository actual marker login/password failure-audit degradation increments fixed counters shared by cloned stores, source getter kiểm1/0 rồi1/1. Provenance13/11 và15/11 tách khỏi historical24/10, không gán HTTP metric export mới. [Closeout15/11](FEAT-TN-001-closeout-2026-11-15.md). |

## 18.3 Contract

| ID | Status | Bằng chứng và phần còn lại |
| --- | --- | --- |
| CT-AUTH-001 | PASS | Provider212 `web-full-login-exact-projection`, protected cookie/header contextUUID/no-store, exact summary/expiresAt/limited, không token body; persisted row match expiry. |
| CT-AUTH-002 | PASS | Provider212 `android-full-login-exact-projection`, token/expiresAt UTC/limited và exact summary, không cookie hoặc Web-context headers, persisted digest/expiry đúng. |
| CT-AUTH-003 | PASS | Sol host104tests gồm26negative shared HTTP cases và23case canary matrix missing/null/number/bool/empty/unknown/duplicate/malformed/MIME/oversize, exactpath/code và no-cookie/no-echo trước lazy pool. [Mapping host](FEAT-TN-001-host-acceptance-mapping-2026-11-13.md). |
| CT-AUTH-004 | PASS | IOS enum mismatch đã RED→sửa backend/migration0020. Provider212 actual full/limited bearer, exactprojection/persistedmetadata/24h, protected me200/limited403, cookie-misuse401 và logout204/token401 đạt. iOS UI N/A theo OQ007. Final independent review bổ sung còn pending. |
| CT-AUTH-005 | PASS | Provider212 exact401 AUTH_INVALID và so cùng public projection known-wrong/unknown/disabled, chỉ correlationId được sinh riêng. |
| CT-AUTH-006 | PASS | P `shared-limiter-attempt-6` và `rate-limit-retry-after`; N/C quan sát client thực. |
| CT-AUTH-007 | PASS | P `limited-resource-guard` asserts `/devices` 403/PASSWORD_CHANGE_REQUIRED trên Web limited. |
| CT-AUTH-008 | PASS | Provider252 `web-full-profile-exact-schema`, exact page/summary assertions, ACTIVE-only membership và không có resource fields. Root32577/8d1932 exit0, eightzero cleanup, independent Sol review đối chiếu assertion. [Report](FEAT-TN-001-final-continuation-2026-11-13.md). |
| CT-AUTH-009 | PASS | P `empty-login`, `empty-guard-or-empty` asserts exact 200 items=[]/nextCursor=null. |
| CT-AUTH-010 | PASS | Provider212 exact WEB/ANDROID login serialization và Webfull/limited, IOSfull/limited projection, UUID/context/UTCexpiry/booleanlimited, kênh credential đúng. Oracle6tests có negative extraauthority/cross-transport/malformed metadata. |
| CT-AUTH-011 | PASS | Sol high15/11 đối chiếu actual401/403/409/429/503 exact error-only4keys/genericmessage/details/UUID, hostvalidation fieldErrors/noecho/no credential, RetryAfter chỉ RateLimited và actualpositive/absence controls. Required-context GET/mutations409 trướcsideeffect, original/foreignsessions giữ identity sau denial. Missingcontext `/me` là discovery200 được duyệt. Root274/parity/backendworkspace và commonserializer source đủ originalscope, không thêm gate. [Review](FEAT-TN-001-closeout-review-2026-11-15.md). |
| CT-AUTH-012 | PASS | Actual stable signed traversal/noomission/terminalempty, user/limitbinding và authoritychange rejection. Host production HMAC cursor tests futurecontrol/expiryboundary/version/tamper400, default20/range1..100, immutable ACTIVE/UUID namespace và unsupported filter/sort rejection. Backend workspace suite15/11 exit0. Scope từng boundary ghi rõ trong report. [Closeout15/11](FEAT-TN-001-closeout-2026-11-15.md). |
| CT-AUTH-013 | PASS | Actual root15/11 provider274/258 qua production Web API/Dart DTO + HttpAppAuthApi,14boolean true bao gồm full/limited/auth401/validation422/rate429/service503/context409. Missing/null/type/summary mutations và extension compatibility giữ rõ, raw response chỉRAM/private stdin. Owner71887/1f85d9exit0, cleanup8zero, Sol high review. [Closeout](FEAT-TN-001-closeout-2026-11-15.md). |
| CT-AUTH-014 | PASS | P `limited-confirmation-no-profile`, `limited-guard-or-empty`, `limited-resource-guard`: `/me`403 có context/CSRF, `/workspaces`403, không profile trong `/me`; scope fixture Web. |
| CT-AUTH-015 | PASS | Shared26password và14email vectors chạy Rust/Web/Dart. Unicode scalar boundaries/password preserved, new composition policy hiện hành, email server canonicalization và rawclientwire/422. Web35/Flutter213/backend workspace PASS, provider canonical lookup/unique-key actual. Không thêm client normalizer. [Closeout15/11](FEAT-TN-001-closeout-2026-11-15.md). |
| CT-AUTH-016 | PASS | Sol host HTTP23case matrix cùng nestedduplicate test kiểm duplicate/unknown400, contenttype415, oversize413, fieldpath/code, whole serialized response không canary, không cookie/token. [Mapping host](FEAT-TN-001-host-acceptance-mapping-2026-11-13.md). |

## 18.4 Security

| ID | Status | Bằng chứng và phần còn lại |
| --- | --- | --- |
| SEC-AUTH-001 | PASS | Provider212 so exact public401/code/message/details và envelope của wrong/unknown/disabled, correlation UUID riêng. Không suy kết quả này thành timing equivalence SEC014. |
| SEC-AUTH-002 | NOT_RUN | Đã scan full actual success/denial audit rows với password/email/actual bearer và named fields, chín correlation UUID tra đúng outcome; audit scan PASS. Structured log sink chưa thu, giữ acceptance tổng mở. [Checkpoint15/11](FEAT-TN-001-remaining-checkpoint-2026-11-15.md). |
| SEC-AUTH-003 | NOT_RUN | Native response-loss actual18257/884869 exit0 scan đúng App PID logcat23241bytes và SDK stdout77254/stderr529bytes; tám canary gồm password/5emails/2actualbearer, zero canary/named-field matches. Browser debug actual còn thiếu, không đóng cả Web/App từ App alone. [Checkpoint15/11](FEAT-TN-001-remaining-checkpoint-2026-11-15.md). |
| SEC-AUTH-004 | PASS | Host handler `negative_shared_login_fixtures_match_http_provider` từ chối role=ADMIN và workspaceId bằng422/UNKNOWN_FIELD, không cookie, trước lazy pool. Đây là cùng evidence đã nhận ở UT010/SEC010. Known-foreign resource/query-order thuộc SEC011. [Reconciliation](FEAT-TN-001-provider-i1-sol-actual-2026-11-13.md). |
| SEC-AUTH-005 | PASS | Provider215 insert đúng một expired IOS session fixture mới với TTL24h, owned user/run/provenance/digest, GET me bằng capability đó trả401/SESSION_EXPIRED exact error-only. Giữ trigger/session live. Original cleanup8zero. |
| SEC-AUTH-006 | PASS | Provider252 actual kiểm foreign Origin WEB/ANDROID/IOS, Web thiếu Origin/Referer, HTTP/foreign Referer fallback, bootstrap foreign Origin me/workspaces/devices deny. Exact error/no credential/CORS grant và unchanged session/success-audit counts. Existing CSRF guard assertions giữ scope mutation. Independent Sol review đạt. |
| SEC-AUTH-007 | PASS | Provider212 đổi Forwarded/X-Forwarded-For và WEB/ANDROID/IOS qua sáu attempts cùng canonical email vẫn5×401+429, exact envelope và no-cookie. Metadata tự khai không đổi limiter key. |
| SEC-AUTH-008 | PASS | API24 native inspection trên production adapter namespace chứa synthetic marker: plaintext/Base64 không có trong private shared preferences; compiled allowBackup=false và đúng manifest refs/exclusions cloud/device-transfer. Persist→instrumentation→restore original terminals exit0. Không claim actual cloud restore/OEM transfer. [Checkpoint15/11](FEAT-TN-001-remaining-checkpoint-2026-11-15.md). |
| SEC-AUTH-009 | NOT_RUN | Provider thật audit/metric/evidence named-field+canary và correlation lookup đạt; nine denial stages+fixed bounded labels. Provider artifact chưa thu structured log/browser debug/App debug; native response-loss bổ sung App PID logcat và SDK pipes actual PASS với tám canary/zero matches. Còn structured log/browser debug. Không suy toàn bộ sink từ ledger. [Checkpoint15/11](FEAT-TN-001-remaining-checkpoint-2026-11-15.md). |
| SEC-AUTH-010 | PASS | Host router `negative_shared_login_fixtures_match_http_provider` kiểm role/workspaceId 422/UNKNOWN_FIELD, không cookie; root receipt 13/11 `login_boolean_and_unknown_authority_fields_do_not_echo_input` kiểm thêm expiresAt bị từ chối, không cookie/token. Pool lazy, scope handler trước DB. |
| SEC-AUTH-011 | PASS | Production DeviceService.schema spy với full ACTIVE session, known tenant selector và current no-membership/suspended/revoked grant đều Forbidden, pin/content counters0. Positive admission control pin1. Backend4tests15/11 PASS và Sol high review. Service/application boundary, HTTP resource adapter WF010 chưa có nên E2E007 giữ mở. [Closeout15/11](FEAT-TN-001-closeout-2026-11-15.md). |
| SEC-AUTH-012 | PASS | Cùng provider212 có forged forwarding headers/clientlabels không né window, sáu barrier-released requests split hai backendprocesses cho shared key đúng5×401+429 và shared session discovery. Scope local deployment policy hiện hành. |
| SEC-AUTH-013 | PASS | Provider252 exact foreignOrigin/missing/wrong context GET/mutation, CSRFmissing/wrong và cookieA+realaccountBcontext/CSRF trên me/logout/password409. Contextual me200 đối chứng cả hai originalsessions còn usable, unchanged authority. Cookie/header policy assertions và8zero cleanup, independent Sol review đạt provider scope. Chrome controlled lateA fault có report riêng. |
| SEC-AUTH-014 | PASS | Cùng fixture/provider, chín denial xoay ba vòng wrong/unknown/disabled, cùng valid input và pinned Argon2id m19456/t2/p1/v19, mỗi request positive hashWork và đủ12 measurement stages. Ba mẫu/nhánh khoảng453–510ms, không early return bỏ verify. Evidence hữu hạn, không phải production latency SLO. [Checkpoint15/11](FEAT-TN-001-remaining-checkpoint-2026-11-15.md). |
| SEC-AUTH-015 | PASS | Provider252 foreignOrigin với clientTypeANDROID/IOS đều deny/no credential, Web thiếuOrigin/Referer hoặc HTTP/foreignReferer fallback deny, mixedcredential/wrongtransport assertions đạt. No new CORS grant/session/audit sideeffect, rootactual và independentSol review. |
| SEC-AUTH-016 | PASS | Historical repository actual24/10 có marker `Admin audit read excludes global/other workspace and expired rows; keyset has no duplicate` cùng USER/foreign deny. Sol13/11 đối chiếu AuditService currentAdmin và Pg WHERE workspace_id=$1 loại globalNULL. Scope service/repository, HTTP audit-logs adapter thuộc WF040 chưa có. [Sol scope audit/provenance](FEAT-TN-001-sol-independent-final-2026-11-13.md). |

## 18.5 Web

| ID | Status | Bằng chứng và phần còn lại |
| --- | --- | --- |
| WEB-AUTH-001 | PASS | C full login→profile/list→picker và H `full login confirms context before picker and rechecks selection`; C có runtime request statuses. |
| WEB-AUTH-002 | PASS | H `same-form queued login locks submit immediately and issues one POST`, fake lock/API; scope component/coordinator test. |
| WEB-AUTH-003 | PASS | C disabled generic 401/UI và H `credential rejection returns to form with no automatic retry`. |
| WEB-AUTH-004 | PASS | C real 5×401, 429/countdown rồi 921054ms, không auto POST trước explicit login. |
| WEB-AUTH-005 | PASS | C limited200→me403→password-only, không workspace; P `limited-confirmation-no-profile` context/CSRF, H matching403. Các evidence khác run, không khẳng định header C được capture. |
| WEB-AUTH-006 | PASS | C picker A/B trước lựa chọn; P `picker-current-membership-roles`; đây là finite observation của fixture. |
| WEB-AUTH-007 | PASS | C empty/create disabled có giải thích, P `empty-guard-or-empty` exact page. |
| WEB-AUTH-008 | PASS | Root Chrome13/11 kiểm AX accessible names, DOM labels/`aria-invalid`/`aria-describedby`, focus qua Enter/Tab, toggle Space, viewport320 và contrast; C ghi thao tác và ảnh bổ sung. Đây là kiểm accessibility tree/DOM và keyboard, không khẳng định đã nghe output của ứng dụng screen reader. |
| WEB-AUTH-009 | PASS | Eight added consumer tests đưa malformed200/missing-credential me401 qua parser/coordinator, UNKNOWN giữ qua restore, explicit GET-only recovery không autoPOST, khóa protected state. Final34tests b99c05 và independent259b0d exit0. [Mapping](FEAT-TN-001-web-remaining-mapping-2026-11-13.md). Actual jar variants có Chrome54ca evidence riêng. |
| WEB-AUTH-010 | PASS | Consumer matrix missing/wrong responsecontext, thiếuCSRF,401/503/network/200 sai limited confirmation đều khóa/noaccepted; matching403 mới password-only. Web34tests và independent Sol review đạt component/integration boundary. [Exact names/mapping](FEAT-TN-001-web-remaining-mapping-2026-11-13.md). |
| WEB-AUTH-011 | PASS | Added coordinator tests on-demand cursorencoding/dedupe/emptycursor-page/selectiondenial và page503recovery, no extraattempts. Provider cursor-version/server currentmembership guard có actual riêng. Web34/independent34 exit0, consumer integration scope. |
| WEB-AUTH-012 | PASS | Fresh-coordinator acceptedlimited marker restore gửi context,403matching lấyfreshCSRF trước password/logout. No-markerdiscovery không gửi context, không mutation trước explicit confirmation. Added consumer integration tests trong34PASS/independent34; Chrome limitedreload/logout actual cũ giữ runtimeprovenance riêng, không suy headers khôngcapture. |
| WEB-AUTH-013 | NOT_RUN | Chrome54ca committedresponse-loss/cookieA/B/missing/reload/newtab/candidate/confirmation và session/audit oracle giữ scope. Added consumer storage-denied trướcPOST PASS trong34tests. Chrome364d sharedjar timeout actual noautoreplay và explicit discoverycandidate đạt. Chrome thật15/11 bổ sung login/picker/logout và nhánh lỗi, nhưng full browserprocess close/reopen chưa chạy. [Evidence mới](FEAT-TN-001-continuation-2026-11-15.md). |
| WEB-AUTH-014 | NOT_RUN | Chrome364d controlled actualA-cookie replay sauacceptedB đổijar, detail26708.60 vàreloadme26708.110409 AUTH_CONTEXT_MISMATCH, hai tab khóa UI/cache, explicitdiscovery chỉcandidate. Riêng race dùng WebLocksteal/timer120s. Default15s restored timeout14708.61 abort/noautoPOST PASS. Logout204clear-cookie replay chưa xóa jar, CDPdeletecookie→me401 chỉ là missingcookie branch. Chrome thật15/11 kiểm logout204 thành công nhưng không chạy delayed clear-cookie/race variant; giữ NOT_RUN. [Faults và evidence](FEAT-TN-001-continuation-2026-11-15.md). |
| WEB-AUTH-015 | PASS | C injected workspace GET503 và `/me` connection failure, UI khóa và explicit GET-only recovery; ledger một login POST, không auto login/logout. Scope hai faults này. |

## 18.6 Android

| ID | Status | Bằng chứng và phần còn lại |
| --- | --- | --- |
| MB-AUTH-001 | PASS | N full login/secure-storage plugin thực, A/B, cold resume/recheck/logout trên API24; scope fixture cụ thể. |
| MB-AUTH-002 | PASS | O4 root+independent actual chứng minh offline/no-autoPOST/explicit recovery. New composed HTTP-adapter SocketException→repository→host case kiểm signedOut/networkUnavailable, zero storewrites, đúng1client-creation attempt, explicit recovery blank password và không replay. Root00d37c exit0, Sol review. Native plain-storage forensic vẫn thuộc SEC008/009. |
| MB-AUTH-003 | PASS | New composed widget case write side-effect rồi storage error kiểm không admission, recovery rõ, revoke đúng candidate token và explicit recovery. Root00d37c7/7, Sol scoped review. Native plugin persistence có evidence riêng, không suy widget failure thành lỗi plugin thật. |
| MB-AUTH-004 | PASS | New widget case cùng host lifetime render A rồi login B, giữ callback picker cũ, kiểm A email/workspace/summary biến mất và request mới dùng đúng B token. Root00d37c exit0/Sol accepted component scope. |
| MB-AUTH-005 | PASS | N limited/password-only UI, không workspace/control trong scope password actual. |
| MB-AUTH-006 | PASS | N full A/B picker; O4 có A/Admin rồi B/User; không suy mọi realtime path từ hai rows. |
| MB-AUTH-007 | PASS | New widget case framework lifecycle giữa held workspace-list bootstrap, resume chờ fresh profile ACK trước picker mới. Reuse coordinator generation tests, root00d37c exit0 và Sol review. Đây là lifecycle observer/component proof, không khẳng định OS process death. |
| MB-AUTH-008 | PASS | New composed case đưa HTTP200 thiếu token/thiếu expiresAt/sai limited type qua real adapter/parser→repository→host, không store/success, recovery rõ và exact1attempt sau explicit recovery. Root00d37c exit0/Sol accepted. |
| MB-AUTH-009 | PASS | Composed real-adapter limited case exact1HTTP creation/no profile/workspace/resource và zero additional attempts đã review. Native15/11 password/password-relogin actual API24, PROFILE_READ/OTHER0 ở boundary bắt buộc, original owner34939/f92a9d exit0 và fixture cleanup PASS. [Checkpoint15/11](FEAT-TN-001-remaining-checkpoint-2026-11-15.md). |
| MB-AUTH-010 | PASS | New two-page widget picker→selection denial xóa rows cũ/no summary, root00d37c/Sol component accepted. Server recheck có existing independent stale actual API24 owner81400/0cff6b exit0, suspend B→denial→refresh/openA cùng7orderedrequests. Provider signed cursor/version change guards có ledger riêng. §18.6 không yêu cầu ghép mọi oracle trong một lượt mới. |
| MB-AUTH-011 | PASS | Storage-error OR branch có new composed write-side-effect/error→locked recovery/exact candidate revoke, root00d37c exit0. Existing late login/write dispose/resume tests drain/revoke đúng in-memory candidate. Concurrent logout/account-switch lúc busy bị public API từ chối, không invent accepted boundary. Xem mapping/Sol review cho scope từng test. |

## 18.7 E2E và 19: AT/TS

| ID | Status | Bằng chứng và phần còn lại |
| --- | --- | --- |
| E2E-AUTH-001 | NOT_RUN | N shared Web/API24 cùng fixture, distinct sessions, memberships, logout hai chiều đã chạy; Android API24 full login/cold-resume/logout rerun15/11 là App đơn lẻ. Cần audit redaction gắn cùng Web/App run. |
| E2E-AUTH-002 | PASS | Sol high actual13/11 owner2389/ff62c1 exit0,177markers/164distinct. Revised `limited-resource-guard` kiểm `/devices`403/PASSWORD_CHANGE_REQUIRED và exact error-only envelope, details{}, canonical correlation UUID, không resource payload. Original fixture cleanup và extra8zero đạt. [I1 actual report](FEAT-TN-001-provider-i1-sol-actual-2026-11-13.md). |
| E2E-AUTH-003 | PARTIAL | Chrome thật ghi không device/resource request trước picker; Android API24 exact picker-boundary oracle PASS: login1/profile≥1/workspace-list1/OTHER0. Cần seed device rows khác nhau vào A/B để hoàn tất precondition và verify no-data behavior với resources thực. [Web](FEAT-TN-001-continuation-2026-11-15.md), [Android](FEAT-TN-001-android-api24-full-resume-2026-11-15.md). |
| E2E-AUTH-004 | PASS | P `disabled-{web,android}-{invalid,no-credential,no-issued-session}`; N/C disabled UI generic. |
| E2E-AUTH-005 | PASS | P 5 failures rồi 429/Retry-After; C real window timestamp và N real900s root/independent. |
| E2E-AUTH-006 | NOT_RUN | Android main actual response-loss18257/884869 exit0: upstream login200 commit rồi drop body, pending/quiet30s/no GET/autoPOST, explicit recovery+submit, picker→logout; exact2new sessions orphan1/revoked1, debug scan và cleanup đạt. Android API24 full/cold-resume/logout rerun15/11 không phải response-loss. Web cookie A/B/missing/reload/tab đã có lịch sử; full Chrome process reopen và delayed logout clear-cookie còn thiếu. [Checkpoint15/11](FEAT-TN-001-remaining-checkpoint-2026-11-15.md), [Android rerun](FEAT-TN-001-android-api24-full-resume-2026-11-15.md). |
| E2E-AUTH-007 | NOT_RUN | Root+independent và rerun API24 thật ngày15/11 đạt UI chọn B từ picker cũ sau suspend, khóa protected content, refresh còn A, mở A/logout; H2 detail404 không thay protected-resource HTTP/no-data oracle. Backend resource adapter còn phụ thuộc FEAT-WF010. [Rerun](FEAT-TN-001-continuation-2026-11-15.md). |
| E2E-AUTH-008 | NOT_RUN | Provider368 four-membership stale/restart PASS; Web production coordinator36test PASS; API24 actual UI rerun kiểm chọn B từ picker cũ sau suspend, khóa content, refresh chỉ A, mở A/logout. Chưa kiểm stale cursor qua page boundary/restart và account only-suspended, cũng chưa có protected-resource oracle. [Rerun](FEAT-TN-001-continuation-2026-11-15.md). |
| AT-WF-001-01 | PASS | N shared fixture Web/API24 distinct sessions cùng memberships, thực; scope actual riêng, audit-redaction yêu cầu bổ sung của E2E001 vẫn mở. |
| AT-WF-001-02 | PASS | P `limited-resource-guard` assert limited `/devices`403/PASSWORD_CHANGE_REQUIRED; E2E-AUTH-002 còn oracle payload riêng. |
| AT-WF-001-03 | PARTIAL | C/N picker A/B và exact Web+Android request oracle trước selection đã có; chưa seed device khác nhau ở A/B nên no-data precondition chưa được chạy. |
| TS-TN-001 | PASS | N shared Web/API24 active account, distinct sessions; emulator theo user override. |

## 19: acceptance bổ sung

| Điều kiện | Status / mapping |
| --- | --- |
| Wrong/unknown/disabled generic | PASS scoped provider — UT003/CT005/SEC001, exact public projection so trong cùng fixture. Timing SEC014 còn mở. |
| Rate 5/15 atomic, Retry-After client | PASS scoped — UT008/009, IT006, CT006, WEB004, E2E005; P concurrent và C/N thực. |
| Không tự cấp role/workspace/permission | PASS scoped host — UT010/SEC010, thêm fixture `CT-LOGIN-UNKNOWN-PERMISSIONS`; request bị handler từ chối trước pool lazy. |
| Web secret không JS; Android chỉ secure storage | NOT_RUN — P HttpOnly; N plugin thật, SEC003/008 forensic còn mở. |
| Không password/token/raw body trong logs/audit/metric/evidence | NOT_RUN — SEC002/003/009. |
| Không resource query trước selection | NOT_RUN — E2E003 request oracle đầy đủ. |
| Loading/error/rate/limited/empty/picker UI | NOT_RUN — C/N có nhiều state; cần ledger loading và mỗi state theo hai client khi áp dụng. |
| Cùng error/DTO semantics Web/Android | PASS scoped — Root15/11 actual full/limited/validation/auth/rate/service/context qua production parsers, shared26password/14email vectors. Xem closeout15/11. |
| Login/me/workspaces khớp OpenAPI header/type/required/pagination/error | NOT_RUN — CT001–016 và remaining variants. |
| Web limited confirmation/discovery; App không gọi `/me` | PASS scoped — CT014/WEB012/MB009 đã được đối chiếu actual/provider và consumer ledgers. App limited chỉPOSTlogin trước password-only theo composed test, không suy thêm native request quan sát chưa có. |
| Correlation/bounded labels/canary scan | NOT_RUN — SEC009. |
| Mỗi test có status và evidence | PASS cho **ledger audit này**, không phải mọi case PASS: từng ID trên có status và link/index; NOT_RUN chỉ rõ gaps. |

## 20: evidence bắt buộc

| Artifact | Status / điểm còn thiếu |
| --- | --- |
| OpenAPI/fixture version và compatibility | NOT_RUN — [password policy](FEAT-TN-001-password-policy-2026-10-26.md), H contracts; cần matrix version + provider→hai parsers CT013/015. |
| Backend unit/integration/contract/security reports | NOT_RUN — P/H có test thực/historical, nhiều ID trên chưa map đủ. |
| Web component/integration và accessibility | PASS scoped — H/C có host, Chrome keyboard/focus, AX/DOM labels/error association và contrast cho form đã kiểm. Không tuyên bố toàn bộ WCAG hoặc output bằng screen reader. |
| Flutter widget/integration Android | READY_FOR_QA —213host tests/analyzer0 trên source15/11, MB001–011 có mapping. Existing native actual giữ manifest riêng, forensic/response-loss variants còn theo SEC/E2E. |
| E2E trace correlationId, masked session IDs, client types/membership | NOT_RUN — N shared session/membership evidence; cần gắn correlation/audit redaction của đúng shared run. |
| Audit sample redacted | NOT_RUN — P audit counts và retained anonymous; cần sample theo đúng shared fixture với redaction được chứng minh. |
| Log scan không password/token/cookie | NOT_RUN — SEC009 named-field/canary toàn các sink được yêu cầu. |
| OQ-AUTH decisions và reviewer; contract versioned trước code | NOT_RUN — cần đối chiếu bản chốt/người duyệt/timestamps thực, không tự tạo chữ ký. |
| Provider serialization → Web parser → Android parser | PASS scoped — Actual provider274/258, Web7/Dart7 booleans gồm full/limited/error, root71887/1f85d9exit0 và8zero cleanup. Dùng replay network double từ response thật trong RAM, không tính thành native UI E2E. |
| Header, row/digest, cross-workspace guard | NOT_RUN — P `cookie-protected-exact-path`, `web-metadata-no-store`, `rate-limit-retry-after`, cursor/CSRF/context có phạm vi; IT001, SEC011/013 còn thiếu. |
| Screenshot/video bổ sung | PASS scoped — C screenshot hash được đọc; không thay API/test log hay chứng nhận screen-reader. |
| Build/environment/device/input/expected/actual/status/path/defect cho mỗi record | NOT_RUN — các report linked có provenance khác nhau; từng execution chưa được reconcile đủ mọi field, defect ID ghi none chỉ khi xác nhận. |

## Thứ tự việc còn lại, không rerun historical chỉ vì checkbox cũ

1. Reconcile test outputs/source cho từng UT/IT/CT/SEC NOT_RUN trên; nếu marker đúng assertion và đã chạy trên manifest phù hợp, cập nhật evidence mà không rerun. Ưu tiên P pagination/cursor, audit fault, commit ACK, user fence; một marker tên rộng không thay assertion. Sau đó chạy chỉ biến thể chưa có: malformed/extra body, email/password shared boundaries, limiter edge/proxy/expired session, security scan/correlation và known workspace B resource oracle.
2. Web: capture limited reload headers và no-marker recovery; có orchestration có kiểm chứng thì chạy từng cookie A/B/missing, late A, timeout, delayed logout clear-cookie, hai tab/reopen/storage failure. Capture method/status/context identity an toàn, no replay và UI/cache; không ghi cookie/token. WEB008 dựa trên AX/DOM và keyboard như ghi ở trên, không tự thêm gate cài phần mềm screen reader.
3. Android emulator: storage write/key-loss, late response sau logout/account switch/cache, background giữa bootstrap, limited exact request ledger, pagination/authz-change; không gọi native PoC hoặc host fake là actual. O4 offline đã root actual PASS trong scope, không bắt chạy lại chỉ do review cũ.
4. Reconcile shared-run audit/redaction/correlation và evidence manifest; request owner/QA decision riêng khi mọi acceptance được xác nhận. Không giả owner signature hoặc ghi whole feature complete từ bảng này.

## Bổ sung host input/contract — independent execution 13/11

Tester chạy trực tiếp bằng tool terminal; evidence là output/exit code trong phiên làm việc, không có log riêng hay DB/browser/device. Source hashes bên dưới được đọc **sau** lượt chạy; chúng không phải phép chụp atomic toàn bộ tree lúc compile. Không sửa source/test trong lượt bổ sung này. Dữ liệu đều synthetic. Không cài dependency và Cargo chạy offline.

| Lệnh | Kết quả thực tế |
| --- | --- |
| `cargo test --workspace --offline` trong `backend` | exit 0; 73 tests passed trong các test binary, không tính doc-tests 0. Có 4 `login_atomicity`, 12 domain unit, 4 `policies`, 1 password policy. |
| `cargo test --offline --features http-server --lib --test http_auth --test password_policy` trong `backend` | exit 0; 17 lib + 7 router HTTP + 1 password policy, có overlap với workspace, không cộng thành tests distinct. Pool trong `http_auth.rs` lazy, không kết nối PostgreSQL. |
| `python -X utf8 -B -m unittest discover -s contracts/tests -p '*.py' -v` từ root | exit 0; 39 tests. Đây là kiểm nội dung schema/fixture, không gọi provider. |
| `node --experimental-transform-types --test tests/auth.test.mjs tests/password_policy.test.mjs` trong `web` | exit 0; 26 tests, 0 failed/skipped. Node cảnh báo experimental type stripping. API và lock trong coordinator là fake; không phải browser. |

Mapping cụ thể, dùng cùng status tổng ở bảng trên:

| Plan ID | Test thực chạy và chính xác phạm vi |
| --- | --- |
| UT001/002, CT015 | Domain `input::tests::passwords_preserve_scalar_and_whitespace_boundaries` kiểm login 8/9/128/129, emoji, whitespace validation. `shared_password_policy_matches_each_boundary` chạy **17** vector `password-policy.json` cho login/current/new; `password policy matches shared cross-platform cases` chạy cùng 17 vector qua TypeScript; `test_shared_examples_cover_boundaries_composition_and_preservation` đối chiếu fixture độc lập. Có `EMPTY`, `CURRENT_ONLY`, `EIGHT`, `NINE`, `MAXIMUM`, `TOO_LONG`, missing composition, Unicode và emoji. `mobile/test/auth/password_policy_test.dart::password policy matches shared cross-platform cases` đọc cùng fixture nhưng Flutter không chạy trong lượt audit này. Root đã chạy regression password whitespace tới fake verify ở bảng dưới, nên UT001 PASS; UT002 và CT015 còn các phần normalization/Android runtime/email parity chưa map đủ. |
| UT010, SEC004/010 | `negative_shared_login_fixtures_match_http_provider` dùng handler thật và pool lazy: `CT-LOGIN-UNKNOWN-ROLE`, `-WORKSPACEID`, `-USERID`, `-PERMISSIONS` trả 422, `details` đúng root UNKNOWN_FIELD, không Set-Cookie. `test_client_authority_fields_have_root_unknown_field_errors` kiểm fixture. Root test mới kiểm `expiresAt` giả, không cookie/token. UT010 và SEC010 PASS trong scope host boundary; SEC004 còn known workspace B/provider scope. |
| UT011 | `input::tests::email_canonicalization_preserves_identity_parts` chứng minh ASCII trim/case, giữ `+tag`/dot, từ chối Unicode và format; `email_lengths_match_contract_boundaries` kiểm local64/65, total254/255. `test_email_canonicalization_and_length_examples_are_concrete` chỉ kiểm fixture. Không đủ chứng minh unique key + lookup của cùng account trong DB. |
| UT012 | `session_authorization_checks_current_authority_and_context_before_limited` cho expired đúng boundary và đổi account Disabled sau khi tạo session; guard domain trả `SessionInvalid`, không dựa claim. Đây là unit/fake snapshot, không tự đổi SEC005 runtime HTTP thành PASS. |
| UT013, CT003 | `negative_shared_login_fixtures_match_http_provider` kiểm missing/null/number của mỗi email/password/clientType, empty, malformed, array/null root, authority fields; exact status/`error.details`, Cache-Control no-store và không Set-Cookie. `malformed_and_typed_inputs_keep_contract_errors` kiểm duplicate400, password null422/path/code/correlation. `size_media_and_nested_duplicate_are_rejected_before_storage` kiểm 65537 bytes→413, text/plain→415, nested duplicate→400 cùng code. Chưa kiểm boolean ở mỗi field hoặc full response no-echo/no-session DB từng biến thể. |
| CT016 | `size_media_and_nested_duplicate_are_rejected_before_storage` kiểm size/MIME/nested duplicate; `negative_shared_login_fixtures_match_http_provider` kiểm unknown key; chưa scan toàn error body với attacker key/value canary. |
| SEC015 | `browser_cannot_bypass_origin_by_claiming_android` trả 403/no-store/no-cookie với attacker Origin; `ambiguous_transport_is_rejected_before_storage` trả 400/no-cookie cho mixed cookie/bearer. Thiếu WEB thiếu Origin/Referer và tất cả transport variants. |
| IT002/007/012 | Fake transaction `lost_commit_ack_returns_unknown_without_issuing_credential` giữ đúng một commit/session nhưng trả CommitUnknown; `success_audit_failure_rolls_back_session` giữ zero sessions/commits; `failure_audit_error_preserves_committed_counter` giữ counter/failure audit warning và InvalidCredentials. P là provider/DB evidence riêng; fake không chứng minh DB rollback hoặc exporter thực. |
| CT012 | Feature-gated `http::sessions::tests::pagination_query_has_explicit_shape_and_limits` kiểm parser query/limits; P có first page/no duplicate/forged/stale authority. Expiry, binding và no-omission tổng vẫn còn. |

Các hash SHA-256 sau lượt chạy:

```text
96CECFDFB5516C74A108E5CF145EDCCF7EEB3E39554BF001383F939330587A81 backend/crates/domain/src/input.rs
9FD934E41DCC28E6D923D70798A0B9225C20BED9537DCC624E15094744349BDE backend/crates/domain/tests/policies.rs
FCBCF904E28923EFB381DD060DD26048194BD2E1E52A13ACE138E65157D8416B backend/crates/application/tests/login_atomicity.rs
DD9EBBFDD54B25C7B7B2936D89A9184EF0577D92BA67AC0407F6BE121411B519 backend/tests/http_auth.rs
D324F4D32A991BC96197711CA4431D73A106FC0E994E231D31D622B83E9811AB backend/tests/password_policy.rs
2092E33A505F254E11E2266711226DE3DDAD71D9CBD6FAA6D3F320306AD767CB contracts/fixtures/auth/password-policy.json
9293D0ECAFD80D66B008E0B65A1484692A961E1BDC1B1F71FA8F79D3DAA87EC3 contracts/fixtures/auth/login-validation-scenarios.json
A8DC266F2F9E6A8B1120707976246233D74CFD25614187DD08764A08A5679DB5 contracts/tests/test_login_contract.py
E59649D51F8980B3258252D7CD388FE9A6CE54C086B33AF68C0376395BCC4710 contracts/tests/test_password_policy.py
CF9B09BC172B4514CFDC05F3ED5299D506B1144E51E02381125F65491D5BD083 web/tests/auth.test.mjs
345F33DE725EC5A2EA734709D718F7BB78446AFEDB5A7784EF3CECD7A1FBEAFB web/tests/password_policy.test.mjs
```

Sau khi các lệnh trên hoàn tất, tool tạo process liên tục báo `helper_unknown_error: setup refresh had errors`. Theo phân công, bổ sung hai test-only regression trong `backend/crates/application/tests/login_atomicity.rs` và `backend/tests/http_auth.rs`; root sẽ chạy và review. Các hash trong bảng là **trước** hai edit này, các kết quả host ở trên không chứng nhận test sau edit.

| Test mới | Status | Giới hạn |
| --- | --- | --- |
| `login_passes_password_whitespace_unchanged_to_verifier` | PASS — ROOT | Fake verifier chỉ đồng ý nếu nhận đúng password synthetic có whitespace, test kiểm login thành công và một session fake; không phải crypto adapter/DB thật. |
| `login_boolean_and_unknown_authority_fields_do_not_echo_input` | PASS — ROOT | Router + pool lazy: true/false từng field; extra `expiresAt` và unknown key; kiểm 422, path/code, không cookie/token, full error string không chứa email/password/key/value canary. |

Root báo đã format hai file và chạy serial owner `65327` / terminal `2c1e33` exit 0: `cargo test --offline -p iot-application --test login_atomicity` 5/5 và `cargo test --offline --features http-server --test http_auth` 8/8, bao gồm hai test mới. Đây là root execution report, independent reviewer không chạy lại vì process tool lỗi. Full workspace 73 test đã chạy trước edit, không chuyển thành full-suite sau edit. Hai hash sau được đọc lại sau format:

```text
D829C16D5DDA9B4A85CA956D94A30BECC8AA1131557C4FC3F7410F861A993B53 backend/crates/application/tests/login_atomicity.rs
DCC83D27E0304962C291829018C07045868A64E3D3B325F37FA883F45F494F07 backend/tests/http_auth.rs
```

Regression chỉ bổ sung test cho boundary có sẵn trong plan, không đổi production logic; provider session/DB và các variants còn thiếu vẫn giữ scope riêng.

## Review oracle provider error-only 13/11

Independent source review phát hiện revision đầu của oracle đòi `details=null`, trong khi adapter `HttpError::code` serialize `details={}`; root đã sửa oracle và fixture synthetic theo adapter trước khi chạy provider. Bản cuối kiểm đúng hai code denial, exact top-level/error keys, message chung cố định, details `{}` và correlation UUID canonical. Empty account dùng workspace ID đã đọc từ list/detail fixture, không dùng UUID ngẫu nhiên. Đây là kiểm error projection/no payload, chưa tự chứng minh thứ tự authorization trước database resource query.

Independent chạy `python -X utf8 -B -m unittest discover -s ops/auth -p test_provider_error_projection.py -v`, exit 0, 2 tests và 11 negative subcases. Test dùng synthetic JSON, không mở API/DB; actual provider và cleanup chờ root execution/receipt. Test hiện có positive `PASSWORD_CHANGE_REQUIRED` và negative mismatch `RESOURCE_NOT_FOUND`; chưa có positive riêng `RESOURCE_NOT_FOUND`, dù predicate nhận đúng hai code theo source. Hash sau review: `ops/auth/verify_provider.py` SHA-256 `E7CAE2C224EC21BDA6D34709F956A7AAC4EC55D29DD67A5BAC53006CDA9F0EAF`, `ops/auth/test_provider_error_projection.py` SHA-256 `8F2429B4275054FFE6B9A72AFDA18883DB04A44895617B0E224B4B1EF3CFEBAA`.

## Bổ sung evidence 15/11 — backend output capture

Lượt PostgreSQL thật sau này dùng `python -B ops/auth/run_local.py --verify`, exit0, **370 check markers/333 ID khác nhau**; report [provider-latest.json](../../ops/auth/evidence/provider-latest.json) có `fixtureCleanup=APPLICATION_ROWS_REMOVED`. Stdout của process primary và peer đều `PASS` (15 byte, 166 canary, 0 canary/named-field match). Hai stderr rỗng và structured log được ghi `NOT_RUN`; không suy silence thành structured-log PASS. Sau đó chạy `python -B -m unittest discover -s ops/auth/tests -q`, **133 PASS**. GPT-6.1 Sol high review phát hiện structured event secret có thể tạo verdict mâu thuẫn; đã sửa, thêm regression và final review không còn P0/P1/Important trong scope capture. Chi tiết/hashes: [backend output capture report](FEAT-TN-001-backend-output-capture-2026-11-15.md).

Bổ sung này không đổi các status `NOT_RUN`: remote exporter fault, structured log sink, browser debug, các race Chrome/E2E tổ hợp và owner acceptance vẫn thiếu evidence theo từng dòng. Toàn feature giữ `VERIFY_IN_PROGRESS`.
