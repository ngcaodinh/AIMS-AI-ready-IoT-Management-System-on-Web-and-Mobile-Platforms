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
