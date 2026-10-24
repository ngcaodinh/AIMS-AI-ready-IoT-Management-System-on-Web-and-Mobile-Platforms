/* Entry point vận hành và index FK; migration cuối baseline, không cấp quyền vượt phạm vi.
 * Check quota dựa ledger dưới fence, không tin counter projection có thể lệch sau restore.
 */
/* Đếm ledger sau User/Workspace fence, cập nhật projection cùng mutation execution.
 * Input: execution OLD/NEW. Output:hàng hợp lệ; Errors:23514 khi vượt10 hoặc đổi identity.
 * Side effects: MVCC fence và reconcile counter; không gọi network.
 */
CREATE OR REPLACE FUNCTION enforce_execution_quota() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE selected_workspace uuid; active_delta integer; active_count integer; BEGIN
 IF TG_OP='UPDATE' AND ROW(NEW.workspace_id,NEW.rule_execution_id,NEW.rule_id,NEW.rule_version_id) IS DISTINCT FROM ROW(OLD.workspace_id,OLD.rule_execution_id,OLD.rule_id,OLD.rule_version_id) THEN
  RAISE EXCEPTION 'Execution identity is immutable' USING ERRCODE='23514';
 END IF;
 selected_workspace:=CASE WHEN TG_OP='DELETE' THEN OLD.workspace_id ELSE NEW.workspace_id END;
 active_delta:=0;
 IF TG_OP<>'DELETE' AND NEW.state IN ('RUNNING','WAITING') THEN active_delta:=active_delta+1; END IF;
 IF TG_OP<>'INSERT' AND OLD.state IN ('RUNNING','WAITING') THEN active_delta:=active_delta-1; END IF;
 IF active_delta<>0 THEN
  UPDATE public.workspaces SET authorization_version=authorization_version WHERE workspace_id=selected_workspace;
  SELECT count(*) INTO active_count FROM public.rule_executions WHERE workspace_id=selected_workspace AND state IN ('RUNNING','WAITING');
  IF active_count+active_delta NOT BETWEEN 0 AND 10 THEN RAISE EXCEPTION 'Execution quota exceeded' USING ERRCODE='23514',CONSTRAINT='ck_execution_workspace_quota'; END IF;
  INSERT INTO public.workspace_runtime_quotas(workspace_id,active_execution_count) VALUES(selected_workspace,active_count+active_delta)
  ON CONFLICT(workspace_id) DO UPDATE SET active_execution_count=EXCLUDED.active_execution_count,revision=workspace_runtime_quotas.revision+1;
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END $$;

/* Kiểm đủ1..5 action liên tiếp và tổngWAIT≤600s tại cuối publish/save batch.
 * Input: NEW parent/action hoặc OLD child DELETE. Output:NULL; Errors:23514 nếu thiếu/lệch/budget.
 * AST và reference bijection vẫn là boundary validator backend, không suy từ CHECK JSON object.
 */
CREATE FUNCTION validate_rule_action_cardinality() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE selected_workspace uuid; selected_version uuid; action_count integer; last_position integer; total_wait integer; BEGIN
 selected_workspace:=CASE WHEN TG_OP='DELETE' THEN OLD.workspace_id ELSE NEW.workspace_id END;
 selected_version:=CASE WHEN TG_OP='DELETE' THEN OLD.rule_version_id ELSE NEW.rule_version_id END;
 IF EXISTS(SELECT 1 FROM public.rule_versions WHERE(workspace_id,rule_version_id)=(selected_workspace,selected_version)) THEN
  SELECT count(*),max(action_position),coalesce(sum(wait_seconds),0) INTO action_count,last_position,total_wait FROM public.rule_version_actions
  WHERE(workspace_id,rule_version_id)=(selected_workspace,selected_version);
  IF action_count NOT BETWEEN 1 AND 5 OR last_position<>action_count-1 OR total_wait>600 THEN
   RAISE EXCEPTION 'Rule action sequence is invalid' USING ERRCODE='23514',CONSTRAINT='ck_rule_action_cardinality';
  END IF;
 END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER ct_rule_version_actions AFTER INSERT ON rule_versions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION validate_rule_action_cardinality();
CREATE CONSTRAINT TRIGGER ct_rule_actions AFTER INSERT OR UPDATE OR DELETE ON rule_version_actions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION validate_rule_action_cardinality();

/* Không thêm grant device/scope vào key đã cấp ở transaction khác.
 * Published helper dùng cùng parent identity; consumer rotate phải tạo keyId mới.
 */
CREATE TRIGGER tr_api_device_sealed BEFORE INSERT ON api_key_devices FOR EACH ROW EXECUTE FUNCTION enforce_published_child_insert('api_keys','api_key_id');
CREATE TRIGGER tr_api_scope_sealed BEFORE INSERT ON api_key_scopes FOR EACH ROW EXECUTE FUNCTION enforce_published_child_insert('api_keys','api_key_id');
/* Không có hai enrollment nonterminal/device; guard cleanup vẫn tồn tại sau terminal. */
CREATE UNIQUE INDEX uq_enrollment_sessions_active_device ON enrollment_sessions(workspace_id,device_id)
 WHERE state IN ('CREATED','BLE_CONNECTED','WIFI_JOINED','CLOUD_CONNECTING');

/* Guard chỉ được release khi hoàn tất hoặc cleanup có đủ hai proof.
 * Input: OLD guard bị DELETE. Output:OLD; Errors:23514 nếu TTL/terminal chưa có cleanup proof.
 */
CREATE FUNCTION validate_enrollment_guard_release() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.enrollment_sessions WHERE(workspace_id,enrollment_session_id)=(OLD.workspace_id,OLD.enrollment_session_id) AND state='COMPLETED') AND
    NOT EXISTS(SELECT 1 FROM public.enrollment_cleanup_operations WHERE(workspace_id,enrollment_session_id)=(OLD.workspace_id,OLD.enrollment_session_id)
    AND settled_at IS NOT NULL AND broker_revoke_receipt IS NOT NULL AND disconnect_receipt IS NOT NULL AND state='SUCCEEDED') THEN
  RAISE EXCEPTION 'Enrollment cleanup proof is required' USING ERRCODE='23514',CONSTRAINT='ck_enrollment_guard_release';
 END IF;
 RETURN OLD;
END $$;
CREATE TRIGGER tr_enrollment_guard_release BEFORE DELETE ON device_enrollment_guards FOR EACH ROW EXECUTE FUNCTION validate_enrollment_guard_release();

/* Claim bounded batch ngắn bằng SKIP LOCKED; mỗi lần tăng lease_generation trước network.
 * Input
 * Param: target_consumer — pipeline cố định do backend chọn.
 * Param: lease_seconds — thời gian giữ lease1..300s của vận hành, không TTL nghiệp vụ.
 * Param: batch_limit — số claim1..1000, giới hạn tài nguyên mỗi transaction.
 * Output: outbox IDs/generation được claim; Errors:22023 khi tham số ngoài miền.
 */
CREATE FUNCTION claim_outbox(target_consumer text,lease_seconds integer,batch_limit integer)
RETURNS TABLE(claimed_event_id uuid,claimed_generation bigint) LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 IF lease_seconds NOT BETWEEN 1 AND 300 OR batch_limit NOT BETWEEN 1 AND 1000 OR target_consumer IS NULL OR btrim(target_consumer)='' THEN
  RAISE EXCEPTION 'Invalid lease parameters' USING ERRCODE='22023';
 END IF;
 RETURN QUERY WITH candidates AS (
  SELECT consumption.outbox_event_id,consumption.consumer_code FROM public.outbox_consumptions consumption
  WHERE consumption.consumer_code=target_consumer AND consumption.available_at<=clock_timestamp() AND
   (consumption.state IN ('PENDING','RETRY_WAIT') OR (consumption.state='PROCESSING' AND consumption.lease_until<=clock_timestamp()))
  ORDER BY consumption.available_at,consumption.outbox_event_id LIMIT batch_limit FOR UPDATE SKIP LOCKED
 ) UPDATE public.outbox_consumptions consumption SET state='PROCESSING',lease_generation=consumption.lease_generation+1,
  lease_until=clock_timestamp()+make_interval(secs=>lease_seconds),attempt_count=consumption.attempt_count+1
 FROM candidates WHERE(consumption.outbox_event_id,consumption.consumer_code)=(candidates.outbox_event_id,candidates.consumer_code)
 RETURNING consumption.outbox_event_id,consumption.lease_generation;
END $$;

/* Stale worker không settle được sau takeover/expiry; false là CAS thất bại, không retry side effect.
 * Input: target_event/consumer/generation là receipt claim. Output:boolean một winner.
 * Side effects: chuyển COMPLETED và xóa lease chỉ khi generation hiện hành còn hiệu lực.
 */
CREATE FUNCTION complete_outbox(target_event uuid,target_consumer text,expected_generation bigint) RETURNS boolean LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 UPDATE public.outbox_consumptions SET state='COMPLETED',completed_at=clock_timestamp(),lease_until=NULL
 WHERE outbox_event_id=target_event AND consumer_code=target_consumer AND state='PROCESSING'
 AND lease_generation=expected_generation AND lease_until>clock_timestamp();
 RETURN FOUND;
END $$;

/* Consume websocket ticket một lần, recheck session/grant/membership/account/workspace ngay tại UPDATE.
 * Input: presented_digest là SHA256 của ticket ngoài DB. Output:boolean một winner còn quyền.
 * Side effects: consumed_at; không trả raw ticket hoặc mở socket trước commit.
 */
CREATE FUNCTION consume_websocket_ticket(presented_digest bytea) RETURNS boolean LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 UPDATE public.websocket_tickets ticket SET consumed_at=clock_timestamp()
 FROM public.sessions session_row, public.memberships membership, public.membership_grants grant_row, public.users account,public.workspaces workspace
 WHERE ticket.ticket_digest=presented_digest AND ticket.consumed_at IS NULL AND ticket.revoked_at IS NULL AND ticket.expires_at>clock_timestamp()
 AND session_row.session_id=ticket.session_id AND session_row.user_id=ticket.user_id AND session_row.revoked_at IS NULL AND NOT session_row.limited AND session_row.expires_at>clock_timestamp()
 AND membership.workspace_id=ticket.workspace_id AND membership.user_id=ticket.user_id AND membership.status='ACTIVE'
 AND membership.current_grant_generation=ticket.grant_generation AND membership.authorization_version=ticket.membership_authorization_version
 AND(grant_row.workspace_id,grant_row.user_id,grant_row.grant_generation)=(membership.workspace_id,membership.user_id,membership.current_grant_generation) AND grant_row.revoked_at IS NULL
 AND account.user_id=ticket.user_id AND account.account_status='ACTIVE' AND NOT account.must_change_password
 AND workspace.workspace_id=ticket.workspace_id AND workspace.status='ACTIVE' AND workspace.authorization_version=ticket.workspace_authorization_version;
 RETURN FOUND;
END $$;

/* Purge raw tối đa một batch, giữ receipt/floor để không resurrect replay.
 * Input: batch_limit1..10000 là giới hạn vận hành. Output:số envelope xóa; lỗi22023 nếu ngoài miền.
 * Side effects: khóa envelope cũ>7d, xóa points rồi envelope atomically; không xóa dedupe ledger.
 */
CREATE FUNCTION purge_expired_telemetry(batch_limit integer) RETURNS integer LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE target record; removed_count integer:=0; BEGIN
 IF batch_limit NOT BETWEEN 1 AND 10000 THEN RAISE EXCEPTION 'Invalid retention batch' USING ERRCODE='22023'; END IF;
 SET CONSTRAINTS ct_points_count DEFERRED;
 FOR target IN SELECT workspace_id,envelope_id FROM public.telemetry_envelopes WHERE received_at<=statement_timestamp()-interval '7 days'
  ORDER BY received_at,workspace_id,envelope_id LIMIT batch_limit FOR UPDATE SKIP LOCKED LOOP
  DELETE FROM public.telemetry_points WHERE(workspace_id,envelope_id)=(target.workspace_id,target.envelope_id);
  DELETE FROM public.telemetry_envelopes WHERE(workspace_id,envelope_id)=(target.workspace_id,target.envelope_id);
  removed_count:=removed_count+1;
 END LOOP;
 RETURN removed_count;
END $$;
/* Cutoff trước scope để retention quét theo tuổi; query history vẫn dùng index theo tenant/device. */
CREATE INDEX ix_telemetry_retention ON telemetry_envelopes(received_at,workspace_id,envelope_id);
/* Bổ sung index FK chỉ khi chưa có prefix tương ứng, giảm scan/lock khi kiểm parent/purge.
 * Tên và cột lấy từ pg_catalog của schema này; không index JSON hay mọi cột tùy tiện.
 */
DO $$ DECLARE reference_row record; BEGIN
 FOR reference_row IN SELECT constraint_row.oid,constraint_row.conrelid,constraint_row.conkey,table_row.relname,
   string_agg(quote_ident(attribute.attname),',' ORDER BY key_column.position) AS columns
  FROM pg_constraint constraint_row JOIN pg_class table_row ON table_row.oid=constraint_row.conrelid
  JOIN pg_namespace namespace_row ON namespace_row.oid=table_row.relnamespace
  CROSS JOIN LATERAL unnest(constraint_row.conkey) WITH ORDINALITY AS key_column(attribute_number,position)
  JOIN pg_attribute attribute ON attribute.attrelid=table_row.oid AND attribute.attnum=key_column.attribute_number
  WHERE constraint_row.contype='f' AND namespace_row.nspname='public'
  GROUP BY constraint_row.oid,constraint_row.conrelid,constraint_row.conkey,table_row.relname ORDER BY constraint_row.oid LOOP
  IF NOT EXISTS(SELECT 1 FROM pg_index index_row WHERE index_row.indrelid=reference_row.conrelid AND index_row.indisvalid AND index_row.indpred IS NULL AND
    ARRAY(SELECT attribute_number FROM unnest(index_row.indkey) WITH ORDINALITY AS index_key(attribute_number,position) WHERE position<=cardinality(reference_row.conkey))=reference_row.conkey) THEN
   EXECUTE format('CREATE INDEX %I ON public.%I(%s)','ix_fk_'||reference_row.relname||'_'||substr(md5(reference_row.columns),1,8),reference_row.relname,reference_row.columns);
  END IF;
 END LOOP;
END $$;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC,iot_runtime;
