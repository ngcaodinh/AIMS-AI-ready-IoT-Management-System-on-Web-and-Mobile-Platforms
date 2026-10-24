/* Sửa seal phiên bản, SAVEPOINT và TTL API key bằng forward migration.
 * ADD COLUMN nullable không backfill payload; ALTER TABLE cần ACCESS EXCLUSIVE ngắn.
 * Runner đặt lock/statement timeout và rollback cả version nếu preflight TTL không đạt.
 * Không gán authority mới cho parent đã tồn tại: marker NULL nghĩa đã chốt, cấm thêm child.
 */
ALTER TABLE public.template_versions
    -- XID 64 bit của transaction tạo parent; NULL cho hàng lịch sử đã chốt trước migration.
    ADD COLUMN publication_transaction_id xid8,
    -- Identity cluster tạo parent, ngăn marker từ logical restore khớp XID của cluster khác.
    ADD COLUMN publication_cluster_id bigint;
ALTER TABLE public.rule_versions
    -- XID transaction trên cùng, dùng chung cả khi parent được tạo trong SAVEPOINT.
    ADD COLUMN publication_transaction_id xid8,
    -- Cluster authority đi cùng XID; không phải workspace hoặc ID do client cung cấp.
    ADD COLUMN publication_cluster_id bigint;
ALTER TABLE public.firmware_packages
    -- Marker transaction tạo canonical package, không đổi khi UPDATE no-op.
    ADD COLUMN publication_transaction_id xid8,
    -- Cluster ban đầu của marker; restore sang cluster khác phải giữ package đã chốt.
    ADD COLUMN publication_cluster_id bigint;
ALTER TABLE public.api_keys
    -- Transaction phát hành key và tập grant, độc lập với revision/last_used_at thay đổi sau đó.
    ADD COLUMN publication_transaction_id xid8,
    -- Cluster phát hành marker, ngăn reuse XID sau logical restore tạo authority giả.
    ADD COLUMN publication_cluster_id bigint;

/* Gán provenance một lần khi INSERT và cấm UPDATE đổi marker để không mở lại parent cũ.
 * Input: NEW/OLD của bốn parent đã định danh bởi trigger.
 * Output: NEW có marker của transaction hiện hành; SAVEPOINT không đổi top-level XID.
 * Errors: 23514 nếu writer cố thay marker sau khi parent đã tồn tại.
 * Side effects: chỉ gán hai thuộc tính vận hành; không network hoặc tạo quyền runtime.
 */
CREATE FUNCTION public.enforce_publication_origin() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
    IF TG_OP='INSERT' THEN
        -- BEFORE INSERT cũng chạy với ON CONFLICT; chỉ hàng INSERT thật giữ marker mới.
        NEW.publication_transaction_id:=pg_current_xact_id();
        SELECT system_identifier INTO NEW.publication_cluster_id FROM pg_control_system();
    ELSIF ROW(NEW.publication_transaction_id,NEW.publication_cluster_id)
        IS DISTINCT FROM ROW(OLD.publication_transaction_id,OLD.publication_cluster_id) THEN
        RAISE EXCEPTION 'Publication origin is immutable'
            USING ERRCODE='23514',CONSTRAINT='ck_publication_origin_immutable';
    END IF;
    RETURN NEW;
END $$;

/* Child chỉ thêm trong transaction thật đã INSERT parent, không dựa xmin của row version.
 * Input: NEW child; TG_ARGV gồm tên parent và khóa từ các trigger do migration tạo.
 * Output: NEW khi marker của đúng parent/workspace khớp cả XID và cluster hiện hành.
 * Errors: 23514 nếu parent cũ/khác transaction; 22023 nếu trigger args ngoài allowlist.
 */
CREATE OR REPLACE FUNCTION public.enforce_published_child_insert() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE created_here boolean;
BEGIN
    -- Identifier chỉ từ allowlist nội bộ; giá trị scope/identity được bind qua USING.
    IF ROW(TG_ARGV[0],TG_ARGV[1]) NOT IN (
        ROW('template_versions','template_version_id'),ROW('rule_versions','rule_version_id'),
        ROW('firmware_packages','firmware_package_id'),ROW('api_keys','api_key_id')) THEN
        RAISE EXCEPTION 'Invalid publication parent' USING ERRCODE='22023';
    END IF;
    EXECUTE format('SELECT publication_transaction_id=pg_current_xact_id() AND publication_cluster_id=(SELECT system_identifier FROM pg_control_system()) FROM public.%I WHERE workspace_id=$1 AND %I=$2',TG_ARGV[0],TG_ARGV[1])
        INTO created_here USING NEW.workspace_id,(to_jsonb(NEW)->>TG_ARGV[1])::uuid;
    IF created_here IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'Published content cannot be extended'
            USING ERRCODE='23514',CONSTRAINT='ck_published_child_sealed';
    END IF;
    RETURN NEW;
END $$;

/* Các parent dùng cùng protocol; không thêm default để không backfill XID vào hàng cũ. */
CREATE TRIGGER tr_publication_origin BEFORE INSERT OR UPDATE ON public.template_versions
    FOR EACH ROW EXECUTE FUNCTION public.enforce_publication_origin();
CREATE TRIGGER tr_publication_origin BEFORE INSERT OR UPDATE ON public.rule_versions
    FOR EACH ROW EXECUTE FUNCTION public.enforce_publication_origin();
CREATE TRIGGER tr_publication_origin BEFORE INSERT OR UPDATE ON public.firmware_packages
    FOR EACH ROW EXECUTE FUNCTION public.enforce_publication_origin();
CREATE TRIGGER tr_publication_origin BEFORE INSERT OR UPDATE ON public.api_keys
    FOR EACH ROW EXECUTE FUNCTION public.enforce_publication_origin();
REVOKE ALL ON FUNCTION public.enforce_publication_origin() FROM PUBLIC,iot_runtime;
REVOKE ALL ON FUNCTION public.enforce_published_child_insert() FROM PUBLIC,iot_runtime;

/* Contract FEAT057: ngày = 86400 giây; interval seconds không trôi theo calendar/DST.
 * Validate constraint mới trước bỏ CHECK cũ; nếu có dữ liệu sai thì rollback, không tự sửa expiry.
 */
ALTER TABLE public.api_keys ADD CONSTRAINT ck_api_keys_fixed_duration_ttl
    CHECK(expires_at>=issued_at+interval '86400 seconds'
      AND expires_at<=issued_at+interval '7776000 seconds') NOT VALID;
ALTER TABLE public.api_keys VALIDATE CONSTRAINT ck_api_keys_fixed_duration_ttl;
ALTER TABLE public.api_keys DROP CONSTRAINT api_keys_check;

/* Native descriptions cho thuộc tính vận hành mới; không có credential hoặc dữ liệu người dùng. */
COMMENT ON COLUMN public.template_versions.publication_transaction_id IS 'XID 64 bit của transaction tạo parent; gán bởi trigger, bất biến khi UPDATE, hỗ trợ SAVEPOINT. NULL ở parent lịch sử nghĩa đã chốt, không được thêm child.';
COMMENT ON COLUMN public.template_versions.publication_cluster_id IS 'Identity cluster PostgreSQL tạo publication marker; kết hợp XID ngăn authority giả khi logical restore sang cluster khác. NULL ở parent lịch sử đã chốt.';
COMMENT ON COLUMN public.rule_versions.publication_transaction_id IS 'XID 64 bit của transaction tạo parent; gán bởi trigger, bất biến khi UPDATE, hỗ trợ SAVEPOINT. NULL ở parent lịch sử nghĩa đã chốt, không được thêm child.';
COMMENT ON COLUMN public.rule_versions.publication_cluster_id IS 'Identity cluster PostgreSQL tạo publication marker; kết hợp XID ngăn authority giả khi logical restore sang cluster khác. NULL ở parent lịch sử đã chốt.';
COMMENT ON COLUMN public.firmware_packages.publication_transaction_id IS 'XID 64 bit của transaction tạo parent; gán bởi trigger, bất biến khi UPDATE, hỗ trợ SAVEPOINT. NULL ở parent lịch sử nghĩa đã chốt, không được thêm child.';
COMMENT ON COLUMN public.firmware_packages.publication_cluster_id IS 'Identity cluster PostgreSQL tạo publication marker; kết hợp XID ngăn authority giả khi logical restore sang cluster khác. NULL ở parent lịch sử đã chốt.';
COMMENT ON COLUMN public.api_keys.publication_transaction_id IS 'XID 64 bit của transaction tạo parent; gán bởi trigger, bất biến khi UPDATE, hỗ trợ SAVEPOINT. NULL ở parent lịch sử nghĩa đã chốt, không được thêm child.';
COMMENT ON COLUMN public.api_keys.publication_cluster_id IS 'Identity cluster PostgreSQL tạo publication marker; kết hợp XID ngăn authority giả khi logical restore sang cluster khác. NULL ở parent lịch sử đã chốt.';
