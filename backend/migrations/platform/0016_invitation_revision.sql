/* Hoàn thiện CAS metadata/revoke và terminal truth của invitation theo WF066.
 * ALTER TABLE giữ ACCESS EXCLUSIVE trong transaction migration ngắn; baseline chỉ áp khi invitation trống.
 * Không sửa SQL/checksum đã áp; không suy revision lịch sử cho dữ liệu legacy hoặc reset capability.
 * Native PK/issuer/token identity và one-way guards hiện có tiếp tục chạy trước constraint validation.
 */
LOCK TABLE public.workspace_invitations IN ACCESS EXCLUSIVE MODE;
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM public.workspace_invitations) THEN
  RAISE EXCEPTION 'Invitation baseline requires reviewed adoption for existing rows'
   USING ERRCODE='23514',CONSTRAINT='ck_invitation_revision_adoption_required';
 END IF;
END $$;

-- Revision metadata dùng If-Match; bigint dương, NOT NULL, DEFAULT1 cho capability mới.
-- UPDATE do native trigger quản lý, caller không tự tăng hoặc ghi đè version.
ALTER TABLE public.workspace_invitations ADD COLUMN revision bigint NOT NULL DEFAULT 1
 CONSTRAINT ck_invitation_revision_positive CHECK(revision>0);

/* Mỗi capability chỉ có một terminal; used phải nằm trong cửa sổ24h, expired không xuất hiện trước deadline.
 * Các nhánh IS NULL xử lý rõ optional timestamp; issued/expires đã NOT NULL nên CHECK không lọt UNKNOWN.
 */
ALTER TABLE public.workspace_invitations ADD CONSTRAINT ck_invitation_terminal_shape CHECK(
 num_nonnulls(used_at,revoked_at,expired_at)<=1 AND
 (used_at IS NULL OR (used_at>=issued_at AND used_at<expires_at)) AND
 (revoked_at IS NULL OR revoked_at>=issued_at) AND
 (expired_at IS NULL OR expired_at>=expires_at)
);

/* Tăng revision đúng một khi nội dung thay đổi để consume/expire/revoke mọi writer đều có CAS version.
 * Input: OLD/NEW invitation dưới row lock; caller phải giữ revision hiện hành trong NEW.
 * Output: NEW với version engine quản lý; no-op giữ version; Errors23514 nếu override/overflow.
 * Không SELECT account, không thay quyền và không ghi secret vào exception/log.
 */
CREATE FUNCTION public.advance_invitation_revision() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog AS $$ BEGIN
 IF NEW.revision IS DISTINCT FROM OLD.revision THEN
  RAISE EXCEPTION 'Invitation revision is engine managed'
   USING ERRCODE='23514',CONSTRAINT='ck_invitation_revision_override';
 END IF;
 IF (to_jsonb(NEW)-'revision') IS DISTINCT FROM (to_jsonb(OLD)-'revision') THEN
  IF OLD.revision=9223372036854775807 THEN
   RAISE EXCEPTION 'Invitation revision exhausted'
    USING ERRCODE='23514',CONSTRAINT='ck_invitation_revision_exhausted';
  END IF;
  NEW.revision:=OLD.revision+1;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER tr_invitation_revision BEFORE UPDATE ON public.workspace_invitations
 FOR EACH ROW EXECUTE FUNCTION public.advance_invitation_revision();
REVOKE ALL ON FUNCTION public.advance_invitation_revision() FROM PUBLIC;

-- Tenant đứng đầu, rồi issued_at/id ổn định cho metadata keyset; trạng thái được tính với server clock tại query.
CREATE INDEX ix_workspace_invitations_created ON public.workspace_invitations(workspace_id,issued_at DESC,invitation_id DESC);
COMMENT ON COLUMN public.workspace_invitations.revision IS 'Revision dương của metadata invitation cho If-Match; mặc định1, engine tự tăng khi row thay đổi, no-op giữ nguyên và caller không được tự ghi đè.';
COMMENT ON FUNCTION public.advance_invitation_revision() IS 'Bảo vệ revision invitation do engine quản lý: thay đổi row tăng đúng1, no-op giữ version; từ chối override/overflow để CAS không bị quay vòng.';
