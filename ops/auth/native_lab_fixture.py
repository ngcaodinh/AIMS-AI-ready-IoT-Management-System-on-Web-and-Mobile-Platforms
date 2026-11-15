"""Adapter test riêng: credential chỉ stdin RAM, launcher vẫn sở hữu grants, process và finally cleanup."""

import contextlib
import hashlib
import hmac
import io
import json
import re
import sys
import threading
import time
from uuid import UUID

import run_local as launcher
from native_membership_operation import NativeMembershipOperation


# Cùng một SELECT cho positive diagnostic và cleanup: UUID/digest chỉ qua quoted psql bindings,
# bytea giải mã hex đúng schema; không đọc key/token, không mở selector hoặc mutation từ journal.
CLEANUP_READBACK_SQL = """WITH owned AS (
SELECT unnest(string_to_array(:'auth_fault_correlations', ',')::uuid[]) AS user_id),
owned_buckets AS (
SELECT decode(digest, 'hex') AS email_digest
FROM unnest(string_to_array(:'auth_lab_bucket_digests', ',')) AS digest)
SELECT json_build_object(
'role',(SELECT count(*) FROM pg_roles WHERE rolname='iot_repository_probe'),
'hba',(SELECT count(*) FROM pg_hba_file_rules WHERE user_name @> ARRAY['iot_repository_probe']),
'users',(SELECT count(*) FROM users WHERE user_id IN (SELECT user_id FROM owned)),
'sessions',(SELECT count(*) FROM sessions WHERE user_id IN (SELECT user_id FROM owned)),
'workspaces',(SELECT count(*) FROM workspaces WHERE created_by_user_id IN (SELECT user_id FROM owned)),
'memberships',(SELECT count(*) FROM memberships WHERE user_id IN (SELECT user_id FROM owned)),
'auditActor',(SELECT count(*) FROM audit_events WHERE actor_user_id IN (SELECT user_id FROM owned)),
'limiterBuckets',(SELECT count(*) FROM login_attempt_buckets
WHERE email_digest IN (SELECT email_digest FROM owned_buckets)));"""


def build_cleanup_scope(config):
    """Chốt selectors synthetic bất biến từ config live trước spawn, không dùng journal làm quyền cleanup.

    Input
    Param: config — object RAM do launcher tạo sau provision; key không được xuất khỏi process.
    Output: tuple năm UUID và sáu HMAC hex theo đúng namespace/thuật toán launcher.
    Errors: ValueError cố định nếu identity/email/key sai shape, không phản chiếu giá trị gốc.
    """
    try:
        run_id = config['runId']
        user_ids = config['userIds']
        key = config['signingKey']
        if (not isinstance(run_id, str) or str(UUID(run_id)) != run_id
                or not isinstance(user_ids, list) or len(user_ids) != 5
                or any(not isinstance(value, str) or str(UUID(value)) != value for value in user_ids)
                or len(set(user_ids)) != 5
                or config['emails'] != [f'probe-{run_id}-{index}@example.invalid' for index in range(5)]
                or not isinstance(key, list) or len(key) != 32
                or any(type(value) is not int or not 0 <= value <= 255 for value in key)):
            raise ValueError()
        # Bao gồm email không tồn tại để không bỏ bucket của nhánh AUTH_INVALID synthetic.
        emails = [*config['emails'], f'probe-{run_id}-unknown@example.invalid']
        digests = tuple(hmac.new(bytes(key), email.encode('utf-8'), hashlib.sha256).hexdigest() for email in emails)
        if len(set(digests)) != 6:
            raise ValueError()
        return tuple(user_ids), digests
    except (ValueError, TypeError, KeyError, AttributeError):
        raise ValueError('INVALID_NATIVE_LAB_CLEANUP_SCOPE') from None


def parse_packet(raw):
    """Kiểm packet private trước mọi DB I/O; chỉ cho mật khẩu synthetic CSPRNG đã thống nhất.

    Input
    Param: raw — JSON bytes tối đa4KiB từ pipe của owned runner, không argv/env/file.
    Output: password trong RAM; không trả hoặc log packet qua stdout.
    Errors: ValueError cho encoding/schema/password sai, không kèm dữ liệu gốc.
    """
    try:
        if len(raw) > 4096:
            raise ValueError()
        packet = json.loads(raw)
        if not isinstance(packet, dict) or set(packet) not in ({'version', 'password'}, {'version', 'password', 'scenario'}) or ('scenario' in packet and packet['scenario'] not in ('password', 'rate-limit', 'membership-stale', 'offline-login')) or type(packet['version']) is not int or packet['version'] != 1 or not isinstance(packet['password'], str) or not re.fullmatch(r'Aa1[0-9a-f]{32}', packet['password']):
            raise ValueError()
        return packet['password']
    except (ValueError, TypeError, UnicodeError):
        raise ValueError('INVALID_NATIVE_LAB_PACKET') from None


class NativeFixtureControl:
    """Giữ STOP xuyên startup và chỉ xuất metadata cần cho oracle của đúng child đã sở hữu."""

    def __init__(self, emit, start_backend, scenario='default'):
        """Nhận output và spawn capability từ adapter, không tự tìm hoặc chiếm process khác.

        Input
        Param: emit — callback đồng bộ chỉ nhận public metadata/fixed enum.
        Param: start_backend — hàm launcher gốc có guard và startup cleanup.
        Param: scenario — default20/password35/rate-limit40 hoặc membership-stale20phút; membership neo trước spawn, rate sau ARM.
        """
        if scenario not in ('default', 'password', 'rate-limit', 'membership-stale', 'offline-login'):
            raise ValueError('INVALID_NATIVE_LAB_SCENARIO')
        self.scenario = scenario
        self.work_seconds = {'default': 1200, 'password': 2100, 'rate-limit': 2400, 'membership-stale': 1200, 'offline-login': 1200}[scenario]
        # Rate startup15phút gồm READY transport/chờ ARM; event chỉ đánh thức, không mở lại deadline khi thread trễ.
        self.startup_deadline = time.monotonic() + 900 if scenario == 'rate-limit' else None
        # Membership neo20phút trước launcher build/spawn, không cộng lại sau READY.
        self.work_deadline = time.monotonic() + 1200 if scenario in ('membership-stale', 'offline-login') else None
        self.state_changed = threading.Event()
        self.emit = emit
        self.start_backend = start_backend
        self.lock = threading.Lock()
        self.stopping = threading.Event()
        self.ready = threading.Event()
        self.process = None
        self.config = None
        self._cleanup_scope = None
        self._membership_scope = None
        self._membership_target = None
        self._membership_target_attempted = False
        self._membership_suspend_attempted = False
        self._membership_operation = None

    def start_lab(self, config, pool_budget=False):
        """Bàn giao child cho run gốc ngay cả STOP đến sớm, để finally luôn biết handle cần dừng.

        Input
        Param: config — config launcher sinh trong RAM, gồm secrets không được đưa ra output.
        Param: pool_budget — giữ signature launcher; adapter chỉ gọi normal run, không bật fault mode.
        Output: owned backend handle; pendingSTOP không được raise trước khi caller ghi nhận handle.
        Errors: config malformed bị từ chối trước spawn; projection chỉ chốt sau capability trả child.
        """
        cleanup_scope = build_cleanup_scope(config)
        child = self.start_backend(config, pool_budget)
        with self.lock:
            self.process = child
            self.config = config
            # Provenance là callback launcher live + owned child, không phải shape của file/journal.
            self._cleanup_scope = cleanup_scope
            self._membership_scope = (config['runId'], cleanup_scope[0][0], cleanup_scope[0][4])
            pending_stop = self.stopping.is_set()
            if not pending_stop:
                try:
                    self.emit({'kind': 'READY', 'runId': config['runId'], 'userIds': config['userIds'], 'emails': config['emails']})
                    self.ready.set()
                except BaseException:
                    # Child đã spawn nhưng run chưa append handle; lỗi output phải STOP và vẫn return child.
                    self.stopping.set()
                    pending_stop = True
        if pending_stop:
            self.stop()
        return child

    def stop(self):
        """Giữ intent STOP trước READY và dừng đúng owned child, không coi timeout là terminal.

        Side effects: lỗi backend stop phát fixed marker; operation drain chưa xác nhận phải raise để chặn graph cleanup.
        """
        if self.scenario == 'rate-limit':
            # ARM/STOP/watchdog tranh cùng lock: STOP thắng thì không còn ARM ACK, wake cả waiter trước ARM.
            with self.lock:
                self.stopping.set()
                self.state_changed.set()
        else:
            self.stopping.set()
        with self.lock:
            if self.process is not None:
                try:
                    launcher.stop_lab(self.process)
                except (OSError, launcher.subprocess.SubprocessError):
                    try:
                        self.emit({'kind': 'STOP_UNCONFIRMED'})
                    except BaseException:
                        # Marker best-effort không được cướp handle khỏi finally; parent đã mất pipe nên không thể ACK.
                        pass

            # Không nuốt lỗi drain, launcher finally phải giữ graph/journal nếu backend operation còn sống.
            if self._membership_operation is not None:
                self._membership_operation.stop()

    def snapshot(self, scope='full'):
        """Đọc metadata phiên của account fixture cố định để kiểm native admission/logout, không mở selector tùy ý.

        Input
        Param: scope — full0/disabled1/limited2/empty3; UUID chỉ lấy config owned sau READY.
        Output: tối đa16 UUID/revoked boolean, không bearer/token verifier hoặc profile người dùng thật.
        Errors: ValueError cho scope khác allowlist trước SQL; chưa ready/đang STOP hoặc DB/schema lỗi phải FAIL.
        """
        account_indexes = {'full': 0, 'disabled': 1, 'limited': 2, 'empty': 3}
        if not isinstance(scope, str) or scope not in account_indexes:
            raise ValueError('INVALID_NATIVE_LAB_SCOPE')
        with self.lock:
            if (not self.ready.is_set() or self.stopping.is_set() or self.process.poll() is not None
                    or (self.scenario in ('rate-limit', 'membership-stale', 'offline-login') and
                        (self.work_deadline is None or time.monotonic() >= self.work_deadline))):
                raise RuntimeError('NATIVE_LAB_SNAPSHOT_UNAVAILABLE')
            user_id = str(UUID(self.config['userIds'][account_indexes[scope]]))
            # UUID qua psql quoted variable đã whitelist; chỉ projection public, không SELECT token_digest.
            statement = """SELECT coalesce(json_agg(row), '[]'::json) FROM (
SELECT session_id AS "sessionId", (revoked_at IS NOT NULL) AS revoked
FROM sessions WHERE user_id=:'auth_fault_user_id'::uuid AND client_type='ANDROID'
ORDER BY session_id LIMIT 17) row;"""
            rows = json.loads(launcher.lab.sql(statement, database=launcher.DATABASE, variables=(('auth_fault_user_id', user_id),)).stdout.strip())
            if not isinstance(rows, list) or len(rows) > 16:
                raise RuntimeError('NATIVE_LAB_SNAPSHOT_INVALID')
            for row in rows:
                if not isinstance(row, dict) or set(row) != {'sessionId', 'revoked'} or type(row['revoked']) is not bool or not isinstance(row['sessionId'], str):
                    raise RuntimeError('NATIVE_LAB_SNAPSHOT_INVALID')
                row['sessionId'] = str(UUID(row['sessionId']))
            return rows

    def _require_membership_available(self):
        """Chặn projection khi lifecycle không còn authority, caller phải đang giữ control lock.

        Errors: fixed failure trước SQL hoặc sau operation nếu STOP/child terminal/rate hết work.
        """
        if (not self.ready.is_set() or self.stopping.is_set() or self.process is None
                or self.process.poll() is not None or self._membership_scope is None
                or (self.scenario in ('rate-limit', 'membership-stale', 'offline-login') and
                    (self.work_deadline is None or time.monotonic() >= self.work_deadline))):
            raise RuntimeError('NATIVE_LAB_MEMBERSHIP_UNAVAILABLE')

    def membership_target(self):
        """Resolve B một lần từ live launcher ownership, trả copy metadata cho matcher của harness.

        Output: workspaceId/revision/authorizationVersion/grantGeneration của USER ACTIVE trong B owned.
        Errors: admission/SQL/schema lỗi trả fixed failure và không retry query sau attempt chưa xác nhận.
        Side effects: SELECT read-only có server bounds, không suspend hoặc cấp quyền membership.
        """
        with self.lock:
            self._require_membership_available()
            if self._membership_target is not None:
                return dict(self._membership_target)
            if self._membership_target_attempted:
                raise RuntimeError('NATIVE_LAB_MEMBERSHIP_UNAVAILABLE')
            self._membership_target_attempted = True
            # Tuple immutable chốt từ callback live trước READY, journal/channel không cấp selector.
            scope = ','.join(self._membership_scope)
            # SELECT cần direct SQL để chốt target trước proxy matcher. UUID bind qua quoted psql array;
            # cùng snapshot kiểm role marker/user provenance/creator/grant để không resolve workspace ngoài run.
            statement = """BEGIN READ ONLY;
SET LOCAL statement_timeout='20s';
SET LOCAL lock_timeout='5s';
SET LOCAL idle_in_transaction_session_timeout='25s';
WITH scope AS (SELECT string_to_array(:'auth_fault_correlations', ',')::uuid[] AS ids),
owned AS (
SELECT w.workspace_id AS "workspaceId", member.revision,
member.authorization_version AS "authorizationVersion",
member.current_grant_generation AS "grantGeneration"
FROM scope
JOIN users actor ON actor.user_id=scope.ids[2]
JOIN users owner ON owner.user_id=scope.ids[3]
JOIN workspaces w ON w.created_by_user_id=owner.user_id
JOIN memberships member ON member.workspace_id=w.workspace_id AND member.user_id=actor.user_id
JOIN memberships creator ON creator.workspace_id=w.workspace_id AND creator.user_id=owner.user_id
JOIN membership_grants grant_row ON grant_row.workspace_id=member.workspace_id
AND grant_row.user_id=member.user_id AND grant_row.grant_generation=member.current_grant_generation
JOIN membership_grants creator_grant ON creator_grant.workspace_id=creator.workspace_id
AND creator_grant.user_id=creator.user_id AND creator_grant.grant_generation=creator.current_grant_generation
WHERE EXISTS(SELECT 1 FROM pg_roles WHERE rolname='iot_repository_probe'
AND shobj_description(oid,'pg_authid')='Temporary canonical repository verification:'||scope.ids[1]::text)
AND actor.account_status='ACTIVE' AND owner.account_status='ACTIVE'
AND actor.activation_provenance='AUTH_HTTP_LAB:'||scope.ids[1]::text
AND owner.activation_provenance='AUTH_HTTP_LAB:'||scope.ids[1]::text
AND actor.email_normalized='probe-'||scope.ids[1]::text||'-0@example.invalid'
AND owner.email_normalized='probe-'||scope.ids[1]::text||'-4@example.invalid'
AND w.description='AUTH_HTTP_LAB:'||scope.ids[1]::text AND w.status='ACTIVE'
AND creator.role='ADMIN' AND creator.status='ACTIVE' AND creator.removed_at IS NULL
AND creator_grant.revoked_at IS NULL
AND member.role='USER' AND member.status='ACTIVE' AND member.removed_at IS NULL
AND grant_row.revoked_at IS NULL
ORDER BY w.workspace_id LIMIT 2)
SELECT coalesce(json_agg(owned), '[]'::json) FROM owned;
COMMIT;"""
            try:
                result = launcher.lab.sql(statement, database=launcher.DATABASE, check=False,
                                          variables=(('auth_fault_correlations', scope),))
                if (type(result.returncode) is not int or result.returncode != 0
                        or not isinstance(result.stdout, str) or len(result.stdout) > 4096):
                    raise ValueError()
                rows = json.loads(result.stdout.strip())
                if not isinstance(rows, list) or len(rows) != 1:
                    raise ValueError()
                target = rows[0]
                if (not isinstance(target, dict)
                        or set(target) != {'workspaceId', 'revision', 'authorizationVersion', 'grantGeneration'}
                        or not isinstance(target['workspaceId'], str)
                        or str(UUID(target['workspaceId'])) != target['workspaceId']):
                    raise ValueError()
                for key in ('revision', 'authorizationVersion', 'grantGeneration'):
                    if type(target[key]) is not int or not 0 < target[key] < 2**63:
                        raise ValueError()
                # SQL trở về chưa đủ cấp authority nếu STOP/expiry/child terminal xảy ra trong operation.
                self._require_membership_available()
                self._membership_target = dict(target)
                return dict(target)
            except (ValueError, TypeError, KeyError, AttributeError, RuntimeError, OSError,
                    launcher.subprocess.SubprocessError):
                raise RuntimeError('NATIVE_LAB_MEMBERSHIP_UNAVAILABLE') from None



    def membership_session_evidence(self):
        """Đọc sessions/audit cùng một snapshot SQL của account0 owned để host bind UUID và audit logout.

        Output: sessions tối đa16 và audit tối đa32 metadata rows. Offline bổ sung đúng A/Admin và B/User
        từ owner0/owner4 live, không token/profile/redacted payload hoặc mutation membership.
        Errors: fixed failure khi profile/ownership/lifecycle/query/schema sai, chưa chứng minh business success.
        """
        with self.lock:
            try:
                offline = self.scenario == 'offline-login'
                if not offline and (self.scenario != 'membership-stale' or self._membership_target is None):
                    raise RuntimeError()
                self._require_membership_available()
                scope = ','.join(self._membership_scope if offline else self._membership_scope[:2])
                # Một SELECT read-only giữ sessions và audit cùng MVCC snapshot; quoted UUID array
                # chỉ từ live immutable scope. Không SELECT token, email hoặc redacted_diff trong projection.
                statement = """BEGIN READ ONLY;
SET LOCAL statement_timeout='20s';
SET LOCAL lock_timeout='5s';
SET LOCAL idle_in_transaction_session_timeout='25s';
WITH scope AS (SELECT string_to_array(:'auth_fault_correlations', ',')::uuid[] AS ids),
owned AS (SELECT actor.user_id FROM users actor,scope
WHERE actor.user_id=scope.ids[2] AND actor.account_status='ACTIVE'
AND actor.email_normalized='probe-'||scope.ids[1]::text||'-0@example.invalid'
AND actor.activation_provenance='AUTH_HTTP_LAB:'||scope.ids[1]::text
AND EXISTS(SELECT 1 FROM pg_roles WHERE rolname='iot_repository_probe'
AND shobj_description(oid,'pg_authid')='Temporary canonical repository verification:'||scope.ids[1]::text)),
session_rows AS (
SELECT s.session_id AS "sessionId",(s.revoked_at IS NOT NULL) AS revoked
FROM sessions s JOIN owned ON owned.user_id=s.user_id
WHERE s.client_type='ANDROID' ORDER BY s.session_id LIMIT 17),
audit_rows AS (
SELECT a.session_id AS "sessionId",a.event_type AS "eventType",a.outcome,a.client_type AS "clientType"
FROM audit_events a JOIN sessions s ON a.session_id=s.session_id AND a.actor_user_id=s.user_id
JOIN owned ON owned.user_id=s.user_id
WHERE a.client_type='ANDROID' AND s.client_type='ANDROID'
AND a.event_type IN ('LOGIN_SUCCEEDED','LOGOUT') ORDER BY a.audit_event_id LIMIT 33)
SELECT json_build_object(
'sessions',coalesce((SELECT json_agg(session_rows) FROM session_rows),'[]'::json),
'audit',coalesce((SELECT json_agg(audit_rows) FROM audit_rows),'[]'::json)) FROM owned;
COMMIT;"""
                if offline:
                    # Cùng MVCC SELECT ghép A/B từ live ownership để host pin route detail mà không tốn query thứ hai.
                    # Các fragment là literal nội bộ, UUID vẫn qua quoted binding, không nhận SQL/selector từ pipe.
                    statement = statement.replace("audit_rows AS (", """workspace_rows AS (
SELECT w.workspace_id AS "workspaceId",w.name,member.role
FROM owned JOIN memberships member ON member.user_id=owned.user_id
JOIN workspaces w ON w.workspace_id=member.workspace_id
JOIN membership_grants grant_row ON grant_row.workspace_id=member.workspace_id
AND grant_row.user_id=member.user_id AND grant_row.grant_generation=member.current_grant_generation
CROSS JOIN scope JOIN users creator ON creator.user_id=w.created_by_user_id
JOIN memberships creator_membership ON creator_membership.workspace_id=w.workspace_id
AND creator_membership.user_id=creator.user_id
JOIN membership_grants creator_grant ON creator_grant.workspace_id=creator_membership.workspace_id
AND creator_grant.user_id=creator_membership.user_id
AND creator_grant.grant_generation=creator_membership.current_grant_generation
WHERE w.status='ACTIVE' AND w.description='AUTH_HTTP_LAB:'||scope.ids[1]::text
AND member.status='ACTIVE' AND member.removed_at IS NULL AND grant_row.revoked_at IS NULL
AND creator_membership.status='ACTIVE' AND creator_membership.role='ADMIN'
AND creator_membership.removed_at IS NULL AND creator_grant.revoked_at IS NULL
AND ((w.created_by_user_id=scope.ids[2] AND member.role='ADMIN' AND w.name='Phòng vận hành A')
OR (w.created_by_user_id=scope.ids[3] AND member.role='USER' AND w.name='Nhà kính B'))
AND creator.account_status='ACTIVE' AND creator.activation_provenance='AUTH_HTTP_LAB:'||scope.ids[1]::text
AND creator.email_normalized='probe-'||scope.ids[1]::text||
CASE WHEN w.created_by_user_id=scope.ids[2] THEN '-0@example.invalid' ELSE '-4@example.invalid' END
ORDER BY w.workspace_id LIMIT 3),
audit_rows AS (""")
                    statement = statement.replace("'audit',coalesce((SELECT json_agg(audit_rows) FROM audit_rows),'[]'::json))",
                        "'audit',coalesce((SELECT json_agg(audit_rows) FROM audit_rows),'[]'::json),"
                        "'workspaces',coalesce((SELECT json_agg(workspace_rows) FROM workspace_rows),'[]'::json))")
                result = launcher.lab.sql(statement,database=launcher.DATABASE,check=False,
                                          variables=(('auth_fault_correlations',scope),))
                if (type(result.returncode) is not int or result.returncode != 0
                        or not isinstance(result.stdout,str) or len(result.stdout)>8192):
                    raise ValueError()
                evidence=json.loads(result.stdout.strip())
                if (not isinstance(evidence,dict) or set(evidence)!=({'sessions','audit','workspaces'} if offline else {'sessions','audit'})
                        or not isinstance(evidence['sessions'],list) or len(evidence['sessions'])>16
                        or not isinstance(evidence['audit'],list) or len(evidence['audit'])>32):
                    raise ValueError()
                session_ids=set()
                for row in evidence['sessions']:
                    if (not isinstance(row,dict) or set(row)!={'sessionId','revoked'}
                            or type(row['revoked']) is not bool or not isinstance(row['sessionId'],str)
                            or str(UUID(row['sessionId']))!=row['sessionId'] or row['sessionId'] in session_ids):
                        raise ValueError()
                    session_ids.add(row['sessionId'])
                for row in evidence['audit']:
                    if (not isinstance(row,dict) or set(row)!={'sessionId','eventType','outcome','clientType'}
                            or not isinstance(row['sessionId'],str) or row['sessionId'] not in session_ids
                            or row['eventType'] not in ('LOGIN_SUCCEEDED','LOGOUT')
                            or row['outcome'] not in ('SUCCESS','FAILURE') or row['clientType']!='ANDROID'):
                        raise ValueError()
                if offline:
                    workspaces = evidence['workspaces']
                    if (not isinstance(workspaces, list) or len(workspaces) != 2
                            or any(not isinstance(row, dict) or set(row) != {'workspaceId', 'name', 'role'}
                                   or not isinstance(row['workspaceId'], str)
                                   or str(UUID(row['workspaceId'])) != row['workspaceId'] for row in workspaces)
                            or len({row['workspaceId'] for row in workspaces}) != 2
                            or {(row['name'], row['role']) for row in workspaces} !=
                            {('Phòng vận hành A', 'ADMIN'), ('Nhà kính B', 'USER')}):
                        raise ValueError()
                # Audit duplicates được giữ để final oracle bắt count sai, không deduplicate che multiple events.
                self._require_membership_available()
                return evidence
            except (ValueError,TypeError,KeyError,AttributeError,RuntimeError,OSError,launcher.subprocess.SubprocessError):
                raise RuntimeError('NATIVE_LAB_MEMBERSHIP_EVIDENCE_UNAVAILABLE') from None


    def suspend_b(self):
        """Suspend đúng pinned B một lần trong profile membership, owner phải drain trước host ACK.

        Output: receipt copy đã commit/readback/drain, không chứa SQL hoặc capability mới.
        Errors: fixed failure khi admission/operation/late lifecycle sai, không retry unknown commit.
        Side effects: guard lifecycle được kiểm lại sau startup và sát send; STOP sau admission vẫn phải drain SQL.
        """
        with self.lock:
            try:
                if (self.scenario != 'membership-stale' or self._membership_target is None
                        or self._membership_suspend_attempted):
                    raise RuntimeError()
                self._require_membership_available()
                self._membership_suspend_attempted = True
                # Control cố định đã nằm registry của launcher từ trước spawn backend.
                # Ghi owned object trước execute để STOP/backend-death luôn nhìn thấy operation cần drain.
                self._membership_operation = NativeMembershipOperation(
                    *self._membership_scope, self._membership_target,
                    assert_active=self._require_membership_available)
                receipt = self._membership_operation.execute()
                self._require_membership_available()
                return dict(receipt)
            except (ValueError, TypeError, RuntimeError, OSError, launcher.subprocess.SubprocessError):
                raise RuntimeError('NATIVE_LAB_MEMBERSHIP_SUSPEND_UNAVAILABLE') from None


    def watchdog(self):
        """Giữ startup/work deadlines; rate chờ ARM trong startup15phút, hết budget chỉ STOP chứ không giả cleanup."""
        if self.scenario == 'rate-limit':
            while True:
                with self.lock:
                    if self.stopping.is_set():
                        return
                    deadline = self.startup_deadline if self.work_deadline is None else self.work_deadline
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        # Chốt STOP trong lock để ARM tới cùng boundary không thể mở window mới.
                        self.stopping.set()
                        self.state_changed.set()
                        expired = True
                    else:
                        expired = False
                        # Clear dưới cùng lock với ARM/STOP để không làm mất wakeup sau khi nhả lock.
                        self.state_changed.clear()
                if expired:
                    self.stop()
                    return
                self.state_changed.wait(remaining)
        if self.scenario in ('membership-stale', 'offline-login'):
            remaining = max(0, self.work_deadline - time.monotonic())
            if not self.ready.wait(min(900, remaining)):
                self.stop()
                return
            remaining = self.work_deadline - time.monotonic()
            if remaining <= 0 or not self.stopping.wait(remaining):
                self.stop()
            return
        # Không gộp cleanup vào25phút cũ: Docker call có budget120s và không được kill shim trước finally.
        if not self.ready.wait(15 * 60) or not self.stopping.wait(self.work_seconds):
            self.stop()

    def arm(self):
        """Chốt đúng một work window rate từ intent host đã neo clock trước write, không dùng READY arrival làm mốc.

        Side effects: publish ARMED sau khi chốt absolute deadline và đánh thức watchdog trong cùng lock.
        Errors: fixed failure nếu chưa READY, STOP/quá startup, child đã chết hoặc replay; không có SQL.
        """
        with self.lock:
            now = time.monotonic()
            if (self.scenario != 'rate-limit' or not self.ready.is_set() or self.stopping.is_set()
                    or self.process is None or self.process.poll() is not None
                    or self.work_deadline is not None or now >= self.startup_deadline):
                raise RuntimeError('NATIVE_LAB_ARM_UNAVAILABLE')
            self.work_deadline = now + self.work_seconds
            self.state_changed.set()
            self.emit({'kind': 'ARMED'})

    def read_commands(self, input_stream):
        """Nhận control cố định qua raw pipe; lỗi output chỉ best-effort, STOP luôn được thử.

        Input
        Param: input_stream — private raw stdin do main sở hữu, command tối đa64bytes.
        Side effects: SNAPSHOT/target metadata, membership-stale thêm SUSPEND_B/session evidence; STOP/EOF/lỗi drain owner.
        """
        try:
            while not self.stopping.is_set():
                command = input_stream.readline(65)
                scopes = {b'SNAPSHOT\n': 'full', b'SNAPSHOT_DISABLED\n': 'disabled', b'SNAPSHOT_LIMITED\n': 'limited', b'SNAPSHOT_EMPTY\n': 'empty'}
                if command == b'ARM\n' and self.scenario == 'rate-limit':
                    self.arm()
                elif command == b'MEMBERSHIP_TARGET\n' and self.scenario != 'offline-login':
                    self.emit({'kind': 'MEMBERSHIP_TARGET', 'target': self.membership_target()})
                elif command == b'MEMBERSHIP_SESSION_EVIDENCE\n' and self.scenario in ('membership-stale', 'offline-login'):
                    self.emit({'kind': 'MEMBERSHIP_SESSION_EVIDENCE', **self.membership_session_evidence()})
                elif command == b'SUSPEND_B\n' and self.scenario == 'membership-stale':
                    self.emit({'kind': 'MEMBERSHIP_SUSPENDED', 'target': self.suspend_b()})
                elif command in scopes:
                    scope = scopes[command]
                    self.emit({'kind': 'SNAPSHOT', 'scope': scope, 'sessions': self.snapshot(scope)})
                else:
                    self.stop()
        except (ValueError, RuntimeError, OSError, launcher.subprocess.SubprocessError):
            try:
                self.emit({'kind': 'CONTROL_FAILED'})
            except BaseException:
                # Parent mất pipe vẫn cần cleanup; không để daemon in traceback hoặc bỏ STOP vì lỗi marker.
                pass
            finally:
                self.stop()

    def verify_cleanup(self):
        """Readback sau launcher finally để STOPPED chứng minh role/HBA/graph/bucket owned đã dọn.

        Output: đúng8count public của5fixture users và6bucket; mọi count phải integer0 trước ACK.
        Errors: thiếu projection/child terminal, SQL/schema hoặc dữ liệu còn lại chỉ trả fixed failure.
        """
        try:
            with self.lock:
                if self._cleanup_scope is None or self.process is None or self.process.poll() is None:
                    raise RuntimeError()
                user_ids, digests = self._cleanup_scope
            # Một SQL bound như trước; check=False tránh raw stderr có thể phản chiếu selector vào exception.
            result = launcher.lab.sql(CLEANUP_READBACK_SQL, role=launcher.lab.ADMIN, database=launcher.DATABASE,
                                      check=False, variables=(('auth_fault_correlations', ','.join(user_ids)),
                                                              ('auth_lab_bucket_digests', ','.join(digests))))
            if type(result.returncode) is not int or result.returncode != 0:
                raise RuntimeError()
            counts = json.loads(result.stdout.strip())
            expected = {'role', 'hba', 'users', 'sessions', 'workspaces', 'memberships', 'auditActor', 'limiterBuckets'}
            if not isinstance(counts, dict) or set(counts) != expected or any(type(value) is not int or value != 0 for value in counts.values()):
                raise RuntimeError()
            return counts
        except (ValueError, TypeError, AttributeError, RuntimeError, OSError, launcher.subprocess.SubprocessError):
            raise RuntimeError('NATIVE_LAB_CLEANUP_UNCONFIRMED') from None


class DiscardOutput(io.TextIOBase):
    """Không giữ/forward output launcher; chỉ protocol emitter có capability viết pipe thật."""

    def write(self, value):
        """Bỏ text launcher trong process test để output không trộn protocol.

        Input
        Param: value — text do launcher xuất, không lưu hoặc log lại.
        Output: số ký tự đã tiêu thụ theo TextIO interface.
        """
        return len(value)


def main():
    """Chạy launcher thật qua adapter riêng; STOP/EOF luôn yêu cầu finally trước fixed STOPPED marker.

    Side effects: canonical role1h/5users/2workspaces như launcher đã được duyệt; không đổi SQL/grants.
    Errors: chỉ fixed FAILED, không traceback, packet hoặc subprocess output nhạy cảm.
    """
    if len(sys.argv) != 1:
        raise ValueError('INVALID_NATIVE_LAB_ARGUMENTS')
    # Pipe raw không giữ buffered-reader lock khi daemon đang chờ; startup lỗi phải thoát sạch trước host EOF.
    # Dùng raw ngay từ packet đầu để buffered prefetch không nuốt STOP đã gửi liền sau JSON.
    input_stream = sys.stdin.buffer.raw
    raw_packet = input_stream.readline(4097)
    password = parse_packet(raw_packet)
    scenario = json.loads(raw_packet).get('scenario', 'default')
    raw_packet = b''
    output = sys.stdout
    output_lock = threading.Lock()

    def emit(value):
        """Xuất một frame public có lock để watchdog/control không trộn JSON.

        Input
        Param: value — metadata do code chọn, không nhận packet/config secrets.
        Side effects: ghi/flushed stdout pipe của owned runner.
        """
        with output_lock:
            output.write(json.dumps(value) + '\n')
            output.flush()

    control = NativeFixtureControl(emit, launcher.start_lab, scenario=scenario)

    def fixture_password(prompt):
        """Cấp fixture password từ packet private cho getpass của launcher, không hỏi terminal.

        Input
        Param: prompt — nhãn launcher; không in vì protocol không nhận text tự do.
        Output: mật khẩu synthetic còn trong RAM.
        """
        return password

    original_start = launcher.start_lab
    original_getpass = launcher.getpass.getpass
    try:
        launcher.start_lab = control.start_lab
        launcher.getpass.getpass = fixture_password
        threading.Thread(target=control.read_commands, args=(input_stream,), daemon=True).start()
        threading.Thread(target=control.watchdog, daemon=True).start()
        with contextlib.redirect_stdout(DiscardOutput()):
            if scenario in ('membership-stale', 'offline-login'):
                # Registry cố định trước run để cả child chết sớm vẫn drain control trước graph cleanup.
                launcher.run(False, 3000, operation_holders=[control])
            else:
                launcher.run(False, 3000)
        emit({'kind': 'STOPPED', 'cleanup': control.verify_cleanup()})
    finally:
        try:
            # Run có thể lỗi trước registry-drain của launcher, membership vẫn phải giữ trách nhiệm owned operation.
            if scenario in ('membership-stale', 'offline-login'):
                control.stop()
            else:
                control.stopping.set()
        finally:
            launcher.start_lab = original_start
            launcher.getpass.getpass = original_getpass
            password = ''


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError, KeyError, TypeError, OSError, launcher.subprocess.SubprocessError):
        print('{"kind":"FAILED"}')
        raise SystemExit(1) from None
