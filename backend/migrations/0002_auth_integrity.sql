/* Đóng bốn lỗi integrity đã chứng minh trên PostgreSQL17, không sửa checksum0001.
 * Phụ thuộc:0001_auth.sql; runner phải bọc toàn file trong một transaction.
 * LOCK/ALTER cần cửa sổ bảo trì với writer dừng; DB lab hiện trống, không backfill.
 * Dữ liệu vi phạm khiến migration abort; không tự sửa actor, cấp Admin hoặc đổi session.
 * Với DB lớn cần kế hoạch index concurrent/validation riêng trước áp, không suy từ lab.
 */
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';

-- Giữ dữ liệu ổn định giữa preflight và DDL; không cho writer tạo vi phạm trong khoảng kiểm.
LOCK TABLE public.users, public.workspaces, public.memberships, public.sessions,
    public.audit_events, public.login_attempts IN ACCESS EXCLUSIVE MODE;

/* Chỉ kiểm sự tồn tại của vi phạm, không đọc/in verifier hoặc key material.
 * Errors:23514 yêu cầu đối soát dữ liệu trước, không tự bịa giá trị thay thế.
 */
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.login_attempts
        WHERE (failure_count=0 AND window_started_at IS NOT NULL)
           OR (failure_count>0 AND window_started_at IS NULL)
    ) THEN
        RAISE EXCEPTION 'Existing login bucket violates count/window coherence' USING ERRCODE='23514';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.audit_events AS audit
        JOIN public.sessions AS session ON session.id=audit.session_id
        WHERE audit.actor_id IS DISTINCT FROM session.user_id
    ) THEN
        RAISE EXCEPTION 'Existing audit actor does not own referenced session' USING ERRCODE='23514';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.workspaces AS workspace
        WHERE NOT EXISTS (
            SELECT 1 FROM public.memberships AS membership
            JOIN public.users AS account ON account.id=membership.user_id
            WHERE membership.workspace_id=workspace.id
              AND membership.role='ADMIN' AND membership.status='ACTIVE'
              AND account.status='ACTIVE' AND NOT account.must_change_password
        )
    ) THEN
        RAISE EXCEPTION 'Existing workspace has no capable active administrator' USING ERRCODE='23514';
    END IF;
END $$;

/* Cửa sổ bắt đầu tại failure đầu tiên theo FEAT001; trạng thái rỗng có count0/windowNULL.
 * Không CHECK theo clock hiện tại: expiry do admission protocol kiểm trong transaction.
 */
ALTER TABLE public.login_attempts ADD CONSTRAINT ck_login_attempts_window_coherence
    CHECK ((failure_count=0 AND window_started_at IS NULL)
        OR (failure_count>0 AND window_started_at IS NOT NULL));

/* id đã global unique; user_id lặp trong UK để composite FK cưỡng chế binding actor/session.
 * Đây là supporting superkey, không tuyên bố là candidate key tối thiểu mới.
 */
ALTER TABLE public.sessions ADD CONSTRAINT uq_sessions_user_identity UNIQUE(user_id,id);
ALTER TABLE public.audit_events ADD CONSTRAINT ck_audit_events_session_actor
    CHECK (session_id IS NULL OR actor_id IS NOT NULL);
ALTER TABLE public.audit_events ADD CONSTRAINT fk_audit_events_actor_session
    FOREIGN KEY(actor_id,session_id) REFERENCES public.sessions(user_id,id)
    MATCH SIMPLE ON UPDATE NO ACTION ON DELETE NO ACTION;

/* Giữ identity/admission của phiên bất biến để limited không nâng thành full tại chỗ.
 * Input: OLD/NEW là phiên trước/sau UPDATE; chỉ revoked_at có thể chuyển NULL→thời điểm thu hồi.
 * Output: NEW hợp lệ; Errors:23514 khi đổi identity/admission hoặc đảo ngược revocation.
 * Side effects: không ghi bảng khác; đổi password phải cấp phiên mới theo FEAT001/004.
 */
CREATE FUNCTION public.enforce_session_immutability()
RETURNS trigger LANGUAGE plpgsql VOLATILE
SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
    IF ROW(NEW.id,NEW.user_id,NEW.token_digest,NEW.auth_context_id,NEW.client_type,
           NEW.limited,NEW.created_at,NEW.expires_at)
       IS DISTINCT FROM
       ROW(OLD.id,OLD.user_id,OLD.token_digest,OLD.auth_context_id,OLD.client_type,
           OLD.limited,OLD.created_at,OLD.expires_at) THEN
        RAISE EXCEPTION 'Session identity and admission mode are immutable'
            USING ERRCODE='23514', CONSTRAINT='ck_sessions_identity_immutable';
    END IF;
    IF OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at THEN
        RAISE EXCEPTION 'Session revocation cannot be rewritten'
            USING ERRCODE='23514', CONSTRAINT='ck_sessions_revocation_monotonic';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER tr_sessions_immutability BEFORE UPDATE ON public.sessions
    FOR EACH ROW EXECUTE FUNCTION public.enforce_session_immutability();

/* Kiểm trạng thái cuối của workspace, không dùng snapshot actor được caller cung cấp.
 * Input
 * Param: target_workspace_id — workspace phải còn Admin đủ khả năng quản trị theo FEAT003.
 * Output: void nếu hợp lệ hoặc parent đã được xóa hợp lệ trong transaction.
 * Errors:23514 với constraint ổn định để service map LAST_ADMIN_REQUIRED.
 */
CREATE FUNCTION public.assert_workspace_capable_admin(target_workspace_id uuid)
RETURNS void LANGUAGE plpgsql VOLATILE
SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
    IF EXISTS(SELECT 1 FROM public.workspaces WHERE id=target_workspace_id)
       AND NOT EXISTS (
           SELECT 1 FROM public.memberships AS membership
           JOIN public.users AS account ON account.id=membership.user_id
           WHERE membership.workspace_id=target_workspace_id
             AND membership.role='ADMIN' AND membership.status='ACTIVE'
             AND account.status='ACTIVE' AND NOT account.must_change_password
       ) THEN
        RAISE EXCEPTION 'Workspace requires a capable active administrator'
            USING ERRCODE='23514', CONSTRAINT='ck_workspaces_capable_admin';
    END IF;
END $$;

/* Serialize membership theo cả User và Workspace để không bỏ sót grant ở snapshot RR cũ.
 * Input: TG_OP cùng OLD/NEW cung cấp hai phía của mutation, kể cả chuyển identity bằng SQL.
 * Output: hàng phù hợp cho INSERT/UPDATE/DELETE; Side effects: tạo MVCC version trên parent.
 * No-op UPDATE có chủ đích: row lock đơn thuần không làm RR phát hiện membership mới.
 * Row trigger không hứa tránh deadlock cho batch owner DML; writer phải pre-lock User→W→M,
 * và retry toàn transaction chưa side effect khi gặp40P01/40001.
 */
CREATE FUNCTION public.fence_membership_administrators()
RETURNS trigger LANGUAGE plpgsql VOLATILE
SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE
    affected_user_ids uuid[];
    affected_workspace_ids uuid[];
    target_user_id uuid;
    target_workspace_id uuid;
BEGIN
    IF TG_OP='INSERT' THEN
        affected_user_ids:=ARRAY[NEW.user_id];
        affected_workspace_ids:=ARRAY[NEW.workspace_id];
    ELSIF TG_OP='DELETE' THEN
        affected_user_ids:=ARRAY[OLD.user_id];
        affected_workspace_ids:=ARRAY[OLD.workspace_id];
    ELSE
        affected_user_ids:=ARRAY[OLD.user_id,NEW.user_id];
        affected_workspace_ids:=ARRAY[OLD.workspace_id,NEW.workspace_id];
    END IF;
    FOR target_user_id IN
        SELECT DISTINCT member_id FROM pg_catalog.unnest(affected_user_ids) AS scope(member_id)
        ORDER BY member_id
    LOOP
        -- Write fence trên User đóng phantom grant khi transaction RR chưa thấy membership mới.
        UPDATE public.users AS account SET status=account.status WHERE account.id=target_user_id;
    END LOOP;
    FOR target_workspace_id IN
        SELECT DISTINCT workspace_id FROM pg_catalog.unnest(affected_workspace_ids) AS scope(workspace_id)
        ORDER BY workspace_id
    LOOP
        -- Write fence trên Workspace serialize count/check cuối TX mà không đổi revision wire.
        UPDATE public.workspaces AS workspace SET authz_version=workspace.authz_version
        WHERE workspace.id=target_workspace_id;
    END LOOP;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER tr_memberships_admin_fence BEFORE INSERT OR UPDATE OR DELETE ON public.memberships
    FOR EACH ROW EXECUTE FUNCTION public.fence_membership_administrators();

/* Đổi trạng thái account cũng có thể loại người quản trị cuối ở nhiều workspace.
 * Input: OLD/NEW của User; chỉ thực sự fence khi status/must_change_password đổi giá trị.
 * Output: NEW; Side effects: write fence các workspace đang có membership ADMIN/ACTIVE.
 * Bỏ qua no-op từ membership fence để không đệ quy hoặc phát sinh authz thay đổi giả.
 */
CREATE FUNCTION public.fence_user_administrator_workspaces()
RETURNS trigger LANGUAGE plpgsql VOLATILE
SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE target_workspace_id uuid;
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status
       OR OLD.must_change_password IS DISTINCT FROM NEW.must_change_password THEN
        FOR target_workspace_id IN
            SELECT workspace_id FROM public.memberships
            WHERE user_id=OLD.id AND role='ADMIN' AND status='ACTIVE'
            ORDER BY workspace_id
        LOOP
            UPDATE public.workspaces AS workspace SET authz_version=workspace.authz_version
            WHERE workspace.id=target_workspace_id;
        END LOOP;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER tr_users_admin_fence BEFORE UPDATE OF status,must_change_password ON public.users
    FOR EACH ROW EXECUTE FUNCTION public.fence_user_administrator_workspaces();

/* Kiểm cả workspace cũ và mới ở cuối transaction; không mất nghĩa vụ khi move/delete membership.
 * Input: OLD/NEW theo TG_OP. Output: NULL vì AFTER trigger không sửa hàng.
 * Errors:23514 nếu một parent còn tồn tại mất capable Admin sau toàn bộ batch.
 */
CREATE FUNCTION public.validate_membership_administrators()
RETURNS trigger LANGUAGE plpgsql VOLATILE
SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
    IF TG_OP<>'INSERT' THEN
        PERFORM public.assert_workspace_capable_admin(OLD.workspace_id);
    END IF;
    IF TG_OP<>'DELETE' THEN
        PERFORM public.assert_workspace_capable_admin(NEW.workspace_id);
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER ct_memberships_capable_admin
    AFTER INSERT OR UPDATE OR DELETE ON public.memberships
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION public.validate_membership_administrators();

/* Workspace mới chỉ được commit cùng Admin đầu tiên; no-op parent fence vẫn phải kiểm cuối TX.
 * Input: NEW là parent sau INSERT/UPDATE. Output: NULL; Errors:23514 khi parent thiếu Admin.
 */
CREATE FUNCTION public.validate_workspace_administrators()
RETURNS trigger LANGUAGE plpgsql VOLATILE
SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
    PERFORM public.assert_workspace_capable_admin(NEW.id);
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER ct_workspaces_capable_admin
    AFTER INSERT OR UPDATE ON public.workspaces
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION public.validate_workspace_administrators();

/* Kiểm lại các membership còn hiệu lực sau account-state mutation; membership events giữ phía cũ.
 * Input: NEW.id của User bị đổi status/must_change_password. Output: NULL; Errors:23514.
 */
CREATE FUNCTION public.validate_user_administrator_workspaces()
RETURNS trigger LANGUAGE plpgsql VOLATILE
SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE target_workspace_id uuid;
BEGIN
    FOR target_workspace_id IN
        SELECT workspace_id FROM public.memberships
        WHERE user_id=NEW.id AND role='ADMIN' AND status='ACTIVE'
        ORDER BY workspace_id
    LOOP
        PERFORM public.assert_workspace_capable_admin(target_workspace_id);
    END LOOP;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER ct_users_capable_admin AFTER UPDATE ON public.users
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    WHEN (OLD.status IS DISTINCT FROM NEW.status OR OLD.must_change_password IS DISTINCT FROM NEW.must_change_password)
    EXECUTE FUNCTION public.validate_user_administrator_workspaces();

/* TRUNCATE không phát row trigger nên phải chặn riêng để không né last-Admin guard.
 * Output: không trả bình thường; Errors:23514. Cleanup có kiểm soát dùng DELETE/transaction.
 */
CREATE FUNCTION public.reject_membership_truncate()
RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
    RAISE EXCEPTION 'TRUNCATE memberships bypasses administrator integrity'
        USING ERRCODE='23514', CONSTRAINT='ck_workspaces_capable_admin';
END $$;
CREATE TRIGGER tr_memberships_reject_truncate BEFORE TRUNCATE ON public.memberships
    FOR EACH STATEMENT EXECUTE FUNCTION public.reject_membership_truncate();

/* Không tạo privileged entry point cho PUBLIC; tất cả helper là SECURITY INVOKER.
 * Migrator sở hữu routine nên có EXECUTE; runtime PoC không có mutation/EXECUTE mới.
 * Writer ứng dụng tương lai cần grant helper cụ thể kèm quyền parent theo protocol đã review.
 */
REVOKE ALL ON FUNCTION public.enforce_session_immutability() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.assert_workspace_capable_admin(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fence_membership_administrators() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fence_user_administrator_workspaces() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.validate_membership_administrators() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.validate_workspace_administrators() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.validate_user_administrator_workspaces() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reject_membership_truncate() FROM PUBLIC;
