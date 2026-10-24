/* Push dedupe không chứa binding_generation; login lại không tạo lần giao thứhai. */
INSERT INTO push_deliveries(workspace_id,push_delivery_id,notification_id,installation_id,recipient_user_id,binding_generation,created_at,expires_at)
 VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(1311),pg_temp.fixture_id(1211),pg_temp.fixture_id(1301),pg_temp.fixture_id(1),1,now(),now()+interval '1 hour');
UPDATE push_installations SET binding_generation=2;
SELECT pg_temp.rejects('push_rebind_does_not_reopen_fanout', $$INSERT INTO push_deliveries(workspace_id,push_delivery_id,notification_id,installation_id,recipient_user_id,binding_generation,created_at,expires_at) VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(1312),pg_temp.fixture_id(1211),pg_temp.fixture_id(1301),pg_temp.fixture_id(1),2,now(),now()+interval '1 hour')$$,'23505');
SELECT pg_temp.rejects('push_expiry_uses_notification_creation', $$INSERT INTO push_deliveries(workspace_id,push_delivery_id,notification_id,installation_id,recipient_user_id,binding_generation,created_at,expires_at) VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(1312),pg_temp.fixture_id(1211),pg_temp.fixture_id(1301),pg_temp.fixture_id(1),2,now()+interval '1 minute',now()+interval '61 minutes')$$,'23514','ck_push_delivery_snapshot');
UPDATE push_deliveries SET state='SENDING';
INSERT INTO push_delivery_attempts(workspace_id,push_delivery_id,attempt_number,intent_at,token_generation,outcome)
 SELECT pg_temp.fixture_id(101),pg_temp.fixture_id(1311),attempt_number,now(),1,'INTENT' FROM generate_series(1,4) AS attempt_number;
SELECT pg_temp.rejects('push_attempt_budget_four', $$INSERT INTO push_delivery_attempts(workspace_id,push_delivery_id,attempt_number,intent_at,token_generation,outcome) VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(1311),5,now(),1,'INTENT')$$,'23514');
UPDATE push_delivery_attempts SET outcome='ACCEPTED',observed_at=now() WHERE attempt_number=1;
SELECT pg_temp.rejects('observed_attempt_outcome_cannot_rewind', $$UPDATE push_delivery_attempts SET outcome='PERMANENT_FAILURE' WHERE attempt_number=1$$,'23514','ck_attempt_outcome_immutable');
UPDATE push_deliveries SET state='ACCEPTED',terminal_at=now();
SELECT pg_temp.rejects('push_terminal_cannot_rewind', $$UPDATE push_deliveries SET state='PENDING'$$,'23514','ck_delivery_terminal');
/* Hai transition của cùng Event tạo hai nghĩa vụ BUSINESS khác nhau. */
INSERT INTO webhook_deliveries(workspace_id,webhook_delivery_id,webhook_subscription_id,kind,occurrence_id,endpoint_url_snapshot,endpoint_revision_snapshot,secret_version,raw_body,body_digest,admitted_at,expires_at)
 SELECT workspace_id,pg_temp.fixture_id(2000+row_number() OVER(ORDER BY occurrence_id)::int),pg_temp.fixture_id(1001),'BUSINESS',occurrence_id,'https://receiver.example.invalid/hook',1,1,decode('00','hex'),decode(repeat('01',32),'hex'),now(),committed_at+interval '24 hours' FROM event_occurrences;
SELECT CASE WHEN count(*)=2 THEN 'PASS:webhook_both_event_transitions' ELSE 'FAIL:webhook_both_event_transitions' END FROM webhook_deliveries;
SELECT pg_temp.rejects('webhook_duplicate_occurrence', $$INSERT INTO webhook_deliveries(workspace_id,webhook_delivery_id,webhook_subscription_id,kind,occurrence_id,endpoint_url_snapshot,endpoint_revision_snapshot,secret_version,raw_body,body_digest,admitted_at,expires_at) SELECT workspace_id,pg_temp.fixture_id(2099),webhook_subscription_id,kind,occurrence_id,endpoint_url_snapshot,endpoint_revision_snapshot,secret_version,raw_body,body_digest,admitted_at,expires_at FROM webhook_deliveries LIMIT 1$$,'23505','uq_webhook_delivery_occurrence');
SELECT pg_temp.rejects('webhook_body_immutable', $$UPDATE webhook_deliveries SET raw_body=decode('01','hex')$$,'23514','ck_resource_identity_immutable');
SELECT pg_temp.rejects('webhook_secret_kept_after_three_rotations', $$DELETE FROM webhook_secret_versions WHERE secret_version=1$$,'23503');
SELECT pg_temp.rejects('webhook_expiry_not_worker_clock', $$INSERT INTO webhook_deliveries(workspace_id,webhook_delivery_id,webhook_subscription_id,kind,occurrence_id,endpoint_url_snapshot,endpoint_revision_snapshot,secret_version,raw_body,body_digest,admitted_at,expires_at) VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(2099),pg_temp.fixture_id(1001),'BUSINESS',pg_temp.fixture_id(1201),'https://receiver.example.invalid/hook',1,1,decode('00','hex'),decode(repeat('01',32),'hex'),now(),now()+interval '25 hours')$$,'23514','ck_webhook_occurrence_expiry');
UPDATE webhook_deliveries SET state='SENDING' WHERE webhook_delivery_id=pg_temp.fixture_id(2001);
INSERT INTO webhook_delivery_attempts(workspace_id,webhook_delivery_id,attempt_number,batch_number,intent_at,request_digest,outcome)
 SELECT pg_temp.fixture_id(101),pg_temp.fixture_id(2001),attempt_number,0,now(),decode(repeat('01',32),'hex'),'INTENT' FROM generate_series(1,6) AS attempt_number;
SELECT pg_temp.rejects('webhook_cannot_auto_seventh_attempt', $$INSERT INTO webhook_delivery_attempts(workspace_id,webhook_delivery_id,attempt_number,batch_number,intent_at,request_digest,outcome) VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(2001),7,1,now(),decode(repeat('01',32),'hex'),'INTENT')$$,'23514','ck_delivery_attempt_budget');
UPDATE webhook_deliveries SET state='DEAD_LETTER',terminal_at=now() WHERE webhook_delivery_id=pg_temp.fixture_id(2001);
UPDATE webhook_deliveries SET state='PENDING',manual_batch_count=1,terminal_at=NULL WHERE webhook_delivery_id=pg_temp.fixture_id(2001);
SELECT CASE WHEN manual_batch_count=1 THEN 'PASS:webhook_manual_batch_preserves_delivery' ELSE 'FAIL:webhook_manual_batch_preserves_delivery' END FROM webhook_deliveries WHERE webhook_delivery_id=pg_temp.fixture_id(2001);
UPDATE webhook_deliveries SET state='SENDING' WHERE webhook_delivery_id=pg_temp.fixture_id(2001);
INSERT INTO webhook_delivery_attempts(workspace_id,webhook_delivery_id,attempt_number,batch_number,intent_at,request_digest,outcome)
 SELECT pg_temp.fixture_id(101),pg_temp.fixture_id(2001),attempt_number,1,now(),decode(repeat('01',32),'hex'),'INTENT' FROM generate_series(7,12) AS attempt_number;
UPDATE webhook_deliveries SET state='DEAD_LETTER' WHERE webhook_delivery_id=pg_temp.fixture_id(2001);
SELECT pg_temp.rejects('webhook_no_second_manual_batch', $$UPDATE webhook_deliveries SET state='PENDING',manual_batch_count=2 WHERE webhook_delivery_id=pg_temp.fixture_id(2001)$$,'23514','ck_webhook_manual_batch');
INSERT INTO webhook_deliveries(workspace_id,webhook_delivery_id,webhook_subscription_id,kind,endpoint_url_snapshot,endpoint_revision_snapshot,secret_version,raw_body,body_digest,state,admitted_at,expires_at)
 VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(2011),pg_temp.fixture_id(1001),'TEST','https://receiver.example.invalid/hook',1,1,decode('00','hex'),decode(repeat('01',32),'hex'),'SENDING',now(),now()+interval '30 seconds');
INSERT INTO webhook_delivery_attempts(workspace_id,webhook_delivery_id,attempt_number,batch_number,intent_at,request_digest,outcome)
 VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(2011),1,0,now(),decode(repeat('01',32),'hex'),'INTENT');
SELECT pg_temp.rejects('webhook_test_one_attempt_only', $$INSERT INTO webhook_delivery_attempts(workspace_id,webhook_delivery_id,attempt_number,batch_number,intent_at,request_digest,outcome) VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(2011),2,0,now(),decode(repeat('01',32),'hex'),'INTENT')$$,'23514','ck_delivery_attempt_budget');
/* API key global ID và FK cùng tenant, không hồi sinh scope khi rotate. */
SELECT pg_temp.rejects('api_key_id_global_unique', $$SET CONSTRAINTS ALL DEFERRED; INSERT INTO api_keys(api_key_id,workspace_id,owner_user_id,owner_grant_generation,verifier_digest,name,prefix,issued_at,expires_at) VALUES(pg_temp.fixture_id(1701),pg_temp.fixture_id(102),pg_temp.fixture_id(2),1,decode(repeat('18',32),'hex'),'Other','synthetic',now(),now()+interval '30 days')$$,'23505','api_keys_pkey');
SELECT pg_temp.rejects('api_key_foreign_device', $$INSERT INTO api_key_devices VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(1701),pg_temp.fixture_id(321))$$,'23503');
INSERT INTO api_key_devices VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(1701),pg_temp.fixture_id(305));
SELECT pg_temp.rejects('api_key_sixth_device_rejected', $$INSERT INTO api_key_devices VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(1701),pg_temp.fixture_id(306))$$,'23514','ck_api_key_cardinality');
SELECT pg_temp.rejects('api_key_scope_allowlist', $$INSERT INTO api_key_scopes VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(1701),'admin:all')$$,'23514');
