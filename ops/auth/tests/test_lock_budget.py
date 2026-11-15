"""Oracle lock timeout phải fail closed; dữ liệu synthetic không thay provider evidence."""

from copy import deepcopy
from contextlib import ExitStack
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import MagicMock, Mock, patch
from uuid import UUID, uuid4

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'database'))
import verify_lock_budget as budget


class LockBudgetOracleTests(unittest.TestCase):
    """Chỉ503 an toàn và exact error-stage5s mới được dùng làm evidence lock budget."""

    def response(self):
        """Tạo error contract tổng hợp không credential, giữ UUID chỉ trong RAM."""
        return 503, {'Cache-Control': 'no-store'}, {'error': {
            'code': 'SERVICE_UNAVAILABLE', 'message': 'Không thể hoàn tất yêu cầu. Vui lòng kiểm tra trạng thái và thử lại.',
            'details': {}, 'correlationId': str(uuid4())}}

    def snapshot(self):
        """Tạo đúng5stage; chỉ account acquire lỗi và fenced work drop, không giả rollback từ metric."""
        return {'windowId': 13, 'valid': True, 'droppedSamples': 0, 'staleSamples': 0, 'poisoned': False,
                'samples': [{'stage': stage, 'outcome': outcome, 'elapsedUs': 5001000}
                            for stage, outcome in [('pool_acquire', 'completed'), ('transaction_begin', 'completed'),
                                                   ('bucket_acquire', 'completed'), ('account_acquire', 'error'),
                                                   ('fenced_work', 'abandoned')]]}

    def test_safe_unavailable_accepts_only_generic_contract(self):
        """Không dùng401/429 hoặc error chứa capability làm503PASS; lỗi không được phản chiếu secret."""
        response = self.response()
        self.assertEqual(str(budget.validate_unavailable(response)), response[2]['error']['correlationId'])
        for kind in ('status', 'cookie', 'nested-secret', 'message', 'correlation'):
            changed = deepcopy(response)
            if kind == 'status':
                changed = (401, changed[1], changed[2])
            elif kind == 'cookie':
                changed[1]['Set-Cookie'] = ''
            elif kind == 'nested-secret':
                changed[2]['error']['details'] = {'token': 'synthetic-private-token'}
            elif kind == 'message':
                changed[2]['error']['message'] = 'raw-database-diagnostic'
            else:
                changed[2]['error']['correlationId'] = 'not-uuid'
            with self.subTest(kind=kind), self.assertRaises(RuntimeError):
                budget.validate_unavailable(changed)

    def test_exact_five_stages_and_real_wait_duration_are_required(self):
        """Thiếu/trùngstage, saioutcome/generation/flags hoặc accountError tức thời không phải timeout thật."""
        value = self.snapshot()
        self.assertEqual(budget.validate_lock_snapshot(value, 13), value)
        for kind in ('duplicate', 'outcome', 'short', 'long', 'stale', 'loss', 'bool', 'extra'):
            changed = deepcopy(value)
            if kind == 'duplicate':
                changed['samples'][0]['stage'] = 'transaction_begin'
            elif kind == 'outcome':
                changed['samples'][3]['outcome'] = 'completed'
            elif kind in ('short', 'long'):
                changed['samples'][3]['elapsedUs'] = 1 if kind == 'short' else 8000000
            elif kind == 'stale':
                changed['windowId'] = 12
            elif kind == 'loss':
                changed['droppedSamples'] = 1
            elif kind == 'bool':
                changed['staleSamples'] = False
            else:
                changed['secret'] = 'synthetic-private-token'
            with self.subTest(kind=kind), self.assertRaises(RuntimeError):
                budget.validate_lock_snapshot(changed, 13)


class LockBudgetOrchestrationTests(unittest.TestCase):
    """Kiểm ownership, deadline và thứ tự fault bằng boundaries giả, không tạo thread hoặc kết nối DB."""

    def exercise(self, fault=None):
        """Giữ state committed riêng với pending request để không lấy503 làm bằng chứng rollback.

        Input
        Param: fault — một nhánh wait/proof/HTTP/state/stage/recovery/deadline lỗi tổng hợp.
        Output: observations, checks và events; lỗi phải cleanup holder trước executor join.
        """
        events, holders, checks = [], [], []
        identities = [UUID(int=index + 1) for index in range(5)]
        emails = [f'synthetic-private-email-{index}' for index in range(5)]
        digests = [str(index) * 64 for index in range(5)]
        run_id, key = UUID(int=10), b'x' * 32
        state = {'clock': 10.0, 'generation': 12, 'window': False, 'client': None,
                 'done': False, 'call': None, 'counts': [0, 0, 0], 'fault_clients': set()}

        def clock_read():
            """Cấp monotonic clock điều khiển được để kiểm ngân sách còn lại mà không sleep."""
            return state['clock']

        def login(port, email, password, client):
            """Mô phỏng credential channel và committed counters; request dưới holder chỉ trả error.

            Input
            Param: port — loopback primary cố định của lượt synthetic.
            Param: email — identity fixture3, chỉ so sánh trong RAM.
            Param: password — credential synthetic, không xuất vào report.
            Param: client — WEB/ANDROID để giữ đúng channel cookie hoặc bearer.
            Output: response tổng hợp; Side effects: healthy login mới tăng session/audit.
            """
            self.assertEqual((port, email, password), (3001, emails[3], 'synthetic-private-password'))
            self.assertIn(client, ('WEB', 'ANDROID'))
            state['client'] = client
            if state.get('in_fault'):
                self.assertTrue(any(holder.active for holder in holders))
                response = LockBudgetOracleTests().response()
                return (401, response[1], response[2]) if fault == 'http' else response
            phase = 'recovery' if client in state['fault_clients'] else 'control'
            events.append((client, phase))
            if fault == phase:
                return 503, {}, {}
            self.assertFalse(state['window'])
            state['counts'][0] += 1
            if not (fault == 'recovery-state' and phase == 'recovery'):
                state['counts'][1] += 1
            body = {'me': {'id': str(identities[3])}, 'limited': False}
            headers = {'Cache-Control': 'no-store'}
            if client == 'WEB':
                headers['Set-Cookie'] = 'iot_session=synthetic-private-cookie; HttpOnly; SameSite=Lax; Path=/'
                headers['X-Auth-Context-Id'] = str(UUID(int=20))
                headers['X-CSRF-Token'] = 'synthetic-private-csrf'
            else:
                body['token'] = 'synthetic-private-token'
            return 200, headers, body

        def snapshot(user_id, digest, correlations=()):
            """Đọc committed counts giả theo đúng fixture, không suy trạng thái từ HTTP status.

            Input
            Param: user_id — UUID fixture3 do launcher sở hữu.
            Param: digest — selector bucket synthetic, không dùng làm metric label.
            Param: correlations — request lỗi để kiểm exact audit count bằng0.
            Output: session, actor audit, failure counter và request audit.
            """
            self.assertEqual((user_id, digest), (identities[3], digests[3]))
            events.append((state['client'], 'committed_read'))
            counts = list(state['counts'])
            if fault == 'counter':
                counts[2] = 1
            if fault == 'state' and correlations:
                counts[0] += 1
            return (*counts, 0)

        def begin(port, received_key, previous=0):
            """Đòi carry-forward generation qua hai client và mở window sau holder READY.

            Input
            Param: port — listener primary synthetic.
            Param: received_key — capability TEST giữ trong RAM.
            Param: previous — generation cuối M4a hoặc case WEB trước đó.
            Output: generation kế tiếp; Side effects: đánh dấu window đang mở.
            """
            self.assertEqual((port, received_key, previous), (3001, key, state['generation']))
            self.assertTrue(any(holder.active for holder in holders))
            self.assertFalse(state['window'])
            state['generation'] += 1
            state['window'] = True
            events.append((state['client'], 'begin'))
            return state['generation']

        def control(port, action, received_key):
            """Chỉ cho end sau holder cleanup, trả snapshot lỗi trước recovery ngoài window.

            Input
            Param: port — listener primary synthetic.
            Param: action — chỉ end vì begin có boundary kiểm generation riêng.
            Param: received_key — capability TEST không xuất evidence.
            Output: năm stage hợp lệ hoặc fault mất sample.
            """
            self.assertEqual((port, action, received_key), (3001, 'end', key))
            self.assertFalse(any(holder.active for holder in holders))
            self.assertTrue(state['window'])
            state['window'] = False
            events.append((state['client'], 'end'))
            value = LockBudgetOracleTests().snapshot()
            value['windowId'] = state['generation']
            if fault == 'stage':
                value['samples'].pop()
            return value

        def create_holder(received_run, target_id, source_id):
            """Tạo handle giả sở hữu riêng, kiểm registry trước start và không cho gọi mutation.

            Input
            Param: received_run — UUID lượt chạy synthetic.
            Param: target_id — chỉ fixture3 không membership.
            Param: source_id — fixture2 chỉ phục vụ constructor, không được commit mutation.
            Output: holder fake với state active và marker protocol cố định.
            """
            self.assertEqual((received_run, target_id, source_id), (run_id, identities[3], identities[2]))
            holder = Mock()
            holder.active = False

            def start():
                """Chỉ cấp READY khi caller đã lưu quyền cleanup trong registry của launcher."""
                self.assertIn(holder, holders)
                holder.active = True
                events.append((state['client'], 'start'))
                if fault == 'start':
                    raise RuntimeError('Synthetic holder startup failed')

            def wait():
                """Dùng hai giây ngân sách observe giả để phát hiện reset deadline sau actual wait."""
                self.assertTrue(holder.active)
                events.append((state['client'], 'wait'))
                state['clock'] += 2.0
                if fault == 'wait':
                    raise RuntimeError('Synthetic wait not observed')

            def send(statement):
                """Đòi literal proof đúng owned backend sau response, không chấp nhận early release.

                Input
                Param: statement — SQL literal của PLAN, không có input hoặc selector động.
                """
                expected = "SELECT 'FENCE_STILL_HELD' WHERE EXISTS(SELECT 1 FROM pg_locks WHERE pid=pg_backend_pid() AND relation='public.users'::regclass AND mode='RowShareLock' AND granted);"
                self.assertEqual(' '.join(statement.split()), expected)
                self.assertTrue(holder.active)
                self.assertTrue(state['done'])
                events.append((state['client'], 'proof_send'))

            def marker(expected, timeout):
                """Chỉ nhận proof mới sau response trong cận1s, không dùng process-alive làm bằng chứng.

                Input
                Param: expected — literal marker sau-response của PLAN.
                Param: timeout — ngân sách đọc marker phải dương và không quá1s.
                """
                self.assertEqual(expected, 'FENCE_STILL_HELD')
                self.assertGreater(timeout, 0)
                self.assertLessEqual(timeout, 1.0)
                self.assertTrue(holder.active)
                events.append((state['client'], 'proof_marker'))
                if fault == 'proof':
                    raise RuntimeError('Synthetic proof missing')

            def stop():
                """Cleanup idempotent; chỉ lần nhả holder thật mới được ghi vào sequence."""
                if holder.active:
                    holder.active = False
                    events.append((state['client'], 'stop'))

            holder.start.side_effect = start
            holder.wait_for_blocked.side_effect = wait
            holder.send.side_effect = send
            holder.read_marker.side_effect = marker
            holder.stop.side_effect = stop
            holder.commit.side_effect = AssertionError('Lock budget must not mutate holder transaction')
            return holder

        def is_done():
            """Mô phỏng cả pending thật và fault đã xong trước actual-wait acceptance."""
            return state['done'] or fault == 'done'

        def finish(timeout=None):
            """Hoàn tất worker giả dưới holder; late response cố tình vượt deadline để cần fresh check.

            Input
            Param: timeout — phải là phần còn lại của8s sau hai giây observe, không phải8s mới.
            Output: response tổng hợp; Side effects: advance clock và đánh dấu request hoàn tất.
            """
            self.assertIsNotNone(timeout)
            self.assertGreater(timeout, 0)
            self.assertLessEqual(timeout, 6.0)
            state['done'] = True
            state['in_fault'] = True
            function, arguments, keywords = state['call']
            try:
                response = function(*arguments, **keywords)
            finally:
                state['in_fault'] = False
            state['fault_clients'].add(state['client'])
            state['clock'] += 7.0 if fault == 'late' else 3.05
            events.append((state['client'], 'response'))
            return response

        future = Mock()
        future.done.side_effect = is_done
        future.result.side_effect = finish

        def submit(function, *arguments, **keywords):
            """Lưu đúng một công việc để result chạy có kiểm soát, không tạo thread thật.

            Input
            Param: function — callback request đã patch boundary HTTP.
            Param: arguments — input callback synthetic chỉ giữ trong RAM.
            Param: keywords — tùy chọn callback synthetic không log.
            Output: pending future fake chưa hoàn tất.
            """
            self.assertTrue(state['window'])
            self.assertTrue(any(holder.active for holder in holders))
            state['done'] = False
            state['call'] = (function, arguments, keywords)
            events.append((state['client'], 'submit'))
            return future

        def join(_kind, _value, _traceback):
            """Đòi stop holder trước executor join kể cả wait/proof/HTTP failure.

            Input
            Param: _kind — loại lỗi của context, không suppress.
            Param: _value — dữ liệu lỗi không được xuất vào evidence.
            Param: _traceback — traceback context không dùng thay đổi verdict.
            Output: False để propagate lỗi; Side effects: ghi join phi bí mật.
            """
            self.assertFalse(any(holder.active for holder in holders))
            events.append((state['client'], 'join'))
            return False

        workers = MagicMock()
        workers.__enter__.return_value = workers
        workers.__exit__.side_effect = join
        workers.submit.side_effect = submit

        def create_executor(max_workers):
            """Chỉ cấp một worker giả như PLAN, không đổi concurrency để đạt timeout.

            Input
            Param: max_workers — số worker phải đúng1 cho mỗi case.
            Output: executor fake dùng cùng event state để quan sát lifecycle.
            """
            self.assertEqual(max_workers, 1)
            return workers

        with ExitStack() as stack:
            for name, replacement in (('UserFenceHolder', create_holder), ('ThreadPoolExecutor', create_executor),
                                      ('login_request', login), ('read_snapshot', snapshot),
                                      ('begin_window', begin), ('measurement_control', control)):
                stack.enter_context(patch.object(budget, name, side_effect=replacement))
            stack.enter_context(patch.object(budget.time, 'monotonic', side_effect=clock_read))
            try:
                observations = budget.verify_lock_budget(3001, emails, 'synthetic-private-password', identities,
                                                         digests, run_id, key, 12, checks, holders)
            finally:
                self.last_events, self.last_holders = events, holders
                self.assertFalse(any(holder.active for holder in holders))
        return observations, checks, events

    def test_both_clients_keep_holder_through_response_and_export_only_numeric_stages(self):
        """Giữ khóa qua503/proof, carry generation rồi recovery ngoài window; report không có credential."""
        observations, checks, events = self.exercise()
        self.assertEqual([value['clientType'] for value in observations], ['WEB', 'ANDROID'])
        self.assertEqual([value['snapshot']['windowId'] for value in observations], [13, 14])
        self.assertEqual(len(checks), 16)
        for client in ('WEB', 'ANDROID'):
            sequence = [event for owner, event in events if owner == client]
            required = ('control', 'start', 'begin', 'submit', 'wait', 'response',
                        'proof_send', 'proof_marker', 'stop', 'join', 'end', 'recovery')
            positions = [sequence.index(event) for event in required]
            self.assertEqual(positions, sorted(positions))
            reads = [index for index, event in enumerate(sequence) if event == 'committed_read']
            self.assertTrue(any(sequence.index('control') < index < sequence.index('start') for index in reads))
            self.assertTrue(any(sequence.index('stop') < index < sequence.index('recovery') for index in reads))
            self.assertTrue(any(sequence.index('recovery') < index for index in reads))
        serialized = json.dumps(observations)
        for private in ('synthetic-private', str(UUID(int=4)), str(UUID(int=10))):
            self.assertNotIn(private, serialized)

    def test_wait_or_proof_failure_stops_owned_holder_before_join(self):
        """Mất actual wait/proof phải FAIL và nhả holder trước join, không chuyển sang recovery."""
        for fault in ('start', 'wait', 'proof'):
            with self.subTest(fault=fault), self.assertRaises(RuntimeError):
                self.exercise(fault)
            self.assertNotIn(('WEB', 'recovery'), self.last_events)

    def test_http_state_stage_and_recovery_failures_cannot_return_observations(self):
        """503 sai, committed state đổi, thiếu stage hoặc recovery lỗi không được xuất partial PASS."""
        for fault in ('http', 'state', 'stage', 'recovery', 'recovery-state'):
            with self.subTest(fault=fault), self.assertRaises(RuntimeError):
                self.exercise(fault)

    def test_late_response_cannot_reset_accepted_result_deadline(self):
        """Response trả về sau8s vẫn FAIL dù future.result fake trả dữ liệu thay vì TimeoutError."""
        with self.assertRaises(RuntimeError):
            self.exercise('late')
        self.assertNotIn(('WEB', 'recovery'), self.last_events)

    def test_finished_pending_request_cannot_count_as_actual_wait(self):
        """Waiter metadata không đủ nếu HTTP pending đã xong trước khi chấp nhận actual wait."""
        with self.assertRaises(RuntimeError):
            self.exercise('done')

    def test_bad_control_or_nonfresh_counter_stops_before_holder_start(self):
        """Credential precondition và counter0 phải được kiểm trước khi tạo fault window."""
        for fault in ('control', 'counter'):
            with self.subTest(fault=fault), self.assertRaises(RuntimeError):
                self.exercise(fault)
            self.assertFalse(self.last_holders)


if __name__ == '__main__':
    unittest.main()
