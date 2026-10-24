/* Đóng NULL boundary và admission fence của các entry point0009; chỉ forward migration. */
/* Claim bounded lease, NULL không được biến LIMIT thành không giới hạn hoặc tạo lease vô hạn.
 * Input
 * Param: target_consumer — consumer đã cấu hình phía server.
 * Param: lease_seconds — thời gian lease1..300s, không thay expiry nghiệp vụ.
 * Param: batch_limit — số hàng claim1..1000 trong một transaction ngắn.
 * Output: cặp event/generation đã claim; Errors:22023 nếu input không hợp lệ.
 */
CREATE OR REPLACE FUNCTION claim_outbox(target_consumer text,lease_seconds integer,batch_limit integer)
RETURNS TABLE(claimed_event_id uuid,claimed_generation bigint) LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 IF lease_seconds IS NULL OR batch_limit IS NULL OR lease_seconds NOT BETWEEN 1 AND 300 OR batch_limit NOT BETWEEN 1 AND 1000 OR target_consumer IS NULL OR btrim(target_consumer)='' THEN
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

/* Ticket consume lấy cùng User→Workspace fence với mutation membership, khóa phiên trước CAS.
 * Input
 * Param: presented_digest — SHA256 của ticket client, không raw ticket.
 * Output:boolean cho admission thắng và còn quyền; Side effects:consumed_at một lần.
 */
CREATE OR REPLACE FUNCTION consume_websocket_ticket(presented_digest bytea) RETURNS boolean LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE selected_user uuid; selected_workspace uuid; selected_session uuid; BEGIN
 SELECT user_id,workspace_id,session_id INTO selected_user,selected_workspace,selected_session FROM public.websocket_tickets WHERE ticket_digest=presented_digest;
 IF NOT FOUND THEN RETURN false; END IF;
 UPDATE public.users SET account_status=account_status WHERE user_id=selected_user;
 UPDATE public.workspaces SET authorization_version=authorization_version WHERE workspace_id=selected_workspace;
 PERFORM 1 FROM public.sessions WHERE session_id=selected_session FOR SHARE;
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

/* Purge raw theo cutoff7d, batch không NULL, giữ receipt authority và frontier chưa compact.
 * Input
 * Param: batch_limit — tối đa1..10000 envelope mỗi lượt để giữ lock/transaction có giới hạn.
 * Output:số envelope xóa; Errors:22023 khi batch sai; Side effects:xóa points rồi parent.
 */
CREATE OR REPLACE FUNCTION purge_expired_telemetry(batch_limit integer) RETURNS integer LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE target record; removed_count integer:=0; BEGIN
 IF batch_limit IS NULL OR batch_limit NOT BETWEEN 1 AND 10000 THEN RAISE EXCEPTION 'Invalid retention batch' USING ERRCODE='22023'; END IF;
 SET CONSTRAINTS ct_points_count DEFERRED;
 FOR target IN SELECT workspace_id,envelope_id FROM public.telemetry_envelopes WHERE received_at<=statement_timestamp()-interval '7 days'
  ORDER BY received_at,workspace_id,envelope_id LIMIT batch_limit FOR UPDATE SKIP LOCKED LOOP
  DELETE FROM public.telemetry_points WHERE(workspace_id,envelope_id)=(target.workspace_id,target.envelope_id);
  DELETE FROM public.telemetry_envelopes WHERE(workspace_id,envelope_id)=(target.workspace_id,target.envelope_id);
  removed_count:=removed_count+1;
 END LOOP;
 RETURN removed_count;
END $$;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC,iot_runtime;
