/* Một claim/settle winner và stale lease không thể ghi COMPLETED. */
INSERT INTO outbox_events VALUES(pg_temp.fixture_id(2201),pg_temp.fixture_id(101),'lease-case','test',1,'{}',now());
INSERT INTO outbox_consumptions(outbox_event_id,consumer_code,available_at) VALUES(pg_temp.fixture_id(2201),'TEST',now());
SELECT CASE WHEN count(*)=1 AND max(claimed_generation)=1 THEN 'PASS:outbox_claim_first_generation' ELSE 'FAIL:outbox_claim_first_generation' END FROM claim_outbox('TEST',30,1);
SELECT CASE WHEN count(*)=0 THEN 'PASS:outbox_no_double_claim' ELSE 'FAIL:outbox_no_double_claim' END FROM claim_outbox('TEST',30,1);
SELECT CASE WHEN NOT complete_outbox(pg_temp.fixture_id(2201),'TEST',2) THEN 'PASS:outbox_rejects_stale_generation' ELSE 'FAIL:outbox_rejects_stale_generation' END;
SELECT CASE WHEN complete_outbox(pg_temp.fixture_id(2201),'TEST',1) THEN 'PASS:outbox_current_generation_completes' ELSE 'FAIL:outbox_current_generation_completes' END;
SELECT CASE WHEN NOT complete_outbox(pg_temp.fixture_id(2201),'TEST',1) THEN 'PASS:outbox_complete_is_single_winner' ELSE 'FAIL:outbox_complete_is_single_winner' END;
SELECT pg_temp.rejects('outbox_null_batch_rejected', $$SELECT claim_outbox('TEST',30,NULL)$$,'22023');
SELECT pg_temp.rejects('retention_null_batch_rejected', $$SELECT purge_expired_telemetry(NULL)$$,'22023');
/* Ticket vẫn phải recheck session/grant; consume lần2 thất bại dù TTL còn. */
INSERT INTO websocket_tickets(ticket_id,ticket_digest,workspace_id,user_id,session_id,grant_generation,workspace_authorization_version,membership_authorization_version,issued_at,expires_at)
 VALUES(pg_temp.fixture_id(2211),decode(repeat('22',32),'hex'),pg_temp.fixture_id(101),pg_temp.fixture_id(1),pg_temp.fixture_id(411),1,1,1,now(),now()+interval '30 seconds');
SELECT CASE WHEN consume_websocket_ticket(decode(repeat('22',32),'hex')) THEN 'PASS:websocket_ticket_first_consume' ELSE 'FAIL:websocket_ticket_first_consume' END;
SELECT CASE WHEN NOT consume_websocket_ticket(decode(repeat('22',32),'hex')) THEN 'PASS:websocket_ticket_second_consume_denied' ELSE 'FAIL:websocket_ticket_second_consume_denied' END;
SELECT pg_temp.rejects('websocket_ticket_cannot_clear_consumption', $$UPDATE websocket_tickets SET consumed_at=NULL$$,'23514','ck_one_way_timestamp');
INSERT INTO device_latest_values VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(301),pg_temp.fixture_id(211),'fan',1,now(),'true',1,'true','FRESH');
SELECT pg_temp.rejects('latest_null_marker_cannot_reuse_old_good', $$UPDATE device_latest_values SET latest_marker_sequence=2,latest_value=NULL$$,'23514','ck_latest_rule_current_marker');
SELECT pg_temp.rejects('latest_sequence_cannot_regress', $$UPDATE device_latest_values SET latest_marker_sequence=0$$,'23514','ck_latest_sequence_monotonic');
/* Capable Admin constraint ngăn disable tùy ý; password change vẫn revoke cả phiên cũ. */
UPDATE users SET password_hash='changed-invalid-test-verifier' WHERE user_id=pg_temp.fixture_id(1);
SELECT CASE WHEN count(*)=0 THEN 'PASS:password_change_revokes_existing_sessions' ELSE 'FAIL:password_change_revokes_existing_sessions' END FROM sessions WHERE revoked_at IS NULL;
