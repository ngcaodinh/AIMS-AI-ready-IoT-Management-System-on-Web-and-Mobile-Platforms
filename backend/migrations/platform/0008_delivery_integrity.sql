/* Hoàn thiện identity, retry budget và các invariant còn lại sau0007.
 * Không mở writer runtime; owner là boundary tin cậy cho DDL/retention/validator chữ ký.
 */
/* Khóa các cột identity được trigger truyền tên tường minh, không khóa state được phép đổi.
 * Input: OLD/NEW và TG_ARGV là danh sách cột nội bộ. Output:NEW; Errors:23514 khi identity đổi.
 */
CREATE FUNCTION enforce_identity_columns() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE column_name text; BEGIN
 FOREACH column_name IN ARRAY TG_ARGV LOOP
  IF to_jsonb(NEW)->column_name IS DISTINCT FROM to_jsonb(OLD)->column_name THEN
   RAISE EXCEPTION 'Resource identity is immutable' USING ERRCODE='23514',CONSTRAINT='ck_resource_identity_immutable';
  END IF;
 END LOOP;
 RETURN NEW;
END $$;
/* Mọi PK giữ nguyên trong vòng đời; FK reference không bị UPDATE key kéo sang identity khác. */
DO $$ DECLARE relation record; BEGIN
 FOR relation IN SELECT table_row.relname, string_agg(quote_literal(attribute.attname),',' ORDER BY key_column.position) AS arguments
  FROM pg_constraint constraint_row JOIN pg_class table_row ON table_row.oid=constraint_row.conrelid
  JOIN pg_namespace namespace_row ON namespace_row.oid=table_row.relnamespace
  CROSS JOIN LATERAL unnest(constraint_row.conkey) WITH ORDINALITY AS key_column(attribute_number,position)
  JOIN pg_attribute attribute ON attribute.attrelid=table_row.oid AND attribute.attnum=key_column.attribute_number
  WHERE namespace_row.nspname='public' AND constraint_row.contype='p' GROUP BY table_row.relname LOOP
  EXECUTE format('CREATE TRIGGER tr_identity_columns BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.enforce_identity_columns(%s)',relation.relname,relation.arguments);
 END LOOP;
END $$;
CREATE TRIGGER tr_device_pin_identity BEFORE UPDATE ON devices FOR EACH ROW EXECUTE FUNCTION enforce_identity_columns('workspace_id','template_version_id','owner_user_id','serial_number','model','hardware_revision');
CREATE TRIGGER tr_workspace_creator_identity BEFORE UPDATE ON workspaces FOR EACH ROW EXECUTE FUNCTION enforce_identity_columns('created_by_user_id','created_at');
CREATE TRIGGER tr_rule_owner_identity BEFORE UPDATE ON rules FOR EACH ROW EXECUTE FUNCTION enforce_identity_columns('owner_user_id');
CREATE TRIGGER tr_dashboard_owner_identity BEFORE UPDATE ON dashboards FOR EACH ROW EXECUTE FUNCTION enforce_identity_columns('owner_user_id');
CREATE TRIGGER tr_notification_identity BEFORE UPDATE ON notifications FOR EACH ROW EXECUTE FUNCTION enforce_identity_columns('recipient_user_id','kind','event_id','target_type','target_device_id','target_rule_execution_id','created_at');
CREATE TRIGGER tr_push_identity BEFORE UPDATE ON push_deliveries FOR EACH ROW EXECUTE FUNCTION enforce_identity_columns('notification_id','installation_id','recipient_user_id','binding_generation','created_at','expires_at');
CREATE TRIGGER tr_api_key_identity BEFORE UPDATE ON api_keys FOR EACH ROW EXECUTE FUNCTION enforce_identity_columns('owner_user_id','owner_grant_generation','verifier_digest','issued_at','expires_at','prefix');
CREATE TRIGGER tr_webhook_delivery_identity BEFORE UPDATE ON webhook_deliveries FOR EACH ROW EXECUTE FUNCTION enforce_identity_columns('webhook_subscription_id','kind','occurrence_id','endpoint_url_snapshot','endpoint_revision_snapshot','secret_version','raw_body','body_digest','admitted_at','expires_at');
CREATE TRIGGER tr_ota_identity BEFORE UPDATE ON ota_jobs FOR EACH ROW EXECUTE FUNCTION enforce_identity_columns('device_id','firmware_package_id','source_firmware_version_snapshot','target_artifact_digest_snapshot','job_nonce','maintenance_epoch','admitted_at','deadline_at');
CREATE TRIGGER tr_enrollment_identity BEFORE UPDATE ON enrollment_sessions FOR EACH ROW EXECUTE FUNCTION enforce_identity_columns('device_id','actor_user_id','actor_grant_generation','client_installation_id','enrollment_proof_digest','mode','started_at','expires_at');

/* Hạn chế current-pointer cập nhật phải có grant mới hơn; tombstone không tái dùng generation.
 * Input: OLD/NEW membership. Output:NEW; Errors:23514 nếu generation giảm/rejoin grant cũ.
 */
CREATE FUNCTION enforce_membership_generation() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 IF NEW.current_grant_generation<OLD.current_grant_generation OR
  (OLD.status='REMOVED' AND NEW.status<>'REMOVED' AND NEW.current_grant_generation<=OLD.current_grant_generation) THEN
  RAISE EXCEPTION 'Membership cannot reuse old grant' USING ERRCODE='23514',CONSTRAINT='ck_membership_generation';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_membership_generation BEFORE UPDATE ON memberships FOR EACH ROW EXECUTE FUNCTION enforce_membership_generation();

/* Password/account đổi thu hồi toàn bộ phiên cũ trong cùng commit; phiên mới tạo sau mutation.
 * Input: OLD/NEW User. Output:NULL; Side effects: revoke unrevoked sessions, không đọc credential.
 */
CREATE FUNCTION revoke_changed_account_sessions() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 IF NEW.password_hash IS DISTINCT FROM OLD.password_hash OR (NEW.account_status='DISABLED' AND OLD.account_status<>'DISABLED') OR
   (NEW.must_change_password AND NOT OLD.must_change_password) THEN
  UPDATE public.sessions SET revoked_at=clock_timestamp() WHERE user_id=NEW.user_id AND revoked_at IS NULL;
 END IF;
 RETURN NULL;
END $$;
CREATE TRIGGER tr_user_revoke_sessions AFTER UPDATE ON users FOR EACH ROW EXECUTE FUNCTION revoke_changed_account_sessions();

/* Capability phải đúng writable pin/type; ENUM có literal đã khai, safeValue không nullable.
 * Input: NEW capability snapshot. Output:NEW; Errors:23514 nếu READ/STRING hoặc safe value sai.
 */
CREATE FUNCTION validate_datastream_capability() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE definition public.datastream_definitions; BEGIN
 SELECT * INTO definition FROM public.datastream_definitions WHERE(workspace_id,template_version_id,stream_key)=(NEW.workspace_id,NEW.template_version_id,NEW.stream_key);
 IF definition.direction='READ' OR definition.data_type='STRING' THEN RAISE EXCEPTION 'Capability requires writable stream' USING ERRCODE='23514',CONSTRAINT='ck_stream_writable'; END IF;
 PERFORM public.assert_stream_value(definition,NEW.safe_value,false);
 RETURN NEW;
END $$;
CREATE TRIGGER tr_capability_validate BEFORE INSERT ON datastream_capabilities FOR EACH ROW EXECUTE FUNCTION validate_datastream_capability();

/* Cardinality cuối batch: tối đa5 device/key, scope không rỗng; khóa parent chống count race.
 * Input: NEW child key/device/scope. Output:NEW; Errors:23514 khi quá cap; mọi writer cùng anchor.
 */
CREATE FUNCTION fence_api_key_children() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 UPDATE public.api_keys SET revision=revision WHERE(workspace_id,api_key_id)=(NEW.workspace_id,NEW.api_key_id);
 RETURN NEW;
END $$;
CREATE TRIGGER tr_api_key_device_fence BEFORE INSERT ON api_key_devices FOR EACH ROW EXECUTE FUNCTION fence_api_key_children();
CREATE TRIGGER tr_api_key_scope_fence BEFORE INSERT ON api_key_scopes FOR EACH ROW EXECUTE FUNCTION fence_api_key_children();

/* Check deferred hỗ trợ tạo principal và allowlist/scopes nguyên tử, không principal rỗng.
 * Input: NEW parent/OLD/NEW child. Output:NULL; Errors:23514 nếu không1..5devices hoặc scope rỗng.
 */
CREATE FUNCTION validate_api_key_cardinality() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE selected_workspace uuid; selected_key uuid; device_count bigint; BEGIN
 selected_workspace:=CASE WHEN TG_OP='DELETE' THEN OLD.workspace_id ELSE NEW.workspace_id END;
 selected_key:=CASE WHEN TG_OP='DELETE' THEN OLD.api_key_id ELSE NEW.api_key_id END;
 IF EXISTS(SELECT 1 FROM public.api_keys WHERE(workspace_id,api_key_id)=(selected_workspace,selected_key)) THEN
  SELECT count(*) INTO device_count FROM public.api_key_devices WHERE(workspace_id,api_key_id)=(selected_workspace,selected_key);
  IF device_count NOT BETWEEN 1 AND 5 OR NOT EXISTS(SELECT 1 FROM public.api_key_scopes WHERE(workspace_id,api_key_id)=(selected_workspace,selected_key)) THEN
   RAISE EXCEPTION 'API key requires 1..5 devices and nonempty scopes' USING ERRCODE='23514',CONSTRAINT='ck_api_key_cardinality';
  END IF;
 END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER ct_api_key_cardinality AFTER INSERT ON api_keys DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION validate_api_key_cardinality();
CREATE CONSTRAINT TRIGGER ct_api_key_devices AFTER INSERT OR DELETE ON api_key_devices DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION validate_api_key_cardinality();
CREATE CONSTRAINT TRIGGER ct_api_key_scopes AFTER INSERT OR DELETE ON api_key_scopes DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION validate_api_key_cardinality();

/* Push expiry neo Notification.created_at; rebind không thay fanout/expiry đã đóng băng.
 * Input: NEW delivery. Output:NEW; Errors:23514 nếu không đúng gốc notification hoặc binding.
 */
CREATE FUNCTION validate_push_delivery() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE notification_time timestamptz; installation public.push_installations; BEGIN
 SELECT created_at INTO notification_time FROM public.notifications WHERE(workspace_id,notification_id)=(NEW.workspace_id,NEW.notification_id);
 SELECT * INTO installation FROM public.push_installations WHERE installation_id=NEW.installation_id;
 IF NEW.created_at IS DISTINCT FROM notification_time OR NEW.binding_generation IS DISTINCT FROM installation.binding_generation OR
    NEW.recipient_user_id IS DISTINCT FROM installation.active_user_id THEN
  RAISE EXCEPTION 'Push delivery snapshot is inconsistent' USING ERRCODE='23514',CONSTRAINT='ck_push_delivery_snapshot';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_push_delivery_validate BEFORE INSERT ON push_deliveries FOR EACH ROW EXECUTE FUNCTION validate_push_delivery();

/* Webhook BUSINESS dùng occurrence.committed_at+24h, TEST riêng30s và không Event giả.
 * Input: NEW delivery. Output:NEW; Errors:23514 nếu deadline/body hash/secret metadata không hợp lệ.
 * Hash phải được producer tính SHA256; không thêm extension crypto chưa được duyệt.
 */
CREATE FUNCTION validate_webhook_delivery() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE occurrence_time timestamptz; BEGIN
 IF NEW.kind='BUSINESS' THEN
  SELECT committed_at INTO occurrence_time FROM public.event_occurrences WHERE(workspace_id,occurrence_id)=(NEW.workspace_id,NEW.occurrence_id) AND public_event_type IS NOT NULL;
  IF occurrence_time IS NULL OR NEW.expires_at IS DISTINCT FROM occurrence_time+interval '24 hours' THEN
   RAISE EXCEPTION 'Webhook expiry must use original occurrence commit' USING ERRCODE='23514',CONSTRAINT='ck_webhook_occurrence_expiry';
  END IF;
 END IF;
 IF NOT EXISTS(SELECT 1 FROM public.webhook_secret_versions WHERE(workspace_id,webhook_subscription_id,secret_version)=(NEW.workspace_id,NEW.webhook_subscription_id,NEW.secret_version) AND secret_ciphertext IS NOT NULL) THEN
  RAISE EXCEPTION 'Webhook secret is unavailable' USING ERRCODE='23514',CONSTRAINT='ck_webhook_secret_available';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_webhook_delivery_validate BEFORE INSERT ON webhook_deliveries FOR EACH ROW EXECUTE FUNCTION validate_webhook_delivery();

/* Một manual batch mở lại DEAD_LETTER trên chính delivery, không đổi body/key/occurrence.
 * Input: OLD/NEW. Output:NEW; Errors:23514 nếu batch thứhai hoặc rewind terminal trái contract.
 */
CREATE FUNCTION enforce_delivery_transition() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 IF TG_TABLE_NAME='webhook_deliveries' THEN
  IF NEW.manual_batch_count<>OLD.manual_batch_count AND NOT(OLD.manual_batch_count=0 AND NEW.manual_batch_count=1 AND
    OLD.kind='BUSINESS' AND OLD.state='DEAD_LETTER' AND NEW.state='PENDING' AND NEW.expires_at>clock_timestamp()) THEN
   RAISE EXCEPTION 'Invalid webhook manual retry batch' USING ERRCODE='23514',CONSTRAINT='ck_webhook_manual_batch';
  END IF;
  IF OLD.state IN ('ACCEPTED','FAILED','CANCELLED') AND NEW.state<>OLD.state THEN
   RAISE EXCEPTION 'Webhook terminal cannot rewind' USING ERRCODE='23514',CONSTRAINT='ck_delivery_terminal';
  END IF;
  IF OLD.state='DEAD_LETTER' AND NEW.state<>'DEAD_LETTER' AND NOT(NEW.state='PENDING' AND OLD.manual_batch_count=0 AND NEW.manual_batch_count=1 AND NEW.expires_at>clock_timestamp()) THEN
   RAISE EXCEPTION 'Dead letter requires explicit manual batch' USING ERRCODE='23514',CONSTRAINT='ck_webhook_manual_batch';
  END IF;
 ELSE
  IF OLD.state IN ('ACCEPTED','FAILED','EXPIRED','SUPPRESSED') AND NEW.state<>OLD.state THEN
   RAISE EXCEPTION 'Push terminal cannot rewind' USING ERRCODE='23514',CONSTRAINT='ck_delivery_terminal';
  END IF;
 END IF;
 IF NEW.lease_generation<OLD.lease_generation THEN RAISE EXCEPTION 'Lease cannot go backwards' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_push_transition BEFORE UPDATE ON push_deliveries FOR EACH ROW EXECUTE FUNCTION enforce_delivery_transition();
CREATE TRIGGER tr_webhook_transition BEFORE UPDATE ON webhook_deliveries FOR EACH ROW EXECUTE FUNCTION enforce_delivery_transition();

/* Intent consume budget trước network; sequence liên tiếp và neo deadline parent.
 * Input: NEW push/webhook attempt. Output:NEW; Errors:23514 khi hết hạn/budget hoặc skip số.
 */
CREATE FUNCTION validate_delivery_attempt() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE expires_at_value timestamptz; expected_number integer; parent_kind text; manual_count integer; parent_state text; BEGIN
 IF TG_TABLE_NAME='push_delivery_attempts' THEN
  SELECT expires_at,state INTO expires_at_value,parent_state FROM public.push_deliveries
   WHERE(workspace_id,push_delivery_id)=(NEW.workspace_id,NEW.push_delivery_id) FOR UPDATE;
  SELECT coalesce(max(attempt_number),0)+1 INTO expected_number FROM public.push_delivery_attempts WHERE(workspace_id,push_delivery_id)=(NEW.workspace_id,NEW.push_delivery_id);
 ELSE
  SELECT expires_at,kind,manual_batch_count,state INTO expires_at_value,parent_kind,manual_count,parent_state FROM public.webhook_deliveries
   WHERE(workspace_id,webhook_delivery_id)=(NEW.workspace_id,NEW.webhook_delivery_id) FOR UPDATE;
  SELECT coalesce(max(attempt_number),0)+1 INTO expected_number FROM public.webhook_delivery_attempts WHERE(workspace_id,webhook_delivery_id)=(NEW.workspace_id,NEW.webhook_delivery_id);
  IF (parent_kind='TEST' AND NEW.attempt_number<>1) OR NEW.batch_number>manual_count THEN
   RAISE EXCEPTION 'Delivery attempt budget exceeded' USING ERRCODE='23514',CONSTRAINT='ck_delivery_attempt_budget';
  END IF;
 END IF;
 IF expires_at_value IS NULL OR NEW.intent_at>=expires_at_value OR NEW.attempt_number<>expected_number OR parent_state<>'SENDING' THEN
  RAISE EXCEPTION 'Delivery attempt is ineligible' USING ERRCODE='23514',CONSTRAINT='ck_delivery_attempt_admission';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_push_attempt_admission BEFORE INSERT ON push_delivery_attempts FOR EACH ROW EXECUTE FUNCTION validate_delivery_attempt();
CREATE TRIGGER tr_webhook_attempt_admission BEFORE INSERT ON webhook_delivery_attempts FOR EACH ROW EXECUTE FUNCTION validate_delivery_attempt();
CREATE TRIGGER tr_push_attempt_identity BEFORE UPDATE ON push_delivery_attempts FOR EACH ROW EXECUTE FUNCTION enforce_identity_columns('intent_at','token_generation');
CREATE TRIGGER tr_webhook_attempt_identity BEFORE UPDATE ON webhook_delivery_attempts FOR EACH ROW EXECUTE FUNCTION enforce_identity_columns('batch_number','intent_at','request_digest');

/* OTA giữ slot cho tới settlement; terminal success/rollback bắt buộc proof ở service.
 * Input: OLD/NEW OTA. Output:NEW; Errors:23514 nếu tự release recovery hoặc thay trạng thái settled.
 */
CREATE FUNCTION enforce_ota_settlement() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 IF NEW.settled_at IS NOT NULL AND NEW.state NOT IN ('SUCCEEDED','FAILED','CANCELLED','ROLLED_BACK') THEN
  RAISE EXCEPTION 'OTA cannot release unresolved maintenance' USING ERRCODE='23514',CONSTRAINT='ck_ota_settlement';
 END IF;
 IF TG_OP='UPDATE' AND OLD.settled_at IS NOT NULL AND NEW IS DISTINCT FROM OLD THEN
  RAISE EXCEPTION 'Settled OTA is immutable' USING ERRCODE='23514',CONSTRAINT='ck_ota_settlement';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_ota_settlement BEFORE INSERT OR UPDATE ON ota_jobs FOR EACH ROW EXECUTE FUNCTION enforce_ota_settlement();

/* Typed OTA receipt/ticket phải cùng job deadline; tránh bearer ticket sống quá intent.
 * Input: NEW ticket. Output:NEW; Errors:23514 khi ticket vượt deadline job.
 */
CREATE FUNCTION validate_ota_ticket_expiry() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.ota_jobs WHERE(workspace_id,ota_job_id)=(NEW.workspace_id,NEW.ota_job_id) AND NEW.expires_at<=deadline_at) THEN
  RAISE EXCEPTION 'OTA ticket exceeds job deadline' USING ERRCODE='23514',CONSTRAINT='ck_ota_ticket_expiry';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_ota_ticket_expiry BEFORE INSERT ON ota_download_tickets FOR EACH ROW EXECUTE FUNCTION validate_ota_ticket_expiry();

/* Logical retention không chờ cron; không grant view này cho role thiếu authorization scope. */
CREATE VIEW telemetry_history WITH(security_invoker=true) AS SELECT point.* FROM telemetry_points point
 JOIN telemetry_envelopes envelope USING(workspace_id,envelope_id)
 WHERE envelope.received_at>statement_timestamp()-interval '7 days';
CREATE VIEW audit_history WITH(security_invoker=true) AS SELECT * FROM audit_events WHERE occurred_at>statement_timestamp()-interval '30 days';
CREATE VIEW execution_history WITH(security_invoker=true) AS SELECT * FROM rule_executions WHERE admitted_at>statement_timestamp()-interval '30 days';
CREATE VIEW push_delivery_history WITH(security_invoker=true) AS SELECT * FROM push_deliveries WHERE created_at>statement_timestamp()-interval '30 days';
CREATE VIEW webhook_delivery_history WITH(security_invoker=true) AS SELECT * FROM webhook_deliveries WHERE admitted_at>statement_timestamp()-interval '30 days';
/* Replay receipts và operational UNKNOWN không bị view retention xóa authority. */
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC,iot_runtime;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC,iot_runtime;
