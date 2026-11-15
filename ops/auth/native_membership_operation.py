"""Owned fault operation chỉ suspend membership B synthetic, reuse lifecycle psql/backend của UserFenceHolder."""

import subprocess
import threading
import time
from uuid import UUID

from user_fence_holder import (
    UserFenceHolder, STARTUP_TIMEOUT, inspect_owned_lab, metadata_count, remaining, lab,
)


class NativeMembershipOperation(UserFenceHolder):
    """Giữ capability và một execute duy nhất; launcher phải đăng ký owner trước admission."""

    def __init__(self, run_id, user_id, creator_id, target, assert_active=None):
        """Chốt UUID/version synthetic để operation không theo metadata mutable của caller.

        Input
        Param: run_id — UUID run live, phải khớp marker role và provenance SQL.
        Param: user_id — account0 USER trong B, không Admin creator.
        Param: creator_id — account4 tạo B, phải có ADMIN ACTIVE.
        Param: target — baseline workspaceId/revision/authorizationVersion/grantGeneration từ owned projection.
        Param: assert_active — guard trusted của control đang giữ lock, kiểm STOP/deadline/backend trước mutation admission.
        Errors: ValueError cố định trước I/O nếu shape sai hoặc version không còn chỗ tăng1.
        """
        try:
            if assert_active is not None and not callable(assert_active):
                raise ValueError()
            for value in (run_id, user_id, creator_id):
                if not isinstance(value, str) or str(UUID(value)) != value:
                    raise ValueError()
            if len({run_id, user_id, creator_id}) != 3:
                raise ValueError()
            if (not isinstance(target, dict)
                    or set(target) != {'workspaceId','revision','authorizationVersion','grantGeneration'}
                    or not isinstance(target['workspaceId'], str)
                    or str(UUID(target['workspaceId'])) != target['workspaceId']):
                raise ValueError()
            for key in ('revision','authorizationVersion','grantGeneration'):
                maximum = 2**63 if key == 'grantGeneration' else 2**63-1
                if type(target[key]) is not int or not 0 < target[key] < maximum:
                    raise ValueError()
        except (ValueError, TypeError, KeyError, AttributeError):
            raise ValueError('INVALID_NATIVE_MEMBERSHIP_CAPABILITY') from None
        super().__init__(run_id, user_id, creator_id)
        self._target = dict(target)
        self._operation_lock = threading.Lock()
        self._closing = threading.Event()
        self._executed = False
        self._drained = False
        self._assert_external_active = assert_active

    def _assert_active(self):
        """Kiểm cancellation và lifecycle live trước admission, không coi guard là khả năng hủy SQL đã gửi.

        Errors: fixed failure khi STOP local hoặc guard owner từ chối deadline/backend hiện hành.
        """
        if self._closing.is_set():
            raise RuntimeError('NATIVE_MEMBERSHIP_OPERATION_FAILED')
        if self._assert_external_active is not None:
            self._assert_external_active()
        if self._closing.is_set():
            raise RuntimeError('NATIVE_MEMBERSHIP_OPERATION_FAILED')

    def _ownership_sql(self):
        """Output: predicate fixed với quoted psql bindings, kiểm live run/user/creator/workspace cùng snapshot."""
        return """EXISTS(SELECT 1 FROM users actor
JOIN users owner ON owner.user_id=:'owned_creator'::uuid
JOIN workspaces workspace ON workspace.workspace_id=:'owned_workspace'::uuid
AND workspace.created_by_user_id=owner.user_id
JOIN memberships creator ON creator.workspace_id=workspace.workspace_id AND creator.user_id=owner.user_id
JOIN membership_grants creator_grant ON creator_grant.workspace_id=creator.workspace_id
AND creator_grant.user_id=creator.user_id AND creator_grant.grant_generation=creator.current_grant_generation
WHERE actor.user_id=:'owned_user'::uuid AND actor.account_status='ACTIVE' AND owner.account_status='ACTIVE'
AND actor.email_normalized='probe-'||:'owned_run'||'-0@example.invalid'
AND owner.email_normalized='probe-'||:'owned_run'||'-4@example.invalid'
AND actor.activation_provenance='AUTH_HTTP_LAB:'||:'owned_run'
AND owner.activation_provenance='AUTH_HTTP_LAB:'||:'owned_run'
AND workspace.description='AUTH_HTTP_LAB:'||:'owned_run' AND workspace.status='ACTIVE'
AND creator.role='ADMIN' AND creator.status='ACTIVE' AND creator.removed_at IS NULL
AND creator_grant.revoked_at IS NULL
AND EXISTS(SELECT 1 FROM pg_roles WHERE rolname='iot_repository_probe'
AND shobj_description(oid,'pg_authid')='Temporary canonical repository verification:'||:'owned_run'))"""

    def _grant_sql(self):
        """Output: current grant đúng target USER chưa revoked, không tạo hoặc thay grant generation."""
        return """EXISTS(SELECT 1 FROM membership_grants grant_row
WHERE grant_row.workspace_id=target.workspace_id AND grant_row.user_id=target.user_id
AND grant_row.grant_generation=target.current_grant_generation AND grant_row.revoked_at IS NULL)"""

    def start(self):
        """Mở psql riêng và giữ khóa User→Workspace→creator/member trước update.

        Side effects: chỉ locks trong transaction của application_name ngẫu nhiên đã chốt trước spawn.
        Errors: thiếu role/ownership/lock marker hoặc hết startup5s phải FAIL, owner vẫn chịu drain.
        """
        deadline = time.monotonic() + STARTUP_TIMEOUT
        marker_query = ("SELECT count(*) FROM pg_roles WHERE rolname='iot_repository_probe' "
                        "AND shobj_description(oid,'pg_authid')="
                        f"'Temporary canonical repository verification:{self.run_id}';")
        if self._closing.is_set() or self.process is not None or metadata_count(marker_query, remaining(deadline,'startup')) != 1:
            raise RuntimeError('NATIVE_MEMBERSHIP_OWNER_MISMATCH')
        inspect_owned_lab(deadline)
        bindings = {
            'owned_run': str(self.run_id), 'owned_user': str(self.target_id),
            'owned_creator': str(self.changed_source_id), 'owned_workspace': self._target['workspaceId'],
            'expected_revision': str(self._target['revision']),
            'expected_authorization': str(self._target['authorizationVersion']),
            'expected_grant': str(self._target['grantGeneration']),
        }
        connection = f'dbname=iot_platform_lab application_name={self.application_name} connect_timeout=3'
        # Reuse cùng container/owner guard của holder. Value đã typed vẫn dùng quoted psql variables,
        # không nhận SQL, selector hoặc application_name từ command channel.
        arguments = ['docker','exec','-i',lab.CONTAINER,'psql','-X','-qAtw','-v','ON_ERROR_STOP=1',
                     '-h','/tmp','-U',lab.ADMIN,'-d',connection]
        for key, value in bindings.items():
            arguments.extend(['--set', f'{key}={value}'])
        remaining(deadline,'startup')
        self.process = subprocess.Popen(arguments, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True, encoding='utf-8',
                                        creationflags=subprocess.CREATE_NO_WINDOW)
        # Slow spawn không được mở SQL admission sau startup cap.
        remaining(deadline,'startup')
        self.reader = threading.Thread(target=self.collect_lines, daemon=True)
        self.reader.start()
        ownership = self._ownership_sql()
        # Chốt User locks theo UUID order trước Workspace. Mọi marker chỉ có khi ownership hiện hành đạt.
        statement = f"""SET statement_timeout='2s'; SET lock_timeout='2s';
SET idle_in_transaction_session_timeout='10s'; BEGIN;
WITH locked_users AS (
SELECT actor.user_id FROM users actor
WHERE actor.user_id IN (:'owned_user'::uuid,:'owned_creator'::uuid)
ORDER BY actor.user_id FOR UPDATE)
SELECT 'FENCE_READY|'||pg_backend_pid() WHERE (SELECT count(*) FROM locked_users)=2 AND {ownership};
SELECT 'MEMBERSHIP_WORKSPACE_LOCKED' FROM workspaces workspace
WHERE workspace_id=:'owned_workspace'::uuid AND {ownership} FOR UPDATE;
SELECT 'MEMBERSHIP_CREATOR_LOCKED' FROM memberships creator
WHERE workspace_id=:'owned_workspace'::uuid AND user_id=:'owned_creator'::uuid
AND role='ADMIN' AND status='ACTIVE' AND {ownership} FOR UPDATE;
SELECT 'MEMBERSHIP_MEMBER_LOCKED' FROM memberships target
WHERE workspace_id=:'owned_workspace'::uuid AND user_id=:'owned_user'::uuid
AND role='USER' AND status='ACTIVE' AND removed_at IS NULL
AND revision=:'expected_revision'::bigint AND authorization_version=:'expected_authorization'::bigint
AND current_grant_generation=:'expected_grant'::bigint AND {self._grant_sql()}
AND {ownership} FOR UPDATE;"""
        remaining(deadline,'startup')
        self.send(statement)
        self.pid = self.read_marker('FENCE_READY', remaining(deadline,'startup'))
        for marker in ('MEMBERSHIP_WORKSPACE_LOCKED','MEMBERSHIP_CREATOR_LOCKED','MEMBERSHIP_MEMBER_LOCKED'):
            self.read_marker(marker, remaining(deadline,'startup'))
            remaining(deadline,'startup')

    def _suspend(self):
        """Update CAS một row rồi xác nhận commit và readback riêng trong fixed5s.

        Errors: marker thiếu/sai/đến muộn là unknown hoặc conflict, caller không replay.
        """
        deadline = time.monotonic() + 5
        ownership = self._ownership_sql()
        # PK target + CAS giữ đúng một membership. Marker UPDATE chưa là commit, readback chỉ chạy sau COMMIT.
        statement = f"""UPDATE memberships target
SET status='SUSPENDED', revision=revision+1, authorization_version=authorization_version+1
WHERE workspace_id=:'owned_workspace'::uuid AND user_id=:'owned_user'::uuid
AND role='USER' AND status='ACTIVE' AND removed_at IS NULL
AND revision=:'expected_revision'::bigint AND authorization_version=:'expected_authorization'::bigint
AND current_grant_generation=:'expected_grant'::bigint AND {self._grant_sql()} AND {ownership}
RETURNING 'MEMBERSHIP_CHANGED';
COMMIT;
\\echo MEMBERSHIP_COMMITTED
SELECT 'MEMBERSHIP_READBACK' FROM memberships target
WHERE workspace_id=:'owned_workspace'::uuid AND user_id=:'owned_user'::uuid
AND role='USER' AND status='SUSPENDED' AND removed_at IS NULL
AND revision=:'expected_revision'::bigint+1 AND authorization_version=:'expected_authorization'::bigint+1
AND current_grant_generation=:'expected_grant'::bigint AND {self._grant_sql()} AND {ownership};"""
        # Guard chốt admission sát pipe write. STOP sau guard vẫn là in-flight, phải giữ commit/drain ownership.
        self._assert_active()
        self.send(statement)
        for marker in ('MEMBERSHIP_CHANGED','MEMBERSHIP_COMMITTED','MEMBERSHIP_READBACK'):
            self.read_marker(marker, remaining(deadline,'commit'))
            remaining(deadline,'commit')

    def _drain(self):
        """Chốt Popen/reader/backend-gone trước release, không xem local Docker exit là server terminal.

        Errors: fixed drain failure nếu inherited owned shutdown chưa chứng minh backend biến mất.
        """
        if self._drained:
            return
        try:
            super().stop()
        except (ValueError, RuntimeError, OSError, subprocess.SubprocessError):
            raise RuntimeError('NATIVE_MEMBERSHIP_DRAIN_UNCONFIRMED') from None
        self._drained = True

    def execute(self):
        """Thực hiện capability đúng một lần rồi drain trước trả receipt dùng cho host ACK.

        Output: copy target với statusSUSPENDED và revision/authVersion tăng1 sau commit/readback/drain.
        Errors: fixed business failure, hoặc fixed drain-unconfirmed ưu tiên giữ graph chưa cleanup.
        """
        with self._operation_lock:
            if self._executed or self._closing.is_set():
                raise RuntimeError('NATIVE_MEMBERSHIP_OPERATION_FAILED')
            self._executed = True
            try:
                try:
                    self._assert_active()
                    self.start()
                    self._assert_active()
                    self._suspend()
                except (ValueError, TypeError, RuntimeError, OSError, subprocess.SubprocessError):
                    raise RuntimeError('NATIVE_MEMBERSHIP_OPERATION_FAILED') from None
            finally:
                self._drain()
            self._assert_active()
            return {**self._target, 'status':'SUSPENDED', 'revision':self._target['revision']+1,
                    'authorizationVersion':self._target['authorizationVersion']+1}

    def stop(self):
        """Registry chốt cancellation trước lock rồi đợi execute/drain, ngăn mutation sau fixture cleanup."""
        self._closing.set()
        with self._operation_lock:
            self._drain()
