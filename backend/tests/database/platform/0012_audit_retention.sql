/* Run metadata đóng cutoff UTC và batch metadata append-only, không phụ thuộc session lifetime. */
INSERT INTO audit_retention_runs(run_id) VALUES(pg_temp.fixture_id(990));
SELECT CASE WHEN cutoff<=statement_timestamp()-interval '720 hours'
 THEN 'PASS:audit_retention_run_server_cutoff' ELSE 'FAIL:audit_retention_run_server_cutoff' END
FROM audit_retention_runs WHERE run_id=pg_temp.fixture_id(990);
SELECT pg_temp.rejects('audit_retention_future_cutoff',
 $$INSERT INTO audit_retention_runs(run_id,cutoff) VALUES('00000000-0000-0000-0000-000000000991',now())$$,'23514','ck_audit_retention_cutoff');
SELECT pg_temp.rejects('audit_retention_run_immutable',
 $$UPDATE audit_retention_runs SET cutoff=cutoff-interval '1 hour' WHERE run_id='00000000-0000-0000-0000-000000000990'$$,'23514','ck_record_immutable');
INSERT INTO audit_retention_batches(batch_id,run_id,batch_limit,removed_count)
VALUES(pg_temp.fixture_id(992),pg_temp.fixture_id(990),10,3);
SELECT pg_temp.rejects('audit_retention_batch_count_bound',
 $$INSERT INTO audit_retention_batches(batch_id,run_id,batch_limit,removed_count) VALUES('00000000-0000-0000-0000-000000000993','00000000-0000-0000-0000-000000000990',1,2)$$,'23514','ck_audit_retention_batch_count');
SELECT pg_temp.rejects('audit_retention_batch_limit_bound',
 $$INSERT INTO audit_retention_batches(batch_id,run_id,batch_limit,removed_count) VALUES('00000000-0000-0000-0000-000000000993','00000000-0000-0000-0000-000000000990',1001,0)$$,'23514','ck_audit_retention_batch_limit');
SELECT pg_temp.rejects('audit_retention_batch_immutable',
 $$UPDATE audit_retention_batches SET removed_count=4 WHERE batch_id='00000000-0000-0000-0000-000000000992'$$,'23514','ck_record_immutable');
