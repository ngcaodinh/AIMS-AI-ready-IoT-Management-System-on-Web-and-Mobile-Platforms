"""Kiểm repository Rust trên duy nhất DB canonical với credential SCRAM tạm trong bộ nhớ."""

import hashlib
import hmac
import json
import re
import secrets
import subprocess
import threading
from datetime import datetime, timezone, timedelta
from contextlib import contextmanager
from pathlib import Path
from uuid import UUID, uuid4

import local_db_bridge as bridge
import verify_database as lab
import verify_platform as platform

ROOT = Path(__file__).resolve().parents[2]
ROLE = "iot_repository_probe"
DATABASE = "iot_platform_lab"
TABLES = ("users", "sessions", "login_attempt_buckets", "workspaces", "memberships", "membership_grants", "user_preferences", "push_installations", "websocket_tickets", "outbox_events", "outbox_consumptions", "global_idempotency_records", "workspace_invitations", "membership_admission_fences", "workspace_idempotency_records", "password_reset_admissions")
MEMBER_TABLES = ("rules", "rule_versions", "rule_version_actions", "rule_executions", "action_executions", "action_jobs", "workspace_runtime_quotas", "commands", "api_keys", "push_deliveries", "webhook_subscriptions", "webhook_deliveries")
MEMBER_KEY_TABLES = ("templates", "template_versions", "template_draft_streams", "template_draft_enum_values", "template_draft_capabilities", "datastream_definitions", "datastream_enum_values", "datastream_capabilities", "actuator_states", "devices", "device_runtime", "device_credentials", "api_key_devices", "api_key_scopes")


def scoped_hba(install):
    """Thêm/bỏ đúng dòng SCRAM của probe, giữ nguyên reader và các rule khác.
    Input
    Param: install — True khi mở probe, False khi dọn probe.
    Side effects: ghi HBA không chứa credential và reload, không restart PostgreSQL.
    """
    script = r'''
use strict; use warnings;
my $path='/tmp/iot-postgres17-data/pg_hba.conf';
open my $input,'<',$path or die 'HBA unavailable'; local $/; my $content=<$input>; close $input;
my $rule="local iot_platform_lab iot_repository_probe scram-sha-256\n";
$content =~ s/^\Q$rule\E//mg;
my $install=shift @ARGV;
open my $output,'>',"$path.repository-tmp" or die 'HBA write failed';
print $output ($install eq 'yes'?$rule:'').$content; close $output;
chmod 0600,"$path.repository-tmp" or die 'HBA protection failed';
rename "$path.repository-tmp",$path or die 'HBA replace failed';
'''
    lab.docker("exec", lab.CONTAINER, "perl", "-e", script, "yes" if install else "no")
    if lab.sql("SELECT pg_reload_conf();", role=lab.ADMIN, database=DATABASE).stdout.strip() != "t":
        raise RuntimeError("Scoped authentication reload failed")


def provision_probe(password, run_id):
    """Tạo role tạm không DDL/owner, không thay runtime hoặc reader DBeaver.
    Input
    Param: password — chuỗi CSPRNG chỉ giữ trong bộ nhớ và chuyển qua stdin psql.
    Param: run_id — marker sở hữu role riêng cho lượt chạy để cleanup không chiếm role cũ.
    Errors: dừng khi role đã tồn tại; không chiếm một principal cũ.
    """
    if not re.fullmatch(r"[0-9a-f]{64}",password):
        raise ValueError("Invalid generated probe credential shape")
    valid_until=(datetime.now(timezone.utc)+timedelta(hours=1)).isoformat()
    statement = """BEGIN;
DO $$ BEGIN IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname IN ('iot_repository_probe','iot_audit_retention_probe')) THEN
 RAISE EXCEPTION 'Repository probe role already exists'; END IF; END $$;
CREATE ROLE iot_repository_probe LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 16;
COMMENT ON ROLE iot_repository_probe IS 'Temporary canonical repository verification:"""+str(run_id)+"""';
CREATE ROLE iot_audit_retention_probe NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
COMMENT ON ROLE iot_audit_retention_probe IS 'Temporary canonical repository verification:"""+str(run_id)+"""';
/* SET chỉ cho pool worker; app pool không inherit quyền DELETE/row lock của worker. */
GRANT iot_audit_retention_probe TO iot_repository_probe WITH INHERIT FALSE, SET TRUE;
GRANT USAGE ON SCHEMA public TO iot_audit_retention_probe;
GRANT SELECT,DELETE ON audit_events TO iot_audit_retention_probe;
/* FOR UPDATE cần UPDATE ít nhất một cột; immutable trigger cấm đổi ID thực, không cấp UPDATE payload/created-at. */
GRANT UPDATE(audit_event_id) ON audit_events TO iot_audit_retention_probe;
GRANT SELECT,INSERT ON audit_retention_runs,audit_retention_batches TO iot_audit_retention_probe;
SET LOCAL password_encryption='scram-sha-256';
ALTER ROLE iot_repository_probe PASSWORD '""" + password + """';
ALTER ROLE iot_repository_probe VALID UNTIL '"""+valid_until+"""';
GRANT CONNECT ON DATABASE iot_platform_lab TO iot_repository_probe;
GRANT USAGE ON SCHEMA public TO iot_repository_probe;
GRANT SELECT,INSERT,UPDATE ON users,sessions,login_attempt_buckets,workspaces,memberships,membership_grants,user_preferences TO iot_repository_probe;
GRANT SELECT,INSERT ON audit_events TO iot_repository_probe;
GRANT SELECT,INSERT,UPDATE ON push_installations,websocket_tickets TO iot_repository_probe;
GRANT SELECT,INSERT ON outbox_events,outbox_consumptions TO iot_repository_probe;
GRANT SELECT,INSERT,UPDATE,DELETE ON global_idempotency_records TO iot_repository_probe;
GRANT SELECT,INSERT,UPDATE ON workspace_invitations,membership_admission_fences TO iot_repository_probe;
GRANT SELECT,INSERT,UPDATE,DELETE ON workspace_idempotency_records TO iot_repository_probe;
GRANT SELECT,INSERT ON password_reset_admissions TO iot_repository_probe;
GRANT SELECT,INSERT,UPDATE ON rules,rule_versions,rule_version_actions,rule_executions,action_executions,action_jobs,workspace_runtime_quotas,commands,api_keys,push_deliveries,webhook_subscriptions,webhook_deliveries TO iot_repository_probe;
GRANT SELECT,INSERT,UPDATE ON templates,template_versions,datastream_definitions,datastream_capabilities,actuator_states,devices,api_key_devices,api_key_scopes TO iot_repository_probe;
GRANT SELECT,INSERT ON datastream_enum_values TO iot_repository_probe;
/* Registry probe chỉ ghi runtime UNKNOWN và đọc credential identity/count; không cấp provisioning writer. */
GRANT SELECT,INSERT ON device_runtime TO iot_repository_probe;
GRANT SELECT(workspace_id,device_id) ON device_credentials TO iot_repository_probe;
GRANT SELECT,INSERT,UPDATE,DELETE ON template_draft_streams,template_draft_enum_values,template_draft_capabilities TO iot_repository_probe;
/* Deferred trigger gọi helper bằng invoker; cấp đúng một hàm đọc invariant, không mở worker/owner. */
GRANT EXECUTE ON FUNCTION public.assert_workspace_capable_admin(uuid) TO iot_repository_probe;
GRANT EXECUTE ON FUNCTION public.consume_websocket_ticket(bytea) TO iot_repository_probe;
GRANT EXECUTE ON FUNCTION public.assert_stream_value(public.datastream_definitions,jsonb,boolean) TO iot_repository_probe;
COMMIT;"""
    # Không đưa stderr SQL chứa literal credential ra log khi provision gặp lỗi.
    result = lab.sql(statement, role=lab.ADMIN, database=DATABASE, check=False)
    if result.returncode:
        raise RuntimeError("Repository probe provisioning failed; no credential details logged")
    scoped_hba(True)


def owns_probe(run_id):
    """Kiểm marker metadata để chỉ dọn principal do lượt chạy này tạo, kể cả lỗi sau SQL commit.
    Input
    Param: run_id — UUID provenance không secret của lượt kiểm hiện hành.
    Output: True khi role thuộc đúng lượt chạy; không đọc password verifier.
    """
    marker="Temporary canonical repository verification:"+str(run_id)
    return lab.sql("SELECT coalesce(bool_and(shobj_description(oid,'pg_authid')='"+marker+"'),false) FROM pg_roles WHERE rolname='iot_repository_probe';",role=lab.ADMIN,database=DATABASE).stdout.strip()=="t"


@contextmanager
def probe_scope(password,run_id,user_ids,email_digests,journal=None):
    """Bao provision và mọi lỗi teardown trong cleanup sở hữu rõ ràng; không để role LOGIN sót lại khi HBA lỗi.
    Input
    Param: password — credential tạm, không log/serialize ra evidence.
    Param: run_id — marker sở hữu role/fixture của lượt chạy.
    Param: user_ids — UUID fixture do launcher sinh trước provision.
    Param: email_digests — bucket fixture cần dọn khi use case đã có thể commit.
    Param: journal — metadata cleanup của lượt chạy; chỉ xóa khi cả fixture và role đã dọn thành công.
    Side effects: luôn cố revoke role thuộc lượt chạy kể cả fixture cleanup thất bại.
    """
    try:
        provision_probe(password,run_id)
        yield
    finally:
        if owns_probe(run_id):
            try:
                cleanup_probe(run_id,user_ids,email_digests)
            finally:
                revoke_probe()
            if journal is not None:
                journal.unlink(missing_ok=True)


def cleanup_probe(run_id, user_ids, email_digests):
    """Xóa đúng fixture có marker và role tạm; giữ nguyên dữ liệu ngoài namespace của lượt chạy.
    Input
    Param: run_id — UUID đánh dấu provenance/correlation của fixture.
    Param: user_ids — UUID fixture do launcher cấp, không lấy từ dữ liệu ứng dụng.
    Param: email_digests — HMAC bucket của những email tổng hợp trong lượt chạy.
    Errors: dừng cleanup dữ liệu nếu một identity trùng dữ liệu không thuộc probe.
    """
    # Account do use case sinh UUID không có trong config; tra đúng ba email synthetic đã cấp trước.
    # Ownership guard phía dưới vẫn kiểm origin/audit trước bất kỳ DELETE nào.
    creation_emails = ",".join("'probe-"+str(run_id)+"-"+str(index)+"@example.invalid'" for index in range(8,11))
    dynamic = lab.sql("SELECT user_id FROM users WHERE email_normalized IN ("+creation_emails+");", database=DATABASE).stdout.splitlines()
    identities = ",".join("'"+str(identity)+"'::uuid" for identity in [*user_ids, *(UUID(value.strip()) for value in dynamic if value.strip())])
    digests = ",".join("decode('"+digest+"','hex')" for digest in email_digests)
    # UUID và digest đều do launcher sinh, không nội suy input người dùng vào SQL.
    statement = f"""BEGIN;
DO $$ BEGIN IF EXISTS(SELECT 1 FROM users account WHERE user_id IN ({identities}) AND
 (email_normalized NOT LIKE 'probe-{run_id}-%@example.invalid' OR NOT(
 activation_provenance='REPOSITORY_PROBE:{run_id}' OR
 (activation_provenance='SELF_PASSWORD_CHANGE' AND EXISTS(SELECT 1 FROM audit_events audit WHERE audit.actor_user_id=account.user_id AND audit.correlation_id='{run_id}'::uuid AND audit.event_type='PASSWORD_CHANGED')) OR
 (activation_provenance='ADMIN_TEMPORARY_V1' AND EXISTS(SELECT 1 FROM audit_events audit WHERE audit.resource_type='USER' AND audit.resource_id=account.user_id::text AND audit.correlation_id='{run_id}'::uuid AND audit.event_type='TEMPORARY_ACCOUNT_CREATED')))))
 THEN RAISE EXCEPTION 'Fixture ownership mismatch'; END IF; END $$;
DELETE FROM audit_events WHERE correlation_id='{run_id}'::uuid;
DELETE FROM audit_retention_batches WHERE run_id IN ('{run_id}'::uuid,{identities});
DELETE FROM audit_retention_runs WHERE run_id IN ('{run_id}'::uuid,{identities});
DELETE FROM password_reset_admissions WHERE target_user_id IN ({identities});
DELETE FROM global_idempotency_records WHERE user_id IN ({identities});
DELETE FROM workspace_idempotency_records WHERE user_id IN ({identities});
DELETE FROM workspace_invitations WHERE workspace_id IN(SELECT workspace_id FROM workspaces WHERE created_by_user_id IN ({identities}));
DELETE FROM membership_admission_fences WHERE workspace_id IN(SELECT workspace_id FROM workspaces WHERE created_by_user_id IN ({identities}));
DELETE FROM outbox_consumptions WHERE outbox_event_id IN(SELECT outbox_event_id FROM outbox_events WHERE (event_type='SESSION_REVOKED' AND payload->>'userId' IN(SELECT user_id::text FROM users WHERE user_id IN ({identities}))) OR workspace_id IN(SELECT workspace_id FROM workspaces WHERE created_by_user_id IN ({identities})));
DELETE FROM outbox_events WHERE (event_type='SESSION_REVOKED' AND payload->>'userId' IN(SELECT user_id::text FROM users WHERE user_id IN ({identities}))) OR workspace_id IN(SELECT workspace_id FROM workspaces WHERE created_by_user_id IN ({identities}));
DELETE FROM websocket_tickets WHERE user_id IN ({identities});
DELETE FROM push_installations WHERE installation_id='{run_id}'::uuid AND app_version='REPOSITORY_PROBE:{run_id}';
DELETE FROM sessions WHERE user_id IN ({identities});
DELETE FROM commands WHERE workspace_id IN(SELECT workspace_id FROM workspaces WHERE created_by_user_id IN ({identities}));
DELETE FROM action_jobs WHERE workspace_id IN(SELECT workspace_id FROM workspaces WHERE created_by_user_id IN ({identities}));
DELETE FROM action_executions WHERE workspace_id IN(SELECT workspace_id FROM workspaces WHERE created_by_user_id IN ({identities}));
DELETE FROM rule_executions WHERE workspace_id IN(SELECT workspace_id FROM workspaces WHERE created_by_user_id IN ({identities}));
DELETE FROM rule_version_actions WHERE workspace_id IN(SELECT workspace_id FROM workspaces WHERE created_by_user_id IN ({identities}));
DELETE FROM rule_versions WHERE workspace_id IN(SELECT workspace_id FROM workspaces WHERE created_by_user_id IN ({identities}));
DELETE FROM rules WHERE workspace_id IN(SELECT workspace_id FROM workspaces WHERE created_by_user_id IN ({identities}));
DELETE FROM workspace_runtime_quotas WHERE workspace_id IN(SELECT workspace_id FROM workspaces WHERE created_by_user_id IN ({identities}));
DELETE FROM api_key_scopes WHERE workspace_id IN(SELECT workspace_id FROM workspaces WHERE created_by_user_id IN ({identities}));
DELETE FROM api_key_devices WHERE workspace_id IN(SELECT workspace_id FROM workspaces WHERE created_by_user_id IN ({identities}));
DELETE FROM api_keys WHERE workspace_id IN(SELECT workspace_id FROM workspaces WHERE created_by_user_id IN ({identities}));
DELETE FROM actuator_states WHERE workspace_id IN(SELECT workspace_id FROM workspaces WHERE created_by_user_id IN ({identities}));
DELETE FROM device_runtime WHERE workspace_id IN(SELECT workspace_id FROM workspaces WHERE created_by_user_id IN ({identities}));
DELETE FROM devices WHERE workspace_id IN(SELECT workspace_id FROM workspaces WHERE created_by_user_id IN ({identities}));
DELETE FROM datastream_capabilities WHERE workspace_id IN(SELECT workspace_id FROM workspaces WHERE created_by_user_id IN ({identities}));
DELETE FROM datastream_enum_values WHERE workspace_id IN(SELECT workspace_id FROM workspaces WHERE created_by_user_id IN ({identities}));
DELETE FROM datastream_definitions WHERE workspace_id IN(SELECT workspace_id FROM workspaces WHERE created_by_user_id IN ({identities}));
DELETE FROM template_versions WHERE workspace_id IN(SELECT workspace_id FROM workspaces WHERE created_by_user_id IN ({identities}));
DELETE FROM template_draft_capabilities WHERE workspace_id IN(SELECT workspace_id FROM workspaces WHERE created_by_user_id IN ({identities}));
DELETE FROM template_draft_enum_values WHERE workspace_id IN(SELECT workspace_id FROM workspaces WHERE created_by_user_id IN ({identities}));
DELETE FROM template_draft_streams WHERE workspace_id IN(SELECT workspace_id FROM workspaces WHERE created_by_user_id IN ({identities}));
DELETE FROM templates WHERE workspace_id IN(SELECT workspace_id FROM workspaces WHERE created_by_user_id IN ({identities}));
DELETE FROM membership_grants WHERE user_id IN ({identities});
DELETE FROM memberships WHERE user_id IN ({identities});
DELETE FROM workspaces WHERE created_by_user_id IN ({identities});
DELETE FROM user_preferences WHERE user_id IN ({identities});
DELETE FROM users WHERE user_id IN ({identities});
DELETE FROM login_attempt_buckets WHERE email_digest IN ({digests});
SET CONSTRAINTS ALL IMMEDIATE;
COMMIT;"""
    # Membership trigger kiểm current-grant ngay cả DELETE; xóa graph dùng deferred constraints.
    result = lab.sql(statement, database=DATABASE, check=False)
    if result.returncode:
        raise RuntimeError("Repository fixture cleanup failed; retained for ownership review")


def revoke_probe():
    """Đóng quyền đăng nhập, terminate đúng session probe rồi gỡ grants/role và dòng HBA riêng.
    Side effects: không terminate DBeaver hoặc role khác; không DROP dữ liệu/schema/database.
    """
    names = ",".join(TABLES+MEMBER_TABLES+MEMBER_KEY_TABLES)
    lab.sql(f"""ALTER ROLE iot_repository_probe NOLOGIN;
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename='iot_repository_probe' AND pid<>pg_backend_pid();
DO $$ BEGIN IF EXISTS(SELECT 1 FROM pg_roles worker WHERE worker.rolname='iot_audit_retention_probe'
 AND shobj_description(worker.oid,'pg_authid') IS DISTINCT FROM
 (SELECT shobj_description(oid,'pg_authid') FROM pg_roles WHERE rolname='iot_repository_probe')) THEN
 RAISE EXCEPTION 'Retention probe ownership mismatch'; END IF; END $$;
REVOKE ALL ON {names},audit_events FROM iot_repository_probe;
REVOKE ALL ON SCHEMA public FROM iot_repository_probe;
REVOKE ALL ON FUNCTION public.assert_workspace_capable_admin(uuid) FROM iot_repository_probe;
REVOKE ALL ON FUNCTION public.consume_websocket_ticket(bytea) FROM iot_repository_probe;
REVOKE ALL ON FUNCTION public.claim_outbox(text,integer,integer) FROM iot_repository_probe;
REVOKE ALL ON FUNCTION public.complete_outbox(uuid,text,bigint) FROM iot_repository_probe;
REVOKE ALL ON FUNCTION public.assert_stream_value(public.datastream_definitions,jsonb,boolean) FROM iot_repository_probe;
REVOKE ALL ON DATABASE iot_platform_lab FROM iot_repository_probe;
REVOKE iot_audit_retention_probe FROM iot_repository_probe;
REVOKE ALL ON audit_events,audit_retention_runs,audit_retention_batches FROM iot_audit_retention_probe;
REVOKE UPDATE(audit_event_id) ON audit_events FROM iot_audit_retention_probe;
REVOKE ALL ON SCHEMA public FROM iot_audit_retention_probe;
DROP ROLE iot_audit_retention_probe;
DROP ROLE iot_repository_probe;""", role=lab.ADMIN, database=DATABASE)
    scoped_hba(False)


def run_probe_binary(binary, config):
    """Chạy đúng binary đã build bằng stdin kín; chỉ trả tên checks không chứa dữ liệu fixture.
    Input
    Param: binary — đường dẫn xác định do Cargo vừa tạo, không dò/list build folder.
    Param: config — credential tạm và marker chỉ trong bộ nhớ, không kế thừa env máy.
    Output: danh sách tên invariant đã đạt; Errors: lỗi generic và tên checks đã hoàn thành.
    """
    result = subprocess.run([str(binary)], input=json.dumps(config), capture_output=True,
                            text=True, encoding="utf-8", timeout=180, env={"SystemRoot":r"C:\Windows"})
    if result.returncode:
        raise RuntimeError("PostgreSQL repository integration failed: " + result.stdout.strip())
    return json.loads(result.stdout)


def main():
    """Build rồi chạy integration binary bằng stdin kín; chỉ ghi metadata và tên check PASS.
    Output: evidence JSON không chứa credential/fixture secret; Errors: exit khác0 nếu build/test/cleanup lỗi.
    """
    build = subprocess.run(["cargo", "build", "--locked", "--features", "repository-probe", "--bin", "repository-probe"],
                           cwd=ROOT/"backend", capture_output=True, text=True, encoding="utf-8", timeout=300)
    if build.returncode:
        raise RuntimeError("Repository binary build failed: " + build.stderr)
    lab.inspect_lab()
    # Purge probe toàn cục chỉ chạy khi DB không có dữ liệu ứng dụng; không xóa history người dùng để test.
    platform.sql("BEGIN;\n"+platform.EMPTY_GUARD+"\nROLLBACK;")
    # Chặn chạy nhầm schema chưa có đủ baseline; chỉ đọc ledger metadata, không row ứng dụng.
    count = lab.sql("SELECT count(*) FROM migration_control.applied_migrations WHERE version LIKE 'platform-%';", database=DATABASE).stdout.strip()
    if count != str(len(platform.SOURCE_NAMES)):
        raise RuntimeError("Canonical baseline mismatch")
    run_id = uuid4()
    user_ids = [uuid4() for _ in range(7)]
    emails = [f"probe-{run_id}-{index}@example.invalid" for index in range(14)]
    password = secrets.token_hex(32)
    limiter_key = secrets.token_bytes(32)
    email_digests = [hmac.new(limiter_key, email.encode(), hashlib.sha256).hexdigest() for email in emails]
    server = None
    # Journal chỉ chứa khóa cleanup tổng hợp, không password/token/verifier/key HMAC; giúp dọn sau process crash.
    journal=ROOT/"ops/database/evidence"/f"repository-probe-{run_id}.json"
    journal.write_text(json.dumps({"runId":str(run_id),"userIds":list(map(str,user_ids)),"emailDigests":email_digests}),encoding="utf-8")
    with probe_scope(password,run_id,user_ids,email_digests,journal=journal):
        try:
            server = bridge.InspectionServer((bridge.HOST, 0), bridge.InspectionHandler)
            server.allowed_user = ROLE
            server.read_only = False
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            config = {"port":server.server_address[1], "username":ROLE, "password":password,
                      "limiterKey":list(limiter_key), "runId":str(run_id), "userIds":list(map(str,user_ids)), "emails":emails}
            binary = ROOT/"backend/target/x86_64-pc-windows-gnu/debug/repository-probe.exe"
            # Không đọc/list thư mục build: chỉ thực thi binary xác định do Cargo vừa tạo.
            # Windows cần SystemRoot tường minh; không kế thừa/đọc env máy và không chuyển bất kỳ biến PG nào.
            checks = run_probe_binary(binary, config)
            checks.extend(run_probe_binary(binary, {**config, "phase":"memberCreation"}))
            checks.extend(run_probe_binary(binary, {**config, "phase":"preferences"}))
            checks.extend(run_probe_binary(binary, {**config, "phase":"invitationManagement"}))
            checks.extend(run_probe_binary(binary, {**config, "phase":"template"}))
            checks.extend(run_probe_binary(binary, {**config, "phase":"device"}))
            # Quyền lease chỉ sống trong phase probe; không mở production runtime hoặc reader DBeaver.
            lab.sql("GRANT UPDATE ON outbox_consumptions TO iot_repository_probe; GRANT EXECUTE ON FUNCTION public.claim_outbox(text,integer,integer),public.complete_outbox(uuid,text,bigint) TO iot_repository_probe;", role=lab.ADMIN, database=DATABASE)
            try:
                checks.extend(run_probe_binary(binary, {**config, "phase":"outbox"}))
            finally:
                lab.sql("REVOKE UPDATE ON outbox_consumptions FROM iot_repository_probe; REVOKE ALL ON FUNCTION public.claim_outbox(text,integer,integer),public.complete_outbox(uuid,text,bigint) FROM iot_repository_probe;", role=lab.ADMIN, database=DATABASE)
            # Chỉ principal của lượt này được fault injection; không đụng runtime hoặc DBeaver reader.
            if not owns_probe(run_id):
                raise RuntimeError("Audit fault injection requires owned probe role")
            # Marker cho target reset fault chưa tạo; UUID/email ở config và correlation cùng run bảo vệ cleanup.
            # Đây là metadata fixture, không giả làm use case tạo account đã được nghiệm thu.
            lab.sql(f"""INSERT INTO audit_events(audit_event_id,actor_user_id,event_type,outcome,resource_type,resource_id,correlation_id,client_type)
VALUES('{uuid4()}'::uuid,'{user_ids[1]}'::uuid,'TEMPORARY_ACCOUNT_CREATED','SUCCESS','USER','{user_ids[4]}','{run_id}'::uuid,'UNKNOWN');""", role=lab.ADMIN, database=DATABASE)
            lab.sql("REVOKE INSERT ON audit_events FROM iot_repository_probe;", role=lab.ADMIN, database=DATABASE)
            try:
                checks.extend(run_probe_binary(binary, {**config, "phase":"auditFailure"}))
            finally:
                lab.sql("GRANT INSERT ON audit_events TO iot_repository_probe;", role=lab.ADMIN, database=DATABASE)
            checks.extend(run_probe_binary(binary, {**config, "phase":"retention"}))
            # Lỗi metadata writer phải rollback audit DELETE; quyền chỉ đổi trên worker NOLOGIN do run sở hữu.
            lab.sql("REVOKE INSERT ON audit_retention_batches FROM iot_audit_retention_probe;", role=lab.ADMIN, database=DATABASE)
            try:
                checks.extend(run_probe_binary(binary, {**config, "phase":"retentionFailure"}))
            finally:
                lab.sql("GRANT INSERT ON audit_retention_batches TO iot_audit_retention_probe;", role=lab.ADMIN, database=DATABASE)
        finally:
            if server:
                try:
                    server.shutdown()
                finally:
                    server.server_close()
    report = {"recordedAt":datetime.now(timezone.utc).isoformat(), "database":DATABASE,
              "engine":"PostgreSQL17.11", "driver":"sqlx0.8.6", "transport":"ephemeral loopback SCRAM gateway",
              "checks":checks, "temporaryRoleRemoved":True, "fixtureCleanup":"PASS", "createsDatabase":False}
    path = ROOT/"ops/database/evidence/repositories-latest.json"
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
