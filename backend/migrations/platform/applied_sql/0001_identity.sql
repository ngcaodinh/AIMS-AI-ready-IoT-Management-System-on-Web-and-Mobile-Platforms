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
