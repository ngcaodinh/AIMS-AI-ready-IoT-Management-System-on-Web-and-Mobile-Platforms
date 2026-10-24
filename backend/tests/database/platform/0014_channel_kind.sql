/* Hai thuộc tính stream độc lập; fixture công bố trước cùng transaction và tất cả rollback cuối suite. */
SELECT CASE WHEN bool_and(channel_kind=CASE WHEN stream_key='temperature' THEN 'TELEMETRY' ELSE 'STATE' END)
 THEN 'PASS:stream_channel_kind_explicit_fixture' ELSE 'FAIL:stream_channel_kind_explicit_fixture' END FROM datastream_definitions;

SELECT pg_temp.rejects('published_channel_kind_immutable',
 $$UPDATE datastream_definitions SET channel_kind='TELEMETRY' WHERE stream_key='fan'$$,'23514','ck_record_immutable');
SELECT pg_temp.rejects('published_channel_kind_required',
 $$INSERT INTO datastream_definitions(workspace_id,template_version_id,stream_key,display_name,data_type,direction)
 SELECT workspace_id,template_version_id,'missing_kind','Missing','BOOLEAN','READ' FROM template_versions LIMIT 1$$,'23502');
SELECT pg_temp.rejects('published_channel_kind_allowlist',
 $$INSERT INTO datastream_definitions(workspace_id,template_version_id,stream_key,display_name,data_type,direction,channel_kind)
 SELECT workspace_id,template_version_id,'invalid_kind','Invalid','BOOLEAN','READ','READ' FROM template_versions LIMIT 1$$,'23514','ck_datastream_channel_kind');

/* Draft là relation chỉnh sửa được, nhưng missing/invalid kind không tự nhận default suy từ direction. */
SELECT pg_temp.rejects('draft_channel_kind_required',
 $$INSERT INTO template_draft_streams(workspace_id,template_id,stream_key,display_name,data_type,direction)
 SELECT workspace_id,template_id,'missing_kind','Missing','BOOLEAN','READ' FROM templates LIMIT 1$$,'23502');
SELECT pg_temp.rejects('draft_channel_kind_allowlist',
 $$INSERT INTO template_draft_streams(workspace_id,template_id,stream_key,display_name,data_type,direction,channel_kind)
 SELECT workspace_id,template_id,'invalid_kind','Invalid','BOOLEAN','READ','READ' FROM templates LIMIT 1$$,'23514','ck_draft_stream_channel_kind');

INSERT INTO template_draft_streams(workspace_id,template_id,stream_key,display_name,data_type,direction,channel_kind)
SELECT workspace_id,template_id,'observed_state','Observed','BOOLEAN','READ','STATE' FROM templates LIMIT 1;
SELECT CASE WHEN count(*)=1 THEN 'PASS:state_channel_can_be_read_only' ELSE 'FAIL:state_channel_can_be_read_only' END
FROM template_draft_streams WHERE stream_key='observed_state' AND direction='READ' AND channel_kind='STATE';

/* Loại kênh không tự sinh SET_VALUE hoặc cấp quyền; capability vẫn là relation tách biệt. */
SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM template_draft_capabilities WHERE stream_key='observed_state')
 THEN 'PASS:channel_kind_does_not_create_control_capability' ELSE 'FAIL:channel_kind_does_not_create_control_capability' END;
SELECT CASE WHEN count(*)=2 AND bool_and(column_default IS NULL)
 THEN 'PASS:channel_kind_has_no_guessed_default' ELSE 'FAIL:channel_kind_has_no_guessed_default' END
FROM information_schema.columns WHERE table_schema='public' AND table_name IN ('template_draft_streams','datastream_definitions') AND column_name='channel_kind';
