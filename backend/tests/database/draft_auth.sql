/* Kiểm baseline0001 và các guard0002 trên PostgreSQL17 đã provision riêng.
 * Fixture tổng hợp dùng verifier không đăng nhập được; mọi thay đổi rollback cuối file.
 * Chỉ migrator lab chạy; không cài routine kiểm thử vào schema ứng dụng.
 */
BEGIN;
SET LOCAL statement_timeout='15s';
SET LOCAL lock_timeout='5s';
SET LOCAL TIME ZONE 'UTC';
CREATE TEMP TABLE test_results(test_name text PRIMARY KEY, status text NOT NULL) ON COMMIT DROP;

/* Chứng minh câu SQL nội bộ bị từ chối bằng đúng SQLSTATE, tránh PASS vì lỗi khác.
 * Input: test_name là tên ca; statement là SQL fixture cố định; expected_state là SQLSTATE.
 * Output: thêm một PASS; Errors: sai/mất lỗi kỳ vọng; Side effects: rollback riêng mutation lỗi.
 */
CREATE FUNCTION pg_temp.expect_error(test_name text, statement text, expected_state text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE actual_state text;
BEGIN
    BEGIN
        -- EXECUTE chỉ dùng chuỗi fixture cố định trong file này, không nhận input ứng dụng.
        EXECUTE statement;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS actual_state=RETURNED_SQLSTATE;
    END;
    IF actual_state IS DISTINCT FROM expected_state THEN
        RAISE EXCEPTION 'Test % expected SQLSTATE %, got %', test_name, expected_state, actual_state;
    END IF;
    INSERT INTO test_results VALUES(test_name,'PASS');
END $$;

/* Kiểm positive control bằng biểu thức rõ NULL để phân biệt dữ liệu hợp lệ với test không chạy.
 * Input: test_name là tên ca; condition phải TRUE. Errors: FALSE/NULL làm dừng psql.
 */
CREATE FUNCTION pg_temp.expect_true(test_name text, condition boolean)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF condition IS DISTINCT FROM TRUE THEN
        RAISE EXCEPTION 'Positive control failed: %', test_name;
    END IF;
    INSERT INTO test_results VALUES(test_name,'PASS');
END $$;

-- Dữ liệu này không phải seed sử dụng thật; password_hash là marker không phải hash xác thực.
INSERT INTO users(id,email_normalized,password_hash,status) VALUES
('00000000-0000-0000-0000-000000000001','synthetic-one@example.invalid','synthetic-non-authenticating-verifier','ACTIVE'),
('00000000-0000-0000-0000-000000000002','synthetic-two@example.invalid','synthetic-non-authenticating-verifier','ACTIVE');
INSERT INTO workspaces(id,name,created_by) VALUES
('00000000-0000-0000-0000-000000000101','Synthetic workspace A','00000000-0000-0000-0000-000000000001'),
('00000000-0000-0000-0000-000000000102','Synthetic workspace B','00000000-0000-0000-0000-000000000002');
INSERT INTO memberships(workspace_id,user_id,role) VALUES
('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000001','ADMIN'),
('00000000-0000-0000-0000-000000000102','00000000-0000-0000-0000-000000000002','ADMIN'),
('00000000-0000-0000-0000-000000000102','00000000-0000-0000-0000-000000000001','USER');
INSERT INTO sessions(id,user_id,token_digest,auth_context_id,client_type,limited,created_at,expires_at) VALUES
('00000000-0000-0000-0000-000000000201','00000000-0000-0000-0000-000000000001',decode(repeat('01',32),'hex'),'00000000-0000-0000-0000-000000000301','WEB',false,'2026-10-23T00:00:00Z','2026-10-24T00:00:00Z');
INSERT INTO audit_events(id,actor_id,session_id,workspace_id,event_type,outcome,client_type,correlation_id) VALUES
('00000000-0000-0000-0000-000000000401','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000201','00000000-0000-0000-0000-000000000101','SYNTHETIC_TEST','SUCCESS','WEB','00000000-0000-0000-0000-000000000501');

SELECT pg_temp.expect_true('seven_application_tables',(SELECT count(*)=7 FROM pg_tables WHERE schemaname='public'));
SELECT pg_temp.expect_true('two_workspace_positive_control',(SELECT count(*)=2 FROM workspaces));
SELECT pg_temp.expect_true('membership_scope_positive_control',(SELECT count(*)=1 FROM memberships WHERE workspace_id='00000000-0000-0000-0000-000000000101'));
SELECT pg_temp.expect_error('unique_user_identity',$q$INSERT INTO users SELECT * FROM users LIMIT 1$q$,'23505');
SELECT pg_temp.expect_error('unique_canonical_email',$q$INSERT INTO users(id,email_normalized,password_hash,status) VALUES('00000000-0000-0000-0000-000000000003','synthetic-one@example.invalid','synthetic-non-authenticating-verifier','ACTIVE')$q$,'23505');
SELECT pg_temp.expect_error('account_status_domain',$q$UPDATE users SET status='ADMIN'$q$,'23514');
SELECT pg_temp.expect_error('positive_preferences_revision',$q$UPDATE users SET preferences_revision=0$q$,'23514');
SELECT pg_temp.expect_error('session_digest_length',$q$INSERT INTO sessions SELECT '00000000-0000-0000-0000-000000000202',user_id,decode('02','hex'),'00000000-0000-0000-0000-000000000302',client_type,limited,created_at,expires_at,revoked_at FROM sessions$q$,'23514');
SELECT pg_temp.expect_error('session_ttl_24h',$q$INSERT INTO sessions SELECT '00000000-0000-0000-0000-000000000202',user_id,decode(repeat('02',32),'hex'),'00000000-0000-0000-0000-000000000302',client_type,limited,created_at,created_at+interval '25 hours',revoked_at FROM sessions$q$,'23514');
SELECT pg_temp.expect_error('session_requires_existing_user',$q$INSERT INTO sessions SELECT '00000000-0000-0000-0000-000000000202','00000000-0000-0000-0000-000000000099',decode(repeat('02',32),'hex'),'00000000-0000-0000-0000-000000000302',client_type,limited,created_at,expires_at,revoked_at FROM sessions$q$,'23503');
SELECT pg_temp.expect_error('unique_session_token',$q$INSERT INTO sessions SELECT '00000000-0000-0000-0000-000000000202',user_id,token_digest,'00000000-0000-0000-0000-000000000302',client_type,limited,created_at,expires_at,revoked_at FROM sessions$q$,'23505');
SELECT pg_temp.expect_error('unique_auth_context',$q$INSERT INTO sessions SELECT '00000000-0000-0000-0000-000000000202',user_id,decode(repeat('02',32),'hex'),auth_context_id,client_type,limited,created_at,expires_at,revoked_at FROM sessions$q$,'23505');
SELECT pg_temp.expect_error('limiter_counter_bound',$q$INSERT INTO login_attempts(email_digest,failure_count,window_started_at) VALUES(decode(repeat('03',32),'hex'),6,clock_timestamp())$q$,'23514');
SELECT pg_temp.expect_error('limiter_digest_length',$q$INSERT INTO login_attempts(email_digest,failure_count) VALUES(decode('03','hex'),0)$q$,'23514');
SELECT pg_temp.expect_error('workspace_name_not_blank',$q$UPDATE workspaces SET name='   '$q$,'23514');
SELECT pg_temp.expect_error('workspace_status_domain',$q$UPDATE workspaces SET status='DELETED'$q$,'23514');
SELECT pg_temp.expect_error('workspace_revision_positive',$q$UPDATE workspaces SET revision=0$q$,'23514');
SELECT pg_temp.expect_error('unique_membership',$q$INSERT INTO memberships SELECT * FROM memberships LIMIT 1$q$,'23505');
SELECT pg_temp.expect_error('membership_role_domain',$q$UPDATE memberships SET role='OWNER'$q$,'23514');
SELECT pg_temp.expect_error('membership_requires_workspace',$q$INSERT INTO memberships(workspace_id,user_id,role) VALUES('00000000-0000-0000-0000-000000000199','00000000-0000-0000-0000-000000000001','USER')$q$,'23503');
SELECT pg_temp.expect_error('membership_requires_user',$q$INSERT INTO memberships(workspace_id,user_id,role) VALUES('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000099','USER')$q$,'23503');
SELECT pg_temp.expect_error('audit_requires_session',$q$UPDATE audit_events SET session_id='00000000-0000-0000-0000-000000000299'$q$,'23503');
SELECT pg_temp.expect_error('session_delete_preserves_audit',$q$DELETE FROM sessions$q$,'23503');
SELECT pg_temp.expect_error('invalid_signing_key_length',$q$INSERT INTO auth_settings(signing_key) VALUES(decode('00','hex'))$q$,'23514');
SELECT pg_temp.expect_error('statement_batch_is_atomic',$q$INSERT INTO users(id,email_normalized,password_hash,status) VALUES('00000000-0000-0000-0000-000000000004','synthetic-atomic@example.invalid','synthetic-non-authenticating-verifier','ACTIVE'); INSERT INTO memberships(workspace_id,user_id,role) VALUES('00000000-0000-0000-0000-000000000199','00000000-0000-0000-0000-000000000004','USER')$q$,'23503');
SELECT pg_temp.expect_true('failed_batch_left_no_user',(SELECT count(*)=0 FROM users WHERE id='00000000-0000-0000-0000-000000000004'));

-- Không chấp nhận GAP sau0002: mọi ca dưới phải bị engine chặn bằng đúng SQLSTATE.
SELECT pg_temp.expect_error('positive_failure_requires_window',$q$INSERT INTO login_attempts(email_digest,failure_count,window_started_at) VALUES(decode(repeat('04',32),'hex'),1,NULL)$q$,'23514');
SELECT pg_temp.expect_error('zero_failure_has_no_window',$q$INSERT INTO login_attempts(email_digest,failure_count,window_started_at) VALUES(decode(repeat('04',32),'hex'),0,clock_timestamp())$q$,'23514');
INSERT INTO login_attempts(email_digest,failure_count,window_started_at) VALUES(decode(repeat('04',32),'hex'),1,clock_timestamp());
SELECT pg_temp.expect_true('positive_failure_window_positive_control',(SELECT count(*)=1 FROM login_attempts));
SELECT pg_temp.expect_error('session_identity_immutable',$q$UPDATE sessions SET user_id='00000000-0000-0000-0000-000000000002'$q$,'23514');
SELECT pg_temp.expect_error('full_session_admission_immutable',$q$UPDATE sessions SET limited=true$q$,'23514');
INSERT INTO sessions(id,user_id,token_digest,auth_context_id,client_type,limited,created_at,expires_at) VALUES
('00000000-0000-0000-0000-000000000203','00000000-0000-0000-0000-000000000002',decode(repeat('03',32),'hex'),'00000000-0000-0000-0000-000000000303','WEB',true,'2026-10-23T00:00:00Z','2026-10-24T00:00:00Z');
SELECT pg_temp.expect_error('limited_session_upgrade_guard',$q$UPDATE sessions SET limited=false WHERE id='00000000-0000-0000-0000-000000000203'$q$,'23514');
UPDATE sessions SET revoked_at='2026-10-23T01:00:00Z' WHERE id='00000000-0000-0000-0000-000000000203';
SELECT pg_temp.expect_error('session_revocation_cannot_rewind',$q$UPDATE sessions SET revoked_at=NULL WHERE id='00000000-0000-0000-0000-000000000203'$q$,'23514');
SELECT pg_temp.expect_error('audit_actor_session_binding',$q$UPDATE audit_events SET actor_id='00000000-0000-0000-0000-000000000002'$q$,'23503');
SELECT pg_temp.expect_error('audit_session_requires_actor',$q$UPDATE audit_events SET actor_id=NULL$q$,'23514');
INSERT INTO audit_events(id,event_type,outcome,client_type,correlation_id) VALUES
('00000000-0000-0000-0000-000000000402','SYNTHETIC_GLOBAL_AUTH','FAILURE','UNKNOWN','00000000-0000-0000-0000-000000000502');
SELECT pg_temp.expect_true('anonymous_global_audit_positive_control',(SELECT count(*)=1 FROM audit_events WHERE actor_id IS NULL AND session_id IS NULL AND workspace_id IS NULL));

-- Deferred guard kiểm trạng thái cuối transaction, hỗ trợ tạo workspace+Admin và handoff.
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
SELECT pg_temp.expect_error('last_active_admin_guard',$q$UPDATE memberships SET role='USER' WHERE workspace_id='00000000-0000-0000-0000-000000000101'; SET CONSTRAINTS ALL IMMEDIATE$q$,'23514');
SELECT pg_temp.expect_error('last_admin_delete_guard',$q$DELETE FROM memberships WHERE workspace_id='00000000-0000-0000-0000-000000000101'; SET CONSTRAINTS ALL IMMEDIATE$q$,'23514');
SELECT pg_temp.expect_error('last_admin_suspend_guard',$q$UPDATE memberships SET status='SUSPENDED' WHERE workspace_id='00000000-0000-0000-0000-000000000101'; SET CONSTRAINTS ALL IMMEDIATE$q$,'23514');
SELECT pg_temp.expect_error('membership_truncate_cannot_bypass_guard',$q$TRUNCATE memberships$q$,'23514');
SELECT pg_temp.expect_error('disabled_account_not_capable_admin',$q$UPDATE users SET status='DISABLED' WHERE id='00000000-0000-0000-0000-000000000001'; SET CONSTRAINTS ALL IMMEDIATE$q$,'23514');
SELECT pg_temp.expect_error('temporary_account_not_capable_admin',$q$UPDATE users SET must_change_password=true WHERE id='00000000-0000-0000-0000-000000000001'; SET CONSTRAINTS ALL IMMEDIATE$q$,'23514');
SELECT pg_temp.expect_error('workspace_requires_first_capable_admin',$q$INSERT INTO workspaces(id,name,created_by) VALUES('00000000-0000-0000-0000-000000000103','Synthetic empty workspace','00000000-0000-0000-0000-000000000001'); SET CONSTRAINTS ALL IMMEDIATE$q$,'23514');
INSERT INTO memberships(workspace_id,user_id,role) VALUES('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000002','USER');
UPDATE memberships SET role='USER' WHERE workspace_id='00000000-0000-0000-0000-000000000101' AND user_id='00000000-0000-0000-0000-000000000001';
UPDATE memberships SET role='ADMIN' WHERE workspace_id='00000000-0000-0000-0000-000000000101' AND user_id='00000000-0000-0000-0000-000000000002';
SET CONSTRAINTS ALL IMMEDIATE;
SELECT pg_temp.expect_true('deferred_admin_handoff_positive_control',(SELECT count(*)=1 FROM memberships WHERE workspace_id='00000000-0000-0000-0000-000000000101' AND role='ADMIN' AND status='ACTIVE'));
SELECT status || ':' || test_name FROM test_results ORDER BY status,test_name;
ROLLBACK;
