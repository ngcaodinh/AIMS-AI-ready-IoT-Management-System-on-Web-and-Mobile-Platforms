/* Hai tenant có grant đầy đủ là positive control của deferred pointer. */
SELECT CASE WHEN count(*)=2 THEN 'PASS:identity_two_workspaces' ELSE 'FAIL:identity_two_workspaces' END FROM workspaces;
SELECT pg_temp.rejects('identity_bucket_missing_window',
 $$INSERT INTO login_attempt_buckets VALUES(decode(repeat('01',32),'hex'),1,NULL)$$,'23514','ck_login_bucket_coherence');
SELECT pg_temp.rejects('identity_cross_workspace_reset',
 $$INSERT INTO password_reset_admissions VALUES('00000000-0000-0000-0000-000000000501','00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001',now())$$,'23503');
SELECT pg_temp.rejects('identity_grant_generation_unique',
 $$INSERT INTO membership_grants(workspace_id,user_id,grant_generation) VALUES('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000001',2)$$,'23505','uq_membership_grants_current');
/* Enum lạ vẫn bị chặn; IOS là bearer contract server tại OQ007 dù UI iOS ngoài scope. */
SELECT pg_temp.rejects('identity_unknown_client_rejected',
 $$INSERT INTO sessions(session_id,user_id,token_digest,auth_context_id,limited,client_type,issued_at,expires_at) VALUES('00000000-0000-0000-0000-000000000401','00000000-0000-0000-0000-000000000001',decode(repeat('01',32),'hex'),'00000000-0000-0000-0000-000000000402',false,'ATTACKER',now(),now()+interval '24 hours')$$,'23514');

/* Savepoint giữ fixture gốc khi positive IOS kiểm đủ constraint và TTL24h trên engine. */
SAVEPOINT ios_contract;
INSERT INTO sessions(session_id,user_id,token_digest,auth_context_id,limited,client_type,issued_at,expires_at)
 VALUES('00000000-0000-0000-0000-000000000401','00000000-0000-0000-0000-000000000001',decode(repeat('01',32),'hex'),'00000000-0000-0000-0000-000000000402',false,'IOS',now(),now()+interval '24 hours');
SELECT CASE WHEN count(*)=1 THEN 'PASS:identity_ios_bearer_client' ELSE 'FAIL:identity_ios_bearer_client' END
 FROM sessions WHERE session_id='00000000-0000-0000-0000-000000000401' AND client_type='IOS' AND expires_at=issued_at+interval '24 hours';
ROLLBACK TO SAVEPOINT ios_contract;
