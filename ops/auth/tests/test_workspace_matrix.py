"""Kiểm harness bốn workspace bằng SQL/HTTP giả; không thay bằng chứng integration thật."""

from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from uuid import UUID

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_workspace_matrix as matrix

RUN = UUID('10000000-0000-4000-8000-000000000001')
USER = UUID('10000000-0000-4000-8000-000000000002')
OWNER = UUID('10000000-0000-4000-8000-000000000003')
SUSPENDED = UUID('10000000-0000-4000-8000-000000000006')
REMOVED = UUID('10000000-0000-4000-8000-000000000007')


class WorkspaceMatrixHarnessTests(unittest.TestCase):
    """Bắt fixture sai ownership, page lặp/bỏ row và cursor stale được nhận nhầm."""

    def exercise(self, mode='valid'):
        """Giả lập hai active rows và hai membership bị chặn, theo dõi restart/cleanup.

        Input
        Param: mode — defect hữu hạn trong page/cursor/detail hoặc setup SQL.
        Output: checks và HTTP paths khi oracle đúng; RuntimeError an toàn khi sai.
        """
        active = [{'id': '10000000-0000-4000-8000-000000000004', 'name': 'Synthetic A', 'status': 'ACTIVE', 'role': 'ADMIN', 'revision': 1},
                  {'id': '10000000-0000-4000-8000-000000000005', 'name': 'Synthetic D', 'status': 'ACTIVE', 'role': 'USER', 'revision': 1}]
        baseline = {'items': active, 'nextCursor': None}
        paths = []
        stale = False
        error = {'error': {'code': 'RESOURCE_NOT_FOUND', 'message': 'Không thể hoàn tất yêu cầu. Vui lòng kiểm tra trạng thái và thử lại.', 'details': {}, 'correlationId': str(RUN)}}

        def request(port, method, path, headers=None):
            """Trả boundary hữu hạn, cố tình cài mutation để xác minh oracle từ chối.

            Input
            Param: port/method/path/headers — request verifier; chỉ giữ path không credential.
            Output: tuple status/header/body tổng hợp theo thứ tự traversal hiện hành.
            """
            paths.append(path)
            self.assertEqual((port, method), (3001, 'GET'))
            if path.startswith('/workspaces/'):
                return (200 if mode == 'detail-leak' else 404), {}, error
            if path == '/workspaces':
                body = {'items': active + [dict(active[0], id=str(SUSPENDED))], 'nextCursor': None} if mode == 'inactive-visible' else baseline
                return 200, {}, body
            if stale:
                return (200, {}, baseline) if mode == 'stale-accepted' else (400, {}, {'error': {**error['error'], 'code': 'CURSOR_INVALID'}})
            if path == '/workspaces?limit=1':
                return 200, {}, {'items': active[:1], 'nextCursor': 'page-1'}
            if path.endswith('cursor=page-1'):
                items = active[:1] if mode == 'duplicate' else ([] if mode == 'omitted' else active[1:])
                return 200, {}, {'items': items, 'nextCursor': 'page-2'}
            self.assertTrue(path.endswith('cursor=page-2'))
            return 200, {}, {'items': [], 'nextCursor': None}

        def transition(*args):
            """Mô phỏng B SUSPENDED→REMOVED, chỉ cursor cũ ngay sau mutation bị stale."""
            nonlocal stale
            self.assertEqual(args, (RUN, USER, OWNER, SUSPENDED, 'REMOVED'))
            stale = True

        def restart_request(port, method, path, headers=None):
            """Giữ stale đúng request có cursor cũ, rồi cho traversal mới bắt đầu lại từ đầu."""
            nonlocal stale
            result = request(port, method, path, headers)
            if stale and 'cursor=' in path:
                stale = False
            return result

        checks = []
        with patch.object(matrix, 'uuid4', side_effect=[SUSPENDED, REMOVED]), patch.object(
                matrix, 'workspace_matrix_fixture', side_effect=[RuntimeError('Four-workspace fixture rejected'), None] if mode == 'setup-failed' else None) as fixture, patch.object(
                matrix.provider, 'request', side_effect=restart_request), patch.object(
                matrix.provider, 'set_owned_membership_status', side_effect=transition):
            try:
                matrix.verify_workspace_matrix(3001, {'X-Auth-Context-Id': str(RUN)}, baseline, RUN, USER, OWNER, checks)
            finally:
                self.assertEqual(fixture.call_args_list[-1].args[-1], False)
                self.assertEqual(fixture.call_args_list[0].args[-1], True)
        return checks, paths

    def test_exact_active_pair_and_restart_pass_then_cleanup(self):
        """Đúng A/D, B/C bị chặn và stale cursor restart mới cho PASS; không có resource request."""
        checks, paths = self.exercise()
        self.assertIn('four-workspace-exact-active-pair', checks)
        self.assertIn('four-workspace-restart-exact-active-pair', checks)
        self.assertIn('four-workspace-fixture-removed', checks)
        self.assertTrue(all(path.startswith('/workspaces') for path in paths))

    def test_inactive_rows_duplicates_omissions_and_stale_success_fail(self):
        """Mỗi kết quả sai đều dừng với check ID và vẫn cleanup hai workspace tạm."""
        for mode in ('inactive-visible', 'duplicate', 'omitted', 'detail-leak', 'stale-accepted'):
            with self.subTest(mode=mode), self.assertRaisesRegex(RuntimeError, '^Provider check failed: four-workspace-'):
                self.exercise(mode)

    def test_setup_failure_still_attempts_owned_cleanup(self):
        """Setup có thể mất ACK sau commit; cleanup vẫn phải được thử trước khi lỗi truyền ra ngoài."""
        with self.assertRaisesRegex(RuntimeError, '^Four-workspace fixture rejected$'):
            self.exercise('setup-failed')

    def test_fixture_guard_and_exact_readback(self):
        """Không ownership hoặc SQL/readback lệch phải fail; cleanup chỉ nhắm UUID/provenance run."""
        for create in (True, False):
            for mode in ('valid', 'unowned', 'sql-failed', 'wrong-count'):
                database = SimpleNamespace(sql=None)
                repository = SimpleNamespace(owns_probe=None)
                expected = '2|4|4|ACTIVE,ACTIVE,REMOVED,SUSPENDED' if create else '0|0|0'
                with self.subTest(create=create, mode=mode), patch.dict(sys.modules, {
                        'verify_database': database, 'verify_repositories': repository}), patch.object(
                        repository, 'owns_probe', return_value=mode != 'unowned'), patch.object(
                        database, 'sql', return_value=SimpleNamespace(returncode=int(mode == 'sql-failed'),
                                                                      stdout='unexpected' if mode == 'wrong-count' else expected)) as query:
                    if mode == 'valid':
                        matrix.workspace_matrix_fixture(RUN, USER, OWNER, (SUSPENDED, REMOVED), create)
                        statement = query.call_args.args[0]
                        self.assertIn('AUTH_HTTP_LAB_MATRIX:' + str(RUN), statement)
                        self.assertIn('AUTH_HTTP_LAB:' + str(RUN), statement)
                        self.assertIn('SET CONSTRAINTS ALL IMMEDIATE', statement)
                        self.assertIn('BEGIN;', statement)
                        self.assertIn('COMMIT;', statement)
                    else:
                        with self.assertRaisesRegex(RuntimeError, '^Four-workspace fixture rejected$'):
                            matrix.workspace_matrix_fixture(RUN, USER, OWNER, (SUSPENDED, REMOVED), create)
                        if mode == 'unowned':
                            query.assert_not_called()


if __name__ == '__main__':
    unittest.main()
