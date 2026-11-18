"""Khởi tạo PostgreSQL thật và kiểm bản nháp trên đúng đích lab đã được giao."""

import argparse
import hashlib
import json
import re
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from threading import Barrier
from uuid import uuid4


ROOT = Path(__file__).resolve().parents[2]
IMAGE = "postgres@sha256:858bb5e98eed02eb8cafbcdc007f9a65d1b613972028944a8ec2133ccaf80d27"
CONTAINER = "iot-postgres17-database"
DATABASE = "iot_database_lab"
PURPOSE = "iot-platform-database-plan"
DOCKER_CLI_CONFIG = ROOT / "ops/auth/.auth-lab-docker-config"
ADMIN = "iot_lab_owner"
MIGRATOR = "iot_migrator"
RUNTIME = "iot_runtime"
MIGRATION_ROOT = ROOT / "backend/migrations"
MIGRATION = MIGRATION_ROOT / "0001_auth.sql"
TEST_SQL = ROOT / "backend/tests/database/draft_auth.sql"
DATA_DIRECTORY = "/tmp/iot-postgres17-data"


# Cố định config CLI về đường dẫn rỗng riêng để Docker không đọc credential mặc định của người chạy.
def docker_argv(*arguments):
    """Tạo argv Docker an toàn để mọi fixture dùng config cô lập, không kế thừa registry token cá nhân.

    Input
    Param: arguments — các lệnh/đối số Docker nội bộ đã chọn bởi caller.
    Output: argv không qua shell, trỏ `--config` vào namespace Auth Lab.
    """
    return ["docker", "--config", str(DOCKER_CLI_CONFIG), *arguments]


# Chạy argv riêng và nhận stdin UTF-8; không mở shell hoặc đọc/cấp environment.
def docker(*arguments, input_text=None, check=True):
    """Input: arguments là argv nội bộ, input_text là SQL tổng hợp, check điều khiển lỗi.
    Output: CompletedProcess; Errors: timeout/lỗi Docker khi check bật.
    Side effects: chỉ thực hiện thao tác Docker được caller chọn trong namespace lab.
    """
    result = subprocess.run(
        docker_argv(*arguments), input=input_text, text=True, encoding="utf-8",
        capture_output=True, timeout=120,
    )
    if check and result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return result


# Chỉ cho phép DB chính và DB restore mới có hậu tố ngẫu nhiên, tránh nhắm DB hệ thống.
def validate_database_name(database):
    """Input: database là tên đích; Errors: ValueError nếu ngoài namespace đã duyệt."""
    if database not in (DATABASE, "iot_platform_lab") and not re.fullmatch(r"iot_database_restore_[0-9a-f]{12}", database):
        raise ValueError("Database target is outside the approved namespace")


# Kiểm identity và boundary trước mọi lần ghi; không nhận nhầm container cùng tên.
def validate_container(metadata, expected_image):
    """Input: metadata chỉ gồm field không secret, expected_image là image ID đã pin.
    Errors: RuntimeError khi label/image/user/network/cổng không đúng lab.
    """
    expected = {"label": PURPOSE, "image": expected_image, "network": "none", "user": "postgres"}
    if (
        any(metadata.get(key) != value for key, value in expected.items())
        or metadata.get("ports") not in ({}, None)
        or metadata.get("mounts") not in ("", "tmpfs:/var/lib/postgresql/data;")
    ):
        raise RuntimeError("Container identity or isolation differs from the approved lab")


# Chỉ inspect các field được nêu; không đọc Config.Env hoặc toàn bộ container config.
def inspect_lab():
    """Output: metadata identity không secret; Errors: lỗi container thiếu/sai boundary."""
    expected_image = docker("image", "inspect", IMAGE, "--format", "{{.Id}}").stdout.strip()
    template = '{{index .Config.Labels "com.iot.database-purpose"}}|{{.Image}}|{{.HostConfig.NetworkMode}}|{{json .HostConfig.PortBindings}}|{{.Config.User}}|{{range .Mounts}}{{.Type}}:{{.Destination}};{{end}}'
    fields = docker("inspect", CONTAINER, "--format", template).stdout.strip().split("|")
    metadata = dict(zip(("label", "image", "network", "ports", "user", "mounts"), fields))
    metadata["ports"] = json.loads(metadata["ports"])
    validate_container(metadata, expected_image)
    return metadata


# Gửi SQL qua stdin tới Unix socket của container được kiểm, không dùng connection secret.
def sql(statement, role=MIGRATOR, database=DATABASE, check=True, variables=()):
    """Gửi SQL nội bộ qua stdin với role/DB allowlist và quote riêng value để tránh chèn SQL.

    Input
    Param: statement — SQL source do caller nội bộ chọn; không nhận câu lệnh HTTP/client.
    Param: role — một trong owner/migrator/runtime của lab, không principal tùy ý.
    Param: database — đích lab được kiểm namespace trước khi chạy Docker.
    Param: check — True truyền lỗi psql cho caller; False cho fault harness lọc lỗi an toàn.
    Param: variables — value hữu hạn dùng qua quote :'name'; tên và định dạng đều phải thuộc allowlist.
    Output: CompletedProcess để kiểm exit/SQLSTATE; không tự log row hoặc value.
    Side effects: mutation theo SQL nội bộ đã chọn, không mở owner TCP hoặc đọc credential/env.
    """
    validate_database_name(database)
    if role not in (ADMIN, MIGRATOR, RUNTIME):
        raise ValueError("Unknown lab role")
    arguments = ["exec", "-i", CONTAINER, "psql", "-X", "-q", "-A", "-t", "-w", "-v", "ON_ERROR_STOP=1", "-h", "/tmp", "-U", role, "-d", database]
    has_lab_bucket_digests = False
    for name, value in variables:
        # Psql lấy value cuối khi tên lặp; binding scope mới phải duy nhất trước khi tạo process.
        if name == "auth_lab_bucket_digests":
            if has_lab_bucket_digests:
                raise ValueError("Duplicate auth lab bucket binding")
            has_lab_bucket_digests = True
        valid = (name == "migration_checksum" and re.fullmatch(r"[0-9a-f]{64}", value)) or (
            name == "migration_version" and re.fullmatch(r"[a-z0-9][a-z0-9-]{0,127}", value)
        ) or (
            name == "auth_fault_user_id" and re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", value)
        ) or (
            # Chỉ bind ID của session/context synthetic; caller không thể chọn UUID tùy ý ngoài hình dạng chuẩn.
            name in ("auth_fault_expired_session_id", "auth_fault_expired_context_id")
            and re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", value)
        ) or (
            # Bearer không qua psql; chỉ SHA-256 lowercase của fixture expired được bind làm verifier.
            name == "auth_fault_token_digest" and re.fullmatch(r"[0-9a-f]{64}", value)
        ) or (
            name == "auth_fault_bucket_digest" and re.fullmatch(r"[0-9a-f]{64}", value)
        ) or (
            # 5email fixture và1unknown: đúng6hex digest/389ký tự, không mở danh sách tùy ý hoặc nối SQL.
            name == "auth_lab_bucket_digests" and isinstance(value, str)
            and re.fullmatch(r"[0-9a-f]{64}(?:,[0-9a-f]{64}){5}", value)
            and len(set(value.split(","))) == 6
        ) or (
            # Mảng UUID request bounded8 của fault suite; quote ở SQL rồi cast uuid[] kiểm kiểu lần nữa.
            name == "auth_fault_correlations" and re.fullmatch(r"(?:[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})(?:,[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}){0,7}|", value)
        ) or (
            # Oracle logout chỉ nhận một đến ba session UUID đã xác minh từ fixture.
            name == "auth_fault_session_ids" and re.fullmatch(
                r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}(?:,[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}){0,2}",
                value,
            )
        ) or (
            # Installation fixture được xóa theo đúng UUID ngẫu nhiên do test vừa tạo.
            name in ("auth_fault_installation_id", "auth_fault_survivor_installation_id") and re.fullmatch(
                r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", value
            )
        )
        if not valid:
            raise ValueError("Unexpected psql variable")
        arguments.extend(["--set", f"{name}={value}"])
    return docker(*arguments, input_text=statement, check=check)


# Tạo engine chỉ khi namespace chưa có container; lần chạy lại bắt buộc khớp identity.
def provision():
    """Side effects: tạo/start container và hai role/DB tổng hợp; không reset target có sẵn.
    Errors: container sai identity, daemon lỗi hoặc engine không ready trong45 giây.
    """
    names = docker("container", "ls", "-a", "--filter", f"name=^/{CONTAINER}$", "--format", "{{.Names}}").stdout.strip()
    if not names:
        # Unix trust chỉ trong container network none; host TCP bị reject, không publish cổng.
        startup = (
            f"if test ! -f {DATA_DIRECTORY}/PG_VERSION; then "
            f"initdb -D {DATA_DIRECTORY} -U {ADMIN} --auth-local=trust --auth-host=reject --locale=C --encoding=UTF8 || exit 1; fi; "
            f"exec postgres -D {DATA_DIRECTORY} -c listen_addresses='' -c unix_socket_directories=/tmp"
        )
        docker("create", "--name", CONTAINER, "--network", "none", "--user", "postgres", "--label", f"com.iot.database-purpose={PURPOSE}", "--tmpfs", "/var/lib/postgresql/data", "--entrypoint", "/bin/sh", IMAGE, "-c", startup)
    inspect_lab()
    docker("start", CONTAINER)
    deadline = time.monotonic() + 45
    while docker("exec", CONTAINER, "pg_isready", "-q", "-h", "/tmp", "-U", ADMIN, check=False).returncode:
        if time.monotonic() >= deadline:
            raise RuntimeError("PostgreSQL did not become ready within 45 seconds")
        time.sleep(0.5)
    bootstrap_database(DATABASE)


# Đóng migration và ledger trong một transaction; khóa chung chặn hai runner áp cùng lúc.
def migration_script(migration, checksum, version="draft-0001-auth"):
    """Tạo script atomic từ một nguồn SQL canonical, giữ version ledger đã áp.
    Input
    Param: migration — DDL đã đọc từ numbered migration.
    Param: checksum — SHA-256 hex được bind riêng qua psql.
    Param: version — identity migration ổn định, được bind riêng qua psql.
    Output: script psql có lock/replay/drift guard; Errors: digest/version sai định dạng.
    """
    if not re.fullmatch(r"[0-9a-f]{64}", checksum):
        raise ValueError("Invalid migration checksum")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,127}", version):
        raise ValueError("Invalid migration version")
    template = (MIGRATION_ROOT / "runner/apply.sql").read_text(encoding="utf-8")
    ledger = (MIGRATION_ROOT / "runner/ledger.sql").read_text(encoding="utf-8")
    return template.replace("{{ledger_sql}}", ledger).replace("{{migration_sql}}", migration)


# Khóa thứ tự migration tường minh, không áp nhầm schema snapshot hoặc SQL bootstrap.
def migration_sources():
    """Output: các cặp version/path theo thứ tự, giữ identity legacy0001 đã có trong ledger."""
    return (
        ("draft-0001-auth", MIGRATION_ROOT / "0001_auth.sql"),
        ("0002-auth-integrity", MIGRATION_ROOT / "0002_auth_integrity.sql"),
    )


# Áp từng version với checksum byte gốc; không rewrite lịch sử của phiên bản cũ.
def apply_migrations(database=DATABASE):
    """Input
    Param: database — đích lab đã allowlist.
    Output: trạng thái áp từng version; Errors: SQL/drift rollback version lỗi.
    """
    results = {}
    for version, path in migration_sources():
        checksum = hashlib.sha256(path.read_bytes()).hexdigest()
        script = migration_script(path.read_text(encoding="utf-8"), checksum, version)
        result = sql(script, database=database, variables=(("migration_checksum", checksum), ("migration_version", version)))
        results[version] = result.stdout.strip()
    return results


# Cấp đúng DB lab bằng SQL bootstrap có lưu trong migrations, không tìm credential có sẵn.
def bootstrap_database(database):
    """Input
    Param: database — tên main/restore được allowlist.
    Side effects: CREATE role/DB còn thiếu; Errors: target sai hoặc role/owner bất thường.
    """
    validate_database_name(database)
    docker("exec", "-i", CONTAINER, "psql", "-X", "-q", "-w", "-v", "ON_ERROR_STOP=1", "--set", f"lab_database={database}", "-h", "/tmp", "-U", ADMIN, "-d", "postgres", input_text=(MIGRATION_ROOT / "lab/bootstrap.sql").read_text(encoding="utf-8"))


# Evidence phải fail nếu còn GAP hoặc tên ca trùng, không xuất báo cáo thành công giả.
def validate_sql_results(results):
    """Input
    Param: results — các dòng trạng thái do SQL suite thật trả về.
    Errors: RuntimeError khi thiếu kết quả, chưa PASS hoặc duplicate test.
    """
    if not results or len(results) != len(set(results)) or any(not re.fullmatch(r"PASS:[a-z][a-z0-9_]+", item) for item in results):
        raise RuntimeError("SQL verification contains missing, duplicate, or non-PASS results")


# Chỉ điều chỉnh lệnh tạo public mà initdb đã cung cấp trên DB restore mới, giữ mọi constraint.
def prepare_restore_dump(dump):
    """Input: dump là SQL do pg_dump của lab sinh. Output: SQL giữ nội dung ngoài CREATE SCHEMA public.
    Errors: ValueError nếu có nhiều lệnh public bất thường; không áp lên DB có dữ liệu.
    """
    pattern = r"^CREATE SCHEMA public;$"
    if len(re.findall(pattern, dump, flags=re.MULTILINE)) > 1:
        raise ValueError("Unexpected repeated public schema declaration")
    return re.sub(pattern, "CREATE SCHEMA IF NOT EXISTS public;", dump, flags=re.MULTILINE)


# Mỗi test migration/restore nhận một DB mới; không xóa hoặc tái dùng DB đích chưa rõ trạng thái.
def create_test_database():
    """Output: tên DB mới thuộc namespace allowlist; Side effects: CREATE DATABASE bằng admin lab."""
    database = "iot_database_restore_" + uuid4().hex[:12]
    bootstrap_database(database)
    return database


# Chỉ kiểm số hàng, không đọc verifier/key; từ chối fixture/dump khi đích đã có dữ liệu ứng dụng.
def ensure_empty_application_tables():
    """Errors: RuntimeError nếu bảy bảng ứng dụng có hàng hoặc count không xác định.
    Side effects: chỉ SELECT count để tránh đọc dữ liệu có thể không còn thuộc fixture lab.
    """
    count = sql("SELECT (SELECT count(*) FROM users)+(SELECT count(*) FROM auth_settings)+(SELECT count(*) FROM sessions)+(SELECT count(*) FROM login_attempts)+(SELECT count(*) FROM workspaces)+(SELECT count(*) FROM memberships)+(SELECT count(*) FROM audit_events);").stdout.strip()
    if count != "0":
        raise RuntimeError("Lab has application rows; refusing synthetic fixtures or dump")


# Export toàn bộ DDL/ACL hiện tại, không export dữ liệu, rồi import snapshot trên DB mới để đối chiếu.
def export_schema_snapshot(fingerprint):
    """Input
    Param: fingerprint — metadata fingerprint của main DB đã kiểm chứng.
    Output: đường dẫn/hash/tên DB kiểm snapshot; Side effects: ghi schema.sql và tạo DB test mới.
    Errors: snapshot tái tạo không khớp table/constraint/trigger/function/ACL.
    """
    snapshot = docker("exec", CONTAINER, "pg_dump", "-h", "/tmp", "-U", MIGRATOR, "-d", DATABASE, "--schema-only", "--no-owner", "--schema=public", "--schema=migration_control").stdout
    descriptions = {
        "enforce_session_immutability": "Giữ identity/admission của phiên và không đảo revocation; chi tiết nguồn0002.",
        "assert_workspace_capable_admin": "Kiểm workspace còn Admin ACTIVE có account ACTIVE/full ở trạng thái cuối transaction.",
        "fence_membership_administrators": "Ghi MVCC fence trên User/Workspace cũ và mới để chống write skew, kể cả RR snapshot cũ.",
        "fence_user_administrator_workspaces": "Đồng bộ account-state mutation với workspace khi quyền quản trị có thể mất hiệu lực.",
        "validate_membership_administrators": "Kiểm các workspace hai phía membership bằng deferred trigger sau batch cuối.",
        "validate_workspace_administrators": "Buộc workspace mới có Admin đầu tiên cùng commit và kiểm parent fence.",
        "validate_user_administrator_workspaces": "Kiểm capable Admin sau thay đổi status/must_change_password của account.",
        "reject_membership_truncate": "Chặn TRUNCATE vì lệnh này không phát row trigger và có thể né last-Admin guard.",
    }
    for name, description in descriptions.items():
        snapshot = re.sub(r"(?m)^CREATE FUNCTION public\." + re.escape(name) + r"\(", "/* " + description + " */\n" + r"\g<0>", snapshot)
    for name, description in {
        "sessions_by_user": "Phục vụ revoke/list session theo user_id trước session identity.",
        "memberships_picker": "Phục vụ picker ACTIVE theo user_id/workspace_id, giữ đúng scope principal.",
        "audit_events_retention": "Phục vụ purge theo occurred_at/id với cutoff và FK đã kiểm riêng.",
    }.items():
        snapshot = re.sub(r"(?m)^CREATE INDEX " + re.escape(name) + r" ", "/* " + description + " */\n" + r"\g<0>", snapshot)
    header = (
        "/* Snapshot schema-only của iot_database_lab trên PostgreSQL17; không có dữ liệu/credential.\n"
        " * Nguồn chuẩn:0001_auth.sql +0002_auth_integrity.sql, runner/ và lab/.\n"
        " * Snapshot gồm public/migration_control và ACL; bootstrap role ở lab/bootstrap.sql.\n"
        " * Không chạy snapshot nối tiếp numbered migration; runner chỉ áp danh sách version tường minh.\n"
        " * Có thể dựng DB trống bằng psql/migrator sau bootstrap; lịch sử applied_migrations không có dữ liệu.\n"
        " */\n"
    )
    snapshot = header + prepare_restore_dump(snapshot)
    database = create_test_database()
    sql(snapshot, database=database)
    fingerprint_sql = (MIGRATION_ROOT / "runner/fingerprint.sql").read_text(encoding="utf-8")
    if sql(fingerprint_sql, database=database).stdout.strip() != fingerprint:
        raise RuntimeError("Schema-only snapshot does not reproduce the live schema and ACL")
    path = MIGRATION_ROOT / "schema.sql"
    path.write_text(snapshot, encoding="utf-8")
    return {"path": str(path.relative_to(ROOT)), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "verification_database": database, "status": "REIMPORTED_SCHEMA_AND_ACL_MATCH"}


# Kiểm engine thật, ràng buộc hiện có, runner, quyền và restore; không quy thành feature PASS.
def verify():
    """Output: evidence chỉ chứa version/hash/count/status; Side effects: DB restore mới và marker tổng hợp.
    Errors: bất kỳ assertion/SQL test nào sai đều dừng và giữ dữ liệu để review.
    """
    inspect_lab()
    checksum = hashlib.sha256(MIGRATION.read_bytes()).hexdigest()
    ensure_empty_application_tables()
    migration_database = create_test_database()
    # Barrier cho hai client cùng tranh migration lock, không dùng sleep để phỏng đoán race.
    barrier = Barrier(2)

    # Mỗi worker có psql connection riêng, giúp kiểm serial hóa của ledger trên PostgreSQL.
    def apply_contender():
        """Output: trạng thái apply của một connection sau barrier; Errors: lỗi runner thật."""
        barrier.wait(timeout=10)
        return apply_migrations(database=migration_database)

    with ThreadPoolExecutor(max_workers=2) as executor:
        futures = [executor.submit(apply_contender) for _ in range(2)]
        applications = [future.result() for future in futures]
    for version, _ in migration_sources():
        if sorted(item[version] for item in applications) != ["ALREADY_APPLIED", "APPLIED"]:
            raise RuntimeError("Fresh concurrent migration did not have exactly one winner per version")
    main_applications = apply_migrations()
    for database in (DATABASE, migration_database):
        sql((MIGRATION_ROOT / "lab/permissions.sql").read_text(encoding="utf-8"), database=database)
        sql((MIGRATION_ROOT / "lab/restore_probe.sql").read_text(encoding="utf-8"), database=database)
    for version, path in migration_sources():
        drift = sql(migration_script(path.read_text(encoding="utf-8"), "0" * 64, version), check=False, variables=(("migration_checksum", "0" * 64), ("migration_version", version)))
        if drift.returncode == 0 or "migration checksum drift" not in drift.stderr:
            raise RuntimeError("Checksum drift was not rejected for " + version)
    # Lỗi sau CREATE TABLE phải rollback DDL; không DROP bất kỳ bảng đang có nào.
    interrupted = sql("BEGIN; CREATE TABLE migration_control.rollback_probe(probe_id integer); SELECT 1/0; COMMIT;", check=False)
    if interrupted.returncode == 0 or sql("SELECT to_regclass('migration_control.rollback_probe') IS NULL;").stdout.strip() != "t":
        raise RuntimeError("Interrupted transaction did not roll back DDL")
    checks = sql(TEST_SQL.read_text(encoding="utf-8")).stdout.strip().splitlines()
    validate_sql_results(checks)
    clean_checks = sql(TEST_SQL.read_text(encoding="utf-8"), database=migration_database).stdout.strip().splitlines()
    validate_sql_results(clean_checks)
    if checks != clean_checks:
        raise RuntimeError("Clean build and upgrade SQL results differ")
    permissions = []
    for statement in ("CREATE TABLE public.forbidden_runtime_table(id integer);", "SELECT signing_key FROM auth_settings;", "DELETE FROM audit_events;", "UPDATE users SET status='DISABLED';"):
        denied = sql(statement, role=RUNTIME, check=False)
        if denied.returncode == 0 or "permission denied" not in denied.stderr:
            raise RuntimeError("Runtime privilege negative control failed")
        permissions.append("DENIED")
    sql("SELECT count(*) FROM memberships;", role=RUNTIME)
    # Chỉ dump dữ liệu tổng hợp của lab đã nhận diện; dump nằm trong RAM, không in vào evidence.
    ensure_empty_application_tables()
    dump = docker("exec", CONTAINER, "pg_dump", "-h", "/tmp", "-U", MIGRATOR, "-d", DATABASE, "--no-owner", "--schema=public", "--schema=migration_control").stdout
    restore_database = create_test_database()
    if sql("SELECT count(*)=0 FROM pg_class WHERE relnamespace='public'::regnamespace;", database=restore_database).stdout.strip() != "t":
        raise RuntimeError("Restore target public schema is not empty")
    sql(prepare_restore_dump(dump), database=restore_database)
    fingerprint_sql = (MIGRATION_ROOT / "runner/fingerprint.sql").read_text(encoding="utf-8")
    fingerprint = sql(fingerprint_sql).stdout.strip()
    for database in (migration_database, restore_database):
        if fingerprint != sql(fingerprint_sql, database=database).stdout.strip():
            raise RuntimeError("Clean/restore schema, triggers, routines or ACL differ from main")
    if sql("SELECT note FROM migration_control.restore_probe WHERE probe_id=1;", database=restore_database).stdout.strip() != "synthetic restore marker":
        raise RuntimeError("Restore lost the synthetic row")
    roles = sql("SELECT count(*)=2 AND bool_and(NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolbypassrls) FROM pg_roles WHERE rolname IN ('iot_migrator','iot_runtime');").stdout.strip()
    if roles != "t":
        raise RuntimeError("PoC roles have elevated cluster privileges")
    # Module cục bộ chỉ được nạp khi chạy verify, không có Docker side effect khi import unit test.
    from concurrency_checks import verify_concurrency
    concurrency = verify_concurrency(sql, CONTAINER, MIGRATOR, migration_database)
    snapshot = export_schema_snapshot(fingerprint)
    return {"timestamp_utc": datetime.now(timezone.utc).isoformat(), "database": DATABASE, "container": CONTAINER, "image": IMAGE, "server_version": sql("SHOW server_version;").stdout.strip(), "migration_sha256": checksum, "migration_checksums": {version: hashlib.sha256(path.read_bytes()).hexdigest() for version, path in migration_sources()}, "main_migrations": main_applications, "migration_database": migration_database, "migration_contenders": applications, "checksum_drift": "REJECTED_FOR_ALL_VERSIONS", "interrupted_ddl": "ROLLED_BACK", "sql_checks": checks, "sql_pass_count": len(checks), "concurrency_checks": concurrency, "schema_fingerprint": fingerprint, "schema_snapshot": snapshot, "runtime_denials": len(permissions), "runtime_roles": "NON_SUPERUSER", "restore_database": restore_database, "restore": "SCHEMA_TRIGGERS_FUNCTIONS_ACL_AND_SYNTHETIC_ROW_MATCH", "design_plan_acceptance": "CURRENT_IMPORTED_SCHEMA_REPAIRED_NOT_ALL_FEATURES"}


# CLI chỉ nhận các tác vụ có scope cố định, không nhận URL/credential/SQL tùy ý.
def main():
    """Side effects: provision hoặc verify theo lựa chọn CLI; Output: JSON evidence không secret."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("provision", "verify", "status"))
    command = parser.parse_args().command
    if command == "provision":
        provision()
        print(json.dumps({"container": CONTAINER, "database": DATABASE, "image": IMAGE, "status": "READY"}, indent=2))
    elif command == "verify":
        # Evidence chỉ có identity/count/hash/status; không chứa dump, verifier hoặc key material.
        report = json.dumps(verify(), indent=2) + "\n"
        report_path = ROOT / "ops/database/evidence/runtime-2026-10-23.json"
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(report, encoding="utf-8")
        print(report, end="")
    else:
        print(json.dumps(inspect_lab(), indent=2))


if __name__ == "__main__":
    main()
