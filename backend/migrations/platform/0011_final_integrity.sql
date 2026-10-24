/* Forward repair từ review: CAS resolution giữ terminal truth, one-time không rewind,
 * latest marker không fallback GOOD cũ, attempt outcome đã xác nhận không bị late reply đảo.
 */
/* Command admission/state bất biến theo contract; revision được tăng khi resolution ACK dùng CAS.
 * Input: OLD/NEW command. Output:NEW; Errors:23514 khi sửa truth, identity hoặc hạ revision.
 */
CREATE OR REPLACE FUNCTION enforce_command_transition() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE definition public.datastream_definitions; candidate jsonb; BEGIN
 IF TG_OP='UPDATE' THEN
  IF (to_jsonb(NEW)-ARRAY['state','outcome','dispatch_intent_at','terminal_at','revision']) IS DISTINCT FROM
     (to_jsonb(OLD)-ARRAY['state','outcome','dispatch_intent_at','terminal_at','revision']) THEN
   RAISE EXCEPTION 'Command admission is immutable' USING ERRCODE='23514',CONSTRAINT='ck_command_admission_immutable';
  END IF;
  IF NEW.revision<OLD.revision THEN RAISE EXCEPTION 'Command revision cannot regress' USING ERRCODE='23514'; END IF;
  IF OLD.state IN ('SUCCEEDED','FAILED','TIMED_OUT','EXPIRED_BEFORE_DISPATCH','CANCELLED') AND
    (to_jsonb(NEW)-'revision') IS DISTINCT FROM (to_jsonb(OLD)-'revision') THEN
   RAISE EXCEPTION 'Command terminal cannot change' USING ERRCODE='23514',CONSTRAINT='ck_command_terminal_immutable';
  END IF;
  IF NEW.state<>OLD.state AND NOT(
   (OLD.state='ADMITTED' AND NEW.state IN ('DISPATCHING','EXPIRED_BEFORE_DISPATCH','CANCELLED')) OR
   (OLD.state='DISPATCHING' AND NEW.state IN ('DISPATCHED','ACCEPTED','SUCCEEDED','FAILED','TIMED_OUT')) OR
   (OLD.state='DISPATCHED' AND NEW.state IN ('ACCEPTED','SUCCEEDED','FAILED','TIMED_OUT')) OR
   (OLD.state='ACCEPTED' AND NEW.state IN ('SUCCEEDED','FAILED','TIMED_OUT'))) THEN
   RAISE EXCEPTION 'Invalid command transition' USING ERRCODE='23514',CONSTRAINT='ck_command_transition';
  END IF;
 ELSE
  IF NEW.state<>'ADMITTED' OR NEW.outcome<>'PENDING' THEN RAISE EXCEPTION 'Command must start admitted' USING ERRCODE='23514'; END IF;
  SELECT stream.* INTO definition FROM public.devices device JOIN public.datastream_definitions stream USING(workspace_id,template_version_id)
  WHERE device.workspace_id=NEW.workspace_id AND device.device_id=NEW.device_id AND stream.stream_key=NEW.stream_key;
  IF definition.data_type IS DISTINCT FROM NEW.value_type THEN RAISE EXCEPTION 'Command type differs from pin' USING ERRCODE='23514',CONSTRAINT='ck_stream_value'; END IF;
  candidate:=coalesce(to_jsonb(NEW.numeric_value),to_jsonb(NEW.boolean_value),to_jsonb(NEW.text_value));
  PERFORM public.assert_stream_value(definition,candidate,true);
  IF EXISTS(SELECT 1 FROM public.actuator_states WHERE(workspace_id,device_id,stream_key)=(NEW.workspace_id,NEW.device_id,NEW.stream_key) AND unresolved_command_id IS NOT NULL) THEN
   RAISE EXCEPTION 'Actuator requires reconciliation' USING ERRCODE='23514',CONSTRAINT='ck_command_unresolved_guard';
  END IF;
 END IF;
 RETURN NEW;
END $$;

/* Mốc consume/revoke/expiry đã ghi chỉ được giữ nguyên; không mở lại one-time capability.
 * Input: OLD/NEW và TG_ARGV là tên timestamp nội bộ. Output:NEW; Errors:23514 nếu đổi mốc đã có.
 */
CREATE FUNCTION enforce_one_way_timestamps() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE column_name text; BEGIN
 FOREACH column_name IN ARRAY TG_ARGV LOOP
  IF to_jsonb(OLD)->column_name<>'null'::jsonb AND to_jsonb(NEW)->column_name IS DISTINCT FROM to_jsonb(OLD)->column_name THEN
   RAISE EXCEPTION 'One-way timestamp cannot be rewritten' USING ERRCODE='23514',CONSTRAINT='ck_one_way_timestamp';
  END IF;
 END LOOP;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_ticket_one_way BEFORE UPDATE ON websocket_tickets FOR EACH ROW EXECUTE FUNCTION enforce_one_way_timestamps('consumed_at','revoked_at');
CREATE TRIGGER tr_invitation_one_way BEFORE UPDATE ON workspace_invitations FOR EACH ROW EXECUTE FUNCTION enforce_one_way_timestamps('used_at','revoked_at','expired_at');
CREATE TRIGGER tr_api_key_one_way BEFORE UPDATE ON api_keys FOR EACH ROW EXECUTE FUNCTION enforce_one_way_timestamps('revoked_at');
CREATE TRIGGER tr_ticket_binding_identity BEFORE UPDATE ON websocket_tickets FOR EACH ROW EXECUTE FUNCTION enforce_identity_columns('ticket_digest','workspace_id','user_id','session_id','grant_generation','workspace_authorization_version','membership_authorization_version','issued_at','expires_at');
CREATE TRIGGER tr_invitation_snapshot_identity BEFORE UPDATE ON workspace_invitations FOR EACH ROW EXECUTE FUNCTION enforce_identity_columns('token_digest','email_normalized','email_digest','role','issued_by_user_id','issuer_grant_generation','issuer_authorization_version','admission_generation','issued_at','expires_at');

/* Latest dành cho rule chỉ được dùng đúng marker hiện hành, không GOOD cũ khi mẫu mới NULL/stale. */
ALTER TABLE device_latest_values ADD CONSTRAINT ck_latest_rule_current_marker
 CHECK(rule_eligible_marker_sequence IS NULL OR rule_eligible_marker_sequence=latest_marker_sequence);
ALTER TABLE device_latest_values ADD CONSTRAINT ck_latest_rule_value_shape
 CHECK((rule_eligible_marker_sequence IS NULL)=(rule_value IS NULL) AND (rule_value IS NULL OR rule_value<>'null'::jsonb));
/* Projection sequence/time không lùi khi nhận out-of-order; ingest owner vẫn chịu atomic receipt.
 * Input: OLD/NEW latest projection. Output:NEW; Errors:23514 khi marker hoặc thời gian bị lùi.
 */
CREATE FUNCTION enforce_latest_sequence() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 IF NEW.latest_marker_sequence<OLD.latest_marker_sequence OR NEW.latest_received_at<OLD.latest_received_at THEN
  RAISE EXCEPTION 'Latest projection cannot regress' USING ERRCODE='23514',CONSTRAINT='ck_latest_sequence_monotonic';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_latest_sequence BEFORE UPDATE ON device_latest_values FOR EACH ROW EXECUTE FUNCTION enforce_latest_sequence();

/* Response đã xác nhận giữ nguyên outcome; UNKNOWN có thể bổ sung quan sát muộn, không rewind parent.
 * Input: OLD/NEW attempt push/webhook. Output:NEW; Errors:23514 nếu đổi outcome đã kết luận.
 */
CREATE FUNCTION enforce_attempt_outcome() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 IF OLD.outcome NOT IN ('INTENT','UNKNOWN') AND NEW.outcome<>OLD.outcome THEN
  RAISE EXCEPTION 'Observed attempt outcome cannot change' USING ERRCODE='23514',CONSTRAINT='ck_attempt_outcome_immutable';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_push_attempt_outcome BEFORE UPDATE ON push_delivery_attempts FOR EACH ROW EXECUTE FUNCTION enforce_attempt_outcome();
CREATE TRIGGER tr_webhook_attempt_outcome BEFORE UPDATE ON webhook_delivery_attempts FOR EACH ROW EXECUTE FUNCTION enforce_attempt_outcome();
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC,iot_runtime;
