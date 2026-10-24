/* Envelope/points được commit nguyên tử; metadata authority nằm ở receipt/envelope. */
SET CONSTRAINTS ct_envelope_points,ct_points_count DEFERRED;
INSERT INTO telemetry_receipts VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(301),'boot-test','message-1',100,decode(repeat('01',32),'hex'),now(),1);
INSERT INTO telemetry_envelopes VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(1801),pg_temp.fixture_id(301),'boot-test','message-1',now(),now(),now(),'DEVICE',1,2);
INSERT INTO telemetry_points VALUES
 (pg_temp.fixture_id(101),pg_temp.fixture_id(1801),0,pg_temp.fixture_id(301),'fan',now(),now(),'GOOD','BOOLEAN',NULL,true,NULL),
 (pg_temp.fixture_id(101),pg_temp.fixture_id(1801),1,pg_temp.fixture_id(301),'temperature',now(),now(),'GOOD','NUMBER',25,NULL,NULL);
SET CONSTRAINTS ALL IMMEDIATE;
SELECT CASE WHEN count(*)=2 THEN 'PASS:telemetry_complete_envelope' ELSE 'FAIL:telemetry_complete_envelope' END FROM telemetry_points;
SELECT pg_temp.rejects('telemetry_duplicate_receipt', $$INSERT INTO telemetry_receipts SELECT * FROM telemetry_receipts$$,'23505');
SELECT pg_temp.rejects('telemetry_duplicate_stream', $$INSERT INTO telemetry_points VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(1801),1,pg_temp.fixture_id(301),'fan',now(),now(),'GOOD','BOOLEAN',NULL,false,NULL)$$,'23505');
SELECT pg_temp.rejects('telemetry_timestamp_copy_rejected', $$INSERT INTO telemetry_points VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(1801),0,pg_temp.fixture_id(301),'fan',NULL,now(),'GOOD','BOOLEAN',NULL,true,NULL)$$,'23514','ck_point_envelope_metadata');
SELECT pg_temp.rejects('telemetry_cross_device_rejected', $$INSERT INTO telemetry_points VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(1801),0,pg_temp.fixture_id(302),'fan',now(),now(),'GOOD','BOOLEAN',NULL,true,NULL)$$,'23514','ck_point_envelope_metadata');
SELECT pg_temp.rejects('telemetry_wrong_type_rejected', $$INSERT INTO telemetry_points VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(1801),0,pg_temp.fixture_id(301),'fan',now(),now(),'GOOD','NUMBER',1,NULL,NULL)$$,'23514','ck_stream_value');
SELECT pg_temp.rejects('telemetry_nonfinite_rejected', $$INSERT INTO telemetry_points VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(1801),1,pg_temp.fixture_id(301),'temperature',now(),now(),'GOOD','NUMBER','NaN'::float8,NULL,NULL)$$,'23514','ck_stream_value');
SELECT pg_temp.rejects('telemetry_incomplete_envelope_rollback', $$SET CONSTRAINTS ct_envelope_points,ct_points_count DEFERRED; INSERT INTO telemetry_receipts VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(301),'boot-test','incomplete',102,decode(repeat('02',32),'hex'),now(),2); INSERT INTO telemetry_envelopes VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(1802),pg_temp.fixture_id(301),'boot-test','incomplete',NULL,now(),now(),'SERVER',2,1); SET CONSTRAINTS ct_envelope_points,ct_points_count IMMEDIATE$$,'23514','ck_envelope_point_count');
SELECT CASE WHEN count(*)=1 THEN 'PASS:telemetry_failed_envelope_no_receipt' ELSE 'FAIL:telemetry_failed_envelope_no_receipt' END FROM telemetry_receipts;
/* Raw purge xóa child trước parent cùng TX; receipt sống độc lập để chống replay. */
SET CONSTRAINTS ct_points_count DEFERRED;
DELETE FROM telemetry_points;
DELETE FROM telemetry_envelopes;
SET CONSTRAINTS ALL IMMEDIATE;
SELECT CASE WHEN count(*)=1 THEN 'PASS:raw_purge_preserves_receipt' ELSE 'FAIL:raw_purge_preserves_receipt' END FROM telemetry_receipts;
/* Kiểm chính retention entry point với raw cũ; logical view không chờ cron. */
SET CONSTRAINTS ct_envelope_points,ct_points_count DEFERRED;
INSERT INTO telemetry_receipts VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(301),'boot-test','old-message',102,decode(repeat('02',32),'hex'),now()-interval '8 days',2);
INSERT INTO telemetry_envelopes VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(1802),pg_temp.fixture_id(301),'boot-test','old-message',NULL,now()-interval '8 days',now()-interval '8 days','SERVER',2,1);
INSERT INTO telemetry_points VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(1802),0,pg_temp.fixture_id(301),'temperature',NULL,now()-interval '8 days','SERVER_TIME','NUMBER',25,NULL,NULL);
SET CONSTRAINTS ALL IMMEDIATE;
SELECT CASE WHEN count(*)=0 THEN 'PASS:telemetry_logical_cutoff_hides_old_raw' ELSE 'FAIL:telemetry_logical_cutoff_hides_old_raw' END FROM telemetry_history;
SELECT CASE WHEN purge_expired_telemetry(1)=1 THEN 'PASS:telemetry_retention_entrypoint_purges_batch' ELSE 'FAIL:telemetry_retention_entrypoint_purges_batch' END;
SELECT CASE WHEN count(*)=2 AND NOT EXISTS(SELECT 1 FROM telemetry_envelopes) THEN 'PASS:retention_entrypoint_keeps_dedupe_authority' ELSE 'FAIL:retention_entrypoint_keeps_dedupe_authority' END FROM telemetry_receipts;
