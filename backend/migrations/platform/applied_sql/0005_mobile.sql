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
