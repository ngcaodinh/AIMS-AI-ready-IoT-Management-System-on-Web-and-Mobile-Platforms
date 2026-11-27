# Relation worksheet của database canonical

Sinh từ catalog và metadata PostgreSQL thật. Cột/type/NULL/default/FK/index đầy đủ ở [manifest.json](manifest.json).
Candidate key dưới đây là PK/UK NOT NULL tối thiểu theo constraints đã khai; partial/nullable unique là key có điều kiện, xem index manifest.
Với mỗi key K, K+ bằng toàn bộ thuộc tính relation dưới FD K→A do uniqueness thực thi. Đây là closure theo FD đã khai, không chứng minh không có business FD khác.
Không chứng nhận mọi bảng đạt BCNF/4NF: namespace, pin, binding, fixed TTL và snapshot/projection có redundancy được liệt kê. AST/presentation/result là document có schema riêng, validator backend vẫn phải kiểm references/shape.

## action_executions

Grain: một action trong execution.
Khóa tối thiểu theo constraints: (workspace_id, rule_execution_id, action_position); (workspace_id, action_execution_id).
Thuộc tính: workspace_id, rule_execution_id, action_position, action_execution_id, rule_version_id, state, started_at, ended_at, command_id, reason_code.
FD/ngoại lệ: execution→version trong cùng workspace; version copy phục vụ FK action/version.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## action_jobs

Grain: một durable job/action.
Khóa tối thiểu theo constraints: (workspace_id, rule_execution_id, action_position).
Thuộc tính: workspace_id, rule_execution_id, action_position, state, due_at, lease_until, lease_generation, attempt_count.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## actuator_states

Grain: một writable stream/device.
Khóa tối thiểu theo constraints: (workspace_id, device_id, stream_key).
Thuộc tính: workspace_id, device_id, stream_key, pinned_template_version_id, manual_epoch, last_reported_value, last_reported_at, reported_source, unresolved_command_id.
FD/ngoại lệ: device_id→workspace_id theo global device registry; workspace lặp có chủ đích để composite FK bảo vệ tenant.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## api_key_devices

Grain: một device được cấp cho key.
Khóa tối thiểu theo constraints: (workspace_id, api_key_id, device_id).
Thuộc tính: workspace_id, api_key_id, device_id.
FD/ngoại lệ: device_id→workspace_id theo global device registry; workspace lặp có chủ đích để composite FK bảo vệ tenant; api_key_id→workspace_id theo global key lookup; supporting scoped UK không phải key tối thiểu mới.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## api_key_scopes

Grain: một permission của key.
Khóa tối thiểu theo constraints: (workspace_id, api_key_id, scope_code).
Thuộc tính: workspace_id, api_key_id, scope_code.
FD/ngoại lệ: api_key_id→workspace_id theo global key lookup; supporting scoped UK không phải key tối thiểu mới.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## api_keys

Grain: một API principal global-lookup, quyền scoped.
Khóa tối thiểu theo constraints: (api_key_id); (verifier_digest).
Thuộc tính: api_key_id, workspace_id, owner_user_id, owner_grant_generation, verifier_digest, name, prefix, issued_at, expires_at, revoked_at, last_used_at, revision, publication_transaction_id, publication_cluster_id.
FD/ngoại lệ: api_key_id→workspace_id theo global key lookup; supporting scoped UK không phải key tối thiểu mới; expires_at là deadline lưu bền vững theo policy của aggregate; TTL cố định được CHECK, expiry theo clock vẫn phải kiểm tại admission.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## audit_events

Grain: một ghi nhận lịch sử.
Khóa tối thiểu theo constraints: (audit_event_id).
Thuộc tính: audit_event_id, workspace_id, actor_user_id, session_id, event_type, outcome, resource_type, resource_id, correlation_id, occurred_at, reason_code, redacted_diff, client_type, created_at.
FD/ngoại lệ: session_id→principal với nhánh session không NULL; composite FK giữ binding.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## audit_retention_batches

Grain: một result batch đã commit.
Khóa tối thiểu theo constraints: (batch_id).
Thuộc tính: batch_id, run_id, batch_limit, removed_count, completed_at.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## audit_retention_runs

Grain: một run purge với cutoff đã đóng.
Khóa tối thiểu theo constraints: (run_id).
Thuộc tính: run_id, cutoff.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## command_evidence

Grain: một late/conflicting observation.
Khóa tối thiểu theo constraints: (workspace_id, command_evidence_id).
Thuộc tính: workspace_id, command_evidence_id, command_id, evidence_type, received_at, payload_digest, sanitized_payload.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## command_resolutions

Grain: trạng thái xử lý UNKNOWN.
Khóa tối thiểu theo constraints: (workspace_id, command_id).
Thuộc tính: workspace_id, command_id, resolution_status, resolved_by_user_id, resolved_at, manual_observation, device_evidence_id, reason_code.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## command_result_receipts

Grain: một result phase.
Khóa tối thiểu theo constraints: (workspace_id, command_id, result_phase).
Thuộc tính: workspace_id, command_id, result_phase, device_id, boot_id, credential_generation, payload_digest, received_at, result_snapshot.
FD/ngoại lệ: device_id→workspace_id theo global device registry; workspace lặp có chủ đích để composite FK bảo vệ tenant.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## commands

Grain: một admission.
Khóa tối thiểu theo constraints: (workspace_id, command_id).
Thuộc tính: workspace_id, command_id, device_id, stream_key, origin_type, actor_user_id, api_key_id, action_execution_id, value_type, numeric_value, boolean_value, text_value, state, outcome, admitted_at, deadline_at, dispatch_intent_at, terminal_at, manual_epoch_snapshot, revision.
FD/ngoại lệ: device_id→workspace_id theo global device registry; workspace lặp có chủ đích để composite FK bảo vệ tenant; api_key_id→workspace_id theo global key lookup; supporting scoped UK không phải key tối thiểu mới.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## connectivity_transitions

Grain: một online/offline transition.
Khóa tối thiểu theo constraints: (workspace_id, device_id, transition_sequence).
Thuộc tính: workspace_id, device_id, transition_sequence, connection_generation, from_state, to_state, observed_at, boot_id.
FD/ngoại lệ: device_id→workspace_id theo global device registry; workspace lặp có chủ đích để composite FK bảo vệ tenant.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## dashboard_widget_bindings

Grain: một slot dữ liệu của widget.
Khóa tối thiểu theo constraints: (workspace_id, dashboard_id, widget_id, binding_slot).
Thuộc tính: workspace_id, dashboard_id, widget_id, binding_slot, device_id, template_version_id, stream_key.
FD/ngoại lệ: device_id→workspace_id theo global device registry; workspace lặp có chủ đích để composite FK bảo vệ tenant.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## dashboard_widgets

Grain: một widget.
Khóa tối thiểu theo constraints: (workspace_id, dashboard_id, widget_id).
Thuộc tính: workspace_id, dashboard_id, widget_id, widget_type, position, presentation, layout_x, layout_y, layout_width, layout_height.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## dashboards

Grain: một dashboard.
Khóa tối thiểu theo constraints: (workspace_id, dashboard_id).
Thuộc tính: workspace_id, dashboard_id, owner_user_id, title, schema_version, revision, lifecycle_status, created_at, updated_at.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## datastream_capabilities

Grain: một capability của stream đã publish.
Khóa tối thiểu theo constraints: (workspace_id, template_version_id, stream_key, command_type).
Thuộc tính: workspace_id, template_version_id, stream_key, command_type, safe_value.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## datastream_definitions

Grain: một stream trong version.
Khóa tối thiểu theo constraints: (workspace_id, template_version_id, stream_key).
Thuộc tính: workspace_id, template_version_id, stream_key, display_name, data_type, direction, unit, min_value, max_value, string_max_length, channel_kind, default_value.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## datastream_enum_values

Grain: một literal ENUM trong stream đã publish.
Khóa tối thiểu theo constraints: (workspace_id, template_version_id, stream_key, enum_value).
Thuộc tính: workspace_id, template_version_id, stream_key, enum_value.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## device_boot_sessions

Grain: một boot/session broker đã xác minh.
Khóa tối thiểu theo constraints: (workspace_id, device_id, boot_id).
Thuộc tính: workspace_id, device_id, boot_id, credential_generation, connection_generation, started_at, retired_at, source_sequence_floor, last_source_sequence.
FD/ngoại lệ: device_id→workspace_id theo global device registry; workspace lặp có chủ đích để composite FK bảo vệ tenant.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## device_credentials

Grain: một credential generation.
Khóa tối thiểu theo constraints: (credential_identifier); (workspace_id, device_id, credential_generation).
Thuộc tính: workspace_id, device_id, credential_generation, credential_identifier, verifier_digest, credential_state, issued_at, revoked_at.
FD/ngoại lệ: device_id→workspace_id theo global device registry; workspace lặp có chủ đích để composite FK bảo vệ tenant.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## device_enrollment_guards

Grain: một enrollment giữ device.
Khóa tối thiểu theo constraints: (workspace_id, device_id).
Thuộc tính: workspace_id, device_id, enrollment_session_id, acquired_at.
FD/ngoại lệ: device_id→workspace_id theo global device registry; workspace lặp có chủ đích để composite FK bảo vệ tenant.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## device_latest_values

Grain: một stream projection.
Khóa tối thiểu theo constraints: (workspace_id, device_id, stream_key).
Thuộc tính: workspace_id, device_id, template_version_id, stream_key, latest_marker_sequence, latest_received_at, latest_value, rule_eligible_marker_sequence, rule_value, eligibility_reason.
FD/ngoại lệ: device_id→workspace_id theo global device registry; workspace lặp có chủ đích để composite FK bảo vệ tenant.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## device_operations

Grain: một lifecycle intent.
Khóa tối thiểu theo constraints: (workspace_id, device_operation_id).
Thuộc tính: workspace_id, device_operation_id, device_id, operation_type, state, requested_revision, actor_user_id, intent_at, settled_at, broker_revoke_receipt, disconnect_receipt.
FD/ngoại lệ: device_id→workspace_id theo global device registry; workspace lặp có chủ đích để composite FK bảo vệ tenant.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## device_runtime

Grain: một device runtime.
Khóa tối thiểu theo constraints: (workspace_id, device_id).
Thuộc tính: workspace_id, device_id, ingestion_sequence, connection_generation, maintenance_epoch, maintenance, last_seen_at, presence_state, current_boot_id.
FD/ngoại lệ: device_id→workspace_id theo global device registry; workspace lặp có chủ đích để composite FK bảo vệ tenant.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## devices

Grain: một device đăng ký.
Khóa tối thiểu theo constraints: (device_id); (serial_number).
Thuộc tính: device_id, workspace_id, serial_number, template_version_id, owner_user_id, name, description, model, hardware_revision, firmware_version, firmware_digest, lifecycle_status, revision, authorization_version, created_at, updated_at.
FD/ngoại lệ: device_id→workspace_id theo global device registry; workspace lặp có chủ đích để composite FK bảo vệ tenant.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## enrollment_cleanup_operations

Grain: một cleanup intent.
Khóa tối thiểu theo constraints: (workspace_id, enrollment_cleanup_operation_id); (workspace_id, enrollment_session_id).
Thuộc tính: workspace_id, enrollment_cleanup_operation_id, enrollment_session_id, device_id, state, intent_at, broker_revoke_receipt, disconnect_receipt, settled_at.
FD/ngoại lệ: device_id→workspace_id theo global device registry; workspace lặp có chủ đích để composite FK bảo vệ tenant.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## enrollment_sessions

Grain: một onboarding intent.
Khóa tối thiểu theo constraints: (workspace_id, enrollment_session_id).
Thuộc tính: workspace_id, enrollment_session_id, device_id, actor_user_id, actor_grant_generation, client_installation_id, enrollment_proof_digest, mode, state, started_at, expires_at, provisioning_operation_id, completed_at, revision.
FD/ngoại lệ: device_id→workspace_id theo global device registry; workspace lặp có chủ đích để composite FK bảo vệ tenant; expires_at là deadline lưu bền vững theo policy của aggregate; TTL cố định được CHECK, expiry theo clock vẫn phải kiểm tại admission.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## event_occurrences

Grain: một transition được commit của nguồn typed.
Khóa tối thiểu theo constraints: (workspace_id, occurrence_id).
Thuộc tính: workspace_id, occurrence_id, source_kind, event_id, event_revision, command_id, connectivity_device_id, connectivity_transition_sequence, occurrence_type, public_event_type, occurred_at, committed_at, immutable_payload.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## events

Grain: một domain event/episode.
Khóa tối thiểu theo constraints: (workspace_id, event_id).
Thuộc tính: workspace_id, event_id, source_kind, source_device_id, source_rule_id, source_identity, episode_key, severity, status, title, safe_message, revision, created_at, acknowledged_by_user_id, acknowledged_at, resolved_at.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## execution_actuator_snapshots

Grain: một actuator tại start.
Khóa tối thiểu theo constraints: (workspace_id, rule_execution_id, device_id, stream_key).
Thuộc tính: workspace_id, rule_execution_id, device_id, stream_key, manual_epoch_at_start.
FD/ngoại lệ: device_id→workspace_id theo global device registry; workspace lặp có chủ đích để composite FK bảo vệ tenant; snapshot immutable ghi sự thật tại admission, không đồng bộ theo current mutable resource; authority/runtime fence không thay history.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## firmware_package_templates

Grain: một compatibility relation.
Khóa tối thiểu theo constraints: (workspace_id, firmware_package_id, template_version_id).
Thuộc tính: workspace_id, firmware_package_id, template_version_id.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## firmware_packages

Grain: một package hợp lệ.
Khóa tối thiểu theo constraints: (workspace_id, firmware_package_id); (workspace_id, artifact_digest).
Thuộc tính: workspace_id, firmware_package_id, artifact_digest, raw_manifest, signature, artifact_reference, artifact_size_bytes, signing_key_fingerprint, signing_key_identifier, manifest_schema_version, board_model, hardware_revision, firmware_version, build_identifier, validation_state, created_at, publication_transaction_id, publication_cluster_id.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## firmware_upload_attempts

Grain: một upload/verify attempt.
Khóa tối thiểu theo constraints: (workspace_id, firmware_upload_attempt_id).
Thuộc tính: workspace_id, firmware_upload_attempt_id, actor_user_id, artifact_digest, temporary_artifact_reference, state, failure_reason, created_at, expires_at.
FD/ngoại lệ: expires_at là deadline lưu bền vững theo policy của aggregate; TTL cố định được CHECK, expiry theo clock vẫn phải kiểm tại admission.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## global_idempotency_records

Grain: một global request key.
Khóa tối thiểu theo constraints: (user_id, route_key, key_digest).
Thuộc tính: user_id, route_key, key_digest, request_digest, admitted_at, expires_at, state, response_status, sanitized_result.
FD/ngoại lệ: expires_at là deadline lưu bền vững theo policy của aggregate; TTL cố định được CHECK, expiry theo clock vẫn phải kiểm tại admission.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## login_attempt_buckets

Grain: một canonical email digest.
Khóa tối thiểu theo constraints: (email_digest).
Thuộc tính: email_digest, failure_count, window_started_at.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## membership_admission_fences

Grain: một email tại workspace.
Khóa tối thiểu theo constraints: (workspace_id, email_digest).
Thuộc tính: workspace_id, email_digest, admission_generation, updated_at.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## membership_grants

Grain: một lần được cấp membership.
Khóa tối thiểu theo constraints: (workspace_id, user_id, grant_generation).
Thuộc tính: workspace_id, user_id, grant_generation, issued_at, revoked_at.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## memberships

Grain: một quan hệ account-workspace.
Khóa tối thiểu theo constraints: (workspace_id, user_id).
Thuộc tính: workspace_id, user_id, role, status, alias, revision, authorization_version, current_grant_generation, joined_at, removed_at.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## notifications

Grain: một inbox item/recipient.
Khóa tối thiểu theo constraints: (workspace_id, notification_id).
Thuộc tính: workspace_id, notification_id, recipient_user_id, kind, event_id, target_type, target_device_id, target_rule_execution_id, created_at, read_at.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## ota_download_tickets

Grain: một bearer download ticket.
Khóa tối thiểu theo constraints: (ticket_id); (ticket_digest).
Thuộc tính: ticket_id, ticket_digest, workspace_id, ota_job_id, issued_at, expires_at, revoked_at.
FD/ngoại lệ: expires_at là deadline lưu bền vững theo policy của aggregate; TTL cố định được CHECK, expiry theo clock vẫn phải kiểm tại admission.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## ota_jobs

Grain: một OTA intent.
Khóa tối thiểu theo constraints: (workspace_id, ota_job_id).
Thuộc tính: workspace_id, ota_job_id, device_id, firmware_package_id, source_firmware_version_snapshot, target_artifact_digest_snapshot, job_nonce, state, phase, maintenance_epoch, admitted_at, deadline_at, start_intent_at, settled_at, recovery_reason, recovery_boot_id, reconciled_at, revision.
FD/ngoại lệ: device_id→workspace_id theo global device registry; workspace lặp có chủ đích để composite FK bảo vệ tenant; snapshot immutable ghi sự thật tại admission, không đồng bộ theo current mutable resource; authority/runtime fence không thay history.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## ota_probe_intents

Grain: một probe budget item.
Khóa tối thiểu theo constraints: (workspace_id, ota_job_id, recovery_epoch, probe_number); (request_id).
Thuộc tính: workspace_id, ota_job_id, recovery_epoch, probe_number, request_id, intended_at, sent_at, reply_at, reply_digest, state.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## ota_status_receipts

Grain: một authenticated status sequence.
Khóa tối thiểu theo constraints: (workspace_id, ota_job_id, status_sequence).
Thuộc tính: workspace_id, ota_job_id, status_sequence, device_id, payload_digest, boot_id, credential_generation, phase, received_at, sanitized_payload.
FD/ngoại lệ: device_id→workspace_id theo global device registry; workspace lặp có chủ đích để composite FK bảo vệ tenant.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## outbox_consumptions

Grain: một consumer nhận sự kiện.
Khóa tối thiểu theo constraints: (outbox_event_id, consumer_code).
Thuộc tính: outbox_event_id, consumer_code, state, available_at, lease_until, lease_generation, attempt_count, completed_at.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## outbox_events

Grain: một sự kiện đã commit.
Khóa tối thiểu theo constraints: (outbox_event_id).
Thuộc tính: outbox_event_id, workspace_id, event_key, event_type, payload_schema_version, payload, created_at.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## password_change_attempt_buckets

Grain: một bucket giới hạn đổi mật khẩu theo user.
Khóa tối thiểu theo constraints: (user_id).
Thuộc tính: user_id, failure_count, window_started_at.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## password_reset_admissions

Grain: một reset thành công.
Khóa tối thiểu theo constraints: (admission_id).
Thuộc tính: admission_id, workspace_id, actor_user_id, target_user_id, admitted_at.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## provisioning_operations

Grain: một credential intent.
Khóa tối thiểu theo constraints: (workspace_id, provisioning_operation_id); (workspace_id, device_id, credential_generation).
Thuộc tính: workspace_id, provisioning_operation_id, device_id, credential_generation, delivery_channel, state, actor_user_id, intent_at, expires_at, broker_receipt_at, claimed_at, secret_ciphertext, encryption_key_reference, delivery_status, retry_count, error_code.
FD/ngoại lệ: device_id→workspace_id theo global device registry; workspace lặp có chủ đích để composite FK bảo vệ tenant; expires_at là deadline lưu bền vững theo policy của aggregate; TTL cố định được CHECK, expiry theo clock vẫn phải kiểm tại admission.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## push_deliveries

Grain: một notification tới installation snapshot.
Khóa tối thiểu theo constraints: (workspace_id, push_delivery_id); (workspace_id, notification_id, installation_id).
Thuộc tính: workspace_id, push_delivery_id, notification_id, installation_id, recipient_user_id, binding_generation, state, created_at, expires_at, terminal_at, next_attempt_at, lease_until, lease_generation.
FD/ngoại lệ: expires_at là deadline lưu bền vững theo policy của aggregate; TTL cố định được CHECK, expiry theo clock vẫn phải kiểm tại admission; snapshot immutable ghi sự thật tại admission, không đồng bộ theo current mutable resource; authority/runtime fence không thay history.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## push_delivery_attempts

Grain: một send intent.
Khóa tối thiểu theo constraints: (workspace_id, push_delivery_id, attempt_number).
Thuộc tính: workspace_id, push_delivery_id, attempt_number, intent_at, token_generation, provider_request_id, outcome, observed_at, next_delay_seconds.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## push_installations

Grain: một app installation.
Khóa tối thiểu theo constraints: (installation_id).
Thuộc tính: installation_id, installation_proof_digest, platform, token_ciphertext, token_digest, encryption_key_reference, token_generation, binding_generation, client_sequence, permission_state, enabled, app_version, active_user_id, active_session_id, updated_at.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## rate_limit_admissions

Grain: một durable admission đã tính budget.
Khóa tối thiểu theo constraints: (admission_id).
Thuộc tính: admission_id, workspace_id, user_id, api_key_id, policy_code, admitted_at, request_correlation_id.
FD/ngoại lệ: api_key_id→workspace_id theo global key lookup; supporting scoped UK không phải key tối thiểu mới.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## rule_draft_actions

Grain: một action draft.
Khóa tối thiểu theo constraints: (workspace_id, rule_id, action_position).
Thuộc tính: workspace_id, rule_id, action_position, action_type, wait_seconds, target_device_id, target_template_version_id, target_stream_key, target_value, notification_config.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## rule_draft_references

Grain: một resource reference trong AST/trigger/action draft.
Khóa tối thiểu theo constraints: (workspace_id, rule_id, reference_path).
Thuộc tính: workspace_id, rule_id, reference_path, device_id, template_version_id, stream_key, reference_kind.
FD/ngoại lệ: device_id→workspace_id theo global device registry; workspace lặp có chủ đích để composite FK bảo vệ tenant.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## rule_drafts

Grain: nội dung draft hiện hành.
Khóa tối thiểu theo constraints: (workspace_id, rule_id).
Thuộc tính: workspace_id, rule_id, trigger_type, trigger_config, condition_ast, schema_version, cooldown_seconds, priority, on_failure.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## rule_execution_snapshots

Grain: history payload của execution.
Khóa tối thiểu theo constraints: (workspace_id, rule_execution_id).
Thuộc tính: workspace_id, rule_execution_id, input_snapshot, condition_trace, definition_snapshot.
FD/ngoại lệ: snapshot immutable ghi sự thật tại admission, không đồng bộ theo current mutable resource; authority/runtime fence không thay history.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## rule_executions

Grain: một lần quyết định/chạy.
Khóa tối thiểu theo constraints: (workspace_id, rule_execution_id); (workspace_id, rule_version_id, trigger_key).
Thuộc tính: workspace_id, rule_execution_id, rule_id, rule_version_id, trigger_key, state, admitted_at, deadline_at, ended_at, next_action_position, owner_user_id_snapshot, failure_reason.
FD/ngoại lệ: (workspace_id,rule_version_id)→rule_id; bản sao rule binding được composite FK kiểm.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## rule_runtime

Grain: một active rule state.
Khóa tối thiểu theo constraints: (workspace_id, rule_id).
Thuộc tính: workspace_id, rule_id, active_generation, cooldown_until, error_disabled_reason, current_rule_version_id.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## rule_trigger_receipts

Grain: một trigger được quyết định.
Khóa tối thiểu theo constraints: (workspace_id, rule_version_id, trigger_key).
Thuộc tính: workspace_id, rule_version_id, trigger_key, decision, decided_at, rule_execution_id.
FD/ngoại lệ: execution→version trong cùng workspace; version copy phục vụ FK action/version.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## rule_trigger_states

Grain: một trigger episode của version.
Khóa tối thiểu theo constraints: (workspace_id, rule_version_id, trigger_key).
Thuộc tính: workspace_id, rule_version_id, trigger_key, is_armed, hold_started_at, last_fresh_at, episode_sequence, last_marker_sequence.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## rule_version_actions

Grain: một action published.
Khóa tối thiểu theo constraints: (workspace_id, rule_version_id, action_position).
Thuộc tính: workspace_id, rule_version_id, action_position, action_type, wait_seconds, target_device_id, target_template_version_id, target_stream_key, target_value, notification_config.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## rule_version_references

Grain: một reference AST/trigger/action.
Khóa tối thiểu theo constraints: (workspace_id, rule_version_id, reference_path).
Thuộc tính: workspace_id, rule_version_id, reference_path, device_id, template_version_id, stream_key, reference_kind.
FD/ngoại lệ: device_id→workspace_id theo global device registry; workspace lặp có chủ đích để composite FK bảo vệ tenant.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## rule_versions

Grain: một published definition.
Khóa tối thiểu theo constraints: (workspace_id, rule_version_id); (workspace_id, rule_id, version_number).
Thuộc tính: workspace_id, rule_version_id, rule_id, version_number, trigger_type, trigger_config, condition_ast, schema_version, cooldown_seconds, priority, on_failure, published_at, content_digest, publication_transaction_id, publication_cluster_id.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## rules

Grain: một rule aggregate.
Khóa tối thiểu theo constraints: (workspace_id, rule_id).
Thuộc tính: workspace_id, rule_id, owner_user_id, name, lifecycle_status, revision, draft_revision, active_rule_version_id, created_at, updated_at.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## schedule_occurrences

Grain: một lần lịch định danh.
Khóa tối thiểu theo constraints: (workspace_id, rule_version_id, occurrence_key).
Thuộc tính: workspace_id, rule_version_id, occurrence_key, scheduled_at, timezone_snapshot, state, rule_execution_id.
FD/ngoại lệ: execution→version trong cùng workspace; version copy phục vụ FK action/version.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## sessions

Grain: một lần login.
Khóa tối thiểu theo constraints: (auth_context_id); (session_id); (token_digest).
Thuộc tính: session_id, user_id, token_digest, auth_context_id, limited, client_type, issued_at, expires_at, revoked_at.
FD/ngoại lệ: session_id→principal với nhánh session không NULL; composite FK giữ binding; expires_at là deadline lưu bền vững theo policy của aggregate; TTL cố định được CHECK, expiry theo clock vẫn phải kiểm tại admission.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## telemetry_envelopes

Grain: một raw envelope được nhận.
Khóa tối thiểu theo constraints: (workspace_id, envelope_id); (workspace_id, device_id, boot_id, message_id).
Thuộc tính: workspace_id, envelope_id, device_id, boot_id, message_id, observed_at, received_at, effective_at, time_basis, ingestion_sequence, point_count.
FD/ngoại lệ: device_id→workspace_id theo global device registry; workspace lặp có chủ đích để composite FK bảo vệ tenant.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## telemetry_points

Grain: một point trong envelope.
Khóa tối thiểu theo constraints: (workspace_id, envelope_id, point_index); (workspace_id, envelope_id, stream_key).
Thuộc tính: workspace_id, envelope_id, point_index, device_id, stream_key, observed_at, event_at, quality, value_type, numeric_value, boolean_value, text_value.
FD/ngoại lệ: device_id→workspace_id theo global device registry; workspace lặp có chủ đích để composite FK bảo vệ tenant; envelope→device/observed_at/event_at là partial dependency có chủ đích theo Core33; trigger null-safe kiểm authority, không gắn nhãn2NF/3NF thuần.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## telemetry_receipts

Grain: một envelope identity từng chấp nhận.
Khóa tối thiểu theo constraints: (workspace_id, device_id, boot_id, message_id); (workspace_id, device_id, ingestion_sequence).
Thuộc tính: workspace_id, device_id, boot_id, message_id, source_sequence, payload_digest, first_received_at, ingestion_sequence.
FD/ngoại lệ: device_id→workspace_id theo global device registry; workspace lặp có chủ đích để composite FK bảo vệ tenant.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## template_draft_capabilities

Grain: một capability của stream draft.
Khóa tối thiểu theo constraints: (workspace_id, template_id, stream_key, command_type).
Thuộc tính: workspace_id, template_id, stream_key, command_type, safe_value.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## template_draft_enum_values

Grain: một literal ENUM trong stream draft.
Khóa tối thiểu theo constraints: (workspace_id, template_id, stream_key, enum_value).
Thuộc tính: workspace_id, template_id, stream_key, enum_value.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## template_draft_streams

Grain: một stream draft.
Khóa tối thiểu theo constraints: (workspace_id, template_id, stream_key).
Thuộc tính: workspace_id, template_id, stream_key, display_name, data_type, direction, unit, min_value, max_value, string_max_length, revision, channel_kind, default_value.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## template_versions

Grain: một publish.
Khóa tối thiểu theo constraints: (workspace_id, template_version_id); (workspace_id, template_id, version_number).
Thuộc tính: workspace_id, template_version_id, template_id, version_number, name, model, published_at, published_by_user_id, content_digest, publication_transaction_id, publication_cluster_id.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## templates

Grain: một template.
Khóa tối thiểu theo constraints: (workspace_id, template_id).
Thuộc tính: workspace_id, template_id, name, model, description, lifecycle_status, created_by_user_id, revision, created_at, updated_at.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## user_preferences

Grain: một user.
Khóa tối thiểu theo constraints: (user_id).
Thuộc tính: user_id, display_timezone, revision, updated_at.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## users

Grain: một account.
Khóa tối thiểu theo constraints: (email_normalized); (user_id).
Thuộc tính: user_id, email_normalized, password_hash, account_status, must_change_password, activated_at, activation_provenance, created_at.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## webhook_deliveries

Grain: một occurrence/subscription hoặc TEST.
Khóa tối thiểu theo constraints: (workspace_id, webhook_delivery_id).
Thuộc tính: workspace_id, webhook_delivery_id, webhook_subscription_id, kind, occurrence_id, endpoint_url_snapshot, endpoint_revision_snapshot, secret_version, raw_body, body_digest, state, admitted_at, expires_at, terminal_at, manual_batch_count, next_attempt_at, lease_until, lease_generation.
FD/ngoại lệ: expires_at là deadline lưu bền vững theo policy của aggregate; TTL cố định được CHECK, expiry theo clock vẫn phải kiểm tại admission; snapshot immutable ghi sự thật tại admission, không đồng bộ theo current mutable resource; authority/runtime fence không thay history.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## webhook_delivery_attempts

Grain: một outbound intent.
Khóa tối thiểu theo constraints: (workspace_id, webhook_delivery_id, attempt_number).
Thuộc tính: workspace_id, webhook_delivery_id, attempt_number, batch_number, intent_at, request_digest, response_status, outcome, observed_at, next_attempt_at.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## webhook_secret_versions

Grain: một key generation.
Khóa tối thiểu theo constraints: (workspace_id, webhook_subscription_id, secret_version).
Thuộc tính: workspace_id, webhook_subscription_id, secret_version, secret_ciphertext, encryption_key_reference, created_at, retired_at.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## webhook_subscription_devices

Grain: một filter device.
Khóa tối thiểu theo constraints: (workspace_id, webhook_subscription_id, device_id).
Thuộc tính: workspace_id, webhook_subscription_id, device_id.
FD/ngoại lệ: device_id→workspace_id theo global device registry; workspace lặp có chủ đích để composite FK bảo vệ tenant.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## webhook_subscription_events

Grain: một event type filter.
Khóa tối thiểu theo constraints: (workspace_id, webhook_subscription_id, event_type).
Thuộc tính: workspace_id, webhook_subscription_id, event_type.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## webhook_subscriptions

Grain: một subscription.
Khóa tối thiểu theo constraints: (workspace_id, webhook_subscription_id).
Thuộc tính: workspace_id, webhook_subscription_id, owner_user_id, endpoint_url, endpoint_revision, verified_endpoint_revision, verified_at, revision, lifecycle_status, active_secret_version, created_at, updated_at.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## websocket_tickets

Grain: một ticket dùng một lần.
Khóa tối thiểu theo constraints: (ticket_id); (ticket_digest).
Thuộc tính: ticket_id, ticket_digest, workspace_id, user_id, session_id, grant_generation, workspace_authorization_version, membership_authorization_version, issued_at, expires_at, consumed_at, revoked_at.
FD/ngoại lệ: session_id→principal với nhánh session không NULL; composite FK giữ binding; expires_at là deadline lưu bền vững theo policy của aggregate; TTL cố định được CHECK, expiry theo clock vẫn phải kiểm tại admission.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## workspace_idempotency_records

Grain: một scoped request key.
Khóa tối thiểu theo constraints: (workspace_id, idempotency_record_id).
Thuộc tính: workspace_id, idempotency_record_id, user_id, api_key_id, route_key, key_digest, request_digest, admitted_at, expires_at, state, response_status, sanitized_result, command_id.
FD/ngoại lệ: api_key_id→workspace_id theo global key lookup; supporting scoped UK không phải key tối thiểu mới; expires_at là deadline lưu bền vững theo policy của aggregate; TTL cố định được CHECK, expiry theo clock vẫn phải kiểm tại admission.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## workspace_invitations

Grain: một lời mời.
Khóa tối thiểu theo constraints: (workspace_id, invitation_id); (token_digest).
Thuộc tính: workspace_id, invitation_id, token_digest, email_normalized, email_digest, role, issued_by_user_id, issuer_grant_generation, issuer_authorization_version, admission_generation, issued_at, expires_at, used_at, revoked_at, expired_at, revision.
FD/ngoại lệ: expires_at là deadline lưu bền vững theo policy của aggregate; TTL cố định được CHECK, expiry theo clock vẫn phải kiểm tại admission.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## workspace_notification_preferences

Grain: một user/W.
Khóa tối thiểu theo constraints: (workspace_id, user_id).
Thuộc tính: workspace_id, user_id, enabled, minimum_severity, revision, updated_at.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## workspace_operation_devices

Grain: một device trong operation.
Khóa tối thiểu theo constraints: (workspace_id, workspace_operation_id, device_id).
Thuộc tính: workspace_id, workspace_operation_id, device_id, device_operation_id, state, observed_at.
FD/ngoại lệ: device_id→workspace_id theo global device registry; workspace lặp có chủ đích để composite FK bảo vệ tenant.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## workspace_operations

Grain: một lifecycle intent.
Khóa tối thiểu theo constraints: (workspace_id, workspace_operation_id).
Thuộc tính: workspace_id, workspace_operation_id, operation_type, requested_by_user_id, requested_revision, state, intent_at, settled_at, reason_code.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## workspace_runtime_quotas

Grain: một hàng khóa quota.
Khóa tối thiểu theo constraints: (workspace_id).
Thuộc tính: workspace_id, active_execution_count, revision.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.

## workspaces

Grain: một workspace.
Khóa tối thiểu theo constraints: (workspace_id).
Thuộc tính: workspace_id, name, description, default_timezone, status, created_by_user_id, revision, authorization_version, created_at, updated_at, archived_at.
FD/ngoại lệ: các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema.
Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.
