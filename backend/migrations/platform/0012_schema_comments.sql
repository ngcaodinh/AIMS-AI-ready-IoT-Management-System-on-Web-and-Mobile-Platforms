/* Chú thích công dụng bảng/cột của database canonical bằng tiếng Việt.
 * Chỉ metadata: COMMENT lấy SHARE UPDATE EXCLUSIVE trên object, không backfill/xóa row.
 * Áp sau0011 trong transaction của runner; không sửa checksum migration đã áp.
 * Comment không chứa secret và không được dùng thay validation/authorization nghiệp vụ.
 */

/* Công dụng của migration_control.applied_migrations. */
COMMENT ON TABLE migration_control.applied_migrations IS 'Lịch sử phiên bản migration và SHA-256 source đã áp trong database này. Runner ghi cùng transaction DDL để chạy lại an toàn và từ chối checksum drift; không phải dữ liệu nghiệp vụ.';
COMMENT ON COLUMN migration_control.applied_migrations.version IS 'Identity phiên bản migration ổn định trong ledger, không tự đổi tên hoặc tái áp bằng nội dung khác.';
COMMENT ON COLUMN migration_control.applied_migrations.checksum IS 'SHA-256 hex của byte source migration đã áp; runner so exact checksum và từ chối drift thay vì hợp thức hóa history.';
COMMENT ON COLUMN migration_control.applied_migrations.applied_at IS 'Thời điểm runner ghi migration đã áp cùng transaction DDL; không là timestamp tạo file hoặc thời gian sửa source.';

/* Công dụng của public.action_executions. */
COMMENT ON TABLE public.action_executions IS 'Trạng thái từng action trong một execution, gắn đúng rule version và action_position. Giữ command backlink và lý do kết thúc để coordinator quyết định bước kế.';
COMMENT ON COLUMN public.action_executions.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.action_executions.rule_execution_id IS 'Identity một lần quyết định/chạy rule version, dùng quota, history, action chain và notification target.';
COMMENT ON COLUMN public.action_executions.action_position IS 'Chỉ số action bắt đầu 0 trong chuỗi tối đa 5 bước, dùng ghép definition/action execution/job.';
COMMENT ON COLUMN public.action_executions.action_execution_id IS 'Identity ổn định của một action runtime; unique command theo identity này ngăn retry tạo lệnh vật lý thứ hai.';
COMMENT ON COLUMN public.action_executions.rule_version_id IS 'Identity rule snapshot đã publish, dùng pin trigger/action/execution thay vì đọc draft hiện hành.';
COMMENT ON COLUMN public.action_executions.state IS 'Trạng thái từng bước BLOCKED/READY/WAITING/DISPATCHING/AWAITING_RESULT/SUCCEEDED/FAILED/CANCELLED/NEEDS_ATTENTION; UNKNOWN không tự unblock bước sau.';
COMMENT ON COLUMN public.action_executions.started_at IS 'Thời điểm bắt đầu boot/enrollment/action hoặc hoạt động tương ứng, tùy ngữ nghĩa bảng.';
COMMENT ON COLUMN public.action_executions.ended_at IS 'Thời điểm execution/action kết thúc; NULL khi chưa ghi nhận kết thúc, outcome/state là trục kết quả riêng.';
COMMENT ON COLUMN public.action_executions.command_id IS 'Identity command ổn định qua retry/result/reconciliation; không tạo command mới chỉ vì mất response.';
COMMENT ON COLUMN public.action_executions.reason_code IS 'Mã nguyên nhân ổn định để giải thích kết quả/transition; phải là nội dung an toàn, không chứa raw lỗi/secret.';

/* Công dụng của public.action_jobs. */
COMMENT ON TABLE public.action_jobs IS 'Công việc bền vững tương ứng từng action, gồm dueAt, lease và retry counter. WAIT dùng thời điểm tuyệt đối trong DB; worker không giữ timer RAM làm nguồn sự thật.';
COMMENT ON COLUMN public.action_jobs.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.action_jobs.rule_execution_id IS 'Identity một lần quyết định/chạy rule version, dùng quota, history, action chain và notification target.';
COMMENT ON COLUMN public.action_jobs.action_position IS 'Chỉ số action bắt đầu 0 trong chuỗi tối đa 5 bước, dùng ghép definition/action execution/job.';
COMMENT ON COLUMN public.action_jobs.state IS 'Trạng thái công việc tương ứng action execution; chỉ một READY/execution, due_at và lease quyết định khi worker được claim.';
COMMENT ON COLUMN public.action_jobs.due_at IS 'Thời điểm tuyệt đối UTC mà job/lượt WAIT được phép đến hạn; timer RAM chỉ đánh thức worker, không thay mốc này.';
COMMENT ON COLUMN public.action_jobs.lease_until IS 'Hạn thuê xử lý hiện hành của worker; lease hết không chứng minh network side effect chưa xảy ra.';
COMMENT ON COLUMN public.action_jobs.lease_generation IS 'Thế hệ lease tăng khi claim/takeover, dùng CAS để worker cũ không settle kết quả của thế hệ mới.';
COMMENT ON COLUMN public.action_jobs.attempt_count IS 'Số lần xử lý/claim đã tiêu hao theo pipeline; không tự coi một lần retry là một ý định nghiệp vụ mới.';

/* Công dụng của public.actuator_states. */
COMMENT ON TABLE public.actuator_states IS 'Trạng thái một kênh điều khiển của thiết bị, gồm manual epoch và giá trị được thiết bị báo. Có thể giữ command chưa đối soát; không coi giá trị người dùng yêu cầu là reported truth.';
COMMENT ON COLUMN public.actuator_states.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.actuator_states.device_id IS 'Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng tenant.';
COMMENT ON COLUMN public.actuator_states.stream_key IS 'Khóa kỹ thuật ổn định của kênh trong template/version; không dùng nhãn hiển thị thay khóa schema.';
COMMENT ON COLUMN public.actuator_states.pinned_template_version_id IS 'Template version cố định của device/actuator, lặp để FK kiểm stream đúng pin thay vì chỉ đúng tên kênh.';
COMMENT ON COLUMN public.actuator_states.manual_epoch IS 'Bộ đếm thao tác điều khiển thủ công/integration làm thay đổi ưu tiên actuator; dùng ngăn automation cũ ghi đè thao tác mới.';
COMMENT ON COLUMN public.actuator_states.last_reported_value IS 'Giá trị đầu ra được thiết bị xác nhận gần nhất; không cập nhật thành target chỉ vì command đã admission.';
COMMENT ON COLUMN public.actuator_states.last_reported_at IS 'Thời điểm của reported observation gần nhất được chấp nhận, phục vụ hiển thị độ mới của trạng thái đầu ra.';
COMMENT ON COLUMN public.actuator_states.reported_source IS 'Nguồn của reported value NONE/DEVICE_RESULT/TELEMETRY/HELLO để phân biệt bằng chứng thiết bị với giá trị người dùng yêu cầu.';
COMMENT ON COLUMN public.actuator_states.unresolved_command_id IS 'Command còn cần đối soát trên actuator; NULL khi không giữ guard này, không tự chứng minh physical output an toàn.';

/* Công dụng của public.api_key_devices. */
COMMENT ON TABLE public.api_key_devices IS 'Allowlist thiết bị được API key cấp quyền, tối đa 5 theo admission policy. Đây là tập độc lập với scopes, không lưu tích Descartes device×permission.';
COMMENT ON COLUMN public.api_key_devices.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.api_key_devices.api_key_id IS 'Identity principal API key toàn cục, dùng resolve workspace trước kiểm quyền; không chứa raw key secret.';
COMMENT ON COLUMN public.api_key_devices.device_id IS 'Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng tenant.';

/* Công dụng của public.api_key_scopes. */
COMMENT ON TABLE public.api_key_scopes IS 'Các permission được cấp cho API key theo allowlist scope code. Không suy thêm quyền quản trị từ scope đọc telemetry hoặc điều khiển thiết bị.';
COMMENT ON COLUMN public.api_key_scopes.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.api_key_scopes.api_key_id IS 'Identity principal API key toàn cục, dùng resolve workspace trước kiểm quyền; không chứa raw key secret.';
COMMENT ON COLUMN public.api_key_scopes.scope_code IS 'Permission API key từ allowlist devices:read/telemetry:read/commands:write; không chứa quyền admin ngầm định.';

/* Công dụng của public.api_keys. */
COMMENT ON TABLE public.api_keys IS 'Principal API key có lookup ID toàn cục nhưng quyền chỉ trong một workspace. Chụp grant của owner, lưu protected verifier/expiry/revocation; không lưu raw secret để đọc lại.';
COMMENT ON COLUMN public.api_keys.api_key_id IS 'Identity principal API key toàn cục, dùng resolve workspace trước kiểm quyền; không chứa raw key secret.';
COMMENT ON COLUMN public.api_keys.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.api_keys.owner_user_id IS 'Tài khoản sở hữu tài nguyên trong workspace; backend phải kiểm membership và quyền hiện hành khi đọc/ghi.';
COMMENT ON COLUMN public.api_keys.owner_grant_generation IS 'Grant owner được chụp khi cấp API key; request sau này phải giao với quyền/grant hiện hành.';
COMMENT ON COLUMN public.api_keys.verifier_digest IS 'Bộ kiểm chứng mật 32 byte dùng xác thực credential/API key theo protected-verifier contract; không là raw secret và không trả client/log.';
COMMENT ON COLUMN public.api_keys.name IS 'Tên hiển thị do người dùng đặt cho tài nguyên; không dùng làm identity, quyền hoặc khóa chống lặp.';
COMMENT ON COLUMN public.api_keys.prefix IS 'Phần nhận diện không nhạy cảm của API key để hiển thị/quản trị; không đủ xác thực và không thay secret.';
COMMENT ON COLUMN public.api_keys.issued_at IS 'Thời điểm phát hành phiên/grant/credential/ticket, làm gốc tính TTL theo loại bản ghi.';
COMMENT ON COLUMN public.api_keys.expires_at IS 'Deadline API key theo admission policy 1..90 ngày, một ngày=86400 giây theo contract; backend phải validate input trước issue.';
COMMENT ON COLUMN public.api_keys.revoked_at IS 'Thời điểm thu hồi quyền/credential; NULL nghĩa chưa ghi nhận thu hồi, không đồng nghĩa mọi điều kiện xác thực khác còn hợp lệ.';
COMMENT ON COLUMN public.api_keys.last_used_at IS 'Mốc request hợp lệ gần nhất được key chấp nhận theo policy; update đến trễ không được làm lùi mốc hoặc hồi sinh key revoked.';
COMMENT ON COLUMN public.api_keys.revision IS 'Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng transaction contract.';

/* Công dụng của public.audit_events. */
COMMENT ON TABLE public.audit_events IS 'Nhật ký kiểm toán ai làm gì, ở đâu và kết quả ra sao. Hỗ trợ sự kiện IAM toàn cục với workspace NULL, giữ tương quan request; chỉ lưu phần thay đổi đã loại bỏ dữ liệu nhạy cảm.';
COMMENT ON COLUMN public.audit_events.audit_event_id IS 'Identity duy nhất của một bản ghi kiểm toán, dùng phân trang và tương quan lịch sử.';
COMMENT ON COLUMN public.audit_events.workspace_id IS 'Workspace của sự kiện kiểm toán; NULL chỉ cho IAM/global audit, không được fanout global log cho Admin workspace.';
COMMENT ON COLUMN public.audit_events.actor_user_id IS 'Principal thực hiện thao tác; NULL cho anonymous/system event hợp lệ, nhưng có session_id thì actor phải đúng chủ phiên.';
COMMENT ON COLUMN public.audit_events.session_id IS 'Identity một phiên đăng nhập; dùng gắn thao tác hoặc ticket với đúng principal, không phải raw token xác thực.';
COMMENT ON COLUMN public.audit_events.event_type IS 'Loại sự kiện được audit/outbox/webhook sử dụng; ý nghĩa/allowlist phụ thuộc bảng và schema contract.';
COMMENT ON COLUMN public.audit_events.outcome IS 'Kết quả kiểm toán của thao tác như thành công/từ chối/lỗi theo event contract; không mặc định là trạng thái command vật lý.';
COMMENT ON COLUMN public.audit_events.resource_type IS 'Loại resource được audit chụp lại; đi cùng resource_id như snapshot lịch sử, không là authority hoặc FK đa hình để cấp quyền.';
COMMENT ON COLUMN public.audit_events.resource_id IS 'Identity resource được audit chụp ở thời điểm thao tác; có thể không còn live resource sau retention nhưng không cấp quyền truy cập.';
COMMENT ON COLUMN public.audit_events.correlation_id IS 'Identity tương quan request/flow để nối audit và intent/result; không chứa raw token, email hoặc payload nhạy cảm.';
COMMENT ON COLUMN public.audit_events.occurred_at IS 'Thời điểm nghiệp vụ/sự kiện diễn ra để sắp xếp timeline; không mặc định bằng thời điểm fanout hoặc provider phản hồi.';
COMMENT ON COLUMN public.audit_events.reason_code IS 'Mã nguyên nhân ổn định để giải thích kết quả/transition; phải là nội dung an toàn, không chứa raw lỗi/secret.';
COMMENT ON COLUMN public.audit_events.redacted_diff IS 'Phần thay đổi metadata đã loại bỏ secret/PII theo audit policy; producer chịu trách nhiệm chọn trường trước ghi JSON.';
COMMENT ON COLUMN public.audit_events.client_type IS 'Loại client khởi tạo phiên/thao tác; enum của từng bảng phân biệt WEB, ANDROID và UNKNOWN khi được phép.';

/* Công dụng của public.audit_history. */
COMMENT ON VIEW public.audit_history IS 'View audit trong cutoff 30 ngày; global audit vẫn cần policy riêng, không tự cho Admin workspace xem mọi log.';
COMMENT ON COLUMN public.audit_history.audit_event_id IS 'Identity duy nhất của một bản ghi kiểm toán, dùng phân trang và tương quan lịch sử.';
COMMENT ON COLUMN public.audit_history.workspace_id IS 'Workspace của sự kiện kiểm toán; NULL chỉ cho IAM/global audit, không được fanout global log cho Admin workspace.';
COMMENT ON COLUMN public.audit_history.actor_user_id IS 'Principal thực hiện thao tác; NULL cho anonymous/system event hợp lệ, nhưng có session_id thì actor phải đúng chủ phiên.';
COMMENT ON COLUMN public.audit_history.session_id IS 'Identity một phiên đăng nhập; dùng gắn thao tác hoặc ticket với đúng principal, không phải raw token xác thực.';
COMMENT ON COLUMN public.audit_history.event_type IS 'Loại sự kiện được audit/outbox/webhook sử dụng; ý nghĩa/allowlist phụ thuộc bảng và schema contract.';
COMMENT ON COLUMN public.audit_history.outcome IS 'Kết quả kiểm toán của thao tác như thành công/từ chối/lỗi theo event contract; không mặc định là trạng thái command vật lý.';
COMMENT ON COLUMN public.audit_history.resource_type IS 'Loại resource được audit chụp lại; đi cùng resource_id như snapshot lịch sử, không là authority hoặc FK đa hình để cấp quyền.';
COMMENT ON COLUMN public.audit_history.resource_id IS 'Identity resource được audit chụp ở thời điểm thao tác; có thể không còn live resource sau retention nhưng không cấp quyền truy cập.';
COMMENT ON COLUMN public.audit_history.correlation_id IS 'Identity tương quan request/flow để nối audit và intent/result; không chứa raw token, email hoặc payload nhạy cảm.';
COMMENT ON COLUMN public.audit_history.occurred_at IS 'Thời điểm nghiệp vụ/sự kiện diễn ra để sắp xếp timeline; không mặc định bằng thời điểm fanout hoặc provider phản hồi.';
COMMENT ON COLUMN public.audit_history.reason_code IS 'Mã nguyên nhân ổn định để giải thích kết quả/transition; phải là nội dung an toàn, không chứa raw lỗi/secret.';
COMMENT ON COLUMN public.audit_history.redacted_diff IS 'Phần thay đổi metadata đã loại bỏ secret/PII theo audit policy; producer chịu trách nhiệm chọn trường trước ghi JSON.';
COMMENT ON COLUMN public.audit_history.client_type IS 'Loại client khởi tạo phiên/thao tác; enum của từng bảng phân biệt WEB, ANDROID và UNKNOWN khi được phép.';

/* Công dụng của public.command_evidence. */
COMMENT ON TABLE public.command_evidence IS 'Bằng chứng quan sát muộn hoặc mâu thuẫn của command. Ghi bổ sung vào timeline thay vì sửa terminal outcome hoặc tự phát lại thao tác vật lý.';
COMMENT ON COLUMN public.command_evidence.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.command_evidence.command_evidence_id IS 'Identity một bằng chứng command bổ sung để liên kết resolution và timeline quan sát.';
COMMENT ON COLUMN public.command_evidence.command_id IS 'Identity command ổn định qua retry/result/reconciliation; không tạo command mới chỉ vì mất response.';
COMMENT ON COLUMN public.command_evidence.evidence_type IS 'Loại bằng chứng command LATE_RESULT/CONFLICTING_RESULT/DEVICE_OBSERVATION để không nhầm quan sát với terminal truth.';
COMMENT ON COLUMN public.command_evidence.received_at IS 'Thời điểm server nhận gói dữ liệu/kết quả; phân biệt với observed_at do thiết bị hoặc nguồn sự kiện cung cấp.';
COMMENT ON COLUMN public.command_evidence.payload_digest IS 'SHA-256 32 byte của payload đã chấp nhận, phục vụ dedupe và phát hiện cùng identity nhưng body mâu thuẫn.';
COMMENT ON COLUMN public.command_evidence.sanitized_payload IS 'Payload quan sát đã được producer loại trường nhạy cảm, dùng audit/đối soát; SQL JSON type không tự làm redaction.';

/* Công dụng của public.command_resolutions. */
COMMENT ON TABLE public.command_resolutions IS 'Trục xử lý/đối soát command UNKNOWN: ghi nhận ACK thủ công hoặc bằng chứng thiết bị muộn. Không đồng nhất resolution với kết quả thực thi ban đầu.';
COMMENT ON COLUMN public.command_resolutions.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.command_resolutions.command_id IS 'Identity command ổn định qua retry/result/reconciliation; không tạo command mới chỉ vì mất response.';
COMMENT ON COLUMN public.command_resolutions.resolution_status IS 'Tình trạng đối soát UNKNOWN: UNRESOLVED/ACKNOWLEDGED_UNKNOWN/DEVICE_CONFIRMED_LATE, độc lập command outcome.';
COMMENT ON COLUMN public.command_resolutions.resolved_by_user_id IS 'Thành viên thực hiện đối soát hoặc xác nhận thủ công; NULL khi chưa có người xử lý theo nhánh resolution.';
COMMENT ON COLUMN public.command_resolutions.resolved_at IS 'Mốc ghi nhận resolution ACK/late device proof; không viết lại terminal_at hoặc outcome của command gốc.';
COMMENT ON COLUMN public.command_resolutions.manual_observation IS 'Quan sát do người dùng khai lúc ACK UNKNOWN; không được ghi đè reported value từ thiết bị hoặc coi là device proof.';
COMMENT ON COLUMN public.command_resolutions.device_evidence_id IS 'Bằng chứng thuộc chính command được dùng cho DEVICE_CONFIRMED_LATE; không nhận evidence của command khác.';
COMMENT ON COLUMN public.command_resolutions.reason_code IS 'Mã nguyên nhân ổn định để giải thích kết quả/transition; phải là nội dung an toàn, không chứa raw lỗi/secret.';

/* Công dụng của public.command_result_receipts. */
COMMENT ON TABLE public.command_result_receipts IS 'Kết quả MQTT từng phase của command đã được xác minh theo device/boot/credential. Khóa phase và digest phục vụ nhận trùng, không ghi đè kết quả đã chấp nhận.';
COMMENT ON COLUMN public.command_result_receipts.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.command_result_receipts.command_id IS 'Identity command ổn định qua retry/result/reconciliation; không tạo command mới chỉ vì mất response.';
COMMENT ON COLUMN public.command_result_receipts.result_phase IS 'Phase result ACCEPTED/SUCCEEDED/FAILED của command; ACCEPTED không phải kết quả vật lý thành công.';
COMMENT ON COLUMN public.command_result_receipts.device_id IS 'Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng tenant.';
COMMENT ON COLUMN public.command_result_receipts.boot_id IS 'Identity boot của thiết bị theo wire dạng text, không suy UUID; chỉ chấp nhận khi gắn với credential/connection đã xác minh.';
COMMENT ON COLUMN public.command_result_receipts.credential_generation IS 'Thế hệ credential MQTT của thiết bị, phân biệt lần cấp mới với credential cũ đã thu hồi.';
COMMENT ON COLUMN public.command_result_receipts.payload_digest IS 'SHA-256 32 byte của payload đã chấp nhận, phục vụ dedupe và phát hiện cùng identity nhưng body mâu thuẫn.';
COMMENT ON COLUMN public.command_result_receipts.received_at IS 'Thời điểm server nhận gói dữ liệu/kết quả; phân biệt với observed_at do thiết bị hoặc nguồn sự kiện cung cấp.';
COMMENT ON COLUMN public.command_result_receipts.result_snapshot IS 'Snapshot result đã xác thực và redact, dùng dedupe/đối soát; không thay quyền hiện hành khi hiển thị.';

/* Công dụng của public.commands. */
COMMENT ON TABLE public.commands IS 'Ledger mỗi lần nhận yêu cầu điều khiển: nguồn lệnh, giá trị đích, deadline và kết quả vật lý. Tách admission/dispatch khỏi terminal outcome; UNKNOWN không được biến thành thành công chỉ vì có ACK thủ công.';
COMMENT ON COLUMN public.commands.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.commands.command_id IS 'Identity command ổn định qua retry/result/reconciliation; không tạo command mới chỉ vì mất response.';
COMMENT ON COLUMN public.commands.device_id IS 'Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng tenant.';
COMMENT ON COLUMN public.commands.stream_key IS 'Khóa kỹ thuật ổn định của kênh trong template/version; không dùng nhãn hiển thị thay khóa schema.';
COMMENT ON COLUMN public.commands.origin_type IS 'Nguồn command MANUAL/AUTOMATION/INTEGRATION, quyết định actor/user, action execution hoặc API key phải có.';
COMMENT ON COLUMN public.commands.actor_user_id IS 'Người phát lệnh MANUAL; phải NULL cho AUTOMATION/INTEGRATION vì hai nguồn đó có principal typed riêng.';
COMMENT ON COLUMN public.commands.api_key_id IS 'Identity principal API key toàn cục, dùng resolve workspace trước kiểm quyền; không chứa raw key secret.';
COMMENT ON COLUMN public.commands.action_execution_id IS 'Identity ổn định của một action runtime; unique command theo identity này ngăn retry tạo lệnh vật lý thứ hai.';
COMMENT ON COLUMN public.commands.value_type IS 'Nhánh kiểu dữ liệu của giá trị được lưu; XOR chọn đúng cột numeric/boolean/text và phải khớp pinned definition.';
COMMENT ON COLUMN public.commands.numeric_value IS 'Giá trị số hữu hạn của nhánh NUMBER hoặc ENUM số; NULL khi dùng nhánh giá trị khác hoặc quality NULL.';
COMMENT ON COLUMN public.commands.boolean_value IS 'Giá trị boolean của nhánh BOOLEAN; false là dữ liệu thật, không tương đương NULL/missing.';
COMMENT ON COLUMN public.commands.text_value IS 'Giá trị chuỗi của nhánh STRING hoặc ENUM chuỗi; không chuyển mọi datatype thành text để bỏ kiểm kiểu.';
COMMENT ON COLUMN public.commands.state IS 'Tiến trình command từ ADMITTED qua dispatch tới terminal; transition được guard, không nhảy thẳng admission thành success.';
COMMENT ON COLUMN public.commands.outcome IS 'Kết quả vật lý PENDING/SUCCEEDED/FAILED/UNKNOWN; TIMED_OUT giữ UNKNOWN kể cả sau ACK thủ công hoặc thêm late evidence.';
COMMENT ON COLUMN public.commands.admitted_at IS 'Thời điểm yêu cầu được backend nhận vào ledger sau kiểm điều kiện; không chứng minh side effect đã thực hiện.';
COMMENT ON COLUMN public.commands.deadline_at IS 'Deadline cố định admitted_at + 10 giây; command đã có khả năng dispatch mà hết hạn không được blind retry.';
COMMENT ON COLUMN public.commands.dispatch_intent_at IS 'Thời điểm lưu ý định dispatch command trước network; dùng phân biệt chưa gửi với đã có khả năng tác động vật lý.';
COMMENT ON COLUMN public.commands.terminal_at IS 'Thời điểm quan sát trạng thái kết thúc của command/delivery; không thay gốc expiry hoặc gốc retention.';
COMMENT ON COLUMN public.commands.manual_epoch_snapshot IS 'Manual epoch chụp khi command admission, để kiểm command/automation không dựa vào quyền điều khiển đã lỗi thời.';
COMMENT ON COLUMN public.commands.revision IS 'Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng transaction contract.';

/* Công dụng của public.connectivity_transitions. */
COMMENT ON TABLE public.connectivity_transitions IS 'Nhật ký từng chuyển trạng thái kết nối thực sự của thiết bị. Sequence ổn định giúp rule và webhook chống tạo sự kiện trùng từ heartbeat hoặc hello lặp.';
COMMENT ON COLUMN public.connectivity_transitions.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.connectivity_transitions.device_id IS 'Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng tenant.';
COMMENT ON COLUMN public.connectivity_transitions.transition_sequence IS 'Số thứ tự chuyển presence thực sự của thiết bị, bắt đầu lớn hơn 0; heartbeat trùng không tạo transition mới.';
COMMENT ON COLUMN public.connectivity_transitions.connection_generation IS 'Thế hệ kết nối đã xác minh của device, dùng loại sự kiện/reply từ kết nối cũ.';
COMMENT ON COLUMN public.connectivity_transitions.from_state IS 'Trạng thái presence trước chuyển đổi, dùng đối chiếu edge thực tế và giải thích trigger connectivity.';
COMMENT ON COLUMN public.connectivity_transitions.to_state IS 'Trạng thái presence sau chuyển đổi, phải khác from_state; không tự thay lifecycle ACTIVE/SUSPENDED.';
COMMENT ON COLUMN public.connectivity_transitions.observed_at IS 'Thời điểm quan sát được dữ liệu/kết quả; nguồn và ý nghĩa được quy định theo bảng, không mặc định là thời gian commit.';
COMMENT ON COLUMN public.connectivity_transitions.boot_id IS 'Identity boot của thiết bị theo wire dạng text, không suy UUID; chỉ chấp nhận khi gắn với credential/connection đã xác minh.';

/* Công dụng của public.dashboard_widget_bindings. */
COMMENT ON TABLE public.dashboard_widget_bindings IS 'Liên kết từng slot widget với thiết bị và kênh đã pin. Presence binding có thể không có stream; FK và shape bảo vệ tham chiếu trong đúng workspace/version.';
COMMENT ON COLUMN public.dashboard_widget_bindings.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.dashboard_widget_bindings.dashboard_id IS 'Identity dashboard trong workspace, dùng nhóm widget và kiểm owner/revision khi lưu cấu hình.';
COMMENT ON COLUMN public.dashboard_widget_bindings.widget_id IS 'Identity widget trong dashboard, giữ binding đúng thành phần dù thay layout hoặc thứ tự mobile.';
COMMENT ON COLUMN public.dashboard_widget_bindings.binding_slot IS 'Tên slot dữ liệu/điều khiển của widget, để một widget có thể liên kết từng nhu cầu với resource đúng scope.';
COMMENT ON COLUMN public.dashboard_widget_bindings.device_id IS 'Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng tenant.';
COMMENT ON COLUMN public.dashboard_widget_bindings.template_version_id IS 'Pin version cho stream binding; cùng NULL với stream_key khi binding là presence của device.';
COMMENT ON COLUMN public.dashboard_widget_bindings.stream_key IS 'Kênh pinned của stream binding; cùng NULL với template_version_id khi slot dùng presence, device_id vẫn bắt buộc.';

/* Công dụng của public.dashboard_widgets. */
COMMENT ON TABLE public.dashboard_widgets IS 'Từng widget trong dashboard: loại hiển thị/điều khiển, thứ tự trên mobile và bố cục grid. Presentation giữ cấu hình của loại widget, không là nơi lưu credential hoặc script tùy ý.';
COMMENT ON COLUMN public.dashboard_widgets.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.dashboard_widgets.dashboard_id IS 'Identity dashboard trong workspace, dùng nhóm widget và kiểm owner/revision khi lưu cấu hình.';
COMMENT ON COLUMN public.dashboard_widgets.widget_id IS 'Identity widget trong dashboard, giữ binding đúng thành phần dù thay layout hoặc thứ tự mobile.';
COMMENT ON COLUMN public.dashboard_widgets.widget_type IS 'Loại widget VALUE/GAUGE/STATUS/SWITCH/BUTTON/CHART; backend còn phải kiểm tương thích datatype/capability và config.';
COMMENT ON COLUMN public.dashboard_widgets.position IS 'Thứ tự widget trên mobile, từ 0 đến 19 và duy nhất trong dashboard; khác tọa độ layout grid Web.';
COMMENT ON COLUMN public.dashboard_widgets.presentation IS 'Cấu hình hiển thị theo loại widget dưới dạng JSON object; không phải nơi lưu resource authority, secret hoặc script tùy ý.';
COMMENT ON COLUMN public.dashboard_widgets.layout_x IS 'Tọa độ cột bắt đầu trong grid Web 12 cột, từ 0 đến 11; phải cộng width không vượt 12.';
COMMENT ON COLUMN public.dashboard_widgets.layout_y IS 'Tọa độ hàng bắt đầu của widget trong grid Web, không âm; khác mobile order.';
COMMENT ON COLUMN public.dashboard_widgets.layout_width IS 'Số cột grid mà widget chiếm, lớn hơn 0; tổng với layout_x phải nằm trong 12 cột.';
COMMENT ON COLUMN public.dashboard_widgets.layout_height IS 'Số đơn vị hàng grid mà widget chiếm, lớn hơn 0; không phải pixel hoặc số mẫu lịch sử.';

/* Công dụng của public.dashboards. */
COMMENT ON TABLE public.dashboards IS 'Gốc dashboard do một thành viên sở hữu, chứa tên, trạng thái và revision. Các widget/binding là dữ liệu con để lưu một cấu hình nguyên tử qua CAS.';
COMMENT ON COLUMN public.dashboards.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.dashboards.dashboard_id IS 'Identity dashboard trong workspace, dùng nhóm widget và kiểm owner/revision khi lưu cấu hình.';
COMMENT ON COLUMN public.dashboards.owner_user_id IS 'Tài khoản sở hữu tài nguyên trong workspace; backend phải kiểm membership và quyền hiện hành khi đọc/ghi.';
COMMENT ON COLUMN public.dashboards.title IS 'Tiêu đề hiển thị của dashboard hoặc sự kiện; là nội dung giao diện, không dùng thay identity tài nguyên.';
COMMENT ON COLUMN public.dashboards.schema_version IS 'Phiên bản cấu trúc document dashboard/rule, hiện 1; khác revision chỉnh sửa và version publish.';
COMMENT ON COLUMN public.dashboards.revision IS 'Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng transaction contract.';
COMMENT ON COLUMN public.dashboards.lifecycle_status IS 'Trạng thái vòng đời quản lý tài nguyên, tách khỏi presence hoặc tiến độ của job đang chạy.';
COMMENT ON COLUMN public.dashboards.created_at IS 'Thời điểm tạo bản ghi dưới dạng timestamptz; dùng provenance/sắp xếp hoặc retention khi policy của bảng quy định.';
COMMENT ON COLUMN public.dashboards.updated_at IS 'Thời điểm cập nhật gần nhất do đường ghi quản lý; không mặc định SQL tự cập nhật nếu không có trigger tương ứng.';

/* Công dụng của public.datastream_capabilities. */
COMMENT ON TABLE public.datastream_capabilities IS 'Capability SET_VALUE cùng safeValue của kênh đã công bố. Cho phép kiểm kênh có thể điều khiển, thay vì suy từ việc stream tồn tại.';
COMMENT ON COLUMN public.datastream_capabilities.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.datastream_capabilities.template_version_id IS 'Identity snapshot template cụ thể, dùng pin schema và kiểm đúng definition trong workspace.';
COMMENT ON COLUMN public.datastream_capabilities.stream_key IS 'Khóa kỹ thuật ổn định của kênh trong template/version; không dùng nhãn hiển thị thay khóa schema.';
COMMENT ON COLUMN public.datastream_capabilities.command_type IS 'Capability lệnh được template công bố, hiện chỉ SET_VALUE; không cho thực thi script hoặc lệnh tùy ý.';
COMMENT ON COLUMN public.datastream_capabilities.safe_value IS 'Literal giá trị an toàn của capability, phải đúng datatype/range/ENUM; đây là cấu hình, không tự gửi lệnh tới thiết bị.';

/* Công dụng của public.datastream_definitions. */
COMMENT ON TABLE public.datastream_definitions IS 'Định nghĩa từng kênh trong template version đã công bố. Là nguồn datatype, mode, đơn vị và giới hạn để kiểm telemetry, binding và giá trị điều khiển theo đúng pin của thiết bị.';
COMMENT ON COLUMN public.datastream_definitions.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.datastream_definitions.template_version_id IS 'Identity snapshot template cụ thể, dùng pin schema và kiểm đúng definition trong workspace.';
COMMENT ON COLUMN public.datastream_definitions.stream_key IS 'Khóa kỹ thuật ổn định của kênh trong template/version; không dùng nhãn hiển thị thay khóa schema.';
COMMENT ON COLUMN public.datastream_definitions.display_name IS 'Nhãn hiển thị của kênh dữ liệu; stream_key vẫn là khóa kỹ thuật ổn định khi nhãn thay đổi.';
COMMENT ON COLUMN public.datastream_definitions.data_type IS 'Kiểu dữ liệu NUMBER/BOOLEAN/STRING/ENUM của definition; validator kiểm literal và giới hạn theo kiểu này.';
COMMENT ON COLUMN public.datastream_definitions.direction IS 'Chiều sử dụng kênh READ/WRITE/READ_WRITE; tồn tại stream không đồng nghĩa có capability điều khiển.';
COMMENT ON COLUMN public.datastream_definitions.unit IS 'Đơn vị đo hiển thị của kênh, ví dụ đơn vị cảm biến; NULL khi đại lượng không có đơn vị theo schema.';
COMMENT ON COLUMN public.datastream_definitions.min_value IS 'Cận dưới cho giá trị NUMBER hữu hạn; NULL nghĩa không khai cận dưới, không mặc định bằng 0.';
COMMENT ON COLUMN public.datastream_definitions.max_value IS 'Cận trên cho giá trị NUMBER hữu hạn; NULL nghĩa không khai cận trên, không tự đặt giới hạn phần cứng.';
COMMENT ON COLUMN public.datastream_definitions.string_max_length IS 'Độ dài tối đa của STRING tính bằng ký tự theo validation hiện hành; NULL khi schema không khai giới hạn này.';

/* Công dụng của public.datastream_enum_values. */
COMMENT ON TABLE public.datastream_enum_values IS 'Các literal ENUM thuộc một kênh của template version đã công bố. Giữ tập giá trị theo phiên bản để dữ liệu cũ không phụ thuộc draft hiện hành.';
COMMENT ON COLUMN public.datastream_enum_values.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.datastream_enum_values.template_version_id IS 'Identity snapshot template cụ thể, dùng pin schema và kiểm đúng definition trong workspace.';
COMMENT ON COLUMN public.datastream_enum_values.stream_key IS 'Khóa kỹ thuật ổn định của kênh trong template/version; không dùng nhãn hiển thị thay khóa schema.';
COMMENT ON COLUMN public.datastream_enum_values.enum_value IS 'Một literal JSON number/string được phép của kênh ENUM; validator còn phải kiểm bộ giá trị và type theo contract.';

/* Công dụng của public.device_boot_sessions. */
COMMENT ON TABLE public.device_boot_sessions IS 'Mỗi lần khởi động/kết nối thiết bị đã được backend xác minh. Gắn boot với credential và connection generation, lưu frontier sequence để phân biệt replay với dữ liệu của boot mới.';
COMMENT ON COLUMN public.device_boot_sessions.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.device_boot_sessions.device_id IS 'Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng tenant.';
COMMENT ON COLUMN public.device_boot_sessions.boot_id IS 'Identity boot của thiết bị theo wire dạng text, không suy UUID; chỉ chấp nhận khi gắn với credential/connection đã xác minh.';
COMMENT ON COLUMN public.device_boot_sessions.credential_generation IS 'Thế hệ credential MQTT của thiết bị, phân biệt lần cấp mới với credential cũ đã thu hồi.';
COMMENT ON COLUMN public.device_boot_sessions.connection_generation IS 'Thế hệ kết nối đã xác minh của device, dùng loại sự kiện/reply từ kết nối cũ.';
COMMENT ON COLUMN public.device_boot_sessions.started_at IS 'Thời điểm backend xác minh boot/kết nối theo credential generation; không chỉ tin boot_id trong payload.';
COMMENT ON COLUMN public.device_boot_sessions.retired_at IS 'Thời điểm boot/secret version được retire; dữ liệu lịch sử và các nghĩa vụ còn tham chiếu có thể tiếp tục được giữ.';
COMMENT ON COLUMN public.device_boot_sessions.source_sequence_floor IS 'Frontier sequence nguồn đã được compact/retire theo boot; writer phải đối soát trước compact receipt, không tự reset khi purge raw.';
COMMENT ON COLUMN public.device_boot_sessions.last_source_sequence IS 'Sequence nguồn gần nhất đã ghi nhận cho boot; NULL khi chưa có mốc, không dùng thay thứ tự server ingest.';

/* Công dụng của public.device_credentials. */
COMMENT ON TABLE public.device_credentials IS 'Các generation credential MQTT của thiết bị và trạng thái cấp/thu hồi. Chỉ lưu bộ kiểm chứng, không giữ raw credential để đọc lại.';
COMMENT ON COLUMN public.device_credentials.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.device_credentials.device_id IS 'Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng tenant.';
COMMENT ON COLUMN public.device_credentials.credential_generation IS 'Thế hệ credential MQTT của thiết bị, phân biệt lần cấp mới với credential cũ đã thu hồi.';
COMMENT ON COLUMN public.device_credentials.credential_identifier IS 'Định danh credential/client phía broker, duy nhất toàn cục; không phải raw password MQTT.';
COMMENT ON COLUMN public.device_credentials.verifier_digest IS 'Bộ kiểm chứng mật 32 byte dùng xác thực credential/API key theo protected-verifier contract; không là raw secret và không trả client/log.';
COMMENT ON COLUMN public.device_credentials.credential_state IS 'Tiến trình credential PROVISIONING/ACTIVE/REVOCATION_PENDING/REVOKED; chỉ báo đã revoke khi có xác nhận phù hợp.';
COMMENT ON COLUMN public.device_credentials.issued_at IS 'Thời điểm phát hành phiên/grant/credential/ticket, làm gốc tính TTL theo loại bản ghi.';
COMMENT ON COLUMN public.device_credentials.revoked_at IS 'Thời điểm thu hồi quyền/credential; NULL nghĩa chưa ghi nhận thu hồi, không đồng nghĩa mọi điều kiện xác thực khác còn hợp lệ.';

/* Công dụng của public.device_enrollment_guards. */
COMMENT ON TABLE public.device_enrollment_guards IS 'Khóa nghiệp vụ giữ một thiết bị cho enrollment đang chưa giải quyết. Guard chỉ được nhả khi hoàn tất hoặc cleanup có proof, không chỉ vì session đã hết hạn.';
COMMENT ON COLUMN public.device_enrollment_guards.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.device_enrollment_guards.device_id IS 'Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng tenant.';
COMMENT ON COLUMN public.device_enrollment_guards.enrollment_session_id IS 'Identity ý định onboarding/đổi Wi-Fi, dùng polling, proof binding và liên kết cleanup/guard.';
COMMENT ON COLUMN public.device_enrollment_guards.acquired_at IS 'Thời điểm device enrollment guard được giữ, giúp chẩn đoán thời gian chiếm thiết bị khi session đã hết hạn.';

/* Công dụng của public.device_latest_values. */
COMMENT ON TABLE public.device_latest_values IS 'Projection mẫu mới nhất của từng kênh phục vụ giao diện và rule. Giữ marker đủ điều kiện riêng để mẫu NULL/stale mới không bị thay bằng GOOD cũ khi điều khiển.';
COMMENT ON COLUMN public.device_latest_values.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.device_latest_values.device_id IS 'Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng tenant.';
COMMENT ON COLUMN public.device_latest_values.template_version_id IS 'Identity snapshot template cụ thể, dùng pin schema và kiểm đúng definition trong workspace.';
COMMENT ON COLUMN public.device_latest_values.stream_key IS 'Khóa kỹ thuật ổn định của kênh trong template/version; không dùng nhãn hiển thị thay khóa schema.';
COMMENT ON COLUMN public.device_latest_values.latest_marker_sequence IS 'Marker server của mẫu mới nhất được projection chấp nhận; không được lùi khi message đến sai thứ tự.';
COMMENT ON COLUMN public.device_latest_values.latest_received_at IS 'Mốc server nhận mẫu đang làm latest; không được lùi, không thay observed/effective time của dữ liệu gốc.';
COMMENT ON COLUMN public.device_latest_values.latest_value IS 'Snapshot giá trị mới nhất cho hiển thị, có thể NULL/không đủ điều kiện rule; không mặc định fallback GOOD cũ.';
COMMENT ON COLUMN public.device_latest_values.rule_eligible_marker_sequence IS 'Marker của mẫu hiện hành đủ điều kiện rule, phải bằng latest marker nếu có; NULL nghĩa không có giá trị rule đủ điều kiện.';
COMMENT ON COLUMN public.device_latest_values.rule_value IS 'Giá trị của đúng eligible marker hiện hành để rule dùng; NULL khi marker mới không đủ điều kiện, không giữ GOOD cũ làm authority.';
COMMENT ON COLUMN public.device_latest_values.eligibility_reason IS 'Lý do latest được/không được dùng cho rule, giúp giải thích NULL/stale/server-time thay vì đoán từ giá trị.';

/* Công dụng của public.device_operations. */
COMMENT ON TABLE public.device_operations IS 'Ý định lifecycle thiết bị như suspend/resume/archive/revoke. Giữ trạng thái đối soát cùng receipt broker/disconnect để không báo hoàn tất khi side effect chưa được xác nhận.';
COMMENT ON COLUMN public.device_operations.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.device_operations.device_operation_id IS 'Identity lifecycle operation của thiết bị; khi tham chiếu cùng device_id phải khớp đúng thiết bị đó.';
COMMENT ON COLUMN public.device_operations.device_id IS 'Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng tenant.';
COMMENT ON COLUMN public.device_operations.operation_type IS 'Loại lifecycle mutation được yêu cầu, để worker thực hiện đúng thao tác và kiểm proof tương ứng.';
COMMENT ON COLUMN public.device_operations.state IS 'Trạng thái xử lý bền vững của ledger/job/operation; không suy rằng enum hợp lệ tự chứng minh transition hợp lệ.';
COMMENT ON COLUMN public.device_operations.requested_revision IS 'Revision resource mà người yêu cầu dựa vào lúc khởi tạo lifecycle operation; dùng phát hiện yêu cầu chỉnh sửa đã lỗi thời.';
COMMENT ON COLUMN public.device_operations.actor_user_id IS 'Tài khoản thực hiện hoặc khởi tạo thao tác, phục vụ kiểm quyền và truy vết; không lấy authority chỉ từ ID client gửi.';
COMMENT ON COLUMN public.device_operations.intent_at IS 'Thời điểm lưu ý định trước side effect bên ngoài DB; dùng tính ngân sách/expiry và phục hồi khi mất ACK.';
COMMENT ON COLUMN public.device_operations.settled_at IS 'Thời điểm nghĩa vụ vận hành được đối soát xong và có thể nhả guard/quota; NULL tiếp tục giữ nghĩa vụ chưa giải quyết.';
COMMENT ON COLUMN public.device_operations.broker_revoke_receipt IS 'Bằng chứng đã redact về broker xác nhận thu hồi; không suy chỉ ghi trạng thái DB là broker đã chặn credential.';
COMMENT ON COLUMN public.device_operations.disconnect_receipt IS 'Bằng chứng đã redact về kết nối thiết bị bị ngắt theo cleanup/lifecycle protocol; cần giữ để settlement có căn cứ.';

/* Công dụng của public.device_runtime. */
COMMENT ON TABLE public.device_runtime IS 'Trạng thái vận hành thay đổi thường xuyên của thiết bị: presence, boot hiện hành, bộ đếm ingest và epoch bảo trì. Tách khỏi metadata để telemetry không làm tăng revision chỉnh sửa thiết bị.';
COMMENT ON COLUMN public.device_runtime.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.device_runtime.device_id IS 'Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng tenant.';
COMMENT ON COLUMN public.device_runtime.ingestion_sequence IS 'Bộ đếm server đã tiếp nhận cho device, ban đầu 0; tăng theo ingest commit, không lấy wire seq thay thế.';
COMMENT ON COLUMN public.device_runtime.connection_generation IS 'Thế hệ kết nối đã xác minh của device, dùng loại sự kiện/reply từ kết nối cũ.';
COMMENT ON COLUMN public.device_runtime.maintenance_epoch IS 'Thế hệ khóa bảo trì, dùng phân biệt OTA/dispatch đang hiện hành với callback cũ; không reset do reconnect.';
COMMENT ON COLUMN public.device_runtime.maintenance IS 'Chế độ vận hành NONE/OTA của thiết bị, dùng chặn command/automation khi đang bảo trì.';
COMMENT ON COLUMN public.device_runtime.last_seen_at IS 'Thời điểm hoạt động hợp lệ gần nhất từ thiết bị, dùng phát hiện mất kết nối theo policy presence.';
COMMENT ON COLUMN public.device_runtime.presence_state IS 'Trạng thái kết nối UNKNOWN/ONLINE/OFFLINE, độc lập với lifecycle và maintenance của thiết bị.';
COMMENT ON COLUMN public.device_runtime.current_boot_id IS 'Boot đang hiện hành của thiết bị; NULL khi chưa có boot đáng tin cậy, không hồi sinh boot cũ từ hello trùng.';

/* Công dụng của public.devices. */
COMMENT ON TABLE public.devices IS 'Registry thiết bị: identity MQTT toàn cục, serial, workspace, owner và template version đã pin. Quản lý lifecycle/metadata; trạng thái kết nối và bộ đếm runtime tách sang device_runtime.';
COMMENT ON COLUMN public.devices.device_id IS 'Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng tenant.';
COMMENT ON COLUMN public.devices.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.devices.serial_number IS 'Serial phần cứng duy nhất toàn cục, phân biệt hoa/thường theo contract registry; dùng lookup đăng ký/onboarding.';
COMMENT ON COLUMN public.devices.template_version_id IS 'Identity snapshot template cụ thể, dùng pin schema và kiểm đúng definition trong workspace.';
COMMENT ON COLUMN public.devices.owner_user_id IS 'Tài khoản sở hữu tài nguyên trong workspace; backend phải kiểm membership và quyền hiện hành khi đọc/ghi.';
COMMENT ON COLUMN public.devices.name IS 'Tên hiển thị do người dùng đặt cho tài nguyên; không dùng làm identity, quyền hoặc khóa chống lặp.';
COMMENT ON COLUMN public.devices.description IS 'Mô tả bổ sung để người dùng hiểu tài nguyên; NULL nghĩa chưa cung cấp mô tả, không mang authority vận hành.';
COMMENT ON COLUMN public.devices.model IS 'Mã model phần cứng/template theo registry đã duyệt, dùng kiểm tương thích; không suy model từ tên hiển thị.';
COMMENT ON COLUMN public.devices.hardware_revision IS 'Revision phần cứng để kiểm đúng biến thể board/firmware, khác firmware_version và revision chỉnh sửa metadata.';
COMMENT ON COLUMN public.devices.firmware_version IS 'Phiên bản firmware được thiết bị báo hoặc manifest khai; không tự chứng minh artifact đã được xác minh/chạy khỏe.';
COMMENT ON COLUMN public.devices.firmware_digest IS 'SHA-256 32 byte của image firmware được xác thực từ thiết bị; NULL khi chưa có identity image đáng tin cậy.';
COMMENT ON COLUMN public.devices.lifecycle_status IS 'Trạng thái vòng đời quản lý tài nguyên, tách khỏi presence hoặc tiến độ của job đang chạy.';
COMMENT ON COLUMN public.devices.revision IS 'Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng transaction contract.';
COMMENT ON COLUMN public.devices.authorization_version IS 'Mốc phiên bản quyền hiện hành; bên ghi phải tăng khi quyền thay đổi để ticket/job/cache phát hiện ngữ cảnh quyền cũ.';
COMMENT ON COLUMN public.devices.created_at IS 'Thời điểm tạo bản ghi dưới dạng timestamptz; dùng provenance/sắp xếp hoặc retention khi policy của bảng quy định.';
COMMENT ON COLUMN public.devices.updated_at IS 'Thời điểm cập nhật gần nhất do đường ghi quản lý; không mặc định SQL tự cập nhật nếu không có trigger tương ứng.';

/* Công dụng của public.enrollment_cleanup_operations. */
COMMENT ON TABLE public.enrollment_cleanup_operations IS 'Công việc cleanup enrollment cùng bằng chứng revoke/disconnect. Tách khỏi TTL của phiên để expiry không bị hiểu nhầm là cloud cleanup đã hoàn tất.';
COMMENT ON COLUMN public.enrollment_cleanup_operations.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.enrollment_cleanup_operations.enrollment_cleanup_operation_id IS 'Identity công việc cleanup của enrollment, dùng theo dõi proof và settlement độc lập TTL phiên.';
COMMENT ON COLUMN public.enrollment_cleanup_operations.enrollment_session_id IS 'Identity ý định onboarding/đổi Wi-Fi, dùng polling, proof binding và liên kết cleanup/guard.';
COMMENT ON COLUMN public.enrollment_cleanup_operations.device_id IS 'Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng tenant.';
COMMENT ON COLUMN public.enrollment_cleanup_operations.state IS 'Trạng thái xử lý bền vững của ledger/job/operation; không suy rằng enum hợp lệ tự chứng minh transition hợp lệ.';
COMMENT ON COLUMN public.enrollment_cleanup_operations.intent_at IS 'Thời điểm lưu ý định trước side effect bên ngoài DB; dùng tính ngân sách/expiry và phục hồi khi mất ACK.';
COMMENT ON COLUMN public.enrollment_cleanup_operations.broker_revoke_receipt IS 'Bằng chứng đã redact về broker xác nhận thu hồi; không suy chỉ ghi trạng thái DB là broker đã chặn credential.';
COMMENT ON COLUMN public.enrollment_cleanup_operations.disconnect_receipt IS 'Bằng chứng đã redact về kết nối thiết bị bị ngắt theo cleanup/lifecycle protocol; cần giữ để settlement có căn cứ.';
COMMENT ON COLUMN public.enrollment_cleanup_operations.settled_at IS 'Thời điểm nghĩa vụ vận hành được đối soát xong và có thể nhả guard/quota; NULL tiếp tục giữ nghĩa vụ chưa giải quyết.';

/* Công dụng của public.enrollment_sessions. */
COMMENT ON TABLE public.enrollment_sessions IS 'Ý định onboarding/đổi Wi-Fi gắn device, actor grant, installation và proof, hạn 10 phút. Không lưu PoP/SSID/mật khẩu Wi-Fi và không phụ thuộc quyền nhận push.';
COMMENT ON COLUMN public.enrollment_sessions.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.enrollment_sessions.enrollment_session_id IS 'Identity ý định onboarding/đổi Wi-Fi, dùng polling, proof binding và liên kết cleanup/guard.';
COMMENT ON COLUMN public.enrollment_sessions.device_id IS 'Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng tenant.';
COMMENT ON COLUMN public.enrollment_sessions.actor_user_id IS 'Tài khoản thực hiện hoặc khởi tạo thao tác, phục vụ kiểm quyền và truy vết; không lấy authority chỉ từ ID client gửi.';
COMMENT ON COLUMN public.enrollment_sessions.actor_grant_generation IS 'Grant actor được chụp lúc tạo enrollment, giúp kiểm tác vụ cũ sau remove/rejoin.';
COMMENT ON COLUMN public.enrollment_sessions.client_installation_id IS 'Installation mà enrollment gắn với; cố ý không FK tới push_installations vì onboarding không đòi quyền push.';
COMMENT ON COLUMN public.enrollment_sessions.enrollment_proof_digest IS 'Digest 32 byte của proof enrollment do installation nắm, dùng chứng minh quyền thao tác phiên; không thay QR PoP hoặc physical proof.';
COMMENT ON COLUMN public.enrollment_sessions.mode IS 'Chế độ enrollment INITIAL/WIFI_RECONFIGURE; đổi Wi-Fi không tự tạo/thu hồi MQTT credential hiện hành.';
COMMENT ON COLUMN public.enrollment_sessions.state IS 'CREATED→BLE_CONNECTED→WIFI_JOINED→CLOUD_CONNECTING→COMPLETED hoặc FAILED/CANCELLED/EXPIRED; chỉ trusted cloud evidence mới được xác nhận COMPLETED.';
COMMENT ON COLUMN public.enrollment_sessions.started_at IS 'Thời điểm bắt đầu boot/enrollment/action hoặc hoạt động tương ứng, tùy ngữ nghĩa bảng.';
COMMENT ON COLUMN public.enrollment_sessions.expires_at IS 'Hạn phiên started_at + 10 phút; expiry không tự xóa guard khi broker cleanup còn thiếu proof.';
COMMENT ON COLUMN public.enrollment_sessions.provisioning_operation_id IS 'Identity công việc cấp credential, dùng claim một lần và gắn enrollment đúng device/generation.';
COMMENT ON COLUMN public.enrollment_sessions.completed_at IS 'Thời điểm tác vụ hoặc enrollment được ghi nhận hoàn tất theo điều kiện của bảng; không lấy timer client làm bằng chứng.';
COMMENT ON COLUMN public.enrollment_sessions.revision IS 'Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng transaction contract.';

/* Công dụng của public.event_occurrences. */
COMMENT ON TABLE public.event_occurrences IS 'Journal từng transition đã commit của Event, command hoặc connectivity. Identity occurrence dùng cho webhook, khác Event nghiệp vụ; nhánh typed/XOR tránh tạo Event giả.';
COMMENT ON COLUMN public.event_occurrences.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.event_occurrences.occurrence_id IS 'Identity một transition đã commit; wire webhook eventId ánh xạ identity này, không gộp OPEN/RESOLVED thành một Event ID.';
COMMENT ON COLUMN public.event_occurrences.source_kind IS 'Discriminator chỉ loại nguồn typed; phải đi cùng đúng một nhánh FK, không dùng ID đa hình không kiểm chứng.';
COMMENT ON COLUMN public.event_occurrences.event_id IS 'Identity Event nghiệp vụ trong workspace; khác occurrence_id đại diện từng transition để giao webhook.';
COMMENT ON COLUMN public.event_occurrences.event_revision IS 'Revision transition Event được chụp trong occurrence, lớn hơn 0; unique cùng Event tránh phát cùng transition hai lần.';
COMMENT ON COLUMN public.event_occurrences.command_id IS 'Identity command ổn định qua retry/result/reconciliation; không tạo command mới chỉ vì mất response.';
COMMENT ON COLUMN public.event_occurrences.connectivity_device_id IS 'Device làm nguồn occurrence connectivity, chỉ có trong nhánh CONNECTIVITY.';
COMMENT ON COLUMN public.event_occurrences.connectivity_transition_sequence IS 'Transition presence cụ thể của connectivity_device_id; cùng device/sequence là nguồn chống trùng occurrence.';
COMMENT ON COLUMN public.event_occurrences.occurrence_type IS 'Loại transition nội bộ của nguồn occurrence; ACKNOWLEDGED không mặc định thành BUSINESS webhook public.';
COMMENT ON COLUMN public.event_occurrences.public_event_type IS 'Loại event public để webhook fanout; NULL cho occurrence nội bộ không được phép phát BUSINESS webhook.';
COMMENT ON COLUMN public.event_occurrences.occurred_at IS 'Thời điểm nghiệp vụ/sự kiện diễn ra để sắp xếp timeline; không mặc định bằng thời điểm fanout hoặc provider phản hồi.';
COMMENT ON COLUMN public.event_occurrences.committed_at IS 'Mốc thời gian producer ghi cho occurrence trong transaction đã commit thành công; không phải physical commit timestamp biết trước commit.';
COMMENT ON COLUMN public.event_occurrences.immutable_payload IS 'Snapshot payload occurrence đã commit, giữ nguyên để fanout/retry không đọc lại resource mutable rồi đổi sự thật lịch sử.';

/* Công dụng của public.events. */
COMMENT ON TABLE public.events IS 'Sự kiện nghiệp vụ theo nguồn device/rule và episode, có mức độ cùng vòng đời đọc/xác nhận/resolve. Một Event có thể tạo nhiều occurrence và inbox cho từng recipient.';
COMMENT ON COLUMN public.events.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.events.event_id IS 'Identity Event nghiệp vụ trong workspace; khác occurrence_id đại diện từng transition để giao webhook.';
COMMENT ON COLUMN public.events.source_kind IS 'Discriminator chỉ loại nguồn typed; phải đi cùng đúng một nhánh FK, không dùng ID đa hình không kiểm chứng.';
COMMENT ON COLUMN public.events.source_device_id IS 'Device làm nguồn Event khi source_kind=DEVICE; nhánh rule phải để NULL để giữ XOR nguồn.';
COMMENT ON COLUMN public.events.source_rule_id IS 'Rule làm nguồn Event khi source_kind=RULE; nhánh device phải để NULL để giữ XOR nguồn.';
COMMENT ON COLUMN public.events.source_identity IS 'Identity nguồn Event được sinh từ đúng một nhánh device/rule; dùng natural dedupe cùng source_kind và episode_key.';
COMMENT ON COLUMN public.events.episode_key IS 'Identity episode nghiệp vụ của nguồn Event, dùng dedupe một sự kiện trong cùng chu kỳ lỗi/điều kiện.';
COMMENT ON COLUMN public.events.severity IS 'Mức độ INFO/WARNING/CRITICAL của Event, dùng lọc hiển thị/notification; không thay trạng thái Event.';
COMMENT ON COLUMN public.events.status IS 'Vòng đời Event OPEN/ACKNOWLEDGED/RESOLVED; khác trạng thái read của inbox và outcome của command.';
COMMENT ON COLUMN public.events.title IS 'Tiêu đề hiển thị của dashboard hoặc sự kiện; là nội dung giao diện, không dùng thay identity tài nguyên.';
COMMENT ON COLUMN public.events.safe_message IS 'Thông điệp Event dùng hiển thị hoặc thông báo sau validation/redaction phía producer; không là nơi cất payload bí mật.';
COMMENT ON COLUMN public.events.revision IS 'Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng transaction contract.';
COMMENT ON COLUMN public.events.created_at IS 'Thời điểm tạo bản ghi dưới dạng timestamptz; dùng provenance/sắp xếp hoặc retention khi policy của bảng quy định.';
COMMENT ON COLUMN public.events.acknowledged_by_user_id IS 'Thành viên đã xác nhận Event; đi cùng acknowledged_at để lưu người và thời điểm ACK.';
COMMENT ON COLUMN public.events.acknowledged_at IS 'Thời điểm thành viên ACK Event, đi cùng acknowledged_by_user_id và độc lập read_at của inbox.';
COMMENT ON COLUMN public.events.resolved_at IS 'Thời điểm Event/resolution được đóng xử lý; ngữ nghĩa theo aggregate, không tự thay command UNKNOWN thành SUCCEEDED.';

/* Công dụng của public.execution_actuator_snapshots. */
COMMENT ON TABLE public.execution_actuator_snapshots IS 'Manual epoch của từng actuator tại đầu execution. Giữ snapshot trước WAIT để automation phát hiện người dùng đã điều khiển thủ công và không ghi đè thao tác mới.';
COMMENT ON COLUMN public.execution_actuator_snapshots.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.execution_actuator_snapshots.rule_execution_id IS 'Identity một lần quyết định/chạy rule version, dùng quota, history, action chain và notification target.';
COMMENT ON COLUMN public.execution_actuator_snapshots.device_id IS 'Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng tenant.';
COMMENT ON COLUMN public.execution_actuator_snapshots.stream_key IS 'Khóa kỹ thuật ổn định của kênh trong template/version; không dùng nhãn hiển thị thay khóa schema.';
COMMENT ON COLUMN public.execution_actuator_snapshots.manual_epoch_at_start IS 'Manual epoch của actuator được chụp lúc execution bắt đầu, trước WAIT; không đọc lại sau WAIT rồi coi là snapshot ban đầu.';

/* Công dụng của public.execution_history. */
COMMENT ON VIEW public.execution_history IS 'View lịch sử execution trong cutoff 30 ngày; operational guard chưa giải quyết vẫn giữ ở ledger gốc.';
COMMENT ON COLUMN public.execution_history.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.execution_history.rule_execution_id IS 'Identity một lần quyết định/chạy rule version, dùng quota, history, action chain và notification target.';
COMMENT ON COLUMN public.execution_history.rule_id IS 'Identity gốc rule trong workspace, dùng nhóm draft/version/runtime; không là identity một lần chạy.';
COMMENT ON COLUMN public.execution_history.rule_version_id IS 'Identity rule snapshot đã publish, dùng pin trigger/action/execution thay vì đọc draft hiện hành.';
COMMENT ON COLUMN public.execution_history.trigger_key IS 'Identity ổn định của trigger/episode/occurrence theo version; dùng dedupe, không sinh key mới chỉ vì worker restart.';
COMMENT ON COLUMN public.execution_history.state IS 'Trạng thái RUNNING/WAITING hoặc kết quả SUCCEEDED/PARTIAL/FAILED/CANCELLED/NEEDS_ATTENTION/NO_MATCH; RUNNING/WAITING chiếm quota.';
COMMENT ON COLUMN public.execution_history.admitted_at IS 'Thời điểm yêu cầu được backend nhận vào ledger sau kiểm điều kiện; không chứng minh side effect đã thực hiện.';
COMMENT ON COLUMN public.execution_history.deadline_at IS 'Deadline admitted_at + 15 phút cho cả execution; WAIT/restart không kéo dài ngân sách toàn chuỗi.';
COMMENT ON COLUMN public.execution_history.ended_at IS 'Thời điểm execution/action kết thúc; NULL khi chưa ghi nhận kết thúc, outcome/state là trục kết quả riêng.';
COMMENT ON COLUMN public.execution_history.next_action_position IS 'Vị trí bước kế của execution, miền 0..5; giá trị 5 có thể biểu diễn đã qua bước cuối trong chuỗi tối đa 5 action.';
COMMENT ON COLUMN public.execution_history.owner_user_id_snapshot IS 'Owner được chụp khi execution admission, dùng phân quyền lịch sử theo policy; request vẫn phải recheck membership hiện hành.';
COMMENT ON COLUMN public.execution_history.failure_reason IS 'Nguyên nhân thất bại đã chuẩn hóa/redact cho vận hành và lịch sử; không lưu response bí mật của dịch vụ ngoài.';

/* Công dụng của public.firmware_package_templates. */
COMMENT ON TABLE public.firmware_package_templates IS 'Tập template version được package khai tương thích trong signed manifest. Giữ FK tới version cụ thể, không suy compatibility từ tên hoặc template root.';
COMMENT ON COLUMN public.firmware_package_templates.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.firmware_package_templates.firmware_package_id IS 'Identity canonical package firmware trong workspace, dùng liên kết compatibility và OTA jobs.';
COMMENT ON COLUMN public.firmware_package_templates.template_version_id IS 'Identity snapshot template cụ thể, dùng pin schema và kiểm đúng definition trong workspace.';

/* Công dụng của public.firmware_packages. */
COMMENT ON TABLE public.firmware_packages IS 'Metadata package firmware đã được validator xác minh, giữ exact signed manifest bytes và chữ ký. Binary nằm ở artifact store; nhãn VERIFIED trong SQL không tự thực hiện kiểm chữ ký.';
COMMENT ON COLUMN public.firmware_packages.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.firmware_packages.firmware_package_id IS 'Identity canonical package firmware trong workspace, dùng liên kết compatibility và OTA jobs.';
COMMENT ON COLUMN public.firmware_packages.artifact_digest IS 'SHA-256 32 byte của artifact firmware, dùng identity nội dung và kiểm binary khớp manifest.';
COMMENT ON COLUMN public.firmware_packages.raw_manifest IS 'Exact signed manifest bytes làm authority kiểm chữ ký; không dựng lại từ các cột parsed rồi giả là cùng signed bytes.';
COMMENT ON COLUMN public.firmware_packages.signature IS 'Bytes chữ ký của exact raw_manifest theo thuật toán trong trust profile; SQL chỉ lưu bytes, validator phải kiểm chữ ký.';
COMMENT ON COLUMN public.firmware_packages.artifact_reference IS 'Locator artifact trong kho đã duyệt, không là arbitrary URL cho client điều khiển hoặc private signing key.';
COMMENT ON COLUMN public.firmware_packages.artifact_size_bytes IS 'Kích thước binary firmware tính bằng byte, dùng kiểm manifest, giới hạn download và khả năng chứa image của board.';
COMMENT ON COLUMN public.firmware_packages.signing_key_fingerprint IS 'Fingerprint SHA-256 32 byte của khóa ký được tin cậy, phục vụ audit/provenance chữ ký firmware.';
COMMENT ON COLUMN public.firmware_packages.signing_key_identifier IS 'Định danh khóa ký public/trust profile dùng kiểm firmware manifest; không lưu private signing key.';
COMMENT ON COLUMN public.firmware_packages.manifest_schema_version IS 'Phiên bản cấu trúc signed manifest, hiện 1; khác firmware version hoặc revision package.';
COMMENT ON COLUMN public.firmware_packages.board_model IS 'Model board được signed manifest khai hỗ trợ; validator đối chiếu với device trước OTA.';
COMMENT ON COLUMN public.firmware_packages.hardware_revision IS 'Revision phần cứng để kiểm đúng biến thể board/firmware, khác firmware_version và revision chỉnh sửa metadata.';
COMMENT ON COLUMN public.firmware_packages.firmware_version IS 'Phiên bản firmware được thiết bị báo hoặc manifest khai; không tự chứng minh artifact đã được xác minh/chạy khỏe.';
COMMENT ON COLUMN public.firmware_packages.build_identifier IS 'Định danh build firmware trong manifest, dùng truy vết artifact/toolchain; không thay artifact digest.';
COMMENT ON COLUMN public.firmware_packages.validation_state IS 'Nhãn package đã đi qua validator, bảng canonical hiện chỉ VERIFIED; không tự chứng minh chữ ký đúng chỉ nhờ INSERT giá trị này.';
COMMENT ON COLUMN public.firmware_packages.created_at IS 'Thời điểm tạo bản ghi dưới dạng timestamptz; dùng provenance/sắp xếp hoặc retention khi policy của bảng quy định.';

/* Công dụng của public.firmware_upload_attempts. */
COMMENT ON TABLE public.firmware_upload_attempts IS 'Mỗi lần upload/verify firmware, kể cả lần lỗi. Tách khỏi canonical package để chữ ký sai đầu tiên không chiếm identity digest của artifact hợp lệ.';
COMMENT ON COLUMN public.firmware_upload_attempts.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.firmware_upload_attempts.firmware_upload_attempt_id IS 'Identity một lượt upload/verify, kể cả reject; không là canonical package identity.';
COMMENT ON COLUMN public.firmware_upload_attempts.actor_user_id IS 'Tài khoản thực hiện hoặc khởi tạo thao tác, phục vụ kiểm quyền và truy vết; không lấy authority chỉ từ ID client gửi.';
COMMENT ON COLUMN public.firmware_upload_attempts.artifact_digest IS 'SHA-256 32 byte của artifact firmware, dùng identity nội dung và kiểm binary khớp manifest.';
COMMENT ON COLUMN public.firmware_upload_attempts.temporary_artifact_reference IS 'Locator blob upload tạm còn cần verify/cleanup, khác artifact canonical đã được package/job tham chiếu.';
COMMENT ON COLUMN public.firmware_upload_attempts.state IS 'Kết quả lượt upload UPLOADED/VERIFIED/REJECTED; lần reject không chiếm canonical package identity.';
COMMENT ON COLUMN public.firmware_upload_attempts.failure_reason IS 'Nguyên nhân thất bại đã chuẩn hóa/redact cho vận hành và lịch sử; không lưu response bí mật của dịch vụ ngoài.';
COMMENT ON COLUMN public.firmware_upload_attempts.created_at IS 'Thời điểm tạo bản ghi dưới dạng timestamptz; dùng provenance/sắp xếp hoặc retention khi policy của bảng quy định.';
COMMENT ON COLUMN public.firmware_upload_attempts.expires_at IS 'Mốc created_at + 24 giờ cho artifact upload tạm theo policy; cleanup vẫn phải kiểm reference/lease còn hoạt động.';

/* Công dụng của public.global_idempotency_records. */
COMMENT ON TABLE public.global_idempotency_records IS 'Biên nhận chống lặp cho request global theo tài khoản/route/key digest, không gắn workspace đang chọn. Chỉ giữ kết quả đã loại secret trong cửa sổ replay 24 giờ.';
COMMENT ON COLUMN public.global_idempotency_records.user_id IS 'Tài khoản principal của request global; không đưa workspace đang chọn vào namespace replay.';
COMMENT ON COLUMN public.global_idempotency_records.route_key IS 'Namespace route canonical gồm identity resource cần thiết; không chỉ là route template khi nhiều target dùng chung idempotency key.';
COMMENT ON COLUMN public.global_idempotency_records.key_digest IS 'Digest idempotency key của client; cùng namespace principal/route tạo identity replay, không chứa secret response.';
COMMENT ON COLUMN public.global_idempotency_records.request_digest IS 'Digest 32 byte của request/body đã canonical hóa để phát hiện cùng identity khác nội dung hoặc đối chiếu send intent.';
COMMENT ON COLUMN public.global_idempotency_records.admitted_at IS 'Thời điểm yêu cầu được backend nhận vào ledger sau kiểm điều kiện; không chứng minh side effect đã thực hiện.';
COMMENT ON COLUMN public.global_idempotency_records.expires_at IS 'Hết cửa sổ replay sau admitted_at + 24 giờ; không replay one-time secret, chỉ sanitized_result.';
COMMENT ON COLUMN public.global_idempotency_records.state IS 'Receipt đang IN_PROGRESS hoặc COMPLETED; lỗi mất ACK không cho tự kết luận transaction chưa commit.';
COMMENT ON COLUMN public.global_idempotency_records.response_status IS 'HTTP status đã ghi nhận, miền 100..599 khi có; NULL khi chưa có response đáng tin cậy.';
COMMENT ON COLUMN public.global_idempotency_records.sanitized_result IS 'Kết quả replay đã loại secret, không lưu one-time credential response để trả lại sau retry.';

/* Công dụng của public.login_attempt_buckets. */
COMMENT ON TABLE public.login_attempt_buckets IS 'Bộ đếm đăng nhập sai theo digest email chuẩn hóa. Ghi mốc cửa sổ thất bại để backend thực thi giới hạn đăng nhập đồng nhất giữa các tiến trình.';
COMMENT ON COLUMN public.login_attempt_buckets.email_digest IS 'Digest 32 byte của email chuẩn hóa để lập bucket/fence mà không dùng raw email làm khóa vận hành; policy key version thuộc custody.';
COMMENT ON COLUMN public.login_attempt_buckets.failure_count IS 'Số lần đăng nhập sai trong bucket hiện hành, miền 0..5; count 0 đi cùng window_started_at NULL.';
COMMENT ON COLUMN public.login_attempt_buckets.window_started_at IS 'Mốc failure đầu mở fixed window đăng nhập, không trượt theo mỗi lần retry/429; NULL khi bucket rỗng.';

/* Công dụng của public.membership_admission_fences. */
COMMENT ON TABLE public.membership_admission_fences IS 'Điểm tuần tự hóa nhận thành viên theo workspace và digest email, kể cả khi chưa có tài khoản. Generation hiện hành giúp vô hiệu hóa lời mời hoặc admission cũ.';
COMMENT ON COLUMN public.membership_admission_fences.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.membership_admission_fences.email_digest IS 'Digest 32 byte của email chuẩn hóa để lập bucket/fence mà không dùng raw email làm khóa vận hành; policy key version thuộc custody.';
COMMENT ON COLUMN public.membership_admission_fences.admission_generation IS 'Thế hệ nhận thành viên theo email/workspace; snapshot invitation phải được so với fence hiện hành tại consume.';
COMMENT ON COLUMN public.membership_admission_fences.updated_at IS 'Thời điểm cập nhật gần nhất do đường ghi quản lý; không mặc định SQL tự cập nhật nếu không có trigger tương ứng.';

/* Công dụng của public.membership_grants. */
COMMENT ON TABLE public.membership_grants IS 'Lịch sử từng lần cấp quyền thành viên. Giữ identity theo generation để lời mời, API key hoặc tác vụ dùng grant cũ không tự có quyền lại khi tài khoản tham gia lại.';
COMMENT ON COLUMN public.membership_grants.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.membership_grants.user_id IS 'Identity tài khoản liên quan; khi đi cùng workspace_id phải tham chiếu đúng membership của workspace.';
COMMENT ON COLUMN public.membership_grants.grant_generation IS 'Generation của một lần cấp membership cụ thể, lớn hơn 0; không tái sử dụng identity khi remove rồi rejoin.';
COMMENT ON COLUMN public.membership_grants.issued_at IS 'Thời điểm phát hành phiên/grant/credential/ticket, làm gốc tính TTL theo loại bản ghi.';
COMMENT ON COLUMN public.membership_grants.revoked_at IS 'Thời điểm thu hồi quyền/credential; NULL nghĩa chưa ghi nhận thu hồi, không đồng nghĩa mọi điều kiện xác thực khác còn hợp lệ.';

/* Công dụng của public.memberships. */
COMMENT ON TABLE public.memberships IS 'Quan hệ hiện hành giữa tài khoản và workspace: vai trò ADMIN/USER, trạng thái và grant đang sử dụng. Đây là nguồn xác định tư cách thành viên, không sao chép vai trò vào từng thiết bị.';
COMMENT ON COLUMN public.memberships.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.memberships.user_id IS 'Identity tài khoản liên quan; khi đi cùng workspace_id phải tham chiếu đúng membership của workspace.';
COMMENT ON COLUMN public.memberships.role IS 'Vai trò thành viên ADMIN/USER trong workspace, không là quyền quản trị toàn bộ hệ thống.';
COMMENT ON COLUMN public.memberships.status IS 'Tư cách thành viên ACTIVE/SUSPENDED/REMOVED trong workspace; khác trạng thái tài khoản toàn cục.';
COMMENT ON COLUMN public.memberships.alias IS 'Tên gọi của tài khoản trong workspace này, độc lập email đăng nhập hoặc tên trong workspace khác.';
COMMENT ON COLUMN public.memberships.revision IS 'Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng transaction contract.';
COMMENT ON COLUMN public.memberships.authorization_version IS 'Phiên bản quyền của membership, chụp vào ticket/job; đường ghi phải tăng khi role/status/quyền thay đổi theo protocol.';
COMMENT ON COLUMN public.memberships.current_grant_generation IS 'Grant membership hiện đang dùng; phải trỏ đúng lịch sử cấp quyền, không tự bật lại grant đã revoke.';
COMMENT ON COLUMN public.memberships.joined_at IS 'Thời điểm hình thành membership; lịch sử cấp quyền từng lần được giữ ở membership_grants.';
COMMENT ON COLUMN public.memberships.removed_at IS 'Thời điểm membership bị remove; NULL khi chưa ghi nhận remove, không thay điều kiện status/current grant.';

/* Công dụng của public.notifications. */
COMMENT ON TABLE public.notifications IS 'Một mục inbox của một recipient, phân biệt EVENT và PUSH_TEST. Read state thuộc recipient; target typed giữ đích deep link mà không cấp quyền đọc vượt scope hiện hành.';
COMMENT ON COLUMN public.notifications.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.notifications.notification_id IS 'Identity mục inbox của recipient, là gốc fanout push/deep link; không thay Event source hoặc occurrence identity.';
COMMENT ON COLUMN public.notifications.recipient_user_id IS 'Thành viên nhận inbox/push; chỉ chính recipient được hưởng quyền đọc và thay đổi read state của inbox.';
COMMENT ON COLUMN public.notifications.kind IS 'EVENT là inbox từ Event nghiệp vụ; PUSH_TEST là test push không tạo Event giả.';
COMMENT ON COLUMN public.notifications.event_id IS 'Identity Event nghiệp vụ trong workspace; khác occurrence_id đại diện từng transition để giao webhook.';
COMMENT ON COLUMN public.notifications.target_type IS 'Loại đích deep link EVENT/EXECUTION/DEVICE/NOTIFICATION, quyết định target FK nào phải có hoặc phải NULL.';
COMMENT ON COLUMN public.notifications.target_device_id IS 'Thiết bị đích của action hoặc deep link; NULL khi nhánh không có device, nếu có phải cùng workspace và đúng pin.';
COMMENT ON COLUMN public.notifications.target_rule_execution_id IS 'Execution đích của notification; giữ identity lịch sử nhưng không kéo dài quyền đọc history sau retention/mất quyền.';
COMMENT ON COLUMN public.notifications.created_at IS 'Mốc tạo notification làm gốc expiry push +1 giờ; delivery fanout muộn không được lấy mốc worker mới làm gốc TTL.';
COMMENT ON COLUMN public.notifications.read_at IS 'Thời điểm recipient đánh dấu mục inbox đã đọc; không ACK/resolve Event và không chứng minh provider đã giao push.';

/* Công dụng của public.ota_download_tickets. */
COMMENT ON TABLE public.ota_download_tickets IS 'Bearer ticket tải artifact cho một OTA job. Lưu digest và expiry không vượt deadline job; không coi ticket là device proof-of-possession.';
COMMENT ON COLUMN public.ota_download_tickets.ticket_id IS 'Identity quản lý bearer ticket, không phải secret; ticket_digest dùng xác minh/consume.';
COMMENT ON COLUMN public.ota_download_tickets.ticket_digest IS 'Digest SHA-256 32 byte của bearer ticket, dùng lookup/consume hoặc tải artifact; raw ticket chỉ được trả qua kênh admission.';
COMMENT ON COLUMN public.ota_download_tickets.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.ota_download_tickets.ota_job_id IS 'Identity ý định OTA ổn định qua status/probe/recovery, dùng gắn nonce, artifact và maintenance epoch.';
COMMENT ON COLUMN public.ota_download_tickets.issued_at IS 'Thời điểm phát hành phiên/grant/credential/ticket, làm gốc tính TTL theo loại bản ghi.';
COMMENT ON COLUMN public.ota_download_tickets.expires_at IS 'Hạn bearer download ticket phải sau issued_at và không vượt deadline của OTA job; không reset khi tải lại.';
COMMENT ON COLUMN public.ota_download_tickets.revoked_at IS 'Thời điểm thu hồi quyền/credential; NULL nghĩa chưa ghi nhận thu hồi, không đồng nghĩa mọi điều kiện xác thực khác còn hợp lệ.';

/* Công dụng của public.ota_jobs. */
COMMENT ON TABLE public.ota_jobs IS 'Ý định OTA một thiết bị, chụp firmware nguồn/đích, nonce và maintenance epoch. RECOVERY_REQUIRED tiếp tục giữ slot cho tới settlement có đối soát; timeout không là proof rollback.';
COMMENT ON COLUMN public.ota_jobs.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.ota_jobs.ota_job_id IS 'Identity ý định OTA ổn định qua status/probe/recovery, dùng gắn nonce, artifact và maintenance epoch.';
COMMENT ON COLUMN public.ota_jobs.device_id IS 'Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng tenant.';
COMMENT ON COLUMN public.ota_jobs.firmware_package_id IS 'Identity canonical package firmware trong workspace, dùng liên kết compatibility và OTA jobs.';
COMMENT ON COLUMN public.ota_jobs.source_firmware_version_snapshot IS 'Firmware nguồn được chụp lúc OTA admission để đối soát upgrade/rollback sau reboot.';
COMMENT ON COLUMN public.ota_jobs.target_artifact_digest_snapshot IS 'SHA-256 image đích được chụp khi nhận OTA, không đổi theo package/config hiện tại.';
COMMENT ON COLUMN public.ota_jobs.job_nonce IS 'Nonce 32 byte gắn ý định OTA, giúp board/backend phân biệt job cũ và bằng chứng của lần update khác.';
COMMENT ON COLUMN public.ota_jobs.state IS 'Vòng đời OTA từ QUEUED tới dispatch/download/verify/reboot/health và terminal hoặc RECOVERY_REQUIRED; recovery vẫn giữ slot.';
COMMENT ON COLUMN public.ota_jobs.phase IS 'Pha kỹ thuật OTA hiện được job/status báo; khác state điều phối và phải được validator/worker kiểm theo protocol.';
COMMENT ON COLUMN public.ota_jobs.maintenance_epoch IS 'Thế hệ khóa bảo trì, dùng phân biệt OTA/dispatch đang hiện hành với callback cũ; không reset do reconnect.';
COMMENT ON COLUMN public.ota_jobs.admitted_at IS 'Thời điểm yêu cầu được backend nhận vào ledger sau kiểm điều kiện; không chứng minh side effect đã thực hiện.';
COMMENT ON COLUMN public.ota_jobs.deadline_at IS 'Deadline admitted_at + 10 phút của ý định OTA; hết deadline không tự settlement nếu chưa biết image/board state.';
COMMENT ON COLUMN public.ota_jobs.start_intent_at IS 'Thời điểm ghi ý định gửi START OTA trước network; có thể đã gửi khi mất ACK, không blind resend chỉ vì thiếu reply.';
COMMENT ON COLUMN public.ota_jobs.settled_at IS 'Thời điểm nghĩa vụ vận hành được đối soát xong và có thể nhả guard/quota; NULL tiếp tục giữ nghĩa vụ chưa giải quyết.';
COMMENT ON COLUMN public.ota_jobs.recovery_reason IS 'Lý do cần recovery/đối soát OTA đã redact; không tự giải phóng maintenance hoặc kết luận rollback.';
COMMENT ON COLUMN public.ota_jobs.recovery_boot_id IS 'Boot tham gia recovery được xác minh theo protocol; NULL khi chưa có bằng chứng boot phục hồi.';
COMMENT ON COLUMN public.ota_jobs.reconciled_at IS 'Thời điểm backend hoàn tất bước đối soát recovery, khác deadline và thời điểm board reboot.';
COMMENT ON COLUMN public.ota_jobs.revision IS 'Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng transaction contract.';

/* Công dụng của public.ota_probe_intents. */
COMMENT ON TABLE public.ota_probe_intents IS 'Ngân sách probe bền vững theo job/recovery epoch. Mỗi ý định probe có request identity để restart không reset budget hoặc tự phát lại START OTA.';
COMMENT ON COLUMN public.ota_probe_intents.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.ota_probe_intents.ota_job_id IS 'Identity ý định OTA ổn định qua status/probe/recovery, dùng gắn nonce, artifact và maintenance epoch.';
COMMENT ON COLUMN public.ota_probe_intents.recovery_epoch IS 'Thế hệ một đợt recovery/probe của job để ngân sách probe không bị dùng lại sau restart.';
COMMENT ON COLUMN public.ota_probe_intents.probe_number IS 'Số thứ tự probe trong một recovery epoch, từ 1 đến 3; không reset để vượt budget bằng retry.';
COMMENT ON COLUMN public.ota_probe_intents.request_id IS 'Identity duy nhất của probe request, dùng ghép reply với đúng ý định gửi.';
COMMENT ON COLUMN public.ota_probe_intents.intended_at IS 'Thời điểm ghi ý định probe OTA trước network call, dùng giữ budget bền vững qua restart.';
COMMENT ON COLUMN public.ota_probe_intents.sent_at IS 'Thời điểm adapter ghi nhận đã gửi probe; NULL khi chưa có xác nhận gửi, không mặc định nghĩa là chắc chắn chưa gửi.';
COMMENT ON COLUMN public.ota_probe_intents.reply_at IS 'Thời điểm server ghi nhận reply probe, dùng giải thích kết quả recovery và deadline.';
COMMENT ON COLUMN public.ota_probe_intents.reply_digest IS 'Digest 32 byte của reply probe nhận được, phục vụ đối soát cùng request mà không lưu nội dung bí mật.';
COMMENT ON COLUMN public.ota_probe_intents.state IS 'Trạng thái probe INTENT/SENT/REPLIED/UNKNOWN; missing reply không cho reset budget hoặc suy đã rollback.';

/* Công dụng của public.ota_status_receipts. */
COMMENT ON TABLE public.ota_status_receipts IS 'Status OTA được xác thực theo job/device/boot/credential và sequence. Digest phục vụ dedupe hoặc phát hiện cùng sequence khác body, không ghi đè status đã nhận.';
COMMENT ON COLUMN public.ota_status_receipts.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.ota_status_receipts.ota_job_id IS 'Identity ý định OTA ổn định qua status/probe/recovery, dùng gắn nonce, artifact và maintenance epoch.';
COMMENT ON COLUMN public.ota_status_receipts.status_sequence IS 'Sequence uint32 của status OTA, từ 0 đến 4294967295; cùng sequence khác digest phải được đối soát, không last-write-wins.';
COMMENT ON COLUMN public.ota_status_receipts.device_id IS 'Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng tenant.';
COMMENT ON COLUMN public.ota_status_receipts.payload_digest IS 'SHA-256 32 byte của payload đã chấp nhận, phục vụ dedupe và phát hiện cùng identity nhưng body mâu thuẫn.';
COMMENT ON COLUMN public.ota_status_receipts.boot_id IS 'Identity boot của thiết bị theo wire dạng text, không suy UUID; chỉ chấp nhận khi gắn với credential/connection đã xác minh.';
COMMENT ON COLUMN public.ota_status_receipts.credential_generation IS 'Thế hệ credential MQTT của thiết bị, phân biệt lần cấp mới với credential cũ đã thu hồi.';
COMMENT ON COLUMN public.ota_status_receipts.phase IS 'Pha kỹ thuật OTA hiện được job/status báo; khác state điều phối và phải được validator/worker kiểm theo protocol.';
COMMENT ON COLUMN public.ota_status_receipts.received_at IS 'Thời điểm server nhận gói dữ liệu/kết quả; phân biệt với observed_at do thiết bị hoặc nguồn sự kiện cung cấp.';
COMMENT ON COLUMN public.ota_status_receipts.sanitized_payload IS 'Payload quan sát đã được producer loại trường nhạy cảm, dùng audit/đối soát; SQL JSON type không tự làm redaction.';

/* Công dụng của public.outbox_consumptions. */
COMMENT ON TABLE public.outbox_consumptions IS 'Trạng thái xử lý riêng của từng consumer đối với một outbox event. Lease generation và complete CAS ngăn worker cũ settle công việc sau khi bị takeover.';
COMMENT ON COLUMN public.outbox_consumptions.outbox_event_id IS 'Identity outbox event đã commit, dùng ghép trạng thái riêng của từng consumer và claim/complete receipt.';
COMMENT ON COLUMN public.outbox_consumptions.consumer_code IS 'Tên pipeline nhận outbox event; mỗi consumer có trạng thái/lease riêng để không ảnh hưởng consumer khác.';
COMMENT ON COLUMN public.outbox_consumptions.state IS 'Tiến trình consumer PENDING/PROCESSING/RETRY_WAIT/COMPLETED/DEAD_LETTER; COMPLETED phải đi cùng completed_at.';
COMMENT ON COLUMN public.outbox_consumptions.available_at IS 'Thời điểm sớm nhất consumer được claim công việc, phục vụ pending/retry schedule bền vững.';
COMMENT ON COLUMN public.outbox_consumptions.lease_until IS 'Hạn thuê xử lý hiện hành của worker; lease hết không chứng minh network side effect chưa xảy ra.';
COMMENT ON COLUMN public.outbox_consumptions.lease_generation IS 'Thế hệ lease tăng khi claim/takeover, dùng CAS để worker cũ không settle kết quả của thế hệ mới.';
COMMENT ON COLUMN public.outbox_consumptions.attempt_count IS 'Số lần xử lý/claim đã tiêu hao theo pipeline; không tự coi một lần retry là một ý định nghiệp vụ mới.';
COMMENT ON COLUMN public.outbox_consumptions.completed_at IS 'Thời điểm tác vụ hoặc enrollment được ghi nhận hoàn tất theo điều kiện của bảng; không lấy timer client làm bằng chứng.';

/* Công dụng của public.outbox_events. */
COMMENT ON TABLE public.outbox_events IS 'Sự kiện nội bộ được producer ghi cùng transaction nghiệp vụ. Payload/version và event key ổn định cho các consumer xử lý sau commit, không thay network bằng transaction dài.';
COMMENT ON COLUMN public.outbox_events.outbox_event_id IS 'Identity outbox event đã commit, dùng ghép trạng thái riêng của từng consumer và claim/complete receipt.';
COMMENT ON COLUMN public.outbox_events.workspace_id IS 'Scope sự kiện; NULL là namespace IAM/global riêng, không được nhầm với quyền truy cập mọi workspace.';
COMMENT ON COLUMN public.outbox_events.event_key IS 'Khóa nghĩa vụ outbox ổn định để dedupe trong namespace workspace hoặc global IAM; không sinh key mới cho cùng retry.';
COMMENT ON COLUMN public.outbox_events.event_type IS 'Loại sự kiện được audit/outbox/webhook sử dụng; ý nghĩa/allowlist phụ thuộc bảng và schema contract.';
COMMENT ON COLUMN public.outbox_events.payload_schema_version IS 'Phiên bản schema payload outbox để consumer đọc đúng cấu trúc, không nhầm với entity revision.';
COMMENT ON COLUMN public.outbox_events.payload IS 'Document sự kiện nội bộ theo payload_schema_version; producer phải validation/redact trước ghi, không dùng thay authority entity.';
COMMENT ON COLUMN public.outbox_events.created_at IS 'Thời điểm tạo bản ghi dưới dạng timestamptz; dùng provenance/sắp xếp hoặc retention khi policy của bảng quy định.';

/* Công dụng của public.password_reset_admissions. */
COMMENT ON TABLE public.password_reset_admissions IS 'Nhật ký những lần reset mật khẩu đã được nhận xử lý thành công theo actor/target/workspace. Phục vụ đếm ngân sách reset và truy vết; không lưu mật khẩu tạm.';
COMMENT ON COLUMN public.password_reset_admissions.admission_id IS 'Identity một lần admission đã được ghi nhận trong ledger reset/rate; không phải token dùng xác thực.';
COMMENT ON COLUMN public.password_reset_admissions.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.password_reset_admissions.actor_user_id IS 'Tài khoản thực hiện hoặc khởi tạo thao tác, phục vụ kiểm quyền và truy vết; không lấy authority chỉ từ ID client gửi.';
COMMENT ON COLUMN public.password_reset_admissions.target_user_id IS 'Tài khoản đích của thao tác quản trị trong workspace, phân biệt với actor thực hiện thao tác.';
COMMENT ON COLUMN public.password_reset_admissions.admitted_at IS 'Thời điểm yêu cầu được backend nhận vào ledger sau kiểm điều kiện; không chứng minh side effect đã thực hiện.';

/* Công dụng của public.provisioning_operations. */
COMMENT ON TABLE public.provisioning_operations IS 'Ý định cấp credential và tiến trình bàn giao một lần qua USB/BLE. Tách kết quả cấu hình broker khỏi trạng thái phát secret; escrow chỉ là ciphertext tạm có key reference và hạn riêng.';
COMMENT ON COLUMN public.provisioning_operations.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.provisioning_operations.provisioning_operation_id IS 'Identity công việc cấp credential, dùng claim một lần và gắn enrollment đúng device/generation.';
COMMENT ON COLUMN public.provisioning_operations.device_id IS 'Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng tenant.';
COMMENT ON COLUMN public.provisioning_operations.credential_generation IS 'Thế hệ credential MQTT của thiết bị, phân biệt lần cấp mới với credential cũ đã thu hồi.';
COMMENT ON COLUMN public.provisioning_operations.delivery_channel IS 'Kênh phát credential USB_ONE_TIME/ENROLLMENT_BLE; quyết định binding/escrow/claim policy, không là trạng thái broker.';
COMMENT ON COLUMN public.provisioning_operations.state IS 'Kết quả cấu hình broker PENDING/READY/FAILED, tách khỏi delivery_status của secret để không báo board đã nhận credential chỉ vì broker READY.';
COMMENT ON COLUMN public.provisioning_operations.actor_user_id IS 'Tài khoản thực hiện hoặc khởi tạo thao tác, phục vụ kiểm quyền và truy vết; không lấy authority chỉ từ ID client gửi.';
COMMENT ON COLUMN public.provisioning_operations.intent_at IS 'Thời điểm lưu ý định trước side effect bên ngoài DB; dùng tính ngân sách/expiry và phục hồi khi mất ACK.';
COMMENT ON COLUMN public.provisioning_operations.expires_at IS 'Hạn escrow intent_at + 10 phút; broker ACK/retry/poll không kéo dài deadline, cleanup intent có thể sống lâu hơn escrow.';
COMMENT ON COLUMN public.provisioning_operations.broker_receipt_at IS 'Mốc backend có xác nhận cấu hình credential/ACL từ broker; khác MQTT PUBACK của message ứng dụng.';
COMMENT ON COLUMN public.provisioning_operations.claimed_at IS 'Thời điểm server tiêu thụ quyền phát credential một lần; không chứng minh client/board đã nhận được secret.';
COMMENT ON COLUMN public.provisioning_operations.secret_ciphertext IS 'Secret recoverable đã mã hóa cho escrow/ký webhook; key wrapping nằm ngoài DB và chỉ đường ghi có custody được dùng giá trị này.';
COMMENT ON COLUMN public.provisioning_operations.encryption_key_reference IS 'Tham chiếu/version của khóa dùng giải mã ciphertext, không chứa key material; NULL phải đồng bộ với nhánh không có ciphertext.';
COMMENT ON COLUMN public.provisioning_operations.delivery_status IS 'Tiến độ phát credential PENDING/AVAILABLE/CLAIMED/EXPIRED/UNAVAILABLE, tách khỏi state PENDING/READY/FAILED của operation.';

/* Công dụng của public.push_deliveries. */
COMMENT ON TABLE public.push_deliveries IS 'Nghĩa vụ giao một notification tới một installation tại fanout snapshot. Dedupe không chứa binding generation; rebind không tạo thêm delivery cho cùng notification/installation.';
COMMENT ON COLUMN public.push_deliveries.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.push_deliveries.push_delivery_id IS 'Identity nghĩa vụ giao push, giữ nguyên qua mọi send attempt và phản hồi provider.';
COMMENT ON COLUMN public.push_deliveries.notification_id IS 'Identity mục inbox của recipient, là gốc fanout push/deep link; không thay Event source hoặc occurrence identity.';
COMMENT ON COLUMN public.push_deliveries.installation_id IS 'Identity một cài đặt app Android, không đồng nghĩa user hoặc hardware device; rebind cần proof của installation.';
COMMENT ON COLUMN public.push_deliveries.recipient_user_id IS 'Thành viên nhận inbox/push; chỉ chính recipient được hưởng quyền đọc và thay đổi read state của inbox.';
COMMENT ON COLUMN public.push_deliveries.binding_generation IS 'Thế hệ gắn user/session của installation; delivery chụp làm fence, không đưa vào dedupe notification/installation.';
COMMENT ON COLUMN public.push_deliveries.state IS 'Tiến trình PENDING/SENDING/RETRY_WAIT và terminal ACCEPTED/FAILED/EXPIRED/SUPPRESSED; ACCEPTED chỉ chứng minh provider nhận.';
COMMENT ON COLUMN public.push_deliveries.created_at IS 'Bản sao Notification.created_at tại fanout, không là thời điểm worker gửi lần đầu.';
COMMENT ON COLUMN public.push_deliveries.expires_at IS 'Hạn gửi Notification.created_at + 1 giờ, độc lập retention history 30 ngày; rebind/retry không kéo dài TTL.';
COMMENT ON COLUMN public.push_deliveries.terminal_at IS 'Thời điểm quan sát trạng thái kết thúc của command/delivery; không thay gốc expiry hoặc gốc retention.';
COMMENT ON COLUMN public.push_deliveries.next_attempt_at IS 'Thời điểm sớm nhất được thử gửi tiếp; không được gửi sớm hơn mốc này hoặc vượt expiry/budget của parent.';
COMMENT ON COLUMN public.push_deliveries.lease_until IS 'Hạn thuê xử lý hiện hành của worker; lease hết không chứng minh network side effect chưa xảy ra.';
COMMENT ON COLUMN public.push_deliveries.lease_generation IS 'Thế hệ lease tăng khi claim/takeover, dùng CAS để worker cũ không settle kết quả của thế hệ mới.';

/* Công dụng của public.push_delivery_attempts. */
COMMENT ON TABLE public.push_delivery_attempts IS 'Ý định gửi push từng lần, tiêu hao ngân sách trước network call. Lưu token generation và outcome quan sát; provider ACCEPTED không có nghĩa người dùng đã đọc.';
COMMENT ON COLUMN public.push_delivery_attempts.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.push_delivery_attempts.push_delivery_id IS 'Identity nghĩa vụ giao push, giữ nguyên qua mọi send attempt và phản hồi provider.';
COMMENT ON COLUMN public.push_delivery_attempts.attempt_number IS 'Số thứ tự send intent của một delivery, bắt đầu 1; PK và admission guard bảo vệ thứ tự/ngân sách.';
COMMENT ON COLUMN public.push_delivery_attempts.intent_at IS 'Thời điểm lưu ý định trước side effect bên ngoài DB; dùng tính ngân sách/expiry và phục hồi khi mất ACK.';
COMMENT ON COLUMN public.push_delivery_attempts.token_generation IS 'Thế hệ provider token của installation; attempt giữ generation để giải thích token rotate và reply cũ.';
COMMENT ON COLUMN public.push_delivery_attempts.provider_request_id IS 'Identity request/message do push provider trả để đối chiếu attempt; không lưu bearer header hoặc response secret.';
COMMENT ON COLUMN public.push_delivery_attempts.outcome IS 'Kết quả quan sát INTENT/ACCEPTED/TRANSIENT_FAILURE/PERMANENT_FAILURE/UNKNOWN của một send intent; không đồng nghĩa recipient đã đọc.';
COMMENT ON COLUMN public.push_delivery_attempts.observed_at IS 'Thời điểm quan sát được dữ liệu/kết quả; nguồn và ý nghĩa được quy định theo bảng, không mặc định là thời gian commit.';
COMMENT ON COLUMN public.push_delivery_attempts.next_delay_seconds IS 'Khoảng chờ retry tiếp theo tính bằng giây đã được adapter/policy chọn; không phải timestamp tuyệt đối.';

/* Công dụng của public.push_delivery_history. */
COMMENT ON VIEW public.push_delivery_history IS 'View lịch sử push trong cutoff 30 ngày từ created_at, khác hạn gửi 1 giờ.';
COMMENT ON COLUMN public.push_delivery_history.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.push_delivery_history.push_delivery_id IS 'Identity nghĩa vụ giao push, giữ nguyên qua mọi send attempt và phản hồi provider.';
COMMENT ON COLUMN public.push_delivery_history.notification_id IS 'Identity mục inbox của recipient, là gốc fanout push/deep link; không thay Event source hoặc occurrence identity.';
COMMENT ON COLUMN public.push_delivery_history.installation_id IS 'Identity một cài đặt app Android, không đồng nghĩa user hoặc hardware device; rebind cần proof của installation.';
COMMENT ON COLUMN public.push_delivery_history.recipient_user_id IS 'Thành viên nhận inbox/push; chỉ chính recipient được hưởng quyền đọc và thay đổi read state của inbox.';
COMMENT ON COLUMN public.push_delivery_history.binding_generation IS 'Thế hệ gắn user/session của installation; delivery chụp làm fence, không đưa vào dedupe notification/installation.';
COMMENT ON COLUMN public.push_delivery_history.state IS 'Tiến trình PENDING/SENDING/RETRY_WAIT và terminal ACCEPTED/FAILED/EXPIRED/SUPPRESSED; ACCEPTED chỉ chứng minh provider nhận.';
COMMENT ON COLUMN public.push_delivery_history.created_at IS 'Bản sao Notification.created_at tại fanout, không là thời điểm worker gửi lần đầu.';
COMMENT ON COLUMN public.push_delivery_history.expires_at IS 'Hạn gửi Notification.created_at + 1 giờ, độc lập retention history 30 ngày; rebind/retry không kéo dài TTL.';
COMMENT ON COLUMN public.push_delivery_history.terminal_at IS 'Thời điểm quan sát trạng thái kết thúc của command/delivery; không thay gốc expiry hoặc gốc retention.';
COMMENT ON COLUMN public.push_delivery_history.next_attempt_at IS 'Thời điểm sớm nhất được thử gửi tiếp; không được gửi sớm hơn mốc này hoặc vượt expiry/budget của parent.';
COMMENT ON COLUMN public.push_delivery_history.lease_until IS 'Hạn thuê xử lý hiện hành của worker; lease hết không chứng minh network side effect chưa xảy ra.';
COMMENT ON COLUMN public.push_delivery_history.lease_generation IS 'Thế hệ lease tăng khi claim/takeover, dùng CAS để worker cũ không settle kết quả của thế hệ mới.';

/* Công dụng của public.push_installations. */
COMMENT ON TABLE public.push_installations IS 'Một cài đặt Android với proof, provider token mã hóa và binding user/session hiện hành. Generation/sequence phục vụ rebind, token rotate và tránh cleanup phiên cũ làm mất binding mới.';
COMMENT ON COLUMN public.push_installations.installation_id IS 'Identity một cài đặt app Android, không đồng nghĩa user hoặc hardware device; rebind cần proof của installation.';
COMMENT ON COLUMN public.push_installations.installation_proof_digest IS 'Digest proof của một installation, dùng xác minh rebind/token update; không chỉ tin installation_id do client khai.';
COMMENT ON COLUMN public.push_installations.platform IS 'Nền tảng installation được triển khai, hiện ANDROID; không tự mở scope iOS đã hoãn.';
COMMENT ON COLUMN public.push_installations.token_ciphertext IS 'Provider push token đã mã hóa; chỉ adapter gửi push được giải mã theo custody, không trả ra UI/log.';
COMMENT ON COLUMN public.push_installations.token_digest IS 'Digest 32 byte của provider push token hiện hành, phục vụ dedupe token giữa installation; raw token nằm ở ciphertext.';
COMMENT ON COLUMN public.push_installations.encryption_key_reference IS 'Tham chiếu/version của khóa dùng giải mã ciphertext, không chứa key material; NULL phải đồng bộ với nhánh không có ciphertext.';
COMMENT ON COLUMN public.push_installations.token_generation IS 'Thế hệ provider token của installation; attempt giữ generation để giải thích token rotate và reply cũ.';
COMMENT ON COLUMN public.push_installations.binding_generation IS 'Thế hệ gắn user/session của installation; delivery chụp làm fence, không đưa vào dedupe notification/installation.';
COMMENT ON COLUMN public.push_installations.client_sequence IS 'Sequence cập nhật từ installation để từ chối update/rebind tới trễ, không dùng arrival time làm last-write-wins.';
COMMENT ON COLUMN public.push_installations.permission_state IS 'Permission Android do app báo: UNKNOWN/GRANTED/DENIED/NOT_DETERMINED; không tự nâng preference hoặc session quyền.';
COMMENT ON COLUMN public.push_installations.enabled IS 'Cờ cho phép nhận thông báo theo installation hoặc preference; còn phải giao với permission, binding và quyền hiện hành.';
COMMENT ON COLUMN public.push_installations.app_version IS 'Phiên bản app do installation khai để chẩn đoán tương thích; không phải bằng chứng xác thực hoặc quyền.';
COMMENT ON COLUMN public.push_installations.active_user_id IS 'Tài khoản hiện đang gắn với installation push; phải cùng active_session_id hoặc cùng NULL khi chưa bind.';
COMMENT ON COLUMN public.push_installations.active_session_id IS 'Phiên đang sở hữu binding push hiện hành; cleanup phiên cũ phải CAS đúng binding để không xóa binding phiên mới.';
COMMENT ON COLUMN public.push_installations.updated_at IS 'Thời điểm cập nhật gần nhất do đường ghi quản lý; không mặc định SQL tự cập nhật nếu không có trigger tương ứng.';

/* Công dụng của public.rate_limit_admissions. */
COMMENT ON TABLE public.rate_limit_admissions IS 'Nhật ký admission đã tính ngân sách theo policy và principal typed. Dùng đếm rate giữa nhiều backend; login bucket và password-reset admission có ledger chuyên biệt riêng.';
COMMENT ON COLUMN public.rate_limit_admissions.admission_id IS 'Identity một lần admission đã được ghi nhận trong ledger reset/rate; không phải token dùng xác thực.';
COMMENT ON COLUMN public.rate_limit_admissions.workspace_id IS 'Workspace của policy scoped; NULL khi policy được phép ở namespace global, API key luôn phải có scope workspace.';
COMMENT ON COLUMN public.rate_limit_admissions.user_id IS 'Principal user tiêu hao rate admission; chỉ có đúng một nhánh user_id hoặc api_key_id.';
COMMENT ON COLUMN public.rate_limit_admissions.api_key_id IS 'Principal API key tiêu hao rate admission, luôn gắn với workspace resolve từ key.';
COMMENT ON COLUMN public.rate_limit_admissions.policy_code IS 'Identity policy rate-limit đã được duyệt, dùng nhóm admission và cửa sổ đếm; không cho client tự chọn policy để bỏ giới hạn.';
COMMENT ON COLUMN public.rate_limit_admissions.admitted_at IS 'Thời điểm yêu cầu được backend nhận vào ledger sau kiểm điều kiện; không chứng minh side effect đã thực hiện.';
COMMENT ON COLUMN public.rate_limit_admissions.request_correlation_id IS 'Identity request/flow đã tiêu hao rate admission, dùng truy vết và đối chiếu thay vì đếm lại cùng nghĩa vụ.';

/* Công dụng của public.rule_draft_actions. */
COMMENT ON TABLE public.rule_draft_actions IS 'Chuỗi action của rule draft theo thứ tự, với các nhánh SET_VALUE/WAIT/NOTIFY được biểu diễn typed. Lưu cấu hình hành động, không lưu kết quả chạy.';
COMMENT ON COLUMN public.rule_draft_actions.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.rule_draft_actions.rule_id IS 'Identity gốc rule trong workspace, dùng nhóm draft/version/runtime; không là identity một lần chạy.';
COMMENT ON COLUMN public.rule_draft_actions.action_position IS 'Chỉ số action bắt đầu 0 trong chuỗi tối đa 5 bước, dùng ghép definition/action execution/job.';
COMMENT ON COLUMN public.rule_draft_actions.action_type IS 'Loại hành động SET_VALUE/WAIT/NOTIFY; mỗi nhánh yêu cầu bộ trường typed riêng, không chứa code/script tùy ý.';
COMMENT ON COLUMN public.rule_draft_actions.wait_seconds IS 'Thời lượng WAIT theo giây, từ 5 đến 600 cho một bước; tổng WAIT của version còn bị giới hạn 600 giây.';
COMMENT ON COLUMN public.rule_draft_actions.target_device_id IS 'Thiết bị đích của action hoặc deep link; NULL khi nhánh không có device, nếu có phải cùng workspace và đúng pin.';
COMMENT ON COLUMN public.rule_draft_actions.target_template_version_id IS 'Template version của target device, lặp để FK bảo vệ target stream đúng pin.';
COMMENT ON COLUMN public.rule_draft_actions.target_stream_key IS 'Kênh điều khiển đích trong pinned template version, không chỉ một stream cùng tên ở version bất kỳ.';
COMMENT ON COLUMN public.rule_draft_actions.target_value IS 'Literal JSON của SET_VALUE, phải qua kiểm datatype/range/capability; không được dùng expression hoặc script làm giá trị.';
COMMENT ON COLUMN public.rule_draft_actions.notification_config IS 'Cấu hình NOTIFY theo schema, chỉ tồn tại ở nhánh NOTIFY; nội dung phải được validation/redact khi tạo Event.';

/* Công dụng của public.rule_draft_references. */
COMMENT ON TABLE public.rule_draft_references IS 'Các tham chiếu resource trích từ AST/trigger/action của draft, định danh theo đường dẫn trong tài liệu. FK bảo vệ scope/pin; validator còn phải kiểm đủ và khớp hai chiều với AST.';
COMMENT ON COLUMN public.rule_draft_references.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.rule_draft_references.rule_id IS 'Identity gốc rule trong workspace, dùng nhóm draft/version/runtime; không là identity một lần chạy.';
COMMENT ON COLUMN public.rule_draft_references.reference_path IS 'Đường dẫn ổn định tới một reference trong AST/trigger/action snapshot, dùng kiểm đủ và đúng hai chiều với document.';
COMMENT ON COLUMN public.rule_draft_references.device_id IS 'Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng tenant.';
COMMENT ON COLUMN public.rule_draft_references.template_version_id IS 'Identity snapshot template cụ thể, dùng pin schema và kiểm đúng definition trong workspace.';
COMMENT ON COLUMN public.rule_draft_references.stream_key IS 'Khóa kỹ thuật ổn định của kênh trong template/version; không dùng nhãn hiển thị thay khóa schema.';
COMMENT ON COLUMN public.rule_draft_references.reference_kind IS 'Reference thuộc TRIGGER/CONDITION/ACTION, giúp validator đối chiếu đúng vai trò tài nguyên tại publish/save.';

/* Công dụng của public.rule_drafts. */
COMMENT ON TABLE public.rule_drafts IS 'Nội dung rule hiện đang soạn: trigger, AST điều kiện và policy. Chưa là định nghĩa được thực thi cho đến khi được validate và publish.';
COMMENT ON COLUMN public.rule_drafts.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.rule_drafts.rule_id IS 'Identity gốc rule trong workspace, dùng nhóm draft/version/runtime; không là identity một lần chạy.';
COMMENT ON COLUMN public.rule_drafts.trigger_type IS 'Nguồn kích hoạt THRESHOLD/SCHEDULE/CONNECTIVITY/MANUAL của rule, quyết định shape trigger_config cần validate.';
COMMENT ON COLUMN public.rule_drafts.trigger_config IS 'Cấu hình trigger theo schema version; JSON object CHECK chỉ kiểm dạng ngoài, không thay validator typed và quyền resource.';
COMMENT ON COLUMN public.rule_drafts.condition_ast IS 'Cây điều kiện AND/OR/literal theo rule contract; backend phải kiểm depth/type/leaves và bijection với reference rows.';
COMMENT ON COLUMN public.rule_drafts.schema_version IS 'Phiên bản cấu trúc document dashboard/rule, hiện 1; khác revision chỉnh sửa và version publish.';
COMMENT ON COLUMN public.rule_drafts.cooldown_seconds IS 'Thời gian nghỉ tối thiểu giữa các lần admission rule, đơn vị giây, từ 10 đến 3600 theo policy rule.';
COMMENT ON COLUMN public.rule_drafts.priority IS 'Mức ưu tiên HIGH/NORMAL/LOW của rule, không tự cho quyền vượt manual epoch hoặc guard actuator.';
COMMENT ON COLUMN public.rule_drafts.on_failure IS 'Policy STOP/CONTINUE cho lỗi đã biết của chuỗi; UNKNOWN vẫn cần dừng/đối soát theo contract, không tự chạy bước sau.';

/* Công dụng của public.rule_execution_snapshots. */
COMMENT ON TABLE public.rule_execution_snapshots IS 'Payload giải thích execution: input, condition trace và snapshot định nghĩa. Lưu sự thật tại lúc đánh giá để người dùng đọc lịch sử mà không live-join vào draft đã đổi.';
COMMENT ON COLUMN public.rule_execution_snapshots.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.rule_execution_snapshots.rule_execution_id IS 'Identity một lần quyết định/chạy rule version, dùng quota, history, action chain và notification target.';
COMMENT ON COLUMN public.rule_execution_snapshots.input_snapshot IS 'Dữ liệu đầu vào/quality/time được chụp tại evaluation để giải thích quyết định mà không lấy latest mới ghi đè lịch sử.';
COMMENT ON COLUMN public.rule_execution_snapshots.condition_trace IS 'Trace kết quả từng phần của AST tại evaluation, phục vụ giải thích TRUE/FALSE/UNKNOWN và dry-run/history.';
COMMENT ON COLUMN public.rule_execution_snapshots.definition_snapshot IS 'Bản sao định nghĩa cần giữ cho lịch sử khi policy cho phép; không live-join draft mutable để diễn giải execution cũ.';

/* Công dụng của public.rule_executions. */
COMMENT ON TABLE public.rule_executions IS 'Mỗi lần quyết định/chạy một rule version với trigger identity ổn định và deadline 15 phút. Là ledger runtime cho quota, tiến độ và outcome, tách khỏi payload lịch sử lớn.';
COMMENT ON COLUMN public.rule_executions.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.rule_executions.rule_execution_id IS 'Identity một lần quyết định/chạy rule version, dùng quota, history, action chain và notification target.';
COMMENT ON COLUMN public.rule_executions.rule_id IS 'Identity gốc rule trong workspace, dùng nhóm draft/version/runtime; không là identity một lần chạy.';
COMMENT ON COLUMN public.rule_executions.rule_version_id IS 'Identity rule snapshot đã publish, dùng pin trigger/action/execution thay vì đọc draft hiện hành.';
COMMENT ON COLUMN public.rule_executions.trigger_key IS 'Identity ổn định của trigger/episode/occurrence theo version; dùng dedupe, không sinh key mới chỉ vì worker restart.';
COMMENT ON COLUMN public.rule_executions.state IS 'Trạng thái RUNNING/WAITING hoặc kết quả SUCCEEDED/PARTIAL/FAILED/CANCELLED/NEEDS_ATTENTION/NO_MATCH; RUNNING/WAITING chiếm quota.';
COMMENT ON COLUMN public.rule_executions.admitted_at IS 'Thời điểm yêu cầu được backend nhận vào ledger sau kiểm điều kiện; không chứng minh side effect đã thực hiện.';
COMMENT ON COLUMN public.rule_executions.deadline_at IS 'Deadline admitted_at + 15 phút cho cả execution; WAIT/restart không kéo dài ngân sách toàn chuỗi.';
COMMENT ON COLUMN public.rule_executions.ended_at IS 'Thời điểm execution/action kết thúc; NULL khi chưa ghi nhận kết thúc, outcome/state là trục kết quả riêng.';
COMMENT ON COLUMN public.rule_executions.next_action_position IS 'Vị trí bước kế của execution, miền 0..5; giá trị 5 có thể biểu diễn đã qua bước cuối trong chuỗi tối đa 5 action.';
COMMENT ON COLUMN public.rule_executions.owner_user_id_snapshot IS 'Owner được chụp khi execution admission, dùng phân quyền lịch sử theo policy; request vẫn phải recheck membership hiện hành.';
COMMENT ON COLUMN public.rule_executions.failure_reason IS 'Nguyên nhân thất bại đã chuẩn hóa/redact cho vận hành và lịch sử; không lưu response bí mật của dịch vụ ngoài.';

/* Công dụng của public.rule_runtime. */
COMMENT ON TABLE public.rule_runtime IS 'Trạng thái điều phối rule đang chạy như active generation và cooldown. Lưu bền vững để restart không xóa khoảng nghỉ hoặc dùng lại thế hệ runtime cũ.';
COMMENT ON COLUMN public.rule_runtime.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.rule_runtime.rule_id IS 'Identity gốc rule trong workspace, dùng nhóm draft/version/runtime; không là identity một lần chạy.';
COMMENT ON COLUMN public.rule_runtime.active_generation IS 'Thế hệ kích hoạt runtime rule, dùng phân biệt công việc cũ sau enable/disable/publish lại.';
COMMENT ON COLUMN public.rule_runtime.cooldown_until IS 'Mốc UTC kết thúc cooldown đang có hiệu lực; restart không được reset mốc để lách giới hạn.';
COMMENT ON COLUMN public.rule_runtime.error_disabled_reason IS 'Nguyên nhân rule bị tắt do lỗi/rate policy, đã chuẩn hóa để hiển thị và yêu cầu thao tác phục hồi phù hợp.';
COMMENT ON COLUMN public.rule_runtime.current_rule_version_id IS 'Rule version runtime hiện hành của đúng rule, dùng phối hợp active generation/cooldown với coordinator.';

/* Công dụng của public.rule_trigger_receipts. */
COMMENT ON TABLE public.rule_trigger_receipts IS 'Quyết định đã xử lý một trigger identity: nhận chạy, không khớp hoặc bị chặn. Giữ receipt chống replay ngay cả khi payload history execution được purge.';
COMMENT ON COLUMN public.rule_trigger_receipts.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.rule_trigger_receipts.rule_version_id IS 'Identity rule snapshot đã publish, dùng pin trigger/action/execution thay vì đọc draft hiện hành.';
COMMENT ON COLUMN public.rule_trigger_receipts.trigger_key IS 'Identity ổn định của trigger/episode/occurrence theo version; dùng dedupe, không sinh key mới chỉ vì worker restart.';
COMMENT ON COLUMN public.rule_trigger_receipts.decision IS 'Quyết định đã xử lý trigger: ADMITTED/NO_MATCH/SUPPRESSED/REJECTED, phục vụ chống lặp admission.';
COMMENT ON COLUMN public.rule_trigger_receipts.decided_at IS 'Thời điểm quyết định trigger được ghi bền vững, không dùng thời điểm worker đọc lại làm lần trigger mới.';
COMMENT ON COLUMN public.rule_trigger_receipts.rule_execution_id IS 'Identity một lần quyết định/chạy rule version, dùng quota, history, action chain và notification target.';

/* Công dụng của public.rule_trigger_states. */
COMMENT ON TABLE public.rule_trigger_states IS 'Trạng thái episode/hold của trigger trong một rule version. Giữ mốc fresh, armed và sequence để tránh fire lặp hoặc cộng hold từ dữ liệu stale.';
COMMENT ON COLUMN public.rule_trigger_states.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.rule_trigger_states.rule_version_id IS 'Identity rule snapshot đã publish, dùng pin trigger/action/execution thay vì đọc draft hiện hành.';
COMMENT ON COLUMN public.rule_trigger_states.trigger_key IS 'Identity ổn định của trigger/episode/occurrence theo version; dùng dedupe, không sinh key mới chỉ vì worker restart.';
COMMENT ON COLUMN public.rule_trigger_states.is_armed IS 'True khi trigger episode sẵn sàng nhận một lần fire theo policy hysteresis/hold; không thay kiểm freshness input.';
COMMENT ON COLUMN public.rule_trigger_states.hold_started_at IS 'Mốc bắt đầu hold liên tục đủ điều kiện; stale/restart phải xử lý theo policy, không cộng thời gian mất dữ liệu như hold hợp lệ.';
COMMENT ON COLUMN public.rule_trigger_states.last_fresh_at IS 'Thời điểm input/trigger gần nhất còn đủ fresh, dùng reset hold hoặc xác định episode không còn tin cậy.';
COMMENT ON COLUMN public.rule_trigger_states.episode_sequence IS 'Sequence episode tăng để identity lần fire không bị tái sử dụng khi condition bật/tắt hoặc worker phục hồi.';
COMMENT ON COLUMN public.rule_trigger_states.last_marker_sequence IS 'Marker dữ liệu cuối đã xử lý cho trigger state, tránh mẫu lặp làm tăng hold hoặc fire lại.';

/* Công dụng của public.rule_version_actions. */
COMMENT ON TABLE public.rule_version_actions IS 'Chuỗi action thuộc rule version đã công bố. Dùng cùng action_position trong execution để xác định chính xác hành động nào được chạy.';
COMMENT ON COLUMN public.rule_version_actions.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.rule_version_actions.rule_version_id IS 'Identity rule snapshot đã publish, dùng pin trigger/action/execution thay vì đọc draft hiện hành.';
COMMENT ON COLUMN public.rule_version_actions.action_position IS 'Chỉ số action bắt đầu 0 trong chuỗi tối đa 5 bước, dùng ghép definition/action execution/job.';
COMMENT ON COLUMN public.rule_version_actions.action_type IS 'Loại hành động SET_VALUE/WAIT/NOTIFY; mỗi nhánh yêu cầu bộ trường typed riêng, không chứa code/script tùy ý.';
COMMENT ON COLUMN public.rule_version_actions.wait_seconds IS 'Thời lượng WAIT theo giây, từ 5 đến 600 cho một bước; tổng WAIT của version còn bị giới hạn 600 giây.';
COMMENT ON COLUMN public.rule_version_actions.target_device_id IS 'Thiết bị đích của action hoặc deep link; NULL khi nhánh không có device, nếu có phải cùng workspace và đúng pin.';
COMMENT ON COLUMN public.rule_version_actions.target_template_version_id IS 'Template version của target device, lặp để FK bảo vệ target stream đúng pin.';
COMMENT ON COLUMN public.rule_version_actions.target_stream_key IS 'Kênh điều khiển đích trong pinned template version, không chỉ một stream cùng tên ở version bất kỳ.';
COMMENT ON COLUMN public.rule_version_actions.target_value IS 'Literal JSON của SET_VALUE, phải qua kiểm datatype/range/capability; không được dùng expression hoặc script làm giá trị.';
COMMENT ON COLUMN public.rule_version_actions.notification_config IS 'Cấu hình NOTIFY theo schema, chỉ tồn tại ở nhánh NOTIFY; nội dung phải được validation/redact khi tạo Event.';

/* Công dụng của public.rule_version_references. */
COMMENT ON TABLE public.rule_version_references IS 'Các tham chiếu thiết bị/kênh theo đường dẫn trong rule version đã công bố. Giữ quan hệ typed và pinned, không thay thế kiểm tra AST/reference completeness của validator.';
COMMENT ON COLUMN public.rule_version_references.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.rule_version_references.rule_version_id IS 'Identity rule snapshot đã publish, dùng pin trigger/action/execution thay vì đọc draft hiện hành.';
COMMENT ON COLUMN public.rule_version_references.reference_path IS 'Đường dẫn ổn định tới một reference trong AST/trigger/action snapshot, dùng kiểm đủ và đúng hai chiều với document.';
COMMENT ON COLUMN public.rule_version_references.device_id IS 'Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng tenant.';
COMMENT ON COLUMN public.rule_version_references.template_version_id IS 'Identity snapshot template cụ thể, dùng pin schema và kiểm đúng definition trong workspace.';
COMMENT ON COLUMN public.rule_version_references.stream_key IS 'Khóa kỹ thuật ổn định của kênh trong template/version; không dùng nhãn hiển thị thay khóa schema.';
COMMENT ON COLUMN public.rule_version_references.reference_kind IS 'Reference thuộc TRIGGER/CONDITION/ACTION, giúp validator đối chiếu đúng vai trò tài nguyên tại publish/save.';

/* Công dụng của public.rule_versions. */
COMMENT ON TABLE public.rule_versions IS 'Ảnh chụp rule tại một lần publish, gồm điều kiện, trigger và policy. Execution tham chiếu phiên bản này để restart hoặc chỉnh draft không đổi định nghĩa lịch sử.';
COMMENT ON COLUMN public.rule_versions.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.rule_versions.rule_version_id IS 'Identity rule snapshot đã publish, dùng pin trigger/action/execution thay vì đọc draft hiện hành.';
COMMENT ON COLUMN public.rule_versions.rule_id IS 'Identity gốc rule trong workspace, dùng nhóm draft/version/runtime; không là identity một lần chạy.';
COMMENT ON COLUMN public.rule_versions.version_number IS 'Số phiên bản publish tăng trong cùng template/rule, bắt đầu 1; khác revision chỉnh sửa metadata.';
COMMENT ON COLUMN public.rule_versions.trigger_type IS 'Nguồn kích hoạt THRESHOLD/SCHEDULE/CONNECTIVITY/MANUAL của rule, quyết định shape trigger_config cần validate.';
COMMENT ON COLUMN public.rule_versions.trigger_config IS 'Cấu hình trigger theo schema version; JSON object CHECK chỉ kiểm dạng ngoài, không thay validator typed và quyền resource.';
COMMENT ON COLUMN public.rule_versions.condition_ast IS 'Cây điều kiện AND/OR/literal theo rule contract; backend phải kiểm depth/type/leaves và bijection với reference rows.';
COMMENT ON COLUMN public.rule_versions.schema_version IS 'Phiên bản cấu trúc document dashboard/rule, hiện 1; khác revision chỉnh sửa và version publish.';
COMMENT ON COLUMN public.rule_versions.cooldown_seconds IS 'Thời gian nghỉ tối thiểu giữa các lần admission rule, đơn vị giây, từ 10 đến 3600 theo policy rule.';
COMMENT ON COLUMN public.rule_versions.priority IS 'Mức ưu tiên HIGH/NORMAL/LOW của rule, không tự cho quyền vượt manual epoch hoặc guard actuator.';
COMMENT ON COLUMN public.rule_versions.on_failure IS 'Policy STOP/CONTINUE cho lỗi đã biết của chuỗi; UNKNOWN vẫn cần dừng/đối soát theo contract, không tự chạy bước sau.';
COMMENT ON COLUMN public.rule_versions.published_at IS 'Thời điểm tạo snapshot đã công bố; không thay đổi theo các lần sửa draft sau đó.';
COMMENT ON COLUMN public.rule_versions.content_digest IS 'SHA-256 32 byte của nội dung snapshot đã publish, dùng nhận diện/đối chiếu định nghĩa thay vì hash metadata draft hiện tại.';

/* Công dụng của public.rules. */
COMMENT ON TABLE public.rules IS 'Gốc rule thuộc một owner: metadata, trạng thái bật/tắt, revision draft và con trỏ phiên bản đang dùng. Draft và version runtime được tách để chỉnh sửa không thay execution đang chạy.';
COMMENT ON COLUMN public.rules.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.rules.rule_id IS 'Identity gốc rule trong workspace, dùng nhóm draft/version/runtime; không là identity một lần chạy.';
COMMENT ON COLUMN public.rules.owner_user_id IS 'Tài khoản sở hữu tài nguyên trong workspace; backend phải kiểm membership và quyền hiện hành khi đọc/ghi.';
COMMENT ON COLUMN public.rules.name IS 'Tên hiển thị do người dùng đặt cho tài nguyên; không dùng làm identity, quyền hoặc khóa chống lặp.';
COMMENT ON COLUMN public.rules.lifecycle_status IS 'Trạng thái vòng đời quản lý tài nguyên, tách khỏi presence hoặc tiến độ của job đang chạy.';
COMMENT ON COLUMN public.rules.revision IS 'Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng transaction contract.';
COMMENT ON COLUMN public.rules.draft_revision IS 'Phiên bản chỉnh sửa của draft rule, tách khỏi revision metadata root và version_number của snapshot đã publish.';
COMMENT ON COLUMN public.rules.active_rule_version_id IS 'Version đang được rule chọn để thực thi; FK buộc thuộc cùng rule, khác draft đang chỉnh.';
COMMENT ON COLUMN public.rules.created_at IS 'Thời điểm tạo bản ghi dưới dạng timestamptz; dùng provenance/sắp xếp hoặc retention khi policy của bảng quy định.';
COMMENT ON COLUMN public.rules.updated_at IS 'Thời điểm cập nhật gần nhất do đường ghi quản lý; không mặc định SQL tự cập nhật nếu không có trigger tương ứng.';

/* Công dụng của public.schedule_occurrences. */
COMMENT ON TABLE public.schedule_occurrences IS 'Mỗi lần lịch được định danh ổn định theo rule version và occurrence key. Giữ thời gian/timezone snapshot cùng kết quả admission để tránh chạy trùng sau restart/DST.';
COMMENT ON COLUMN public.schedule_occurrences.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.schedule_occurrences.rule_version_id IS 'Identity rule snapshot đã publish, dùng pin trigger/action/execution thay vì đọc draft hiện hành.';
COMMENT ON COLUMN public.schedule_occurrences.occurrence_key IS 'Identity calendar ổn định của một lần lịch trong rule version, dùng chống chạy trùng/catchup sai sau restart.';
COMMENT ON COLUMN public.schedule_occurrences.scheduled_at IS 'Instant lịch đã resolve theo timezone/DST policy; không tính lại từ timezone mặc định mới khi job được đọc lại.';
COMMENT ON COLUMN public.schedule_occurrences.timezone_snapshot IS 'Múi giờ IANA được chụp khi định danh schedule occurrence, giữ đúng calendar/DST policy dù cấu hình mặc định đổi.';
COMMENT ON COLUMN public.schedule_occurrences.state IS 'Tiến trình lần lịch PENDING/ADMITTED/SKIPPED/CANCELLED; không tạo occurrence identity mới khi restart đọc lại.';
COMMENT ON COLUMN public.schedule_occurrences.rule_execution_id IS 'Identity một lần quyết định/chạy rule version, dùng quota, history, action chain và notification target.';

/* Công dụng của public.sessions. */
COMMENT ON TABLE public.sessions IS 'Mỗi hàng là một phiên đăng nhập Web hoặc Android, có chế độ full/limited và hạn 24 giờ. Lưu digest để xác minh, thu hồi phiên; không lưu raw session token.';
COMMENT ON COLUMN public.sessions.session_id IS 'Identity một phiên đăng nhập; dùng gắn thao tác hoặc ticket với đúng principal, không phải raw token xác thực.';
COMMENT ON COLUMN public.sessions.user_id IS 'Identity tài khoản liên quan; khi đi cùng workspace_id phải tham chiếu đúng membership của workspace.';
COMMENT ON COLUMN public.sessions.token_digest IS 'SHA-256 32 byte của raw session token; unique toàn cục để lookup phiên, không trả về client/log.';
COMMENT ON COLUMN public.sessions.auth_context_id IS 'Identity ngữ cảnh xác thực của phiên theo auth contract, dùng phân biệt các lần admission và đối chiếu client.';
COMMENT ON COLUMN public.sessions.limited IS 'True nếu phiên bị giới hạn vì cần đổi mật khẩu; không được đổi thành full tại chỗ, phải cấp phiên mới theo contract.';
COMMENT ON COLUMN public.sessions.client_type IS 'Loại client khởi tạo phiên/thao tác; enum của từng bảng phân biệt WEB, ANDROID và UNKNOWN khi được phép.';
COMMENT ON COLUMN public.sessions.issued_at IS 'Thời điểm phát hành phiên/grant/credential/ticket, làm gốc tính TTL theo loại bản ghi.';
COMMENT ON COLUMN public.sessions.expires_at IS 'Hạn hiệu lực cố định issued_at + 24 giờ; revoke có thể làm phiên hết quyền sớm hơn, row còn giữ khi audit/ticket tham chiếu.';
COMMENT ON COLUMN public.sessions.revoked_at IS 'Thời điểm thu hồi quyền/credential; NULL nghĩa chưa ghi nhận thu hồi, không đồng nghĩa mọi điều kiện xác thực khác còn hợp lệ.';

/* Công dụng của public.telemetry_envelopes. */
COMMENT ON TABLE public.telemetry_envelopes IS 'Một gói telemetry đã nhận, chứa thời gian/provenance chung và số point dự kiến. Liên kết receipt với các point để ghi toàn gói hoặc rollback toàn gói.';
COMMENT ON COLUMN public.telemetry_envelopes.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.telemetry_envelopes.envelope_id IS 'Identity raw envelope trong workspace để liên kết các point; receipt tự nhiên vẫn tồn tại khi raw envelope bị purge.';
COMMENT ON COLUMN public.telemetry_envelopes.device_id IS 'Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng tenant.';
COMMENT ON COLUMN public.telemetry_envelopes.boot_id IS 'Identity boot của thiết bị theo wire dạng text, không suy UUID; chỉ chấp nhận khi gắn với credential/connection đã xác minh.';
COMMENT ON COLUMN public.telemetry_envelopes.message_id IS 'Identity message do thiết bị gửi trong một boot, kiểu text theo wire contract; kết hợp device/boot để chống nhận trùng.';
COMMENT ON COLUMN public.telemetry_envelopes.observed_at IS 'Timestamp do thiết bị khai chung cho envelope; NULL khi thiết bị chưa có clock, không nhận timestamp khác nhau cho từng point.';
COMMENT ON COLUMN public.telemetry_envelopes.received_at IS 'Server first-received time phải khớp receipt, không thay thành thời gian nhận lại khi retry.';
COMMENT ON COLUMN public.telemetry_envelopes.effective_at IS 'Thời gian hiệu lực chung của envelope theo time_basis, là authority để point event_at khớp cùng mốc.';
COMMENT ON COLUMN public.telemetry_envelopes.time_basis IS 'Nguồn thời gian hiệu lực DEVICE/SERVER: DEVICE dùng observed_at, SERVER dùng received_at theo envelope.';
COMMENT ON COLUMN public.telemetry_envelopes.ingestion_sequence IS 'Thứ tự tiếp nhận do server quản lý trong từng device, khác sequence trên wire của thiết bị.';
COMMENT ON COLUMN public.telemetry_envelopes.point_count IS 'Số point dự kiến của envelope, từ 1 đến 10; deferred cardinality check ngăn commit gói thiếu/extra point.';

/* Công dụng của public.telemetry_history. */
COMMENT ON VIEW public.telemetry_history IS 'View lịch sử telemetry trong cutoff raw 7 ngày, không chờ cron purge; không tự cấp quyền đọc ngoài workspace.';
COMMENT ON COLUMN public.telemetry_history.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.telemetry_history.envelope_id IS 'Identity raw envelope trong workspace để liên kết các point; receipt tự nhiên vẫn tồn tại khi raw envelope bị purge.';
COMMENT ON COLUMN public.telemetry_history.point_index IS 'Vị trí point trong envelope, bắt đầu 0 và tối đa 9; khác stream_key dùng kiểm trùng kênh.';
COMMENT ON COLUMN public.telemetry_history.device_id IS 'Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng tenant.';
COMMENT ON COLUMN public.telemetry_history.stream_key IS 'Khóa kỹ thuật ổn định của kênh trong template/version; không dùng nhãn hiển thị thay khóa schema.';
COMMENT ON COLUMN public.telemetry_history.observed_at IS 'Bản sao observed_at của envelope để phục vụ lịch sử; so khớp null-safe, không phải per-point timestamp độc lập từ wire.';
COMMENT ON COLUMN public.telemetry_history.event_at IS 'Thời gian dùng query point, phải bằng envelope.effective_at; được lặp để phục vụ index lịch sử theo stream.';
COMMENT ON COLUMN public.telemetry_history.quality IS 'Chất lượng mẫu GOOD/NULL/SERVER_TIME; quality NULL biểu diễn mẫu null, không là giá trị số 0 và không tự quyết định time_basis.';
COMMENT ON COLUMN public.telemetry_history.value_type IS 'Nhánh kiểu dữ liệu của giá trị được lưu; XOR chọn đúng cột numeric/boolean/text và phải khớp pinned definition.';
COMMENT ON COLUMN public.telemetry_history.numeric_value IS 'Giá trị số hữu hạn của nhánh NUMBER hoặc ENUM số; NULL khi dùng nhánh giá trị khác hoặc quality NULL.';
COMMENT ON COLUMN public.telemetry_history.boolean_value IS 'Giá trị boolean của nhánh BOOLEAN; false là dữ liệu thật, không tương đương NULL/missing.';
COMMENT ON COLUMN public.telemetry_history.text_value IS 'Giá trị chuỗi của nhánh STRING hoặc ENUM chuỗi; không chuyển mọi datatype thành text để bỏ kiểm kiểu.';

/* Công dụng của public.telemetry_points. */
COMMENT ON TABLE public.telemetry_points IS 'Các mẫu typed trong một envelope, mỗi stream xuất hiện tối đa một lần. Device và thời gian được lặp có chủ đích cho query lịch sử, phải khớp authority ở envelope.';
COMMENT ON COLUMN public.telemetry_points.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.telemetry_points.envelope_id IS 'Identity raw envelope trong workspace để liên kết các point; receipt tự nhiên vẫn tồn tại khi raw envelope bị purge.';
COMMENT ON COLUMN public.telemetry_points.point_index IS 'Vị trí point trong envelope, bắt đầu 0 và tối đa 9; khác stream_key dùng kiểm trùng kênh.';
COMMENT ON COLUMN public.telemetry_points.device_id IS 'Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng tenant.';
COMMENT ON COLUMN public.telemetry_points.stream_key IS 'Khóa kỹ thuật ổn định của kênh trong template/version; không dùng nhãn hiển thị thay khóa schema.';
COMMENT ON COLUMN public.telemetry_points.observed_at IS 'Bản sao observed_at của envelope để phục vụ lịch sử; so khớp null-safe, không phải per-point timestamp độc lập từ wire.';
COMMENT ON COLUMN public.telemetry_points.event_at IS 'Thời gian dùng query point, phải bằng envelope.effective_at; được lặp để phục vụ index lịch sử theo stream.';
COMMENT ON COLUMN public.telemetry_points.quality IS 'Chất lượng mẫu GOOD/NULL/SERVER_TIME; quality NULL biểu diễn mẫu null, không là giá trị số 0 và không tự quyết định time_basis.';
COMMENT ON COLUMN public.telemetry_points.value_type IS 'Nhánh kiểu dữ liệu của giá trị được lưu; XOR chọn đúng cột numeric/boolean/text và phải khớp pinned definition.';
COMMENT ON COLUMN public.telemetry_points.numeric_value IS 'Giá trị số hữu hạn của nhánh NUMBER hoặc ENUM số; NULL khi dùng nhánh giá trị khác hoặc quality NULL.';
COMMENT ON COLUMN public.telemetry_points.boolean_value IS 'Giá trị boolean của nhánh BOOLEAN; false là dữ liệu thật, không tương đương NULL/missing.';
COMMENT ON COLUMN public.telemetry_points.text_value IS 'Giá trị chuỗi của nhánh STRING hoặc ENUM chuỗi; không chuyển mọi datatype thành text để bỏ kiểm kiểu.';

/* Công dụng của public.telemetry_receipts. */
COMMENT ON TABLE public.telemetry_receipts IS 'Ledger định danh và digest của envelope đã nhận thành công. Tồn tại độc lập raw telemetry để retry không tái tạo dữ liệu sau khi raw bị purge.';
COMMENT ON COLUMN public.telemetry_receipts.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.telemetry_receipts.device_id IS 'Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng tenant.';
COMMENT ON COLUMN public.telemetry_receipts.boot_id IS 'Identity boot của thiết bị theo wire dạng text, không suy UUID; chỉ chấp nhận khi gắn với credential/connection đã xác minh.';
COMMENT ON COLUMN public.telemetry_receipts.message_id IS 'Identity message do thiết bị gửi trong một boot, kiểu text theo wire contract; kết hợp device/boot để chống nhận trùng.';
COMMENT ON COLUMN public.telemetry_receipts.source_sequence IS 'Sequence thiết bị khai trong message/boot theo wire; dùng frontier chống replay, không nhầm với ingestion_sequence.';
COMMENT ON COLUMN public.telemetry_receipts.payload_digest IS 'SHA-256 32 byte của payload đã chấp nhận, phục vụ dedupe và phát hiện cùng identity nhưng body mâu thuẫn.';
COMMENT ON COLUMN public.telemetry_receipts.first_received_at IS 'Thời điểm server chấp nhận lần đầu message identity, giữ nguyên khi retry và làm authority cho envelope received_at.';
COMMENT ON COLUMN public.telemetry_receipts.ingestion_sequence IS 'Thứ tự tiếp nhận do server quản lý trong từng device, khác sequence trên wire của thiết bị.';

/* Công dụng của public.template_draft_capabilities. */
COMMENT ON TABLE public.template_draft_capabilities IS 'Capability điều khiển và safeValue của từng kênh bản nháp. Mô tả khả năng SET_VALUE để validator kiểm type/range trước khi publish.';
COMMENT ON COLUMN public.template_draft_capabilities.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.template_draft_capabilities.template_id IS 'Identity gốc template trong workspace, dùng nhóm các version và nội dung draft; không là identity version đã pin.';
COMMENT ON COLUMN public.template_draft_capabilities.stream_key IS 'Khóa kỹ thuật ổn định của kênh trong template/version; không dùng nhãn hiển thị thay khóa schema.';
COMMENT ON COLUMN public.template_draft_capabilities.command_type IS 'Capability lệnh được template công bố, hiện chỉ SET_VALUE; không cho thực thi script hoặc lệnh tùy ý.';
COMMENT ON COLUMN public.template_draft_capabilities.safe_value IS 'Literal giá trị an toàn của capability, phải đúng datatype/range/ENUM; đây là cấu hình, không tự gửi lệnh tới thiết bị.';

/* Công dụng của public.template_draft_enum_values. */
COMMENT ON TABLE public.template_draft_enum_values IS 'Tập literal được phép của một kênh ENUM trong bản nháp. Tách thành relation để kiểm trùng giá trị, không lưu danh sách giá trị dạng chuỗi CSV.';
COMMENT ON COLUMN public.template_draft_enum_values.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.template_draft_enum_values.template_id IS 'Identity gốc template trong workspace, dùng nhóm các version và nội dung draft; không là identity version đã pin.';
COMMENT ON COLUMN public.template_draft_enum_values.stream_key IS 'Khóa kỹ thuật ổn định của kênh trong template/version; không dùng nhãn hiển thị thay khóa schema.';
COMMENT ON COLUMN public.template_draft_enum_values.enum_value IS 'Một literal JSON number/string được phép của kênh ENUM; validator còn phải kiểm bộ giá trị và type theo contract.';

/* Công dụng của public.template_draft_streams. */
COMMENT ON TABLE public.template_draft_streams IS 'Các kênh dữ liệu đang chỉnh sửa của một template, gồm datatype, chiều đọc/ghi và giới hạn. Cho phép editor sửa draft trước khi tạo snapshot phiên bản.';
COMMENT ON COLUMN public.template_draft_streams.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.template_draft_streams.template_id IS 'Identity gốc template trong workspace, dùng nhóm các version và nội dung draft; không là identity version đã pin.';
COMMENT ON COLUMN public.template_draft_streams.stream_key IS 'Khóa kỹ thuật ổn định của kênh trong template/version; không dùng nhãn hiển thị thay khóa schema.';
COMMENT ON COLUMN public.template_draft_streams.display_name IS 'Nhãn hiển thị của kênh dữ liệu; stream_key vẫn là khóa kỹ thuật ổn định khi nhãn thay đổi.';
COMMENT ON COLUMN public.template_draft_streams.data_type IS 'Kiểu dữ liệu NUMBER/BOOLEAN/STRING/ENUM của definition; validator kiểm literal và giới hạn theo kiểu này.';
COMMENT ON COLUMN public.template_draft_streams.direction IS 'Chiều sử dụng kênh READ/WRITE/READ_WRITE; tồn tại stream không đồng nghĩa có capability điều khiển.';
COMMENT ON COLUMN public.template_draft_streams.unit IS 'Đơn vị đo hiển thị của kênh, ví dụ đơn vị cảm biến; NULL khi đại lượng không có đơn vị theo schema.';
COMMENT ON COLUMN public.template_draft_streams.min_value IS 'Cận dưới cho giá trị NUMBER hữu hạn; NULL nghĩa không khai cận dưới, không mặc định bằng 0.';
COMMENT ON COLUMN public.template_draft_streams.max_value IS 'Cận trên cho giá trị NUMBER hữu hạn; NULL nghĩa không khai cận trên, không tự đặt giới hạn phần cứng.';
COMMENT ON COLUMN public.template_draft_streams.string_max_length IS 'Độ dài tối đa của STRING tính bằng ký tự theo validation hiện hành; NULL khi schema không khai giới hạn này.';
COMMENT ON COLUMN public.template_draft_streams.revision IS 'Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng transaction contract.';

/* Công dụng của public.template_versions. */
COMMENT ON TABLE public.template_versions IS 'Ảnh chụp schema và metadata template tại mỗi lần publish. Là phiên bản được thiết bị tham chiếu cố định để thay đổi draft không làm lệch schema của thiết bị đang chạy.';
COMMENT ON COLUMN public.template_versions.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.template_versions.template_version_id IS 'Identity snapshot template cụ thể, dùng pin schema và kiểm đúng definition trong workspace.';
COMMENT ON COLUMN public.template_versions.template_id IS 'Identity gốc template trong workspace, dùng nhóm các version và nội dung draft; không là identity version đã pin.';
COMMENT ON COLUMN public.template_versions.version_number IS 'Số phiên bản publish tăng trong cùng template/rule, bắt đầu 1; khác revision chỉnh sửa metadata.';
COMMENT ON COLUMN public.template_versions.name IS 'Tên hiển thị do người dùng đặt cho tài nguyên; không dùng làm identity, quyền hoặc khóa chống lặp.';
COMMENT ON COLUMN public.template_versions.model IS 'Mã model phần cứng/template theo registry đã duyệt, dùng kiểm tương thích; không suy model từ tên hiển thị.';
COMMENT ON COLUMN public.template_versions.published_at IS 'Thời điểm tạo snapshot đã công bố; không thay đổi theo các lần sửa draft sau đó.';
COMMENT ON COLUMN public.template_versions.published_by_user_id IS 'Thành viên thực hiện publish template version, giữ provenance của snapshot đã công bố.';
COMMENT ON COLUMN public.template_versions.content_digest IS 'SHA-256 32 byte của nội dung snapshot đã publish, dùng nhận diện/đối chiếu định nghĩa thay vì hash metadata draft hiện tại.';

/* Công dụng của public.templates. */
COMMENT ON TABLE public.templates IS 'Gốc quản lý template thiết bị và metadata bản nháp như tên/model. Không dùng bản nháp làm schema runtime; thiết bị phải pin vào một template_versions đã công bố.';
COMMENT ON COLUMN public.templates.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.templates.template_id IS 'Identity gốc template trong workspace, dùng nhóm các version và nội dung draft; không là identity version đã pin.';
COMMENT ON COLUMN public.templates.name IS 'Tên hiển thị do người dùng đặt cho tài nguyên; không dùng làm identity, quyền hoặc khóa chống lặp.';
COMMENT ON COLUMN public.templates.model IS 'Mã model phần cứng/template theo registry đã duyệt, dùng kiểm tương thích; không suy model từ tên hiển thị.';
COMMENT ON COLUMN public.templates.description IS 'Mô tả bổ sung để người dùng hiểu tài nguyên; NULL nghĩa chưa cung cấp mô tả, không mang authority vận hành.';
COMMENT ON COLUMN public.templates.lifecycle_status IS 'Trạng thái vòng đời quản lý tài nguyên, tách khỏi presence hoặc tiến độ của job đang chạy.';
COMMENT ON COLUMN public.templates.created_by_user_id IS 'Tài khoản tạo tài nguyên; giữ provenance và làm anchor quota hoặc FK thành viên theo loại tài nguyên.';
COMMENT ON COLUMN public.templates.revision IS 'Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng transaction contract.';
COMMENT ON COLUMN public.templates.created_at IS 'Thời điểm tạo bản ghi dưới dạng timestamptz; dùng provenance/sắp xếp hoặc retention khi policy của bảng quy định.';
COMMENT ON COLUMN public.templates.updated_at IS 'Thời điểm cập nhật gần nhất do đường ghi quản lý; không mặc định SQL tự cập nhật nếu không có trigger tương ứng.';

/* Công dụng của public.user_preferences. */
COMMENT ON TABLE public.user_preferences IS 'Tùy chọn hiển thị của từng tài khoản, hiện gồm múi giờ. Tách khỏi hồ sơ xác thực để đổi giao diện không làm thay đổi thông tin đăng nhập.';
COMMENT ON COLUMN public.user_preferences.user_id IS 'Identity tài khoản liên quan; khi đi cùng workspace_id phải tham chiếu đúng membership của workspace.';
COMMENT ON COLUMN public.user_preferences.display_timezone IS 'Múi giờ IANA dùng hiển thị cho user, mặc định UTC; không đổi instant lưu trong DB hay lịch rule hiện hữu.';
COMMENT ON COLUMN public.user_preferences.revision IS 'Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng transaction contract.';
COMMENT ON COLUMN public.user_preferences.updated_at IS 'Thời điểm cập nhật gần nhất do đường ghi quản lý; không mặc định SQL tự cập nhật nếu không có trigger tương ứng.';

/* Công dụng của public.users. */
COMMENT ON TABLE public.users IS 'Danh tính tài khoản dùng chung toàn hệ thống: lưu email đăng nhập, bộ kiểm chứng mật khẩu và trạng thái kích hoạt. Vai trò theo workspace nằm ở memberships, không gắn vai trò toàn cục vào tài khoản.';
COMMENT ON COLUMN public.users.user_id IS 'Identity tài khoản toàn cục để đăng nhập và liên kết các membership; không gắn với một workspace duy nhất.';
COMMENT ON COLUMN public.users.email_normalized IS 'Email đã được lớp xác thực chuẩn hóa, dùng lookup tài khoản/lời mời; quy tắc chuẩn hóa phải thống nhất trước ghi.';
COMMENT ON COLUMN public.users.password_hash IS 'Bộ kiểm chứng mật khẩu theo encoding của password hasher; không chứa mật khẩu gốc và không trả về client/log.';
COMMENT ON COLUMN public.users.account_status IS 'Trạng thái tài khoản toàn cục ACTIVE/DISABLED; khác trạng thái membership trong một workspace.';
COMMENT ON COLUMN public.users.must_change_password IS 'Đánh dấu tài khoản phải đổi mật khẩu trước thao tác thông thường; backend dùng để hạn chế admission và session.';
COMMENT ON COLUMN public.users.activated_at IS 'Thời điểm xác nhận tài khoản đã kích hoạt; NULL không được tự suy thành tài khoản tạm nếu provenance là legacy/unknown.';
COMMENT ON COLUMN public.users.activation_provenance IS 'Nguồn/bằng chứng hình thành trạng thái kích hoạt, giúp phân biệt account tạm mới với dữ liệu legacy chưa rõ lịch sử.';
COMMENT ON COLUMN public.users.created_at IS 'Thời điểm tạo bản ghi dưới dạng timestamptz; dùng provenance/sắp xếp hoặc retention khi policy của bảng quy định.';

/* Công dụng của public.webhook_deliveries. */
COMMENT ON TABLE public.webhook_deliveries IS 'Nghĩa vụ giao occurrence tới subscription hoặc một lần TEST, với exact body/endpoint/secret snapshot. Retry dùng cùng delivery identity và body, không dựng lại payload từ dữ liệu hiện tại.';
COMMENT ON COLUMN public.webhook_deliveries.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.webhook_deliveries.webhook_delivery_id IS 'Identity nghĩa vụ webhook giữ nguyên khi retry, để receiver dedupe ngay cả khi response bị mất.';
COMMENT ON COLUMN public.webhook_deliveries.webhook_subscription_id IS 'Identity cấu hình webhook trong workspace, dùng nhóm filter, secret versions và lịch sử delivery.';
COMMENT ON COLUMN public.webhook_deliveries.kind IS 'BUSINESS có occurrence nguồn và budget 6+6; TEST không có occurrence/Event giả, chỉ một lần gửi trong 30 giây.';
COMMENT ON COLUMN public.webhook_deliveries.occurrence_id IS 'Identity một transition đã commit; wire webhook eventId ánh xạ identity này, không gộp OPEN/RESOLVED thành một Event ID.';
COMMENT ON COLUMN public.webhook_deliveries.endpoint_url_snapshot IS 'URL đích được chụp khi delivery admission; retry không tự đổi sang URL hiện hành khác.';
COMMENT ON COLUMN public.webhook_deliveries.endpoint_revision_snapshot IS 'Revision URL được delivery chụp, phục vụ recheck endpoint/fanout policy và giải thích lịch sử gửi.';
COMMENT ON COLUMN public.webhook_deliveries.secret_version IS 'Thế hệ secret ký webhook trong một subscription; khác endpoint_revision và được delivery giữ cố định khi retry.';
COMMENT ON COLUMN public.webhook_deliveries.raw_body IS 'Exact body bytes gửi webhook và ký HMAC, giữ nguyên khi retry/manual batch; không dựng lại từ live resource.';
COMMENT ON COLUMN public.webhook_deliveries.body_digest IS 'SHA-256 32 byte của exact raw_body webhook; producer tính trước gửi và giữ nguyên khi retry.';
COMMENT ON COLUMN public.webhook_deliveries.state IS 'Tiến trình PENDING/SENDING/RETRY_WAIT hoặc ACCEPTED/FAILED/DEAD_LETTER/CANCELLED; DEAD_LETTER có thể mở đúng một manual batch đủ điều kiện.';
COMMENT ON COLUMN public.webhook_deliveries.admitted_at IS 'Thời điểm yêu cầu được backend nhận vào ledger sau kiểm điều kiện; không chứng minh side effect đã thực hiện.';
COMMENT ON COLUMN public.webhook_deliveries.expires_at IS 'BUSINESS neo occurrence.committed_at +24 giờ; TEST neo admitted_at +30 giây, độc lập history retention 30 ngày.';
COMMENT ON COLUMN public.webhook_deliveries.terminal_at IS 'Thời điểm quan sát trạng thái kết thúc của command/delivery; không thay gốc expiry hoặc gốc retention.';
COMMENT ON COLUMN public.webhook_deliveries.manual_batch_count IS 'Số đợt retry thủ công webhook đã mở, chỉ 0 hoặc 1; TEST không có manual batch.';
COMMENT ON COLUMN public.webhook_deliveries.next_attempt_at IS 'Thời điểm sớm nhất được thử gửi tiếp; không được gửi sớm hơn mốc này hoặc vượt expiry/budget của parent.';
COMMENT ON COLUMN public.webhook_deliveries.lease_until IS 'Hạn thuê xử lý hiện hành của worker; lease hết không chứng minh network side effect chưa xảy ra.';
COMMENT ON COLUMN public.webhook_deliveries.lease_generation IS 'Thế hệ lease tăng khi claim/takeover, dùng CAS để worker cũ không settle kết quả của thế hệ mới.';

/* Công dụng của public.webhook_delivery_attempts. */
COMMENT ON TABLE public.webhook_delivery_attempts IS 'Ý định HTTP outbound mỗi lần gửi delivery, với batch và outcome đã loại dữ liệu nhạy cảm. Ngân sách BUSINESS 6 tự động + một batch 6 thủ công, TEST chỉ một attempt.';
COMMENT ON COLUMN public.webhook_delivery_attempts.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.webhook_delivery_attempts.webhook_delivery_id IS 'Identity nghĩa vụ webhook giữ nguyên khi retry, để receiver dedupe ngay cả khi response bị mất.';
COMMENT ON COLUMN public.webhook_delivery_attempts.attempt_number IS 'Số thứ tự send intent của một delivery, bắt đầu 1; PK và admission guard bảo vệ thứ tự/ngân sách.';
COMMENT ON COLUMN public.webhook_delivery_attempts.batch_number IS 'Đợt webhook: 0 là tự động, 1 là đợt retry thủ công duy nhất; không tạo body/delivery identity mới.';
COMMENT ON COLUMN public.webhook_delivery_attempts.intent_at IS 'Thời điểm lưu ý định trước side effect bên ngoài DB; dùng tính ngân sách/expiry và phục hồi khi mất ACK.';
COMMENT ON COLUMN public.webhook_delivery_attempts.request_digest IS 'Digest 32 byte của request/body đã canonical hóa để phát hiện cùng identity khác nội dung hoặc đối chiếu send intent.';
COMMENT ON COLUMN public.webhook_delivery_attempts.response_status IS 'HTTP status đã ghi nhận, miền 100..599 khi có; NULL khi chưa có response đáng tin cậy.';
COMMENT ON COLUMN public.webhook_delivery_attempts.outcome IS 'Kết quả quan sát của một HTTP send intent, không tự chứng minh receiver chưa xử lý khi response bị mất.';
COMMENT ON COLUMN public.webhook_delivery_attempts.observed_at IS 'Thời điểm quan sát được dữ liệu/kết quả; nguồn và ý nghĩa được quy định theo bảng, không mặc định là thời gian commit.';
COMMENT ON COLUMN public.webhook_delivery_attempts.next_attempt_at IS 'Thời điểm sớm nhất được thử gửi tiếp; không được gửi sớm hơn mốc này hoặc vượt expiry/budget của parent.';

/* Công dụng của public.webhook_delivery_history. */
COMMENT ON VIEW public.webhook_delivery_history IS 'View lịch sử webhook trong cutoff 30 ngày từ admitted_at, khác expiry BUSINESS/TEST.';
COMMENT ON COLUMN public.webhook_delivery_history.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.webhook_delivery_history.webhook_delivery_id IS 'Identity nghĩa vụ webhook giữ nguyên khi retry, để receiver dedupe ngay cả khi response bị mất.';
COMMENT ON COLUMN public.webhook_delivery_history.webhook_subscription_id IS 'Identity cấu hình webhook trong workspace, dùng nhóm filter, secret versions và lịch sử delivery.';
COMMENT ON COLUMN public.webhook_delivery_history.kind IS 'BUSINESS có occurrence nguồn và budget 6+6; TEST không có occurrence/Event giả, chỉ một lần gửi trong 30 giây.';
COMMENT ON COLUMN public.webhook_delivery_history.occurrence_id IS 'Identity một transition đã commit; wire webhook eventId ánh xạ identity này, không gộp OPEN/RESOLVED thành một Event ID.';
COMMENT ON COLUMN public.webhook_delivery_history.endpoint_url_snapshot IS 'URL đích được chụp khi delivery admission; retry không tự đổi sang URL hiện hành khác.';
COMMENT ON COLUMN public.webhook_delivery_history.endpoint_revision_snapshot IS 'Revision URL được delivery chụp, phục vụ recheck endpoint/fanout policy và giải thích lịch sử gửi.';
COMMENT ON COLUMN public.webhook_delivery_history.secret_version IS 'Thế hệ secret ký webhook trong một subscription; khác endpoint_revision và được delivery giữ cố định khi retry.';
COMMENT ON COLUMN public.webhook_delivery_history.raw_body IS 'Exact body bytes gửi webhook và ký HMAC, giữ nguyên khi retry/manual batch; không dựng lại từ live resource.';
COMMENT ON COLUMN public.webhook_delivery_history.body_digest IS 'SHA-256 32 byte của exact raw_body webhook; producer tính trước gửi và giữ nguyên khi retry.';
COMMENT ON COLUMN public.webhook_delivery_history.state IS 'Tiến trình PENDING/SENDING/RETRY_WAIT hoặc ACCEPTED/FAILED/DEAD_LETTER/CANCELLED; DEAD_LETTER có thể mở đúng một manual batch đủ điều kiện.';
COMMENT ON COLUMN public.webhook_delivery_history.admitted_at IS 'Thời điểm yêu cầu được backend nhận vào ledger sau kiểm điều kiện; không chứng minh side effect đã thực hiện.';
COMMENT ON COLUMN public.webhook_delivery_history.expires_at IS 'BUSINESS neo occurrence.committed_at +24 giờ; TEST neo admitted_at +30 giây, độc lập history retention 30 ngày.';
COMMENT ON COLUMN public.webhook_delivery_history.terminal_at IS 'Thời điểm quan sát trạng thái kết thúc của command/delivery; không thay gốc expiry hoặc gốc retention.';
COMMENT ON COLUMN public.webhook_delivery_history.manual_batch_count IS 'Số đợt retry thủ công webhook đã mở, chỉ 0 hoặc 1; TEST không có manual batch.';
COMMENT ON COLUMN public.webhook_delivery_history.next_attempt_at IS 'Thời điểm sớm nhất được thử gửi tiếp; không được gửi sớm hơn mốc này hoặc vượt expiry/budget của parent.';
COMMENT ON COLUMN public.webhook_delivery_history.lease_until IS 'Hạn thuê xử lý hiện hành của worker; lease hết không chứng minh network side effect chưa xảy ra.';
COMMENT ON COLUMN public.webhook_delivery_history.lease_generation IS 'Thế hệ lease tăng khi claim/takeover, dùng CAS để worker cũ không settle kết quả của thế hệ mới.';

/* Công dụng của public.webhook_secret_versions. */
COMMENT ON TABLE public.webhook_secret_versions IS 'Từng generation secret ký webhook, lưu ciphertext và wrapping key reference. Giữ version còn được delivery tham chiếu; metadata có thể tồn tại sau khi ciphertext được purge theo policy.';
COMMENT ON COLUMN public.webhook_secret_versions.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.webhook_secret_versions.webhook_subscription_id IS 'Identity cấu hình webhook trong workspace, dùng nhóm filter, secret versions và lịch sử delivery.';
COMMENT ON COLUMN public.webhook_secret_versions.secret_version IS 'Thế hệ secret ký webhook trong một subscription; khác endpoint_revision và được delivery giữ cố định khi retry.';
COMMENT ON COLUMN public.webhook_secret_versions.secret_ciphertext IS 'Secret recoverable đã mã hóa cho escrow/ký webhook; key wrapping nằm ngoài DB và chỉ đường ghi có custody được dùng giá trị này.';
COMMENT ON COLUMN public.webhook_secret_versions.encryption_key_reference IS 'Tham chiếu/version của khóa dùng giải mã ciphertext, không chứa key material; NULL phải đồng bộ với nhánh không có ciphertext.';
COMMENT ON COLUMN public.webhook_secret_versions.created_at IS 'Thời điểm tạo bản ghi dưới dạng timestamptz; dùng provenance/sắp xếp hoặc retention khi policy của bảng quy định.';
COMMENT ON COLUMN public.webhook_secret_versions.retired_at IS 'Thời điểm boot/secret version được retire; dữ liệu lịch sử và các nghĩa vụ còn tham chiếu có thể tiếp tục được giữ.';

/* Công dụng của public.webhook_subscription_devices. */
COMMENT ON TABLE public.webhook_subscription_devices IS 'Bộ lọc thiết bị của webhook subscription trong cùng workspace. Quyền hiện hành vẫn phải được kiểm tại fanout/send, không chỉ dựa vào FK tồn tại.';
COMMENT ON COLUMN public.webhook_subscription_devices.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.webhook_subscription_devices.webhook_subscription_id IS 'Identity cấu hình webhook trong workspace, dùng nhóm filter, secret versions và lịch sử delivery.';
COMMENT ON COLUMN public.webhook_subscription_devices.device_id IS 'Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng tenant.';

/* Công dụng của public.webhook_subscription_events. */
COMMENT ON TABLE public.webhook_subscription_events IS 'Các loại BUSINESS event mà subscription muốn nhận. Tách relation có CHECK allowlist, không lưu mảng chuỗi làm nguồn quyền/fanout.';
COMMENT ON COLUMN public.webhook_subscription_events.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.webhook_subscription_events.webhook_subscription_id IS 'Identity cấu hình webhook trong workspace, dùng nhóm filter, secret versions và lịch sử delivery.';
COMMENT ON COLUMN public.webhook_subscription_events.event_type IS 'Loại sự kiện được audit/outbox/webhook sử dụng; ý nghĩa/allowlist phụ thuộc bảng và schema contract.';

/* Công dụng của public.webhook_subscriptions. */
COMMENT ON TABLE public.webhook_subscriptions IS 'Cấu hình đích webhook, owner, trạng thái endpoint verification và active secret version. Revision endpoint khác secret version để đổi URL không được hưởng kết quả verify của URL cũ.';
COMMENT ON COLUMN public.webhook_subscriptions.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.webhook_subscriptions.webhook_subscription_id IS 'Identity cấu hình webhook trong workspace, dùng nhóm filter, secret versions và lịch sử delivery.';
COMMENT ON COLUMN public.webhook_subscriptions.owner_user_id IS 'Tài khoản sở hữu tài nguyên trong workspace; backend phải kiểm membership và quyền hiện hành khi đọc/ghi.';
COMMENT ON COLUMN public.webhook_subscriptions.endpoint_url IS 'URL HTTPS của webhook subscription; lớp outbound còn phải kiểm DNS/IP/redirect chống SSRF mỗi lần gửi.';
COMMENT ON COLUMN public.webhook_subscriptions.endpoint_revision IS 'Phiên bản endpoint URL hiện hành; đổi URL phải làm verify cũ không còn hiệu lực.';
COMMENT ON COLUMN public.webhook_subscriptions.verified_endpoint_revision IS 'Endpoint revision đã được xác minh, phải trùng endpoint_revision hiện hành nếu có; NULL khi chưa có verify hợp lệ.';
COMMENT ON COLUMN public.webhook_subscriptions.verified_at IS 'Thời điểm xác minh endpoint revision hiện hành; không dùng lại cho URL mới hoặc coi như quyền SSRF vĩnh viễn.';
COMMENT ON COLUMN public.webhook_subscriptions.revision IS 'Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng transaction contract.';
COMMENT ON COLUMN public.webhook_subscriptions.lifecycle_status IS 'Trạng thái vòng đời quản lý tài nguyên, tách khỏi presence hoặc tiến độ của job đang chạy.';
COMMENT ON COLUMN public.webhook_subscriptions.active_secret_version IS 'Con trỏ secret version hiện hành của đúng subscription; delivery cũ vẫn giữ version snapshot riêng.';
COMMENT ON COLUMN public.webhook_subscriptions.created_at IS 'Thời điểm tạo bản ghi dưới dạng timestamptz; dùng provenance/sắp xếp hoặc retention khi policy của bảng quy định.';
COMMENT ON COLUMN public.webhook_subscriptions.updated_at IS 'Thời điểm cập nhật gần nhất do đường ghi quản lý; không mặc định SQL tự cập nhật nếu không có trigger tương ứng.';

/* Công dụng của public.websocket_tickets. */
COMMENT ON TABLE public.websocket_tickets IS 'Vé kết nối realtime dùng một lần, gắn với session, workspace và generation quyền. Backend consume có điều kiện rồi mới mở kênh; không lưu raw ticket.';
COMMENT ON COLUMN public.websocket_tickets.ticket_id IS 'Identity quản lý bearer ticket, không phải secret; ticket_digest dùng xác minh/consume.';
COMMENT ON COLUMN public.websocket_tickets.ticket_digest IS 'Digest SHA-256 32 byte của bearer ticket, dùng lookup/consume hoặc tải artifact; raw ticket chỉ được trả qua kênh admission.';
COMMENT ON COLUMN public.websocket_tickets.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.websocket_tickets.user_id IS 'Identity tài khoản liên quan; khi đi cùng workspace_id phải tham chiếu đúng membership của workspace.';
COMMENT ON COLUMN public.websocket_tickets.session_id IS 'Identity một phiên đăng nhập; dùng gắn thao tác hoặc ticket với đúng principal, không phải raw token xác thực.';
COMMENT ON COLUMN public.websocket_tickets.grant_generation IS 'Generation của một lần cấp membership cụ thể, lớn hơn 0; không tái sử dụng identity khi remove rồi rejoin.';
COMMENT ON COLUMN public.websocket_tickets.workspace_authorization_version IS 'Phiên bản quyền workspace chụp trong ticket, phải khớp hiện hành khi consume realtime admission.';
COMMENT ON COLUMN public.websocket_tickets.membership_authorization_version IS 'Phiên bản quyền membership chụp trong ticket, dùng vô hiệu ngữ cảnh cũ sau mutation quyền.';
COMMENT ON COLUMN public.websocket_tickets.issued_at IS 'Thời điểm phát hành phiên/grant/credential/ticket, làm gốc tính TTL theo loại bản ghi.';
COMMENT ON COLUMN public.websocket_tickets.expires_at IS 'Deadline issued_at + 30 giây cho admission realtime; consume một winner và recheck session/grant/workspace trước mở socket.';
COMMENT ON COLUMN public.websocket_tickets.consumed_at IS 'Thời điểm vé một lần đã được consume thành công; CAS và mốc một chiều ngăn dùng lại cùng ticket.';
COMMENT ON COLUMN public.websocket_tickets.revoked_at IS 'Thời điểm thu hồi quyền/credential; NULL nghĩa chưa ghi nhận thu hồi, không đồng nghĩa mọi điều kiện xác thực khác còn hợp lệ.';

/* Công dụng của public.workspace_idempotency_records. */
COMMENT ON TABLE public.workspace_idempotency_records IS 'Biên nhận chống lặp cho request trong workspace theo principal user/API key. Digest body dùng phát hiện cùng key khác nội dung; không đưa body hash vào khóa dedupe.';
COMMENT ON COLUMN public.workspace_idempotency_records.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.workspace_idempotency_records.idempotency_record_id IS 'Identity kỹ thuật của receipt scoped; dedupe thực sự theo principal/route/key digest, không dựa vào ID này.';
COMMENT ON COLUMN public.workspace_idempotency_records.user_id IS 'Principal user trong workspace; NULL nếu request do API key, CHECK yêu cầu đúng một nhánh principal.';
COMMENT ON COLUMN public.workspace_idempotency_records.api_key_id IS 'Principal API key của request; NULL nếu dùng user session, FK buộc key thuộc đúng workspace.';
COMMENT ON COLUMN public.workspace_idempotency_records.route_key IS 'Namespace route canonical gồm identity resource cần thiết; không chỉ là route template khi nhiều target dùng chung idempotency key.';
COMMENT ON COLUMN public.workspace_idempotency_records.key_digest IS 'Digest idempotency key của client; cùng namespace principal/route tạo identity replay, không chứa secret response.';
COMMENT ON COLUMN public.workspace_idempotency_records.request_digest IS 'Digest 32 byte của request/body đã canonical hóa để phát hiện cùng identity khác nội dung hoặc đối chiếu send intent.';
COMMENT ON COLUMN public.workspace_idempotency_records.admitted_at IS 'Thời điểm yêu cầu được backend nhận vào ledger sau kiểm điều kiện; không chứng minh side effect đã thực hiện.';
COMMENT ON COLUMN public.workspace_idempotency_records.expires_at IS 'Cửa sổ replay admitted_at + 24 giờ; vẫn phải recheck current authorization trước trả receipt.';
COMMENT ON COLUMN public.workspace_idempotency_records.state IS 'Receipt đang IN_PROGRESS hoặc COMPLETED; request_digest phân biệt retry cùng body với conflict cùng key khác body.';
COMMENT ON COLUMN public.workspace_idempotency_records.response_status IS 'HTTP status đã ghi nhận, miền 100..599 khi có; NULL khi chưa có response đáng tin cậy.';
COMMENT ON COLUMN public.workspace_idempotency_records.sanitized_result IS 'Kết quả replay đã loại secret, không lưu one-time credential response để trả lại sau retry.';
COMMENT ON COLUMN public.workspace_idempotency_records.command_id IS 'Identity command ổn định qua retry/result/reconciliation; không tạo command mới chỉ vì mất response.';

/* Công dụng của public.workspace_invitations. */
COMMENT ON TABLE public.workspace_invitations IS 'Lời mời tham gia workspace, chụp vai trò, người mời và generation quyền tại lúc phát hành. Digest token, hạn 24 giờ và mốc sử dụng/thu hồi phục vụ nhận lời mời một lần.';
COMMENT ON COLUMN public.workspace_invitations.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.workspace_invitations.invitation_id IS 'Identity lời mời workspace dùng quản trị/truy vết; token_digest mới là bộ kiểm chứng khi nhận lời mời.';
COMMENT ON COLUMN public.workspace_invitations.token_digest IS 'Digest token dùng lookup/xác minh mà không lưu raw token; session token và provider token có ngữ nghĩa khác nhau theo bảng.';
COMMENT ON COLUMN public.workspace_invitations.email_normalized IS 'Email đã được lớp xác thực chuẩn hóa, dùng lookup tài khoản/lời mời; quy tắc chuẩn hóa phải thống nhất trước ghi.';
COMMENT ON COLUMN public.workspace_invitations.email_digest IS 'Digest 32 byte của email chuẩn hóa để lập bucket/fence mà không dùng raw email làm khóa vận hành; policy key version thuộc custody.';
COMMENT ON COLUMN public.workspace_invitations.role IS 'Vai trò thành viên ADMIN/USER trong workspace, không là quyền quản trị toàn bộ hệ thống.';
COMMENT ON COLUMN public.workspace_invitations.issued_by_user_id IS 'Thành viên phát hành lời mời; issuer grant/version được chụp riêng để lần consume kiểm lại quyền.';
COMMENT ON COLUMN public.workspace_invitations.issuer_grant_generation IS 'Grant của người mời được chụp lúc phát hành invitation, không mặc định còn hợp lệ tại lúc consume.';
COMMENT ON COLUMN public.workspace_invitations.issuer_authorization_version IS 'Phiên bản quyền của người mời tại lúc phát invitation, dùng kiểm callback/consume có dựa trên quyền cũ hay không.';
COMMENT ON COLUMN public.workspace_invitations.admission_generation IS 'Thế hệ nhận thành viên theo email/workspace; snapshot invitation phải được so với fence hiện hành tại consume.';
COMMENT ON COLUMN public.workspace_invitations.issued_at IS 'Thời điểm phát hành phiên/grant/credential/ticket, làm gốc tính TTL theo loại bản ghi.';
COMMENT ON COLUMN public.workspace_invitations.expires_at IS 'Deadline issued_at + 24 giờ; consume phải kiểm thời gian và generation/quyền hiện hành, không chờ cron xóa row expired.';
COMMENT ON COLUMN public.workspace_invitations.used_at IS 'Thời điểm lời mời được tiêu thụ; một khi đã ghi không được xóa mốc để sử dụng lại token.';
COMMENT ON COLUMN public.workspace_invitations.revoked_at IS 'Thời điểm thu hồi quyền/credential; NULL nghĩa chưa ghi nhận thu hồi, không đồng nghĩa mọi điều kiện xác thực khác còn hợp lệ.';
COMMENT ON COLUMN public.workspace_invitations.expired_at IS 'Thời điểm backend đã đánh dấu lời mời hết hạn để giải phóng pending slot; khác expires_at là deadline gốc.';

/* Công dụng của public.workspace_notification_preferences. */
COMMENT ON TABLE public.workspace_notification_preferences IS 'Tùy chọn nhận push theo user/workspace, tách khỏi permission hệ điều hành của installation. Hàng vắng mang default theo contract; lưu lần đầu bắt đầu revision 1.';
COMMENT ON COLUMN public.workspace_notification_preferences.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.workspace_notification_preferences.user_id IS 'Identity tài khoản liên quan; khi đi cùng workspace_id phải tham chiếu đúng membership của workspace.';
COMMENT ON COLUMN public.workspace_notification_preferences.enabled IS 'Cờ cho phép nhận thông báo theo installation hoặc preference; còn phải giao với permission, binding và quyền hiện hành.';
COMMENT ON COLUMN public.workspace_notification_preferences.minimum_severity IS 'Mức độ Event thấp nhất người dùng cho phép nhận push trong workspace này.';
COMMENT ON COLUMN public.workspace_notification_preferences.revision IS 'Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng transaction contract.';
COMMENT ON COLUMN public.workspace_notification_preferences.updated_at IS 'Thời điểm cập nhật gần nhất do đường ghi quản lý; không mặc định SQL tự cập nhật nếu không có trigger tương ứng.';

/* Công dụng của public.workspace_operation_devices. */
COMMENT ON TABLE public.workspace_operation_devices IS 'Snapshot tập thiết bị tham gia workspace operation cùng tiến độ mỗi thiết bị. Liên kết đúng device_operation trên cùng device, không chỉ cùng tenant.';
COMMENT ON COLUMN public.workspace_operation_devices.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.workspace_operation_devices.workspace_operation_id IS 'Identity lifecycle operation workspace, dùng nhóm tập device snapshot và tiến độ cleanup từng thiết bị.';
COMMENT ON COLUMN public.workspace_operation_devices.device_id IS 'Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng tenant.';
COMMENT ON COLUMN public.workspace_operation_devices.device_operation_id IS 'Identity lifecycle operation của thiết bị; khi tham chiếu cùng device_id phải khớp đúng thiết bị đó.';
COMMENT ON COLUMN public.workspace_operation_devices.state IS 'Trạng thái xử lý bền vững của ledger/job/operation; không suy rằng enum hợp lệ tự chứng minh transition hợp lệ.';
COMMENT ON COLUMN public.workspace_operation_devices.observed_at IS 'Thời điểm quan sát được dữ liệu/kết quả; nguồn và ý nghĩa được quy định theo bảng, không mặc định là thời gian commit.';

/* Công dụng của public.workspace_operations. */
COMMENT ON TABLE public.workspace_operations IS 'Ý định lifecycle toàn workspace và trạng thái đối soát. Một operation chưa settled giữ fence cho đến khi các thiết bị liên quan có đủ kết quả cleanup.';
COMMENT ON COLUMN public.workspace_operations.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.workspace_operations.workspace_operation_id IS 'Identity lifecycle operation workspace, dùng nhóm tập device snapshot và tiến độ cleanup từng thiết bị.';
COMMENT ON COLUMN public.workspace_operations.operation_type IS 'Loại lifecycle mutation được yêu cầu, để worker thực hiện đúng thao tác và kiểm proof tương ứng.';
COMMENT ON COLUMN public.workspace_operations.requested_by_user_id IS 'Thành viên yêu cầu lifecycle operation; dùng truy vết người khởi tạo, không thay kiểm quyền hiện hành khi worker thực thi.';
COMMENT ON COLUMN public.workspace_operations.requested_revision IS 'Revision resource mà người yêu cầu dựa vào lúc khởi tạo lifecycle operation; dùng phát hiện yêu cầu chỉnh sửa đã lỗi thời.';
COMMENT ON COLUMN public.workspace_operations.state IS 'Trạng thái xử lý bền vững của ledger/job/operation; không suy rằng enum hợp lệ tự chứng minh transition hợp lệ.';
COMMENT ON COLUMN public.workspace_operations.intent_at IS 'Thời điểm lưu ý định trước side effect bên ngoài DB; dùng tính ngân sách/expiry và phục hồi khi mất ACK.';
COMMENT ON COLUMN public.workspace_operations.settled_at IS 'Thời điểm nghĩa vụ vận hành được đối soát xong và có thể nhả guard/quota; NULL tiếp tục giữ nghĩa vụ chưa giải quyết.';
COMMENT ON COLUMN public.workspace_operations.reason_code IS 'Mã nguyên nhân ổn định để giải thích kết quả/transition; phải là nội dung an toàn, không chứa raw lỗi/secret.';

/* Công dụng của public.workspace_runtime_quotas. */
COMMENT ON TABLE public.workspace_runtime_quotas IS 'Projection đếm execution đang chiếm quota và hàng điều phối quota workspace. Counter phải được đối soát từ rule_executions; không thay thế lịch sử thực thi.';
COMMENT ON COLUMN public.workspace_runtime_quotas.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.workspace_runtime_quotas.active_execution_count IS 'Projection số execution RUNNING/WAITING của workspace, miền 0..10; trigger đối chiếu ledger khi admission/terminal.';
COMMENT ON COLUMN public.workspace_runtime_quotas.revision IS 'Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng transaction contract.';

/* Công dụng của public.workspaces. */
COMMENT ON TABLE public.workspaces IS 'Đơn vị cô lập dữ liệu và quyền của dự án. Quản lý tên, múi giờ mặc định, trạng thái hoạt động và phiên bản quyền; mọi tài nguyên nghiệp vụ đều thuộc một workspace.';
COMMENT ON COLUMN public.workspaces.workspace_id IS 'Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền của người gọi.';
COMMENT ON COLUMN public.workspaces.name IS 'Tên hiển thị do người dùng đặt cho tài nguyên; không dùng làm identity, quyền hoặc khóa chống lặp.';
COMMENT ON COLUMN public.workspaces.description IS 'Mô tả bổ sung để người dùng hiểu tài nguyên; NULL nghĩa chưa cung cấp mô tả, không mang authority vận hành.';
COMMENT ON COLUMN public.workspaces.default_timezone IS 'Múi giờ IANA mặc định của workspace cho cấu hình mới; đổi giá trị này không tự đổi timezone snapshot của lịch đã tạo.';
COMMENT ON COLUMN public.workspaces.status IS 'Lifecycle ACTIVE/SUSPENDED/ARCHIVED; suspend chặn admission theo policy, archive không phải hard-delete và không tự unarchive.';
COMMENT ON COLUMN public.workspaces.created_by_user_id IS 'Tài khoản tạo workspace, dùng anchor tuần tự hóa quota tối đa 5 workspace do account tạo.';
COMMENT ON COLUMN public.workspaces.revision IS 'Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng transaction contract.';
COMMENT ON COLUMN public.workspaces.authorization_version IS 'Mốc phiên bản quyền hiện hành; bên ghi phải tăng khi quyền thay đổi để ticket/job/cache phát hiện ngữ cảnh quyền cũ.';
COMMENT ON COLUMN public.workspaces.created_at IS 'Thời điểm tạo bản ghi dưới dạng timestamptz; dùng provenance/sắp xếp hoặc retention khi policy của bảng quy định.';
COMMENT ON COLUMN public.workspaces.updated_at IS 'Thời điểm cập nhật gần nhất do đường ghi quản lý; không mặc định SQL tự cập nhật nếu không có trigger tương ứng.';
COMMENT ON COLUMN public.workspaces.archived_at IS 'Thời điểm workspace được archive; phải đi cùng trạng thái ARCHIVED, không phải lệnh hard-delete dữ liệu.';
