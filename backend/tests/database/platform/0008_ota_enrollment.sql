/* RECOVERY_REQUIRED giữ slot dù đã quá deadline; không suy timeout là rollback proof. */
INSERT INTO ota_jobs(workspace_id,ota_job_id,device_id,firmware_package_id,source_firmware_version_snapshot,target_artifact_digest_snapshot,job_nonce,state,phase,maintenance_epoch,admitted_at,deadline_at)
 VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(1501),pg_temp.fixture_id(301),pg_temp.fixture_id(1401),'0.9',decode(repeat('13',32),'hex'),decode(repeat('15',32),'hex'),'RECOVERY_REQUIRED','HEALTH_CHECK',1,now(),now()+interval '10 minutes');
SELECT pg_temp.rejects('ota_recovery_holds_workspace_quota', $$INSERT INTO ota_jobs(workspace_id,ota_job_id,device_id,firmware_package_id,source_firmware_version_snapshot,target_artifact_digest_snapshot,job_nonce,state,phase,maintenance_epoch,admitted_at,deadline_at) VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(1502),pg_temp.fixture_id(302),pg_temp.fixture_id(1401),'0.9',decode(repeat('13',32),'hex'),decode(repeat('16',32),'hex'),'QUEUED','QUEUED',1,now(),now()+interval '10 minutes')$$,'23505','uq_ota_jobs_active_workspace');
SELECT pg_temp.rejects('ota_cannot_settle_recovery_without_result', $$UPDATE ota_jobs SET settled_at=now()$$,'23514','ck_ota_settlement');
SELECT pg_temp.rejects('ota_ticket_cannot_outlive_job', $$INSERT INTO ota_download_tickets VALUES(pg_temp.fixture_id(1511),decode(repeat('16',32),'hex'),pg_temp.fixture_id(101),pg_temp.fixture_id(1501),now(),now()+interval '11 minutes',NULL)$$,'23514','ck_ota_ticket_expiry');
SELECT pg_temp.rejects('firmware_manifest_bytes_immutable', $$UPDATE firmware_packages SET raw_manifest=decode('01','hex')$$,'23514','ck_record_immutable');
/* Installation onboarding không có FK tới push, hoạt động khi người dùng từ chối push. */
INSERT INTO enrollment_sessions(workspace_id,enrollment_session_id,device_id,actor_user_id,actor_grant_generation,client_installation_id,enrollment_proof_digest,mode,started_at,expires_at)
 VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(1601),pg_temp.fixture_id(302),pg_temp.fixture_id(1),1,pg_temp.fixture_id(1699),decode(repeat('16',32),'hex'),'INITIAL',now(),now()+interval '10 minutes');
INSERT INTO device_enrollment_guards VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(302),pg_temp.fixture_id(1601),now());
SELECT CASE WHEN count(*)=1 THEN 'PASS:enrollment_independent_of_push_permission' ELSE 'FAIL:enrollment_independent_of_push_permission' END FROM enrollment_sessions;
SELECT pg_temp.rejects('enrollment_guard_same_device_only', $$INSERT INTO device_enrollment_guards VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(303),pg_temp.fixture_id(1601),now())$$,'23503');
UPDATE enrollment_sessions SET state='EXPIRED';
SELECT CASE WHEN count(*)=1 THEN 'PASS:enrollment_expiry_keeps_guard' ELSE 'FAIL:enrollment_expiry_keeps_guard' END FROM device_enrollment_guards;
