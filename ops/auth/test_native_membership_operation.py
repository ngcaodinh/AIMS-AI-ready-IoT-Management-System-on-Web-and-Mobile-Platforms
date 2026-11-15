"""Kiểm operation suspend B qua owned lifecycle giả, không mở DB hoặc đọc credentials."""

from pathlib import Path
import sys
import threading
import unittest
from unittest.mock import MagicMock, patch
from uuid import uuid4

AUTH_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(AUTH_ROOT))
sys.path.insert(0, str(AUTH_ROOT.parent / 'database'))
import native_membership_operation as operation
import user_fence_holder as holder


def make_operation():
    """Output: operation riêng với UUID/version synthetic, chưa spawn hoặc truy cập DB."""
    return operation.NativeMembershipOperation(
        str(uuid4()), str(uuid4()), str(uuid4()),
        {'workspaceId': str(uuid4()), 'revision': 7, 'authorizationVersion': 9, 'grantGeneration': 3})


class NativeMembershipOperationTests(unittest.TestCase):
    """Bất kỳ thiếu commit/readback/drain đều phải từ chối outcome thành công."""

    def test_invalid_capability_is_rejected_before_io(self):
        """Chặn UUID/schema/bool/overflow trước SQL, kể cả version lớn không còn chỗ tăng1."""
        ids = [str(uuid4()) for index in range(3)]
        valid = {'workspaceId': str(uuid4()), 'revision': 7, 'authorizationVersion': 9, 'grantGeneration': 3}
        for invalid in [{}, {**valid, 'revision': True}, {**valid, 'revision': 0},
                        {**valid, 'revision': 2**63-1}, {**valid, 'authorizationVersion': 2**63},
                        {**valid, 'grantGeneration': '1'}, {**valid, 'extra': 'SYNTHETIC_SECRET'},
                        {**valid, 'workspaceId': 'ABCDEFAB-1234-4567-89AB-ABCDEFABCDEF'}]:
            with self.subTest(shape=list(invalid)), patch.object(operation.subprocess, 'Popen') as spawn:
                with self.assertRaisesRegex(ValueError, '^INVALID_NATIVE_MEMBERSHIP_CAPABILITY$'):
                    operation.NativeMembershipOperation(*ids, invalid)
                spawn.assert_not_called()
        for bad_ids in [[None, ids[1], ids[2]], [ids[0], ids[1], ids[1]], [1, ids[1], ids[2]]]:
            with self.assertRaisesRegex(ValueError, '^INVALID_NATIVE_MEMBERSHIP_CAPABILITY$'):
                operation.NativeMembershipOperation(*bad_ids, valid)

    def test_success_requires_drain_before_return_and_is_one_shot(self):
        """Commit/readback chỉ cho kết quả sau owned drain, không replay execute hoặc theo mutable target."""
        target = {'workspaceId': str(uuid4()), 'revision': 7, 'authorizationVersion': 9, 'grantGeneration': 3}
        probe = operation.NativeMembershipOperation(str(uuid4()), str(uuid4()), str(uuid4()), target)
        expected = {**target, 'status': 'SUSPENDED', 'revision': 8, 'authorizationVersion': 10}
        target['revision'] = 300
        calls = []
        def start():
            """Ghi startup giả để đối chiếu drain phải đi sau business operation."""
            calls.append('start')
        def suspend():
            """Ghi commit/readback giả, chưa cho testcase suy terminal ở đây."""
            calls.append('commit-readback')
        def drain():
            """Ghi owned terminal giả để kiểm nó đã xảy ra trước execute trả receipt."""
            calls.append('drain')
        with patch.object(probe, 'start', side_effect=start), patch.object(probe, '_suspend', side_effect=suspend), patch.object(probe, '_drain', side_effect=drain):
            self.assertEqual(probe.execute(), expected)
            self.assertEqual(calls, ['start','commit-readback','drain'])
            with self.assertRaisesRegex(RuntimeError, '^NATIVE_MEMBERSHIP_OPERATION_FAILED$'):
                probe.execute()
            self.assertEqual(len(calls), 3)

    def test_start_or_commit_failure_always_drains_and_contains_raw_error(self):
        """Raw exception có thể chứa SQL/selector không được ra caller, operation lỗi vẫn giữ owned drain."""
        for failing in ['start','_suspend']:
            probe = make_operation()
            with patch.object(probe, 'start'), patch.object(probe, '_suspend'), patch.object(probe, '_drain') as drain:
                getattr(probe, failing).side_effect = OSError('SYNTHETIC_SECRET')
                with self.assertRaisesRegex(RuntimeError, '^NATIVE_MEMBERSHIP_OPERATION_FAILED$'):
                    probe.execute()
            drain.assert_called_once()

    def test_drain_failure_overrides_business_success(self):
        """Thiếu backend-gone không được trả metadata thành công dù commit/readback giả đã đạt."""
        probe = make_operation()
        with patch.object(probe, 'start'), patch.object(probe, '_suspend'), patch.object(holder.UserFenceHolder, 'stop', side_effect=RuntimeError('SYNTHETIC_SECRET')):
            with self.assertRaisesRegex(RuntimeError, '^NATIVE_MEMBERSHIP_DRAIN_UNCONFIRMED$'):
                probe.execute()

    def test_stop_before_execute_latches_cancellation_before_io(self):
        """Registry drain thắng admission thì operation không được spawn về sau dưới graph đang cleanup."""
        probe = make_operation()
        probe.stop()
        with patch.object(probe, 'start') as start:
            with self.assertRaisesRegex(RuntimeError, '^NATIVE_MEMBERSHIP_OPERATION_FAILED$'):
                probe.execute()
        start.assert_not_called()

    def test_stop_during_execute_waits_and_prevents_late_success(self):
        """Stop giữ intent trước lock, chờ operation drain và chặn return metadata muộn."""
        probe = make_operation()
        entered = threading.Event()
        release = threading.Event()
        outcomes = []

        def pending_suspend():
            """Giữ operation ở commit boundary giả để kiểm registry stop race bằng events."""
            entered.set()
            if not release.wait(5):
                raise RuntimeError('SYNTHETIC_TEST_TIMEOUT')

        def execute():
            """Thu fixed outcome từ worker, không dùng thread exception làm tín hiệu PASS."""
            try:
                probe.execute()
                outcomes.append('unexpected-success')
            except RuntimeError as error:
                outcomes.append(str(error))

        worker = threading.Thread(target=execute)
        stopper = threading.Thread(target=probe.stop)
        with patch.object(probe, 'start'), patch.object(probe, '_suspend', side_effect=pending_suspend), patch.object(holder.UserFenceHolder, 'stop') as drain:
            try:
                worker.start()
                self.assertTrue(entered.wait(5))
                stopper.start()
                self.assertTrue(probe._closing.wait(5))
                drain.assert_not_called()
                release.set()
                worker.join(5)
                stopper.join(5)
                self.assertFalse(worker.is_alive())
                self.assertFalse(stopper.is_alive())
                self.assertEqual(outcomes, ['NATIVE_MEMBERSHIP_OPERATION_FAILED'])
                drain.assert_called_once()
            finally:
                release.set()
                if worker.ident is not None:
                    worker.join(5)
                if stopper.ident is not None:
                    stopper.join(5)

    def test_start_requires_role_owner_before_spawn(self):
        """Marker role thuộc run khác phải dừng trước Popen, không chọn backend theo UUID tự khai."""
        probe = make_operation()
        with patch.object(operation, 'metadata_count', return_value=0), patch.object(operation.subprocess, 'Popen') as spawn:
            with self.assertRaises(RuntimeError):
                probe.start()
        spawn.assert_not_called()

    def test_start_binds_capability_and_locks_users_before_workspace(self):
        """Các value chỉ đi qua psql quoted bindings, markers đòi lock User→Workspace→creator/member."""
        probe = make_operation()
        child = MagicMock()
        child.poll.return_value = None
        with patch.object(operation, 'metadata_count', return_value=1), patch.object(operation, 'inspect_owned_lab'), patch.object(operation.subprocess, 'Popen', return_value=child) as spawn, patch.object(operation.threading, 'Thread') as thread, patch.object(probe, 'send') as send, patch.object(probe, 'read_marker', side_effect=[123,'','','']):
            probe.start()
        self.assertIs(probe.process, child)
        self.assertEqual(probe.pid, 123)
        command = spawn.call_args.args[0]
        self.assertIn('application_name='+probe.application_name, ' '.join(command))
        for name in ['owned_run','owned_user','owned_creator','owned_workspace','expected_revision','expected_authorization','expected_grant']:
            self.assertTrue(any(value.startswith(name+'=') for value in command))
        statement = send.call_args.args[0]
        self.assertIn(":'owned_run'", statement)
        self.assertIn('ORDER BY actor.user_id FOR UPDATE', statement)
        self.assertLess(statement.index('FENCE_READY'), statement.index('MEMBERSHIP_WORKSPACE_LOCKED'))
        self.assertLess(statement.index('MEMBERSHIP_WORKSPACE_LOCKED'), statement.index('MEMBERSHIP_CREATOR_LOCKED'))
        self.assertLess(statement.index('MEMBERSHIP_CREATOR_LOCKED'), statement.index('MEMBERSHIP_MEMBER_LOCKED'))
        self.assertIn("SET statement_timeout='2s'", statement)
        self.assertIn("idle_in_transaction_session_timeout='10s'", statement)
        thread.return_value.start.assert_called_once()

    def test_suspend_requires_changed_commit_then_post_commit_readback(self):
        """Không dùng UPDATE RETURNING để khẳng định COMMIT, query readback phải ở sau COMMIT marker."""
        probe = make_operation()
        calls = []
        def read(name, seconds):
            """Ghi marker theo thứ tự để kiểm COMMIT và readback là hai boundary riêng.

            Input
            Param: name — marker literal cần nhận.
            Param: seconds — remaining budget của stage, không dùng clock thật trong case.
            """
            calls.append(name)
        with patch.object(probe, 'send') as send, patch.object(probe, 'read_marker', side_effect=read):
            probe._suspend()
        self.assertEqual(calls, ['MEMBERSHIP_CHANGED','MEMBERSHIP_COMMITTED','MEMBERSHIP_READBACK'])
        statement = send.call_args.args[0]
        for fragment in ["role='USER'", "status='ACTIVE'", "revision=:'expected_revision'::bigint",
                         "authorization_version=:'expected_authorization'::bigint",
                         "current_grant_generation=:'expected_grant'::bigint",
                         "status='SUSPENDED'", "revision=:'expected_revision'::bigint+1",
                         'AUTH_HTTP_LAB:', 'shobj_description', 'revoked_at IS NULL']:
            self.assertIn(fragment, statement)
        self.assertLess(statement.index('COMMIT;'), statement.index('MEMBERSHIP_COMMITTED'))
        self.assertLess(statement.index('MEMBERSHIP_COMMITTED'), statement.index('MEMBERSHIP_READBACK'))

    def test_missing_commit_or_readback_is_not_success(self):
        """Update nhận marker nhưng mất commit/readback vẫn FAIL, không execute lần nữa."""
        for marker in ['MEMBERSHIP_CHANGED','MEMBERSHIP_COMMITTED','MEMBERSHIP_READBACK']:
            probe = make_operation()
            def read(name, seconds):
                """Giả marker bị mất ở đúng boundary, không thay lifecycle DB thật.

                Input
                Param: name — marker nội bộ đang được đợi.
                Param: seconds — remaining budget, không reset clock.
                """
                if name == marker:
                    raise RuntimeError('SYNTHETIC_SECRET')
            with patch.object(probe, 'start'), patch.object(probe, 'send'), patch.object(probe, 'read_marker', side_effect=read), patch.object(probe, '_drain') as drain:
                with self.assertRaisesRegex(RuntimeError, '^NATIVE_MEMBERSHIP_OPERATION_FAILED$'):
                    probe.execute()
                with self.assertRaisesRegex(RuntimeError, '^NATIVE_MEMBERSHIP_OPERATION_FAILED$'):
                    probe.execute()
            drain.assert_called_once()

    def test_external_guard_is_checked_immediately_before_update_send(self):
        """Owner mất authority trong lúc dựng SQL phải bị từ chối trước pipe write, không chỉ sau startup."""
        probe = make_operation()
        active = threading.Event()
        active.set()

        def assert_active():
            """Từ chối admission khi owner đã latch cancellation, không thực hiện I/O."""
            if not active.is_set():
                raise RuntimeError('NATIVE_LAB_MEMBERSHIP_UNAVAILABLE')

        def lose_authority():
            """Giả lifecycle đổi trong lúc dựng ownership predicate trước guard sát send."""
            active.clear()
            return 'TRUE'

        probe._assert_external_active = assert_active
        with patch.object(probe, '_ownership_sql', side_effect=lose_authority), \
             patch.object(probe, 'send') as send:
            with self.assertRaisesRegex(RuntimeError, '^NATIVE_LAB_MEMBERSHIP_UNAVAILABLE$'):
                probe._suspend()
        send.assert_not_called()

    def test_stop_after_update_admission_drains_without_success_or_retry(self):
        """STOP sau admission là in-flight, vẫn giữ commit/readback/drain và chặn receipt/replay."""
        probe = make_operation()
        calls = []

        def send(statement):
            """Latch STOP tại pipe write giả, khi mutation đã qua guard admission.

            Input
            Param: statement — SQL mutation fixed, chỉ kiểm có UPDATE mà không ghi nội dung.
            """
            self.assertIn('UPDATE memberships target', statement)
            calls.append('send')
            probe._closing.set()

        def drain():
            """Xác nhận owner vẫn drain SQL đang in-flight trước khi trả failure."""
            calls.append('drain')

        with patch.object(probe, 'start'), patch.object(probe, 'send', side_effect=send) as write, \
             patch.object(probe, 'read_marker'), patch.object(probe, '_drain', side_effect=drain):
            for attempt in range(2):
                with self.assertRaisesRegex(RuntimeError, '^NATIVE_MEMBERSHIP_OPERATION_FAILED$'):
                    probe.execute()
        write.assert_called_once()
        self.assertEqual(calls, ['send', 'drain'])

    def test_owned_backend_still_live_prevents_drain(self):
        """Kế thừa backend-gone oracle, query count1 phải giữ failure dù Popen đã terminal."""
        probe = make_operation()
        probe.process = MagicMock()
        probe.process.poll.return_value = 0
        with patch.object(holder, 'metadata_count', return_value=1), patch.object(holder, 'SHUTDOWN_TIMEOUT', .01):
            with self.assertRaisesRegex(RuntimeError, '^NATIVE_MEMBERSHIP_DRAIN_UNCONFIRMED$'):
                probe.stop()



    def test_final_marker_cannot_extend_absolute_stage_deadline(self):
        """Remaining truyền vào helper không được mở lại deadline khi marker cuối về sau absolute cap."""
        for phase in ['start','commit']:
            probe = make_operation()
            with patch.object(operation.time, 'monotonic', return_value=0) as clock:
                def read_marker(name, seconds):
                    """Cho marker cuối tới sau cap, dù dependency giả trả marker đúng.

                    Input
                    Param: name — marker cần nhận của stage.
                    Param: seconds — remaining đã tính trước call.
                    Output: PID cho first marker, các marker khác không mang giá trị.
                    """
                    if name in ('MEMBERSHIP_MEMBER_LOCKED','MEMBERSHIP_READBACK'):
                        clock.return_value = 6
                    return 123 if name == 'FENCE_READY' else None
                with patch.object(probe, 'send'), patch.object(probe, 'read_marker', side_effect=read_marker), patch.object(operation, 'metadata_count', return_value=1), patch.object(operation, 'inspect_owned_lab'), patch.object(operation.subprocess, 'Popen'), patch.object(operation.threading, 'Thread'):
                    with self.assertRaises(RuntimeError):
                        if phase == 'start':
                            probe.start()
                        else:
                            probe._suspend()



    def test_expired_preflight_or_spawn_never_sends_sql_after_deadline(self):
        """Không admission Popen sau inspection hết cap, hoặc gửi SQL sau slow Popen vượt cap."""
        for boundary in ['inspection','spawn']:
            probe = make_operation()
            with patch.object(operation.time,'monotonic',return_value=0) as clock:
                def advance(*args, **kwargs):
                    """Cho dependency dùng hết budget, không làm I/O thật.

                    Input
                    Param: args — arguments của inspection hoặc Popen giả.
                    Param: kwargs — keyword arguments tương ứng.
                    Output: process giả, không được dùng để gửi SQL sau deadline.
                    """
                    clock.return_value=6
                    return MagicMock()
                with patch.object(operation,'metadata_count',return_value=1), patch.object(operation,'inspect_owned_lab') as inspect, patch.object(operation.subprocess,'Popen') as spawn, patch.object(probe,'send') as send, patch.object(operation.threading,'Thread'):
                    if boundary == 'inspection':
                        inspect.side_effect=advance
                    else:
                        spawn.side_effect=advance
                    with self.assertRaises(RuntimeError):
                        probe.start()
                    send.assert_not_called()
                    if boundary == 'inspection':
                        spawn.assert_not_called()


if __name__ == '__main__':
    unittest.main()
