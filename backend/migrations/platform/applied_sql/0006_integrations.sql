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
