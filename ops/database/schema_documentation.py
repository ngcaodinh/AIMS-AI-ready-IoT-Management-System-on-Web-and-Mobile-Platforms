"""Từ điển công dụng bảng/cột; chỉ mô tả schema, không chứa dữ liệu hay cấu hình bí mật."""

import json
import re
import textwrap

# Mô tả grain, trách nhiệm và lý do tách bảng để người đọc hiểu luồng nghiệp vụ.
TABLE_DESCRIPTIONS = {
    'audit_retention_batches': 'Kết quả immutable của từng batch audit purge, commit cùng DELETE audit; batch ID là khóa replay để retry không xóa thêm hoặc trả count giả. Không chứa nội dung audit đã xóa.',
    'audit_retention_runs': 'Run nội bộ của audit retention; mỗi run giữ cutoff UTC đã đóng để restart/retry không làm thay đổi phạm vi xóa. Không chứa audit payload hoặc quyền của user request.',
    "users": "Danh tính tài khoản dùng chung toàn hệ thống: lưu email đăng nhập, bộ kiểm chứng mật khẩu và trạng thái kích hoạt. Vai trò theo workspace nằm ở memberships, không gắn vai trò toàn cục vào tài khoản.",
    "user_preferences": "Tùy chọn hiển thị của từng tài khoản, hiện gồm múi giờ. Tách khỏi hồ sơ xác thực để đổi giao diện không làm thay đổi thông tin đăng nhập.",
    "sessions": "Mỗi hàng là một phiên đăng nhập Web hoặc Android, có chế độ full/limited và hạn 24 giờ. Lưu digest để xác minh, thu hồi phiên; không lưu raw session token.",
    "login_attempt_buckets": "Bộ đếm đăng nhập sai theo digest email chuẩn hóa. Ghi mốc cửa sổ thất bại để backend thực thi giới hạn đăng nhập đồng nhất giữa các tiến trình.",
    "password_change_attempt_buckets": "Bộ đếm sai currentPassword riêng theo User ID; PostgreSQL khóa nguyên tử để chia sẻ giới hạn đổi mật khẩu giữa session và instance.",
    "workspaces": "Đơn vị cô lập dữ liệu và quyền của dự án. Quản lý tên, múi giờ mặc định, trạng thái hoạt động và phiên bản quyền; mọi tài nguyên nghiệp vụ đều thuộc một workspace.",
    "memberships": "Quan hệ hiện hành giữa tài khoản và workspace: vai trò ADMIN/USER, trạng thái và grant đang sử dụng. Đây là nguồn xác định tư cách thành viên, không sao chép vai trò vào từng thiết bị.",
    "membership_grants": "Lịch sử từng lần cấp quyền thành viên. Giữ identity theo generation để lời mời, API key hoặc tác vụ dùng grant cũ không tự có quyền lại khi tài khoản tham gia lại.",
    "membership_admission_fences": "Điểm tuần tự hóa nhận thành viên theo workspace và digest email, kể cả khi chưa có tài khoản. Generation hiện hành giúp vô hiệu hóa lời mời hoặc admission cũ.",
    "workspace_invitations": "Lời mời tham gia workspace, chụp vai trò, người mời và generation quyền tại lúc phát hành. Digest token, hạn 24 giờ và mốc sử dụng/thu hồi phục vụ nhận lời mời một lần.",
    "password_reset_admissions": "Nhật ký những lần reset mật khẩu đã được nhận xử lý thành công theo actor/target/workspace. Phục vụ đếm ngân sách reset và truy vết; không lưu mật khẩu tạm.",
    "workspace_runtime_quotas": "Projection đếm execution đang chiếm quota và hàng điều phối quota workspace. Counter phải được đối soát từ rule_executions; không thay thế lịch sử thực thi.",
    "websocket_tickets": "Vé kết nối realtime dùng một lần, gắn với session, workspace và generation quyền. Backend consume có điều kiện rồi mới mở kênh; không lưu raw ticket.",
    "audit_events": "Nhật ký kiểm toán ai làm gì, ở đâu và kết quả ra sao. Hỗ trợ sự kiện IAM toàn cục với workspace NULL, giữ tương quan request; chỉ lưu phần thay đổi đã loại bỏ dữ liệu nhạy cảm.",
    "templates": "Gốc quản lý template thiết bị và metadata bản nháp như tên/model. Không dùng bản nháp làm schema runtime; thiết bị phải pin vào một template_versions đã công bố.",
    "template_draft_streams": "Các kênh dữ liệu đang chỉnh sửa của một template, gồm datatype, chiều đọc/ghi và giới hạn. Cho phép editor sửa draft trước khi tạo snapshot phiên bản.",
    "template_draft_enum_values": "Tập literal được phép của một kênh ENUM trong bản nháp. Tách thành relation để kiểm trùng giá trị, không lưu danh sách giá trị dạng chuỗi CSV.",
    "template_draft_capabilities": "Capability điều khiển và safeValue của từng kênh bản nháp. Mô tả khả năng SET_VALUE để validator kiểm type/range trước khi publish.",
    "template_versions": "Ảnh chụp schema và metadata template tại mỗi lần publish. Là phiên bản được thiết bị tham chiếu cố định để thay đổi draft không làm lệch schema của thiết bị đang chạy.",
    "datastream_definitions": "Định nghĩa từng kênh trong template version đã công bố. Là nguồn datatype, mode, đơn vị và giới hạn để kiểm telemetry, binding và giá trị điều khiển theo đúng pin của thiết bị.",
    "datastream_enum_values": "Các literal ENUM thuộc một kênh của template version đã công bố. Giữ tập giá trị theo phiên bản để dữ liệu cũ không phụ thuộc draft hiện hành.",
    "datastream_capabilities": "Capability SET_VALUE cùng safeValue của kênh đã công bố. Cho phép kiểm kênh có thể điều khiển, thay vì suy từ việc stream tồn tại.",
    "devices": "Registry thiết bị: identity MQTT toàn cục, serial, workspace, owner và template version đã pin. Quản lý lifecycle/metadata; trạng thái kết nối và bộ đếm runtime tách sang device_runtime.",
    "device_runtime": "Trạng thái vận hành thay đổi thường xuyên của thiết bị: presence, boot hiện hành, bộ đếm ingest và epoch bảo trì. Tách khỏi metadata để telemetry không làm tăng revision chỉnh sửa thiết bị.",
    "device_credentials": "Các generation credential MQTT của thiết bị và trạng thái cấp/thu hồi. Chỉ lưu bộ kiểm chứng, không giữ raw credential để đọc lại.",
    "device_boot_sessions": "Mỗi lần khởi động/kết nối thiết bị đã được backend xác minh. Gắn boot với credential và connection generation, lưu frontier sequence để phân biệt replay với dữ liệu của boot mới.",
    "provisioning_operations": "Ý định cấp credential và tiến trình bàn giao một lần qua USB/BLE. Tách kết quả cấu hình broker khỏi trạng thái phát secret; escrow chỉ là ciphertext tạm có key reference và hạn riêng.",
    "device_operations": "Ý định lifecycle thiết bị như suspend/resume/archive/revoke. Giữ trạng thái đối soát cùng receipt broker/disconnect để không báo hoàn tất khi side effect chưa được xác nhận.",
    "connectivity_transitions": "Nhật ký từng chuyển trạng thái kết nối thực sự của thiết bị. Sequence ổn định giúp rule và webhook chống tạo sự kiện trùng từ heartbeat hoặc hello lặp.",
    "telemetry_receipts": "Ledger định danh và digest của envelope đã nhận thành công. Tồn tại độc lập raw telemetry để retry không tái tạo dữ liệu sau khi raw bị purge.",
    "telemetry_envelopes": "Một gói telemetry đã nhận, chứa thời gian/provenance chung và số point dự kiến. Liên kết receipt với các point để ghi toàn gói hoặc rollback toàn gói.",
    "telemetry_points": "Các mẫu typed trong một envelope, mỗi stream xuất hiện tối đa một lần. Device và thời gian được lặp có chủ đích cho query lịch sử, phải khớp authority ở envelope.",
    "device_latest_values": "Projection mẫu mới nhất của từng kênh phục vụ giao diện và rule. Giữ marker đủ điều kiện riêng để mẫu NULL/stale mới không bị thay bằng GOOD cũ khi điều khiển.",
    "actuator_states": "Trạng thái một kênh điều khiển của thiết bị, gồm manual epoch và giá trị được thiết bị báo. Có thể giữ command chưa đối soát; không coi giá trị người dùng yêu cầu là reported truth.",
    "commands": "Ledger mỗi lần nhận yêu cầu điều khiển: nguồn lệnh, giá trị đích, deadline và kết quả vật lý. Tách admission/dispatch khỏi terminal outcome; UNKNOWN không được biến thành thành công chỉ vì có ACK thủ công.",
    "command_result_receipts": "Kết quả MQTT từng phase của command đã được xác minh theo device/boot/credential. Khóa phase và digest phục vụ nhận trùng, không ghi đè kết quả đã chấp nhận.",
    "command_evidence": "Bằng chứng quan sát muộn hoặc mâu thuẫn của command. Ghi bổ sung vào timeline thay vì sửa terminal outcome hoặc tự phát lại thao tác vật lý.",
    "command_resolutions": "Trục xử lý/đối soát command UNKNOWN: ghi nhận ACK thủ công hoặc bằng chứng thiết bị muộn. Không đồng nhất resolution với kết quả thực thi ban đầu.",
    "dashboards": "Gốc dashboard do một thành viên sở hữu, chứa tên, trạng thái và revision. Các widget/binding là dữ liệu con để lưu một cấu hình nguyên tử qua CAS.",
    "dashboard_widgets": "Từng widget trong dashboard: loại hiển thị/điều khiển, thứ tự trên mobile và bố cục grid. Presentation giữ cấu hình của loại widget, không là nơi lưu credential hoặc script tùy ý.",
    "dashboard_widget_bindings": "Liên kết từng slot widget với thiết bị và kênh đã pin. Presence binding có thể không có stream; FK và shape bảo vệ tham chiếu trong đúng workspace/version.",
    "rules": "Gốc rule thuộc một owner: metadata, trạng thái bật/tắt, revision draft và con trỏ phiên bản đang dùng. Draft và version runtime được tách để chỉnh sửa không thay execution đang chạy.",
    "rule_drafts": "Nội dung rule hiện đang soạn: trigger, AST điều kiện và policy. Chưa là định nghĩa được thực thi cho đến khi được validate và publish.",
    "rule_draft_actions": "Chuỗi action của rule draft theo thứ tự, với các nhánh SET_VALUE/WAIT/NOTIFY được biểu diễn typed. Lưu cấu hình hành động, không lưu kết quả chạy.",
    "rule_draft_references": "Các tham chiếu resource trích từ AST/trigger/action của draft, định danh theo đường dẫn trong tài liệu. FK bảo vệ scope/pin; validator còn phải kiểm đủ và khớp hai chiều với AST.",
    "rule_versions": "Ảnh chụp rule tại một lần publish, gồm điều kiện, trigger và policy. Execution tham chiếu phiên bản này để restart hoặc chỉnh draft không đổi định nghĩa lịch sử.",
    "rule_version_actions": "Chuỗi action thuộc rule version đã công bố. Dùng cùng action_position trong execution để xác định chính xác hành động nào được chạy.",
    "rule_version_references": "Các tham chiếu thiết bị/kênh theo đường dẫn trong rule version đã công bố. Giữ quan hệ typed và pinned, không thay thế kiểm tra AST/reference completeness của validator.",
    "rule_runtime": "Trạng thái điều phối rule đang chạy như active generation và cooldown. Lưu bền vững để restart không xóa khoảng nghỉ hoặc dùng lại thế hệ runtime cũ.",
    "rule_trigger_states": "Trạng thái episode/hold của trigger trong một rule version. Giữ mốc fresh, armed và sequence để tránh fire lặp hoặc cộng hold từ dữ liệu stale.",
    "rule_executions": "Mỗi lần quyết định/chạy một rule version với trigger identity ổn định và deadline 15 phút. Là ledger runtime cho quota, tiến độ và outcome, tách khỏi payload lịch sử lớn.",
    "rule_execution_snapshots": "Payload giải thích execution: input, condition trace và snapshot định nghĩa. Lưu sự thật tại lúc đánh giá để người dùng đọc lịch sử mà không live-join vào draft đã đổi.",
    "execution_actuator_snapshots": "Manual epoch của từng actuator tại đầu execution. Giữ snapshot trước WAIT để automation phát hiện người dùng đã điều khiển thủ công và không ghi đè thao tác mới.",
    "action_executions": "Trạng thái từng action trong một execution, gắn đúng rule version và action_position. Giữ command backlink và lý do kết thúc để coordinator quyết định bước kế.",
    "action_jobs": "Công việc bền vững tương ứng từng action, gồm dueAt, lease và retry counter. WAIT dùng thời điểm tuyệt đối trong DB; worker không giữ timer RAM làm nguồn sự thật.",
    "schedule_occurrences": "Mỗi lần lịch được định danh ổn định theo rule version và occurrence key. Giữ thời gian/timezone snapshot cùng kết quả admission để tránh chạy trùng sau restart/DST.",
    "rule_trigger_receipts": "Quyết định đã xử lý một trigger identity: nhận chạy, không khớp hoặc bị chặn. Giữ receipt chống replay ngay cả khi payload history execution được purge.",
    "events": "Sự kiện nghiệp vụ theo nguồn device/rule và episode, có mức độ cùng vòng đời đọc/xác nhận/resolve. Một Event có thể tạo nhiều occurrence và inbox cho từng recipient.",
    "event_occurrences": "Journal từng transition đã commit của Event, command hoặc connectivity. Identity occurrence dùng cho webhook, khác Event nghiệp vụ; nhánh typed/XOR tránh tạo Event giả.",
    "notifications": "Một mục inbox của một recipient, phân biệt EVENT và PUSH_TEST. Read state thuộc recipient; target typed giữ đích deep link mà không cấp quyền đọc vượt scope hiện hành.",
    "workspace_operations": "Ý định lifecycle toàn workspace và trạng thái đối soát. Một operation chưa settled giữ fence cho đến khi các thiết bị liên quan có đủ kết quả cleanup.",
    "workspace_operation_devices": "Snapshot tập thiết bị tham gia workspace operation cùng tiến độ mỗi thiết bị. Liên kết đúng device_operation trên cùng device, không chỉ cùng tenant.",
    "global_idempotency_records": "Biên nhận chống lặp cho request global theo tài khoản/route/key digest, không gắn workspace đang chọn. Chỉ giữ kết quả đã loại secret trong cửa sổ replay 24 giờ.",
    "workspace_idempotency_records": "Biên nhận chống lặp cho request trong workspace theo principal user/API key. Digest body dùng phát hiện cùng key khác nội dung; không đưa body hash vào khóa dedupe.",
    "outbox_events": "Sự kiện nội bộ được producer ghi cùng transaction nghiệp vụ. Payload/version và event key ổn định cho các consumer xử lý sau commit, không thay network bằng transaction dài.",
    "outbox_consumptions": "Trạng thái xử lý riêng của từng consumer đối với một outbox event. Lease generation và complete CAS ngăn worker cũ settle công việc sau khi bị takeover.",
    "rate_limit_admissions": "Nhật ký admission đã tính ngân sách theo policy và principal typed. Dùng đếm rate giữa nhiều backend; login bucket và password-reset admission có ledger chuyên biệt riêng.",
    "push_installations": "Một cài đặt Android với proof, provider token mã hóa và binding user/session hiện hành. Generation/sequence phục vụ rebind, token rotate và tránh cleanup phiên cũ làm mất binding mới.",
    "workspace_notification_preferences": "Tùy chọn nhận push theo user/workspace, tách khỏi permission hệ điều hành của installation. Hàng vắng mang default theo contract; lưu lần đầu bắt đầu revision 1.",
    "push_deliveries": "Nghĩa vụ giao một notification tới một installation tại fanout snapshot. Dedupe không chứa binding generation; rebind không tạo thêm delivery cho cùng notification/installation.",
    "push_delivery_attempts": "Ý định gửi push từng lần, tiêu hao ngân sách trước network call. Lưu token generation và outcome quan sát; provider ACCEPTED không có nghĩa người dùng đã đọc.",
    "enrollment_sessions": "Ý định onboarding/đổi Wi-Fi gắn device, actor grant, installation và proof, hạn 10 phút. Không lưu PoP/SSID/mật khẩu Wi-Fi và không phụ thuộc quyền nhận push.",
    "enrollment_cleanup_operations": "Công việc cleanup enrollment cùng bằng chứng revoke/disconnect. Tách khỏi TTL của phiên để expiry không bị hiểu nhầm là cloud cleanup đã hoàn tất.",
    "device_enrollment_guards": "Khóa nghiệp vụ giữ một thiết bị cho enrollment đang chưa giải quyết. Guard chỉ được nhả khi hoàn tất hoặc cleanup có proof, không chỉ vì session đã hết hạn.",
    "firmware_upload_attempts": "Mỗi lần upload/verify firmware, kể cả lần lỗi. Tách khỏi canonical package để chữ ký sai đầu tiên không chiếm identity digest của artifact hợp lệ.",
    "firmware_packages": "Metadata package firmware đã được validator xác minh, giữ exact signed manifest bytes và chữ ký. Binary nằm ở artifact store; nhãn VERIFIED trong SQL không tự thực hiện kiểm chữ ký.",
    "firmware_package_templates": "Tập template version được package khai tương thích trong signed manifest. Giữ FK tới version cụ thể, không suy compatibility từ tên hoặc template root.",
    "ota_jobs": "Ý định OTA một thiết bị, chụp firmware nguồn/đích, nonce và maintenance epoch. RECOVERY_REQUIRED tiếp tục giữ slot cho tới settlement có đối soát; timeout không là proof rollback.",
    "ota_download_tickets": "Bearer ticket tải artifact cho một OTA job. Lưu digest và expiry không vượt deadline job; không coi ticket là device proof-of-possession.",
    "ota_status_receipts": "Status OTA được xác thực theo job/device/boot/credential và sequence. Digest phục vụ dedupe hoặc phát hiện cùng sequence khác body, không ghi đè status đã nhận.",
    "ota_probe_intents": "Ngân sách probe bền vững theo job/recovery epoch. Mỗi ý định probe có request identity để restart không reset budget hoặc tự phát lại START OTA.",
    "api_keys": "Principal API key có lookup ID toàn cục nhưng quyền chỉ trong một workspace. Chụp grant của owner, lưu protected verifier/expiry/revocation; không lưu raw secret để đọc lại.",
    "api_key_devices": "Allowlist thiết bị được API key cấp quyền, tối đa 5 theo admission policy. Đây là tập độc lập với scopes, không lưu tích Descartes device×permission.",
    "api_key_scopes": "Các permission được cấp cho API key theo allowlist scope code. Không suy thêm quyền quản trị từ scope đọc telemetry hoặc điều khiển thiết bị.",
    "webhook_subscriptions": "Cấu hình đích webhook, owner, trạng thái endpoint verification và active secret version. Revision endpoint khác secret version để đổi URL không được hưởng kết quả verify của URL cũ.",
    "webhook_subscription_devices": "Bộ lọc thiết bị của webhook subscription trong cùng workspace. Quyền hiện hành vẫn phải được kiểm tại fanout/send, không chỉ dựa vào FK tồn tại.",
    "webhook_subscription_events": "Các loại BUSINESS event mà subscription muốn nhận. Tách relation có CHECK allowlist, không lưu mảng chuỗi làm nguồn quyền/fanout.",
    "webhook_secret_versions": "Từng generation secret ký webhook, lưu ciphertext và wrapping key reference. Giữ version còn được delivery tham chiếu; metadata có thể tồn tại sau khi ciphertext được purge theo policy.",
    "webhook_deliveries": "Nghĩa vụ giao occurrence tới subscription hoặc một lần TEST, với exact body/endpoint/secret snapshot. Retry dùng cùng delivery identity và body, không dựng lại payload từ dữ liệu hiện tại.",
    "webhook_delivery_attempts": "Ý định HTTP outbound mỗi lần gửi delivery, với batch và outcome đã loại dữ liệu nhạy cảm. Ngân sách BUSINESS 6 tự động + một batch 6 thủ công, TEST chỉ một attempt.",
    "migration_control.applied_migrations": "Lịch sử phiên bản migration và SHA-256 source đã áp trong database này. Runner ghi cùng transaction DDL để chạy lại an toàn và từ chối checksum drift; không phải dữ liệu nghiệp vụ.",
}

# Những trường cùng nghĩa được dùng chung mô tả; trường đa nghĩa có override theo từng bảng.
COLUMN_DESCRIPTIONS = {
    "publication_transaction_id": "XID 64 bit của transaction tạo parent; gán bởi trigger, bất biến khi UPDATE, hỗ trợ SAVEPOINT. NULL ở parent lịch sử nghĩa đã chốt, không được thêm child.",
    "publication_cluster_id": "Identity cluster PostgreSQL tạo publication marker; kết hợp XID ngăn authority giả khi logical restore sang cluster khác. NULL ở parent lịch sử đã chốt.",
    "workspace_id": "Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.",
    "user_id": "Identity tài khoản liên quan; khi đi cùng workspace_id phải tham chiếu đúng membership của workspace.",
    "device_id": "Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng tenant.",
    "owner_user_id": "Tài khoản sở hữu tài nguyên trong workspace; backend phải kiểm membership và quyền hiện hành khi đọc/ghi.",
    "actor_user_id": "Tài khoản thực hiện hoặc khởi tạo thao tác, phục vụ kiểm quyền và truy vết; không lấy authority chỉ từ ID client gửi.",
    "created_by_user_id": "Tài khoản tạo tài nguyên; giữ provenance và làm anchor quota hoặc FK thành viên theo loại tài nguyên.",
    "requested_by_user_id": "Thành viên yêu cầu lifecycle operation; dùng truy vết người khởi tạo, không thay kiểm quyền hiện hành khi worker thực thi.",
    "recipient_user_id": "Thành viên nhận inbox/push; chỉ chính recipient được hưởng quyền đọc và thay đổi read state của inbox.",
    "target_user_id": "Tài khoản đích của thao tác quản trị trong workspace, phân biệt với actor thực hiện thao tác.",
    "resolved_by_user_id": "Thành viên thực hiện đối soát hoặc xác nhận thủ công; NULL khi chưa có người xử lý theo nhánh resolution.",
    "acknowledged_by_user_id": "Thành viên đã xác nhận Event; đi cùng acknowledged_at để lưu người và thời điểm ACK.",
    "issued_by_user_id": "Thành viên phát hành lời mời; issuer grant/version được chụp riêng để lần consume kiểm lại quyền.",
    "published_by_user_id": "Thành viên thực hiện publish template version, giữ provenance của snapshot đã công bố.",
    "session_id": "Identity một phiên đăng nhập; dùng gắn thao tác hoặc ticket với đúng principal, không phải raw token xác thực.",
    "auth_context_id": "Identity ngữ cảnh xác thực của phiên theo auth contract, dùng phân biệt các lần admission và đối chiếu client.",
    "limited": "True nếu phiên bị giới hạn vì cần đổi mật khẩu; không được đổi thành full tại chỗ, phải cấp phiên mới theo contract.",
    "client_type": "Loại client khởi tạo phiên/thao tác; enum của từng bảng phân biệt WEB, ANDROID, IOS và UNKNOWN khi được phép.",
    "email_normalized": "Email đã được lớp xác thực chuẩn hóa, dùng lookup tài khoản/lời mời; quy tắc chuẩn hóa phải thống nhất trước ghi.",
    "email_digest": "Digest 32 byte của email chuẩn hóa để lập bucket/fence mà không dùng raw email làm khóa vận hành; policy key version thuộc custody.",
    "password_hash": "Bộ kiểm chứng mật khẩu theo encoding của password hasher; không chứa mật khẩu gốc và không trả về client/log.",
    "account_status": "Trạng thái tài khoản toàn cục ACTIVE/DISABLED; khác trạng thái membership trong một workspace.",
    "must_change_password": "Đánh dấu tài khoản phải đổi mật khẩu trước thao tác thông thường; backend dùng để hạn chế admission và session.",
    "activated_at": "Thời điểm xác nhận tài khoản đã kích hoạt; NULL không được tự suy thành tài khoản tạm nếu provenance là legacy/unknown.",
    "activation_provenance": "Nguồn/bằng chứng hình thành trạng thái kích hoạt, giúp phân biệt account tạm mới với dữ liệu legacy chưa rõ lịch sử.",
    "name": "Tên hiển thị do người dùng đặt cho tài nguyên; không dùng làm identity, quyền hoặc khóa chống lặp.",
    "title": "Tiêu đề hiển thị của dashboard hoặc sự kiện; là nội dung giao diện, không dùng thay identity tài nguyên.",
    "description": "Mô tả bổ sung để người dùng hiểu tài nguyên; NULL nghĩa chưa cung cấp mô tả, không mang authority vận hành.",
    "alias": "Tên gọi của tài khoản trong workspace này, độc lập email đăng nhập hoặc tên trong workspace khác.",
    "display_name": "Nhãn hiển thị của kênh dữ liệu; stream_key vẫn là khóa kỹ thuật ổn định khi nhãn thay đổi.",
    "model": "Mã model phần cứng/template theo registry đã duyệt, dùng kiểm tương thích; không suy model từ tên hiển thị.",
    "board_model": "Model board được signed manifest khai hỗ trợ; validator đối chiếu với device trước OTA.",
    "hardware_revision": "Revision phần cứng để kiểm đúng biến thể board/firmware, khác firmware_version và revision chỉnh sửa metadata.",
    "firmware_version": "Phiên bản firmware được thiết bị báo hoặc manifest khai; không tự chứng minh artifact đã được xác minh/chạy khỏe.",
    "firmware_digest": "SHA-256 32 byte của image firmware được xác thực từ thiết bị; NULL khi chưa có identity image đáng tin cậy.",
    "serial_number": "Serial phần cứng duy nhất toàn cục, phân biệt hoa/thường theo contract registry; dùng lookup đăng ký/onboarding.",
    "revision": "Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng transaction contract.",
    "draft_revision": "Phiên bản chỉnh sửa của draft rule, tách khỏi revision metadata root và version_number của snapshot đã publish.",
    "authorization_version": "Mốc phiên bản quyền hiện hành; bên ghi phải tăng khi quyền thay đổi để ticket/job/cache phát hiện ngữ cảnh quyền cũ.",
    "created_at": "Thời điểm tạo bản ghi dưới dạng timestamptz; dùng provenance/sắp xếp hoặc retention khi policy của bảng quy định.",
    "updated_at": "Thời điểm cập nhật gần nhất do đường ghi quản lý; không mặc định SQL tự cập nhật nếu không có trigger tương ứng.",
    "issued_at": "Thời điểm phát hành phiên/grant/credential/ticket, làm gốc tính TTL theo loại bản ghi.",
    "expires_at": "Deadline hết hiệu lực, được lưu bền vững theo policy từng bảng; hết hạn không đồng nghĩa được xóa ngay nếu còn lịch sử/ref/cleanup.",
    "revoked_at": "Thời điểm thu hồi quyền/credential; NULL nghĩa chưa ghi nhận thu hồi, không đồng nghĩa mọi điều kiện xác thực khác còn hợp lệ.",
    "archived_at": "Thời điểm workspace được archive; phải đi cùng trạng thái ARCHIVED, không phải lệnh hard-delete dữ liệu.",
    "joined_at": "Thời điểm hình thành membership; lịch sử cấp quyền từng lần được giữ ở membership_grants.",
    "removed_at": "Thời điểm membership bị remove; NULL khi chưa ghi nhận remove, không thay điều kiện status/current grant.",
    "used_at": "Thời điểm lời mời được tiêu thụ; một khi đã ghi không được xóa mốc để sử dụng lại token.",
    "expired_at": "Thời điểm backend đã đánh dấu lời mời hết hạn để giải phóng pending slot; khác expires_at là deadline gốc.",
    "consumed_at": "Thời điểm vé một lần đã được consume thành công; CAS và mốc một chiều ngăn dùng lại cùng ticket.",
    "claimed_at": "Thời điểm server tiêu thụ quyền phát credential một lần; không chứng minh client/board đã nhận được secret.",
    "published_at": "Thời điểm tạo snapshot đã công bố; không thay đổi theo các lần sửa draft sau đó.",
    "started_at": "Thời điểm bắt đầu boot/enrollment/action hoặc hoạt động tương ứng, tùy ngữ nghĩa bảng.",
    "ended_at": "Thời điểm execution/action kết thúc; NULL khi chưa ghi nhận kết thúc, outcome/state là trục kết quả riêng.",
    "completed_at": "Thời điểm tác vụ hoặc enrollment được ghi nhận hoàn tất theo điều kiện của bảng; không lấy timer client làm bằng chứng.",
    "settled_at": "Thời điểm nghĩa vụ vận hành được đối soát xong và có thể nhả guard/quota; NULL tiếp tục giữ nghĩa vụ chưa giải quyết.",
    "terminal_at": "Thời điểm quan sát trạng thái kết thúc của command/delivery; không thay gốc expiry hoặc gốc retention.",
    "observed_at": "Thời điểm quan sát được dữ liệu/kết quả; nguồn và ý nghĩa được quy định theo bảng, không mặc định là thời gian commit.",
    "occurred_at": "Thời điểm nghiệp vụ/sự kiện diễn ra để sắp xếp timeline; không mặc định bằng thời điểm fanout hoặc provider phản hồi.",
    "received_at": "Thời điểm server nhận gói dữ liệu/kết quả; phân biệt với observed_at do thiết bị hoặc nguồn sự kiện cung cấp.",
    "first_received_at": "Thời điểm server chấp nhận lần đầu message identity, giữ nguyên khi retry và làm authority cho envelope received_at.",
    "committed_at": "Mốc thời gian producer ghi cho occurrence trong transaction đã commit thành công; không phải physical commit timestamp biết trước commit.",
    "intent_at": "Thời điểm lưu ý định trước side effect bên ngoài DB; dùng tính ngân sách/expiry và phục hồi khi mất ACK.",
    "intended_at": "Thời điểm ghi ý định probe OTA trước network call, dùng giữ budget bền vững qua restart.",
    "admitted_at": "Thời điểm yêu cầu được backend nhận vào ledger sau kiểm điều kiện; không chứng minh side effect đã thực hiện.",
    "deadline_at": "Hạn cuối của command/execution/OTA; restart, WAIT hoặc retry không được tự kéo dài deadline gốc.",
    "due_at": "Thời điểm tuyệt đối UTC mà job/lượt WAIT được phép đến hạn; timer RAM chỉ đánh thức worker, không thay mốc này.",
    "available_at": "Thời điểm sớm nhất consumer được claim công việc, phục vụ pending/retry schedule bền vững.",
    "next_attempt_at": "Thời điểm sớm nhất được thử gửi tiếp; không được gửi sớm hơn mốc này hoặc vượt expiry/budget của parent.",
    "lease_until": "Hạn thuê xử lý hiện hành của worker; lease hết không chứng minh network side effect chưa xảy ra.",
    "lease_generation": "Thế hệ lease tăng khi claim/takeover, dùng CAS để worker cũ không settle kết quả của thế hệ mới.",
    "attempt_count": "Số lần xử lý/claim đã tiêu hao theo pipeline; không tự coi một lần retry là một ý định nghiệp vụ mới.",
    "attempt_number": "Số thứ tự send intent của một delivery, bắt đầu 1; PK và admission guard bảo vệ thứ tự/ngân sách.",
    "batch_number": "Đợt webhook: 0 là tự động, 1 là đợt retry thủ công duy nhất; không tạo body/delivery identity mới.",
    "manual_batch_count": "Số đợt retry thủ công webhook đã mở, chỉ 0 hoặc 1; TEST không có manual batch.",
    "next_delay_seconds": "Khoảng chờ retry tiếp theo tính bằng giây đã được adapter/policy chọn; không phải timestamp tuyệt đối.",
    "role": "Vai trò thành viên ADMIN/USER trong workspace, không là quyền quản trị toàn bộ hệ thống.",
    "status": "Trạng thái nghiệp vụ của tài nguyên; ý nghĩa cụ thể và tập giá trị được nêu theo từng bảng.",
    "state": "Trạng thái xử lý bền vững của ledger/job/operation; không suy rằng enum hợp lệ tự chứng minh transition hợp lệ.",
    "lifecycle_status": "Trạng thái vòng đời quản lý tài nguyên, tách khỏi presence hoặc tiến độ của job đang chạy.",
    "outcome": "Kết quả quan sát/thi hành của thao tác, phân biệt với state điều phối và mức độ chắc chắn về side effect.",
    "kind": "Phân loại nghĩa vụ/thông báo để chọn đúng source, TTL và retry policy; từng nhánh có ràng buộc riêng.",
    "source_kind": "Discriminator chỉ loại nguồn typed; phải đi cùng đúng một nhánh FK, không dùng ID đa hình không kiểm chứng.",
    "origin_type": "Nguồn command MANUAL/AUTOMATION/INTEGRATION, quyết định actor/user, action execution hoặc API key phải có.",
    "operation_type": "Loại lifecycle mutation được yêu cầu, để worker thực hiện đúng thao tác và kiểm proof tương ứng.",
    "decision": "Quyết định đã xử lý trigger: ADMITTED/NO_MATCH/SUPPRESSED/REJECTED, phục vụ chống lặp admission.",
    "decided_at": "Thời điểm quyết định trigger được ghi bền vững, không dùng thời điểm worker đọc lại làm lần trigger mới.",
    "reason_code": "Mã nguyên nhân ổn định để giải thích kết quả/transition; phải là nội dung an toàn, không chứa raw lỗi/secret.",
    "failure_reason": "Nguyên nhân thất bại đã chuẩn hóa/redact cho vận hành và lịch sử; không lưu response bí mật của dịch vụ ngoài.",
    "severity": "Mức độ INFO/WARNING/CRITICAL của Event, dùng lọc hiển thị/notification; không thay trạng thái Event.",
    "minimum_severity": "Mức độ Event thấp nhất người dùng cho phép nhận push trong workspace này.",
    "safe_message": "Thông điệp Event dùng hiển thị hoặc thông báo sau validation/redaction phía producer; không là nơi cất payload bí mật.",
    "read_at": "Thời điểm recipient đánh dấu mục inbox đã đọc; không ACK/resolve Event và không chứng minh provider đã giao push.",
    "acknowledged_at": "Thời điểm thành viên ACK Event, đi cùng acknowledged_by_user_id và độc lập read_at của inbox.",
    "resolved_at": "Thời điểm Event/resolution được đóng xử lý; ngữ nghĩa theo aggregate, không tự thay command UNKNOWN thành SUCCEEDED.",
    "resolution_status": "Tình trạng đối soát UNKNOWN: UNRESOLVED/ACKNOWLEDGED_UNKNOWN/DEVICE_CONFIRMED_LATE, độc lập command outcome.",
    "manual_observation": "Quan sát do người dùng khai lúc ACK UNKNOWN; không được ghi đè reported value từ thiết bị hoặc coi là device proof.",
    "reported_source": "Nguồn của reported value NONE/DEVICE_RESULT/TELEMETRY/HELLO để phân biệt bằng chứng thiết bị với giá trị người dùng yêu cầu.",
    "last_reported_value": "Giá trị đầu ra được thiết bị xác nhận gần nhất; không cập nhật thành target chỉ vì command đã admission.",
    "last_reported_at": "Thời điểm của reported observation gần nhất được chấp nhận, phục vụ hiển thị độ mới của trạng thái đầu ra.",
    "unresolved_command_id": "Command còn cần đối soát trên actuator; NULL khi không giữ guard này, không tự chứng minh physical output an toàn.",
    "manual_epoch": "Bộ đếm thao tác điều khiển thủ công/integration làm thay đổi ưu tiên actuator; dùng ngăn automation cũ ghi đè thao tác mới.",
    "manual_epoch_at_start": "Manual epoch của actuator được chụp lúc execution bắt đầu, trước WAIT; không đọc lại sau WAIT rồi coi là snapshot ban đầu.",
    "manual_epoch_snapshot": "Manual epoch chụp khi command admission, để kiểm command/automation không dựa vào quyền điều khiển đã lỗi thời.",
    "template_id": "Identity gốc template trong workspace, dùng nhóm các version và nội dung draft; không là identity version đã pin.",
    "template_version_id": "Identity snapshot template cụ thể, dùng pin schema và kiểm đúng definition trong workspace.",
    "pinned_template_version_id": "Template version cố định của device/actuator, lặp để FK kiểm stream đúng pin thay vì chỉ đúng tên kênh.",
    "version_number": "Số phiên bản publish tăng trong cùng template/rule, bắt đầu 1; khác revision chỉnh sửa metadata.",
    "stream_key": "Khóa kỹ thuật ổn định của kênh trong template/version; không dùng nhãn hiển thị thay khóa schema.",
    "data_type": "Kiểu dữ liệu NUMBER/BOOLEAN/STRING/ENUM của definition; validator kiểm literal và giới hạn theo kiểu này.",
    "value_type": "Nhánh kiểu dữ liệu của giá trị được lưu; XOR chọn đúng cột numeric/boolean/text và phải khớp pinned definition.",
    "direction": "Chiều sử dụng kênh READ/WRITE/READ_WRITE; tồn tại stream không đồng nghĩa có capability điều khiển.",
    "channel_kind": "Loại kênh TELEMETRY cho số liệu quan sát hoặc STATE cho trạng thái; bắt buộc khai báo tường minh, độc lập với direction và không tự cấp capability hay quyền điều khiển.",
    "unit": "Đơn vị đo hiển thị của kênh, ví dụ đơn vị cảm biến; NULL khi đại lượng không có đơn vị theo schema.",
    "min_value": "Cận dưới cho giá trị NUMBER hữu hạn; NULL nghĩa không khai cận dưới, không mặc định bằng 0.",
    "max_value": "Cận trên cho giá trị NUMBER hữu hạn; NULL nghĩa không khai cận trên, không tự đặt giới hạn phần cứng.",
    "string_max_length": "Độ dài tối đa của STRING tính bằng ký tự theo validation hiện hành; NULL khi schema không khai giới hạn này.",
    "enum_value": "Một literal JSON number/string được phép của kênh ENUM; validator còn phải kiểm bộ giá trị và type theo contract.",
    "command_type": "Capability lệnh được template công bố, hiện chỉ SET_VALUE; không cho thực thi script hoặc lệnh tùy ý.",
    "safe_value": "Literal giá trị an toàn của capability, phải đúng datatype/range/ENUM; đây là cấu hình, không tự gửi lệnh tới thiết bị.",
    "numeric_value": "Giá trị số hữu hạn của nhánh NUMBER hoặc ENUM số; NULL khi dùng nhánh giá trị khác hoặc quality NULL.",
    "boolean_value": "Giá trị boolean của nhánh BOOLEAN; false là dữ liệu thật, không tương đương NULL/missing.",
    "text_value": "Giá trị chuỗi của nhánh STRING hoặc ENUM chuỗi; không chuyển mọi datatype thành text để bỏ kiểm kiểu.",
    "quality": "Chất lượng mẫu GOOD/NULL/SERVER_TIME; quality NULL biểu diễn mẫu null, không là giá trị số 0 và không tự quyết định time_basis.",
    "time_basis": "Nguồn thời gian hiệu lực DEVICE/SERVER: DEVICE dùng observed_at, SERVER dùng received_at theo envelope.",
    "effective_at": "Thời gian hiệu lực chung của envelope theo time_basis, là authority để point event_at khớp cùng mốc.",
    "event_at": "Thời gian dùng query point, phải bằng envelope.effective_at; được lặp để phục vụ index lịch sử theo stream.",
    "point_count": "Số point dự kiến của envelope, từ 1 đến 10; deferred cardinality check ngăn commit gói thiếu/extra point.",
    "point_index": "Vị trí point trong envelope, bắt đầu 0 và tối đa 9; khác stream_key dùng kiểm trùng kênh.",
    "envelope_id": "Identity raw envelope trong workspace để liên kết các point; receipt tự nhiên vẫn tồn tại khi raw envelope bị purge.",
    "message_id": "Identity message do thiết bị gửi trong một boot, kiểu text theo wire contract; kết hợp device/boot để chống nhận trùng.",
    "boot_id": "Identity boot của thiết bị theo wire dạng text, không suy UUID; chỉ chấp nhận khi gắn với credential/connection đã xác minh.",
    "current_boot_id": "Boot đang hiện hành của thiết bị; NULL khi chưa có boot đáng tin cậy, không hồi sinh boot cũ từ hello trùng.",
    "ingestion_sequence": "Thứ tự tiếp nhận do server quản lý trong từng device, khác sequence trên wire của thiết bị.",
    "source_sequence": "Sequence thiết bị khai trong message/boot theo wire; dùng frontier chống replay, không nhầm với ingestion_sequence.",
    "source_sequence_floor": "Frontier sequence nguồn đã được compact/retire theo boot; writer phải đối soát trước compact receipt, không tự reset khi purge raw.",
    "last_source_sequence": "Sequence nguồn gần nhất đã ghi nhận cho boot; NULL khi chưa có mốc, không dùng thay thứ tự server ingest.",
    "connection_generation": "Thế hệ kết nối đã xác minh của device, dùng loại sự kiện/reply từ kết nối cũ.",
    "transition_sequence": "Số thứ tự chuyển presence thực sự của thiết bị, bắt đầu lớn hơn 0; heartbeat trùng không tạo transition mới.",
    "from_state": "Trạng thái presence trước chuyển đổi, dùng đối chiếu edge thực tế và giải thích trigger connectivity.",
    "to_state": "Trạng thái presence sau chuyển đổi, phải khác from_state; không tự thay lifecycle ACTIVE/SUSPENDED.",
    "presence_state": "Trạng thái kết nối UNKNOWN/ONLINE/OFFLINE, độc lập với lifecycle và maintenance của thiết bị.",
    "last_seen_at": "Thời điểm hoạt động hợp lệ gần nhất từ thiết bị, dùng phát hiện mất kết nối theo policy presence.",
    "retired_at": "Thời điểm boot/secret version được retire; dữ liệu lịch sử và các nghĩa vụ còn tham chiếu có thể tiếp tục được giữ.",
    "credential_generation": "Thế hệ credential MQTT của thiết bị, phân biệt lần cấp mới với credential cũ đã thu hồi.",
    "credential_identifier": "Định danh credential/client phía broker, duy nhất toàn cục; không phải raw password MQTT.",
    "credential_state": "Tiến trình credential PROVISIONING/ACTIVE/REVOCATION_PENDING/REVOKED; chỉ báo đã revoke khi có xác nhận phù hợp.",
    "verifier_digest": "Bộ kiểm chứng mật 32 byte dùng xác thực credential/API key theo protected-verifier contract; không là raw secret và không trả client/log.",
    "token_digest": "Digest token dùng lookup/xác minh mà không lưu raw token; session token và provider token có ngữ nghĩa khác nhau theo bảng.",
    "ticket_digest": "Digest SHA-256 32 byte của bearer ticket, dùng lookup/consume hoặc tải artifact; raw ticket chỉ được trả qua kênh admission.",
    "enrollment_proof_digest": "Digest 32 byte của proof enrollment do installation nắm, dùng chứng minh quyền thao tác phiên; không thay QR PoP hoặc physical proof.",
    "installation_proof_digest": "Digest proof của một installation, dùng xác minh rebind/token update; không chỉ tin installation_id do client khai.",
    "key_digest": "Digest idempotency key của client; cùng namespace principal/route tạo identity replay, không chứa secret response.",
    "request_digest": "Digest 32 byte của request/body đã canonical hóa để phát hiện cùng identity khác nội dung hoặc đối chiếu send intent.",
    "payload_digest": "SHA-256 32 byte của payload đã chấp nhận, phục vụ dedupe và phát hiện cùng identity nhưng body mâu thuẫn.",
    "body_digest": "SHA-256 32 byte của exact raw_body webhook; producer tính trước gửi và giữ nguyên khi retry.",
    "content_digest": "SHA-256 32 byte của nội dung snapshot đã publish, dùng nhận diện/đối chiếu định nghĩa thay vì hash metadata draft hiện tại.",
    "artifact_digest": "SHA-256 32 byte của artifact firmware, dùng identity nội dung và kiểm binary khớp manifest.",
    "reply_digest": "Digest 32 byte của reply probe nhận được, phục vụ đối soát cùng request mà không lưu nội dung bí mật.",
    "secret_ciphertext": "Secret recoverable đã mã hóa cho escrow/ký webhook; key wrapping nằm ngoài DB và chỉ đường ghi có custody được dùng giá trị này.",
    "token_ciphertext": "Provider push token đã mã hóa; chỉ adapter gửi push được giải mã theo custody, không trả ra UI/log.",
    "encryption_key_reference": "Tham chiếu/version của khóa dùng giải mã ciphertext, không chứa key material; NULL phải đồng bộ với nhánh không có ciphertext.",
    "secret_version": "Thế hệ secret ký webhook trong một subscription; khác endpoint_revision và được delivery giữ cố định khi retry.",
    "active_secret_version": "Con trỏ secret version hiện hành của đúng subscription; delivery cũ vẫn giữ version snapshot riêng.",
    "signing_key_identifier": "Định danh khóa ký public/trust profile dùng kiểm firmware manifest; không lưu private signing key.",
    "signing_key_fingerprint": "Fingerprint SHA-256 32 byte của khóa ký được tin cậy, phục vụ audit/provenance chữ ký firmware.",
    "signature": "Bytes chữ ký của exact raw_manifest theo thuật toán trong trust profile; SQL chỉ lưu bytes, validator phải kiểm chữ ký.",
    "raw_manifest": "Exact signed manifest bytes làm authority kiểm chữ ký; không dựng lại từ các cột parsed rồi giả là cùng signed bytes.",
    "manifest_schema_version": "Phiên bản cấu trúc signed manifest, hiện 1; khác firmware version hoặc revision package.",
    "build_identifier": "Định danh build firmware trong manifest, dùng truy vết artifact/toolchain; không thay artifact digest.",
    "artifact_reference": "Locator artifact trong kho đã duyệt, không là arbitrary URL cho client điều khiển hoặc private signing key.",
    "temporary_artifact_reference": "Locator blob upload tạm còn cần verify/cleanup, khác artifact canonical đã được package/job tham chiếu.",
    "artifact_size_bytes": "Kích thước binary firmware tính bằng byte, dùng kiểm manifest, giới hạn download và khả năng chứa image của board.",
    "validation_state": "Nhãn package đã đi qua validator, bảng canonical hiện chỉ VERIFIED; không tự chứng minh chữ ký đúng chỉ nhờ INSERT giá trị này.",
    "maintenance": "Chế độ vận hành NONE/OTA của thiết bị, dùng chặn command/automation khi đang bảo trì.",
    "maintenance_epoch": "Thế hệ khóa bảo trì, dùng phân biệt OTA/dispatch đang hiện hành với callback cũ; không reset do reconnect.",
    "source_firmware_version_snapshot": "Firmware nguồn được chụp lúc OTA admission để đối soát upgrade/rollback sau reboot.",
    "target_artifact_digest_snapshot": "SHA-256 image đích được chụp khi nhận OTA, không đổi theo package/config hiện tại.",
    "job_nonce": "Nonce 32 byte gắn ý định OTA, giúp board/backend phân biệt job cũ và bằng chứng của lần update khác.",
    "phase": "Pha kỹ thuật OTA hiện được job/status báo; khác state điều phối và phải được validator/worker kiểm theo protocol.",
    "status_sequence": "Sequence uint32 của status OTA, từ 0 đến 4294967295; cùng sequence khác digest phải được đối soát, không last-write-wins.",
    "start_intent_at": "Thời điểm ghi ý định gửi START OTA trước network; có thể đã gửi khi mất ACK, không blind resend chỉ vì thiếu reply.",
    "dispatch_intent_at": "Thời điểm lưu ý định dispatch command trước network; dùng phân biệt chưa gửi với đã có khả năng tác động vật lý.",
    "recovery_reason": "Lý do cần recovery/đối soát OTA đã redact; không tự giải phóng maintenance hoặc kết luận rollback.",
    "recovery_boot_id": "Boot tham gia recovery được xác minh theo protocol; NULL khi chưa có bằng chứng boot phục hồi.",
    "reconciled_at": "Thời điểm backend hoàn tất bước đối soát recovery, khác deadline và thời điểm board reboot.",
    "recovery_epoch": "Thế hệ một đợt recovery/probe của job để ngân sách probe không bị dùng lại sau restart.",
    "probe_number": "Số thứ tự probe trong một recovery epoch, từ 1 đến 3; không reset để vượt budget bằng retry.",
    "request_id": "Identity duy nhất của probe request, dùng ghép reply với đúng ý định gửi.",
    "sent_at": "Thời điểm adapter ghi nhận đã gửi probe; NULL khi chưa có xác nhận gửi, không mặc định nghĩa là chắc chắn chưa gửi.",
    "reply_at": "Thời điểm server ghi nhận reply probe, dùng giải thích kết quả recovery và deadline.",
    "grant_generation": "Generation của một lần cấp membership cụ thể, lớn hơn 0; không tái sử dụng identity khi remove rồi rejoin.",
    "current_grant_generation": "Grant membership hiện đang dùng; phải trỏ đúng lịch sử cấp quyền, không tự bật lại grant đã revoke.",
    "actor_grant_generation": "Grant actor được chụp lúc tạo enrollment, giúp kiểm tác vụ cũ sau remove/rejoin.",
    "owner_grant_generation": "Grant owner được chụp khi cấp API key; request sau này phải giao với quyền/grant hiện hành.",
    "issuer_grant_generation": "Grant của người mời được chụp lúc phát hành invitation, không mặc định còn hợp lệ tại lúc consume.",
    "admission_generation": "Thế hệ nhận thành viên theo email/workspace; snapshot invitation phải được so với fence hiện hành tại consume.",
    "issuer_authorization_version": "Phiên bản quyền của người mời tại lúc phát invitation, dùng kiểm callback/consume có dựa trên quyền cũ hay không.",
    "workspace_authorization_version": "Phiên bản quyền workspace chụp trong ticket, phải khớp hiện hành khi consume realtime admission.",
    "membership_authorization_version": "Phiên bản quyền membership chụp trong ticket, dùng vô hiệu ngữ cảnh cũ sau mutation quyền.",
    "failure_count": "Số lần đăng nhập sai trong bucket hiện hành, miền 0..5; count 0 đi cùng window_started_at NULL.",
    "window_started_at": "Mốc failure đầu mở fixed window đăng nhập, không trượt theo mỗi lần retry/429; NULL khi bucket rỗng.",
    "display_timezone": "Múi giờ IANA dùng hiển thị cho user, mặc định UTC; không đổi instant lưu trong DB hay lịch rule hiện hữu.",
    "default_timezone": "Múi giờ IANA mặc định của workspace cho cấu hình mới; đổi giá trị này không tự đổi timezone snapshot của lịch đã tạo.",
    "timezone_snapshot": "Múi giờ IANA được chụp khi định danh schedule occurrence, giữ đúng calendar/DST policy dù cấu hình mặc định đổi.",
    "route_key": "Namespace route canonical gồm identity resource cần thiết; không chỉ là route template khi nhiều target dùng chung idempotency key.",
    "response_status": "HTTP status đã ghi nhận, miền 100..599 khi có; NULL khi chưa có response đáng tin cậy.",
    "sanitized_result": "Kết quả replay đã loại secret, không lưu one-time credential response để trả lại sau retry.",
    "sanitized_payload": "Payload quan sát đã được producer loại trường nhạy cảm, dùng audit/đối soát; SQL JSON type không tự làm redaction.",
    "immutable_payload": "Snapshot payload occurrence đã commit, giữ nguyên để fanout/retry không đọc lại resource mutable rồi đổi sự thật lịch sử.",
    "payload": "Document sự kiện nội bộ theo payload_schema_version; producer phải validation/redact trước ghi, không dùng thay authority entity.",
    "payload_schema_version": "Phiên bản schema payload outbox để consumer đọc đúng cấu trúc, không nhầm với entity revision.",
    "event_key": "Khóa nghĩa vụ outbox ổn định để dedupe trong namespace workspace hoặc global IAM; không sinh key mới cho cùng retry.",
    "event_type": "Loại sự kiện được audit/outbox/webhook sử dụng; ý nghĩa/allowlist phụ thuộc bảng và schema contract.",
    "consumer_code": "Tên pipeline nhận outbox event; mỗi consumer có trạng thái/lease riêng để không ảnh hưởng consumer khác.",
    "policy_code": "Identity policy rate-limit đã được duyệt, dùng nhóm admission và cửa sổ đếm; không cho client tự chọn policy để bỏ giới hạn.",
    "correlation_id": "Identity tương quan request/flow để nối audit và intent/result; không chứa raw token, email hoặc payload nhạy cảm.",
    "request_correlation_id": "Identity request/flow đã tiêu hao rate admission, dùng truy vết và đối chiếu thay vì đếm lại cùng nghĩa vụ.",
    "resource_type": "Loại resource được audit chụp lại; đi cùng resource_id như snapshot lịch sử, không là authority hoặc FK đa hình để cấp quyền.",
    "resource_id": "Identity resource được audit chụp ở thời điểm thao tác; có thể không còn live resource sau retention nhưng không cấp quyền truy cập.",
    "redacted_diff": "Phần thay đổi metadata đã loại bỏ secret/PII theo audit policy; producer chịu trách nhiệm chọn trường trước ghi JSON.",
    "trigger_type": "Nguồn kích hoạt THRESHOLD/SCHEDULE/CONNECTIVITY/MANUAL của rule, quyết định shape trigger_config cần validate.",
    "trigger_config": "Cấu hình trigger theo schema version; JSON object CHECK chỉ kiểm dạng ngoài, không thay validator typed và quyền resource.",
    "condition_ast": "Cây điều kiện AND/OR/literal theo rule contract; backend phải kiểm depth/type/leaves và bijection với reference rows.",
    "schema_version": "Phiên bản cấu trúc document dashboard/rule, hiện 1; khác revision chỉnh sửa và version publish.",
    "cooldown_seconds": "Thời gian nghỉ tối thiểu giữa các lần admission rule, đơn vị giây, từ 10 đến 3600 theo policy rule.",
    "cooldown_until": "Mốc UTC kết thúc cooldown đang có hiệu lực; restart không được reset mốc để lách giới hạn.",
    "priority": "Mức ưu tiên HIGH/NORMAL/LOW của rule, không tự cho quyền vượt manual epoch hoặc guard actuator.",
    "on_failure": "Policy STOP/CONTINUE cho lỗi đã biết của chuỗi; UNKNOWN vẫn cần dừng/đối soát theo contract, không tự chạy bước sau.",
    "action_position": "Chỉ số action bắt đầu 0 trong chuỗi tối đa 5 bước, dùng ghép definition/action execution/job.",
    "action_type": "Loại hành động SET_VALUE/WAIT/NOTIFY; mỗi nhánh yêu cầu bộ trường typed riêng, không chứa code/script tùy ý.",
    "wait_seconds": "Thời lượng WAIT theo giây, từ 5 đến 600 cho một bước; tổng WAIT của version còn bị giới hạn 600 giây.",
    "target_device_id": "Thiết bị đích của action hoặc deep link; NULL khi nhánh không có device, nếu có phải cùng workspace và đúng pin.",
    "target_template_version_id": "Template version của target device, lặp để FK bảo vệ target stream đúng pin.",
    "target_stream_key": "Kênh điều khiển đích trong pinned template version, không chỉ một stream cùng tên ở version bất kỳ.",
    "target_value": "Literal JSON của SET_VALUE, phải qua kiểm datatype/range/capability; không được dùng expression hoặc script làm giá trị.",
    "notification_config": "Cấu hình NOTIFY theo schema, chỉ tồn tại ở nhánh NOTIFY; nội dung phải được validation/redact khi tạo Event.",
    "reference_path": "Đường dẫn ổn định tới một reference trong AST/trigger/action snapshot, dùng kiểm đủ và đúng hai chiều với document.",
    "reference_kind": "Reference thuộc TRIGGER/CONDITION/ACTION, giúp validator đối chiếu đúng vai trò tài nguyên tại publish/save.",
    "active_rule_version_id": "Version đang được rule chọn để thực thi; FK buộc thuộc cùng rule, khác draft đang chỉnh.",
    "current_rule_version_id": "Rule version runtime hiện hành của đúng rule, dùng phối hợp active generation/cooldown với coordinator.",
    "active_generation": "Thế hệ kích hoạt runtime rule, dùng phân biệt công việc cũ sau enable/disable/publish lại.",
    "error_disabled_reason": "Nguyên nhân rule bị tắt do lỗi/rate policy, đã chuẩn hóa để hiển thị và yêu cầu thao tác phục hồi phù hợp.",
    "trigger_key": "Identity ổn định của trigger/episode/occurrence theo version; dùng dedupe, không sinh key mới chỉ vì worker restart.",
    "is_armed": "True khi trigger episode sẵn sàng nhận một lần fire theo policy hysteresis/hold; không thay kiểm freshness input.",
    "hold_started_at": "Mốc bắt đầu hold liên tục đủ điều kiện; stale/restart phải xử lý theo policy, không cộng thời gian mất dữ liệu như hold hợp lệ.",
    "last_fresh_at": "Thời điểm input/trigger gần nhất còn đủ fresh, dùng reset hold hoặc xác định episode không còn tin cậy.",
    "episode_sequence": "Sequence episode tăng để identity lần fire không bị tái sử dụng khi condition bật/tắt hoặc worker phục hồi.",
    "last_marker_sequence": "Marker dữ liệu cuối đã xử lý cho trigger state, tránh mẫu lặp làm tăng hold hoặc fire lại.",
    "next_action_position": "Vị trí bước kế của execution, miền 0..5; giá trị 5 có thể biểu diễn đã qua bước cuối trong chuỗi tối đa 5 action.",
    "owner_user_id_snapshot": "Owner được chụp khi execution admission, dùng phân quyền lịch sử theo policy; request vẫn phải recheck membership hiện hành.",
    "input_snapshot": "Dữ liệu đầu vào/quality/time được chụp tại evaluation để giải thích quyết định mà không lấy latest mới ghi đè lịch sử.",
    "condition_trace": "Trace kết quả từng phần của AST tại evaluation, phục vụ giải thích TRUE/FALSE/UNKNOWN và dry-run/history.",
    "definition_snapshot": "Bản sao định nghĩa cần giữ cho lịch sử khi policy cho phép; không live-join draft mutable để diễn giải execution cũ.",
    "scheduled_at": "Instant lịch đã resolve theo timezone/DST policy; không tính lại từ timezone mặc định mới khi job được đọc lại.",
    "occurrence_key": "Identity calendar ổn định của một lần lịch trong rule version, dùng chống chạy trùng/catchup sai sau restart.",
    "episode_key": "Identity episode nghiệp vụ của nguồn Event, dùng dedupe một sự kiện trong cùng chu kỳ lỗi/điều kiện.",
    "source_identity": "Identity nguồn Event được sinh từ đúng một nhánh device/rule; dùng natural dedupe cùng source_kind và episode_key.",
    "source_device_id": "Device làm nguồn Event khi source_kind=DEVICE; nhánh rule phải để NULL để giữ XOR nguồn.",
    "source_rule_id": "Rule làm nguồn Event khi source_kind=RULE; nhánh device phải để NULL để giữ XOR nguồn.",
    "event_revision": "Revision transition Event được chụp trong occurrence, lớn hơn 0; unique cùng Event tránh phát cùng transition hai lần.",
    "connectivity_device_id": "Device làm nguồn occurrence connectivity, chỉ có trong nhánh CONNECTIVITY.",
    "connectivity_transition_sequence": "Transition presence cụ thể của connectivity_device_id; cùng device/sequence là nguồn chống trùng occurrence.",
    "occurrence_type": "Loại transition nội bộ của nguồn occurrence; ACKNOWLEDGED không mặc định thành BUSINESS webhook public.",
    "public_event_type": "Loại event public để webhook fanout; NULL cho occurrence nội bộ không được phép phát BUSINESS webhook.",
    "target_type": "Loại đích deep link EVENT/EXECUTION/DEVICE/NOTIFICATION, quyết định target FK nào phải có hoặc phải NULL.",
    "target_rule_execution_id": "Execution đích của notification; giữ identity lịch sử nhưng không kéo dài quyền đọc history sau retention/mất quyền.",
    "position": "Thứ tự widget trên mobile, từ 0 đến 19 và duy nhất trong dashboard; khác tọa độ layout grid Web.",
    "widget_type": "Loại widget VALUE/GAUGE/STATUS/SWITCH/BUTTON/CHART; backend còn phải kiểm tương thích datatype/capability và config.",
    "presentation": "Cấu hình hiển thị theo loại widget dưới dạng JSON object; không phải nơi lưu resource authority, secret hoặc script tùy ý.",
    "layout_x": "Tọa độ cột bắt đầu trong grid Web 12 cột, từ 0 đến 11; phải cộng width không vượt 12.",
    "layout_y": "Tọa độ hàng bắt đầu của widget trong grid Web, không âm; khác mobile order.",
    "layout_width": "Số cột grid mà widget chiếm, lớn hơn 0; tổng với layout_x phải nằm trong 12 cột.",
    "layout_height": "Số đơn vị hàng grid mà widget chiếm, lớn hơn 0; không phải pixel hoặc số mẫu lịch sử.",
    "binding_slot": "Tên slot dữ liệu/điều khiển của widget, để một widget có thể liên kết từng nhu cầu với resource đúng scope.",
    "latest_marker_sequence": "Marker server của mẫu mới nhất được projection chấp nhận; không được lùi khi message đến sai thứ tự.",
    "latest_received_at": "Mốc server nhận mẫu đang làm latest; không được lùi, không thay observed/effective time của dữ liệu gốc.",
    "latest_value": "Snapshot giá trị mới nhất cho hiển thị, có thể NULL/không đủ điều kiện rule; không mặc định fallback GOOD cũ.",
    "rule_eligible_marker_sequence": "Marker của mẫu hiện hành đủ điều kiện rule, phải bằng latest marker nếu có; NULL nghĩa không có giá trị rule đủ điều kiện.",
    "rule_value": "Giá trị của đúng eligible marker hiện hành để rule dùng; NULL khi marker mới không đủ điều kiện, không giữ GOOD cũ làm authority.",
    "eligibility_reason": "Lý do latest được/không được dùng cho rule, giúp giải thích NULL/stale/server-time thay vì đoán từ giá trị.",
    "active_execution_count": "Projection số execution RUNNING/WAITING của workspace, miền 0..10; trigger đối chiếu ledger khi admission/terminal.",
    "requested_revision": "Revision resource mà người yêu cầu dựa vào lúc khởi tạo lifecycle operation; dùng phát hiện yêu cầu chỉnh sửa đã lỗi thời.",
    "broker_revoke_receipt": "Bằng chứng đã redact về broker xác nhận thu hồi; không suy chỉ ghi trạng thái DB là broker đã chặn credential.",
    "disconnect_receipt": "Bằng chứng đã redact về kết nối thiết bị bị ngắt theo cleanup/lifecycle protocol; cần giữ để settlement có căn cứ.",
    "broker_receipt_at": "Mốc backend có xác nhận cấu hình credential/ACL từ broker; khác MQTT PUBACK của message ứng dụng.",
    "delivery_channel": "Kênh phát credential USB_ONE_TIME/ENROLLMENT_BLE; quyết định binding/escrow/claim policy, không là trạng thái broker.",
    "delivery_status": "Tiến độ phát credential PENDING/AVAILABLE/CLAIMED/EXPIRED/UNAVAILABLE, tách khỏi state PENDING/READY/FAILED của operation.",
    "installation_id": "Identity một cài đặt app Android, không đồng nghĩa user hoặc hardware device; rebind cần proof của installation.",
    "client_installation_id": "Installation mà enrollment gắn với; cố ý không FK tới push_installations vì onboarding không đòi quyền push.",
    "active_user_id": "Tài khoản hiện đang gắn với installation push; phải cùng active_session_id hoặc cùng NULL khi chưa bind.",
    "active_session_id": "Phiên đang sở hữu binding push hiện hành; cleanup phiên cũ phải CAS đúng binding để không xóa binding phiên mới.",
    "token_generation": "Thế hệ provider token của installation; attempt giữ generation để giải thích token rotate và reply cũ.",
    "binding_generation": "Thế hệ gắn user/session của installation; delivery chụp làm fence, không đưa vào dedupe notification/installation.",
    "client_sequence": "Sequence cập nhật từ installation để từ chối update/rebind tới trễ, không dùng arrival time làm last-write-wins.",
    "permission_state": "Trạng thái permission push do app báo, tách khỏi preference workspace và binding xác thực.",
    "enabled": "Cờ cho phép nhận thông báo theo installation hoặc preference; còn phải giao với permission, binding và quyền hiện hành.",
    "platform": "Nền tảng installation được triển khai, hiện ANDROID; không tự mở scope iOS đã hoãn.",
    "app_version": "Phiên bản app do installation khai để chẩn đoán tương thích; không phải bằng chứng xác thực hoặc quyền.",
    "provider_request_id": "Identity request/message do push provider trả để đối chiếu attempt; không lưu bearer header hoặc response secret.",
    "mode": "Chế độ enrollment INITIAL/WIFI_RECONFIGURE; đổi Wi-Fi không tự tạo/thu hồi MQTT credential hiện hành.",
    "acquired_at": "Thời điểm device enrollment guard được giữ, giúp chẩn đoán thời gian chiếm thiết bị khi session đã hết hạn.",
    "endpoint_url": "URL HTTPS của webhook subscription; lớp outbound còn phải kiểm DNS/IP/redirect chống SSRF mỗi lần gửi.",
    "endpoint_revision": "Phiên bản endpoint URL hiện hành; đổi URL phải làm verify cũ không còn hiệu lực.",
    "verified_endpoint_revision": "Endpoint revision đã được xác minh, phải trùng endpoint_revision hiện hành nếu có; NULL khi chưa có verify hợp lệ.",
    "verified_at": "Thời điểm xác minh endpoint revision hiện hành; không dùng lại cho URL mới hoặc coi như quyền SSRF vĩnh viễn.",
    "endpoint_url_snapshot": "URL đích được chụp khi delivery admission; retry không tự đổi sang URL hiện hành khác.",
    "endpoint_revision_snapshot": "Revision URL được delivery chụp, phục vụ recheck endpoint/fanout policy và giải thích lịch sử gửi.",
    "raw_body": "Exact body bytes gửi webhook và ký HMAC, giữ nguyên khi retry/manual batch; không dựng lại từ live resource.",
    "prefix": "Phần nhận diện không nhạy cảm của API key để hiển thị/quản trị; không đủ xác thực và không thay secret.",
    "last_used_at": "Mốc request hợp lệ gần nhất được key chấp nhận theo policy; update đến trễ không được làm lùi mốc hoặc hồi sinh key revoked.",
    "scope_code": "Permission API key từ allowlist devices:read/telemetry:read/commands:write; không chứa quyền admin ngầm định.",
    "evidence_type": "Loại bằng chứng command LATE_RESULT/CONFLICTING_RESULT/DEVICE_OBSERVATION để không nhầm quan sát với terminal truth.",
    "result_phase": "Phase result ACCEPTED/SUCCEEDED/FAILED của command; ACCEPTED không phải kết quả vật lý thành công.",
    "result_snapshot": "Snapshot result đã xác thực và redact, dùng dedupe/đối soát; không thay quyền hiện hành khi hiển thị.",
    "device_evidence_id": "Bằng chứng thuộc chính command được dùng cho DEVICE_CONFIRMED_LATE; không nhận evidence của command khác.",
    "admission_id": "Identity một lần admission đã được ghi nhận trong ledger reset/rate; không phải token dùng xác thực.",
    "api_key_id": "Identity principal API key toàn cục, dùng resolve workspace trước kiểm quyền; không chứa raw key secret.",
    "audit_event_id": "Identity duy nhất của một bản ghi kiểm toán, dùng phân trang và tương quan lịch sử.",
    "command_id": "Identity command ổn định qua retry/result/reconciliation; không tạo command mới chỉ vì mất response.",
    "command_evidence_id": "Identity một bằng chứng command bổ sung để liên kết resolution và timeline quan sát.",
    "dashboard_id": "Identity dashboard trong workspace, dùng nhóm widget và kiểm owner/revision khi lưu cấu hình.",
    "widget_id": "Identity widget trong dashboard, giữ binding đúng thành phần dù thay layout hoặc thứ tự mobile.",
    "device_operation_id": "Identity lifecycle operation của thiết bị; khi tham chiếu cùng device_id phải khớp đúng thiết bị đó.",
    "enrollment_session_id": "Identity ý định onboarding/đổi Wi-Fi, dùng polling, proof binding và liên kết cleanup/guard.",
    "enrollment_cleanup_operation_id": "Identity công việc cleanup của enrollment, dùng theo dõi proof và settlement độc lập TTL phiên.",
    "event_id": "Identity Event nghiệp vụ trong workspace; khác occurrence_id đại diện từng transition để giao webhook.",
    "occurrence_id": "Identity một transition đã commit; wire webhook eventId ánh xạ identity này, không gộp OPEN/RESOLVED thành một Event ID.",
    "firmware_package_id": "Identity canonical package firmware trong workspace, dùng liên kết compatibility và OTA jobs.",
    "firmware_upload_attempt_id": "Identity một lượt upload/verify, kể cả reject; không là canonical package identity.",
    "idempotency_record_id": "Identity kỹ thuật của receipt scoped; dedupe thực sự theo principal/route/key digest, không dựa vào ID này.",
    "invitation_id": "Identity lời mời workspace dùng quản trị/truy vết; token_digest mới là bộ kiểm chứng khi nhận lời mời.",
    "notification_id": "Identity mục inbox của recipient, là gốc fanout push/deep link; không thay Event source hoặc occurrence identity.",
    "ota_job_id": "Identity ý định OTA ổn định qua status/probe/recovery, dùng gắn nonce, artifact và maintenance epoch.",
    "outbox_event_id": "Identity outbox event đã commit, dùng ghép trạng thái riêng của từng consumer và claim/complete receipt.",
    "provisioning_operation_id": "Identity công việc cấp credential, dùng claim một lần và gắn enrollment đúng device/generation.",
    "push_delivery_id": "Identity nghĩa vụ giao push, giữ nguyên qua mọi send attempt và phản hồi provider.",
    "rule_id": "Identity gốc rule trong workspace, dùng nhóm draft/version/runtime; không là identity một lần chạy.",
    "rule_version_id": "Identity rule snapshot đã publish, dùng pin trigger/action/execution thay vì đọc draft hiện hành.",
    "rule_execution_id": "Identity một lần quyết định/chạy rule version, dùng quota, history, action chain và notification target.",
    "action_execution_id": "Identity ổn định của một action runtime; unique command theo identity này ngăn retry tạo lệnh vật lý thứ hai.",
    "ticket_id": "Identity quản lý bearer ticket, không phải secret; ticket_digest dùng xác minh/consume.",
    "webhook_delivery_id": "Identity nghĩa vụ webhook giữ nguyên khi retry, để receiver dedupe ngay cả khi response bị mất.",
    "webhook_subscription_id": "Identity cấu hình webhook trong workspace, dùng nhóm filter, secret versions và lịch sử delivery.",
    "workspace_operation_id": "Identity lifecycle operation workspace, dùng nhóm tập device snapshot và tiến độ cleanup từng thiết bị.",
    "version": "Identity phiên bản migration ổn định trong ledger, không tự đổi tên hoặc tái áp bằng nội dung khác.",
    "checksum": "SHA-256 hex của byte source migration đã áp; runner so exact checksum và từ chối drift thay vì hợp thức hóa history.",
    "applied_at": "Thời điểm runner ghi migration đã áp cùng transaction DDL; không là timestamp tạo file hoặc thời gian sửa source.",
}

# Override cho các tên xuất hiện nhiều nhưng khác nghĩa hoặc có TTL/NULL riêng quan trọng.
COLUMN_OVERRIDES = {
    "template_draft_streams": {
        "default_value": "Default cấu hình typed; không phải safeValue, command hoặc giá trị thiết bị đã báo cáo.",
    },
    "datastream_definitions": {
        "default_value": "Default typed đóng băng cùng snapshot và digest; NULL khi draft không khai báo.",
    },
    "password_change_attempt_buckets": {
        "user_id": "User sở hữu limiter đổi mật khẩu; khóa ngoại giữ bucket gắn đúng account và không dùng email, session hoặc IP làm định danh.",
        "failure_count": "Số lần currentPassword sai trong fixed window hiện hành, miền 0..5; count 0 đi cùng window_started_at NULL.",
        "window_started_at": "Thời điểm failure đầu tiên mở fixed window 15 phút; không trượt khi retry hoặc nhận 429, NULL khi bucket rỗng.",
    },
    "devices": {"hardware_revision": "Revision phần cứng từ authenticated hello/status; NULL khi registry chưa có observation, không lấy từ input đăng ký. Dùng kiểm tương thích firmware, không thuộc identity cloud bất biến."},
    'audit_retention_batches': {'batch_id': 'Identity UUID không nil của intent batch, primary key không NULL/không trùng; retry cùng ID phải giữ run và batch limit gốc.', 'run_id': 'Run/cutoff mà batch tham chiếu bằng khóa ngoại; không cascade xóa result và không sao chép cutoff vào từng batch gây lặp phụ thuộc hàm.', 'batch_limit': 'Số audit tối đa một transaction được xóa, bắt buộc trong1…1000 để giới hạn lock/runtime; là một phần body identity của batch replay.', 'removed_count': 'Số audit thực đã xóa cùng commit với result, trong0…batch_limit;0 không chứng nhận run drain nếu audit đang bị transaction khác khóa.', 'completed_at': 'Thời điểm server ghi batch result đã hoàn tất; row chỉ xuất hiện sau commit DELETE cùng metadata, không dùng làm cutoff retention của audit.'},
    'audit_retention_runs': {'run_id': 'Identity UUID không nil của một run retention do coordinator cấp; primary key không NULL và không trùng, dùng giữ cutoff cố định qua restart.', 'cutoff': 'Cutoff ingestion UTC đã đóng cho run; mặc định serverNow trừ720 giờ, chỉ audit có created_at nhỏ hơn cutoff mới đủ điều kiện purge; đúng cutoff vẫn giữ.'},
    # Audit dùng ingestion timestamp riêng; created_at của bảng khác vẫn giữ mô tả chung đã review.
    "audit_events": {"client_type": "Metadata client WEB/ANDROID/IOS hoặc UNKNOWN khi không nhận diện được. Nhãn hữu hạn phục vụ audit, không cấp quyền hoặc tiết lộ credential.", "created_at": 'Thời điểm server ghi audit bằng statement_timestamp(); dùng phân trang và retention30 ngày, độc lập occurred_at của sự kiện. Runtime chỉ có column INSERT allowlist không gồm cột này; immutable sau INSERT.', "workspace_id": "Workspace của sự kiện kiểm toán; NULL chỉ cho IAM/global audit, không được fanout global log cho Admin workspace.", "actor_user_id": "Principal thực hiện thao tác; NULL cho anonymous/system event hợp lệ, nhưng có session_id thì actor phải đúng chủ phiên.", "outcome": "Kết quả kiểm toán của thao tác như thành công/từ chối/lỗi theo event contract; không mặc định là trạng thái command vật lý."},
    "users": {"user_id": "Identity tài khoản toàn cục để đăng nhập và liên kết các membership; không gắn với một workspace duy nhất."},
    "sessions": {"client_type": "Metadata client WEB/ANDROID/IOS; WEB dùng cookie còn ANDROID/IOS dùng bearer. Không chứng thực platform hoặc cấp quyền; session vẫn có TTL 24 giờ và guard hiện hành.", "expires_at": "Hạn hiệu lực cố định issued_at + 24 giờ; revoke có thể làm phiên hết quyền sớm hơn, row còn giữ khi audit/ticket tham chiếu.", "token_digest": "SHA-256 32 byte của raw session token; unique toàn cục để lookup phiên, không trả về client/log."},
    "workspaces": {"status": "Lifecycle ACTIVE/SUSPENDED/ARCHIVED; suspend chặn admission theo policy, archive không phải hard-delete và không tự unarchive.", "created_by_user_id": "Tài khoản tạo workspace, dùng anchor tuần tự hóa quota tối đa 5 workspace do account tạo."},
    "memberships": {"status": "Tư cách thành viên ACTIVE/SUSPENDED/REMOVED trong workspace; khác trạng thái tài khoản toàn cục.", "authorization_version": "Phiên bản quyền của membership, chụp vào ticket/job; đường ghi phải tăng khi role/status/quyền thay đổi theo protocol."},
    "workspace_invitations": {"expires_at": "Deadline issued_at + 24 giờ; consume phải kiểm thời gian và generation/quyền hiện hành, không chờ cron xóa row expired.", "revision": "Revision dương của metadata invitation cho If-Match; mặc định1, engine tự tăng khi row thay đổi, no-op giữ nguyên và caller không được tự ghi đè."},
    "websocket_tickets": {"expires_at": "Deadline issued_at + 30 giây cho admission realtime; consume một winner và recheck session/grant/workspace trước mở socket."},
    "outbox_events": {"workspace_id": "Scope sự kiện; NULL là namespace IAM/global riêng, không được nhầm với quyền truy cập mọi workspace."},
    "outbox_consumptions": {"state": "Tiến trình consumer PENDING/PROCESSING/RETRY_WAIT/COMPLETED/DEAD_LETTER; COMPLETED phải đi cùng completed_at."},
    "global_idempotency_records": {"user_id": "Tài khoản principal của request global; không đưa workspace đang chọn vào namespace replay.", "expires_at": "Hết cửa sổ replay sau admitted_at + 24 giờ; không replay one-time secret, chỉ sanitized_result.", "state": "Receipt đang IN_PROGRESS hoặc COMPLETED; lỗi mất ACK không cho tự kết luận transaction chưa commit."},
    "workspace_idempotency_records": {"user_id": "Principal user trong workspace; NULL nếu request do API key, CHECK yêu cầu đúng một nhánh principal.", "api_key_id": "Principal API key của request; NULL nếu dùng user session, FK buộc key thuộc đúng workspace.", "expires_at": "Cửa sổ replay admitted_at + 24 giờ; vẫn phải recheck current authorization trước trả receipt.", "state": "Receipt đang IN_PROGRESS hoặc COMPLETED; request_digest phân biệt retry cùng body với conflict cùng key khác body."},
    "rate_limit_admissions": {"workspace_id": "Workspace của policy scoped; NULL khi policy được phép ở namespace global, API key luôn phải có scope workspace.", "user_id": "Principal user tiêu hao rate admission; chỉ có đúng một nhánh user_id hoặc api_key_id.", "api_key_id": "Principal API key tiêu hao rate admission, luôn gắn với workspace resolve từ key."},
    "provisioning_operations": {
        "state": "Kết quả cấu hình broker PENDING/READY/FAILED, tách khỏi delivery_status của secret để không báo board đã nhận credential chỉ vì broker READY.",
        "expires_at": "Hạn escrow intent_at + 10 phút; broker ACK/retry/poll không kéo dài deadline, cleanup intent có thể sống lâu hơn escrow.",
        "retry_count": "Số lần adapter retry đã ghi bền vững; không gồm attempt đầu và không chứa raw diagnostics.",
        "error_code": "Mã lỗi public đã lọc cho status poll; không dùng lỗi broker hoặc giá trị credential làm nội dung.",
    },
    "device_runtime": {"ingestion_sequence": "Bộ đếm server đã tiếp nhận cho device, ban đầu 0; tăng theo ingest commit, không lấy wire seq thay thế."},
    "device_boot_sessions": {"started_at": "Thời điểm backend xác minh boot/kết nối theo credential generation; không chỉ tin boot_id trong payload."},
    "telemetry_envelopes": {"observed_at": "Timestamp do thiết bị khai chung cho envelope; NULL khi thiết bị chưa có clock, không nhận timestamp khác nhau cho từng point.", "received_at": "Server first-received time phải khớp receipt, không thay thành thời gian nhận lại khi retry."},
    "telemetry_points": {"observed_at": "Bản sao observed_at của envelope để phục vụ lịch sử; so khớp null-safe, không phải per-point timestamp độc lập từ wire."},
    "commands": {"state": "Tiến trình command từ ADMITTED qua dispatch tới terminal; transition được guard, không nhảy thẳng admission thành success.", "outcome": "Kết quả vật lý PENDING/SUCCEEDED/FAILED/UNKNOWN; TIMED_OUT giữ UNKNOWN kể cả sau ACK thủ công hoặc thêm late evidence.", "deadline_at": "Deadline cố định admitted_at + 10 giây; command đã có khả năng dispatch mà hết hạn không được blind retry.", "actor_user_id": "Người phát lệnh MANUAL; phải NULL cho AUTOMATION/INTEGRATION vì hai nguồn đó có principal typed riêng."},
    "command_resolutions": {"resolved_at": "Mốc ghi nhận resolution ACK/late device proof; không viết lại terminal_at hoặc outcome của command gốc."},
    "dashboard_widget_bindings": {"template_version_id": "Pin version cho stream binding; cùng NULL với stream_key khi binding là presence của device.", "stream_key": "Kênh pinned của stream binding; cùng NULL với template_version_id khi slot dùng presence, device_id vẫn bắt buộc."},
    "rule_executions": {"state": "Trạng thái RUNNING/WAITING hoặc kết quả SUCCEEDED/PARTIAL/FAILED/CANCELLED/NEEDS_ATTENTION/NO_MATCH; RUNNING/WAITING chiếm quota.", "deadline_at": "Deadline admitted_at + 15 phút cho cả execution; WAIT/restart không kéo dài ngân sách toàn chuỗi."},
    "action_executions": {"state": "Trạng thái từng bước BLOCKED/READY/WAITING/DISPATCHING/AWAITING_RESULT/SUCCEEDED/FAILED/CANCELLED/NEEDS_ATTENTION; UNKNOWN không tự unblock bước sau."},
    "action_jobs": {"state": "Trạng thái công việc tương ứng action execution; chỉ một READY/execution, due_at và lease quyết định khi worker được claim."},
    "schedule_occurrences": {"state": "Tiến trình lần lịch PENDING/ADMITTED/SKIPPED/CANCELLED; không tạo occurrence identity mới khi restart đọc lại."},
    "events": {"status": "Vòng đời Event OPEN/ACKNOWLEDGED/RESOLVED; khác trạng thái read của inbox và outcome của command."},
    "notifications": {"kind": "EVENT là inbox từ Event nghiệp vụ; PUSH_TEST là test push không tạo Event giả.", "created_at": "Mốc tạo notification làm gốc expiry push +1 giờ; delivery fanout muộn không được lấy mốc worker mới làm gốc TTL."},
    "push_installations": {"token_digest": "Digest 32 byte của provider push token hiện hành, phục vụ dedupe token giữa installation; raw token nằm ở ciphertext.", "permission_state": "Permission Android do app báo: UNKNOWN/GRANTED/DENIED/NOT_DETERMINED; không tự nâng preference hoặc session quyền."},
    "push_deliveries": {"state": "Tiến trình PENDING/SENDING/RETRY_WAIT và terminal ACCEPTED/FAILED/EXPIRED/SUPPRESSED; ACCEPTED chỉ chứng minh provider nhận.", "created_at": "Bản sao Notification.created_at tại fanout, không là thời điểm worker gửi lần đầu.", "expires_at": "Hạn gửi Notification.created_at + 1 giờ, độc lập retention history 30 ngày; rebind/retry không kéo dài TTL."},
    "push_delivery_attempts": {"outcome": "Kết quả quan sát INTENT/ACCEPTED/TRANSIENT_FAILURE/PERMANENT_FAILURE/UNKNOWN của một send intent; không đồng nghĩa recipient đã đọc."},
    "enrollment_sessions": {"state": "CREATED→BLE_CONNECTED→WIFI_JOINED→CLOUD_CONNECTING→COMPLETED hoặc FAILED/CANCELLED/EXPIRED; chỉ trusted cloud evidence mới được xác nhận COMPLETED.", "expires_at": "Hạn phiên started_at + 10 phút; expiry không tự xóa guard khi broker cleanup còn thiếu proof."},
    "firmware_upload_attempts": {"state": "Kết quả lượt upload UPLOADED/VERIFIED/REJECTED; lần reject không chiếm canonical package identity.", "expires_at": "Mốc created_at + 24 giờ cho artifact upload tạm theo policy; cleanup vẫn phải kiểm reference/lease còn hoạt động."},
    "ota_jobs": {"state": "Vòng đời OTA từ QUEUED tới dispatch/download/verify/reboot/health và terminal hoặc RECOVERY_REQUIRED; recovery vẫn giữ slot.", "deadline_at": "Deadline admitted_at + 10 phút của ý định OTA; hết deadline không tự settlement nếu chưa biết image/board state."},
    "ota_download_tickets": {"expires_at": "Hạn bearer download ticket phải sau issued_at và không vượt deadline của OTA job; không reset khi tải lại."},
    "ota_probe_intents": {"state": "Trạng thái probe INTENT/SENT/REPLIED/UNKNOWN; missing reply không cho reset budget hoặc suy đã rollback."},
    "api_keys": {"expires_at": "Deadline API key theo admission policy 1..90 ngày, một ngày=86400 giây theo contract; backend phải validate input trước issue."},
    "webhook_deliveries": {"kind": "BUSINESS có occurrence nguồn và budget 6+6; TEST không có occurrence/Event giả, chỉ một lần gửi trong 30 giây.", "state": "Tiến trình PENDING/SENDING/RETRY_WAIT hoặc ACCEPTED/FAILED/DEAD_LETTER/CANCELLED; DEAD_LETTER có thể mở đúng một manual batch đủ điều kiện.", "expires_at": "BUSINESS neo occurrence.committed_at +24 giờ; TEST neo admitted_at +30 giây, độc lập history retention 30 ngày."},
    "webhook_delivery_attempts": {"outcome": "Kết quả quan sát của một HTTP send intent, không tự chứng minh receiver chưa xử lý khi response bị mất."},
}

# View có cùng projection cột với bảng nguồn; mô tả cột được dùng lại và vẫn recheck quyền ở backend.
HISTORY_VIEWS = {
    "telemetry_history": ("telemetry_points", "View lịch sử telemetry trong cutoff raw 7 ngày, không chờ cron purge; không tự cấp quyền đọc ngoài workspace."),
    "audit_history": ("audit_events", "View audit trong cutoff 30 ngày; global audit vẫn cần policy riêng, không tự cho Admin workspace xem mọi log."),
    "execution_history": ("rule_executions", "View lịch sử execution trong cutoff 30 ngày; operational guard chưa giải quyết vẫn giữ ở ledger gốc."),
    "push_delivery_history": ("push_deliveries", "View lịch sử push trong cutoff 30 ngày từ created_at, khác hạn gửi 1 giờ."),
    "webhook_delivery_history": ("webhook_deliveries", "View lịch sử webhook trong cutoff 30 ngày từ admitted_at, khác expiry BUSINESS/TEST."),
}


# Không fallback từ tên cột: thêm relation/attribute mới phải có nghĩa nghiệp vụ được review.
def documented_relations(manifest):
    """Tạo dictionary đầy đủ cho bảng nghiệp vụ, ledger và history view.
    Input
    Param: manifest — danh sách bảng/cột canonical đã đối chiếu engine và source.
    Output: mapping schema.relation tới loại object, purpose và công dụng từng cột.
    Errors: ValueError nếu thiếu mô tả hoặc tên không thuộc namespace được phép.
    """
    result = {}
    for table in manifest["tables"]:
        name = table["name"]
        if not re.fullmatch(r"[a-z_][a-z0-9_]*", name) or name not in TABLE_DESCRIPTIONS:
            raise ValueError("Missing or invalid documented table: " + name)
        columns = {}
        for column in table["columns"]:
            column_name = column["name"]
            description = COLUMN_OVERRIDES.get(name, {}).get(column_name, COLUMN_DESCRIPTIONS.get(column_name))
            if not re.fullmatch(r"[a-z_][a-z0-9_]*", column_name) or not description:
                raise ValueError("Missing column purpose: " + name + "." + column_name)
            columns[column_name] = description
        result["public." + name] = {"kind": "TABLE", "description": TABLE_DESCRIPTIONS[name], "columns": columns}
    ledger = "migration_control.applied_migrations"
    result[ledger] = {"kind": "TABLE", "description": TABLE_DESCRIPTIONS[ledger],
                      "columns": {name: COLUMN_DESCRIPTIONS[name] for name in ("version", "checksum", "applied_at")}}
    for view_name, (source_name, description) in HISTORY_VIEWS.items():
        if "public." + source_name in result:
            result["public." + view_name] = {"kind": "VIEW", "description": description,
                                              "columns": dict(result["public." + source_name]["columns"])}
    return result


# COMMENT dùng literal SQL được escape, không ghép text mô tả thành identifier hoặc psql command.
def render_comments_migration(manifest):
    """Sinh forward migration thuần metadata, không đổi row/constraint/permission.
    Input
    Param: manifest — metadata của schema cần chú thích.
    Output: SQL COMMENT ON TABLE/VIEW/COLUMN với mô tả tiếng Việt và literal được quote.
    """
    lines = ["""/* Chú thích công dụng bảng/cột của database canonical bằng tiếng Việt.
 * Chỉ metadata: COMMENT lấy SHARE UPDATE EXCLUSIVE trên object, không backfill/xóa row.
 * Áp sau0011 trong transaction của runner; không sửa checksum migration đã áp.
 * Comment không chứa secret và không được dùng thay validation/authorization nghiệp vụ.
 */"""]
    for relation_name, relation in sorted(documented_relations(manifest).items()):
        description = relation["description"].replace("'", "''")
        lines.append(f"\n/* Công dụng của {relation_name}. */")
        lines.append(f"COMMENT ON {relation['kind']} {relation_name} IS '{description}';")
        for column_name, column_description in relation["columns"].items():
            description = column_description.replace("'", "''")
            lines.append(f"COMMENT ON COLUMN {relation_name}.{column_name} IS '{description}';")
    return "\n".join(lines) + "\n"


# Bản schema dễ đọc là artifact sinh từ pg_dump; numbered migration đã áp giữ nguyên byte.
def annotate_snapshot(snapshot, manifest):
    """Thêm purpose trước CREATE TABLE/VIEW và comment ngay trước từng column definition.
    Input
    Param: snapshot — schema-only dump có native COMMENT ON của engine.
    Param: manifest — dictionary để mô tả đúng công dụng từng relation/cột.
    Output: SQL cùng hành vi restore, chỉ thêm block/line comment để đọc trong IDE.
    """
    descriptions = documented_relations(manifest)
    lines = []
    current_relation = None
    for line in snapshot.splitlines():
        create = re.match(r"CREATE (TABLE|VIEW) ([a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*)\b", line)
        if create:
            current_relation = create[2] if create[1] == "TABLE" else None
            if create[2] in descriptions:
                description = descriptions[create[2]]["description"].replace("*/", "* /")
                lines.append("/* " + create[2])
                lines.extend(" * " + part for part in textwrap.wrap(description, width=100))
                lines.append(" */")
        if current_relation and line == ");":
            current_relation = None
        # pg_dump quote tên như "position"; bỏ quote khi lookup nhưng giữ nguyên dòng DDL xuất ra.
        column = re.match(r'^(\s+)"?([a-z_][a-z0-9_]*)"?\s+', line) if current_relation else None
        if column and current_relation in descriptions and column[2] in descriptions[current_relation]["columns"]:
            description = descriptions[current_relation]["columns"][column[2]]
            lines.extend(column[1] + "-- " + part for part in textwrap.wrap(description, width=100))
        lines.append(line)
    return "\n".join(lines) + "\n"


# Fingerprint có cả purpose/công dụng cột, không để restore mất comments mà vẫn báo hash khớp.
COMMENTS_FINGERPRINT_SQL = """
/* Chỉ pg_description metadata; không đọc giá trị ứng dụng hoặc ciphertext. */
WITH description_entries(entry) AS (
 SELECT namespace.nspname||'.'||relation.relname||':table:'||coalesce(obj_description(relation.oid,'pg_class'),'')
 FROM pg_class relation JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
 WHERE namespace.nspname IN ('public','migration_control') AND relation.relkind IN ('r','p','v')
 UNION ALL
 SELECT namespace.nspname||'.'||relation.relname||':column:'||attribute.attname||':'||coalesce(col_description(relation.oid,attribute.attnum),'')
 FROM pg_class relation JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
 JOIN pg_attribute attribute ON attribute.attrelid=relation.oid AND attribute.attnum>0 AND NOT attribute.attisdropped
 WHERE namespace.nspname IN ('public','migration_control') AND relation.relkind IN ('r','p','v')
)
SELECT md5(string_agg(entry,E'\\n' ORDER BY entry)) FROM description_entries;
"""


# So exact text và tập cột, không chỉ kiểm comment khác NULL hoặc tự nhận coverage từ file SQL.
def verify_native_comments(sql, manifest):
    """Kiểm chú thích thực sự lưu trong PostgreSQL của mọi bảng/cột/view canonical.
    Input
    Param: sql — adapter metadata trên đúng DB đã định danh.
    Param: manifest — danh sách relation và ý nghĩa được review.
    Output: số bảng/view/cột có mô tả khớp hoàn toàn.
    Errors: RuntimeError nếu thiếu, thừa hoặc text comment sai; không coi partial coverage là PASS.
    """
    expected = documented_relations(manifest)
    # Identifier lấy từ pg_catalog; nội dung trả về chỉ description metadata, không row nghiệp vụ.
    query = """SELECT jsonb_object_agg(relation_name,description) FROM (
     SELECT namespace.nspname||'.'||relation.relname AS relation_name,
       jsonb_build_object('kind',CASE WHEN relation.relkind='v' THEN 'VIEW' ELSE 'TABLE' END,
         'description',obj_description(relation.oid,'pg_class'),
         'columns',(SELECT jsonb_object_agg(attribute.attname,col_description(relation.oid,attribute.attnum))
          FROM pg_attribute attribute WHERE attribute.attrelid=relation.oid AND attribute.attnum>0 AND NOT attribute.attisdropped)) AS description
     FROM pg_class relation JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
     WHERE relation.relkind IN ('r','p','v') AND
       (namespace.nspname='public' OR(namespace.nspname='migration_control' AND relation.relname='applied_migrations'))
    ) documented;"""
    actual = json.loads(sql(query).stdout)
    mismatches = sorted(name for name in set(expected) | set(actual) if expected.get(name) != actual.get(name))
    if mismatches:
        raise RuntimeError("Database documentation differs for: " + ", ".join(mismatches))
    return {"table_count": sum(relation["kind"] == "TABLE" for relation in expected.values()),
            "view_count": sum(relation["kind"] == "VIEW" for relation in expected.values()),
            "table_column_count": sum(len(relation["columns"]) for relation in expected.values() if relation["kind"] == "TABLE"),
            "view_column_count": sum(len(relation["columns"]) for relation in expected.values() if relation["kind"] == "VIEW")}
