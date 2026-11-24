/* Bản tổng hợp database toàn hệ thống; sinh từ numbered migrations, không sửa tay.
 * Chỉ chạy trên iot_platform_lab bằng iot_migrator sau bootstrap role/database.
 * Không chạy nối tiếp schema.sql; file này có ledger và chạy lại an toàn theo checksum.
 */
\set ON_ERROR_STOP on
SELECT current_database()='iot_platform_lab' AS target_matches \gset
\if :target_matches
\else
DO $$ BEGIN RAISE EXCEPTION 'Wrong canonical database target'; END $$;
\endif

\set migration_version platform-0001-identity
\set migration_checksum 0c217b8dd006c1ec0c8066a00ab1ca7b2765cb76bda8dd9eb349e88199571b8e

/* Template psql của runner; hai marker chỉ được thay bằng file SQL nguồn trong repo.
 * migration_version/checksum là literal qua :'name', không chèn input vào SQL.
 * DDL và ledger commit cùng nhau; advisory lock dùng chung cho mọi version/runner.
 */
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
SELECT pg_advisory_xact_lock(17001,1);
/* Lịch sử runner lab: lưu checksum và thời điểm áp thật, không chứa credential.
 * Phải chạy trong transaction đã lấy advisory lock; không thay SQLx production history.
 */
CREATE SCHEMA IF NOT EXISTS migration_control;
CREATE TABLE IF NOT EXISTS migration_control.applied_migrations (
    version text PRIMARY KEY,
    checksum text NOT NULL CHECK(checksum ~ '^[0-9a-f]{64}$'),
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

SELECT NOT EXISTS(
    SELECT 1 FROM migration_control.applied_migrations WHERE version=:'migration_version'
) AS should_apply \gset
\if :should_apply
/* Baseline canonical IAM/workspace của toàn hệ thống, chỉ áp trên DB mới.
 * DDL+ledger phải cùng transaction; không thay lịch sử auth lab ở thư mục cha.
 * Không tạo singleton plaintext signing key; custody thuộc deployment interface.
 */
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

/* Principal toàn cục; activation provenance phân biệt legacy với account tạm mới. */
CREATE TABLE users (
    user_id uuid PRIMARY KEY,
    email_normalized text NOT NULL UNIQUE CHECK (length(email_normalized) BETWEEN 3 AND 254),
    password_hash text NOT NULL,
    account_status text NOT NULL CHECK (account_status IN ('ACTIVE','DISABLED')),
    must_change_password boolean NOT NULL DEFAULT false,
    activated_at timestamptz,
    activation_provenance text NOT NULL CHECK (btrim(activation_provenance)<>''),
    created_at timestamptz NOT NULL DEFAULT transaction_timestamp()
);
/* Preference tách khỏi credential để CAS không làm thay đổi auth aggregate. */
CREATE TABLE user_preferences (
    user_id uuid PRIMARY KEY REFERENCES users,
    display_timezone text NOT NULL DEFAULT 'UTC',
    revision bigint NOT NULL DEFAULT 1 CHECK (revision>0),
    updated_at timestamptz NOT NULL DEFAULT transaction_timestamp()
);
/* Context/admission giữ theo auth contract draft hiện hành; không mở lại iOS đã hoãn. */
CREATE TABLE sessions (
    session_id uuid PRIMARY KEY, user_id uuid NOT NULL REFERENCES users,
    token_digest bytea NOT NULL UNIQUE CHECK (octet_length(token_digest)=32),
    auth_context_id uuid NOT NULL UNIQUE, limited boolean NOT NULL,
    client_type text NOT NULL CHECK (client_type IN ('WEB','ANDROID')),
    issued_at timestamptz NOT NULL, expires_at timestamptz NOT NULL, revoked_at timestamptz,
    CONSTRAINT uq_sessions_user_identity UNIQUE (user_id,session_id),
    CONSTRAINT ck_sessions_ttl CHECK (expires_at=issued_at+interval '24 hours')
);
/* User đứng đầu để revoke toàn bộ phiên; expiry phục vụ purge sau audit retention. */
CREATE INDEX ix_sessions_user ON sessions(user_id,session_id);
CREATE INDEX ix_sessions_expiry ON sessions(expires_at,session_id);
/* Fixed-window bắt đầu ở failure đầu; expiry kiểm khi admission, không CHECK theo now(). */
CREATE TABLE login_attempt_buckets (
    email_digest bytea PRIMARY KEY CHECK (octet_length(email_digest)=32),
    failure_count integer NOT NULL DEFAULT 0 CHECK (failure_count BETWEEN 0 AND 5),
    window_started_at timestamptz,
    CONSTRAINT ck_login_bucket_coherence CHECK (
        (failure_count=0 AND window_started_at IS NULL) OR
        (failure_count>0 AND window_started_at IS NOT NULL))
);
/* Tenant root; creator quota và capable Admin dùng fence/guard ở migration cuối. */
CREATE TABLE workspaces (
    workspace_id uuid PRIMARY KEY, name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 100),
    description text, default_timezone text NOT NULL DEFAULT 'UTC',
    status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','SUSPENDED','ARCHIVED')),
    created_by_user_id uuid NOT NULL REFERENCES users,
    revision bigint NOT NULL DEFAULT 1 CHECK (revision>0),
    authorization_version bigint NOT NULL DEFAULT 1 CHECK (authorization_version>0),
    created_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT transaction_timestamp(), archived_at timestamptz,
    CHECK ((status='ARCHIVED')=(archived_at IS NOT NULL))
);
/* Đếm workspace theo creator; thứ tự khóa bắt đầu từ User, không count ngoài transaction. */
CREATE INDEX ix_workspaces_creator ON workspaces(created_by_user_id,workspace_id);
/* Membership là authority theo workspace; grant generation không tái sử dụng khi rejoin. */
CREATE TABLE memberships (
    workspace_id uuid NOT NULL REFERENCES workspaces, user_id uuid NOT NULL REFERENCES users,
    role text NOT NULL CHECK (role IN ('ADMIN','USER')),
    status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','SUSPENDED','REMOVED')),
    alias text, revision bigint NOT NULL DEFAULT 1 CHECK (revision>0),
    authorization_version bigint NOT NULL DEFAULT 1 CHECK (authorization_version>0),
    current_grant_generation bigint NOT NULL CHECK (current_grant_generation>0),
    joined_at timestamptz NOT NULL DEFAULT transaction_timestamp(), removed_at timestamptz,
    PRIMARY KEY(workspace_id,user_id)
);
/* Picker theo principal trước tenant, chỉ lấy membership còn hiệu lực. */
CREATE INDEX ix_memberships_picker ON memberships(user_id,workspace_id) WHERE status='ACTIVE';
/* Grant immutable identity giữ reference cũ sau remove/rejoin. */
CREATE TABLE membership_grants (
    workspace_id uuid NOT NULL, user_id uuid NOT NULL,
    grant_generation bigint NOT NULL CHECK (grant_generation>0),
    issued_at timestamptz NOT NULL DEFAULT transaction_timestamp(), revoked_at timestamptz,
    PRIMARY KEY(workspace_id,user_id,grant_generation),
    FOREIGN KEY(workspace_id,user_id) REFERENCES memberships
);
/* Một grant chưa revoke cho mỗi membership; generation không nằm ngoài dedupe key. */
CREATE UNIQUE INDEX uq_membership_grants_current ON membership_grants(workspace_id,user_id) WHERE revoked_at IS NULL;
/* Vòng current-pointer cho phép tạo membership và grant atomically trong cùng transaction. */
ALTER TABLE memberships ADD CONSTRAINT fk_memberships_current_grant
    FOREIGN KEY(workspace_id,user_id,current_grant_generation)
    REFERENCES membership_grants DEFERRABLE INITIALLY DEFERRED;
/* Khóa được cả email chưa có User; không giữ raw invitation token. */
CREATE TABLE membership_admission_fences (
    workspace_id uuid NOT NULL REFERENCES workspaces,
    email_digest bytea NOT NULL CHECK (octet_length(email_digest)=32),
    admission_generation bigint NOT NULL CHECK (admission_generation>0),
    updated_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
    PRIMARY KEY(workspace_id,email_digest),
    UNIQUE(workspace_id,email_digest,admission_generation)
);
/* Invitation đóng băng issuer grant/admission generation; service vẫn recheck quyền khi consume. */
CREATE TABLE workspace_invitations (
    workspace_id uuid NOT NULL, invitation_id uuid NOT NULL,
    token_digest bytea NOT NULL UNIQUE CHECK (octet_length(token_digest)=32),
    email_normalized text NOT NULL, email_digest bytea NOT NULL,
    role text NOT NULL CHECK (role IN ('ADMIN','USER')),
    issued_by_user_id uuid NOT NULL, issuer_grant_generation bigint NOT NULL,
    issuer_authorization_version bigint NOT NULL CHECK (issuer_authorization_version>0),
    admission_generation bigint NOT NULL, issued_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL, used_at timestamptz, revoked_at timestamptz, expired_at timestamptz,
    PRIMARY KEY(workspace_id,invitation_id),
    FOREIGN KEY(workspace_id,issued_by_user_id,issuer_grant_generation) REFERENCES membership_grants,
    FOREIGN KEY(workspace_id,email_digest,admission_generation)
        REFERENCES membership_admission_fences(workspace_id,email_digest,admission_generation),
    CHECK (expires_at=issued_at+interval '24 hours')
);
/* Expiry được đánh dấu dưới fence trước invite mới; không dùng partial predicate phụ thuộc clock. */
CREATE UNIQUE INDEX uq_workspace_invitations_pending ON workspace_invitations(workspace_id,email_digest)
    WHERE used_at IS NULL AND revoked_at IS NULL AND expired_at IS NULL;
/* Reset admission không lưu temporary password; budget5/15min thuộc controlled transaction. */
CREATE TABLE password_reset_admissions (
    admission_id uuid PRIMARY KEY, workspace_id uuid NOT NULL,
    actor_user_id uuid NOT NULL, target_user_id uuid NOT NULL, admitted_at timestamptz NOT NULL,
    FOREIGN KEY(workspace_id,actor_user_id) REFERENCES memberships,
    FOREIGN KEY(workspace_id,target_user_id) REFERENCES memberships
);
/* Scope/actor/target đứng trước mốc thời gian để đếm budget reset đúng tenant. */
CREATE INDEX ix_password_reset_budget ON password_reset_admissions(workspace_id,actor_user_id,target_user_id,admitted_at);
/* Hàng khóa quota là projection, cần reconcile từ execution ledger trước mở worker. */
CREATE TABLE workspace_runtime_quotas (
    workspace_id uuid PRIMARY KEY REFERENCES workspaces,
    active_execution_count integer NOT NULL DEFAULT 0 CHECK (active_execution_count BETWEEN 0 AND 10),
    revision bigint NOT NULL DEFAULT 1 CHECK (revision>0)
);
/* Ticket one-time có binding đầy đủ; raw ticket chỉ được trả tại admission. */
CREATE TABLE websocket_tickets (
    ticket_id uuid PRIMARY KEY, ticket_digest bytea NOT NULL UNIQUE CHECK (octet_length(ticket_digest)=32),
    workspace_id uuid NOT NULL, user_id uuid NOT NULL, session_id uuid NOT NULL,
    grant_generation bigint NOT NULL, workspace_authorization_version bigint NOT NULL CHECK (workspace_authorization_version>0),
    membership_authorization_version bigint NOT NULL CHECK (membership_authorization_version>0),
    issued_at timestamptz NOT NULL, expires_at timestamptz NOT NULL, consumed_at timestamptz, revoked_at timestamptz,
    FOREIGN KEY(user_id,session_id) REFERENCES sessions(user_id,session_id),
    FOREIGN KEY(workspace_id,user_id,grant_generation) REFERENCES membership_grants,
    CHECK (expires_at=issued_at+interval '30 seconds')
);
/* Audit global có workspace NULL; session luôn phải thuộc actor, không cascade mất bằng chứng. */
CREATE TABLE audit_events (
    audit_event_id uuid PRIMARY KEY, workspace_id uuid REFERENCES workspaces,
    actor_user_id uuid REFERENCES users, session_id uuid REFERENCES sessions,
    event_type text NOT NULL, outcome text NOT NULL, resource_type text, resource_id text,
    correlation_id uuid NOT NULL, occurred_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
    reason_code text, redacted_diff jsonb,
    client_type text NOT NULL CHECK (client_type IN ('WEB','ANDROID','UNKNOWN')),
    FOREIGN KEY(actor_user_id,session_id) REFERENCES sessions(user_id,session_id),
    CHECK (session_id IS NULL OR actor_user_id IS NOT NULL),
    CHECK ((resource_type IS NULL)=(resource_id IS NULL))
);
/* Workspace/time phục vụ history; global retention dùng time trước identity riêng. */
CREATE INDEX ix_audit_workspace_time ON audit_events(workspace_id,occurred_at DESC,audit_event_id);
CREATE INDEX ix_audit_retention ON audit_events(occurred_at,audit_event_id);

INSERT INTO migration_control.applied_migrations(version,checksum)
    VALUES(:'migration_version',:'migration_checksum');
\echo APPLIED
\else
SELECT checksum=:'migration_checksum' AS checksum_matches
    FROM migration_control.applied_migrations WHERE version=:'migration_version' \gset
\if :checksum_matches
\echo ALREADY_APPLIED
\else
/* Drift phải rollback, không UPDATE checksum để hợp thức hóa lịch sử bị thay đổi. */
DO $$ BEGIN RAISE EXCEPTION 'migration checksum drift'; END $$;
\endif
\endif
COMMIT;

\set migration_version platform-0002-devices
\set migration_checksum 2b5d5300200de6d10b7ef08a1d8dbeb4f93aeb695145418a761285ef027f821b

/* Template psql của runner; hai marker chỉ được thay bằng file SQL nguồn trong repo.
 * migration_version/checksum là literal qua :'name', không chèn input vào SQL.
 * DDL và ledger commit cùng nhau; advisory lock dùng chung cho mọi version/runner.
 */
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
SELECT pg_advisory_xact_lock(17001,1);
/* Lịch sử runner lab: lưu checksum và thời điểm áp thật, không chứa credential.
 * Phải chạy trong transaction đã lấy advisory lock; không thay SQLx production history.
 */
CREATE SCHEMA IF NOT EXISTS migration_control;
CREATE TABLE IF NOT EXISTS migration_control.applied_migrations (
    version text PRIMARY KEY,
    checksum text NOT NULL CHECK(checksum ~ '^[0-9a-f]{64}$'),
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

SELECT NOT EXISTS(
    SELECT 1 FROM migration_control.applied_migrations WHERE version=:'migration_version'
) AS should_apply \gset
\if :should_apply
/* Template, thiết bị và telemetry dùng chung database; phụ thuộc IAM0001.
 * Chỉ DDL trên baseline mới; FK giữ lịch sử, không backfill/xóa auth lab.
 */
CREATE TABLE templates (
 workspace_id uuid NOT NULL REFERENCES workspaces, template_id uuid NOT NULL,
 name text NOT NULL CHECK(btrim(name)<>''), model text NOT NULL CHECK(btrim(model)<>''), description text,
 lifecycle_status text NOT NULL DEFAULT 'DRAFT' CHECK(lifecycle_status IN ('DRAFT','PUBLISHED','ARCHIVED')),
 created_by_user_id uuid NOT NULL, revision bigint NOT NULL DEFAULT 1 CHECK(revision>0),
 created_at timestamptz NOT NULL DEFAULT transaction_timestamp(), updated_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
 PRIMARY KEY(workspace_id,template_id), FOREIGN KEY(workspace_id,created_by_user_id) REFERENCES memberships
);
/* Draft và snapshot có grain riêng; không sửa snapshot khi draft đổi. */
CREATE TABLE template_draft_streams (
 workspace_id uuid NOT NULL, template_id uuid NOT NULL, stream_key text NOT NULL CHECK(btrim(stream_key)<>''),
 display_name text NOT NULL, data_type text NOT NULL CHECK(data_type IN ('NUMBER','BOOLEAN','STRING','ENUM')),
 direction text NOT NULL CHECK(direction IN ('READ','WRITE','READ_WRITE')), unit text,
 min_value double precision, max_value double precision, string_max_length integer CHECK(string_max_length>0),
 revision bigint NOT NULL DEFAULT 1 CHECK(revision>0),
 PRIMARY KEY(workspace_id,template_id,stream_key), FOREIGN KEY(workspace_id,template_id) REFERENCES templates,
 CONSTRAINT ck_draft_stream_bounds CHECK(
  (min_value IS NULL OR (data_type='NUMBER' AND min_value>'-Infinity'::float8 AND min_value<'Infinity'::float8)) AND
  (max_value IS NULL OR (data_type='NUMBER' AND max_value>'-Infinity'::float8 AND max_value<'Infinity'::float8)) AND
  (min_value IS NULL OR max_value IS NULL OR min_value<=max_value) AND (string_max_length IS NULL OR data_type='STRING'))
);
/* ENUM là tập có khóa, không mảng ID; enum_value là literal JSON scalar giữ NUMBER/STRING. */
CREATE TABLE template_draft_enum_values (
 workspace_id uuid NOT NULL, template_id uuid NOT NULL, stream_key text NOT NULL, enum_value jsonb NOT NULL,
 PRIMARY KEY(workspace_id,template_id,stream_key,enum_value),
 FOREIGN KEY(workspace_id,template_id,stream_key) REFERENCES template_draft_streams,
 CHECK(jsonb_typeof(enum_value) IN ('string','number'))
);
/* Safe value thuộc capability SET_VALUE; validator đối chiếu type/range của stream trước publish. */
CREATE TABLE template_draft_capabilities (
 workspace_id uuid NOT NULL, template_id uuid NOT NULL, stream_key text NOT NULL,
 command_type text NOT NULL CHECK(command_type='SET_VALUE'), safe_value jsonb NOT NULL CHECK(jsonb_typeof(safe_value) IN ('number','boolean','string')),
 PRIMARY KEY(workspace_id,template_id,stream_key,command_type),
 FOREIGN KEY(workspace_id,template_id,stream_key) REFERENCES template_draft_streams
);
/* Metadata model/name là snapshot tại publish, không live-copy metadata root. */
CREATE TABLE template_versions (
 workspace_id uuid NOT NULL, template_version_id uuid NOT NULL, template_id uuid NOT NULL,
 version_number integer NOT NULL CHECK(version_number>0), name text NOT NULL, model text NOT NULL,
 published_at timestamptz NOT NULL DEFAULT transaction_timestamp(), published_by_user_id uuid NOT NULL,
 content_digest bytea NOT NULL CHECK(octet_length(content_digest)=32),
 PRIMARY KEY(workspace_id,template_version_id), UNIQUE(workspace_id,template_id,version_number),
 FOREIGN KEY(workspace_id,template_id) REFERENCES templates,
 FOREIGN KEY(workspace_id,published_by_user_id) REFERENCES memberships
);
CREATE TABLE datastream_definitions (
 workspace_id uuid NOT NULL, template_version_id uuid NOT NULL, stream_key text NOT NULL CHECK(btrim(stream_key)<>''),
 display_name text NOT NULL, data_type text NOT NULL CHECK(data_type IN ('NUMBER','BOOLEAN','STRING','ENUM')),
 direction text NOT NULL CHECK(direction IN ('READ','WRITE','READ_WRITE')), unit text,
 min_value double precision, max_value double precision, string_max_length integer CHECK(string_max_length>0),
 PRIMARY KEY(workspace_id,template_version_id,stream_key), FOREIGN KEY(workspace_id,template_version_id) REFERENCES template_versions,
 CONSTRAINT ck_datastream_bounds CHECK(
  (min_value IS NULL OR (data_type='NUMBER' AND min_value>'-Infinity'::float8 AND min_value<'Infinity'::float8)) AND
  (max_value IS NULL OR (data_type='NUMBER' AND max_value>'-Infinity'::float8 AND max_value<'Infinity'::float8)) AND
  (min_value IS NULL OR max_value IS NULL OR min_value<=max_value) AND (string_max_length IS NULL OR data_type='STRING'))
);
CREATE TABLE datastream_enum_values (
 workspace_id uuid NOT NULL, template_version_id uuid NOT NULL, stream_key text NOT NULL, enum_value jsonb NOT NULL,
 PRIMARY KEY(workspace_id,template_version_id,stream_key,enum_value),
 FOREIGN KEY(workspace_id,template_version_id,stream_key) REFERENCES datastream_definitions,
 CHECK(jsonb_typeof(enum_value) IN ('string','number'))
);
CREATE TABLE datastream_capabilities (
 workspace_id uuid NOT NULL, template_version_id uuid NOT NULL, stream_key text NOT NULL,
 command_type text NOT NULL CHECK(command_type='SET_VALUE'), safe_value jsonb NOT NULL CHECK(jsonb_typeof(safe_value) IN ('number','boolean','string')),
 PRIMARY KEY(workspace_id,template_version_id,stream_key,command_type),
 FOREIGN KEY(workspace_id,template_version_id,stream_key) REFERENCES datastream_definitions
);
/* device_id và serial global cho MQTT lookup; UK scoped bảo vệ mọi reference tenant. */
CREATE TABLE devices (
 device_id uuid PRIMARY KEY, workspace_id uuid NOT NULL REFERENCES workspaces, serial_number text NOT NULL UNIQUE,
 template_version_id uuid NOT NULL, owner_user_id uuid NOT NULL, name text NOT NULL, description text,
 model text NOT NULL, hardware_revision text NOT NULL, firmware_version text, firmware_digest bytea CHECK(octet_length(firmware_digest)=32),
 lifecycle_status text NOT NULL DEFAULT 'ACTIVE' CHECK(lifecycle_status IN ('ACTIVE','SUSPENDED','ARCHIVED')),
 revision bigint NOT NULL DEFAULT 1 CHECK(revision>0), authorization_version bigint NOT NULL DEFAULT 1 CHECK(authorization_version>0),
 created_at timestamptz NOT NULL DEFAULT transaction_timestamp(), updated_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
 UNIQUE(workspace_id,device_id), UNIQUE(workspace_id,device_id,template_version_id),
 FOREIGN KEY(workspace_id,template_version_id) REFERENCES template_versions,
 FOREIGN KEY(workspace_id,owner_user_id) REFERENCES memberships
);
/* Tenant/owner trước identity phục vụ danh sách thiết bị được giao. */
CREATE INDEX ix_devices_owner ON devices(workspace_id,owner_user_id,device_id);
CREATE TABLE device_runtime (
 workspace_id uuid NOT NULL, device_id uuid NOT NULL,
 ingestion_sequence bigint NOT NULL DEFAULT 0 CHECK(ingestion_sequence>=0), connection_generation bigint NOT NULL DEFAULT 0 CHECK(connection_generation>=0),
 maintenance_epoch bigint NOT NULL DEFAULT 0 CHECK(maintenance_epoch>=0), maintenance text NOT NULL DEFAULT 'NONE' CHECK(maintenance IN ('NONE','OTA')),
 last_seen_at timestamptz, presence_state text NOT NULL DEFAULT 'OFFLINE' CHECK(presence_state IN ('ONLINE','OFFLINE')), current_boot_id text,
 PRIMARY KEY(workspace_id,device_id), FOREIGN KEY(workspace_id,device_id) REFERENCES devices(workspace_id,device_id)
);
CREATE TABLE device_credentials (
 workspace_id uuid NOT NULL, device_id uuid NOT NULL, credential_generation bigint NOT NULL CHECK(credential_generation>0),
 credential_identifier text NOT NULL UNIQUE, verifier_digest bytea NOT NULL CHECK(octet_length(verifier_digest)=32),
 credential_state text NOT NULL CHECK(credential_state IN ('PROVISIONING','ACTIVE','REVOKING','REVOKED','FAILED')),
 issued_at timestamptz NOT NULL DEFAULT transaction_timestamp(), revoked_at timestamptz,
 PRIMARY KEY(workspace_id,device_id,credential_generation), FOREIGN KEY(workspace_id,device_id) REFERENCES devices(workspace_id,device_id)
);
/* Không cấp hai credential ACTIVE cho cùng thiết bị. */
CREATE UNIQUE INDEX uq_device_credentials_active ON device_credentials(workspace_id,device_id) WHERE credential_state='ACTIVE';
CREATE TABLE device_boot_sessions (
 workspace_id uuid NOT NULL, device_id uuid NOT NULL, boot_id text NOT NULL CHECK(btrim(boot_id)<>''),
 credential_generation bigint NOT NULL, connection_generation bigint NOT NULL CHECK(connection_generation>0),
 started_at timestamptz NOT NULL, retired_at timestamptz, source_sequence_floor bigint NOT NULL DEFAULT 0 CHECK(source_sequence_floor>=0),
 last_source_sequence bigint CHECK(last_source_sequence>=source_sequence_floor),
 PRIMARY KEY(workspace_id,device_id,boot_id), UNIQUE(workspace_id,device_id,boot_id,credential_generation),
 FOREIGN KEY(workspace_id,device_id,credential_generation) REFERENCES device_credentials
);
ALTER TABLE device_runtime ADD CONSTRAINT fk_device_runtime_boot FOREIGN KEY(workspace_id,device_id,current_boot_id) REFERENCES device_boot_sessions;
CREATE TABLE provisioning_operations (
 workspace_id uuid NOT NULL, provisioning_operation_id uuid NOT NULL, device_id uuid NOT NULL, credential_generation bigint NOT NULL,
 delivery_channel text NOT NULL CHECK(delivery_channel IN ('USB_ONE_TIME','ENROLLMENT_BLE')),
 state text NOT NULL CHECK(state IN ('PENDING','PROVISIONING','READY','CLAIMED','FAILED','EXPIRED','REVOKING','REVOKED')),
 actor_user_id uuid NOT NULL, intent_at timestamptz NOT NULL, expires_at timestamptz NOT NULL,
 broker_receipt_at timestamptz, claimed_at timestamptz, secret_ciphertext bytea, encryption_key_reference text,
 PRIMARY KEY(workspace_id,provisioning_operation_id), UNIQUE(workspace_id,device_id,credential_generation),
 UNIQUE(workspace_id,provisioning_operation_id,device_id),
 FOREIGN KEY(workspace_id,device_id,credential_generation) REFERENCES device_credentials,
 FOREIGN KEY(workspace_id,actor_user_id) REFERENCES memberships,
 CHECK(expires_at>intent_at), CHECK((secret_ciphertext IS NULL)=(encryption_key_reference IS NULL))
);
CREATE TABLE device_operations (
 workspace_id uuid NOT NULL, device_operation_id uuid NOT NULL, device_id uuid NOT NULL,
 operation_type text NOT NULL CHECK(operation_type IN ('SUSPEND','RESUME','ARCHIVE','REVOKE_CREDENTIAL')),
 state text NOT NULL CHECK(state IN ('PENDING','RUNNING','SUCCEEDED','FAILED','NEEDS_ATTENTION')),
 requested_revision bigint NOT NULL CHECK(requested_revision>0), actor_user_id uuid NOT NULL,
 intent_at timestamptz NOT NULL, settled_at timestamptz, broker_revoke_receipt jsonb, disconnect_receipt jsonb,
 PRIMARY KEY(workspace_id,device_operation_id), UNIQUE(workspace_id,device_operation_id,device_id),
 FOREIGN KEY(workspace_id,device_id) REFERENCES devices(workspace_id,device_id), FOREIGN KEY(workspace_id,actor_user_id) REFERENCES memberships
);
/* Cleanup chưa có proof vẫn giữ operation guard. */
CREATE UNIQUE INDEX uq_device_operations_unsettled ON device_operations(workspace_id,device_id) WHERE settled_at IS NULL;
CREATE TABLE connectivity_transitions (
 workspace_id uuid NOT NULL, device_id uuid NOT NULL, transition_sequence bigint NOT NULL CHECK(transition_sequence>0),
 connection_generation bigint NOT NULL CHECK(connection_generation>0),
 from_state text NOT NULL CHECK(from_state IN ('ONLINE','OFFLINE')), to_state text NOT NULL CHECK(to_state IN ('ONLINE','OFFLINE')),
 observed_at timestamptz NOT NULL, boot_id text,
 PRIMARY KEY(workspace_id,device_id,transition_sequence), CHECK(from_state<>to_state),
 FOREIGN KEY(workspace_id,device_id) REFERENCES devices(workspace_id,device_id), FOREIGN KEY(workspace_id,device_id,boot_id) REFERENCES device_boot_sessions
);
/* Receipt là authority dedupe, không tham chiếu ngược raw để purge raw độc lập. */
CREATE TABLE telemetry_receipts (
 workspace_id uuid NOT NULL, device_id uuid NOT NULL, boot_id text NOT NULL, message_id text NOT NULL CHECK(btrim(message_id)<>''),
 source_sequence bigint NOT NULL CHECK(source_sequence>=0), payload_digest bytea NOT NULL CHECK(octet_length(payload_digest)=32),
 first_received_at timestamptz NOT NULL, ingestion_sequence bigint NOT NULL CHECK(ingestion_sequence>0),
 PRIMARY KEY(workspace_id,device_id,boot_id,message_id), UNIQUE(workspace_id,device_id,ingestion_sequence),
 FOREIGN KEY(workspace_id,device_id,boot_id) REFERENCES device_boot_sessions
);
CREATE TABLE telemetry_envelopes (
 workspace_id uuid NOT NULL, envelope_id uuid NOT NULL, device_id uuid NOT NULL, boot_id text NOT NULL, message_id text NOT NULL,
 observed_at timestamptz, received_at timestamptz NOT NULL, effective_at timestamptz NOT NULL,
 time_basis text NOT NULL CHECK(time_basis IN ('DEVICE','SERVER')), ingestion_sequence bigint NOT NULL CHECK(ingestion_sequence>0),
 point_count integer NOT NULL CHECK(point_count BETWEEN 1 AND 10),
 PRIMARY KEY(workspace_id,envelope_id), UNIQUE(workspace_id,device_id,boot_id,message_id), UNIQUE(workspace_id,envelope_id,device_id),
 FOREIGN KEY(workspace_id,device_id,boot_id,message_id) REFERENCES telemetry_receipts,
 CONSTRAINT ck_telemetry_time_basis CHECK((time_basis='DEVICE' AND observed_at IS NOT NULL AND effective_at=observed_at) OR (time_basis='SERVER' AND effective_at=received_at))
);
/* Truy vấn lịch sử theo tenant/device rồi mốc ingest; receipt giữ riêng tính duy nhất. */
CREATE INDEX ix_telemetry_envelopes_device ON telemetry_envelopes(workspace_id,device_id,ingestion_sequence);
CREATE TABLE telemetry_points (
 workspace_id uuid NOT NULL, envelope_id uuid NOT NULL, point_index integer NOT NULL CHECK(point_index BETWEEN 0 AND 9),
 device_id uuid NOT NULL, stream_key text NOT NULL, observed_at timestamptz, event_at timestamptz NOT NULL,
 quality text NOT NULL CHECK(quality IN ('GOOD','NULL','SERVER_TIME')),
 value_type text NOT NULL CHECK(value_type IN ('NUMBER','BOOLEAN','STRING','ENUM')),
 numeric_value double precision, boolean_value boolean, text_value text,
 PRIMARY KEY(workspace_id,envelope_id,point_index), UNIQUE(workspace_id,envelope_id,stream_key),
 FOREIGN KEY(workspace_id,envelope_id,device_id) REFERENCES telemetry_envelopes(workspace_id,envelope_id,device_id),
 CONSTRAINT ck_telemetry_point_value CHECK(
  (quality='NULL' AND num_nonnulls(numeric_value,boolean_value,text_value)=0) OR
  (quality<>'NULL' AND num_nonnulls(numeric_value,boolean_value,text_value)=1 AND
   ((value_type='NUMBER' AND numeric_value IS NOT NULL) OR (value_type='BOOLEAN' AND boolean_value IS NOT NULL) OR
    (value_type='STRING' AND text_value IS NOT NULL) OR (value_type='ENUM' AND (numeric_value IS NOT NULL OR text_value IS NOT NULL))))),
 CHECK(numeric_value IS NULL OR (numeric_value>'-Infinity'::float8 AND numeric_value<'Infinity'::float8))
);
/* Projection device/time theo Core33; trigger0007 kiểm null-safe với envelope authority. */
CREATE INDEX ix_telemetry_points_history ON telemetry_points(workspace_id,device_id,stream_key,event_at DESC,envelope_id);
CREATE TABLE device_latest_values (
 workspace_id uuid NOT NULL, device_id uuid NOT NULL, template_version_id uuid NOT NULL, stream_key text NOT NULL,
 latest_marker_sequence bigint NOT NULL CHECK(latest_marker_sequence>0), latest_received_at timestamptz NOT NULL,
 latest_value jsonb, rule_eligible_marker_sequence bigint CHECK(rule_eligible_marker_sequence>0), rule_value jsonb,
 eligibility_reason text NOT NULL,
 PRIMARY KEY(workspace_id,device_id,stream_key),
 FOREIGN KEY(workspace_id,device_id,template_version_id) REFERENCES devices(workspace_id,device_id,template_version_id),
 FOREIGN KEY(workspace_id,template_version_id,stream_key) REFERENCES datastream_definitions,
 CHECK(rule_eligible_marker_sequence IS NULL OR rule_eligible_marker_sequence<=latest_marker_sequence)
);

INSERT INTO migration_control.applied_migrations(version,checksum)
    VALUES(:'migration_version',:'migration_checksum');
\echo APPLIED
\else
SELECT checksum=:'migration_checksum' AS checksum_matches
    FROM migration_control.applied_migrations WHERE version=:'migration_version' \gset
\if :checksum_matches
\echo ALREADY_APPLIED
\else
/* Drift phải rollback, không UPDATE checksum để hợp thức hóa lịch sử bị thay đổi. */
DO $$ BEGIN RAISE EXCEPTION 'migration checksum drift'; END $$;
\endif
\endif
COMMIT;

\set migration_version platform-0003-automation
\set migration_checksum b39d2c6a9abdb6f2875ce0bb60fa148ef3a38620662157a05c02001c0c284925

/* Template psql của runner; hai marker chỉ được thay bằng file SQL nguồn trong repo.
 * migration_version/checksum là literal qua :'name', không chèn input vào SQL.
 * DDL và ledger commit cùng nhau; advisory lock dùng chung cho mọi version/runner.
 */
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
SELECT pg_advisory_xact_lock(17001,1);
/* Lịch sử runner lab: lưu checksum và thời điểm áp thật, không chứa credential.
 * Phải chạy trong transaction đã lấy advisory lock; không thay SQLx production history.
 */
CREATE SCHEMA IF NOT EXISTS migration_control;
CREATE TABLE IF NOT EXISTS migration_control.applied_migrations (
    version text PRIMARY KEY,
    checksum text NOT NULL CHECK(checksum ~ '^[0-9a-f]{64}$'),
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

SELECT NOT EXISTS(
    SELECT 1 FROM migration_control.applied_migrations WHERE version=:'migration_version'
) AS should_apply \gset
\if :should_apply
/* Automation/command/dashboard phụ thuộc device pin0002; cycle FK được đóng cuối migration.
 * Không dispatch mạng, không reset dữ liệu; writer bị khóa ở0007 trước mở ứng dụng.
 */
CREATE TABLE actuator_states (
 workspace_id uuid NOT NULL, device_id uuid NOT NULL, stream_key text NOT NULL, pinned_template_version_id uuid NOT NULL,
 manual_epoch bigint NOT NULL DEFAULT 0 CHECK(manual_epoch>=0), last_reported_value jsonb, last_reported_at timestamptz,
 reported_source text NOT NULL DEFAULT 'NONE' CHECK(reported_source IN ('NONE','DEVICE_RESULT','TELEMETRY','HELLO')),
 unresolved_command_id uuid,
 PRIMARY KEY(workspace_id,device_id,stream_key),
 FOREIGN KEY(workspace_id,device_id,pinned_template_version_id) REFERENCES devices(workspace_id,device_id,template_version_id),
 FOREIGN KEY(workspace_id,pinned_template_version_id,stream_key) REFERENCES datastream_definitions
);
CREATE TABLE dashboards (
 workspace_id uuid NOT NULL, dashboard_id uuid NOT NULL, owner_user_id uuid NOT NULL, title text NOT NULL,
 schema_version integer NOT NULL DEFAULT 1 CHECK(schema_version=1), revision bigint NOT NULL DEFAULT 1 CHECK(revision>0),
 lifecycle_status text NOT NULL DEFAULT 'ACTIVE' CHECK(lifecycle_status IN ('ACTIVE','ARCHIVED')),
 created_at timestamptz NOT NULL DEFAULT transaction_timestamp(), updated_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
 PRIMARY KEY(workspace_id,dashboard_id), FOREIGN KEY(workspace_id,owner_user_id) REFERENCES memberships
);
CREATE TABLE dashboard_widgets (
 workspace_id uuid NOT NULL, dashboard_id uuid NOT NULL, widget_id uuid NOT NULL,
 widget_type text NOT NULL CHECK(widget_type IN ('VALUE','GAUGE','STATUS','SWITCH','BUTTON','CHART')),
 position integer NOT NULL CHECK(position BETWEEN 0 AND 19), presentation jsonb NOT NULL DEFAULT '{}' CHECK(jsonb_typeof(presentation)='object'),
 layout_x integer NOT NULL CHECK(layout_x BETWEEN 0 AND 11), layout_y integer NOT NULL CHECK(layout_y>=0),
 layout_width integer NOT NULL CHECK(layout_width>0), layout_height integer NOT NULL CHECK(layout_height>0),
 PRIMARY KEY(workspace_id,dashboard_id,widget_id), UNIQUE(workspace_id,dashboard_id,position),
 FOREIGN KEY(workspace_id,dashboard_id) REFERENCES dashboards, CHECK(layout_x+layout_width<=12)
);
/* Presence không có stream; tuple pin/stream cùng NULL hoặc cùng có, device luôn scoped. */
CREATE TABLE dashboard_widget_bindings (
 workspace_id uuid NOT NULL, dashboard_id uuid NOT NULL, widget_id uuid NOT NULL, binding_slot text NOT NULL,
 device_id uuid NOT NULL, template_version_id uuid, stream_key text,
 PRIMARY KEY(workspace_id,dashboard_id,widget_id,binding_slot),
 FOREIGN KEY(workspace_id,dashboard_id,widget_id) REFERENCES dashboard_widgets,
 FOREIGN KEY(workspace_id,device_id) REFERENCES devices(workspace_id,device_id),
 FOREIGN KEY(workspace_id,device_id,template_version_id) REFERENCES devices(workspace_id,device_id,template_version_id),
 FOREIGN KEY(workspace_id,template_version_id,stream_key) REFERENCES datastream_definitions,
 CHECK((template_version_id IS NULL)=(stream_key IS NULL))
);
CREATE TABLE rules (
 workspace_id uuid NOT NULL, rule_id uuid NOT NULL, owner_user_id uuid NOT NULL, name text NOT NULL,
 lifecycle_status text NOT NULL DEFAULT 'DRAFT' CHECK(lifecycle_status IN ('DRAFT','ENABLED','DISABLED','ARCHIVED','ERROR_DISABLED')),
 revision bigint NOT NULL DEFAULT 1 CHECK(revision>0), draft_revision bigint NOT NULL DEFAULT 1 CHECK(draft_revision>0), active_rule_version_id uuid,
 created_at timestamptz NOT NULL DEFAULT transaction_timestamp(), updated_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
 PRIMARY KEY(workspace_id,rule_id), FOREIGN KEY(workspace_id,owner_user_id) REFERENCES memberships
);
CREATE TABLE rule_drafts (
 workspace_id uuid NOT NULL, rule_id uuid NOT NULL,
 trigger_type text NOT NULL CHECK(trigger_type IN ('THRESHOLD','SCHEDULE','CONNECTIVITY','MANUAL')),
 trigger_config jsonb NOT NULL CHECK(jsonb_typeof(trigger_config)='object'), condition_ast jsonb NOT NULL CHECK(jsonb_typeof(condition_ast)='object'),
 schema_version integer NOT NULL DEFAULT 1 CHECK(schema_version=1), cooldown_seconds integer NOT NULL CHECK(cooldown_seconds BETWEEN 10 AND 3600),
 priority text NOT NULL CHECK(priority IN ('HIGH','NORMAL','LOW')), on_failure text NOT NULL CHECK(on_failure IN ('STOP','CONTINUE')),
 PRIMARY KEY(workspace_id,rule_id), FOREIGN KEY(workspace_id,rule_id) REFERENCES rules
);
CREATE TABLE rule_draft_actions (
 workspace_id uuid NOT NULL, rule_id uuid NOT NULL, action_position integer NOT NULL CHECK(action_position BETWEEN 0 AND 4),
 action_type text NOT NULL CHECK(action_type IN ('SET_VALUE','WAIT','NOTIFY')), wait_seconds integer,
 target_device_id uuid, target_template_version_id uuid, target_stream_key text, target_value jsonb, notification_config jsonb,
 PRIMARY KEY(workspace_id,rule_id,action_position), FOREIGN KEY(workspace_id,rule_id) REFERENCES rule_drafts,
 FOREIGN KEY(workspace_id,target_device_id,target_template_version_id) REFERENCES devices(workspace_id,device_id,template_version_id),
 FOREIGN KEY(workspace_id,target_template_version_id,target_stream_key) REFERENCES datastream_definitions,
 CONSTRAINT ck_rule_draft_action_shape CHECK(
  (action_type='WAIT' AND wait_seconds IS NOT NULL AND wait_seconds BETWEEN 5 AND 600 AND num_nonnulls(target_device_id,target_template_version_id,target_stream_key,target_value,notification_config)=0) OR
  (action_type='SET_VALUE' AND wait_seconds IS NULL AND notification_config IS NULL AND num_nonnulls(target_device_id,target_template_version_id,target_stream_key,target_value)=4 AND jsonb_typeof(target_value) IN ('boolean','number','string')) OR
  (action_type='NOTIFY' AND notification_config IS NOT NULL AND jsonb_typeof(notification_config)='object' AND num_nonnulls(wait_seconds,target_device_id,target_template_version_id,target_stream_key,target_value)=0))
);
CREATE TABLE rule_draft_references (
 workspace_id uuid NOT NULL, rule_id uuid NOT NULL, reference_path text NOT NULL, device_id uuid NOT NULL,
 template_version_id uuid NOT NULL, stream_key text, reference_kind text NOT NULL CHECK(reference_kind IN ('TRIGGER','CONDITION','ACTION')),
 PRIMARY KEY(workspace_id,rule_id,reference_path), FOREIGN KEY(workspace_id,rule_id) REFERENCES rule_drafts,
 FOREIGN KEY(workspace_id,device_id,template_version_id) REFERENCES devices(workspace_id,device_id,template_version_id),
 FOREIGN KEY(workspace_id,template_version_id,stream_key) REFERENCES datastream_definitions
);
CREATE TABLE rule_versions (
 workspace_id uuid NOT NULL, rule_version_id uuid NOT NULL, rule_id uuid NOT NULL, version_number integer NOT NULL CHECK(version_number>0),
 trigger_type text NOT NULL CHECK(trigger_type IN ('THRESHOLD','SCHEDULE','CONNECTIVITY','MANUAL')),
 trigger_config jsonb NOT NULL CHECK(jsonb_typeof(trigger_config)='object'), condition_ast jsonb NOT NULL CHECK(jsonb_typeof(condition_ast)='object'),
 schema_version integer NOT NULL DEFAULT 1 CHECK(schema_version=1), cooldown_seconds integer NOT NULL CHECK(cooldown_seconds BETWEEN 10 AND 3600),
 priority text NOT NULL CHECK(priority IN ('HIGH','NORMAL','LOW')), on_failure text NOT NULL CHECK(on_failure IN ('STOP','CONTINUE')),
 published_at timestamptz NOT NULL DEFAULT transaction_timestamp(), content_digest bytea NOT NULL CHECK(octet_length(content_digest)=32),
 PRIMARY KEY(workspace_id,rule_version_id), UNIQUE(workspace_id,rule_id,version_number), UNIQUE(workspace_id,rule_id,rule_version_id),
 FOREIGN KEY(workspace_id,rule_id) REFERENCES rules
);
ALTER TABLE rules ADD CONSTRAINT fk_rules_active_version FOREIGN KEY(workspace_id,rule_id,active_rule_version_id) REFERENCES rule_versions(workspace_id,rule_id,rule_version_id) DEFERRABLE INITIALLY DEFERRED;
CREATE TABLE rule_version_actions (
 workspace_id uuid NOT NULL, rule_version_id uuid NOT NULL, action_position integer NOT NULL CHECK(action_position BETWEEN 0 AND 4),
 action_type text NOT NULL CHECK(action_type IN ('SET_VALUE','WAIT','NOTIFY')), wait_seconds integer,
 target_device_id uuid, target_template_version_id uuid, target_stream_key text, target_value jsonb, notification_config jsonb,
 PRIMARY KEY(workspace_id,rule_version_id,action_position), FOREIGN KEY(workspace_id,rule_version_id) REFERENCES rule_versions,
 FOREIGN KEY(workspace_id,target_device_id,target_template_version_id) REFERENCES devices(workspace_id,device_id,template_version_id),
 FOREIGN KEY(workspace_id,target_template_version_id,target_stream_key) REFERENCES datastream_definitions,
 CONSTRAINT ck_rule_version_action_shape CHECK(
  (action_type='WAIT' AND wait_seconds IS NOT NULL AND wait_seconds BETWEEN 5 AND 600 AND num_nonnulls(target_device_id,target_template_version_id,target_stream_key,target_value,notification_config)=0) OR
  (action_type='SET_VALUE' AND wait_seconds IS NULL AND notification_config IS NULL AND num_nonnulls(target_device_id,target_template_version_id,target_stream_key,target_value)=4 AND jsonb_typeof(target_value) IN ('boolean','number','string')) OR
  (action_type='NOTIFY' AND notification_config IS NOT NULL AND jsonb_typeof(notification_config)='object' AND num_nonnulls(wait_seconds,target_device_id,target_template_version_id,target_stream_key,target_value)=0))
);
/* Tối đa một NOTIFY; tổng WAIT và contiguity kiểm tại publish boundary. */
CREATE UNIQUE INDEX uq_rule_version_notify ON rule_version_actions(workspace_id,rule_version_id) WHERE action_type='NOTIFY';
CREATE UNIQUE INDEX uq_rule_draft_notify ON rule_draft_actions(workspace_id,rule_id) WHERE action_type='NOTIFY';
CREATE TABLE rule_version_references (
 workspace_id uuid NOT NULL, rule_version_id uuid NOT NULL, reference_path text NOT NULL, device_id uuid NOT NULL,
 template_version_id uuid NOT NULL, stream_key text, reference_kind text NOT NULL CHECK(reference_kind IN ('TRIGGER','CONDITION','ACTION')),
 PRIMARY KEY(workspace_id,rule_version_id,reference_path), FOREIGN KEY(workspace_id,rule_version_id) REFERENCES rule_versions,
 FOREIGN KEY(workspace_id,device_id,template_version_id) REFERENCES devices(workspace_id,device_id,template_version_id),
 FOREIGN KEY(workspace_id,template_version_id,stream_key) REFERENCES datastream_definitions
);
CREATE TABLE rule_runtime (
 workspace_id uuid NOT NULL, rule_id uuid NOT NULL, active_generation bigint NOT NULL CHECK(active_generation>0),
 cooldown_until timestamptz, error_disabled_reason text, current_rule_version_id uuid,
 PRIMARY KEY(workspace_id,rule_id), FOREIGN KEY(workspace_id,rule_id) REFERENCES rules,
 FOREIGN KEY(workspace_id,rule_id,current_rule_version_id) REFERENCES rule_versions(workspace_id,rule_id,rule_version_id)
);
CREATE TABLE rule_trigger_states (
 workspace_id uuid NOT NULL, rule_version_id uuid NOT NULL, trigger_key text NOT NULL, is_armed boolean NOT NULL,
 hold_started_at timestamptz, last_fresh_at timestamptz, episode_sequence bigint NOT NULL DEFAULT 0 CHECK(episode_sequence>=0),
 last_marker_sequence bigint CHECK(last_marker_sequence>0), PRIMARY KEY(workspace_id,rule_version_id,trigger_key),
 FOREIGN KEY(workspace_id,rule_version_id) REFERENCES rule_versions
);
CREATE TABLE rule_executions (
 workspace_id uuid NOT NULL, rule_execution_id uuid NOT NULL, rule_id uuid NOT NULL, rule_version_id uuid NOT NULL, trigger_key text NOT NULL,
 state text NOT NULL CHECK(state IN ('RUNNING','WAITING','SUCCEEDED','PARTIAL','FAILED','CANCELLED','NEEDS_ATTENTION','NO_MATCH')),
 admitted_at timestamptz NOT NULL, deadline_at timestamptz NOT NULL, ended_at timestamptz,
 next_action_position integer NOT NULL DEFAULT 0 CHECK(next_action_position BETWEEN 0 AND 5), owner_user_id_snapshot uuid NOT NULL, failure_reason text,
 PRIMARY KEY(workspace_id,rule_execution_id), UNIQUE(workspace_id,rule_execution_id,rule_version_id),
 UNIQUE(workspace_id,rule_version_id,trigger_key), FOREIGN KEY(workspace_id,rule_id,rule_version_id) REFERENCES rule_versions(workspace_id,rule_id,rule_version_id),
 FOREIGN KEY(workspace_id,owner_user_id_snapshot) REFERENCES memberships, CHECK(deadline_at=admitted_at+interval '15 minutes')
);
/* Unicité active par rule; quota workspace serialisé par trigger0007. */
CREATE UNIQUE INDEX uq_rule_executions_active_rule ON rule_executions(workspace_id,rule_id) WHERE state IN ('RUNNING','WAITING');
CREATE INDEX ix_rule_executions_history ON rule_executions(workspace_id,rule_id,admitted_at DESC,rule_execution_id);
CREATE TABLE rule_execution_snapshots (
 workspace_id uuid NOT NULL, rule_execution_id uuid NOT NULL, input_snapshot jsonb NOT NULL, condition_trace jsonb NOT NULL, definition_snapshot jsonb,
 PRIMARY KEY(workspace_id,rule_execution_id), FOREIGN KEY(workspace_id,rule_execution_id) REFERENCES rule_executions
);
CREATE TABLE schedule_occurrences (
 workspace_id uuid NOT NULL, rule_version_id uuid NOT NULL, occurrence_key text NOT NULL,
 scheduled_at timestamptz NOT NULL, timezone_snapshot text NOT NULL,
 state text NOT NULL CHECK(state IN ('PENDING','ADMITTED','SKIPPED','CANCELLED')), rule_execution_id uuid,
 PRIMARY KEY(workspace_id,rule_version_id,occurrence_key), FOREIGN KEY(workspace_id,rule_version_id) REFERENCES rule_versions,
 FOREIGN KEY(workspace_id,rule_execution_id,rule_version_id) REFERENCES rule_executions(workspace_id,rule_execution_id,rule_version_id)
);
/* Lịch đến hạn sau scope, không dùng now() trong partial predicate. */
CREATE INDEX ix_schedule_due ON schedule_occurrences(scheduled_at,workspace_id,rule_version_id) WHERE state='PENDING';
CREATE TABLE rule_trigger_receipts (
 workspace_id uuid NOT NULL, rule_version_id uuid NOT NULL, trigger_key text NOT NULL,
 decision text NOT NULL CHECK(decision IN ('ADMITTED','NO_MATCH','SUPPRESSED','REJECTED')), decided_at timestamptz NOT NULL, rule_execution_id uuid,
 PRIMARY KEY(workspace_id,rule_version_id,trigger_key), FOREIGN KEY(workspace_id,rule_version_id) REFERENCES rule_versions,
 FOREIGN KEY(workspace_id,rule_execution_id,rule_version_id) REFERENCES rule_executions(workspace_id,rule_execution_id,rule_version_id)
);
CREATE TABLE execution_actuator_snapshots (
 workspace_id uuid NOT NULL, rule_execution_id uuid NOT NULL, device_id uuid NOT NULL, stream_key text NOT NULL,
 manual_epoch_at_start bigint NOT NULL CHECK(manual_epoch_at_start>=0),
 PRIMARY KEY(workspace_id,rule_execution_id,device_id,stream_key), FOREIGN KEY(workspace_id,rule_execution_id) REFERENCES rule_executions,
 FOREIGN KEY(workspace_id,device_id,stream_key) REFERENCES actuator_states
);
CREATE TABLE action_executions (
 workspace_id uuid NOT NULL, rule_execution_id uuid NOT NULL, action_position integer NOT NULL,
 action_execution_id uuid NOT NULL, rule_version_id uuid NOT NULL,
 state text NOT NULL CHECK(state IN ('BLOCKED','READY','WAITING','DISPATCHING','AWAITING_RESULT','SUCCEEDED','FAILED','CANCELLED','NEEDS_ATTENTION')),
 started_at timestamptz, ended_at timestamptz, command_id uuid, reason_code text,
 PRIMARY KEY(workspace_id,rule_execution_id,action_position), UNIQUE(workspace_id,action_execution_id), UNIQUE(workspace_id,action_execution_id,command_id),
 FOREIGN KEY(workspace_id,rule_execution_id,rule_version_id) REFERENCES rule_executions(workspace_id,rule_execution_id,rule_version_id),
 FOREIGN KEY(workspace_id,rule_version_id,action_position) REFERENCES rule_version_actions
);
CREATE TABLE action_jobs (
 workspace_id uuid NOT NULL, rule_execution_id uuid NOT NULL, action_position integer NOT NULL,
 state text NOT NULL CHECK(state IN ('BLOCKED','READY','WAITING','DISPATCHING','AWAITING_RESULT','SUCCEEDED','FAILED','CANCELLED','NEEDS_ATTENTION')),
 due_at timestamptz NOT NULL, lease_until timestamptz, lease_generation bigint NOT NULL DEFAULT 0 CHECK(lease_generation>=0),
 attempt_count integer NOT NULL DEFAULT 0 CHECK(attempt_count>=0),
 PRIMARY KEY(workspace_id,rule_execution_id,action_position), FOREIGN KEY(workspace_id,rule_execution_id,action_position) REFERENCES action_executions
);
/* Một bước READY/execution; claim theo due_at và lease_generation, không giữ lock qua mạng. */
CREATE UNIQUE INDEX uq_action_jobs_ready ON action_jobs(workspace_id,rule_execution_id) WHERE state='READY';
CREATE INDEX ix_action_jobs_due ON action_jobs(due_at,workspace_id,rule_execution_id) WHERE state IN ('READY','WAITING');
CREATE TABLE commands (
 workspace_id uuid NOT NULL, command_id uuid NOT NULL, device_id uuid NOT NULL, stream_key text NOT NULL,
 origin_type text NOT NULL CHECK(origin_type IN ('MANUAL','AUTOMATION','INTEGRATION')), actor_user_id uuid, api_key_id uuid, action_execution_id uuid,
 value_type text NOT NULL CHECK(value_type IN ('NUMBER','BOOLEAN','ENUM')), numeric_value double precision, boolean_value boolean, text_value text,
 state text NOT NULL DEFAULT 'ADMITTED' CHECK(state IN ('ADMITTED','DISPATCHING','DISPATCHED','ACCEPTED','SUCCEEDED','FAILED','TIMED_OUT','EXPIRED_BEFORE_DISPATCH','CANCELLED')),
 outcome text NOT NULL DEFAULT 'PENDING' CHECK(outcome IN ('PENDING','SUCCEEDED','FAILED','UNKNOWN')),
 admitted_at timestamptz NOT NULL, deadline_at timestamptz NOT NULL, dispatch_intent_at timestamptz, terminal_at timestamptz,
 manual_epoch_snapshot bigint NOT NULL CHECK(manual_epoch_snapshot>=0), revision bigint NOT NULL DEFAULT 1 CHECK(revision>0),
 PRIMARY KEY(workspace_id,command_id), UNIQUE(workspace_id,command_id,device_id), UNIQUE(workspace_id,device_id,stream_key,command_id),
 UNIQUE(workspace_id,command_id,action_execution_id),
 FOREIGN KEY(workspace_id,device_id,stream_key) REFERENCES actuator_states, FOREIGN KEY(workspace_id,actor_user_id) REFERENCES memberships,
 FOREIGN KEY(workspace_id,action_execution_id) REFERENCES action_executions(workspace_id,action_execution_id),
 CHECK(deadline_at=admitted_at+interval '10 seconds'),
 CONSTRAINT ck_command_origin CHECK(
  (origin_type='MANUAL' AND actor_user_id IS NOT NULL AND api_key_id IS NULL AND action_execution_id IS NULL) OR
  (origin_type='AUTOMATION' AND action_execution_id IS NOT NULL AND actor_user_id IS NULL AND api_key_id IS NULL) OR
  (origin_type='INTEGRATION' AND api_key_id IS NOT NULL AND actor_user_id IS NULL AND action_execution_id IS NULL)),
 CONSTRAINT ck_command_value CHECK(num_nonnulls(numeric_value,boolean_value,text_value)=1 AND
  ((value_type='NUMBER' AND numeric_value IS NOT NULL) OR (value_type='BOOLEAN' AND boolean_value IS NOT NULL) OR (value_type='ENUM' AND (numeric_value IS NOT NULL OR text_value IS NOT NULL)))),
 CHECK(numeric_value IS NULL OR (numeric_value>'-Infinity'::float8 AND numeric_value<'Infinity'::float8)),
 CONSTRAINT ck_command_state_outcome CHECK(
  (state IN ('ADMITTED','DISPATCHING','DISPATCHED','ACCEPTED') AND outcome='PENDING' AND terminal_at IS NULL) OR
  (state='SUCCEEDED' AND outcome='SUCCEEDED' AND terminal_at IS NOT NULL) OR
  (state IN ('FAILED','EXPIRED_BEFORE_DISPATCH','CANCELLED') AND outcome='FAILED' AND terminal_at IS NOT NULL) OR
  (state='TIMED_OUT' AND outcome='UNKNOWN' AND terminal_at IS NOT NULL))
);
/* Guard active không đủ cho UNKNOWN; actuator.unresolved_command_id giữ fence sau timeout. */
CREATE UNIQUE INDEX uq_commands_active_actuator ON commands(workspace_id,device_id,stream_key) WHERE state IN ('ADMITTED','DISPATCHING','DISPATCHED','ACCEPTED');
/* Stable action chỉ tạo một command kể cả command đã terminal. */
CREATE UNIQUE INDEX uq_commands_action ON commands(workspace_id,action_execution_id) WHERE action_execution_id IS NOT NULL;
CREATE INDEX ix_commands_history ON commands(workspace_id,device_id,admitted_at DESC,command_id);
ALTER TABLE actuator_states ADD CONSTRAINT fk_actuator_unresolved_command FOREIGN KEY(workspace_id,device_id,stream_key,unresolved_command_id) REFERENCES commands(workspace_id,device_id,stream_key,command_id) DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE action_executions ADD CONSTRAINT fk_action_command FOREIGN KEY(workspace_id,command_id,action_execution_id) REFERENCES commands(workspace_id,command_id,action_execution_id) DEFERRABLE INITIALLY DEFERRED;
CREATE TABLE command_result_receipts (
 workspace_id uuid NOT NULL, command_id uuid NOT NULL, result_phase text NOT NULL CHECK(result_phase IN ('ACCEPTED','SUCCEEDED','FAILED')),
 device_id uuid NOT NULL, boot_id text NOT NULL, credential_generation bigint NOT NULL,
 payload_digest bytea NOT NULL CHECK(octet_length(payload_digest)=32), received_at timestamptz NOT NULL, result_snapshot jsonb NOT NULL,
 PRIMARY KEY(workspace_id,command_id,result_phase), FOREIGN KEY(workspace_id,command_id,device_id) REFERENCES commands(workspace_id,command_id,device_id),
 FOREIGN KEY(workspace_id,device_id,boot_id,credential_generation) REFERENCES device_boot_sessions(workspace_id,device_id,boot_id,credential_generation)
);
CREATE TABLE command_evidence (
 workspace_id uuid NOT NULL, command_evidence_id uuid NOT NULL, command_id uuid NOT NULL,
 evidence_type text NOT NULL CHECK(evidence_type IN ('LATE_RESULT','CONFLICTING_RESULT','DEVICE_OBSERVATION')),
 received_at timestamptz NOT NULL, payload_digest bytea NOT NULL CHECK(octet_length(payload_digest)=32), sanitized_payload jsonb NOT NULL,
 PRIMARY KEY(workspace_id,command_evidence_id), UNIQUE(workspace_id,command_id,command_evidence_id), FOREIGN KEY(workspace_id,command_id) REFERENCES commands
);
/* Timeline bằng chứng theo tenant/command và thời điểm quan sát. */
CREATE INDEX ix_command_evidence_timeline ON command_evidence(workspace_id,command_id,received_at,command_evidence_id);
CREATE TABLE command_resolutions (
 workspace_id uuid NOT NULL, command_id uuid NOT NULL,
 resolution_status text NOT NULL CHECK(resolution_status IN ('UNRESOLVED','ACKNOWLEDGED_UNKNOWN','DEVICE_CONFIRMED_LATE')),
 resolved_by_user_id uuid, resolved_at timestamptz, manual_observation jsonb, device_evidence_id uuid, reason_code text,
 PRIMARY KEY(workspace_id,command_id), FOREIGN KEY(workspace_id,command_id) REFERENCES commands,
 FOREIGN KEY(workspace_id,resolved_by_user_id) REFERENCES memberships,
 FOREIGN KEY(workspace_id,command_id,device_evidence_id) REFERENCES command_evidence(workspace_id,command_id,command_evidence_id)
);

INSERT INTO migration_control.applied_migrations(version,checksum)
    VALUES(:'migration_version',:'migration_checksum');
\echo APPLIED
\else
SELECT checksum=:'migration_checksum' AS checksum_matches
    FROM migration_control.applied_migrations WHERE version=:'migration_version' \gset
\if :checksum_matches
\echo ALREADY_APPLIED
\else
/* Drift phải rollback, không UPDATE checksum để hợp thức hóa lịch sử bị thay đổi. */
DO $$ BEGIN RAISE EXCEPTION 'migration checksum drift'; END $$;
\endif
\endif
COMMIT;

\set migration_version platform-0004-events
\set migration_checksum 5f3882ec086b8723d4f85c486fb68d7d09b63482469d1912db4eac4392635575

/* Template psql của runner; hai marker chỉ được thay bằng file SQL nguồn trong repo.
 * migration_version/checksum là literal qua :'name', không chèn input vào SQL.
 * DDL và ledger commit cùng nhau; advisory lock dùng chung cho mọi version/runner.
 */
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
SELECT pg_advisory_xact_lock(17001,1);
/* Lịch sử runner lab: lưu checksum và thời điểm áp thật, không chứa credential.
 * Phải chạy trong transaction đã lấy advisory lock; không thay SQLx production history.
 */
CREATE SCHEMA IF NOT EXISTS migration_control;
CREATE TABLE IF NOT EXISTS migration_control.applied_migrations (
    version text PRIMARY KEY,
    checksum text NOT NULL CHECK(checksum ~ '^[0-9a-f]{64}$'),
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

SELECT NOT EXISTS(
    SELECT 1 FROM migration_control.applied_migrations WHERE version=:'migration_version'
) AS should_apply \gset
\if :should_apply
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

INSERT INTO migration_control.applied_migrations(version,checksum)
    VALUES(:'migration_version',:'migration_checksum');
\echo APPLIED
\else
SELECT checksum=:'migration_checksum' AS checksum_matches
    FROM migration_control.applied_migrations WHERE version=:'migration_version' \gset
\if :checksum_matches
\echo ALREADY_APPLIED
\else
/* Drift phải rollback, không UPDATE checksum để hợp thức hóa lịch sử bị thay đổi. */
DO $$ BEGIN RAISE EXCEPTION 'migration checksum drift'; END $$;
\endif
\endif
COMMIT;

\set migration_version platform-0005-mobile
\set migration_checksum 67f8542935246e78a87a83893b897eb46e43b58e6dc957a765d4d83e629c31ec

/* Template psql của runner; hai marker chỉ được thay bằng file SQL nguồn trong repo.
 * migration_version/checksum là literal qua :'name', không chèn input vào SQL.
 * DDL và ledger commit cùng nhau; advisory lock dùng chung cho mọi version/runner.
 */
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
SELECT pg_advisory_xact_lock(17001,1);
/* Lịch sử runner lab: lưu checksum và thời điểm áp thật, không chứa credential.
 * Phải chạy trong transaction đã lấy advisory lock; không thay SQLx production history.
 */
CREATE SCHEMA IF NOT EXISTS migration_control;
CREATE TABLE IF NOT EXISTS migration_control.applied_migrations (
    version text PRIMARY KEY,
    checksum text NOT NULL CHECK(checksum ~ '^[0-9a-f]{64}$'),
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

SELECT NOT EXISTS(
    SELECT 1 FROM migration_control.applied_migrations WHERE version=:'migration_version'
) AS should_apply \gset
\if :should_apply
/* Push và enrollment cùng tenant database; không phụ thuộc push permission để onboarding.
 * Ciphertext chỉ là interface lưu trữ; key custody ngoài DB cần nghiệm thu trước dùng thật.
 */
CREATE TABLE push_installations (
 installation_id uuid PRIMARY KEY, installation_proof_digest bytea NOT NULL CHECK(octet_length(installation_proof_digest)=32),
 platform text NOT NULL CHECK(platform='ANDROID'), token_ciphertext bytea, token_digest bytea CHECK(octet_length(token_digest)=32), encryption_key_reference text,
 token_generation bigint NOT NULL DEFAULT 0 CHECK(token_generation>=0), binding_generation bigint NOT NULL DEFAULT 0 CHECK(binding_generation>=0),
 client_sequence bigint NOT NULL DEFAULT 0 CHECK(client_sequence>=0), permission_state text NOT NULL CHECK(permission_state IN ('UNKNOWN','GRANTED','DENIED','NOT_DETERMINED')),
 enabled boolean NOT NULL DEFAULT false, app_version text, active_user_id uuid, active_session_id uuid,
 updated_at timestamptz NOT NULL DEFAULT transaction_timestamp(), FOREIGN KEY(active_user_id,active_session_id) REFERENCES sessions(user_id,session_id),
 CHECK((active_user_id IS NULL)=(active_session_id IS NULL)),
 CHECK(num_nonnulls(token_ciphertext,token_digest,encryption_key_reference) IN (0,3))
);
/* Một provider token hiện hành cho một installation; raw token không là khóa/index. */
CREATE UNIQUE INDEX uq_push_installations_token ON push_installations(token_digest) WHERE token_digest IS NOT NULL;
CREATE TABLE workspace_notification_preferences (
 workspace_id uuid NOT NULL, user_id uuid NOT NULL, enabled boolean NOT NULL,
 minimum_severity text NOT NULL CHECK(minimum_severity IN ('INFO','WARNING','CRITICAL')),
 revision bigint NOT NULL DEFAULT 1 CHECK(revision>0), updated_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
 PRIMARY KEY(workspace_id,user_id), FOREIGN KEY(workspace_id,user_id) REFERENCES memberships
);
CREATE TABLE push_deliveries (
 workspace_id uuid NOT NULL, push_delivery_id uuid NOT NULL, notification_id uuid NOT NULL, installation_id uuid NOT NULL REFERENCES push_installations,
 recipient_user_id uuid NOT NULL, binding_generation bigint NOT NULL CHECK(binding_generation>0),
 state text NOT NULL DEFAULT 'PENDING' CHECK(state IN ('PENDING','SENDING','RETRY_WAIT','ACCEPTED','FAILED','EXPIRED','SUPPRESSED')),
 created_at timestamptz NOT NULL, expires_at timestamptz NOT NULL, terminal_at timestamptz, next_attempt_at timestamptz,
 lease_until timestamptz, lease_generation bigint NOT NULL DEFAULT 0 CHECK(lease_generation>=0),
 PRIMARY KEY(workspace_id,push_delivery_id), UNIQUE(workspace_id,notification_id,installation_id),
 FOREIGN KEY(workspace_id,notification_id,recipient_user_id) REFERENCES notifications(workspace_id,notification_id,recipient_user_id),
 CHECK(expires_at=created_at+interval '1 hour')
);
/* Retry theo thời gian, tenant giữ trong khóa để truy vết và claim không nhầm scope. */
CREATE INDEX ix_push_deliveries_due ON push_deliveries(next_attempt_at,workspace_id,push_delivery_id) WHERE state IN ('PENDING','RETRY_WAIT');
CREATE TABLE push_delivery_attempts (
 workspace_id uuid NOT NULL, push_delivery_id uuid NOT NULL, attempt_number integer NOT NULL CHECK(attempt_number BETWEEN 1 AND 4),
 intent_at timestamptz NOT NULL, token_generation bigint NOT NULL CHECK(token_generation>0), provider_request_id text,
 outcome text NOT NULL CHECK(outcome IN ('INTENT','ACCEPTED','TRANSIENT_FAILURE','PERMANENT_FAILURE','UNKNOWN')),
 observed_at timestamptz, next_delay_seconds integer CHECK(next_delay_seconds>=0),
 PRIMARY KEY(workspace_id,push_delivery_id,attempt_number), FOREIGN KEY(workspace_id,push_delivery_id) REFERENCES push_deliveries
);
CREATE TABLE enrollment_sessions (
 workspace_id uuid NOT NULL, enrollment_session_id uuid NOT NULL, device_id uuid NOT NULL, actor_user_id uuid NOT NULL,
 actor_grant_generation bigint NOT NULL, client_installation_id uuid NOT NULL,
 enrollment_proof_digest bytea NOT NULL CHECK(octet_length(enrollment_proof_digest)=32),
 mode text NOT NULL CHECK(mode IN ('INITIAL','WIFI_RECONFIGURE')),
 state text NOT NULL DEFAULT 'CREATED' CHECK(state IN ('CREATED','BLE_CONNECTED','WIFI_JOINED','CLOUD_CONNECTING','COMPLETED','FAILED','CANCELLED','EXPIRED')),
 started_at timestamptz NOT NULL, expires_at timestamptz NOT NULL, provisioning_operation_id uuid, completed_at timestamptz,
 revision bigint NOT NULL DEFAULT 1 CHECK(revision>0),
 PRIMARY KEY(workspace_id,enrollment_session_id), UNIQUE(workspace_id,enrollment_session_id,device_id),
 FOREIGN KEY(workspace_id,device_id) REFERENCES devices(workspace_id,device_id),
 FOREIGN KEY(workspace_id,actor_user_id,actor_grant_generation) REFERENCES membership_grants,
 FOREIGN KEY(workspace_id,provisioning_operation_id,device_id) REFERENCES provisioning_operations(workspace_id,provisioning_operation_id,device_id),
 CHECK(expires_at=started_at+interval '10 minutes'), CHECK((state='COMPLETED')=(completed_at IS NOT NULL)),
 CHECK(mode<>'WIFI_RECONFIGURE' OR provisioning_operation_id IS NULL)
);
CREATE TABLE enrollment_cleanup_operations (
 workspace_id uuid NOT NULL, enrollment_cleanup_operation_id uuid NOT NULL, enrollment_session_id uuid NOT NULL, device_id uuid NOT NULL,
 state text NOT NULL CHECK(state IN ('PENDING','RUNNING','SUCCEEDED','FAILED','NEEDS_ATTENTION')),
 intent_at timestamptz NOT NULL, broker_revoke_receipt jsonb, disconnect_receipt jsonb, settled_at timestamptz,
 PRIMARY KEY(workspace_id,enrollment_cleanup_operation_id), UNIQUE(workspace_id,enrollment_session_id),
 FOREIGN KEY(workspace_id,enrollment_session_id,device_id) REFERENCES enrollment_sessions(workspace_id,enrollment_session_id,device_id)
);
/* Guard khác TTL: expiry không chứng minh broker đã revoke/disconnect. */
CREATE TABLE device_enrollment_guards (
 workspace_id uuid NOT NULL, device_id uuid NOT NULL, enrollment_session_id uuid NOT NULL, acquired_at timestamptz NOT NULL,
 PRIMARY KEY(workspace_id,device_id), FOREIGN KEY(workspace_id,device_id) REFERENCES devices(workspace_id,device_id),
 FOREIGN KEY(workspace_id,enrollment_session_id,device_id) REFERENCES enrollment_sessions(workspace_id,enrollment_session_id,device_id)
);

INSERT INTO migration_control.applied_migrations(version,checksum)
    VALUES(:'migration_version',:'migration_checksum');
\echo APPLIED
\else
SELECT checksum=:'migration_checksum' AS checksum_matches
    FROM migration_control.applied_migrations WHERE version=:'migration_version' \gset
\if :checksum_matches
\echo ALREADY_APPLIED
\else
/* Drift phải rollback, không UPDATE checksum để hợp thức hóa lịch sử bị thay đổi. */
DO $$ BEGIN RAISE EXCEPTION 'migration checksum drift'; END $$;
\endif
\endif
COMMIT;

\set migration_version platform-0006-integrations
\set migration_checksum ca28b152e93cc00b90448fadd63a207ba2b4d3063d8821a348768f2d6279b0f8

/* Template psql của runner; hai marker chỉ được thay bằng file SQL nguồn trong repo.
 * migration_version/checksum là literal qua :'name', không chèn input vào SQL.
 * DDL và ledger commit cùng nhau; advisory lock dùng chung cho mọi version/runner.
 */
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
SELECT pg_advisory_xact_lock(17001,1);
/* Lịch sử runner lab: lưu checksum và thời điểm áp thật, không chứa credential.
 * Phải chạy trong transaction đã lấy advisory lock; không thay SQLx production history.
 */
CREATE SCHEMA IF NOT EXISTS migration_control;
CREATE TABLE IF NOT EXISTS migration_control.applied_migrations (
    version text PRIMARY KEY,
    checksum text NOT NULL CHECK(checksum ~ '^[0-9a-f]{64}$'),
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

SELECT NOT EXISTS(
    SELECT 1 FROM migration_control.applied_migrations WHERE version=:'migration_version'
) AS should_apply \gset
\if :should_apply
/* OTA và integration đóng các typed FK API key còn chờ0003/0004.
 * Không verify chữ ký, gửi HTTP hoặc flash phần cứng trong migration; raw bytes giữ authority.
 */
CREATE TABLE firmware_upload_attempts (
 workspace_id uuid NOT NULL, firmware_upload_attempt_id uuid NOT NULL, actor_user_id uuid NOT NULL,
 artifact_digest bytea CHECK(octet_length(artifact_digest)=32), temporary_artifact_reference text,
 state text NOT NULL CHECK(state IN ('UPLOADED','VERIFIED','REJECTED')), failure_reason text,
 created_at timestamptz NOT NULL, expires_at timestamptz NOT NULL,
 PRIMARY KEY(workspace_id,firmware_upload_attempt_id), FOREIGN KEY(workspace_id,actor_user_id) REFERENCES memberships,
 CHECK(expires_at=created_at+interval '24 hours')
);
/* Chỉ package đã qua validator đi vào canonical identity; bad upload không chiếm digest. */
CREATE TABLE firmware_packages (
 workspace_id uuid NOT NULL REFERENCES workspaces, firmware_package_id uuid NOT NULL,
 artifact_digest bytea NOT NULL CHECK(octet_length(artifact_digest)=32), raw_manifest bytea NOT NULL CHECK(octet_length(raw_manifest)>0),
 signature bytea NOT NULL CHECK(octet_length(signature)>0), artifact_reference text NOT NULL CHECK(btrim(artifact_reference)<>''),
 artifact_size_bytes bigint NOT NULL CHECK(artifact_size_bytes>0), signing_key_fingerprint bytea NOT NULL CHECK(octet_length(signing_key_fingerprint)=32),
 signing_key_identifier text NOT NULL, manifest_schema_version integer NOT NULL CHECK(manifest_schema_version=1),
 board_model text NOT NULL, hardware_revision text NOT NULL, firmware_version text NOT NULL, build_identifier text NOT NULL,
 validation_state text NOT NULL CHECK(validation_state='VERIFIED'), created_at timestamptz NOT NULL,
 PRIMARY KEY(workspace_id,firmware_package_id), UNIQUE(workspace_id,artifact_digest)
);
CREATE TABLE firmware_package_templates (
 workspace_id uuid NOT NULL, firmware_package_id uuid NOT NULL, template_version_id uuid NOT NULL,
 PRIMARY KEY(workspace_id,firmware_package_id,template_version_id),
 FOREIGN KEY(workspace_id,firmware_package_id) REFERENCES firmware_packages, FOREIGN KEY(workspace_id,template_version_id) REFERENCES template_versions
);
CREATE TABLE ota_jobs (
 workspace_id uuid NOT NULL, ota_job_id uuid NOT NULL, device_id uuid NOT NULL, firmware_package_id uuid NOT NULL,
 source_firmware_version_snapshot text NOT NULL, target_artifact_digest_snapshot bytea NOT NULL CHECK(octet_length(target_artifact_digest_snapshot)=32),
 job_nonce bytea NOT NULL CHECK(octet_length(job_nonce)=32),
 state text NOT NULL CHECK(state IN ('QUEUED','DISPATCHING','ACCEPTED','DOWNLOADING','VERIFYING','REBOOTING','HEALTH_CHECK','SUCCEEDED','FAILED','CANCELLED','ROLLED_BACK','RECOVERY_REQUIRED')),
 phase text NOT NULL, maintenance_epoch bigint NOT NULL CHECK(maintenance_epoch>0),
 admitted_at timestamptz NOT NULL, deadline_at timestamptz NOT NULL, start_intent_at timestamptz, settled_at timestamptz, recovery_reason text,
 recovery_boot_id text, reconciled_at timestamptz, revision bigint NOT NULL DEFAULT 1 CHECK(revision>0),
 PRIMARY KEY(workspace_id,ota_job_id), UNIQUE(workspace_id,ota_job_id,device_id),
 FOREIGN KEY(workspace_id,device_id) REFERENCES devices(workspace_id,device_id), FOREIGN KEY(workspace_id,firmware_package_id) REFERENCES firmware_packages,
 CHECK(deadline_at=admitted_at+interval '10 minutes'), CHECK(state<>'RECOVERY_REQUIRED' OR settled_at IS NULL)
);
/* Chỉ settlement có proof giải phóng quota; timeout/recovery vẫn giữ cả workspace/device. */
CREATE UNIQUE INDEX uq_ota_jobs_active_workspace ON ota_jobs(workspace_id) WHERE settled_at IS NULL;
CREATE UNIQUE INDEX uq_ota_jobs_active_device ON ota_jobs(workspace_id,device_id) WHERE settled_at IS NULL;
CREATE TABLE ota_download_tickets (
 ticket_id uuid PRIMARY KEY, ticket_digest bytea NOT NULL UNIQUE CHECK(octet_length(ticket_digest)=32),
 workspace_id uuid NOT NULL, ota_job_id uuid NOT NULL, issued_at timestamptz NOT NULL, expires_at timestamptz NOT NULL, revoked_at timestamptz,
 FOREIGN KEY(workspace_id,ota_job_id) REFERENCES ota_jobs, CHECK(expires_at>issued_at)
);
CREATE TABLE ota_status_receipts (
 workspace_id uuid NOT NULL, ota_job_id uuid NOT NULL, status_sequence bigint NOT NULL CHECK(status_sequence BETWEEN 0 AND 4294967295),
 device_id uuid NOT NULL, payload_digest bytea NOT NULL CHECK(octet_length(payload_digest)=32), boot_id text NOT NULL,
 credential_generation bigint NOT NULL, phase text NOT NULL, received_at timestamptz NOT NULL, sanitized_payload jsonb NOT NULL,
 PRIMARY KEY(workspace_id,ota_job_id,status_sequence), FOREIGN KEY(workspace_id,ota_job_id,device_id) REFERENCES ota_jobs(workspace_id,ota_job_id,device_id),
 FOREIGN KEY(workspace_id,device_id,boot_id,credential_generation) REFERENCES device_boot_sessions(workspace_id,device_id,boot_id,credential_generation)
);
CREATE TABLE ota_probe_intents (
 workspace_id uuid NOT NULL, ota_job_id uuid NOT NULL, recovery_epoch bigint NOT NULL CHECK(recovery_epoch>0),
 probe_number integer NOT NULL CHECK(probe_number BETWEEN 1 AND 3), request_id uuid NOT NULL UNIQUE,
 intended_at timestamptz NOT NULL, sent_at timestamptz, reply_at timestamptz, reply_digest bytea CHECK(octet_length(reply_digest)=32),
 state text NOT NULL CHECK(state IN ('INTENT','SENT','REPLIED','UNKNOWN')),
 PRIMARY KEY(workspace_id,ota_job_id,recovery_epoch,probe_number), FOREIGN KEY(workspace_id,ota_job_id) REFERENCES ota_jobs
);
/* API credential chỉ có keyId.secret nên keyId phải unique toàn cục trước resolve tenant. */
CREATE TABLE api_keys (
 api_key_id uuid PRIMARY KEY, workspace_id uuid NOT NULL, owner_user_id uuid NOT NULL, owner_grant_generation bigint NOT NULL,
 verifier_digest bytea NOT NULL UNIQUE CHECK(octet_length(verifier_digest)=32), name text NOT NULL, prefix text NOT NULL,
 issued_at timestamptz NOT NULL, expires_at timestamptz NOT NULL, revoked_at timestamptz, last_used_at timestamptz,
 revision bigint NOT NULL DEFAULT 1 CHECK(revision>0), UNIQUE(workspace_id,api_key_id),
 FOREIGN KEY(workspace_id,owner_user_id,owner_grant_generation) REFERENCES membership_grants,
 CHECK(expires_at>=issued_at+interval '1 day' AND expires_at<=issued_at+interval '90 days')
);
CREATE TABLE api_key_devices (
 workspace_id uuid NOT NULL, api_key_id uuid NOT NULL, device_id uuid NOT NULL,
 PRIMARY KEY(workspace_id,api_key_id,device_id), FOREIGN KEY(workspace_id,api_key_id) REFERENCES api_keys(workspace_id,api_key_id),
 FOREIGN KEY(workspace_id,device_id) REFERENCES devices(workspace_id,device_id)
);
CREATE TABLE api_key_scopes (
 workspace_id uuid NOT NULL, api_key_id uuid NOT NULL, scope_code text NOT NULL CHECK(scope_code IN ('devices:read','telemetry:read','commands:write')),
 PRIMARY KEY(workspace_id,api_key_id,scope_code), FOREIGN KEY(workspace_id,api_key_id) REFERENCES api_keys(workspace_id,api_key_id)
);
ALTER TABLE commands ADD CONSTRAINT fk_commands_api_key FOREIGN KEY(workspace_id,api_key_id) REFERENCES api_keys(workspace_id,api_key_id);
ALTER TABLE workspace_idempotency_records ADD CONSTRAINT fk_idempotency_api_key FOREIGN KEY(workspace_id,api_key_id) REFERENCES api_keys(workspace_id,api_key_id);
ALTER TABLE rate_limit_admissions ADD CONSTRAINT fk_rate_limit_api_key FOREIGN KEY(workspace_id,api_key_id) REFERENCES api_keys(workspace_id,api_key_id);
CREATE TABLE webhook_subscriptions (
 workspace_id uuid NOT NULL, webhook_subscription_id uuid NOT NULL, owner_user_id uuid NOT NULL,
 endpoint_url text NOT NULL CHECK(endpoint_url LIKE 'https://%'), endpoint_revision bigint NOT NULL DEFAULT 1 CHECK(endpoint_revision>0),
 verified_endpoint_revision bigint, verified_at timestamptz,
 revision bigint NOT NULL DEFAULT 1 CHECK(revision>0), lifecycle_status text NOT NULL CHECK(lifecycle_status IN ('ACTIVE','PAUSED','REVOKED')),
 active_secret_version bigint NOT NULL CHECK(active_secret_version>0), created_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
 updated_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
 PRIMARY KEY(workspace_id,webhook_subscription_id), FOREIGN KEY(workspace_id,owner_user_id) REFERENCES memberships,
 CHECK((verified_endpoint_revision IS NULL)=(verified_at IS NULL)),
 CHECK(verified_endpoint_revision IS NULL OR verified_endpoint_revision=endpoint_revision),
 CHECK(lifecycle_status<>'ACTIVE' OR verified_endpoint_revision IS NOT NULL)
);
CREATE TABLE webhook_subscription_devices (
 workspace_id uuid NOT NULL, webhook_subscription_id uuid NOT NULL, device_id uuid NOT NULL,
 PRIMARY KEY(workspace_id,webhook_subscription_id,device_id), FOREIGN KEY(workspace_id,webhook_subscription_id) REFERENCES webhook_subscriptions,
 FOREIGN KEY(workspace_id,device_id) REFERENCES devices(workspace_id,device_id)
);
CREATE TABLE webhook_subscription_events (
 workspace_id uuid NOT NULL, webhook_subscription_id uuid NOT NULL,
 event_type text NOT NULL CHECK(event_type IN ('event.opened','event.resolved','command.completed','device.connectivity')),
 PRIMARY KEY(workspace_id,webhook_subscription_id,event_type), FOREIGN KEY(workspace_id,webhook_subscription_id) REFERENCES webhook_subscriptions
);
/* Có thể purge ciphertext sau nghĩa vụ gửi, giữ metadata version để FK lịch sử không đứt. */
CREATE TABLE webhook_secret_versions (
 workspace_id uuid NOT NULL, webhook_subscription_id uuid NOT NULL, secret_version bigint NOT NULL CHECK(secret_version>0),
 secret_ciphertext bytea, encryption_key_reference text, created_at timestamptz NOT NULL, retired_at timestamptz,
 PRIMARY KEY(workspace_id,webhook_subscription_id,secret_version), FOREIGN KEY(workspace_id,webhook_subscription_id) REFERENCES webhook_subscriptions,
 CHECK((secret_ciphertext IS NULL)=(encryption_key_reference IS NULL))
);
ALTER TABLE webhook_subscriptions ADD CONSTRAINT fk_webhook_active_secret FOREIGN KEY(workspace_id,webhook_subscription_id,active_secret_version) REFERENCES webhook_secret_versions DEFERRABLE INITIALLY DEFERRED;
CREATE TABLE webhook_deliveries (
 workspace_id uuid NOT NULL, webhook_delivery_id uuid NOT NULL, webhook_subscription_id uuid NOT NULL,
 kind text NOT NULL CHECK(kind IN ('BUSINESS','TEST')), occurrence_id uuid, endpoint_url_snapshot text NOT NULL,
 endpoint_revision_snapshot bigint NOT NULL CHECK(endpoint_revision_snapshot>0), secret_version bigint NOT NULL,
 raw_body bytea NOT NULL, body_digest bytea NOT NULL CHECK(octet_length(body_digest)=32),
 state text NOT NULL DEFAULT 'PENDING' CHECK(state IN ('PENDING','SENDING','RETRY_WAIT','ACCEPTED','FAILED','DEAD_LETTER','CANCELLED')),
 admitted_at timestamptz NOT NULL, expires_at timestamptz NOT NULL, terminal_at timestamptz,
 manual_batch_count integer NOT NULL DEFAULT 0 CHECK(manual_batch_count BETWEEN 0 AND 1), next_attempt_at timestamptz,
 lease_until timestamptz, lease_generation bigint NOT NULL DEFAULT 0 CHECK(lease_generation>=0),
 PRIMARY KEY(workspace_id,webhook_delivery_id), FOREIGN KEY(workspace_id,webhook_subscription_id) REFERENCES webhook_subscriptions,
 FOREIGN KEY(workspace_id,occurrence_id) REFERENCES event_occurrences,
 FOREIGN KEY(workspace_id,webhook_subscription_id,secret_version) REFERENCES webhook_secret_versions,
 CHECK((kind='BUSINESS' AND occurrence_id IS NOT NULL) OR (kind='TEST' AND occurrence_id IS NULL AND manual_batch_count=0)),
 CHECK(expires_at>admitted_at), CHECK(kind<>'TEST' OR expires_at=admitted_at+interval '30 seconds')
);
/* Transition occurrence và subscription là dedupe; secret rotate không tạo delivery mới. */
CREATE UNIQUE INDEX uq_webhook_delivery_occurrence ON webhook_deliveries(workspace_id,webhook_subscription_id,occurrence_id) WHERE kind='BUSINESS';
CREATE INDEX ix_webhook_deliveries_due ON webhook_deliveries(next_attempt_at,workspace_id,webhook_delivery_id) WHERE state IN ('PENDING','RETRY_WAIT');
CREATE TABLE webhook_delivery_attempts (
 workspace_id uuid NOT NULL, webhook_delivery_id uuid NOT NULL, attempt_number integer NOT NULL CHECK(attempt_number BETWEEN 1 AND 12),
 batch_number integer NOT NULL CHECK(batch_number BETWEEN 0 AND 1), intent_at timestamptz NOT NULL,
 request_digest bytea NOT NULL CHECK(octet_length(request_digest)=32), response_status integer CHECK(response_status BETWEEN 100 AND 599),
 outcome text NOT NULL CHECK(outcome IN ('INTENT','ACCEPTED','TRANSIENT_FAILURE','PERMANENT_FAILURE','UNKNOWN')),
 observed_at timestamptz, next_attempt_at timestamptz,
 PRIMARY KEY(workspace_id,webhook_delivery_id,attempt_number), FOREIGN KEY(workspace_id,webhook_delivery_id) REFERENCES webhook_deliveries,
 CHECK(batch_number=(attempt_number-1)/6)
);

INSERT INTO migration_control.applied_migrations(version,checksum)
    VALUES(:'migration_version',:'migration_checksum');
\echo APPLIED
\else
SELECT checksum=:'migration_checksum' AS checksum_matches
    FROM migration_control.applied_migrations WHERE version=:'migration_version' \gset
\if :checksum_matches
\echo ALREADY_APPLIED
\else
/* Drift phải rollback, không UPDATE checksum để hợp thức hóa lịch sử bị thay đổi. */
DO $$ BEGIN RAISE EXCEPTION 'migration checksum drift'; END $$;
\endif
\endif
COMMIT;

\set migration_version platform-0007-guards
\set migration_checksum 17ee3e4d783e5860e8b12b581da7999c33998b6c545ca2d3beee3a4ab2523351

/* Template psql của runner; hai marker chỉ được thay bằng file SQL nguồn trong repo.
 * migration_version/checksum là literal qua :'name', không chèn input vào SQL.
 * DDL và ledger commit cùng nhau; advisory lock dùng chung cho mọi version/runner.
 */
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
SELECT pg_advisory_xact_lock(17001,1);
/* Lịch sử runner lab: lưu checksum và thời điểm áp thật, không chứa credential.
 * Phải chạy trong transaction đã lấy advisory lock; không thay SQLx production history.
 */
CREATE SCHEMA IF NOT EXISTS migration_control;
CREATE TABLE IF NOT EXISTS migration_control.applied_migrations (
    version text PRIMARY KEY,
    checksum text NOT NULL CHECK(checksum ~ '^[0-9a-f]{64}$'),
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

SELECT NOT EXISTS(
    SELECT 1 FROM migration_control.applied_migrations WHERE version=:'migration_version'
) AS should_apply \gset
\if :should_apply
/* Cưỡng chế invariant liên hàng sau khi toàn bộ graph FK đã tồn tại.
 * Migration dùng transaction; engine mới/trống, không sửa checksum0001..0006.
 * Runtime chưa được cấp writer; service vẫn phải authorize hiện hành trước replay/dispatch.
 */
/* Đồng bộ enum lifecycle theo handoff BR005; connectivity khác lifecycle. */
ALTER TABLE devices DROP CONSTRAINT devices_lifecycle_status_check;
ALTER TABLE devices ALTER COLUMN lifecycle_status SET DEFAULT 'REGISTERED';
ALTER TABLE devices ADD CONSTRAINT ck_device_lifecycle CHECK(lifecycle_status IN ('REGISTERED','ACTIVE','SUSPENDED','ARCHIVED'));
ALTER TABLE device_runtime DROP CONSTRAINT device_runtime_presence_state_check;
ALTER TABLE device_runtime ALTER COLUMN presence_state SET DEFAULT 'UNKNOWN';
ALTER TABLE device_runtime ADD CONSTRAINT ck_device_presence CHECK(presence_state IN ('UNKNOWN','ONLINE','OFFLINE'));
ALTER TABLE device_credentials DROP CONSTRAINT device_credentials_credential_state_check;
ALTER TABLE device_credentials ADD CONSTRAINT ck_device_credential_state CHECK(credential_state IN ('PROVISIONING','ACTIVE','REVOCATION_PENDING','REVOKED'));
ALTER TABLE provisioning_operations DROP CONSTRAINT provisioning_operations_state_check;
ALTER TABLE provisioning_operations ADD CONSTRAINT ck_provisioning_state CHECK(state IN ('PENDING','READY','FAILED'));
ALTER TABLE provisioning_operations ADD COLUMN delivery_status text NOT NULL DEFAULT 'PENDING'
 CHECK(delivery_status IN ('PENDING','AVAILABLE','CLAIMED','EXPIRED','UNAVAILABLE'));
ALTER TABLE provisioning_operations ADD CONSTRAINT ck_provisioning_escrow_expiry CHECK(expires_at=intent_at+interval '10 minutes');
ALTER TABLE workspaces ADD CONSTRAINT ck_workspace_description CHECK(description IS NULL OR length(description)<=500);
ALTER TABLE devices ADD CONSTRAINT ck_device_serial CHECK(serial_number ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$');
/* Fence generation hiện hành phải tiến được dù invitation cũ còn giữ snapshot.
 * FK giữ identity fence; consume phải so snapshot generation, không FK vào mutable current value.
 */
DO $$ DECLARE constraint_name text; BEGIN
 SELECT conname INTO STRICT constraint_name FROM pg_constraint
 WHERE conrelid='public.workspace_invitations'::regclass AND confrelid='public.membership_admission_fences'::regclass;
 EXECUTE format('ALTER TABLE public.workspace_invitations DROP CONSTRAINT %I',constraint_name);
END $$;
ALTER TABLE workspace_invitations ADD CONSTRAINT fk_invitation_admission_identity
 FOREIGN KEY(workspace_id,email_digest) REFERENCES membership_admission_fences;

/* Giữ identity/admission của phiên; chỉ revocation NULL→timestamp được phép.
 * Input: OLD/NEW của phiên. Output: NEW hoặc23514; không nâng phiên limited tại chỗ.
 */
CREATE FUNCTION enforce_session_immutability() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 IF (to_jsonb(NEW)-'revoked_at') IS DISTINCT FROM (to_jsonb(OLD)-'revoked_at') THEN
  RAISE EXCEPTION 'Session identity is immutable' USING ERRCODE='23514',CONSTRAINT='ck_sessions_identity_immutable';
 END IF;
 IF OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at THEN
  RAISE EXCEPTION 'Session cannot be unrevoked' USING ERRCODE='23514',CONSTRAINT='ck_sessions_revocation_monotonic';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_sessions_immutable BEFORE UPDATE ON sessions FOR EACH ROW EXECUTE FUNCTION enforce_session_immutability();

/* Kiểm trạng thái cuối cùng của tenant, kể cả User đã disabled hoặc cần đổi mật khẩu.
 * Input: target_workspace_id là tenant cần giữ Admin. Output:void; Errors:23514 LAST_ADMIN.
 */
CREATE FUNCTION assert_workspace_capable_admin(target_workspace_id uuid) RETURNS void LANGUAGE plpgsql VOLATILE
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 IF EXISTS(SELECT 1 FROM public.workspaces WHERE workspace_id=target_workspace_id) AND NOT EXISTS(
  SELECT 1 FROM public.memberships membership JOIN public.users account USING(user_id)
  WHERE membership.workspace_id=target_workspace_id AND membership.role='ADMIN' AND membership.status='ACTIVE'
  AND account.account_status='ACTIVE' AND NOT account.must_change_password) THEN
  RAISE EXCEPTION 'Workspace requires a capable administrator' USING ERRCODE='23514',CONSTRAINT='ck_workspaces_capable_admin';
 END IF;
END $$;

/* Write fence User→Workspace làm RR phát hiện snapshot cũ, tránh write skew last Admin.
 * Input: membership OLD/NEW. Output: hàng phù hợp; Side effects: MVCC fence trên parent.
 * Batch caller pre-lock các ID tăng dần và retry40001/40P01 trước side effect ngoài DB.
 */
CREATE FUNCTION fence_membership_administrators() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE selected_user uuid; selected_workspace uuid; BEGIN
 IF TG_OP='UPDATE' AND ROW(NEW.workspace_id,NEW.user_id) IS DISTINCT FROM ROW(OLD.workspace_id,OLD.user_id) THEN
  RAISE EXCEPTION 'Membership identity is immutable' USING ERRCODE='23514';
 END IF;
 selected_user:=CASE WHEN TG_OP='DELETE' THEN OLD.user_id ELSE NEW.user_id END;
 selected_workspace:=CASE WHEN TG_OP='DELETE' THEN OLD.workspace_id ELSE NEW.workspace_id END;
 UPDATE public.users SET account_status=account_status WHERE user_id=selected_user;
 UPDATE public.workspaces SET authorization_version=authorization_version WHERE workspace_id=selected_workspace;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_membership_fence BEFORE INSERT OR UPDATE OR DELETE ON memberships FOR EACH ROW EXECUTE FUNCTION fence_membership_administrators();

/* Account state có thể làm mất Admin ở nhiều tenant; fence theo thứ tự ID ổn định.
 * Input: OLD/NEW User. Output:NEW; Side effects: parent fence, revoke phiên khi credential đổi.
 */
CREATE FUNCTION fence_user_workspaces() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE selected_workspace uuid; BEGIN
 IF ROW(NEW.account_status,NEW.must_change_password) IS DISTINCT FROM ROW(OLD.account_status,OLD.must_change_password) THEN
  FOR selected_workspace IN SELECT workspace_id FROM public.memberships WHERE user_id=OLD.user_id AND role='ADMIN' AND status='ACTIVE' ORDER BY workspace_id LOOP
   UPDATE public.workspaces SET authorization_version=authorization_version WHERE workspace_id=selected_workspace;
  END LOOP;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_user_workspace_fence BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION fence_user_workspaces();

/* Deferred check cho phép handoff Admin atomically; User mutation cũng kiểm tenant liên quan.
 * Input: TG_TABLE_NAME/OLD/NEW. Output:NULL; Errors:23514 nếu trạng thái cuối mất Admin.
 */
CREATE FUNCTION validate_capable_administrators() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE selected_workspace uuid; BEGIN
 IF TG_TABLE_NAME='workspaces' THEN
  PERFORM public.assert_workspace_capable_admin(NEW.workspace_id);
 ELSIF TG_TABLE_NAME='memberships' THEN
  PERFORM public.assert_workspace_capable_admin(CASE WHEN TG_OP='DELETE' THEN OLD.workspace_id ELSE NEW.workspace_id END);
 ELSE
  FOR selected_workspace IN SELECT workspace_id FROM public.memberships WHERE user_id=NEW.user_id AND role='ADMIN' AND status='ACTIVE' LOOP
   PERFORM public.assert_workspace_capable_admin(selected_workspace);
  END LOOP;
 END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER ct_workspace_admin AFTER INSERT OR UPDATE ON workspaces DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION validate_capable_administrators();
CREATE CONSTRAINT TRIGGER ct_membership_admin AFTER INSERT OR UPDATE OR DELETE ON memberships DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION validate_capable_administrators();
CREATE CONSTRAINT TRIGGER ct_user_admin AFTER UPDATE ON users DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
 WHEN(OLD.account_status IS DISTINCT FROM NEW.account_status OR OLD.must_change_password IS DISTINCT FROM NEW.must_change_password) EXECUTE FUNCTION validate_capable_administrators();

/* Creator quota5 serialize trên User có thật; Read Committed đọc count sau fence.
 * Input: NEW Workspace. Output:NEW; Errors:23514 khi user không đủ điều kiện hoặc quota đầy.
 */
CREATE FUNCTION enforce_workspace_creator_quota() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 UPDATE public.users SET account_status=account_status WHERE user_id=NEW.created_by_user_id;
 IF NOT EXISTS(SELECT 1 FROM public.users WHERE user_id=NEW.created_by_user_id AND account_status='ACTIVE' AND NOT must_change_password) THEN
  RAISE EXCEPTION 'Workspace creator is ineligible' USING ERRCODE='23514';
 END IF;
 IF (SELECT count(*) FROM public.workspaces WHERE created_by_user_id=NEW.created_by_user_id)>=5 THEN
  RAISE EXCEPTION 'Workspace quota exceeded' USING ERRCODE='23514',CONSTRAINT='ck_workspace_creator_quota';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_workspace_creator_quota BEFORE INSERT ON workspaces FOR EACH ROW EXECUTE FUNCTION enforce_workspace_creator_quota();

/* Tránh TRUNCATE bỏ qua row trigger và xóa evidence; purge hợp lệ dùng DELETE có kiểm.
 * Output: không thành công; Errors:23514 trên bảng protected được gắn trigger.
 */
CREATE FUNCTION reject_protected_truncate() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 RAISE EXCEPTION 'Protected relation cannot be truncated' USING ERRCODE='23514',CONSTRAINT='ck_protected_truncate';
END $$;

/* Không rewrite snapshot/receipt đã chấp nhận; DELETE do retention owner kiểm riêng.
 * Input: OLD/NEW UPDATE. Output:NEW nếu no-op; Errors:23514 nếu nội dung đổi.
 */
CREATE FUNCTION reject_immutable_update() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 IF NEW IS DISTINCT FROM OLD THEN RAISE EXCEPTION 'Immutable record cannot be rewritten' USING ERRCODE='23514',CONSTRAINT='ck_record_immutable'; END IF;
 RETURN NEW;
END $$;

/* Snapshot child chỉ thêm trong transaction tạo parent, không extend published version cũ.
 * Input: NEW và tên parent/column cố định từ trigger. Output:NEW; Errors:23514 nếu parent đã commit.
 */
CREATE FUNCTION enforce_published_child_insert() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE created_here boolean; BEGIN
 EXECUTE format('SELECT xmin=pg_current_xact_id()::text::xid FROM public.%I WHERE workspace_id=$1 AND %I=$2',TG_ARGV[0],TG_ARGV[1])
 INTO created_here USING NEW.workspace_id,(to_jsonb(NEW)->>TG_ARGV[1])::uuid;
 IF created_here IS DISTINCT FROM true THEN RAISE EXCEPTION 'Published content cannot be extended' USING ERRCODE='23514',CONSTRAINT='ck_published_child_sealed'; END IF;
 RETURN NEW;
END $$;

/* Grant identity/revocation monotonic bảo đảm remove/rejoin không hồi sinh quyền cũ.
 * Input: OLD/NEW grant. Output:NEW; Errors:23514 nếu sửa identity hoặc mở revocation.
 */
CREATE FUNCTION enforce_grant_immutability() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 IF (to_jsonb(NEW)-'revoked_at') IS DISTINCT FROM (to_jsonb(OLD)-'revoked_at') OR
  (OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at) THEN
  RAISE EXCEPTION 'Grant identity and revocation are immutable' USING ERRCODE='23514',CONSTRAINT='ck_grant_immutable';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_grant_immutable BEFORE UPDATE ON membership_grants FOR EACH ROW EXECUTE FUNCTION enforce_grant_immutability();

/* Kiểm current grant ở cuối batch membership/grant; suspend không tự tạo grant mới.
 * Input: OLD/NEW membership hoặc grant. Output:NULL; Errors:23514 nếu pointer/status sai.
 */
CREATE FUNCTION validate_current_membership_grant() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE selected_workspace uuid; selected_user uuid; BEGIN
 selected_workspace:=CASE WHEN TG_OP='DELETE' THEN OLD.workspace_id ELSE NEW.workspace_id END;
 selected_user:=CASE WHEN TG_OP='DELETE' THEN OLD.user_id ELSE NEW.user_id END;
 IF EXISTS(SELECT 1 FROM public.memberships membership JOIN public.membership_grants grant_row
  ON (grant_row.workspace_id,grant_row.user_id,grant_row.grant_generation)=(membership.workspace_id,membership.user_id,membership.current_grant_generation)
  WHERE membership.workspace_id=selected_workspace AND membership.user_id=selected_user AND
   ((membership.status='ACTIVE' AND grant_row.revoked_at IS NOT NULL) OR (membership.status='REMOVED' AND grant_row.revoked_at IS NULL))) THEN
  RAISE EXCEPTION 'Current membership grant is inconsistent' USING ERRCODE='23514',CONSTRAINT='ck_membership_current_grant';
 END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER ct_membership_grant AFTER INSERT OR UPDATE ON memberships DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION validate_current_membership_grant();
CREATE CONSTRAINT TRIGGER ct_grant_membership AFTER INSERT OR UPDATE OR DELETE ON membership_grants DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION validate_current_membership_grant();

/* Kiểm typed literal theo pinned definition, không chấp nhận NaN/Infinity hoặc range sai.
 * Input: definition là schema; candidate là JSON scalar/null; writable yêu cầu capability.
 * Output:void; Errors:23514 khi datatype/range/enum/capability không đúng.
 */
CREATE FUNCTION assert_stream_value(definition public.datastream_definitions, candidate jsonb, writable boolean) RETURNS void LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE numeric_candidate double precision; BEGIN
 IF definition.stream_key IS NULL THEN RAISE EXCEPTION 'Unknown pinned stream' USING ERRCODE='23514',CONSTRAINT='ck_stream_value'; END IF;
 IF writable AND (definition.direction='READ' OR definition.data_type='STRING' OR NOT EXISTS(
  SELECT 1 FROM public.datastream_capabilities capability WHERE (capability.workspace_id,capability.template_version_id,capability.stream_key)=(definition.workspace_id,definition.template_version_id,definition.stream_key) AND command_type='SET_VALUE')) THEN
  RAISE EXCEPTION 'Stream is not writable' USING ERRCODE='23514',CONSTRAINT='ck_stream_writable';
 END IF;
 IF candidate IS NULL OR candidate='null'::jsonb THEN
  IF writable THEN RAISE EXCEPTION 'Control value cannot be null' USING ERRCODE='23514',CONSTRAINT='ck_stream_value'; END IF;
  RETURN;
 END IF;
 IF (definition.data_type='NUMBER' AND jsonb_typeof(candidate)<>'number') OR
    (definition.data_type='BOOLEAN' AND jsonb_typeof(candidate)<>'boolean') OR
    (definition.data_type='STRING' AND jsonb_typeof(candidate)<>'string') THEN
  RAISE EXCEPTION 'Stream value has wrong type' USING ERRCODE='23514',CONSTRAINT='ck_stream_value';
 END IF;
 IF definition.data_type='NUMBER' THEN
  numeric_candidate:=(candidate#>>'{}')::double precision;
  IF NOT(numeric_candidate>'-Infinity'::float8 AND numeric_candidate<'Infinity'::float8) OR
   numeric_candidate<definition.min_value OR numeric_candidate>definition.max_value THEN
   RAISE EXCEPTION 'Stream numeric value is out of range' USING ERRCODE='23514',CONSTRAINT='ck_stream_value';
  END IF;
 ELSIF definition.data_type='STRING' AND definition.string_max_length IS NOT NULL AND length(candidate#>>'{}')>definition.string_max_length THEN
  RAISE EXCEPTION 'Stream string is too long' USING ERRCODE='23514',CONSTRAINT='ck_stream_value';
 ELSIF definition.data_type='ENUM' AND NOT EXISTS(SELECT 1 FROM public.datastream_enum_values enum_row
  WHERE (enum_row.workspace_id,enum_row.template_version_id,enum_row.stream_key)=(definition.workspace_id,definition.template_version_id,definition.stream_key) AND enum_value=candidate) THEN
  RAISE EXCEPTION 'Unknown enum value' USING ERRCODE='23514',CONSTRAINT='ck_stream_value';
 END IF;
END $$;

/* Parent metadata phải trùng receipt authority; dùng IS DISTINCT FROM để không lọt NULL.
 * Input: NEW envelope. Output:NEW; Errors:23514 khi sequence/time khác receipt.
 */
CREATE FUNCTION validate_telemetry_envelope() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE receipt public.telemetry_receipts; BEGIN
 SELECT * INTO receipt FROM public.telemetry_receipts WHERE
  (workspace_id,device_id,boot_id,message_id)=(NEW.workspace_id,NEW.device_id,NEW.boot_id,NEW.message_id);
 IF receipt.ingestion_sequence IS DISTINCT FROM NEW.ingestion_sequence OR receipt.first_received_at IS DISTINCT FROM NEW.received_at THEN
  RAISE EXCEPTION 'Envelope differs from receipt' USING ERRCODE='23514',CONSTRAINT='ck_envelope_receipt_metadata';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_envelope_validate BEFORE INSERT ON telemetry_envelopes FOR EACH ROW EXECUTE FUNCTION validate_telemetry_envelope();

/* Projection point copy timestamp/device theo Core33, type đối chiếu đúng pin của device.
 * Input: NEW point. Output:NEW; Errors:23514 nếu metadata/type/value lệch schema/envelope.
 */
CREATE FUNCTION validate_telemetry_point() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE envelope public.telemetry_envelopes; definition public.datastream_definitions; candidate jsonb; BEGIN
 SELECT * INTO envelope FROM public.telemetry_envelopes WHERE (workspace_id,envelope_id)=(NEW.workspace_id,NEW.envelope_id);
 IF NEW.device_id IS DISTINCT FROM envelope.device_id OR NEW.observed_at IS DISTINCT FROM envelope.observed_at OR NEW.event_at IS DISTINCT FROM envelope.effective_at OR NEW.point_index>=envelope.point_count THEN
  RAISE EXCEPTION 'Point differs from envelope' USING ERRCODE='23514',CONSTRAINT='ck_point_envelope_metadata';
 END IF;
 SELECT stream.* INTO definition FROM public.devices device JOIN public.datastream_definitions stream USING(workspace_id,template_version_id)
 WHERE device.workspace_id=NEW.workspace_id AND device.device_id=NEW.device_id AND stream.stream_key=NEW.stream_key;
 IF NEW.value_type IS DISTINCT FROM definition.data_type THEN RAISE EXCEPTION 'Point type differs from pin' USING ERRCODE='23514',CONSTRAINT='ck_stream_value'; END IF;
 candidate:=coalesce(to_jsonb(NEW.numeric_value),to_jsonb(NEW.boolean_value),to_jsonb(NEW.text_value),'null'::jsonb);
 PERFORM public.assert_stream_value(definition,candidate,false);
 RETURN NEW;
END $$;
CREATE TRIGGER tr_point_validate BEFORE INSERT ON telemetry_points FOR EACH ROW EXECUTE FUNCTION validate_telemetry_point();

/* Deferred cardinality protège whole-envelope commit sans empêcher purge raw complète.
 * Input: envelope/point OLD/NEW. Output:NULL; Errors:23514 si point_count incomplet.
 */
CREATE FUNCTION validate_telemetry_point_count() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE selected_workspace uuid; selected_envelope uuid; expected_count integer; actual_count bigint; BEGIN
 selected_workspace:=CASE WHEN TG_OP='DELETE' THEN OLD.workspace_id ELSE NEW.workspace_id END;
 selected_envelope:=CASE WHEN TG_OP='DELETE' THEN OLD.envelope_id ELSE NEW.envelope_id END;
 SELECT point_count INTO expected_count FROM public.telemetry_envelopes WHERE(workspace_id,envelope_id)=(selected_workspace,selected_envelope);
 IF FOUND THEN
  SELECT count(*) INTO actual_count FROM public.telemetry_points WHERE(workspace_id,envelope_id)=(selected_workspace,selected_envelope);
  IF expected_count<>actual_count THEN RAISE EXCEPTION 'Incomplete telemetry envelope' USING ERRCODE='23514',CONSTRAINT='ck_envelope_point_count'; END IF;
 END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER ct_envelope_points AFTER INSERT ON telemetry_envelopes DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION validate_telemetry_point_count();
CREATE CONSTRAINT TRIGGER ct_points_count AFTER INSERT OR DELETE ON telemetry_points DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION validate_telemetry_point_count();

/* Rule quota dùng parent MVCC fence để RR không count snapshot cũ; counter thay cùng TX.
 * Input: execution OLD/NEW. Output:hàng; Side effects: quota row delta và parent fence.
 */
CREATE FUNCTION enforce_execution_quota() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE selected_workspace uuid; active_delta integer; BEGIN
 IF TG_OP='UPDATE' AND ROW(NEW.workspace_id,NEW.rule_execution_id,NEW.rule_id,NEW.rule_version_id) IS DISTINCT FROM ROW(OLD.workspace_id,OLD.rule_execution_id,OLD.rule_id,OLD.rule_version_id) THEN
  RAISE EXCEPTION 'Execution identity is immutable' USING ERRCODE='23514';
 END IF;
 selected_workspace:=CASE WHEN TG_OP='DELETE' THEN OLD.workspace_id ELSE NEW.workspace_id END;
 active_delta:=0;
 IF TG_OP<>'DELETE' AND NEW.state IN ('RUNNING','WAITING') THEN active_delta:=active_delta+1; END IF;
 IF TG_OP<>'INSERT' AND OLD.state IN ('RUNNING','WAITING') THEN active_delta:=active_delta-1; END IF;
 IF active_delta<>0 THEN
  UPDATE public.workspaces SET authorization_version=authorization_version WHERE workspace_id=selected_workspace;
  INSERT INTO public.workspace_runtime_quotas(workspace_id) VALUES(selected_workspace) ON CONFLICT DO NOTHING;
  UPDATE public.workspace_runtime_quotas SET active_execution_count=active_execution_count+active_delta,revision=revision+1 WHERE workspace_id=selected_workspace;
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_execution_quota BEFORE INSERT OR UPDATE OR DELETE ON rule_executions FOR EACH ROW EXECUTE FUNCTION enforce_execution_quota();

/* Command terminal không rewind; late evidence thuộc bảng riêng, identity/target bất biến.
 * Input: OLD/NEW. Output:NEW; Errors:23514 khi transition trái contract.
 */
CREATE FUNCTION enforce_command_transition() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE definition public.datastream_definitions; candidate jsonb; BEGIN
 IF TG_OP='UPDATE' THEN
  IF (to_jsonb(NEW)-ARRAY['state','outcome','dispatch_intent_at','terminal_at','revision']) IS DISTINCT FROM
     (to_jsonb(OLD)-ARRAY['state','outcome','dispatch_intent_at','terminal_at','revision']) THEN
   RAISE EXCEPTION 'Command admission is immutable' USING ERRCODE='23514',CONSTRAINT='ck_command_admission_immutable';
  END IF;
  IF OLD.state IN ('SUCCEEDED','FAILED','TIMED_OUT','EXPIRED_BEFORE_DISPATCH','CANCELLED') AND NEW IS DISTINCT FROM OLD THEN
   RAISE EXCEPTION 'Command terminal cannot change' USING ERRCODE='23514',CONSTRAINT='ck_command_terminal_immutable';
  END IF;
  IF NEW.state<>OLD.state AND NOT(
   (OLD.state='ADMITTED' AND NEW.state IN ('DISPATCHING','EXPIRED_BEFORE_DISPATCH','CANCELLED')) OR
   (OLD.state='DISPATCHING' AND NEW.state IN ('DISPATCHED','ACCEPTED','SUCCEEDED','FAILED','TIMED_OUT')) OR
   (OLD.state='DISPATCHED' AND NEW.state IN ('ACCEPTED','SUCCEEDED','FAILED','TIMED_OUT')) OR
   (OLD.state='ACCEPTED' AND NEW.state IN ('SUCCEEDED','FAILED','TIMED_OUT'))) THEN
   RAISE EXCEPTION 'Invalid command transition' USING ERRCODE='23514',CONSTRAINT='ck_command_transition';
  END IF;
 ELSE
  IF NEW.state<>'ADMITTED' OR NEW.outcome<>'PENDING' THEN RAISE EXCEPTION 'Command must start admitted' USING ERRCODE='23514'; END IF;
  SELECT stream.* INTO definition FROM public.devices device JOIN public.datastream_definitions stream USING(workspace_id,template_version_id)
  WHERE device.workspace_id=NEW.workspace_id AND device.device_id=NEW.device_id AND stream.stream_key=NEW.stream_key;
  IF definition.data_type IS DISTINCT FROM NEW.value_type THEN RAISE EXCEPTION 'Command type differs from pin' USING ERRCODE='23514',CONSTRAINT='ck_stream_value'; END IF;
  candidate:=coalesce(to_jsonb(NEW.numeric_value),to_jsonb(NEW.boolean_value),to_jsonb(NEW.text_value));
  PERFORM public.assert_stream_value(definition,candidate,true);
  IF EXISTS(SELECT 1 FROM public.actuator_states WHERE(workspace_id,device_id,stream_key)=(NEW.workspace_id,NEW.device_id,NEW.stream_key) AND unresolved_command_id IS NOT NULL) THEN
   RAISE EXCEPTION 'Actuator requires reconciliation' USING ERRCODE='23514',CONSTRAINT='ck_command_unresolved_guard';
  END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_command_transition BEFORE INSERT OR UPDATE ON commands FOR EACH ROW EXECUTE FUNCTION enforce_command_transition();

/* Append-only payload/identity và chặn TRUNCATE cho mọi bảng public theo manifest cố định.
 * Các identifier lấy từ literal nội bộ, format%I không ghép input ứng dụng vào DDL.
 */
DO $$ DECLARE relation_name text; BEGIN
 FOREACH relation_name IN ARRAY ARRAY['template_versions','datastream_definitions','datastream_enum_values','datastream_capabilities',
  'rule_versions','rule_version_actions','rule_version_references','firmware_packages','firmware_package_templates',
  'telemetry_receipts','telemetry_envelopes','telemetry_points','command_result_receipts','command_evidence',
  'rule_execution_snapshots','execution_actuator_snapshots','event_occurrences','outbox_events','audit_events','ota_status_receipts'] LOOP
  EXECUTE format('CREATE TRIGGER tr_immutable_update BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.reject_immutable_update()',relation_name);
 END LOOP;
 FOREACH relation_name IN ARRAY ARRAY['datastream_definitions','datastream_enum_values','datastream_capabilities'] LOOP
  EXECUTE format('CREATE TRIGGER tr_published_child BEFORE INSERT ON public.%I FOR EACH ROW EXECUTE FUNCTION public.enforce_published_child_insert(''template_versions'',''template_version_id'')',relation_name);
 END LOOP;
 FOREACH relation_name IN ARRAY ARRAY['rule_version_actions','rule_version_references'] LOOP
  EXECUTE format('CREATE TRIGGER tr_published_child BEFORE INSERT ON public.%I FOR EACH ROW EXECUTE FUNCTION public.enforce_published_child_insert(''rule_versions'',''rule_version_id'')',relation_name);
 END LOOP;
 CREATE TRIGGER tr_published_child BEFORE INSERT ON public.firmware_package_templates FOR EACH ROW EXECUTE FUNCTION public.enforce_published_child_insert('firmware_packages','firmware_package_id');
 FOR relation_name IN SELECT tablename FROM pg_tables WHERE schemaname='public' LOOP
  EXECUTE format('CREATE TRIGGER tr_protected_truncate BEFORE TRUNCATE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION public.reject_protected_truncate()',relation_name);
 END LOOP;
END $$;
/* Giới hạn mặc định: không mở writer hay đọc credential trước khi backend policy được nghiệm thu. */
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC,iot_runtime;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC,iot_runtime;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC,iot_runtime;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM PUBLIC;

INSERT INTO migration_control.applied_migrations(version,checksum)
    VALUES(:'migration_version',:'migration_checksum');
\echo APPLIED
\else
SELECT checksum=:'migration_checksum' AS checksum_matches
    FROM migration_control.applied_migrations WHERE version=:'migration_version' \gset
\if :checksum_matches
\echo ALREADY_APPLIED
\else
/* Drift phải rollback, không UPDATE checksum để hợp thức hóa lịch sử bị thay đổi. */
DO $$ BEGIN RAISE EXCEPTION 'migration checksum drift'; END $$;
\endif
\endif
COMMIT;

\set migration_version platform-0008-delivery-integrity
\set migration_checksum ad72ec33f804365c79266edb36e687ddb2a2dcac1aae833817f5cc8f73dc2c3c

/* Template psql của runner; hai marker chỉ được thay bằng file SQL nguồn trong repo.
 * migration_version/checksum là literal qua :'name', không chèn input vào SQL.
 * DDL và ledger commit cùng nhau; advisory lock dùng chung cho mọi version/runner.
 */
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
SELECT pg_advisory_xact_lock(17001,1);
/* Lịch sử runner lab: lưu checksum và thời điểm áp thật, không chứa credential.
 * Phải chạy trong transaction đã lấy advisory lock; không thay SQLx production history.
 */
CREATE SCHEMA IF NOT EXISTS migration_control;
CREATE TABLE IF NOT EXISTS migration_control.applied_migrations (
    version text PRIMARY KEY,
    checksum text NOT NULL CHECK(checksum ~ '^[0-9a-f]{64}$'),
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

SELECT NOT EXISTS(
    SELECT 1 FROM migration_control.applied_migrations WHERE version=:'migration_version'
) AS should_apply \gset
\if :should_apply
/* Hoàn thiện identity, retry budget và các invariant còn lại sau0007.
 * Không mở writer runtime; owner là boundary tin cậy cho DDL/retention/validator chữ ký.
 */
/* Khóa các cột identity được trigger truyền tên tường minh, không khóa state được phép đổi.
 * Input: OLD/NEW và TG_ARGV là danh sách cột nội bộ. Output:NEW; Errors:23514 khi identity đổi.
 */
CREATE FUNCTION enforce_identity_columns() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE column_name text; BEGIN
 FOREACH column_name IN ARRAY TG_ARGV LOOP
  IF to_jsonb(NEW)->column_name IS DISTINCT FROM to_jsonb(OLD)->column_name THEN
   RAISE EXCEPTION 'Resource identity is immutable' USING ERRCODE='23514',CONSTRAINT='ck_resource_identity_immutable';
  END IF;
 END LOOP;
 RETURN NEW;
END $$;
/* Mọi PK giữ nguyên trong vòng đời; FK reference không bị UPDATE key kéo sang identity khác. */
DO $$ DECLARE relation record; BEGIN
 FOR relation IN SELECT table_row.relname, string_agg(quote_literal(attribute.attname),',' ORDER BY key_column.position) AS arguments
  FROM pg_constraint constraint_row JOIN pg_class table_row ON table_row.oid=constraint_row.conrelid
  JOIN pg_namespace namespace_row ON namespace_row.oid=table_row.relnamespace
  CROSS JOIN LATERAL unnest(constraint_row.conkey) WITH ORDINALITY AS key_column(attribute_number,position)
  JOIN pg_attribute attribute ON attribute.attrelid=table_row.oid AND attribute.attnum=key_column.attribute_number
  WHERE namespace_row.nspname='public' AND constraint_row.contype='p' GROUP BY table_row.relname LOOP
  EXECUTE format('CREATE TRIGGER tr_identity_columns BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.enforce_identity_columns(%s)',relation.relname,relation.arguments);
 END LOOP;
END $$;
CREATE TRIGGER tr_device_pin_identity BEFORE UPDATE ON devices FOR EACH ROW EXECUTE FUNCTION enforce_identity_columns('workspace_id','template_version_id','owner_user_id','serial_number','model','hardware_revision');
CREATE TRIGGER tr_workspace_creator_identity BEFORE UPDATE ON workspaces FOR EACH ROW EXECUTE FUNCTION enforce_identity_columns('created_by_user_id','created_at');
CREATE TRIGGER tr_rule_owner_identity BEFORE UPDATE ON rules FOR EACH ROW EXECUTE FUNCTION enforce_identity_columns('owner_user_id');
CREATE TRIGGER tr_dashboard_owner_identity BEFORE UPDATE ON dashboards FOR EACH ROW EXECUTE FUNCTION enforce_identity_columns('owner_user_id');
CREATE TRIGGER tr_notification_identity BEFORE UPDATE ON notifications FOR EACH ROW EXECUTE FUNCTION enforce_identity_columns('recipient_user_id','kind','event_id','target_type','target_device_id','target_rule_execution_id','created_at');
CREATE TRIGGER tr_push_identity BEFORE UPDATE ON push_deliveries FOR EACH ROW EXECUTE FUNCTION enforce_identity_columns('notification_id','installation_id','recipient_user_id','binding_generation','created_at','expires_at');
CREATE TRIGGER tr_api_key_identity BEFORE UPDATE ON api_keys FOR EACH ROW EXECUTE FUNCTION enforce_identity_columns('owner_user_id','owner_grant_generation','verifier_digest','issued_at','expires_at','prefix');
CREATE TRIGGER tr_webhook_delivery_identity BEFORE UPDATE ON webhook_deliveries FOR EACH ROW EXECUTE FUNCTION enforce_identity_columns('webhook_subscription_id','kind','occurrence_id','endpoint_url_snapshot','endpoint_revision_snapshot','secret_version','raw_body','body_digest','admitted_at','expires_at');
CREATE TRIGGER tr_ota_identity BEFORE UPDATE ON ota_jobs FOR EACH ROW EXECUTE FUNCTION enforce_identity_columns('device_id','firmware_package_id','source_firmware_version_snapshot','target_artifact_digest_snapshot','job_nonce','maintenance_epoch','admitted_at','deadline_at');
CREATE TRIGGER tr_enrollment_identity BEFORE UPDATE ON enrollment_sessions FOR EACH ROW EXECUTE FUNCTION enforce_identity_columns('device_id','actor_user_id','actor_grant_generation','client_installation_id','enrollment_proof_digest','mode','started_at','expires_at');

/* Hạn chế current-pointer cập nhật phải có grant mới hơn; tombstone không tái dùng generation.
 * Input: OLD/NEW membership. Output:NEW; Errors:23514 nếu generation giảm/rejoin grant cũ.
 */
CREATE FUNCTION enforce_membership_generation() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 IF NEW.current_grant_generation<OLD.current_grant_generation OR
  (OLD.status='REMOVED' AND NEW.status<>'REMOVED' AND NEW.current_grant_generation<=OLD.current_grant_generation) THEN
  RAISE EXCEPTION 'Membership cannot reuse old grant' USING ERRCODE='23514',CONSTRAINT='ck_membership_generation';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_membership_generation BEFORE UPDATE ON memberships FOR EACH ROW EXECUTE FUNCTION enforce_membership_generation();

/* Password/account đổi thu hồi toàn bộ phiên cũ trong cùng commit; phiên mới tạo sau mutation.
 * Input: OLD/NEW User. Output:NULL; Side effects: revoke unrevoked sessions, không đọc credential.
 */
CREATE FUNCTION revoke_changed_account_sessions() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 IF NEW.password_hash IS DISTINCT FROM OLD.password_hash OR (NEW.account_status='DISABLED' AND OLD.account_status<>'DISABLED') OR
   (NEW.must_change_password AND NOT OLD.must_change_password) THEN
  UPDATE public.sessions SET revoked_at=clock_timestamp() WHERE user_id=NEW.user_id AND revoked_at IS NULL;
 END IF;
 RETURN NULL;
END $$;
CREATE TRIGGER tr_user_revoke_sessions AFTER UPDATE ON users FOR EACH ROW EXECUTE FUNCTION revoke_changed_account_sessions();

/* Capability phải đúng writable pin/type; ENUM có literal đã khai, safeValue không nullable.
 * Input: NEW capability snapshot. Output:NEW; Errors:23514 nếu READ/STRING hoặc safe value sai.
 */
CREATE FUNCTION validate_datastream_capability() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE definition public.datastream_definitions; BEGIN
 SELECT * INTO definition FROM public.datastream_definitions WHERE(workspace_id,template_version_id,stream_key)=(NEW.workspace_id,NEW.template_version_id,NEW.stream_key);
 IF definition.direction='READ' OR definition.data_type='STRING' THEN RAISE EXCEPTION 'Capability requires writable stream' USING ERRCODE='23514',CONSTRAINT='ck_stream_writable'; END IF;
 PERFORM public.assert_stream_value(definition,NEW.safe_value,false);
 RETURN NEW;
END $$;
CREATE TRIGGER tr_capability_validate BEFORE INSERT ON datastream_capabilities FOR EACH ROW EXECUTE FUNCTION validate_datastream_capability();

/* Cardinality cuối batch: tối đa5 device/key, scope không rỗng; khóa parent chống count race.
 * Input: NEW child key/device/scope. Output:NEW; Errors:23514 khi quá cap; mọi writer cùng anchor.
 */
CREATE FUNCTION fence_api_key_children() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 UPDATE public.api_keys SET revision=revision WHERE(workspace_id,api_key_id)=(NEW.workspace_id,NEW.api_key_id);
 RETURN NEW;
END $$;
CREATE TRIGGER tr_api_key_device_fence BEFORE INSERT ON api_key_devices FOR EACH ROW EXECUTE FUNCTION fence_api_key_children();
CREATE TRIGGER tr_api_key_scope_fence BEFORE INSERT ON api_key_scopes FOR EACH ROW EXECUTE FUNCTION fence_api_key_children();

/* Check deferred hỗ trợ tạo principal và allowlist/scopes nguyên tử, không principal rỗng.
 * Input: NEW parent/OLD/NEW child. Output:NULL; Errors:23514 nếu không1..5devices hoặc scope rỗng.
 */
CREATE FUNCTION validate_api_key_cardinality() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE selected_workspace uuid; selected_key uuid; device_count bigint; BEGIN
 selected_workspace:=CASE WHEN TG_OP='DELETE' THEN OLD.workspace_id ELSE NEW.workspace_id END;
 selected_key:=CASE WHEN TG_OP='DELETE' THEN OLD.api_key_id ELSE NEW.api_key_id END;
 IF EXISTS(SELECT 1 FROM public.api_keys WHERE(workspace_id,api_key_id)=(selected_workspace,selected_key)) THEN
  SELECT count(*) INTO device_count FROM public.api_key_devices WHERE(workspace_id,api_key_id)=(selected_workspace,selected_key);
  IF device_count NOT BETWEEN 1 AND 5 OR NOT EXISTS(SELECT 1 FROM public.api_key_scopes WHERE(workspace_id,api_key_id)=(selected_workspace,selected_key)) THEN
   RAISE EXCEPTION 'API key requires 1..5 devices and nonempty scopes' USING ERRCODE='23514',CONSTRAINT='ck_api_key_cardinality';
  END IF;
 END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER ct_api_key_cardinality AFTER INSERT ON api_keys DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION validate_api_key_cardinality();
CREATE CONSTRAINT TRIGGER ct_api_key_devices AFTER INSERT OR DELETE ON api_key_devices DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION validate_api_key_cardinality();
CREATE CONSTRAINT TRIGGER ct_api_key_scopes AFTER INSERT OR DELETE ON api_key_scopes DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION validate_api_key_cardinality();

/* Push expiry neo Notification.created_at; rebind không thay fanout/expiry đã đóng băng.
 * Input: NEW delivery. Output:NEW; Errors:23514 nếu không đúng gốc notification hoặc binding.
 */
CREATE FUNCTION validate_push_delivery() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE notification_time timestamptz; installation public.push_installations; BEGIN
 SELECT created_at INTO notification_time FROM public.notifications WHERE(workspace_id,notification_id)=(NEW.workspace_id,NEW.notification_id);
 SELECT * INTO installation FROM public.push_installations WHERE installation_id=NEW.installation_id;
 IF NEW.created_at IS DISTINCT FROM notification_time OR NEW.binding_generation IS DISTINCT FROM installation.binding_generation OR
    NEW.recipient_user_id IS DISTINCT FROM installation.active_user_id THEN
  RAISE EXCEPTION 'Push delivery snapshot is inconsistent' USING ERRCODE='23514',CONSTRAINT='ck_push_delivery_snapshot';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_push_delivery_validate BEFORE INSERT ON push_deliveries FOR EACH ROW EXECUTE FUNCTION validate_push_delivery();

/* Webhook BUSINESS dùng occurrence.committed_at+24h, TEST riêng30s và không Event giả.
 * Input: NEW delivery. Output:NEW; Errors:23514 nếu deadline/body hash/secret metadata không hợp lệ.
 * Hash phải được producer tính SHA256; không thêm extension crypto chưa được duyệt.
 */
CREATE FUNCTION validate_webhook_delivery() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE occurrence_time timestamptz; BEGIN
 IF NEW.kind='BUSINESS' THEN
  SELECT committed_at INTO occurrence_time FROM public.event_occurrences WHERE(workspace_id,occurrence_id)=(NEW.workspace_id,NEW.occurrence_id) AND public_event_type IS NOT NULL;
  IF occurrence_time IS NULL OR NEW.expires_at IS DISTINCT FROM occurrence_time+interval '24 hours' THEN
   RAISE EXCEPTION 'Webhook expiry must use original occurrence commit' USING ERRCODE='23514',CONSTRAINT='ck_webhook_occurrence_expiry';
  END IF;
 END IF;
 IF NOT EXISTS(SELECT 1 FROM public.webhook_secret_versions WHERE(workspace_id,webhook_subscription_id,secret_version)=(NEW.workspace_id,NEW.webhook_subscription_id,NEW.secret_version) AND secret_ciphertext IS NOT NULL) THEN
  RAISE EXCEPTION 'Webhook secret is unavailable' USING ERRCODE='23514',CONSTRAINT='ck_webhook_secret_available';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_webhook_delivery_validate BEFORE INSERT ON webhook_deliveries FOR EACH ROW EXECUTE FUNCTION validate_webhook_delivery();

/* Một manual batch mở lại DEAD_LETTER trên chính delivery, không đổi body/key/occurrence.
 * Input: OLD/NEW. Output:NEW; Errors:23514 nếu batch thứhai hoặc rewind terminal trái contract.
 */
CREATE FUNCTION enforce_delivery_transition() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 IF TG_TABLE_NAME='webhook_deliveries' THEN
  IF NEW.manual_batch_count<>OLD.manual_batch_count AND NOT(OLD.manual_batch_count=0 AND NEW.manual_batch_count=1 AND
    OLD.kind='BUSINESS' AND OLD.state='DEAD_LETTER' AND NEW.state='PENDING' AND NEW.expires_at>clock_timestamp()) THEN
   RAISE EXCEPTION 'Invalid webhook manual retry batch' USING ERRCODE='23514',CONSTRAINT='ck_webhook_manual_batch';
  END IF;
  IF OLD.state IN ('ACCEPTED','FAILED','CANCELLED') AND NEW.state<>OLD.state THEN
   RAISE EXCEPTION 'Webhook terminal cannot rewind' USING ERRCODE='23514',CONSTRAINT='ck_delivery_terminal';
  END IF;
  IF OLD.state='DEAD_LETTER' AND NEW.state<>'DEAD_LETTER' AND NOT(NEW.state='PENDING' AND OLD.manual_batch_count=0 AND NEW.manual_batch_count=1 AND NEW.expires_at>clock_timestamp()) THEN
   RAISE EXCEPTION 'Dead letter requires explicit manual batch' USING ERRCODE='23514',CONSTRAINT='ck_webhook_manual_batch';
  END IF;
 ELSE
  IF OLD.state IN ('ACCEPTED','FAILED','EXPIRED','SUPPRESSED') AND NEW.state<>OLD.state THEN
   RAISE EXCEPTION 'Push terminal cannot rewind' USING ERRCODE='23514',CONSTRAINT='ck_delivery_terminal';
  END IF;
 END IF;
 IF NEW.lease_generation<OLD.lease_generation THEN RAISE EXCEPTION 'Lease cannot go backwards' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_push_transition BEFORE UPDATE ON push_deliveries FOR EACH ROW EXECUTE FUNCTION enforce_delivery_transition();
CREATE TRIGGER tr_webhook_transition BEFORE UPDATE ON webhook_deliveries FOR EACH ROW EXECUTE FUNCTION enforce_delivery_transition();

/* Intent consume budget trước network; sequence liên tiếp và neo deadline parent.
 * Input: NEW push/webhook attempt. Output:NEW; Errors:23514 khi hết hạn/budget hoặc skip số.
 */
CREATE FUNCTION validate_delivery_attempt() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE expires_at_value timestamptz; expected_number integer; parent_kind text; manual_count integer; parent_state text; BEGIN
 IF TG_TABLE_NAME='push_delivery_attempts' THEN
  SELECT expires_at,state INTO expires_at_value,parent_state FROM public.push_deliveries
   WHERE(workspace_id,push_delivery_id)=(NEW.workspace_id,NEW.push_delivery_id) FOR UPDATE;
  SELECT coalesce(max(attempt_number),0)+1 INTO expected_number FROM public.push_delivery_attempts WHERE(workspace_id,push_delivery_id)=(NEW.workspace_id,NEW.push_delivery_id);
 ELSE
  SELECT expires_at,kind,manual_batch_count,state INTO expires_at_value,parent_kind,manual_count,parent_state FROM public.webhook_deliveries
   WHERE(workspace_id,webhook_delivery_id)=(NEW.workspace_id,NEW.webhook_delivery_id) FOR UPDATE;
  SELECT coalesce(max(attempt_number),0)+1 INTO expected_number FROM public.webhook_delivery_attempts WHERE(workspace_id,webhook_delivery_id)=(NEW.workspace_id,NEW.webhook_delivery_id);
  IF (parent_kind='TEST' AND NEW.attempt_number<>1) OR NEW.batch_number>manual_count THEN
   RAISE EXCEPTION 'Delivery attempt budget exceeded' USING ERRCODE='23514',CONSTRAINT='ck_delivery_attempt_budget';
  END IF;
 END IF;
 IF expires_at_value IS NULL OR NEW.intent_at>=expires_at_value OR NEW.attempt_number<>expected_number OR parent_state<>'SENDING' THEN
  RAISE EXCEPTION 'Delivery attempt is ineligible' USING ERRCODE='23514',CONSTRAINT='ck_delivery_attempt_admission';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_push_attempt_admission BEFORE INSERT ON push_delivery_attempts FOR EACH ROW EXECUTE FUNCTION validate_delivery_attempt();
CREATE TRIGGER tr_webhook_attempt_admission BEFORE INSERT ON webhook_delivery_attempts FOR EACH ROW EXECUTE FUNCTION validate_delivery_attempt();
CREATE TRIGGER tr_push_attempt_identity BEFORE UPDATE ON push_delivery_attempts FOR EACH ROW EXECUTE FUNCTION enforce_identity_columns('intent_at','token_generation');
CREATE TRIGGER tr_webhook_attempt_identity BEFORE UPDATE ON webhook_delivery_attempts FOR EACH ROW EXECUTE FUNCTION enforce_identity_columns('batch_number','intent_at','request_digest');

/* OTA giữ slot cho tới settlement; terminal success/rollback bắt buộc proof ở service.
 * Input: OLD/NEW OTA. Output:NEW; Errors:23514 nếu tự release recovery hoặc thay trạng thái settled.
 */
CREATE FUNCTION enforce_ota_settlement() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 IF NEW.settled_at IS NOT NULL AND NEW.state NOT IN ('SUCCEEDED','FAILED','CANCELLED','ROLLED_BACK') THEN
  RAISE EXCEPTION 'OTA cannot release unresolved maintenance' USING ERRCODE='23514',CONSTRAINT='ck_ota_settlement';
 END IF;
 IF TG_OP='UPDATE' AND OLD.settled_at IS NOT NULL AND NEW IS DISTINCT FROM OLD THEN
  RAISE EXCEPTION 'Settled OTA is immutable' USING ERRCODE='23514',CONSTRAINT='ck_ota_settlement';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_ota_settlement BEFORE INSERT OR UPDATE ON ota_jobs FOR EACH ROW EXECUTE FUNCTION enforce_ota_settlement();

/* Typed OTA receipt/ticket phải cùng job deadline; tránh bearer ticket sống quá intent.
 * Input: NEW ticket. Output:NEW; Errors:23514 khi ticket vượt deadline job.
 */
CREATE FUNCTION validate_ota_ticket_expiry() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.ota_jobs WHERE(workspace_id,ota_job_id)=(NEW.workspace_id,NEW.ota_job_id) AND NEW.expires_at<=deadline_at) THEN
  RAISE EXCEPTION 'OTA ticket exceeds job deadline' USING ERRCODE='23514',CONSTRAINT='ck_ota_ticket_expiry';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_ota_ticket_expiry BEFORE INSERT ON ota_download_tickets FOR EACH ROW EXECUTE FUNCTION validate_ota_ticket_expiry();

/* Logical retention không chờ cron; không grant view này cho role thiếu authorization scope. */
CREATE VIEW telemetry_history WITH(security_invoker=true) AS SELECT point.* FROM telemetry_points point
 JOIN telemetry_envelopes envelope USING(workspace_id,envelope_id)
 WHERE envelope.received_at>statement_timestamp()-interval '7 days';
CREATE VIEW audit_history WITH(security_invoker=true) AS SELECT * FROM audit_events WHERE occurred_at>statement_timestamp()-interval '30 days';
CREATE VIEW execution_history WITH(security_invoker=true) AS SELECT * FROM rule_executions WHERE admitted_at>statement_timestamp()-interval '30 days';
CREATE VIEW push_delivery_history WITH(security_invoker=true) AS SELECT * FROM push_deliveries WHERE created_at>statement_timestamp()-interval '30 days';
CREATE VIEW webhook_delivery_history WITH(security_invoker=true) AS SELECT * FROM webhook_deliveries WHERE admitted_at>statement_timestamp()-interval '30 days';
/* Replay receipts và operational UNKNOWN không bị view retention xóa authority. */
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC,iot_runtime;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC,iot_runtime;

INSERT INTO migration_control.applied_migrations(version,checksum)
    VALUES(:'migration_version',:'migration_checksum');
\echo APPLIED
\else
SELECT checksum=:'migration_checksum' AS checksum_matches
    FROM migration_control.applied_migrations WHERE version=:'migration_version' \gset
\if :checksum_matches
\echo ALREADY_APPLIED
\else
/* Drift phải rollback, không UPDATE checksum để hợp thức hóa lịch sử bị thay đổi. */
DO $$ BEGIN RAISE EXCEPTION 'migration checksum drift'; END $$;
\endif
\endif
COMMIT;

\set migration_version platform-0009-operations
\set migration_checksum f0806d7963c94737bfb80242891c1a6ba7619affac5e2674054660fc541a3e61

/* Template psql của runner; hai marker chỉ được thay bằng file SQL nguồn trong repo.
 * migration_version/checksum là literal qua :'name', không chèn input vào SQL.
 * DDL và ledger commit cùng nhau; advisory lock dùng chung cho mọi version/runner.
 */
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
SELECT pg_advisory_xact_lock(17001,1);
/* Lịch sử runner lab: lưu checksum và thời điểm áp thật, không chứa credential.
 * Phải chạy trong transaction đã lấy advisory lock; không thay SQLx production history.
 */
CREATE SCHEMA IF NOT EXISTS migration_control;
CREATE TABLE IF NOT EXISTS migration_control.applied_migrations (
    version text PRIMARY KEY,
    checksum text NOT NULL CHECK(checksum ~ '^[0-9a-f]{64}$'),
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

SELECT NOT EXISTS(
    SELECT 1 FROM migration_control.applied_migrations WHERE version=:'migration_version'
) AS should_apply \gset
\if :should_apply
/* Entry point vận hành và index FK; migration cuối baseline, không cấp quyền vượt phạm vi.
 * Check quota dựa ledger dưới fence, không tin counter projection có thể lệch sau restore.
 */
/* Đếm ledger sau User/Workspace fence, cập nhật projection cùng mutation execution.
 * Input: execution OLD/NEW. Output:hàng hợp lệ; Errors:23514 khi vượt10 hoặc đổi identity.
 * Side effects: MVCC fence và reconcile counter; không gọi network.
 */
CREATE OR REPLACE FUNCTION enforce_execution_quota() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE selected_workspace uuid; active_delta integer; active_count integer; BEGIN
 IF TG_OP='UPDATE' AND ROW(NEW.workspace_id,NEW.rule_execution_id,NEW.rule_id,NEW.rule_version_id) IS DISTINCT FROM ROW(OLD.workspace_id,OLD.rule_execution_id,OLD.rule_id,OLD.rule_version_id) THEN
  RAISE EXCEPTION 'Execution identity is immutable' USING ERRCODE='23514';
 END IF;
 selected_workspace:=CASE WHEN TG_OP='DELETE' THEN OLD.workspace_id ELSE NEW.workspace_id END;
 active_delta:=0;
 IF TG_OP<>'DELETE' AND NEW.state IN ('RUNNING','WAITING') THEN active_delta:=active_delta+1; END IF;
 IF TG_OP<>'INSERT' AND OLD.state IN ('RUNNING','WAITING') THEN active_delta:=active_delta-1; END IF;
 IF active_delta<>0 THEN
  UPDATE public.workspaces SET authorization_version=authorization_version WHERE workspace_id=selected_workspace;
  SELECT count(*) INTO active_count FROM public.rule_executions WHERE workspace_id=selected_workspace AND state IN ('RUNNING','WAITING');
  IF active_count+active_delta NOT BETWEEN 0 AND 10 THEN RAISE EXCEPTION 'Execution quota exceeded' USING ERRCODE='23514',CONSTRAINT='ck_execution_workspace_quota'; END IF;
  INSERT INTO public.workspace_runtime_quotas(workspace_id,active_execution_count) VALUES(selected_workspace,active_count+active_delta)
  ON CONFLICT(workspace_id) DO UPDATE SET active_execution_count=EXCLUDED.active_execution_count,revision=workspace_runtime_quotas.revision+1;
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END $$;

/* Kiểm đủ1..5 action liên tiếp và tổngWAIT≤600s tại cuối publish/save batch.
 * Input: NEW parent/action hoặc OLD child DELETE. Output:NULL; Errors:23514 nếu thiếu/lệch/budget.
 * AST và reference bijection vẫn là boundary validator backend, không suy từ CHECK JSON object.
 */
CREATE FUNCTION validate_rule_action_cardinality() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE selected_workspace uuid; selected_version uuid; action_count integer; last_position integer; total_wait integer; BEGIN
 selected_workspace:=CASE WHEN TG_OP='DELETE' THEN OLD.workspace_id ELSE NEW.workspace_id END;
 selected_version:=CASE WHEN TG_OP='DELETE' THEN OLD.rule_version_id ELSE NEW.rule_version_id END;
 IF EXISTS(SELECT 1 FROM public.rule_versions WHERE(workspace_id,rule_version_id)=(selected_workspace,selected_version)) THEN
  SELECT count(*),max(action_position),coalesce(sum(wait_seconds),0) INTO action_count,last_position,total_wait FROM public.rule_version_actions
  WHERE(workspace_id,rule_version_id)=(selected_workspace,selected_version);
  IF action_count NOT BETWEEN 1 AND 5 OR last_position<>action_count-1 OR total_wait>600 THEN
   RAISE EXCEPTION 'Rule action sequence is invalid' USING ERRCODE='23514',CONSTRAINT='ck_rule_action_cardinality';
  END IF;
 END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER ct_rule_version_actions AFTER INSERT ON rule_versions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION validate_rule_action_cardinality();
CREATE CONSTRAINT TRIGGER ct_rule_actions AFTER INSERT OR UPDATE OR DELETE ON rule_version_actions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION validate_rule_action_cardinality();

/* Không thêm grant device/scope vào key đã cấp ở transaction khác.
 * Published helper dùng cùng parent identity; consumer rotate phải tạo keyId mới.
 */
CREATE TRIGGER tr_api_device_sealed BEFORE INSERT ON api_key_devices FOR EACH ROW EXECUTE FUNCTION enforce_published_child_insert('api_keys','api_key_id');
CREATE TRIGGER tr_api_scope_sealed BEFORE INSERT ON api_key_scopes FOR EACH ROW EXECUTE FUNCTION enforce_published_child_insert('api_keys','api_key_id');
/* Không có hai enrollment nonterminal/device; guard cleanup vẫn tồn tại sau terminal. */
CREATE UNIQUE INDEX uq_enrollment_sessions_active_device ON enrollment_sessions(workspace_id,device_id)
 WHERE state IN ('CREATED','BLE_CONNECTED','WIFI_JOINED','CLOUD_CONNECTING');

/* Guard chỉ được release khi hoàn tất hoặc cleanup có đủ hai proof.
 * Input: OLD guard bị DELETE. Output:OLD; Errors:23514 nếu TTL/terminal chưa có cleanup proof.
 */
CREATE FUNCTION validate_enrollment_guard_release() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.enrollment_sessions WHERE(workspace_id,enrollment_session_id)=(OLD.workspace_id,OLD.enrollment_session_id) AND state='COMPLETED') AND
    NOT EXISTS(SELECT 1 FROM public.enrollment_cleanup_operations WHERE(workspace_id,enrollment_session_id)=(OLD.workspace_id,OLD.enrollment_session_id)
    AND settled_at IS NOT NULL AND broker_revoke_receipt IS NOT NULL AND disconnect_receipt IS NOT NULL AND state='SUCCEEDED') THEN
  RAISE EXCEPTION 'Enrollment cleanup proof is required' USING ERRCODE='23514',CONSTRAINT='ck_enrollment_guard_release';
 END IF;
 RETURN OLD;
END $$;
CREATE TRIGGER tr_enrollment_guard_release BEFORE DELETE ON device_enrollment_guards FOR EACH ROW EXECUTE FUNCTION validate_enrollment_guard_release();

/* Claim bounded batch ngắn bằng SKIP LOCKED; mỗi lần tăng lease_generation trước network.
 * Input
 * Param: target_consumer — pipeline cố định do backend chọn.
 * Param: lease_seconds — thời gian giữ lease1..300s của vận hành, không TTL nghiệp vụ.
 * Param: batch_limit — số claim1..1000, giới hạn tài nguyên mỗi transaction.
 * Output: outbox IDs/generation được claim; Errors:22023 khi tham số ngoài miền.
 */
CREATE FUNCTION claim_outbox(target_consumer text,lease_seconds integer,batch_limit integer)
RETURNS TABLE(claimed_event_id uuid,claimed_generation bigint) LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 IF lease_seconds NOT BETWEEN 1 AND 300 OR batch_limit NOT BETWEEN 1 AND 1000 OR target_consumer IS NULL OR btrim(target_consumer)='' THEN
  RAISE EXCEPTION 'Invalid lease parameters' USING ERRCODE='22023';
 END IF;
 RETURN QUERY WITH candidates AS (
  SELECT consumption.outbox_event_id,consumption.consumer_code FROM public.outbox_consumptions consumption
  WHERE consumption.consumer_code=target_consumer AND consumption.available_at<=clock_timestamp() AND
   (consumption.state IN ('PENDING','RETRY_WAIT') OR (consumption.state='PROCESSING' AND consumption.lease_until<=clock_timestamp()))
  ORDER BY consumption.available_at,consumption.outbox_event_id LIMIT batch_limit FOR UPDATE SKIP LOCKED
 ) UPDATE public.outbox_consumptions consumption SET state='PROCESSING',lease_generation=consumption.lease_generation+1,
  lease_until=clock_timestamp()+make_interval(secs=>lease_seconds),attempt_count=consumption.attempt_count+1
 FROM candidates WHERE(consumption.outbox_event_id,consumption.consumer_code)=(candidates.outbox_event_id,candidates.consumer_code)
 RETURNING consumption.outbox_event_id,consumption.lease_generation;
END $$;

/* Stale worker không settle được sau takeover/expiry; false là CAS thất bại, không retry side effect.
 * Input: target_event/consumer/generation là receipt claim. Output:boolean một winner.
 * Side effects: chuyển COMPLETED và xóa lease chỉ khi generation hiện hành còn hiệu lực.
 */
CREATE FUNCTION complete_outbox(target_event uuid,target_consumer text,expected_generation bigint) RETURNS boolean LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 UPDATE public.outbox_consumptions SET state='COMPLETED',completed_at=clock_timestamp(),lease_until=NULL
 WHERE outbox_event_id=target_event AND consumer_code=target_consumer AND state='PROCESSING'
 AND lease_generation=expected_generation AND lease_until>clock_timestamp();
 RETURN FOUND;
END $$;

/* Consume websocket ticket một lần, recheck session/grant/membership/account/workspace ngay tại UPDATE.
 * Input: presented_digest là SHA256 của ticket ngoài DB. Output:boolean một winner còn quyền.
 * Side effects: consumed_at; không trả raw ticket hoặc mở socket trước commit.
 */
CREATE FUNCTION consume_websocket_ticket(presented_digest bytea) RETURNS boolean LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 UPDATE public.websocket_tickets ticket SET consumed_at=clock_timestamp()
 FROM public.sessions session_row, public.memberships membership, public.membership_grants grant_row, public.users account,public.workspaces workspace
 WHERE ticket.ticket_digest=presented_digest AND ticket.consumed_at IS NULL AND ticket.revoked_at IS NULL AND ticket.expires_at>clock_timestamp()
 AND session_row.session_id=ticket.session_id AND session_row.user_id=ticket.user_id AND session_row.revoked_at IS NULL AND NOT session_row.limited AND session_row.expires_at>clock_timestamp()
 AND membership.workspace_id=ticket.workspace_id AND membership.user_id=ticket.user_id AND membership.status='ACTIVE'
 AND membership.current_grant_generation=ticket.grant_generation AND membership.authorization_version=ticket.membership_authorization_version
 AND(grant_row.workspace_id,grant_row.user_id,grant_row.grant_generation)=(membership.workspace_id,membership.user_id,membership.current_grant_generation) AND grant_row.revoked_at IS NULL
 AND account.user_id=ticket.user_id AND account.account_status='ACTIVE' AND NOT account.must_change_password
 AND workspace.workspace_id=ticket.workspace_id AND workspace.status='ACTIVE' AND workspace.authorization_version=ticket.workspace_authorization_version;
 RETURN FOUND;
END $$;

/* Purge raw tối đa một batch, giữ receipt/floor để không resurrect replay.
 * Input: batch_limit1..10000 là giới hạn vận hành. Output:số envelope xóa; lỗi22023 nếu ngoài miền.
 * Side effects: khóa envelope cũ>7d, xóa points rồi envelope atomically; không xóa dedupe ledger.
 */
CREATE FUNCTION purge_expired_telemetry(batch_limit integer) RETURNS integer LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE target record; removed_count integer:=0; BEGIN
 IF batch_limit NOT BETWEEN 1 AND 10000 THEN RAISE EXCEPTION 'Invalid retention batch' USING ERRCODE='22023'; END IF;
 SET CONSTRAINTS ct_points_count DEFERRED;
 FOR target IN SELECT workspace_id,envelope_id FROM public.telemetry_envelopes WHERE received_at<=statement_timestamp()-interval '7 days'
  ORDER BY received_at,workspace_id,envelope_id LIMIT batch_limit FOR UPDATE SKIP LOCKED LOOP
  DELETE FROM public.telemetry_points WHERE(workspace_id,envelope_id)=(target.workspace_id,target.envelope_id);
  DELETE FROM public.telemetry_envelopes WHERE(workspace_id,envelope_id)=(target.workspace_id,target.envelope_id);
  removed_count:=removed_count+1;
 END LOOP;
 RETURN removed_count;
END $$;
/* Cutoff trước scope để retention quét theo tuổi; query history vẫn dùng index theo tenant/device. */
CREATE INDEX ix_telemetry_retention ON telemetry_envelopes(received_at,workspace_id,envelope_id);
/* Bổ sung index FK chỉ khi chưa có prefix tương ứng, giảm scan/lock khi kiểm parent/purge.
 * Tên và cột lấy từ pg_catalog của schema này; không index JSON hay mọi cột tùy tiện.
 */
DO $$ DECLARE reference_row record; BEGIN
 FOR reference_row IN SELECT constraint_row.oid,constraint_row.conrelid,constraint_row.conkey,table_row.relname,
   string_agg(quote_ident(attribute.attname),',' ORDER BY key_column.position) AS columns
  FROM pg_constraint constraint_row JOIN pg_class table_row ON table_row.oid=constraint_row.conrelid
  JOIN pg_namespace namespace_row ON namespace_row.oid=table_row.relnamespace
  CROSS JOIN LATERAL unnest(constraint_row.conkey) WITH ORDINALITY AS key_column(attribute_number,position)
  JOIN pg_attribute attribute ON attribute.attrelid=table_row.oid AND attribute.attnum=key_column.attribute_number
  WHERE constraint_row.contype='f' AND namespace_row.nspname='public'
  GROUP BY constraint_row.oid,constraint_row.conrelid,constraint_row.conkey,table_row.relname ORDER BY constraint_row.oid LOOP
  IF NOT EXISTS(SELECT 1 FROM pg_index index_row WHERE index_row.indrelid=reference_row.conrelid AND index_row.indisvalid AND index_row.indpred IS NULL AND
    ARRAY(SELECT attribute_number FROM unnest(index_row.indkey) WITH ORDINALITY AS index_key(attribute_number,position) WHERE position<=cardinality(reference_row.conkey))=reference_row.conkey) THEN
   EXECUTE format('CREATE INDEX %I ON public.%I(%s)','ix_fk_'||reference_row.relname||'_'||substr(md5(reference_row.columns),1,8),reference_row.relname,reference_row.columns);
  END IF;
 END LOOP;
END $$;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC,iot_runtime;

INSERT INTO migration_control.applied_migrations(version,checksum)
    VALUES(:'migration_version',:'migration_checksum');
\echo APPLIED
\else
SELECT checksum=:'migration_checksum' AS checksum_matches
    FROM migration_control.applied_migrations WHERE version=:'migration_version' \gset
\if :checksum_matches
\echo ALREADY_APPLIED
\else
/* Drift phải rollback, không UPDATE checksum để hợp thức hóa lịch sử bị thay đổi. */
DO $$ BEGIN RAISE EXCEPTION 'migration checksum drift'; END $$;
\endif
\endif
COMMIT;

\set migration_version platform-0010-operation-boundaries
\set migration_checksum 9ae2830bc4c8e1fb654fbfe7671ffbcb01e4420199da845dd133947ed3410913

/* Template psql của runner; hai marker chỉ được thay bằng file SQL nguồn trong repo.
 * migration_version/checksum là literal qua :'name', không chèn input vào SQL.
 * DDL và ledger commit cùng nhau; advisory lock dùng chung cho mọi version/runner.
 */
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
SELECT pg_advisory_xact_lock(17001,1);
/* Lịch sử runner lab: lưu checksum và thời điểm áp thật, không chứa credential.
 * Phải chạy trong transaction đã lấy advisory lock; không thay SQLx production history.
 */
CREATE SCHEMA IF NOT EXISTS migration_control;
CREATE TABLE IF NOT EXISTS migration_control.applied_migrations (
    version text PRIMARY KEY,
    checksum text NOT NULL CHECK(checksum ~ '^[0-9a-f]{64}$'),
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

SELECT NOT EXISTS(
    SELECT 1 FROM migration_control.applied_migrations WHERE version=:'migration_version'
) AS should_apply \gset
\if :should_apply
/* Đóng NULL boundary và admission fence của các entry point0009; chỉ forward migration. */
/* Claim bounded lease, NULL không được biến LIMIT thành không giới hạn hoặc tạo lease vô hạn.
 * Input
 * Param: target_consumer — consumer đã cấu hình phía server.
 * Param: lease_seconds — thời gian lease1..300s, không thay expiry nghiệp vụ.
 * Param: batch_limit — số hàng claim1..1000 trong một transaction ngắn.
 * Output: cặp event/generation đã claim; Errors:22023 nếu input không hợp lệ.
 */
CREATE OR REPLACE FUNCTION claim_outbox(target_consumer text,lease_seconds integer,batch_limit integer)
RETURNS TABLE(claimed_event_id uuid,claimed_generation bigint) LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 IF lease_seconds IS NULL OR batch_limit IS NULL OR lease_seconds NOT BETWEEN 1 AND 300 OR batch_limit NOT BETWEEN 1 AND 1000 OR target_consumer IS NULL OR btrim(target_consumer)='' THEN
  RAISE EXCEPTION 'Invalid lease parameters' USING ERRCODE='22023';
 END IF;
 RETURN QUERY WITH candidates AS (
  SELECT consumption.outbox_event_id,consumption.consumer_code FROM public.outbox_consumptions consumption
  WHERE consumption.consumer_code=target_consumer AND consumption.available_at<=clock_timestamp() AND
   (consumption.state IN ('PENDING','RETRY_WAIT') OR (consumption.state='PROCESSING' AND consumption.lease_until<=clock_timestamp()))
  ORDER BY consumption.available_at,consumption.outbox_event_id LIMIT batch_limit FOR UPDATE SKIP LOCKED
 ) UPDATE public.outbox_consumptions consumption SET state='PROCESSING',lease_generation=consumption.lease_generation+1,
  lease_until=clock_timestamp()+make_interval(secs=>lease_seconds),attempt_count=consumption.attempt_count+1
 FROM candidates WHERE(consumption.outbox_event_id,consumption.consumer_code)=(candidates.outbox_event_id,candidates.consumer_code)
 RETURNING consumption.outbox_event_id,consumption.lease_generation;
END $$;

/* Ticket consume lấy cùng User→Workspace fence với mutation membership, khóa phiên trước CAS.
 * Input
 * Param: presented_digest — SHA256 của ticket client, không raw ticket.
 * Output:boolean cho admission thắng và còn quyền; Side effects:consumed_at một lần.
 */
CREATE OR REPLACE FUNCTION consume_websocket_ticket(presented_digest bytea) RETURNS boolean LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE selected_user uuid; selected_workspace uuid; selected_session uuid; BEGIN
 SELECT user_id,workspace_id,session_id INTO selected_user,selected_workspace,selected_session FROM public.websocket_tickets WHERE ticket_digest=presented_digest;
 IF NOT FOUND THEN RETURN false; END IF;
 UPDATE public.users SET account_status=account_status WHERE user_id=selected_user;
 UPDATE public.workspaces SET authorization_version=authorization_version WHERE workspace_id=selected_workspace;
 PERFORM 1 FROM public.sessions WHERE session_id=selected_session FOR SHARE;
 UPDATE public.websocket_tickets ticket SET consumed_at=clock_timestamp()
 FROM public.sessions session_row, public.memberships membership, public.membership_grants grant_row, public.users account,public.workspaces workspace
 WHERE ticket.ticket_digest=presented_digest AND ticket.consumed_at IS NULL AND ticket.revoked_at IS NULL AND ticket.expires_at>clock_timestamp()
 AND session_row.session_id=ticket.session_id AND session_row.user_id=ticket.user_id AND session_row.revoked_at IS NULL AND NOT session_row.limited AND session_row.expires_at>clock_timestamp()
 AND membership.workspace_id=ticket.workspace_id AND membership.user_id=ticket.user_id AND membership.status='ACTIVE'
 AND membership.current_grant_generation=ticket.grant_generation AND membership.authorization_version=ticket.membership_authorization_version
 AND(grant_row.workspace_id,grant_row.user_id,grant_row.grant_generation)=(membership.workspace_id,membership.user_id,membership.current_grant_generation) AND grant_row.revoked_at IS NULL
 AND account.user_id=ticket.user_id AND account.account_status='ACTIVE' AND NOT account.must_change_password
 AND workspace.workspace_id=ticket.workspace_id AND workspace.status='ACTIVE' AND workspace.authorization_version=ticket.workspace_authorization_version;
 RETURN FOUND;
END $$;

/* Purge raw theo cutoff7d, batch không NULL, giữ receipt authority và frontier chưa compact.
 * Input
 * Param: batch_limit — tối đa1..10000 envelope mỗi lượt để giữ lock/transaction có giới hạn.
 * Output:số envelope xóa; Errors:22023 khi batch sai; Side effects:xóa points rồi parent.
 */
CREATE OR REPLACE FUNCTION purge_expired_telemetry(batch_limit integer) RETURNS integer LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE target record; removed_count integer:=0; BEGIN
 IF batch_limit IS NULL OR batch_limit NOT BETWEEN 1 AND 10000 THEN RAISE EXCEPTION 'Invalid retention batch' USING ERRCODE='22023'; END IF;
 SET CONSTRAINTS ct_points_count DEFERRED;
 FOR target IN SELECT workspace_id,envelope_id FROM public.telemetry_envelopes WHERE received_at<=statement_timestamp()-interval '7 days'
  ORDER BY received_at,workspace_id,envelope_id LIMIT batch_limit FOR UPDATE SKIP LOCKED LOOP
  DELETE FROM public.telemetry_points WHERE(workspace_id,envelope_id)=(target.workspace_id,target.envelope_id);
  DELETE FROM public.telemetry_envelopes WHERE(workspace_id,envelope_id)=(target.workspace_id,target.envelope_id);
  removed_count:=removed_count+1;
 END LOOP;
 RETURN removed_count;
END $$;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC,iot_runtime;

INSERT INTO migration_control.applied_migrations(version,checksum)
    VALUES(:'migration_version',:'migration_checksum');
\echo APPLIED
\else
SELECT checksum=:'migration_checksum' AS checksum_matches
    FROM migration_control.applied_migrations WHERE version=:'migration_version' \gset
\if :checksum_matches
\echo ALREADY_APPLIED
\else
/* Drift phải rollback, không UPDATE checksum để hợp thức hóa lịch sử bị thay đổi. */
DO $$ BEGIN RAISE EXCEPTION 'migration checksum drift'; END $$;
\endif
\endif
COMMIT;

\set migration_version platform-0011-final-integrity
\set migration_checksum a3cc62d76433b7e430541aaaa05ae26baeae7b43be770d4698163c221304047b

/* Template psql của runner; hai marker chỉ được thay bằng file SQL nguồn trong repo.
 * migration_version/checksum là literal qua :'name', không chèn input vào SQL.
 * DDL và ledger commit cùng nhau; advisory lock dùng chung cho mọi version/runner.
 */
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
SELECT pg_advisory_xact_lock(17001,1);
/* Lịch sử runner lab: lưu checksum và thời điểm áp thật, không chứa credential.
 * Phải chạy trong transaction đã lấy advisory lock; không thay SQLx production history.
 */
CREATE SCHEMA IF NOT EXISTS migration_control;
CREATE TABLE IF NOT EXISTS migration_control.applied_migrations (
    version text PRIMARY KEY,
    checksum text NOT NULL CHECK(checksum ~ '^[0-9a-f]{64}$'),
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

SELECT NOT EXISTS(
    SELECT 1 FROM migration_control.applied_migrations WHERE version=:'migration_version'
) AS should_apply \gset
\if :should_apply
/* Forward repair từ review: CAS resolution giữ terminal truth, one-time không rewind,
 * latest marker không fallback GOOD cũ, attempt outcome đã xác nhận không bị late reply đảo.
 */
/* Command admission/state bất biến theo contract; revision được tăng khi resolution ACK dùng CAS.
 * Input: OLD/NEW command. Output:NEW; Errors:23514 khi sửa truth, identity hoặc hạ revision.
 */
CREATE OR REPLACE FUNCTION enforce_command_transition() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE definition public.datastream_definitions; candidate jsonb; BEGIN
 IF TG_OP='UPDATE' THEN
  IF (to_jsonb(NEW)-ARRAY['state','outcome','dispatch_intent_at','terminal_at','revision']) IS DISTINCT FROM
     (to_jsonb(OLD)-ARRAY['state','outcome','dispatch_intent_at','terminal_at','revision']) THEN
   RAISE EXCEPTION 'Command admission is immutable' USING ERRCODE='23514',CONSTRAINT='ck_command_admission_immutable';
  END IF;
  IF NEW.revision<OLD.revision THEN RAISE EXCEPTION 'Command revision cannot regress' USING ERRCODE='23514'; END IF;
  IF OLD.state IN ('SUCCEEDED','FAILED','TIMED_OUT','EXPIRED_BEFORE_DISPATCH','CANCELLED') AND
    (to_jsonb(NEW)-'revision') IS DISTINCT FROM (to_jsonb(OLD)-'revision') THEN
   RAISE EXCEPTION 'Command terminal cannot change' USING ERRCODE='23514',CONSTRAINT='ck_command_terminal_immutable';
  END IF;
  IF NEW.state<>OLD.state AND NOT(
   (OLD.state='ADMITTED' AND NEW.state IN ('DISPATCHING','EXPIRED_BEFORE_DISPATCH','CANCELLED')) OR
   (OLD.state='DISPATCHING' AND NEW.state IN ('DISPATCHED','ACCEPTED','SUCCEEDED','FAILED','TIMED_OUT')) OR
   (OLD.state='DISPATCHED' AND NEW.state IN ('ACCEPTED','SUCCEEDED','FAILED','TIMED_OUT')) OR
   (OLD.state='ACCEPTED' AND NEW.state IN ('SUCCEEDED','FAILED','TIMED_OUT'))) THEN
   RAISE EXCEPTION 'Invalid command transition' USING ERRCODE='23514',CONSTRAINT='ck_command_transition';
  END IF;
 ELSE
  IF NEW.state<>'ADMITTED' OR NEW.outcome<>'PENDING' THEN RAISE EXCEPTION 'Command must start admitted' USING ERRCODE='23514'; END IF;
  SELECT stream.* INTO definition FROM public.devices device JOIN public.datastream_definitions stream USING(workspace_id,template_version_id)
  WHERE device.workspace_id=NEW.workspace_id AND device.device_id=NEW.device_id AND stream.stream_key=NEW.stream_key;
  IF definition.data_type IS DISTINCT FROM NEW.value_type THEN RAISE EXCEPTION 'Command type differs from pin' USING ERRCODE='23514',CONSTRAINT='ck_stream_value'; END IF;
  candidate:=coalesce(to_jsonb(NEW.numeric_value),to_jsonb(NEW.boolean_value),to_jsonb(NEW.text_value));
  PERFORM public.assert_stream_value(definition,candidate,true);
  IF EXISTS(SELECT 1 FROM public.actuator_states WHERE(workspace_id,device_id,stream_key)=(NEW.workspace_id,NEW.device_id,NEW.stream_key) AND unresolved_command_id IS NOT NULL) THEN
   RAISE EXCEPTION 'Actuator requires reconciliation' USING ERRCODE='23514',CONSTRAINT='ck_command_unresolved_guard';
  END IF;
 END IF;
 RETURN NEW;
END $$;

/* Mốc consume/revoke/expiry đã ghi chỉ được giữ nguyên; không mở lại one-time capability.
 * Input: OLD/NEW và TG_ARGV là tên timestamp nội bộ. Output:NEW; Errors:23514 nếu đổi mốc đã có.
 */
CREATE FUNCTION enforce_one_way_timestamps() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE column_name text; BEGIN
 FOREACH column_name IN ARRAY TG_ARGV LOOP
  IF to_jsonb(OLD)->column_name<>'null'::jsonb AND to_jsonb(NEW)->column_name IS DISTINCT FROM to_jsonb(OLD)->column_name THEN
   RAISE EXCEPTION 'One-way timestamp cannot be rewritten' USING ERRCODE='23514',CONSTRAINT='ck_one_way_timestamp';
  END IF;
 END LOOP;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_ticket_one_way BEFORE UPDATE ON websocket_tickets FOR EACH ROW EXECUTE FUNCTION enforce_one_way_timestamps('consumed_at','revoked_at');
CREATE TRIGGER tr_invitation_one_way BEFORE UPDATE ON workspace_invitations FOR EACH ROW EXECUTE FUNCTION enforce_one_way_timestamps('used_at','revoked_at','expired_at');
CREATE TRIGGER tr_api_key_one_way BEFORE UPDATE ON api_keys FOR EACH ROW EXECUTE FUNCTION enforce_one_way_timestamps('revoked_at');
CREATE TRIGGER tr_ticket_binding_identity BEFORE UPDATE ON websocket_tickets FOR EACH ROW EXECUTE FUNCTION enforce_identity_columns('ticket_digest','workspace_id','user_id','session_id','grant_generation','workspace_authorization_version','membership_authorization_version','issued_at','expires_at');
CREATE TRIGGER tr_invitation_snapshot_identity BEFORE UPDATE ON workspace_invitations FOR EACH ROW EXECUTE FUNCTION enforce_identity_columns('token_digest','email_normalized','email_digest','role','issued_by_user_id','issuer_grant_generation','issuer_authorization_version','admission_generation','issued_at','expires_at');

/* Latest dành cho rule chỉ được dùng đúng marker hiện hành, không GOOD cũ khi mẫu mới NULL/stale. */
ALTER TABLE device_latest_values ADD CONSTRAINT ck_latest_rule_current_marker
 CHECK(rule_eligible_marker_sequence IS NULL OR rule_eligible_marker_sequence=latest_marker_sequence);
ALTER TABLE device_latest_values ADD CONSTRAINT ck_latest_rule_value_shape
 CHECK((rule_eligible_marker_sequence IS NULL)=(rule_value IS NULL) AND (rule_value IS NULL OR rule_value<>'null'::jsonb));
/* Projection sequence/time không lùi khi nhận out-of-order; ingest owner vẫn chịu atomic receipt.
 * Input: OLD/NEW latest projection. Output:NEW; Errors:23514 khi marker hoặc thời gian bị lùi.
 */
CREATE FUNCTION enforce_latest_sequence() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 IF NEW.latest_marker_sequence<OLD.latest_marker_sequence OR NEW.latest_received_at<OLD.latest_received_at THEN
  RAISE EXCEPTION 'Latest projection cannot regress' USING ERRCODE='23514',CONSTRAINT='ck_latest_sequence_monotonic';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_latest_sequence BEFORE UPDATE ON device_latest_values FOR EACH ROW EXECUTE FUNCTION enforce_latest_sequence();

/* Response đã xác nhận giữ nguyên outcome; UNKNOWN có thể bổ sung quan sát muộn, không rewind parent.
 * Input: OLD/NEW attempt push/webhook. Output:NEW; Errors:23514 nếu đổi outcome đã kết luận.
 */
CREATE FUNCTION enforce_attempt_outcome() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 IF OLD.outcome NOT IN ('INTENT','UNKNOWN') AND NEW.outcome<>OLD.outcome THEN
  RAISE EXCEPTION 'Observed attempt outcome cannot change' USING ERRCODE='23514',CONSTRAINT='ck_attempt_outcome_immutable';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_push_attempt_outcome BEFORE UPDATE ON push_delivery_attempts FOR EACH ROW EXECUTE FUNCTION enforce_attempt_outcome();
CREATE TRIGGER tr_webhook_attempt_outcome BEFORE UPDATE ON webhook_delivery_attempts FOR EACH ROW EXECUTE FUNCTION enforce_attempt_outcome();
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC,iot_runtime;

INSERT INTO migration_control.applied_migrations(version,checksum)
    VALUES(:'migration_version',:'migration_checksum');
\echo APPLIED
\else
SELECT checksum=:'migration_checksum' AS checksum_matches
    FROM migration_control.applied_migrations WHERE version=:'migration_version' \gset
\if :checksum_matches
\echo ALREADY_APPLIED
\else
/* Drift phải rollback, không UPDATE checksum để hợp thức hóa lịch sử bị thay đổi. */
DO $$ BEGIN RAISE EXCEPTION 'migration checksum drift'; END $$;
\endif
\endif
COMMIT;

\set migration_version platform-0012-schema-comments
\set migration_checksum 0bbdd5c18d2133c390bab09c92000efb40069dd1ea86daf19b25154a80e9e7ae

/* Template psql của runner; hai marker chỉ được thay bằng file SQL nguồn trong repo.
 * migration_version/checksum là literal qua :'name', không chèn input vào SQL.
 * DDL và ledger commit cùng nhau; advisory lock dùng chung cho mọi version/runner.
 */
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
SELECT pg_advisory_xact_lock(17001,1);
/* Lịch sử runner lab: lưu checksum và thời điểm áp thật, không chứa credential.
 * Phải chạy trong transaction đã lấy advisory lock; không thay SQLx production history.
 */
CREATE SCHEMA IF NOT EXISTS migration_control;
CREATE TABLE IF NOT EXISTS migration_control.applied_migrations (
    version text PRIMARY KEY,
    checksum text NOT NULL CHECK(checksum ~ '^[0-9a-f]{64}$'),
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

SELECT NOT EXISTS(
    SELECT 1 FROM migration_control.applied_migrations WHERE version=:'migration_version'
) AS should_apply \gset
\if :should_apply
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

INSERT INTO migration_control.applied_migrations(version,checksum)
    VALUES(:'migration_version',:'migration_checksum');
\echo APPLIED
\else
SELECT checksum=:'migration_checksum' AS checksum_matches
    FROM migration_control.applied_migrations WHERE version=:'migration_version' \gset
\if :checksum_matches
\echo ALREADY_APPLIED
\else
/* Drift phải rollback, không UPDATE checksum để hợp thức hóa lịch sử bị thay đổi. */
DO $$ BEGIN RAISE EXCEPTION 'migration checksum drift'; END $$;
\endif
\endif
COMMIT;

\set migration_version platform-0013-publication-integrity
\set migration_checksum 6c23b8ec92991b9b88e9e4f6f6214b517b1de25836155dc4e08a9a6559deafac

/* Template psql của runner; hai marker chỉ được thay bằng file SQL nguồn trong repo.
 * migration_version/checksum là literal qua :'name', không chèn input vào SQL.
 * DDL và ledger commit cùng nhau; advisory lock dùng chung cho mọi version/runner.
 */
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
SELECT pg_advisory_xact_lock(17001,1);
/* Lịch sử runner lab: lưu checksum và thời điểm áp thật, không chứa credential.
 * Phải chạy trong transaction đã lấy advisory lock; không thay SQLx production history.
 */
CREATE SCHEMA IF NOT EXISTS migration_control;
CREATE TABLE IF NOT EXISTS migration_control.applied_migrations (
    version text PRIMARY KEY,
    checksum text NOT NULL CHECK(checksum ~ '^[0-9a-f]{64}$'),
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

SELECT NOT EXISTS(
    SELECT 1 FROM migration_control.applied_migrations WHERE version=:'migration_version'
) AS should_apply \gset
\if :should_apply
/* Sửa seal phiên bản, SAVEPOINT và TTL API key bằng forward migration.
 * ADD COLUMN nullable không backfill payload; ALTER TABLE cần ACCESS EXCLUSIVE ngắn.
 * Runner đặt lock/statement timeout và rollback cả version nếu preflight TTL không đạt.
 * Không gán authority mới cho parent đã tồn tại: marker NULL nghĩa đã chốt, cấm thêm child.
 */
ALTER TABLE public.template_versions
    -- XID 64 bit của transaction tạo parent; NULL cho hàng lịch sử đã chốt trước migration.
    ADD COLUMN publication_transaction_id xid8,
    -- Identity cluster tạo parent, ngăn marker từ logical restore khớp XID của cluster khác.
    ADD COLUMN publication_cluster_id bigint;
ALTER TABLE public.rule_versions
    -- XID transaction trên cùng, dùng chung cả khi parent được tạo trong SAVEPOINT.
    ADD COLUMN publication_transaction_id xid8,
    -- Cluster authority đi cùng XID; không phải workspace hoặc ID do client cung cấp.
    ADD COLUMN publication_cluster_id bigint;
ALTER TABLE public.firmware_packages
    -- Marker transaction tạo canonical package, không đổi khi UPDATE no-op.
    ADD COLUMN publication_transaction_id xid8,
    -- Cluster ban đầu của marker; restore sang cluster khác phải giữ package đã chốt.
    ADD COLUMN publication_cluster_id bigint;
ALTER TABLE public.api_keys
    -- Transaction phát hành key và tập grant, độc lập với revision/last_used_at thay đổi sau đó.
    ADD COLUMN publication_transaction_id xid8,
    -- Cluster phát hành marker, ngăn reuse XID sau logical restore tạo authority giả.
    ADD COLUMN publication_cluster_id bigint;

/* Gán provenance một lần khi INSERT và cấm UPDATE đổi marker để không mở lại parent cũ.
 * Input: NEW/OLD của bốn parent đã định danh bởi trigger.
 * Output: NEW có marker của transaction hiện hành; SAVEPOINT không đổi top-level XID.
 * Errors: 23514 nếu writer cố thay marker sau khi parent đã tồn tại.
 * Side effects: chỉ gán hai thuộc tính vận hành; không network hoặc tạo quyền runtime.
 */
CREATE FUNCTION public.enforce_publication_origin() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
    IF TG_OP='INSERT' THEN
        -- BEFORE INSERT cũng chạy với ON CONFLICT; chỉ hàng INSERT thật giữ marker mới.
        NEW.publication_transaction_id:=pg_current_xact_id();
        SELECT system_identifier INTO NEW.publication_cluster_id FROM pg_control_system();
    ELSIF ROW(NEW.publication_transaction_id,NEW.publication_cluster_id)
        IS DISTINCT FROM ROW(OLD.publication_transaction_id,OLD.publication_cluster_id) THEN
        RAISE EXCEPTION 'Publication origin is immutable'
            USING ERRCODE='23514',CONSTRAINT='ck_publication_origin_immutable';
    END IF;
    RETURN NEW;
END $$;

/* Child chỉ thêm trong transaction thật đã INSERT parent, không dựa xmin của row version.
 * Input: NEW child; TG_ARGV gồm tên parent và khóa từ các trigger do migration tạo.
 * Output: NEW khi marker của đúng parent/workspace khớp cả XID và cluster hiện hành.
 * Errors: 23514 nếu parent cũ/khác transaction; 22023 nếu trigger args ngoài allowlist.
 */
CREATE OR REPLACE FUNCTION public.enforce_published_child_insert() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE created_here boolean;
BEGIN
    -- Identifier chỉ từ allowlist nội bộ; giá trị scope/identity được bind qua USING.
    IF ROW(TG_ARGV[0],TG_ARGV[1]) NOT IN (
        ROW('template_versions','template_version_id'),ROW('rule_versions','rule_version_id'),
        ROW('firmware_packages','firmware_package_id'),ROW('api_keys','api_key_id')) THEN
        RAISE EXCEPTION 'Invalid publication parent' USING ERRCODE='22023';
    END IF;
    EXECUTE format('SELECT publication_transaction_id=pg_current_xact_id() AND publication_cluster_id=(SELECT system_identifier FROM pg_control_system()) FROM public.%I WHERE workspace_id=$1 AND %I=$2',TG_ARGV[0],TG_ARGV[1])
        INTO created_here USING NEW.workspace_id,(to_jsonb(NEW)->>TG_ARGV[1])::uuid;
    IF created_here IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'Published content cannot be extended'
            USING ERRCODE='23514',CONSTRAINT='ck_published_child_sealed';
    END IF;
    RETURN NEW;
END $$;

/* Các parent dùng cùng protocol; không thêm default để không backfill XID vào hàng cũ. */
CREATE TRIGGER tr_publication_origin BEFORE INSERT OR UPDATE ON public.template_versions
    FOR EACH ROW EXECUTE FUNCTION public.enforce_publication_origin();
CREATE TRIGGER tr_publication_origin BEFORE INSERT OR UPDATE ON public.rule_versions
    FOR EACH ROW EXECUTE FUNCTION public.enforce_publication_origin();
CREATE TRIGGER tr_publication_origin BEFORE INSERT OR UPDATE ON public.firmware_packages
    FOR EACH ROW EXECUTE FUNCTION public.enforce_publication_origin();
CREATE TRIGGER tr_publication_origin BEFORE INSERT OR UPDATE ON public.api_keys
    FOR EACH ROW EXECUTE FUNCTION public.enforce_publication_origin();
REVOKE ALL ON FUNCTION public.enforce_publication_origin() FROM PUBLIC,iot_runtime;
REVOKE ALL ON FUNCTION public.enforce_published_child_insert() FROM PUBLIC,iot_runtime;

/* Contract FEAT057: ngày = 86400 giây; interval seconds không trôi theo calendar/DST.
 * Validate constraint mới trước bỏ CHECK cũ; nếu có dữ liệu sai thì rollback, không tự sửa expiry.
 */
ALTER TABLE public.api_keys ADD CONSTRAINT ck_api_keys_fixed_duration_ttl
    CHECK(expires_at>=issued_at+interval '86400 seconds'
      AND expires_at<=issued_at+interval '7776000 seconds') NOT VALID;
ALTER TABLE public.api_keys VALIDATE CONSTRAINT ck_api_keys_fixed_duration_ttl;
ALTER TABLE public.api_keys DROP CONSTRAINT api_keys_check;

/* Native descriptions cho thuộc tính vận hành mới; không có credential hoặc dữ liệu người dùng. */
COMMENT ON COLUMN public.template_versions.publication_transaction_id IS 'XID 64 bit của transaction tạo parent; gán bởi trigger, bất biến khi UPDATE, hỗ trợ SAVEPOINT. NULL ở parent lịch sử nghĩa đã chốt, không được thêm child.';
COMMENT ON COLUMN public.template_versions.publication_cluster_id IS 'Identity cluster PostgreSQL tạo publication marker; kết hợp XID ngăn authority giả khi logical restore sang cluster khác. NULL ở parent lịch sử đã chốt.';
COMMENT ON COLUMN public.rule_versions.publication_transaction_id IS 'XID 64 bit của transaction tạo parent; gán bởi trigger, bất biến khi UPDATE, hỗ trợ SAVEPOINT. NULL ở parent lịch sử nghĩa đã chốt, không được thêm child.';
COMMENT ON COLUMN public.rule_versions.publication_cluster_id IS 'Identity cluster PostgreSQL tạo publication marker; kết hợp XID ngăn authority giả khi logical restore sang cluster khác. NULL ở parent lịch sử đã chốt.';
COMMENT ON COLUMN public.firmware_packages.publication_transaction_id IS 'XID 64 bit của transaction tạo parent; gán bởi trigger, bất biến khi UPDATE, hỗ trợ SAVEPOINT. NULL ở parent lịch sử nghĩa đã chốt, không được thêm child.';
COMMENT ON COLUMN public.firmware_packages.publication_cluster_id IS 'Identity cluster PostgreSQL tạo publication marker; kết hợp XID ngăn authority giả khi logical restore sang cluster khác. NULL ở parent lịch sử đã chốt.';
COMMENT ON COLUMN public.api_keys.publication_transaction_id IS 'XID 64 bit của transaction tạo parent; gán bởi trigger, bất biến khi UPDATE, hỗ trợ SAVEPOINT. NULL ở parent lịch sử nghĩa đã chốt, không được thêm child.';
COMMENT ON COLUMN public.api_keys.publication_cluster_id IS 'Identity cluster PostgreSQL tạo publication marker; kết hợp XID ngăn authority giả khi logical restore sang cluster khác. NULL ở parent lịch sử đã chốt.';

INSERT INTO migration_control.applied_migrations(version,checksum)
    VALUES(:'migration_version',:'migration_checksum');
\echo APPLIED
\else
SELECT checksum=:'migration_checksum' AS checksum_matches
    FROM migration_control.applied_migrations WHERE version=:'migration_version' \gset
\if :checksum_matches
\echo ALREADY_APPLIED
\else
/* Drift phải rollback, không UPDATE checksum để hợp thức hóa lịch sử bị thay đổi. */
DO $$ BEGIN RAISE EXCEPTION 'migration checksum drift'; END $$;
\endif
\endif
COMMIT;

\set migration_version platform-0014-audit-ingestion
\set migration_checksum 93aec6c0b544231827391f5b613145e5c11e2b42ca9f20ca39de2a7125169413

/* Template psql của runner; hai marker chỉ được thay bằng file SQL nguồn trong repo.
 * migration_version/checksum là literal qua :'name', không chèn input vào SQL.
 * DDL và ledger commit cùng nhau; advisory lock dùng chung cho mọi version/runner.
 */
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
SELECT pg_advisory_xact_lock(17001,1);
/* Lịch sử runner lab: lưu checksum và thời điểm áp thật, không chứa credential.
 * Phải chạy trong transaction đã lấy advisory lock; không thay SQLx production history.
 */
CREATE SCHEMA IF NOT EXISTS migration_control;
CREATE TABLE IF NOT EXISTS migration_control.applied_migrations (
    version text PRIMARY KEY,
    checksum text NOT NULL CHECK(checksum ~ '^[0-9a-f]{64}$'),
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

SELECT NOT EXISTS(
    SELECT 1 FROM migration_control.applied_migrations WHERE version=:'migration_version'
) AS should_apply \gset
\if :should_apply
/* Tách thời điểm audit được server lưu khỏi thời điểm sự kiện xảy ra theo FEAT-TN-040 §8.4.
 * Chỉ baseline audit trống: legacy row không có ingestion provenance phải có backfill được review riêng.
 * ACCESS EXCLUSIVE giữ từ preflight tới DDL để không có INSERT chen giữa kiểm trống và thêm cột.
 * Index thường phù hợp baseline trống này; không áp trực tiếp lên audit production đang có dữ liệu.
 * Không sửa byte/checksum0001…0013, không xóa audit hoặc gán occurred_at làm ingestion giả.
 */
LOCK TABLE public.audit_events IN ACCESS EXCLUSIVE MODE;
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM public.audit_events) THEN
  RAISE EXCEPTION 'Audit ingestion migration requires reviewed legacy backfill'
   USING ERRCODE='23514',CONSTRAINT='ck_audit_ingestion_backfill_required';
 END IF;
END $$;

-- Thời điểm server ghi audit, dùng phân trang/retention; không nhận timestamp này từ client hoặc event source.
-- timestamptz lưu thời điểm tuyệt đối; NOT NULL bắt buộc có; DEFAULT lấy thời điểm bắt đầu câu INSERT hiện hành.
-- Native immutable trigger đã có tiếp tục cấm thay cột này sau INSERT.
ALTER TABLE public.audit_events ADD COLUMN created_at timestamptz NOT NULL DEFAULT statement_timestamp();

-- Tenant đứng đầu cho scope; tuple thời gian/UUID giảm dần khớp thứ tự cursor cố định của audit query.
CREATE INDEX ix_audit_workspace_created ON public.audit_events(workspace_id,created_at DESC,audit_event_id DESC);
-- Cutoff trước UUID phục vụ batch purge toàn cục ổn định; không dùng event-time để kéo dài retention.
CREATE INDEX ix_audit_created_retention ON public.audit_events(created_at,audit_event_id);

/* Thêm cột view ở cuối giữ interface cũ; timestamp đúng cutoff vẫn được giữ theo retention30 ngày. */
CREATE OR REPLACE VIEW public.audit_history WITH(security_invoker=true) AS
 SELECT * FROM public.audit_events WHERE created_at>=statement_timestamp()-interval '30 days';

/* Writer chỉ append những cột đã review; không có INSERT table-wide hoặc quyền override created_at.
 * Grant này không cấp SELECT global audit, UPDATE/DELETE hoặc quyền retention cho runtime.
 */
REVOKE INSERT ON public.audit_events FROM iot_runtime;
GRANT INSERT(audit_event_id,workspace_id,actor_user_id,session_id,event_type,outcome,resource_type,resource_id,
 correlation_id,occurred_at,reason_code,redacted_diff,client_type) ON public.audit_events TO iot_runtime;

-- Comment native khớp dictionary để DBeaver/snapshot giải thích đúng ý nghĩa cột và server default.
COMMENT ON COLUMN public.audit_events.created_at IS 'Thời điểm server ghi audit bằng statement_timestamp(); dùng phân trang và retention30 ngày, độc lập occurred_at của sự kiện. Runtime chỉ có column INSERT allowlist không gồm cột này; immutable sau INSERT.';
COMMENT ON COLUMN public.audit_history.created_at IS 'Thời điểm server ghi audit bằng statement_timestamp(); dùng phân trang và retention30 ngày, độc lập occurred_at của sự kiện. Runtime chỉ có column INSERT allowlist không gồm cột này; immutable sau INSERT.';

INSERT INTO migration_control.applied_migrations(version,checksum)
    VALUES(:'migration_version',:'migration_checksum');
\echo APPLIED
\else
SELECT checksum=:'migration_checksum' AS checksum_matches
    FROM migration_control.applied_migrations WHERE version=:'migration_version' \gset
\if :checksum_matches
\echo ALREADY_APPLIED
\else
/* Drift phải rollback, không UPDATE checksum để hợp thức hóa lịch sử bị thay đổi. */
DO $$ BEGIN RAISE EXCEPTION 'migration checksum drift'; END $$;
\endif
\endif
COMMIT;

\set migration_version platform-0015-audit-retention
\set migration_checksum a6169becd5abd7b2280f6f78c7fca9692000d6f7e257d9dd06198c27c53b9f37

/* Template psql của runner; hai marker chỉ được thay bằng file SQL nguồn trong repo.
 * migration_version/checksum là literal qua :'name', không chèn input vào SQL.
 * DDL và ledger commit cùng nhau; advisory lock dùng chung cho mọi version/runner.
 */
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
SELECT pg_advisory_xact_lock(17001,1);
/* Lịch sử runner lab: lưu checksum và thời điểm áp thật, không chứa credential.
 * Phải chạy trong transaction đã lấy advisory lock; không thay SQLx production history.
 */
CREATE SCHEMA IF NOT EXISTS migration_control;
CREATE TABLE IF NOT EXISTS migration_control.applied_migrations (
    version text PRIMARY KEY,
    checksum text NOT NULL CHECK(checksum ~ '^[0-9a-f]{64}$'),
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

SELECT NOT EXISTS(
    SELECT 1 FROM migration_control.applied_migrations WHERE version=:'migration_version'
) AS should_apply \gset
\if :should_apply
/* Lưu run/cutoff và kết quả từng audit-retention batch theo FEAT-TN-040 §8.4.
 * Hai quan hệ BCNF theo grain khai báo: run_id→cutoff; batch_id→run_id/limit/count/completed_at.
 * DDL thêm bảng nhỏ, không backfill/xóa audit và không cấp DELETE cho runtime request.
 * Trigger immutable/truncate tái dùng guard đã áp; chỉ worker có role riêng mới được purge qua adapter.
 */

-- Bảng audit_retention_runs: mỗi run giữ một cutoff đã đóng để restart không làm trôi cửa sổ retention.
CREATE TABLE audit_retention_runs (
    -- UUID của run do coordinator cấp, khóa chính không NULL/không trùng; không chấp nhận UUID nil.
    run_id uuid PRIMARY KEY CHECK(run_id<>'00000000-0000-0000-0000-000000000000'::uuid),
    -- Cutoff UTC server tính lúc start;720 giờ là30 ngày tuyệt đối, không lệch theo DST/TimeZone.
    -- NOT NULL bắt buộc có; CHECK không cho run xóa dữ liệu chưa đủ30 ngày tại thời điểm admission.
    cutoff timestamptz NOT NULL DEFAULT (statement_timestamp()-interval '720 hours'),
    CONSTRAINT ck_audit_retention_cutoff CHECK(cutoff<=statement_timestamp()-interval '720 hours')
);

-- Bảng audit_retention_batches: một result đã commit cho một batch; replay không DELETE thêm audit.
CREATE TABLE audit_retention_batches (
    -- UUID intent của batch, khóa chính chống xử lý lặp; không tự sinh và không chấp nhận UUID nil.
    batch_id uuid PRIMARY KEY CHECK(batch_id<>'00000000-0000-0000-0000-000000000000'::uuid),
    -- Run sở hữu batch; FK giữ cutoff snapshot chung, không cascade xóa kết quả khi run còn được tham chiếu.
    run_id uuid NOT NULL REFERENCES audit_retention_runs,
    -- Cận row tối đa của một transaction; NOT NULL/CHECK1…1000 ngăn batch vô hạn giữ lock lâu.
    batch_limit integer NOT NULL CONSTRAINT ck_audit_retention_batch_limit CHECK(batch_limit BETWEEN 1 AND 1000),
    -- Số audit đã xóa cùng commit result;0 hợp lệ khi chưa có row unlocked, không khẳng định run đã drain.
    removed_count integer NOT NULL CONSTRAINT ck_audit_retention_batch_count CHECK(removed_count BETWEEN 0 AND batch_limit),
    -- Thời điểm server lưu result; chỉ row result hoàn tất mới được INSERT, không có placeholder nửa chừng.
    completed_at timestamptz NOT NULL DEFAULT statement_timestamp()
);

-- FK/run đứng đầu phục vụ kiểm reference, tổng hợp tiến độ và cleanup batch trước run; không index payload.
CREATE INDEX ix_audit_retention_batches_run ON audit_retention_batches(run_id,batch_id);
-- Không rewrite run cutoff hoặc result sau commit, tránh replay trả số liệu khác lần xử lý gốc.
CREATE TRIGGER tr_audit_retention_runs_immutable BEFORE UPDATE ON audit_retention_runs FOR EACH ROW EXECUTE FUNCTION reject_immutable_update();
CREATE TRIGGER tr_audit_retention_batches_immutable BEFORE UPDATE ON audit_retention_batches FOR EACH ROW EXECUTE FUNCTION reject_immutable_update();
-- Tránh TRUNCATE bỏ qua FK/result evidence; retention metadata có cleanup DELETE riêng khi policy được chốt.
CREATE TRIGGER tr_audit_retention_runs_truncate BEFORE TRUNCATE ON audit_retention_runs FOR EACH STATEMENT EXECUTE FUNCTION reject_protected_truncate();
CREATE TRIGGER tr_audit_retention_batches_truncate BEFORE TRUNCATE ON audit_retention_batches FOR EACH STATEMENT EXECUTE FUNCTION reject_protected_truncate();
REVOKE ALL ON audit_retention_runs,audit_retention_batches FROM PUBLIC,iot_runtime;

/* PostgreSQL interval theo ngày có thể lệch DST với timestamptz;720 giờ giữ đúng duration UTC của policy. */
CREATE OR REPLACE VIEW public.audit_history WITH(security_invoker=true) AS
 SELECT * FROM public.audit_events WHERE created_at>=statement_timestamp()-interval '720 hours';

COMMENT ON TABLE public.audit_retention_runs IS 'Run nội bộ của audit retention; mỗi run giữ cutoff UTC đã đóng để restart/retry không làm thay đổi phạm vi xóa. Không chứa audit payload hoặc quyền của user request.';
COMMENT ON COLUMN public.audit_retention_runs.run_id IS 'Identity UUID không nil của một run retention do coordinator cấp; primary key không NULL và không trùng, dùng giữ cutoff cố định qua restart.';
COMMENT ON COLUMN public.audit_retention_runs.cutoff IS 'Cutoff ingestion UTC đã đóng cho run; mặc định serverNow trừ720 giờ, chỉ audit có created_at nhỏ hơn cutoff mới đủ điều kiện purge; đúng cutoff vẫn giữ.';
COMMENT ON TABLE public.audit_retention_batches IS 'Kết quả immutable của từng batch audit purge, commit cùng DELETE audit; batch ID là khóa replay để retry không xóa thêm hoặc trả count giả. Không chứa nội dung audit đã xóa.';
COMMENT ON COLUMN public.audit_retention_batches.batch_id IS 'Identity UUID không nil của intent batch, primary key không NULL/không trùng; retry cùng ID phải giữ run và batch limit gốc.';
COMMENT ON COLUMN public.audit_retention_batches.run_id IS 'Run/cutoff mà batch tham chiếu bằng khóa ngoại; không cascade xóa result và không sao chép cutoff vào từng batch gây lặp phụ thuộc hàm.';
COMMENT ON COLUMN public.audit_retention_batches.batch_limit IS 'Số audit tối đa một transaction được xóa, bắt buộc trong1…1000 để giới hạn lock/runtime; là một phần body identity của batch replay.';
COMMENT ON COLUMN public.audit_retention_batches.removed_count IS 'Số audit thực đã xóa cùng commit với result, trong0…batch_limit;0 không chứng nhận run drain nếu audit đang bị transaction khác khóa.';
COMMENT ON COLUMN public.audit_retention_batches.completed_at IS 'Thời điểm server ghi batch result đã hoàn tất; row chỉ xuất hiện sau commit DELETE cùng metadata, không dùng làm cutoff retention của audit.';

INSERT INTO migration_control.applied_migrations(version,checksum)
    VALUES(:'migration_version',:'migration_checksum');
\echo APPLIED
\else
SELECT checksum=:'migration_checksum' AS checksum_matches
    FROM migration_control.applied_migrations WHERE version=:'migration_version' \gset
\if :checksum_matches
\echo ALREADY_APPLIED
\else
/* Drift phải rollback, không UPDATE checksum để hợp thức hóa lịch sử bị thay đổi. */
DO $$ BEGIN RAISE EXCEPTION 'migration checksum drift'; END $$;
\endif
\endif
COMMIT;

\set migration_version platform-0016-invitation-revision
\set migration_checksum 2e2bd08fab854a39e494044fd075e43d6c634060c36b7c8cd596fc61ba1b3bce

/* Template psql của runner; hai marker chỉ được thay bằng file SQL nguồn trong repo.
 * migration_version/checksum là literal qua :'name', không chèn input vào SQL.
 * DDL và ledger commit cùng nhau; advisory lock dùng chung cho mọi version/runner.
 */
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
SELECT pg_advisory_xact_lock(17001,1);
/* Lịch sử runner lab: lưu checksum và thời điểm áp thật, không chứa credential.
 * Phải chạy trong transaction đã lấy advisory lock; không thay SQLx production history.
 */
CREATE SCHEMA IF NOT EXISTS migration_control;
CREATE TABLE IF NOT EXISTS migration_control.applied_migrations (
    version text PRIMARY KEY,
    checksum text NOT NULL CHECK(checksum ~ '^[0-9a-f]{64}$'),
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

SELECT NOT EXISTS(
    SELECT 1 FROM migration_control.applied_migrations WHERE version=:'migration_version'
) AS should_apply \gset
\if :should_apply
/* Hoàn thiện CAS metadata/revoke và terminal truth của invitation theo WF066.
 * ALTER TABLE giữ ACCESS EXCLUSIVE trong transaction migration ngắn; baseline chỉ áp khi invitation trống.
 * Không sửa SQL/checksum đã áp; không suy revision lịch sử cho dữ liệu legacy hoặc reset capability.
 * Native PK/issuer/token identity và one-way guards hiện có tiếp tục chạy trước constraint validation.
 */
LOCK TABLE public.workspace_invitations IN ACCESS EXCLUSIVE MODE;
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM public.workspace_invitations) THEN
  RAISE EXCEPTION 'Invitation baseline requires reviewed adoption for existing rows'
   USING ERRCODE='23514',CONSTRAINT='ck_invitation_revision_adoption_required';
 END IF;
END $$;

-- Revision metadata dùng If-Match; bigint dương, NOT NULL, DEFAULT1 cho capability mới.
-- UPDATE do native trigger quản lý, caller không tự tăng hoặc ghi đè version.
ALTER TABLE public.workspace_invitations ADD COLUMN revision bigint NOT NULL DEFAULT 1
 CONSTRAINT ck_invitation_revision_positive CHECK(revision>0);

/* Mỗi capability chỉ có một terminal; used phải nằm trong cửa sổ24h, expired không xuất hiện trước deadline.
 * Các nhánh IS NULL xử lý rõ optional timestamp; issued/expires đã NOT NULL nên CHECK không lọt UNKNOWN.
 */
ALTER TABLE public.workspace_invitations ADD CONSTRAINT ck_invitation_terminal_shape CHECK(
 num_nonnulls(used_at,revoked_at,expired_at)<=1 AND
 (used_at IS NULL OR (used_at>=issued_at AND used_at<expires_at)) AND
 (revoked_at IS NULL OR revoked_at>=issued_at) AND
 (expired_at IS NULL OR expired_at>=expires_at)
);

/* Tăng revision đúng một khi nội dung thay đổi để consume/expire/revoke mọi writer đều có CAS version.
 * Input: OLD/NEW invitation dưới row lock; caller phải giữ revision hiện hành trong NEW.
 * Output: NEW với version engine quản lý; no-op giữ version; Errors23514 nếu override/overflow.
 * Không SELECT account, không thay quyền và không ghi secret vào exception/log.
 */
CREATE FUNCTION public.advance_invitation_revision() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog AS $$ BEGIN
 IF NEW.revision IS DISTINCT FROM OLD.revision THEN
  RAISE EXCEPTION 'Invitation revision is engine managed'
   USING ERRCODE='23514',CONSTRAINT='ck_invitation_revision_override';
 END IF;
 IF (to_jsonb(NEW)-'revision') IS DISTINCT FROM (to_jsonb(OLD)-'revision') THEN
  IF OLD.revision=9223372036854775807 THEN
   RAISE EXCEPTION 'Invitation revision exhausted'
    USING ERRCODE='23514',CONSTRAINT='ck_invitation_revision_exhausted';
  END IF;
  NEW.revision:=OLD.revision+1;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_invitation_revision BEFORE UPDATE ON public.workspace_invitations
 FOR EACH ROW EXECUTE FUNCTION public.advance_invitation_revision();
REVOKE ALL ON FUNCTION public.advance_invitation_revision() FROM PUBLIC;

-- Tenant đứng đầu, rồi issued_at/id ổn định cho metadata keyset; trạng thái được tính với server clock tại query.
CREATE INDEX ix_workspace_invitations_created ON public.workspace_invitations(workspace_id,issued_at DESC,invitation_id DESC);
COMMENT ON COLUMN public.workspace_invitations.revision IS 'Revision dương của metadata invitation cho If-Match; mặc định1, engine tự tăng khi row thay đổi, no-op giữ nguyên và caller không được tự ghi đè.';
COMMENT ON FUNCTION public.advance_invitation_revision() IS 'Bảo vệ revision invitation do engine quản lý: thay đổi row tăng đúng1, no-op giữ version; từ chối override/overflow để CAS không bị quay vòng.';

INSERT INTO migration_control.applied_migrations(version,checksum)
    VALUES(:'migration_version',:'migration_checksum');
\echo APPLIED
\else
SELECT checksum=:'migration_checksum' AS checksum_matches
    FROM migration_control.applied_migrations WHERE version=:'migration_version' \gset
\if :checksum_matches
\echo ALREADY_APPLIED
\else
/* Drift phải rollback, không UPDATE checksum để hợp thức hóa lịch sử bị thay đổi. */
DO $$ BEGIN RAISE EXCEPTION 'migration checksum drift'; END $$;
\endif
\endif
COMMIT;

\set migration_version platform-0017-outbox-lease-clock
\set migration_checksum 837b5c55b905f6617ce7fd8961d39f98e781cea800c8f9d0600374266680e152

/* Template psql của runner; hai marker chỉ được thay bằng file SQL nguồn trong repo.
 * migration_version/checksum là literal qua :'name', không chèn input vào SQL.
 * DDL và ledger commit cùng nhau; advisory lock dùng chung cho mọi version/runner.
 */
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
SELECT pg_advisory_xact_lock(17001,1);
/* Lịch sử runner lab: lưu checksum và thời điểm áp thật, không chứa credential.
 * Phải chạy trong transaction đã lấy advisory lock; không thay SQLx production history.
 */
CREATE SCHEMA IF NOT EXISTS migration_control;
CREATE TABLE IF NOT EXISTS migration_control.applied_migrations (
    version text PRIMARY KEY,
    checksum text NOT NULL CHECK(checksum ~ '^[0-9a-f]{64}$'),
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

SELECT NOT EXISTS(
    SELECT 1 FROM migration_control.applied_migrations WHERE version=:'migration_version'
) AS should_apply \gset
\if :should_apply
/* Sửa race settle lease hết hạn trong khi chờ khóa: khóa consumption trước rồi mới đọc clock.
 * CREATE OR REPLACE giữ signature/ACL và dữ liệu hiện hành; không ALTER TABLE, backfill hoặc reset generation.
 * Migration cần khóa catalog function ngắn; worker đã chạy lời gọi cũ phải drain trước rollout production.
 * Không sửa migration0009 đã áp; quyền invoker không đổi, caller vẫn cần SELECT/UPDATE consumption.
 */

/* Hoàn tất riêng một consumer bằng epoch sống sau khi đã lấy row lock theo identity cố định.
 * Input
 * Param: target_event — UUID event đã claim, không tự tạo nghĩa vụ mới khi retry.
 * Param: target_consumer — pipeline nội bộ cấu hình tại worker.
 * Param: expected_generation — epoch receipt phải khớp generation hiện hành.
 * Output: true khi chuyển COMPLETED; false với thiếu row, stale, terminal hoặc lease hết hạn.
 * Side effects: khóa consumption đến commit; chỉ cập nhật state/completed_at/lease_until nếu CAS hợp lệ.
 * Không giữ transaction qua network; clock được đọc trong statement sau khóa, kể cả locker rollback không thay tuple.
 */
CREATE OR REPLACE FUNCTION public.complete_outbox(target_event uuid,target_consumer text,expected_generation bigint)
RETURNS boolean LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 -- Khóa bằng khóa chính, tuyệt đối không dùng predicate clock trước khi chờ row lock.
 PERFORM 1 FROM public.outbox_consumptions
 WHERE outbox_event_id=target_event AND consumer_code=target_consumer FOR UPDATE;
 IF NOT FOUND THEN RETURN false; END IF;
 -- Sau khóa mới xét state/epoch/thời gian; một winner, không cho stale worker settle sau takeover.
 UPDATE public.outbox_consumptions SET state='COMPLETED',completed_at=clock_timestamp(),lease_until=NULL
 WHERE outbox_event_id=target_event AND consumer_code=target_consumer AND state='PROCESSING'
 AND lease_generation=expected_generation AND lease_until>clock_timestamp();
 RETURN FOUND;
END $$;
COMMENT ON FUNCTION public.complete_outbox(uuid,text,bigint) IS 'Khóa consumption trước khi kiểm clock/epoch; complete một consumer chỉ khi lease còn sống sau chờ khóa, stale/expired/terminal trả false và không đổi nghĩa vụ.';

INSERT INTO migration_control.applied_migrations(version,checksum)
    VALUES(:'migration_version',:'migration_checksum');
\echo APPLIED
\else
SELECT checksum=:'migration_checksum' AS checksum_matches
    FROM migration_control.applied_migrations WHERE version=:'migration_version' \gset
\if :checksum_matches
\echo ALREADY_APPLIED
\else
/* Drift phải rollback, không UPDATE checksum để hợp thức hóa lịch sử bị thay đổi. */
DO $$ BEGIN RAISE EXCEPTION 'migration checksum drift'; END $$;
\endif
\endif
COMMIT;

\set migration_version platform-0018-channel-kind
\set migration_checksum 0911d47647999ec1b5919d89fd26c60c9d38792ee0a0b51477403214954e3d12

/* Template psql của runner; hai marker chỉ được thay bằng file SQL nguồn trong repo.
 * migration_version/checksum là literal qua :'name', không chèn input vào SQL.
 * DDL và ledger commit cùng nhau; advisory lock dùng chung cho mọi version/runner.
 */
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
SELECT pg_advisory_xact_lock(17001,1);
/* Lịch sử runner lab: lưu checksum và thời điểm áp thật, không chứa credential.
 * Phải chạy trong transaction đã lấy advisory lock; không thay SQLx production history.
 */
CREATE SCHEMA IF NOT EXISTS migration_control;
CREATE TABLE IF NOT EXISTS migration_control.applied_migrations (
    version text PRIMARY KEY,
    checksum text NOT NULL CHECK(checksum ~ '^[0-9a-f]{64}$'),
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

SELECT NOT EXISTS(
    SELECT 1 FROM migration_control.applied_migrations WHERE version=:'migration_version'
) AS should_apply \gset
\if :should_apply
/* Tách loại kênh TELEMETRY/STATE khỏi direction READ/WRITE/READ_WRITE theo ADR-004.
 * ALTER TABLE giữ ACCESS EXCLUSIVE trên hai relation stream trong transaction migration ngắn.
 * Không backfill/suy loại kênh từ direction; baseline có stream phải dừng để adoption được review riêng.
 * Published snapshot cũ không được rewrite, migration đã áp giữ nguyên checksum.
 */
LOCK TABLE public.template_draft_streams,public.datastream_definitions IN ACCESS EXCLUSIVE MODE;
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM public.template_draft_streams) OR EXISTS(SELECT 1 FROM public.datastream_definitions) THEN
  RAISE EXCEPTION 'Channel kind requires reviewed adoption for existing streams'
   USING ERRCODE='23514',CONSTRAINT='ck_channel_kind_adoption_required';
 END IF;
END $$;

-- Loại dữ liệu nghiệp vụ của từng stream draft: TELEMETRY là số liệu quan sát, STATE là trạng thái.
-- text NOT NULL: bắt buộc caller chọn loại; CHECK giới hạn đúng hai giá trị; không DEFAULT để tránh tự đoán.
-- Thuộc tính này không cấp quyền hoặc tự tạo capability điều khiển, direction vẫn được lưu độc lập.
ALTER TABLE public.template_draft_streams ADD COLUMN channel_kind text NOT NULL
 CONSTRAINT ck_draft_stream_channel_kind CHECK(channel_kind IN ('TELEMETRY','STATE'));

-- Loại kênh được đóng trong definition published để thiết bị tiếp tục dùng đúng schema đã pin.
-- text NOT NULL, CHECK hai giá trị, không DEFAULT; native immutable trigger cấm đổi snapshot sau publish.
-- Publish service phải sao chép từ draft và đưa thuộc tính vào content digest, không suy lại theo runtime.
ALTER TABLE public.datastream_definitions ADD COLUMN channel_kind text NOT NULL
 CONSTRAINT ck_datastream_channel_kind CHECK(channel_kind IN ('TELEMETRY','STATE'));

COMMENT ON COLUMN public.template_draft_streams.channel_kind IS 'Loại kênh TELEMETRY cho số liệu quan sát hoặc STATE cho trạng thái; bắt buộc khai báo tường minh, độc lập với direction và không tự cấp capability hay quyền điều khiển.';
COMMENT ON COLUMN public.datastream_definitions.channel_kind IS 'Loại kênh TELEMETRY cho số liệu quan sát hoặc STATE cho trạng thái; bắt buộc khai báo tường minh, độc lập với direction và không tự cấp capability hay quyền điều khiển.';

INSERT INTO migration_control.applied_migrations(version,checksum)
    VALUES(:'migration_version',:'migration_checksum');
\echo APPLIED
\else
SELECT checksum=:'migration_checksum' AS checksum_matches
    FROM migration_control.applied_migrations WHERE version=:'migration_version' \gset
\if :checksum_matches
\echo ALREADY_APPLIED
\else
/* Drift phải rollback, không UPDATE checksum để hợp thức hóa lịch sử bị thay đổi. */
DO $$ BEGIN RAISE EXCEPTION 'migration checksum drift'; END $$;
\endif
\endif
COMMIT;

\set migration_version platform-0019-device-registration
\set migration_checksum 591d2289a6f6d11e50ce936864e0cac64c936555ea08e2b4b074f956c68920b4

/* Template psql của runner; hai marker chỉ được thay bằng file SQL nguồn trong repo.
 * migration_version/checksum là literal qua :'name', không chèn input vào SQL.
 * DDL và ledger commit cùng nhau; advisory lock dùng chung cho mọi version/runner.
 */
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
SELECT pg_advisory_xact_lock(17001,1);
/* Lịch sử runner lab: lưu checksum và thời điểm áp thật, không chứa credential.
 * Phải chạy trong transaction đã lấy advisory lock; không thay SQLx production history.
 */
CREATE SCHEMA IF NOT EXISTS migration_control;
CREATE TABLE IF NOT EXISTS migration_control.applied_migrations (
    version text PRIMARY KEY,
    checksum text NOT NULL CHECK(checksum ~ '^[0-9a-f]{64}$'),
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

SELECT NOT EXISTS(
    SELECT 1 FROM migration_control.applied_migrations WHERE version=:'migration_version'
) AS should_apply \gset
\if :should_apply
/* Đồng bộ registry với WF007/OQ-DEVICE-002: chưa có authenticated hello thì hardware chưa biết.
 * ALTER TABLE/DROP TRIGGER giữ khóa metadata trong transaction migration ngắn; không backfill hoặc xóa dữ liệu.
 * Giữ nguyên serial/workspace/owner/model/pin bất biến; hardware là observation do DB-10 xác thực, không input HTTP.
 * Các giá trị hardware hiện có được bảo toàn; không sửa checksum migration đã áp.
 */
ALTER TABLE public.devices ALTER COLUMN hardware_revision DROP NOT NULL;

/* Chỉ bỏ observation khỏi identity guard; không mở chuyển tenant, owner hoặc template đã pin. */
DROP TRIGGER tr_device_pin_identity ON public.devices;
CREATE TRIGGER tr_device_pin_identity BEFORE UPDATE ON public.devices
 FOR EACH ROW EXECUTE FUNCTION public.enforce_identity_columns('workspace_id','template_version_id','owner_user_id','serial_number','model');

COMMENT ON COLUMN public.devices.hardware_revision IS 'Revision phần cứng từ authenticated hello/status; NULL khi registry chưa có observation, không lấy từ input đăng ký. Dùng kiểm tương thích firmware, không thuộc identity cloud bất biến.';

INSERT INTO migration_control.applied_migrations(version,checksum)
    VALUES(:'migration_version',:'migration_checksum');
\echo APPLIED
\else
SELECT checksum=:'migration_checksum' AS checksum_matches
    FROM migration_control.applied_migrations WHERE version=:'migration_version' \gset
\if :checksum_matches
\echo ALREADY_APPLIED
\else
/* Drift phải rollback, không UPDATE checksum để hợp thức hóa lịch sử bị thay đổi. */
DO $$ BEGIN RAISE EXCEPTION 'migration checksum drift'; END $$;
\endif
\endif
COMMIT;

\set migration_version platform-0020-auth-ios-client
\set migration_checksum c2a7670b78bb967d986e1ea92635affd3b9485f2f149c3688a3e2ecc887dac22

/* Template psql của runner; hai marker chỉ được thay bằng file SQL nguồn trong repo.
 * migration_version/checksum là literal qua :'name', không chèn input vào SQL.
 * DDL và ledger commit cùng nhau; advisory lock dùng chung cho mọi version/runner.
 */
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
SELECT pg_advisory_xact_lock(17001,1);
/* Lịch sử runner lab: lưu checksum và thời điểm áp thật, không chứa credential.
 * Phải chạy trong transaction đã lấy advisory lock; không thay SQLx production history.
 */
CREATE SCHEMA IF NOT EXISTS migration_control;
CREATE TABLE IF NOT EXISTS migration_control.applied_migrations (
    version text PRIMARY KEY,
    checksum text NOT NULL CHECK(checksum ~ '^[0-9a-f]{64}$'),
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

SELECT NOT EXISTS(
    SELECT 1 FROM migration_control.applied_migrations WHERE version=:'migration_version'
) AS should_apply \gset
\if :should_apply
/* Giữ enum server WEB/ANDROID/IOS theo OQ-AUTH-007, không triển khai iOS UI.
 * Phải áp sau 0019; ALTER CHECK giữ ACCESS EXCLUSIVE và quét hai bảng trong transaction migration.
 * Runner giới hạn lock_timeout 5 giây và statement_timeout 30 giây; không backfill hoặc sửa hàng session/audit.
 * Nếu cần rollback sau khi đã có IOS, phải revoke/hết hạn và xử lý retention các hàng IOS trước migration thu hẹp.
 */
ALTER TABLE public.sessions DROP CONSTRAINT sessions_client_type_check,
 ADD CONSTRAINT sessions_client_type_check CHECK (client_type IN ('WEB','ANDROID','IOS'));

/* Audit giữ IOS là metadata hữu hạn; UNKNOWN tiếp tục dành cho input không nhận diện được. */
ALTER TABLE public.audit_events DROP CONSTRAINT audit_events_client_type_check,
 ADD CONSTRAINT audit_events_client_type_check CHECK (client_type IN ('WEB','ANDROID','IOS','UNKNOWN'));

COMMENT ON COLUMN public.sessions.client_type IS 'Metadata client WEB/ANDROID/IOS; WEB dùng cookie còn ANDROID/IOS dùng bearer. Không chứng thực platform hoặc cấp quyền; session vẫn có TTL 24 giờ và guard hiện hành.';
COMMENT ON COLUMN public.audit_events.client_type IS 'Metadata client WEB/ANDROID/IOS hoặc UNKNOWN khi không nhận diện được. Nhãn hữu hạn phục vụ audit, không cấp quyền hoặc tiết lộ credential.';

/* History view giữ projection và mô tả cùng audit_events để metadata verification không lệch sau migrate. */
COMMENT ON COLUMN public.audit_history.client_type IS 'Metadata client WEB/ANDROID/IOS hoặc UNKNOWN khi không nhận diện được. Nhãn hữu hạn phục vụ audit, không cấp quyền hoặc tiết lộ credential.';

INSERT INTO migration_control.applied_migrations(version,checksum)
    VALUES(:'migration_version',:'migration_checksum');
\echo APPLIED
\else
SELECT checksum=:'migration_checksum' AS checksum_matches
    FROM migration_control.applied_migrations WHERE version=:'migration_version' \gset
\if :checksum_matches
\echo ALREADY_APPLIED
\else
/* Drift phải rollback, không UPDATE checksum để hợp thức hóa lịch sử bị thay đổi. */
DO $$ BEGIN RAISE EXCEPTION 'migration checksum drift'; END $$;
\endif
\endif
COMMIT;

\set migration_version platform-0021-password-change-attempt-buckets
\set migration_checksum c254a30066c2b7420465d181df523f4621d8afc1aed33260420a5fa5b3fcf4e8

/* Template psql của runner; hai marker chỉ được thay bằng file SQL nguồn trong repo.
 * migration_version/checksum là literal qua :'name', không chèn input vào SQL.
 * DDL và ledger commit cùng nhau; advisory lock dùng chung cho mọi version/runner.
 */
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
SELECT pg_advisory_xact_lock(17001,1);
/* Lịch sử runner lab: lưu checksum và thời điểm áp thật, không chứa credential.
 * Phải chạy trong transaction đã lấy advisory lock; không thay SQLx production history.
 */
CREATE SCHEMA IF NOT EXISTS migration_control;
CREATE TABLE IF NOT EXISTS migration_control.applied_migrations (
    version text PRIMARY KEY,
    checksum text NOT NULL CHECK(checksum ~ '^[0-9a-f]{64}$'),
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

SELECT NOT EXISTS(
    SELECT 1 FROM migration_control.applied_migrations WHERE version=:'migration_version'
) AS should_apply \gset
\if :should_apply
/* Tách limiter đổi mật khẩu khỏi login để giới hạn theo User ổn định xuyên session/instance.
 * Bảng mới không backfill; chỉ tạo row khi có lần xác minh sai đầu tiên.
 * PK/FK và CHECK là DDL metadata ngắn, không quét hoặc khóa dữ liệu auth hiện có.
 */
CREATE TABLE public.password_change_attempt_buckets (
    user_id uuid PRIMARY KEY REFERENCES public.users(user_id) ON DELETE CASCADE,
    failure_count integer NOT NULL DEFAULT 0 CHECK (failure_count BETWEEN 0 AND 5),
    window_started_at timestamptz,
    CONSTRAINT password_change_attempt_buckets_coherence CHECK (
        (failure_count = 0 AND window_started_at IS NULL)
        OR (failure_count > 0 AND window_started_at IS NOT NULL)
    )
);

/* User ID là identity của bucket và không thể được chuyển sang account khác qua UPDATE. */
CREATE TRIGGER tr_password_change_attempt_bucket_identity
BEFORE UPDATE ON public.password_change_attempt_buckets
FOR EACH ROW EXECUTE FUNCTION public.enforce_identity_columns('user_id');

COMMENT ON TABLE public.password_change_attempt_buckets IS
    'Bộ đếm sai currentPassword riêng theo User ID; PostgreSQL khóa nguyên tử để chia sẻ giới hạn đổi mật khẩu giữa session và instance.';
COMMENT ON COLUMN public.password_change_attempt_buckets.user_id IS
    'User sở hữu limiter đổi mật khẩu; khóa ngoại giữ bucket gắn đúng account và không dùng email, session hoặc IP làm định danh.';
COMMENT ON COLUMN public.password_change_attempt_buckets.failure_count IS
    'Số lần currentPassword sai trong fixed window hiện hành, miền 0..5; count 0 đi cùng window_started_at NULL.';
COMMENT ON COLUMN public.password_change_attempt_buckets.window_started_at IS
    'Thời điểm failure đầu tiên mở fixed window 15 phút; không trượt khi retry hoặc nhận 429, NULL khi bucket rỗng.';

INSERT INTO migration_control.applied_migrations(version,checksum)
    VALUES(:'migration_version',:'migration_checksum');
\echo APPLIED
\else
SELECT checksum=:'migration_checksum' AS checksum_matches
    FROM migration_control.applied_migrations WHERE version=:'migration_version' \gset
\if :checksum_matches
\echo ALREADY_APPLIED
\else
/* Drift phải rollback, không UPDATE checksum để hợp thức hóa lịch sử bị thay đổi. */
DO $$ BEGIN RAISE EXCEPTION 'migration checksum drift'; END $$;
\endif
\endif
COMMIT;

\set migration_version platform-0022-template-version-revisions
\set migration_checksum 7dae7852cf56d008fda0c3eae0821cecdb24e947467450192eb028d0c8726e3a

/* Template psql của runner; hai marker chỉ được thay bằng file SQL nguồn trong repo.
 * migration_version/checksum là literal qua :'name', không chèn input vào SQL.
 * DDL và ledger commit cùng nhau; advisory lock dùng chung cho mọi version/runner.
 */
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
SELECT pg_advisory_xact_lock(17001,1);
/* Lịch sử runner lab: lưu checksum và thời điểm áp thật, không chứa credential.
 * Phải chạy trong transaction đã lấy advisory lock; không thay SQLx production history.
 */
CREATE SCHEMA IF NOT EXISTS migration_control;
CREATE TABLE IF NOT EXISTS migration_control.applied_migrations (
    version text PRIMARY KEY,
    checksum text NOT NULL CHECK(checksum ~ '^[0-9a-f]{64}$'),
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

SELECT NOT EXISTS(
    SELECT 1 FROM migration_control.applied_migrations WHERE version=:'migration_version'
) AS should_apply \gset
\if :should_apply
/* Tách revision draft trước publish khỏi revision root sau publish.
 * Row cũ được giữ unknown; CHECK NOT VALID bảo vệ mọi row mới mà không bịa provenance
 * lịch sử từ root mutable hoặc thứ tự version.
 */
ALTER TABLE public.template_versions
    ADD COLUMN source_revision bigint,
    ADD COLUMN published_root_revision bigint;

ALTER TABLE public.template_versions
    ADD CONSTRAINT template_versions_revision_provenance
    CHECK (
        source_revision IS NOT NULL
        AND source_revision > 0
        AND published_root_revision IS NOT NULL
        AND published_root_revision > source_revision
        AND published_root_revision - source_revision = 1
    ) NOT VALID;

COMMENT ON COLUMN public.template_versions.source_revision IS
    'Revision draft root trước publication; NULL trên version cũ khi chưa lưu provenance đáng tin cậy.';
COMMENT ON COLUMN public.template_versions.published_root_revision IS
    'Revision root được publication commit; NULL trên version cũ khi không chứng minh được trạng thái root lịch sử.';

INSERT INTO migration_control.applied_migrations(version,checksum)
    VALUES(:'migration_version',:'migration_checksum');
\echo APPLIED
\else
SELECT checksum=:'migration_checksum' AS checksum_matches
    FROM migration_control.applied_migrations WHERE version=:'migration_version' \gset
\if :checksum_matches
\echo ALREADY_APPLIED
\else
/* Drift phải rollback, không UPDATE checksum để hợp thức hóa lịch sử bị thay đổi. */
DO $$ BEGIN RAISE EXCEPTION 'migration checksum drift'; END $$;
\endif
\endif
COMMIT;
