/* Ingestion time không phụ thuộc event-time; fixture explicit timestamp chỉ chạy bằng owner trong rollback. */
INSERT INTO audit_events(audit_event_id,event_type,outcome,correlation_id,client_type,occurred_at)
VALUES(pg_temp.fixture_id(980),'AUDIT_INGESTION_PROBE','SUCCESS',pg_temp.fixture_id(981),'UNKNOWN',statement_timestamp()-interval '90 days');
SELECT CASE WHEN created_at>=transaction_timestamp() AND occurred_at<created_at-interval '30 days'
 THEN 'PASS:audit_late_event_has_fresh_ingestion' ELSE 'FAIL:audit_late_event_has_fresh_ingestion' END
FROM audit_events WHERE audit_event_id=pg_temp.fixture_id(980);
SELECT CASE WHEN EXISTS(SELECT 1 FROM audit_history WHERE audit_event_id=pg_temp.fixture_id(980))
 THEN 'PASS:audit_history_uses_ingestion_not_event_time' ELSE 'FAIL:audit_history_uses_ingestion_not_event_time' END;

/* Writer thực chỉ có column INSERT, không thể tự đặt ingestion time dù timestamp hợp lệ. */
GRANT EXECUTE ON FUNCTION pg_temp.rejects(text,text,text,text) TO iot_runtime;
SET LOCAL ROLE iot_runtime;
INSERT INTO audit_events(audit_event_id,event_type,outcome,correlation_id,client_type)
VALUES('00000000-0000-0000-0000-000000000982','LOGIN_FAILED','FAILURE','00000000-0000-0000-0000-000000000981','UNKNOWN');
SELECT pg_temp.rejects('audit_writer_cannot_override_ingestion',
 $$INSERT INTO audit_events(audit_event_id,event_type,outcome,correlation_id,client_type,created_at) VALUES('00000000-0000-0000-0000-000000000983','LOGIN_FAILED','FAILURE','00000000-0000-0000-0000-000000000981','UNKNOWN',now()-interval '90 days')$$,'42501');
SELECT pg_temp.rejects('audit_writer_cannot_rewrite',
 $$UPDATE audit_events SET outcome='SUCCESS'$$,'42501');
SELECT pg_temp.rejects('audit_writer_cannot_delete',
 $$DELETE FROM audit_events$$,'42501');
RESET ROLE;
SELECT CASE WHEN count(*)=1 THEN 'PASS:audit_column_writer_append_succeeds' ELSE 'FAIL:audit_column_writer_append_succeeds' END
FROM audit_events WHERE audit_event_id=pg_temp.fixture_id(982);

/* Column mới vẫn tham gia native append-only trigger; cả owner không rewrite lịch sử đã ghi. */
SELECT pg_temp.rejects('audit_ingestion_immutable',
 $$UPDATE audit_events SET created_at=now()-interval '31 days' WHERE audit_event_id='00000000-0000-0000-0000-000000000980'$$,'23514','ck_record_immutable');
