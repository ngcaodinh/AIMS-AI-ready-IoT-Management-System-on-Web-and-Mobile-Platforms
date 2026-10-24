/* Cưỡng chế invariant liên hàng sau khi toàn bộ graph FK đã tồn tại.
 * Migration dùng transaction; engine mới/trống, không sửa checksum0001..0006.
 * Runtime chưa được cấp writer; service vẫn phải authorize hiện hành trước replay/dispatch.
 */
/* Đồng bộ enum lifecycle theo handoff BR005; connectivity khác lifecycle. */
ALTER TABLE devices DROP CONSTRAINT devices_lifecycle_status_check;
ALTER TABLE devices ALTER COLUMN lifecycle_status SET DEFAULT 'REGISTERED';
ALTER TABLE devices ADD CONSTRAINT ck_device_lifecycle CHECK(lifecycle_status IN ('REGISTERED','ACTIVE','SUSPENDED','ARCHIVED'));
ALTER TABLE device_runtime DROP CONSTRAINT device_runtime_presence_state_check;
ALTER TABLE device_runtime ALTER COLUMN presence_state SET DEFAULT 'UNKNOWN';
ALTER TABLE device_runtime ADD CONSTRAINT ck_device_presence CHECK(presence_state IN ('UNKNOWN','ONLINE','OFFLINE'));
ALTER TABLE device_credentials DROP CONSTRAINT device_credentials_credential_state_check;
ALTER TABLE device_credentials ADD CONSTRAINT ck_device_credential_state CHECK(credential_state IN ('PROVISIONING','ACTIVE','REVOCATION_PENDING','REVOKED'));
ALTER TABLE provisioning_operations DROP CONSTRAINT provisioning_operations_state_check;
ALTER TABLE provisioning_operations ADD CONSTRAINT ck_provisioning_state CHECK(state IN ('PENDING','READY','FAILED'));
ALTER TABLE provisioning_operations ADD COLUMN delivery_status text NOT NULL DEFAULT 'PENDING'
 CHECK(delivery_status IN ('PENDING','AVAILABLE','CLAIMED','EXPIRED','UNAVAILABLE'));
ALTER TABLE provisioning_operations ADD CONSTRAINT ck_provisioning_escrow_expiry CHECK(expires_at=intent_at+interval '10 minutes');
ALTER TABLE workspaces ADD CONSTRAINT ck_workspace_description CHECK(description IS NULL OR length(description)<=500);
ALTER TABLE devices ADD CONSTRAINT ck_device_serial CHECK(serial_number ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$');
/* Fence generation hiện hành phải tiến được dù invitation cũ còn giữ snapshot.
 * FK giữ identity fence; consume phải so snapshot generation, không FK vào mutable current value.
 */
DO $$ DECLARE constraint_name text; BEGIN
 SELECT conname INTO STRICT constraint_name FROM pg_constraint
 WHERE conrelid='public.workspace_invitations'::regclass AND confrelid='public.membership_admission_fences'::regclass;
 EXECUTE format('ALTER TABLE public.workspace_invitations DROP CONSTRAINT %I',constraint_name);
END $$;
ALTER TABLE workspace_invitations ADD CONSTRAINT fk_invitation_admission_identity
 FOREIGN KEY(workspace_id,email_digest) REFERENCES membership_admission_fences;

/* Giữ identity/admission của phiên; chỉ revocation NULL→timestamp được phép.
 * Input: OLD/NEW của phiên. Output: NEW hoặc23514; không nâng phiên limited tại chỗ.
 */
CREATE FUNCTION enforce_session_immutability() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 IF (to_jsonb(NEW)-'revoked_at') IS DISTINCT FROM (to_jsonb(OLD)-'revoked_at') THEN
  RAISE EXCEPTION 'Session identity is immutable' USING ERRCODE='23514',CONSTRAINT='ck_sessions_identity_immutable';
 END IF;
 IF OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at THEN
  RAISE EXCEPTION 'Session cannot be unrevoked' USING ERRCODE='23514',CONSTRAINT='ck_sessions_revocation_monotonic';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_sessions_immutable BEFORE UPDATE ON sessions FOR EACH ROW EXECUTE FUNCTION enforce_session_immutability();

/* Kiểm trạng thái cuối cùng của tenant, kể cả User đã disabled hoặc cần đổi mật khẩu.
 * Input: target_workspace_id là tenant cần giữ Admin. Output:void; Errors:23514 LAST_ADMIN.
 */
CREATE FUNCTION assert_workspace_capable_admin(target_workspace_id uuid) RETURNS void LANGUAGE plpgsql VOLATILE
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 IF EXISTS(SELECT 1 FROM public.workspaces WHERE workspace_id=target_workspace_id) AND NOT EXISTS(
  SELECT 1 FROM public.memberships membership JOIN public.users account USING(user_id)
  WHERE membership.workspace_id=target_workspace_id AND membership.role='ADMIN' AND membership.status='ACTIVE'
  AND account.account_status='ACTIVE' AND NOT account.must_change_password) THEN
  RAISE EXCEPTION 'Workspace requires a capable administrator' USING ERRCODE='23514',CONSTRAINT='ck_workspaces_capable_admin';
 END IF;
END $$;

/* Write fence User→Workspace làm RR phát hiện snapshot cũ, tránh write skew last Admin.
 * Input: membership OLD/NEW. Output: hàng phù hợp; Side effects: MVCC fence trên parent.
 * Batch caller pre-lock các ID tăng dần và retry40001/40P01 trước side effect ngoài DB.
 */
CREATE FUNCTION fence_membership_administrators() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE selected_user uuid; selected_workspace uuid; BEGIN
 IF TG_OP='UPDATE' AND ROW(NEW.workspace_id,NEW.user_id) IS DISTINCT FROM ROW(OLD.workspace_id,OLD.user_id) THEN
  RAISE EXCEPTION 'Membership identity is immutable' USING ERRCODE='23514';
 END IF;
 selected_user:=CASE WHEN TG_OP='DELETE' THEN OLD.user_id ELSE NEW.user_id END;
 selected_workspace:=CASE WHEN TG_OP='DELETE' THEN OLD.workspace_id ELSE NEW.workspace_id END;
 UPDATE public.users SET account_status=account_status WHERE user_id=selected_user;
 UPDATE public.workspaces SET authorization_version=authorization_version WHERE workspace_id=selected_workspace;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_membership_fence BEFORE INSERT OR UPDATE OR DELETE ON memberships FOR EACH ROW EXECUTE FUNCTION fence_membership_administrators();

/* Account state có thể làm mất Admin ở nhiều tenant; fence theo thứ tự ID ổn định.
 * Input: OLD/NEW User. Output:NEW; Side effects: parent fence, revoke phiên khi credential đổi.
 */
CREATE FUNCTION fence_user_workspaces() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE selected_workspace uuid; BEGIN
 IF ROW(NEW.account_status,NEW.must_change_password) IS DISTINCT FROM ROW(OLD.account_status,OLD.must_change_password) THEN
  FOR selected_workspace IN SELECT workspace_id FROM public.memberships WHERE user_id=OLD.user_id AND role='ADMIN' AND status='ACTIVE' ORDER BY workspace_id LOOP
   UPDATE public.workspaces SET authorization_version=authorization_version WHERE workspace_id=selected_workspace;
  END LOOP;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_user_workspace_fence BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION fence_user_workspaces();

/* Deferred check cho phép handoff Admin atomically; User mutation cũng kiểm tenant liên quan.
 * Input: TG_TABLE_NAME/OLD/NEW. Output:NULL; Errors:23514 nếu trạng thái cuối mất Admin.
 */
CREATE FUNCTION validate_capable_administrators() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE selected_workspace uuid; BEGIN
 IF TG_TABLE_NAME='workspaces' THEN
  PERFORM public.assert_workspace_capable_admin(NEW.workspace_id);
 ELSIF TG_TABLE_NAME='memberships' THEN
  PERFORM public.assert_workspace_capable_admin(CASE WHEN TG_OP='DELETE' THEN OLD.workspace_id ELSE NEW.workspace_id END);
 ELSE
  FOR selected_workspace IN SELECT workspace_id FROM public.memberships WHERE user_id=NEW.user_id AND role='ADMIN' AND status='ACTIVE' LOOP
   PERFORM public.assert_workspace_capable_admin(selected_workspace);
  END LOOP;
 END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER ct_workspace_admin AFTER INSERT OR UPDATE ON workspaces DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION validate_capable_administrators();
CREATE CONSTRAINT TRIGGER ct_membership_admin AFTER INSERT OR UPDATE OR DELETE ON memberships DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION validate_capable_administrators();
CREATE CONSTRAINT TRIGGER ct_user_admin AFTER UPDATE ON users DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
 WHEN(OLD.account_status IS DISTINCT FROM NEW.account_status OR OLD.must_change_password IS DISTINCT FROM NEW.must_change_password) EXECUTE FUNCTION validate_capable_administrators();

/* Creator quota5 serialize trên User có thật; Read Committed đọc count sau fence.
 * Input: NEW Workspace. Output:NEW; Errors:23514 khi user không đủ điều kiện hoặc quota đầy.
 */
CREATE FUNCTION enforce_workspace_creator_quota() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 UPDATE public.users SET account_status=account_status WHERE user_id=NEW.created_by_user_id;
 IF NOT EXISTS(SELECT 1 FROM public.users WHERE user_id=NEW.created_by_user_id AND account_status='ACTIVE' AND NOT must_change_password) THEN
  RAISE EXCEPTION 'Workspace creator is ineligible' USING ERRCODE='23514';
 END IF;
 IF (SELECT count(*) FROM public.workspaces WHERE created_by_user_id=NEW.created_by_user_id)>=5 THEN
  RAISE EXCEPTION 'Workspace quota exceeded' USING ERRCODE='23514',CONSTRAINT='ck_workspace_creator_quota';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_workspace_creator_quota BEFORE INSERT ON workspaces FOR EACH ROW EXECUTE FUNCTION enforce_workspace_creator_quota();

/* Tránh TRUNCATE bỏ qua row trigger và xóa evidence; purge hợp lệ dùng DELETE có kiểm.
 * Output: không thành công; Errors:23514 trên bảng protected được gắn trigger.
 */
CREATE FUNCTION reject_protected_truncate() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 RAISE EXCEPTION 'Protected relation cannot be truncated' USING ERRCODE='23514',CONSTRAINT='ck_protected_truncate';
END $$;

/* Không rewrite snapshot/receipt đã chấp nhận; DELETE do retention owner kiểm riêng.
 * Input: OLD/NEW UPDATE. Output:NEW nếu no-op; Errors:23514 nếu nội dung đổi.
 */
CREATE FUNCTION reject_immutable_update() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 IF NEW IS DISTINCT FROM OLD THEN RAISE EXCEPTION 'Immutable record cannot be rewritten' USING ERRCODE='23514',CONSTRAINT='ck_record_immutable'; END IF;
 RETURN NEW;
END $$;

/* Snapshot child chỉ thêm trong transaction tạo parent, không extend published version cũ.
 * Input: NEW và tên parent/column cố định từ trigger. Output:NEW; Errors:23514 nếu parent đã commit.
 */
CREATE FUNCTION enforce_published_child_insert() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE created_here boolean; BEGIN
 EXECUTE format('SELECT xmin=pg_current_xact_id()::text::xid FROM public.%I WHERE workspace_id=$1 AND %I=$2',TG_ARGV[0],TG_ARGV[1])
 INTO created_here USING NEW.workspace_id,(to_jsonb(NEW)->>TG_ARGV[1])::uuid;
 IF created_here IS DISTINCT FROM true THEN RAISE EXCEPTION 'Published content cannot be extended' USING ERRCODE='23514',CONSTRAINT='ck_published_child_sealed'; END IF;
 RETURN NEW;
END $$;

/* Grant identity/revocation monotonic bảo đảm remove/rejoin không hồi sinh quyền cũ.
 * Input: OLD/NEW grant. Output:NEW; Errors:23514 nếu sửa identity hoặc mở revocation.
 */
CREATE FUNCTION enforce_grant_immutability() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ BEGIN
 IF (to_jsonb(NEW)-'revoked_at') IS DISTINCT FROM (to_jsonb(OLD)-'revoked_at') OR
  (OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at) THEN
  RAISE EXCEPTION 'Grant identity and revocation are immutable' USING ERRCODE='23514',CONSTRAINT='ck_grant_immutable';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_grant_immutable BEFORE UPDATE ON membership_grants FOR EACH ROW EXECUTE FUNCTION enforce_grant_immutability();

/* Kiểm current grant ở cuối batch membership/grant; suspend không tự tạo grant mới.
 * Input: OLD/NEW membership hoặc grant. Output:NULL; Errors:23514 nếu pointer/status sai.
 */
CREATE FUNCTION validate_current_membership_grant() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE selected_workspace uuid; selected_user uuid; BEGIN
 selected_workspace:=CASE WHEN TG_OP='DELETE' THEN OLD.workspace_id ELSE NEW.workspace_id END;
 selected_user:=CASE WHEN TG_OP='DELETE' THEN OLD.user_id ELSE NEW.user_id END;
 IF EXISTS(SELECT 1 FROM public.memberships membership JOIN public.membership_grants grant_row
  ON (grant_row.workspace_id,grant_row.user_id,grant_row.grant_generation)=(membership.workspace_id,membership.user_id,membership.current_grant_generation)
  WHERE membership.workspace_id=selected_workspace AND membership.user_id=selected_user AND
   ((membership.status='ACTIVE' AND grant_row.revoked_at IS NOT NULL) OR (membership.status='REMOVED' AND grant_row.revoked_at IS NULL))) THEN
  RAISE EXCEPTION 'Current membership grant is inconsistent' USING ERRCODE='23514',CONSTRAINT='ck_membership_current_grant';
 END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER ct_membership_grant AFTER INSERT OR UPDATE ON memberships DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION validate_current_membership_grant();
CREATE CONSTRAINT TRIGGER ct_grant_membership AFTER INSERT OR UPDATE OR DELETE ON membership_grants DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION validate_current_membership_grant();

/* Kiểm typed literal theo pinned definition, không chấp nhận NaN/Infinity hoặc range sai.
 * Input: definition là schema; candidate là JSON scalar/null; writable yêu cầu capability.
 * Output:void; Errors:23514 khi datatype/range/enum/capability không đúng.
 */
CREATE FUNCTION assert_stream_value(definition public.datastream_definitions, candidate jsonb, writable boolean) RETURNS void LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE numeric_candidate double precision; BEGIN
 IF definition.stream_key IS NULL THEN RAISE EXCEPTION 'Unknown pinned stream' USING ERRCODE='23514',CONSTRAINT='ck_stream_value'; END IF;
 IF writable AND (definition.direction='READ' OR definition.data_type='STRING' OR NOT EXISTS(
  SELECT 1 FROM public.datastream_capabilities capability WHERE (capability.workspace_id,capability.template_version_id,capability.stream_key)=(definition.workspace_id,definition.template_version_id,definition.stream_key) AND command_type='SET_VALUE')) THEN
  RAISE EXCEPTION 'Stream is not writable' USING ERRCODE='23514',CONSTRAINT='ck_stream_writable';
 END IF;
 IF candidate IS NULL OR candidate='null'::jsonb THEN
  IF writable THEN RAISE EXCEPTION 'Control value cannot be null' USING ERRCODE='23514',CONSTRAINT='ck_stream_value'; END IF;
  RETURN;
 END IF;
 IF (definition.data_type='NUMBER' AND jsonb_typeof(candidate)<>'number') OR
    (definition.data_type='BOOLEAN' AND jsonb_typeof(candidate)<>'boolean') OR
    (definition.data_type='STRING' AND jsonb_typeof(candidate)<>'string') THEN
  RAISE EXCEPTION 'Stream value has wrong type' USING ERRCODE='23514',CONSTRAINT='ck_stream_value';
 END IF;
 IF definition.data_type='NUMBER' THEN
  numeric_candidate:=(candidate#>>'{}')::double precision;
  IF NOT(numeric_candidate>'-Infinity'::float8 AND numeric_candidate<'Infinity'::float8) OR
   numeric_candidate<definition.min_value OR numeric_candidate>definition.max_value THEN
   RAISE EXCEPTION 'Stream numeric value is out of range' USING ERRCODE='23514',CONSTRAINT='ck_stream_value';
  END IF;
 ELSIF definition.data_type='STRING' AND definition.string_max_length IS NOT NULL AND length(candidate#>>'{}')>definition.string_max_length THEN
  RAISE EXCEPTION 'Stream string is too long' USING ERRCODE='23514',CONSTRAINT='ck_stream_value';
 ELSIF definition.data_type='ENUM' AND NOT EXISTS(SELECT 1 FROM public.datastream_enum_values enum_row
  WHERE (enum_row.workspace_id,enum_row.template_version_id,enum_row.stream_key)=(definition.workspace_id,definition.template_version_id,definition.stream_key) AND enum_value=candidate) THEN
  RAISE EXCEPTION 'Unknown enum value' USING ERRCODE='23514',CONSTRAINT='ck_stream_value';
 END IF;
END $$;

/* Parent metadata phải trùng receipt authority; dùng IS DISTINCT FROM để không lọt NULL.
 * Input: NEW envelope. Output:NEW; Errors:23514 khi sequence/time khác receipt.
 */
CREATE FUNCTION validate_telemetry_envelope() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE receipt public.telemetry_receipts; BEGIN
 SELECT * INTO receipt FROM public.telemetry_receipts WHERE
  (workspace_id,device_id,boot_id,message_id)=(NEW.workspace_id,NEW.device_id,NEW.boot_id,NEW.message_id);
 IF receipt.ingestion_sequence IS DISTINCT FROM NEW.ingestion_sequence OR receipt.first_received_at IS DISTINCT FROM NEW.received_at THEN
  RAISE EXCEPTION 'Envelope differs from receipt' USING ERRCODE='23514',CONSTRAINT='ck_envelope_receipt_metadata';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_envelope_validate BEFORE INSERT ON telemetry_envelopes FOR EACH ROW EXECUTE FUNCTION validate_telemetry_envelope();

/* Projection point copy timestamp/device theo Core33, type đối chiếu đúng pin của device.
 * Input: NEW point. Output:NEW; Errors:23514 nếu metadata/type/value lệch schema/envelope.
 */
CREATE FUNCTION validate_telemetry_point() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE envelope public.telemetry_envelopes; definition public.datastream_definitions; candidate jsonb; BEGIN
 SELECT * INTO envelope FROM public.telemetry_envelopes WHERE (workspace_id,envelope_id)=(NEW.workspace_id,NEW.envelope_id);
 IF NEW.device_id IS DISTINCT FROM envelope.device_id OR NEW.observed_at IS DISTINCT FROM envelope.observed_at OR NEW.event_at IS DISTINCT FROM envelope.effective_at OR NEW.point_index>=envelope.point_count THEN
  RAISE EXCEPTION 'Point differs from envelope' USING ERRCODE='23514',CONSTRAINT='ck_point_envelope_metadata';
 END IF;
 SELECT stream.* INTO definition FROM public.devices device JOIN public.datastream_definitions stream USING(workspace_id,template_version_id)
 WHERE device.workspace_id=NEW.workspace_id AND device.device_id=NEW.device_id AND stream.stream_key=NEW.stream_key;
 IF NEW.value_type IS DISTINCT FROM definition.data_type THEN RAISE EXCEPTION 'Point type differs from pin' USING ERRCODE='23514',CONSTRAINT='ck_stream_value'; END IF;
 candidate:=coalesce(to_jsonb(NEW.numeric_value),to_jsonb(NEW.boolean_value),to_jsonb(NEW.text_value),'null'::jsonb);
 PERFORM public.assert_stream_value(definition,candidate,false);
 RETURN NEW;
END $$;
CREATE TRIGGER tr_point_validate BEFORE INSERT ON telemetry_points FOR EACH ROW EXECUTE FUNCTION validate_telemetry_point();

/* Deferred cardinality protège whole-envelope commit sans empêcher purge raw complète.
 * Input: envelope/point OLD/NEW. Output:NULL; Errors:23514 si point_count incomplet.
 */
CREATE FUNCTION validate_telemetry_point_count() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE selected_workspace uuid; selected_envelope uuid; expected_count integer; actual_count bigint; BEGIN
 selected_workspace:=CASE WHEN TG_OP='DELETE' THEN OLD.workspace_id ELSE NEW.workspace_id END;
 selected_envelope:=CASE WHEN TG_OP='DELETE' THEN OLD.envelope_id ELSE NEW.envelope_id END;
 SELECT point_count INTO expected_count FROM public.telemetry_envelopes WHERE(workspace_id,envelope_id)=(selected_workspace,selected_envelope);
 IF FOUND THEN
  SELECT count(*) INTO actual_count FROM public.telemetry_points WHERE(workspace_id,envelope_id)=(selected_workspace,selected_envelope);
  IF expected_count<>actual_count THEN RAISE EXCEPTION 'Incomplete telemetry envelope' USING ERRCODE='23514',CONSTRAINT='ck_envelope_point_count'; END IF;
 END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER ct_envelope_points AFTER INSERT ON telemetry_envelopes DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION validate_telemetry_point_count();
CREATE CONSTRAINT TRIGGER ct_points_count AFTER INSERT OR DELETE ON telemetry_points DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION validate_telemetry_point_count();

/* Rule quota dùng parent MVCC fence để RR không count snapshot cũ; counter thay cùng TX.
 * Input: execution OLD/NEW. Output:hàng; Side effects: quota row delta và parent fence.
 */
CREATE FUNCTION enforce_execution_quota() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE selected_workspace uuid; active_delta integer; BEGIN
 IF TG_OP='UPDATE' AND ROW(NEW.workspace_id,NEW.rule_execution_id,NEW.rule_id,NEW.rule_version_id) IS DISTINCT FROM ROW(OLD.workspace_id,OLD.rule_execution_id,OLD.rule_id,OLD.rule_version_id) THEN
  RAISE EXCEPTION 'Execution identity is immutable' USING ERRCODE='23514';
 END IF;
 selected_workspace:=CASE WHEN TG_OP='DELETE' THEN OLD.workspace_id ELSE NEW.workspace_id END;
 active_delta:=0;
 IF TG_OP<>'DELETE' AND NEW.state IN ('RUNNING','WAITING') THEN active_delta:=active_delta+1; END IF;
 IF TG_OP<>'INSERT' AND OLD.state IN ('RUNNING','WAITING') THEN active_delta:=active_delta-1; END IF;
 IF active_delta<>0 THEN
  UPDATE public.workspaces SET authorization_version=authorization_version WHERE workspace_id=selected_workspace;
  INSERT INTO public.workspace_runtime_quotas(workspace_id) VALUES(selected_workspace) ON CONFLICT DO NOTHING;
  UPDATE public.workspace_runtime_quotas SET active_execution_count=active_execution_count+active_delta,revision=revision+1 WHERE workspace_id=selected_workspace;
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_execution_quota BEFORE INSERT OR UPDATE OR DELETE ON rule_executions FOR EACH ROW EXECUTE FUNCTION enforce_execution_quota();

/* Command terminal không rewind; late evidence thuộc bảng riêng, identity/target bất biến.
 * Input: OLD/NEW. Output:NEW; Errors:23514 khi transition trái contract.
 */
CREATE FUNCTION enforce_command_transition() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$ DECLARE definition public.datastream_definitions; candidate jsonb; BEGIN
 IF TG_OP='UPDATE' THEN
  IF (to_jsonb(NEW)-ARRAY['state','outcome','dispatch_intent_at','terminal_at','revision']) IS DISTINCT FROM
     (to_jsonb(OLD)-ARRAY['state','outcome','dispatch_intent_at','terminal_at','revision']) THEN
   RAISE EXCEPTION 'Command admission is immutable' USING ERRCODE='23514',CONSTRAINT='ck_command_admission_immutable';
  END IF;
  IF OLD.state IN ('SUCCEEDED','FAILED','TIMED_OUT','EXPIRED_BEFORE_DISPATCH','CANCELLED') AND NEW IS DISTINCT FROM OLD THEN
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
CREATE TRIGGER tr_command_transition BEFORE INSERT OR UPDATE ON commands FOR EACH ROW EXECUTE FUNCTION enforce_command_transition();

/* Append-only payload/identity và chặn TRUNCATE cho mọi bảng public theo manifest cố định.
 * Các identifier lấy từ literal nội bộ, format%I không ghép input ứng dụng vào DDL.
 */
DO $$ DECLARE relation_name text; BEGIN
 FOREACH relation_name IN ARRAY ARRAY['template_versions','datastream_definitions','datastream_enum_values','datastream_capabilities',
  'rule_versions','rule_version_actions','rule_version_references','firmware_packages','firmware_package_templates',
  'telemetry_receipts','telemetry_envelopes','telemetry_points','command_result_receipts','command_evidence',
  'rule_execution_snapshots','execution_actuator_snapshots','event_occurrences','outbox_events','audit_events','ota_status_receipts'] LOOP
  EXECUTE format('CREATE TRIGGER tr_immutable_update BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.reject_immutable_update()',relation_name);
 END LOOP;
 FOREACH relation_name IN ARRAY ARRAY['datastream_definitions','datastream_enum_values','datastream_capabilities'] LOOP
  EXECUTE format('CREATE TRIGGER tr_published_child BEFORE INSERT ON public.%I FOR EACH ROW EXECUTE FUNCTION public.enforce_published_child_insert(''template_versions'',''template_version_id'')',relation_name);
 END LOOP;
 FOREACH relation_name IN ARRAY ARRAY['rule_version_actions','rule_version_references'] LOOP
  EXECUTE format('CREATE TRIGGER tr_published_child BEFORE INSERT ON public.%I FOR EACH ROW EXECUTE FUNCTION public.enforce_published_child_insert(''rule_versions'',''rule_version_id'')',relation_name);
 END LOOP;
 CREATE TRIGGER tr_published_child BEFORE INSERT ON public.firmware_package_templates FOR EACH ROW EXECUTE FUNCTION public.enforce_published_child_insert('firmware_packages','firmware_package_id');
 FOR relation_name IN SELECT tablename FROM pg_tables WHERE schemaname='public' LOOP
  EXECUTE format('CREATE TRIGGER tr_protected_truncate BEFORE TRUNCATE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION public.reject_protected_truncate()',relation_name);
 END LOOP;
END $$;
/* Giới hạn mặc định: không mở writer hay đọc credential trước khi backend policy được nghiệm thu. */
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC,iot_runtime;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC,iot_runtime;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC,iot_runtime;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM PUBLIC;
