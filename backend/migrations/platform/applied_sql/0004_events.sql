/* Journal sự kiện, lifecycle và durable messaging dùng các identity đã có0001..0003.
 * Không tạo Event giả cho command/connectivity; không lưu response chứa secret vào idempotency.
 */
CREATE TABLE workspace_operations (
 workspace_id uuid NOT NULL REFERENCES workspaces, workspace_operation_id uuid NOT NULL,
 operation_type text NOT NULL CHECK(operation_type IN ('SUSPEND','RESUME','ARCHIVE')),
 requested_by_user_id uuid NOT NULL, requested_revision bigint NOT NULL CHECK(requested_revision>0),
 state text NOT NULL CHECK(state IN ('PENDING','RUNNING','SUCCEEDED','FAILED','NEEDS_ATTENTION')),
 intent_at timestamptz NOT NULL, settled_at timestamptz, reason_code text,
 PRIMARY KEY(workspace_id,workspace_operation_id), FOREIGN KEY(workspace_id,requested_by_user_id) REFERENCES memberships
);
/* Operation chưa settled tiếp tục giữ fence kể cả có lỗi cần đối soát. */
CREATE UNIQUE INDEX uq_workspace_operations_unsettled ON workspace_operations(workspace_id) WHERE settled_at IS NULL;
CREATE TABLE workspace_operation_devices (
 workspace_id uuid NOT NULL, workspace_operation_id uuid NOT NULL, device_id uuid NOT NULL, device_operation_id uuid,
 state text NOT NULL CHECK(state IN ('PENDING','RUNNING','SUCCEEDED','FAILED','NEEDS_ATTENTION')), observed_at timestamptz,
 PRIMARY KEY(workspace_id,workspace_operation_id,device_id), FOREIGN KEY(workspace_id,workspace_operation_id) REFERENCES workspace_operations,
 FOREIGN KEY(workspace_id,device_id) REFERENCES devices(workspace_id,device_id),
 FOREIGN KEY(workspace_id,device_operation_id,device_id) REFERENCES device_operations(workspace_id,device_operation_id,device_id)
);
CREATE TABLE events (
 workspace_id uuid NOT NULL REFERENCES workspaces, event_id uuid NOT NULL,
 source_kind text NOT NULL CHECK(source_kind IN ('DEVICE','RULE')), source_device_id uuid, source_rule_id uuid,
 source_identity uuid GENERATED ALWAYS AS (coalesce(source_device_id,source_rule_id)) STORED,
 episode_key text NOT NULL CHECK(btrim(episode_key)<>''), severity text NOT NULL CHECK(severity IN ('INFO','WARNING','CRITICAL')),
 status text NOT NULL DEFAULT 'OPEN' CHECK(status IN ('OPEN','ACKNOWLEDGED','RESOLVED')),
 title text NOT NULL, safe_message text NOT NULL, revision bigint NOT NULL DEFAULT 1 CHECK(revision>0),
 created_at timestamptz NOT NULL, acknowledged_by_user_id uuid, acknowledged_at timestamptz, resolved_at timestamptz,
 PRIMARY KEY(workspace_id,event_id), UNIQUE(workspace_id,source_kind,source_identity,episode_key),
 FOREIGN KEY(workspace_id,source_device_id) REFERENCES devices(workspace_id,device_id), FOREIGN KEY(workspace_id,source_rule_id) REFERENCES rules,
 FOREIGN KEY(workspace_id,acknowledged_by_user_id) REFERENCES memberships,
 CHECK((source_kind='DEVICE' AND source_device_id IS NOT NULL AND source_rule_id IS NULL) OR
       (source_kind='RULE' AND source_rule_id IS NOT NULL AND source_device_id IS NULL)),
 CHECK((acknowledged_by_user_id IS NULL)=(acknowledged_at IS NULL)), CHECK((status='RESOLVED')=(resolved_at IS NOT NULL))
);
/* Tenant và thời gian phục vụ lịch sử, không dùng title làm dedupe. */
CREATE INDEX ix_events_history ON events(workspace_id,created_at DESC,event_id);
CREATE TABLE event_occurrences (
 workspace_id uuid NOT NULL REFERENCES workspaces, occurrence_id uuid NOT NULL,
 source_kind text NOT NULL CHECK(source_kind IN ('EVENT','COMMAND','CONNECTIVITY')),
 event_id uuid, event_revision bigint, command_id uuid, connectivity_device_id uuid, connectivity_transition_sequence bigint,
 occurrence_type text NOT NULL, public_event_type text, occurred_at timestamptz NOT NULL, committed_at timestamptz NOT NULL,
 immutable_payload jsonb NOT NULL CHECK(jsonb_typeof(immutable_payload)='object'),
 PRIMARY KEY(workspace_id,occurrence_id), FOREIGN KEY(workspace_id,event_id) REFERENCES events,
 FOREIGN KEY(workspace_id,command_id) REFERENCES commands,
 FOREIGN KEY(workspace_id,connectivity_device_id,connectivity_transition_sequence) REFERENCES connectivity_transitions,
 CONSTRAINT ck_event_occurrences_source_shape CHECK(
  (source_kind='EVENT' AND event_id IS NOT NULL AND event_revision IS NOT NULL AND event_revision>0 AND num_nonnulls(command_id,connectivity_device_id,connectivity_transition_sequence)=0) OR
  (source_kind='COMMAND' AND command_id IS NOT NULL AND num_nonnulls(event_id,event_revision,connectivity_device_id,connectivity_transition_sequence)=0) OR
  (source_kind='CONNECTIVITY' AND connectivity_device_id IS NOT NULL AND connectivity_transition_sequence IS NOT NULL AND connectivity_transition_sequence>0 AND num_nonnulls(event_id,event_revision,command_id)=0)),
 CONSTRAINT ck_event_occurrences_public_type CHECK(
  (source_kind='EVENT' AND occurrence_type='CREATED' AND public_event_type IS NOT NULL AND public_event_type='event.opened') OR
  (source_kind='EVENT' AND occurrence_type='RESOLVED' AND public_event_type IS NOT NULL AND public_event_type='event.resolved') OR
  (source_kind='EVENT' AND occurrence_type='ACKNOWLEDGED' AND public_event_type IS NULL) OR
  (source_kind='COMMAND' AND occurrence_type='COMMAND_TERMINAL' AND public_event_type IS NOT NULL AND public_event_type='command.completed') OR
  (source_kind='CONNECTIVITY' AND occurrence_type='CONNECTIVITY_CHANGED' AND public_event_type IS NOT NULL AND public_event_type='device.connectivity'))
);
/* Mỗi nguồn có natural dedupe riêng, NULL của nhánh khác không làm yếu uniqueness. */
CREATE UNIQUE INDEX uq_event_occurrences_event_revision ON event_occurrences(workspace_id,event_id,event_revision) WHERE source_kind='EVENT';
CREATE UNIQUE INDEX uq_event_occurrences_command_terminal ON event_occurrences(workspace_id,command_id) WHERE source_kind='COMMAND';
CREATE UNIQUE INDEX uq_event_occurrences_connectivity_transition ON event_occurrences(workspace_id,connectivity_device_id,connectivity_transition_sequence) WHERE source_kind='CONNECTIVITY';
CREATE TABLE notifications (
 workspace_id uuid NOT NULL, notification_id uuid NOT NULL, recipient_user_id uuid NOT NULL,
 kind text NOT NULL CHECK(kind IN ('EVENT','PUSH_TEST')), event_id uuid,
 target_type text NOT NULL CHECK(target_type IN ('EVENT','EXECUTION','DEVICE','NOTIFICATION')), target_device_id uuid, target_rule_execution_id uuid,
 created_at timestamptz NOT NULL, read_at timestamptz,
 PRIMARY KEY(workspace_id,notification_id), UNIQUE(workspace_id,notification_id,recipient_user_id),
 FOREIGN KEY(workspace_id,recipient_user_id) REFERENCES memberships, FOREIGN KEY(workspace_id,event_id) REFERENCES events,
 FOREIGN KEY(workspace_id,target_device_id) REFERENCES devices(workspace_id,device_id), FOREIGN KEY(workspace_id,target_rule_execution_id) REFERENCES rule_executions,
 CONSTRAINT ck_notification_source CHECK((kind='EVENT' AND event_id IS NOT NULL) OR (kind='PUSH_TEST' AND event_id IS NULL)),
 CONSTRAINT ck_notification_target CHECK(
  (target_type='EVENT' AND kind='EVENT' AND target_device_id IS NULL AND target_rule_execution_id IS NULL) OR
  (target_type='DEVICE' AND kind='EVENT' AND target_device_id IS NOT NULL AND target_rule_execution_id IS NULL) OR
  (target_type='EXECUTION' AND kind='EVENT' AND target_device_id IS NULL AND target_rule_execution_id IS NOT NULL) OR
  (target_type='NOTIFICATION' AND kind='PUSH_TEST' AND target_device_id IS NULL AND target_rule_execution_id IS NULL))
);
/* Inbox phân biệt người nhận; read của một người không sửa Event hoặc inbox người khác. */
CREATE UNIQUE INDEX uq_notifications_event_recipient ON notifications(workspace_id,event_id,recipient_user_id) WHERE kind='EVENT';
CREATE INDEX ix_notifications_recipient ON notifications(workspace_id,recipient_user_id,created_at DESC,notification_id);
CREATE TABLE global_idempotency_records (
 user_id uuid NOT NULL REFERENCES users, route_key text NOT NULL, key_digest bytea NOT NULL CHECK(octet_length(key_digest)=32),
 request_digest bytea NOT NULL CHECK(octet_length(request_digest)=32), admitted_at timestamptz NOT NULL, expires_at timestamptz NOT NULL,
 state text NOT NULL CHECK(state IN ('IN_PROGRESS','COMPLETED')), response_status integer CHECK(response_status BETWEEN 100 AND 599), sanitized_result jsonb,
 PRIMARY KEY(user_id,route_key,key_digest), CHECK(expires_at=admitted_at+interval '24 hours')
);
/* Hai principal typed thay principal_id polymorphic không FK; API key FK bổ sung0006. */
CREATE TABLE workspace_idempotency_records (
 workspace_id uuid NOT NULL REFERENCES workspaces, idempotency_record_id uuid NOT NULL, user_id uuid, api_key_id uuid,
 route_key text NOT NULL, key_digest bytea NOT NULL CHECK(octet_length(key_digest)=32), request_digest bytea NOT NULL CHECK(octet_length(request_digest)=32),
 admitted_at timestamptz NOT NULL, expires_at timestamptz NOT NULL, state text NOT NULL CHECK(state IN ('IN_PROGRESS','COMPLETED')),
 response_status integer CHECK(response_status BETWEEN 100 AND 599), sanitized_result jsonb, command_id uuid,
 PRIMARY KEY(workspace_id,idempotency_record_id), FOREIGN KEY(workspace_id,user_id) REFERENCES memberships, FOREIGN KEY(workspace_id,command_id) REFERENCES commands,
 CHECK(num_nonnulls(user_id,api_key_id)=1), CHECK(expires_at=admitted_at+interval '24 hours')
);
/* Body hash không thuộc khóa replay: cùng key khác body phải conflict. */
CREATE UNIQUE INDEX uq_workspace_idempotency_user ON workspace_idempotency_records(workspace_id,user_id,route_key,key_digest) WHERE user_id IS NOT NULL;
CREATE UNIQUE INDEX uq_workspace_idempotency_api_key ON workspace_idempotency_records(workspace_id,api_key_id,route_key,key_digest) WHERE api_key_id IS NOT NULL;
CREATE TABLE outbox_events (
 outbox_event_id uuid PRIMARY KEY, workspace_id uuid REFERENCES workspaces, event_key text NOT NULL, event_type text NOT NULL,
 payload_schema_version integer NOT NULL CHECK(payload_schema_version>0), payload jsonb NOT NULL CHECK(jsonb_typeof(payload)='object'),
 created_at timestamptz NOT NULL DEFAULT transaction_timestamp()
);
/* NULL tenant là namespace IAM toàn cục riêng, không để NULL bypass unique. */
CREATE UNIQUE INDEX uq_outbox_workspace_key ON outbox_events(workspace_id,event_key) WHERE workspace_id IS NOT NULL;
CREATE UNIQUE INDEX uq_outbox_global_key ON outbox_events(event_key) WHERE workspace_id IS NULL;
CREATE TABLE outbox_consumptions (
 outbox_event_id uuid NOT NULL REFERENCES outbox_events, consumer_code text NOT NULL CHECK(btrim(consumer_code)<>''),
 state text NOT NULL DEFAULT 'PENDING' CHECK(state IN ('PENDING','PROCESSING','RETRY_WAIT','COMPLETED','DEAD_LETTER')),
 available_at timestamptz NOT NULL, lease_until timestamptz, lease_generation bigint NOT NULL DEFAULT 0 CHECK(lease_generation>=0),
 attempt_count integer NOT NULL DEFAULT 0 CHECK(attempt_count>=0), completed_at timestamptz,
 PRIMARY KEY(outbox_event_id,consumer_code), CHECK((state='COMPLETED')=(completed_at IS NOT NULL))
);
/* Consumer đứng đầu phục vụ claim riêng từng pipeline bằng SKIP LOCKED. */
CREATE INDEX ix_outbox_claim ON outbox_consumptions(consumer_code,available_at,outbox_event_id) WHERE state IN ('PENDING','RETRY_WAIT','PROCESSING');
CREATE TABLE rate_limit_admissions (
 admission_id uuid PRIMARY KEY, workspace_id uuid REFERENCES workspaces, user_id uuid REFERENCES users, api_key_id uuid,
 policy_code text NOT NULL CHECK(btrim(policy_code)<>''), admitted_at timestamptz NOT NULL, request_correlation_id uuid NOT NULL,
 CHECK(num_nonnulls(user_id,api_key_id)=1), CHECK(api_key_id IS NULL OR workspace_id IS NOT NULL),
 FOREIGN KEY(workspace_id,user_id) REFERENCES memberships
);
/* Policy/principal trước timestamp cho cửa sổ rate; service dùng lock anchor cùng admission. */
CREATE INDEX ix_rate_limit_user ON rate_limit_admissions(workspace_id,user_id,policy_code,admitted_at) WHERE user_id IS NOT NULL;
CREATE INDEX ix_rate_limit_key ON rate_limit_admissions(workspace_id,api_key_id,policy_code,admitted_at) WHERE api_key_id IS NOT NULL;
