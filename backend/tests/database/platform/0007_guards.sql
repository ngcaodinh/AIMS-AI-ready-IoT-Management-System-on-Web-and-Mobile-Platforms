/* Các ca này thất bại khi trigger bảo vệ chưa được áp, tránh chỉ kiểm có bảng. */
SELECT pg_temp.rejects('last_admin_cannot_demote', $$UPDATE memberships SET role='USER' WHERE user_id='00000000-0000-0000-0000-000000000001'$$,'23514','ck_workspaces_capable_admin');
INSERT INTO sessions(session_id,user_id,token_digest,auth_context_id,limited,client_type,issued_at,expires_at) VALUES
 ('00000000-0000-0000-0000-000000000401','00000000-0000-0000-0000-000000000001',decode(repeat('05',32),'hex'),'00000000-0000-0000-0000-000000000402',true,'WEB',now(),now()+interval '24 hours');
SELECT pg_temp.rejects('session_cannot_upgrade_limited', $$UPDATE sessions SET limited=false$$,'23514','ck_sessions_identity_immutable');
UPDATE sessions SET revoked_at=now();
SELECT pg_temp.rejects('session_cannot_unrevoke', $$UPDATE sessions SET revoked_at=NULL$$,'23514','ck_sessions_revocation_monotonic');
SELECT pg_temp.rejects('grant_cannot_rewrite_identity', $$UPDATE membership_grants SET issued_at=issued_at+interval '1 second'$$,'23514','ck_grant_immutable');
SELECT pg_temp.rejects('membership_cannot_truncate', $$TRUNCATE memberships CASCADE$$,'23514','ck_protected_truncate');
