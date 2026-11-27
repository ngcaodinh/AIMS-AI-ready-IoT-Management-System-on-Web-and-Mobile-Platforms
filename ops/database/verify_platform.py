"""Áp và kiểm PostgreSQL thật trên một DB cố định; không tạo DB test/restore rải rác."""

import argparse
import hashlib
import json
import re
from datetime import datetime, timezone
from pathlib import Path

import verify_database as lab
import platform_concurrency
import schema_documentation as documentation
import sql_source_documentation as source_documentation
import publication_checks


DATABASE = "iot_platform_lab"
ROOT = Path(__file__).resolve().parents[2]
MIGRATIONS = ROOT / "backend/migrations/platform"
TEST_ROOT = ROOT / "backend/tests/database/platform"
SOURCE_NAMES = (
    "0001_identity.sql", "0002_devices.sql", "0003_automation.sql", "0004_events.sql",
    "0005_mobile.sql", "0006_integrations.sql", "0007_guards.sql",
    "0008_delivery_integrity.sql", "0009_operations.sql", "0010_operation_boundaries.sql",
    "0011_final_integrity.sql", "0012_schema_comments.sql", "0013_publication_integrity.sql",
    "0014_audit_ingestion.sql",
    "0015_audit_retention.sql",
    "0016_invitation_revision.sql",
    "0017_outbox_lease_clock.sql",
    "0018_channel_kind.sql",
    "0019_device_registration.sql",
    "0020_auth_ios_client.sql",
    "0021_password_change_attempt_buckets.sql",
    "0023_provisioning_poll_metadata.sql",
    "0024_template_stream_defaults.sql",
)
# Các view/check dùng cùng search_path để regclass/regprocedure không drift do pg_dump reset.
FINGERPRINT = "SET search_path=public,pg_catalog;\n" + (
    ROOT / "backend/migrations/runner/fingerprint.sql"
).read_text(encoding="utf-8") + """
SELECT md5(string_agg(viewname||':'||definition,E'\n' ORDER BY viewname))
FROM pg_views WHERE schemaname='public';
""" + documentation.COMMENTS_FINGERPRINT_SQL
# Column ACL và view ACL phải được giữ qua restore, không chỉ table ACL ở fingerprint lịch sử.
FINGERPRINT += """
WITH entries(entry) AS (
 SELECT relation.oid::regclass::text||':'||attribute.attname||':'||acl.grantor::regrole::text||':'||
  CASE WHEN acl.grantee=0 THEN 'PUBLIC' ELSE acl.grantee::regrole::text END||':'||acl.privilege_type||':'||acl.is_grantable
 FROM pg_class relation JOIN pg_attribute attribute ON attribute.attrelid=relation.oid
 CROSS JOIN LATERAL aclexplode(attribute.attacl) acl
 WHERE relation.relnamespace IN ('public'::regnamespace,'migration_control'::regnamespace) AND attribute.attnum>0 AND NOT attribute.attisdropped
 UNION ALL
 SELECT relation.oid::regclass::text||':view:'||acl.grantor::regrole::text||':'||
  CASE WHEN acl.grantee=0 THEN 'PUBLIC' ELSE acl.grantee::regrole::text END||':'||acl.privilege_type||':'||acl.is_grantable
 FROM pg_class relation CROSS JOIN LATERAL aclexplode(coalesce(relation.relacl,acldefault('r',relation.relowner))) acl
 WHERE relation.relnamespace='public'::regnamespace AND relation.relkind='v'
)
SELECT md5(coalesce(string_agg(entry,E'\\n' ORDER BY entry),'')) FROM entries;
"""
EMPTY_GUARD = """
/* Chỉ kiểm có hàng; không đọc/in verifier, token hoặc dữ liệu người dùng. */
DO $$ DECLARE relation record; populated boolean; BEGIN
 FOR relation IN SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename LOOP
  EXECUTE format('LOCK TABLE public.%I IN ACCESS EXCLUSIVE MODE',relation.tablename);
  EXECUTE format('SELECT EXISTS(SELECT 1 FROM public.%I)',relation.tablename) INTO populated;
  IF populated THEN RAISE EXCEPTION 'Platform database has application rows; refusing verification'; END IF;
 END LOOP;
END $$;
"""


# Migration list cố định; file thiếu là lỗi, không âm thầm bỏ slice chưa có.
def sources():
    """Output: toàn bộ baseline có thứ tự. Errors: FileNotFoundError khi thiếu file canonical."""
    paths = tuple(MIGRATIONS / name for name in SOURCE_NAMES)
    for path in paths:
        if not path.is_file():
            raise FileNotFoundError(path)
    return tuple(source_documentation.executable_source(path) for path in paths)


# Boundary chỉ một DB; không nhận connection string hoặc namespace restore từ caller.
def sql(statement, database=DATABASE, check=True, role=lab.MIGRATOR):
    """Chạy SQL nguồn cố định qua psql stdin để kiểm engine thật.
    Input
    Param: statement — SQL nội bộ/fixture tổng hợp; không input người dùng.
    Param: database — chỉ chấp nhận DATABASE canonical.
    Param: check — yêu cầu raise khi psql lỗi.
    Param: role — role trong allowlist launcher.
    Output: CompletedProcess; Errors: ValueError nếu khác DB, RuntimeError nếu SQL lỗi.
    """
    if database != DATABASE:
        raise ValueError("Only the canonical platform database is permitted")
    return lab.sql(statement, database=database, check=check, role=role)


# Runner dùng checksum byte gốc và version tường minh, không sửa history đã commit.
def migration_identity(path):
    """Input
    Param: path — file canonical được sources chọn.
    Output: version và SHA256 để bind qua literal psql.
    """
    return "platform-" + path.stem.replace("_", "-"), hashlib.sha256(path.read_bytes()).hexdigest()


# Mỗi version atomic với ledger, khóa chung với auth runner nhưng target DB cố định.
def apply():
    """Output: trạng thái/hash từng migration. Side effects: áp forward DDL chưa có; drift fail."""
    results = {}
    for path in sources():
        version, checksum = migration_identity(path)
        script = lab.migration_script(path.read_text(encoding="utf-8"), checksum, version)
        result = lab.sql(script, database=DATABASE, variables=(("migration_version", version), ("migration_checksum", checksum)))
        results[path.name] = {"status": result.stdout.strip(), "sha256": checksum}
    return results


# Một file psql đầy đủ numbered migrations và ledger; rerun cùng checksum không tạo object lầnhai.
def bundle_sql():
    """Output: SQL tổng hợp có target guard, transaction/version/checksum; không credential hoặc seed."""
    sections = ["""/* Bản tổng hợp database toàn hệ thống; sinh từ numbered migrations, không sửa tay.
 * Chỉ chạy trên iot_platform_lab bằng iot_migrator sau bootstrap role/database.
 * Không chạy nối tiếp schema.sql; file này có ledger và chạy lại an toàn theo checksum.
 */
\\set ON_ERROR_STOP on
SELECT current_database()='iot_platform_lab' AS target_matches \\gset
\\if :target_matches
\\else
DO $$ BEGIN RAISE EXCEPTION 'Wrong canonical database target'; END $$;
\\endif
"""]
    for path in sources():
        version, checksum = migration_identity(path)
        sections.append(f"\\set migration_version {version}\n\\set migration_checksum {checksum}\n")
        sections.append(lab.migration_script(path.read_text(encoding="utf-8"), checksum, version))
    return "\n".join(sections)


# Fixture source tự bọc BEGIN; luôn ép deferred checks trước ROLLBACK để không che lỗi commit.
def verify_sql():
    """Output: mọi ca PASS trên engine thật. Side effects: chỉ fixture transaction luôn rollback."""
    prefix = (TEST_ROOT / "fixture.sql").read_text(encoding="utf-8") + (TEST_ROOT / "domain_fixture.sql").read_text(encoding="utf-8")
    results = []
    for path in sorted(TEST_ROOT.glob("[0-9]*.sql")):
        # Chỉ ACL harness được SET ROLE runtime để kiểm quyền thật; domain suites vẫn chạy migrator không superuser.
        role = lab.ADMIN if path.name == "0011_audit_ingestion.sql" else lab.MIGRATOR
        output = sql(prefix + path.read_text(encoding="utf-8") + "\nSET CONSTRAINTS ALL IMMEDIATE;\nROLLBACK;", role=role).stdout
        results.extend(line for line in output.splitlines() if line)
    lab.validate_sql_results(results)
    return results


def read_catalog_grains():
    """Đọc bản chiếu grain từ checkout và trả provenance cho manifest/evidence.

    Output: cặp mapping table→grain và thông tin đường dẫn, SHA-256 của bản chiếu
    theo LF cùng SHA-256 của catalog thiết kế nguồn.
    Errors: lỗi đọc/parse hoặc ValueError nếu metadata thiếu provenance hay grain.
    """
    relative_path = "ops/database/schema-catalog-grains.json"
    content = (ROOT / relative_path).read_bytes()
    metadata = json.loads(content)
    if not isinstance(metadata, dict) or set(metadata) != {"source", "grains"}:
        raise ValueError("Invalid catalog projection metadata")
    source = metadata["source"]
    if (
        not isinstance(source, dict)
        or set(source) != {"path", "sha256"}
        or source["path"] != "docs/plan/database/schema-catalog.md"
        or not isinstance(source["sha256"], str)
        or not re.fullmatch(r"[0-9a-f]{64}", source["sha256"])
    ):
        raise ValueError("Invalid catalog source provenance")
    grains = metadata["grains"]
    if not isinstance(grains, dict) or not grains or any(
        not re.fullmatch(r"[a-z_]+", table) or not isinstance(grain, str) or not grain.strip()
        for table, grain in grains.items()
    ):
        raise ValueError("Invalid catalog table or grain")

    # Chuẩn hóa EOL của bản chiếu để hash không phụ thuộc cấu hình checkout Git.
    return grains, {
        "path": relative_path,
        "sha256": hashlib.sha256(content.replace(b"\r\n", b"\n")).hexdigest(),
        "source": source,
    }


# Chỉ metadata schema, không SELECT row ứng dụng, snapshot không chứa khóa hoặc dữ liệu.
def schema_manifest():
    """Output: data dictionary cột/constraint/index và coverage catalog. Errors: RuntimeError khi thiếu bảng."""
    query = """SELECT jsonb_build_object(
     'tables',(SELECT jsonb_agg(jsonb_build_object('name',table_row.tablename,
      'description',obj_description(format('public.%I',table_row.tablename)::regclass,'pg_class'),
      'columns',(SELECT jsonb_agg(jsonb_build_object('name',column_name,'type',data_type,'nullable',is_nullable,'default',column_default,
       'description',col_description(format('public.%I',table_row.tablename)::regclass,ordinal_position)) ORDER BY ordinal_position)
       FROM information_schema.columns WHERE table_schema='public' AND table_name=table_row.tablename),
      'constraints',(SELECT jsonb_agg(jsonb_build_object('name',conname,'type',contype,'definition',pg_get_constraintdef(oid)) ORDER BY conname)
       FROM pg_constraint WHERE conrelid=format('public.%I',table_row.tablename)::regclass),
      'indexes',(SELECT jsonb_agg(jsonb_build_object('name',indexname,'definition',indexdef) ORDER BY indexname) FROM pg_indexes WHERE schemaname='public' AND tablename=table_row.tablename)) ORDER BY table_row.tablename)
      FROM pg_tables table_row WHERE schemaname='public'),
     'views',(SELECT jsonb_agg(jsonb_build_object('name',viewname,'definition',definition) ORDER BY viewname) FROM pg_views WHERE schemaname='public'),
     'function_count',(SELECT count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace),
     'trigger_count',(SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal AND tgrelid IN(SELECT oid FROM pg_class WHERE relnamespace='public'::regnamespace)));
    """
    manifest = json.loads(sql(query).stdout)
    # Ledger cũng cần type/default/key để bản schema giải thích từng cột, chỉ đọc pg_catalog metadata.
    manifest["internal_tables"]=json.loads(sql("""SELECT coalesce(jsonb_agg(jsonb_build_object('name',relation.tablename,
      'description',obj_description(format('migration_control.%I',relation.tablename)::regclass,'pg_class'),
      'columns',(SELECT jsonb_agg(jsonb_build_object('name',column_name,'type',data_type,'nullable',is_nullable,'default',column_default,
        'description',col_description(format('migration_control.%I',relation.tablename)::regclass,ordinal_position)) ORDER BY ordinal_position)
        FROM information_schema.columns WHERE table_schema='migration_control' AND table_name=relation.tablename),
      'constraints',(SELECT jsonb_agg(jsonb_build_object('name',conname,'type',contype,'definition',pg_get_constraintdef(oid)) ORDER BY conname)
        FROM pg_constraint WHERE conrelid=format('migration_control.%I',relation.tablename)::regclass)) ORDER BY relation.tablename),'[]')
      FROM pg_tables relation WHERE relation.schemaname='migration_control';""").stdout)
    actual = {table["name"] for table in manifest["tables"]}
    declared = set()
    for path in sources():
        declared.update(re.findall(r"CREATE TABLE (?:public\.)?([a-z_]+)\s*\(", path.read_text(encoding="utf-8")))
    grains, catalog_input = read_catalog_grains()
    expected = set(grains) | {"rule_draft_references"}
    if actual != declared or expected - actual:
        raise RuntimeError(f"Schema coverage mismatch: catalog missing={sorted(expected-actual)}, DDL drift={sorted(actual^declared)}")
    manifest.update(database=DATABASE, table_count=len(actual), catalog_table_count=len(expected),
                    catalog_missing=[], extra_relations=sorted(actual-expected), catalog_input=catalog_input)
    for table in manifest["tables"]:
        table["grain"] = grains.get(table["name"], {
            "rule_draft_references": "một resource reference trong AST/trigger/action draft",
            "template_draft_enum_values": "một literal ENUM trong stream draft",
            "template_draft_capabilities": "một capability của stream draft",
            "datastream_enum_values": "một literal ENUM trong stream đã publish",
            "datastream_capabilities": "một capability của stream đã publish",
        }.get(table["name"], "")).strip()
        nonnull = {column["name"] for column in table["columns"] if column["nullable"] == "NO"}
        keys = []
        for constraint in table["constraints"]:
            match = re.match(r"(?:PRIMARY KEY|UNIQUE) \(([^)]+)\)", constraint["definition"])
            if match:
                columns = tuple(column.strip() for column in match[1].split(","))
                if set(columns) <= nonnull:
                    keys.append(columns)
        table["candidate_keys_under_declared_constraints"] = [list(key) for key in keys if not any(set(other) < set(key) for other in keys)]
        if not table["grain"] or not table["candidate_keys_under_declared_constraints"]:
            raise RuntimeError("Relation lacks grain or declared candidate key: " + table["name"])
    return manifest


# Worksheet khóa/FD ghi rõ namespace/TTL/projection ngoại lệ, không tự chứng nhận BCNF bằng UUID.
def relation_worksheet(manifest):
    """Input
    Param: manifest — metadata cùng grain/candidate keys đã đối chiếu catalog.
    Output: Markdown dictionary cho89 relation, phân biệt FD được constraint chứng minh và giả định.
    """
    lines = ["# Relation worksheet của database canonical", "",
             "Sinh từ catalog và metadata PostgreSQL thật. Cột/type/NULL/default/FK/index đầy đủ ở [manifest.json](manifest.json).",
             "Candidate key dưới đây là PK/UK NOT NULL tối thiểu theo constraints đã khai; partial/nullable unique là key có điều kiện, xem index manifest.",
             "Với mỗi key K, K+ bằng toàn bộ thuộc tính relation dưới FD K→A do uniqueness thực thi. Đây là closure theo FD đã khai, không chứng minh không có business FD khác.",
             "Không chứng nhận mọi bảng đạt BCNF/4NF: namespace, pin, binding, fixed TTL và snapshot/projection có redundancy được liệt kê. AST/presentation/result là document có schema riêng, validator backend vẫn phải kiểm references/shape.", ""]
    for table in manifest["tables"]:
        columns = {column["name"] for column in table["columns"]}
        lines.extend(["## " + table["name"], "", "Grain: " + table["grain"] + ".",
                      "Khóa tối thiểu theo constraints: " + "; ".join("(" + ", ".join(key) + ")" for key in table["candidate_keys_under_declared_constraints"]) + ".",
                      "Thuộc tính: " + ", ".join(column["name"] for column in table["columns"]) + "."])
        exceptions = []
        if "workspace_id" in columns and "device_id" in columns:
            exceptions.append("device_id→workspace_id theo global device registry; workspace lặp có chủ đích để composite FK bảo vệ tenant")
        if "workspace_id" in columns and "api_key_id" in columns:
            exceptions.append("api_key_id→workspace_id theo global key lookup; supporting scoped UK không phải key tối thiểu mới")
        if "rule_version_id" in columns and "rule_id" in columns and table["name"] != "rule_versions":
            exceptions.append("(workspace_id,rule_version_id)→rule_id; bản sao rule binding được composite FK kiểm")
        if "rule_execution_id" in columns and "rule_version_id" in columns and table["name"] != "rule_executions":
            exceptions.append("execution→version trong cùng workspace; version copy phục vụ FK action/version")
        if "session_id" in columns and ("user_id" in columns or "actor_user_id" in columns):
            exceptions.append("session_id→principal với nhánh session không NULL; composite FK giữ binding")
        if "expires_at" in columns:
            exceptions.append("expires_at là deadline lưu bền vững theo policy của aggregate; TTL cố định được CHECK, expiry theo clock vẫn phải kiểm tại admission")
        if table["name"] == "telemetry_points":
            exceptions.append("envelope→device/observed_at/event_at là partial dependency có chủ đích theo Core33; trigger null-safe kiểm authority, không gắn nhãn2NF/3NF thuần")
        if table["name"] in ("push_deliveries", "webhook_deliveries", "rule_execution_snapshots", "execution_actuator_snapshots", "ota_jobs"):
            exceptions.append("snapshot immutable ghi sự thật tại admission, không đồng bộ theo current mutable resource; authority/runtime fence không thay history")
        lines.append("FD/ngoại lệ: " + ("; ".join(exceptions) + "." if exceptions else "các candidate key→thuộc tính còn lại; business FD bổ sung phải review trước đổi schema."))
        lines.append("Delete/NULL: mặc định NO ACTION/RESTRICT; optional FK dùng MATCH SIMPLE và CHECK shape khi cần, chi tiết từng constraint ở manifest. Không cascade lifecycle thành xóa lịch sử.")
        lines.append("")
    return "\n".join(lines)


# Reset schema chỉ nằm trong transaction và được rollback; DB phải trống, không DB test mới.
def temporary_schema_prefix():
    """Output: SQL giữ lock và guard dữ liệu trước dựng schema tạm. Không COMMIT prefix này."""
    return "BEGIN; SET LOCAL lock_timeout='5s'; SET LOCAL statement_timeout='30s';\n" + EMPTY_GUARD + """
DROP SCHEMA public CASCADE;
DROP SCHEMA migration_control CASCADE;
"""


# Kiểm clean DDL cùng DB, không lưu reset vì transaction rollback cả schema/data/ACL.
def verify_clean_schema(expected_fingerprint, inspection_policy=""):
    """Input
    Param: expected_fingerprint — metadata engine đang có.
    Param: inspection_policy — quyền inspection đã được cấp, tái dựng sau numbered DDL để giữ ACL.
    Output: PASS khi dựng sạch đủ DDL/ledger khớp; Errors: RuntimeError nếu drift.
    """
    script = temporary_schema_prefix() + "CREATE SCHEMA public AUTHORIZATION pg_database_owner; GRANT USAGE ON SCHEMA public TO PUBLIC;\n"
    script += (ROOT / "backend/migrations/runner/ledger.sql").read_text(encoding="utf-8")
    for path in sources():
        script += path.read_text(encoding="utf-8") + "\n"
    script += inspection_policy
    output = sql(script + FINGERPRINT + "\nROLLBACK;").stdout.strip()
    if output != expected_fingerprint:
        raise RuntimeError(f"Clean DDL fingerprint differs: {output} vs {expected_fingerprint}")
    return "PASS:clean_ddl_same_database_rollback"


# Dump chỉ schema/ACL; không account/hash/ciphertext hoặc ledger rows thật đi vào artifact.
def snapshot_sql():
    """Output: schema-only PostgreSQL17 dump. Side effects: chỉ đọc metadata qua pg_dump trong container."""
    snapshot = lab.docker("exec", lab.CONTAINER, "pg_dump", "-h", "/tmp", "-U", lab.MIGRATOR,
                          "-d", DATABASE, "--schema-only", "--no-owner", "--schema=public", "--schema=migration_control").stdout
    # pg_dump bỏ ACL mặc định của public; dựng schema mới phải khôi phục USAGE giống initdb.
    snapshot = snapshot.replace("CREATE SCHEMA public;", "CREATE SCHEMA IF NOT EXISTS public AUTHORIZATION pg_database_owner;")
    return snapshot + "\n/* Khôi phục ACL mặc định public mà pg_dump có thể lược bỏ. */\nGRANT USAGE ON SCHEMA public TO PUBLIC;\n"


# Restore metadata kiểm cùng DB trống trong transaction, rollback khôi phục ledger và schema gốc.
def verify_snapshot(snapshot, expected_fingerprint):
    """Input
    Param: snapshot — SQL pg_dump schema-only không dữ liệu.
    Param: expected_fingerprint — cấu trúc/ACL/functions/views phải giữ nguyên.
    Output: PASS khi restore khớp. Errors: RuntimeError nếu schema/ACL drift.
    """
    # Public do pg_database_owner sở hữu như initdb; no-owner không được làm khác ACL grantor.
    restore = snapshot.replace("CREATE SCHEMA public;", "CREATE SCHEMA public AUTHORIZATION pg_database_owner;")
    output = sql(temporary_schema_prefix() + restore + FINGERPRINT + "\nROLLBACK;").stdout.strip()
    if output != expected_fingerprint:
        raise RuntimeError(f"Snapshot restore fingerprint differs: {output} vs {expected_fingerprint}")
    return "PASS:snapshot_restore_same_database_rollback"


# Chứng minh runner fail drift và rollback toàn DDL+ledger khi SQL lỗi, không thay checksum thật.
def verify_runner():
    """Output: các PASS từ lỗi được chủ động tạo trên engine. Side effects: mọi mutation lỗi rollback."""
    first = sources()[0]
    version, _ = migration_identity(first)
    result = lab.sql(lab.migration_script(first.read_text(encoding="utf-8"), "0"*64, version), database=DATABASE,
                     variables=(("migration_version", version), ("migration_checksum", "0"*64)), check=False)
    if result.returncode == 0 or "migration checksum drift" not in result.stderr:
        raise RuntimeError("Checksum drift was not rejected")
    version = "platform-verification-rollback-check"
    fault = "CREATE TABLE public.migration_rollback_probe(marker integer); SELECT 1/0;"
    checksum = hashlib.sha256(fault.encode()).hexdigest()
    result = lab.sql(lab.migration_script(fault, checksum, version), database=DATABASE,
                     variables=(("migration_version", version), ("migration_checksum", checksum)), check=False)
    remains = sql("SELECT to_regclass('public.migration_rollback_probe') IS NULL AND NOT EXISTS(SELECT 1 FROM migration_control.applied_migrations WHERE version='platform-verification-rollback-check');").stdout.strip()
    if result.returncode == 0 or remains != "t":
        raise RuntimeError("Failed migration left DDL or ledger behind")
    return ["PASS:migration_checksum_drift_rejected", "PASS:migration_fault_rolls_back_ddl_and_ledger"]


# Role phải bị từ chối thật trên engine, không chỉ xem GRANT source hoặc đoán effective ACL.
def verify_permissions():
    """Output: PASS cho SELECT credential, DML, DDL và helper EXECUTE bị deny dưới runtime."""
    results = []
    for name, statement in (
        ("runtime_cannot_read_verifiers", "SELECT token_digest FROM public.sessions;"),
        ("runtime_cannot_update_audit", "UPDATE public.audit_events SET outcome=outcome;"),
        ("runtime_cannot_create_table", "CREATE TABLE public.runtime_permission_probe(marker integer);"),
        ("runtime_cannot_call_owner_worker", "SELECT * FROM public.claim_outbox('TEST',30,1);"),
    ):
        result = sql("\\set VERBOSITY verbose\n" + statement, role=lab.RUNTIME, check=False)
        if result.returncode == 0 or "42501" not in result.stderr:
            raise RuntimeError(f"Unexpected runtime permission outcome: {name}")
        results.append("PASS:" + name)
    return results


# Chỉ duy trì policy của role đã được setup với dấu provenance, không tự cấp role mới khi verify.
def approved_inspection_policy():
    """Output: policy cho role inspection đã setup và có đúng dấu provenance; rỗng nếu chưa có role.
    Errors: RuntimeError nếu role có quyền/nguồn gốc khác, không tự nhận diện role lạ làm role đã được giao.
    """
    state=sql("""SELECT CASE WHEN count(*)=0 THEN 'ABSENT' WHEN bool_and(rolcanlogin AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolreplication AND NOT rolbypassrls
      AND NOT EXISTS(SELECT 1 FROM pg_auth_members WHERE member=pg_roles.oid)
      AND shobj_description(oid,'pg_authid')='IoT canonical local inspection role; no writer authority') THEN 'APPROVED' ELSE 'UNEXPECTED' END
      FROM pg_roles WHERE rolname='iot_dbeaver_reader';""").stdout.strip()
    if state=="ABSENT":
        return ""
    if state!="APPROVED":
        raise RuntimeError("Inspection role provenance or privileges differ from approved policy")
    return (ROOT/"backend/migrations/lab/dbeaver_permissions.sql").read_text(encoding="utf-8")


# Không gọi provision auth hoặc create_test_database; cả vòng đời mới chỉ dùng DATABASE canonical.
def main():
    """Điều phối apply/status/verify trực tiếp trên PostgreSQL thật.
    Output: summary không secret. Side effects: apply DDL, ghi bundle/snapshot/manifest/evidence.
    Errors: dừng ngay khi identity, dữ liệu, checksum, constraint hoặc restore không khớp.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("apply", "verify", "status"), nargs="?", default="verify")
    action = parser.parse_args().action
    lab.inspect_lab()
    if action == "status":
        print(json.dumps(schema_manifest(), ensure_ascii=True))
        return
    lab.bootstrap_database(DATABASE)
    sql("BEGIN;\n" + EMPTY_GUARD + "\nROLLBACK;")
    migrations = apply()
    inspection_policy=approved_inspection_policy()
    if inspection_policy:
        sql(inspection_policy)
    bundle = bundle_sql()
    (ROOT / "backend/migrations/platform.sql").write_text(bundle, encoding="utf-8", newline="\n")
    if action == "apply":
        print(json.dumps({"database": DATABASE, "migrations": migrations}, indent=2))
        return
    fingerprint = sql(FINGERPRINT).stdout.strip()
    manifest = schema_manifest()
    documentation_coverage = documentation.verify_native_comments(sql, manifest)
    checks = verify_sql() + verify_runner() + verify_permissions()
    checks.append("PASS:all_native_table_view_and_column_comments_match_dictionary")
    checks += platform_concurrency.verify(sql, (TEST_ROOT / "fixture.sql").read_text(encoding="utf-8"))
    checks += publication_checks.verify(sql)
    checks.append(verify_clean_schema(fingerprint,inspection_policy))
    snapshot = source_documentation.annotate_tables(documentation.annotate_snapshot(snapshot_sql(), manifest), manifest)
    checks.append(verify_snapshot(snapshot, fingerprint))
    # Kiểm chính file tổng hợp trên engine bằng re-run ledger, không chỉ nối text rồi giao.
    bundle_result = sql(bundle).stdout
    if bundle_result.count("ALREADY_APPLIED") != len(SOURCE_NAMES):
        raise RuntimeError("Aggregate SQL did not replay every canonical version")
    checks.append("PASS:aggregate_sql_rerun_verified")
    if sql(FINGERPRINT).stdout.strip() != fingerprint:
        raise RuntimeError("Verification changed the canonical schema")
    sql("BEGIN;\n" + EMPTY_GUARD + "\nROLLBACK;")
    checks.append("PASS:canonical_schema_and_empty_data_preserved")
    lab.validate_sql_results(checks)
    (MIGRATIONS / "schema.sql").write_text(snapshot, encoding="utf-8", newline="\n")
    (MIGRATIONS / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False)+"\n", encoding="utf-8")
    (MIGRATIONS / "relations.md").write_text(relation_worksheet(manifest), encoding="utf-8", newline="\n")
    report = {"timestamp_utc": datetime.now(timezone.utc).isoformat(), "database": DATABASE,
              "server_version": sql("SHOW server_version;").stdout.strip(), "migrations": migrations,
              "table_count": manifest["table_count"], "catalog_table_count": manifest["catalog_table_count"],
              "catalog_input": manifest["catalog_input"],
              "function_count": manifest["function_count"], "trigger_count": manifest["trigger_count"],
              "documentation_coverage": documentation_coverage,
              "fingerprint": fingerprint.splitlines(), "sql_checks": checks, "sql_pass_count": len(checks),
              "aggregate_sha256": hashlib.sha256(bundle.encode()).hexdigest(),
              "scope": "CANONICAL_DATABASE_DDL_VERIFIED", "additional_databases_created": 0,
              "remaining_gates": ["BACKEND_WRITER_AUTHORIZATION", "AST_REFERENCE_BIJECTION", "TEMPLATE_AND_DASHBOARD_VALIDATORS", "CRYPTOGRAPHIC_CUSTODY_AND_VALIDATION",
                                  "PHYSICAL_DEVICE_AND_PROVIDER_RECONCILIATION", "LOAD_30_MINUTES", "PRODUCTION_RPO_RTO"]}
    (ROOT / "ops/database/evidence/platform-latest.json").write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")
    print(json.dumps({key: value for key, value in report.items() if key not in ("migrations", "sql_checks")}, indent=2))


if __name__ == "__main__":
    main()
