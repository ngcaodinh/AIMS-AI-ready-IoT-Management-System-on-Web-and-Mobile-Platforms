/* Regression seal/SAVEPOINT và TTL; runner tạo fixture tổng hợp rồi rollback toàn bộ.
 * Trước0013, INSERT child trong SAVEPOINT dưới đây tái hiện lỗi ck_published_child_sealed.
 */
SET CONSTRAINTS ALL DEFERRED;
SAVEPOINT publish_savepoint;
INSERT INTO template_versions(workspace_id,template_version_id,template_id,version_number,name,model,published_by_user_id,content_digest,source_revision,published_root_revision)
SELECT workspace_id,pg_temp.fixture_id(219),template_id,2,name,model,created_by_user_id,decode(repeat('29',32),'hex'),2,3
FROM templates WHERE workspace_id=pg_temp.fixture_id(101);
INSERT INTO datastream_definitions(workspace_id,template_version_id,stream_key,display_name,data_type,direction,channel_kind)
VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(219),'savepoint','Savepoint','BOOLEAN','READ','STATE');
RELEASE SAVEPOINT publish_savepoint;
SELECT 'PASS:template_publish_inside_savepoint';

SAVEPOINT rollback_publication;
INSERT INTO template_versions(workspace_id,template_version_id,template_id,version_number,name,model,published_by_user_id,content_digest,source_revision,published_root_revision)
SELECT workspace_id,pg_temp.fixture_id(220),template_id,3,name,model,created_by_user_id,decode(repeat('30',32),'hex'),3,4
FROM templates WHERE workspace_id=pg_temp.fixture_id(101);
ROLLBACK TO SAVEPOINT rollback_publication;
INSERT INTO template_versions(workspace_id,template_version_id,template_id,version_number,name,model,published_by_user_id,content_digest,source_revision,published_root_revision)
SELECT workspace_id,pg_temp.fixture_id(220),template_id,3,name,model,created_by_user_id,decode(repeat('30',32),'hex'),3,4
FROM templates WHERE workspace_id=pg_temp.fixture_id(101);
INSERT INTO datastream_definitions(workspace_id,template_version_id,stream_key,display_name,data_type,direction,channel_kind)
VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(220),'retry','Retry','BOOLEAN','READ','STATE');
RELEASE SAVEPOINT rollback_publication;
SELECT 'PASS:publication_rollback_savepoint_then_retry';

/* Marker có sẵn ngay BEFORE INSERT parent, nên cùng statement CTE cũng publish được. */
WITH published AS (
 INSERT INTO template_versions(workspace_id,template_version_id,template_id,version_number,name,model,published_by_user_id,content_digest,source_revision,published_root_revision)
 SELECT workspace_id,pg_temp.fixture_id(221),template_id,4,name,model,created_by_user_id,decode(repeat('31',32),'hex'),4,5
 FROM templates WHERE workspace_id=pg_temp.fixture_id(101)
 RETURNING workspace_id,template_version_id
)
INSERT INTO datastream_definitions(workspace_id,template_version_id,stream_key,display_name,data_type,direction,channel_kind)
SELECT workspace_id,template_version_id,'cte','CTE','BOOLEAN','READ','STATE' FROM published;
SELECT 'PASS:publication_parent_child_same_statement_cte';

/* Marker input giả bị bỏ qua lúc INSERT; không tin provenance từ caller. */
INSERT INTO template_versions(workspace_id,template_version_id,template_id,version_number,name,model,published_by_user_id,content_digest,publication_transaction_id,publication_cluster_id,source_revision,published_root_revision)
SELECT workspace_id,pg_temp.fixture_id(222),template_id,5,name,model,created_by_user_id,decode(repeat('32',32),'hex'),'0'::xid8,0,5,6
FROM templates WHERE workspace_id=pg_temp.fixture_id(101);
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM template_versions WHERE template_version_id=pg_temp.fixture_id(222)
   AND publication_transaction_id=pg_current_xact_id() AND publication_cluster_id=(SELECT system_identifier FROM pg_control_system())) THEN
  RAISE EXCEPTION 'Caller forged publication origin';
 END IF;
END $$;
SELECT 'PASS:publication_marker_input_overwritten';
SELECT pg_temp.rejects('publication_marker_update_rejected',
 'UPDATE api_keys SET publication_transaction_id=''0''::xid8 WHERE api_key_id=pg_temp.fixture_id(1701)',
 '23514','ck_publication_origin_immutable');

/* INSERT trong subtransaction phải gán top-level XID cho cả bốn loại parent. */
DO $$ DECLARE parent_table text; valid_count bigint; BEGIN
 FOREACH parent_table IN ARRAY ARRAY['template_versions','rule_versions','firmware_packages','api_keys'] LOOP
  EXECUTE format('SELECT count(*) FROM public.%I WHERE publication_transaction_id IS DISTINCT FROM pg_current_xact_id() OR publication_cluster_id IS DISTINCT FROM (SELECT system_identifier FROM pg_control_system())',parent_table)
  INTO valid_count;
  IF valid_count<>0 THEN RAISE EXCEPTION 'Incorrect publication origin: %',parent_table; END IF;
 END LOOP;
END $$;
SELECT 'PASS:all_parent_markers_use_top_transaction_and_cluster';

/* Giả lập dữ liệu legacy/restore trong fixture rollback: chỉ owner tạm nạp marker, bật lại guard trước probe.
 * Không dùng cách này trong writer ứng dụng; fingerprint cuối suite kiểm mọi trigger đã được khôi phục.
 */
ALTER TABLE public.template_versions DISABLE TRIGGER tr_immutable_update;
ALTER TABLE public.template_versions DISABLE TRIGGER tr_publication_origin;
UPDATE public.template_versions SET publication_transaction_id=NULL,publication_cluster_id=NULL
WHERE template_version_id=pg_temp.fixture_id(222);
ALTER TABLE public.template_versions ENABLE TRIGGER tr_publication_origin;
ALTER TABLE public.template_versions ENABLE TRIGGER tr_immutable_update;
SELECT pg_temp.rejects('legacy_null_marker_is_sealed',
 $$INSERT INTO datastream_definitions(workspace_id,template_version_id,stream_key,display_name,data_type,direction,channel_kind)
 VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(222),'legacy','Legacy','BOOLEAN','READ','STATE')$$,
 '23514','ck_published_child_sealed');

ALTER TABLE public.template_versions DISABLE TRIGGER tr_immutable_update;
ALTER TABLE public.template_versions DISABLE TRIGGER tr_publication_origin;
UPDATE public.template_versions SET publication_transaction_id=pg_current_xact_id(),publication_cluster_id=0
WHERE template_version_id=pg_temp.fixture_id(222);
ALTER TABLE public.template_versions ENABLE TRIGGER tr_publication_origin;
ALTER TABLE public.template_versions ENABLE TRIGGER tr_immutable_update;
SELECT pg_temp.rejects('restored_marker_from_other_cluster_is_sealed',
 $$INSERT INTO datastream_definitions(workspace_id,template_version_id,stream_key,display_name,data_type,direction,channel_kind)
 VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(222),'restored','Restored','BOOLEAN','READ','STATE')$$,
 '23514','ck_published_child_sealed');

/* Bound kiểm theo seconds: UTC và DST xuân/thu, biên 1/90 ngày và lệch một giây. */
DO $$ DECLARE selected_zone text; selected_time timestamptz; selected_days integer; ttl_check text; valid_bound boolean; BEGIN
 SELECT pg_get_constraintdef(oid) INTO ttl_check FROM pg_constraint
 WHERE conrelid='public.api_keys'::regclass AND conname='ck_api_keys_fixed_duration_ttl' AND convalidated;
 IF ttl_check IS NULL THEN RAISE EXCEPTION 'Validated fixed-duration check missing'; END IF;
 FOREACH selected_zone IN ARRAY ARRAY['UTC','America/New_York','Europe/Berlin'] LOOP
  PERFORM set_config('TimeZone',selected_zone,true);
  FOREACH selected_time IN ARRAY ARRAY[timestamptz '2026-02-01 00:00:00+00',timestamptz '2026-10-01 00:00:00+00'] LOOP
   FOREACH selected_days IN ARRAY ARRAY[1,90] LOOP
    EXECUTE 'SELECT '||substring(ttl_check FROM 8 FOR length(ttl_check)-8)
      ||' FROM (SELECT $1::timestamptz issued_at,$2::timestamptz expires_at) input'
      INTO valid_bound USING selected_time,selected_time+make_interval(secs=>selected_days*86400);
    IF valid_bound IS DISTINCT FROM true THEN RAISE EXCEPTION 'Valid fixed duration rejected'; END IF;
   END LOOP;
   EXECUTE 'SELECT '||substring(ttl_check FROM 8 FOR length(ttl_check)-8)
      ||' FROM (SELECT $1::timestamptz issued_at,$2::timestamptz expires_at) input'
      INTO valid_bound USING selected_time,selected_time+interval '86399 seconds';
   IF valid_bound IS DISTINCT FROM false THEN RAISE EXCEPTION 'Short TTL accepted'; END IF;
   EXECUTE 'SELECT '||substring(ttl_check FROM 8 FOR length(ttl_check)-8)
      ||' FROM (SELECT $1::timestamptz issued_at,$2::timestamptz expires_at) input'
      INTO valid_bound USING selected_time,selected_time+interval '7776001 seconds';
   IF valid_bound IS DISTINCT FROM false THEN RAISE EXCEPTION 'Long TTL accepted'; END IF;
  END LOOP;
 END LOOP;
 PERFORM set_config('TimeZone','UTC',true);
END $$;
SELECT 'PASS:api_key_fixed_duration_bounds_across_timezones';
