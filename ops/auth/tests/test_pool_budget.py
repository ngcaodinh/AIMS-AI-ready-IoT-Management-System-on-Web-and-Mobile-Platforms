"""Kiểm pool-budget harness bằng boundaries giả; không thay bằng chứng HTTP/PostgreSQL thật."""

from contextlib import ExitStack
from copy import deepcopy
import json
import io
from pathlib import Path
import queue
import subprocess
import sys
import unittest
from unittest.mock import MagicMock, Mock, patch
from uuid import UUID

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'database'))
import verify_pool_budget as budget
import run_local as launcher


def pool_snapshot(generation=1, elapsed=5_001_000):
    """Tạo exact một PoolAcquire/Error để phân biệt acquire timeout với BEGIN hoặc pool đóng tức thời.

    Input
    Param: generation — window của đúng special process.
    Param: elapsed — microseconds synthetic quanh budget5s, không phải HTTP wall time.
    Output: payload numeric/enum không chứa credential.
    """
    return {'windowId': generation, 'valid': True, 'droppedSamples': 0, 'staleSamples': 0,
            'poisoned': False, 'samples': [{'stage': 'pool_acquire', 'outcome': 'error', 'elapsedUs': elapsed}]}


class PoolBudgetOracleTests(unittest.TestCase):
    """Oracle phải reject mọi dữ liệu không đủ chứng minh exact acquire-error window5s."""

    def test_accepts_exact_error_sample_and_closed_duration_bounds(self):
        """Hai cận4.9–7s đều hợp lệ nhưng không cho stage khác hoặc thay bằng thời gian HTTP."""
        for elapsed in (4_900_000, 5_001_000, 7_000_000):
            value = pool_snapshot(13, elapsed)
            with self.subTest(elapsed=elapsed):
                self.assertEqual(budget.validate_pool_snapshot(value, 13), value)

    def test_rejects_bad_stage_count_outcome_duration_and_sample_shape(self):
        """Giữ riêng các biến thể cùng count để guard stage/outcome không bị che bởi count guard."""
        for kind in ('missing', 'duplicate', 'begin', 'completed', 'abandoned', 'short', 'long',
                     'negative', 'float', 'bool', 'overflow', 'sample-extra', 'sample-missing', 'sample-null'):
            value = pool_snapshot(13)
            sample = value['samples'][0]
            if kind == 'missing':
                value['samples'] = []
            elif kind == 'duplicate':
                value['samples'].append(deepcopy(sample))
            elif kind == 'begin':
                sample['stage'] = 'transaction_begin'
            elif kind in ('completed', 'abandoned'):
                sample['outcome'] = kind
            elif kind in ('short', 'long', 'negative', 'float', 'bool', 'overflow'):
                sample['elapsedUs'] = {'short': 4_899_999, 'long': 7_000_001, 'negative': -1,
                                       'float': 5_001_000.0, 'bool': True, 'overflow': 1 << 64}[kind]
            elif kind == 'sample-extra':
                sample['token'] = 'synthetic-private-token'
            elif kind == 'sample-missing':
                del sample['outcome']
            else:
                value['samples'][0] = None
            with self.subTest(kind=kind), self.assertRaises(RuntimeError):
                budget.validate_pool_snapshot(value, 13)

    def test_rejects_stale_loss_poison_extra_and_boolean_metadata(self):
        """Boolean không được giả uint; exact metadata và generation là điều kiện evidence độc lập."""
        changes = [('windowId', 12), ('windowId', True), ('windowId', 13.0), ('valid', False),
                   ('valid', 1), ('droppedSamples', 1), ('droppedSamples', False), ('staleSamples', 1),
                   ('staleSamples', False), ('poisoned', True), ('poisoned', 0), ('samples', ()),
                   ('secret', 'synthetic-private-token')]
        for field, changed in changes:
            value = pool_snapshot(13)
            value[field] = changed
            with self.subTest(field=field, value_type=type(changed).__name__), self.assertRaises(RuntimeError):
                budget.validate_pool_snapshot(value, 13)
        for field in tuple(pool_snapshot()):
            value = pool_snapshot(13)
            del value[field]
            with self.subTest(missing=field), self.assertRaises(RuntimeError):
                budget.validate_pool_snapshot(value, 13)
        for value in (None, [], 'synthetic-private-payload'):
            with self.subTest(shape=type(value).__name__), self.assertRaises(RuntimeError):
                budget.validate_pool_snapshot(value, 13)


class PoolBudgetProtocolTests(unittest.TestCase):
    """Kiểm literal ACK, command phase và deadline bằng fake pipe/queue; không mở Popen hoặc thread."""

    def exercise(self, scenario='success', reply=None):
        """Chạy protocol với clock điều khiển được, lưu events để đối soát terminate trước join.

        Input
        Param: scenario — happy path hoặc một lỗi ACK/phase/reap tổng hợp.
        Param: reply — marker bất hợp lệ cần bị reject mà không echo vào exception.
        Output: commands/events trong RAM; Errors: RuntimeError của harness được giữ nguyên cho test.
        """
        events, written = [], []
        state = {'clock': 10.0, 'exit': None, 'current': None}
        process, lines, reader = MagicMock(), MagicMock(), MagicMock()
        reader.is_alive.return_value = False
        lines.empty.return_value = True
        lines.get_nowait.side_effect = queue.Empty
        self.protocol_events, self.protocol_written = events, written

        def monotonic():
            """Cấp monotonic clock giả để không sleep hoặc phụ thuộc tốc độ máy."""
            return state['clock']

        def poll():
            """Đọc exit state chỉ của fake process do test sở hữu."""
            return state['exit']

        def write(value):
            """Nhận command literal, không chấp nhận credential hoặc frame nối từ input không tin cậy."""
            self.assertIn(value, ('HOLD\n', 'CHECK_HELD\n', 'RELEASE\n', 'STOP\n'))
            state['current'] = value.rstrip('\n')
            written.append(state['current'])
            events.append('write-' + state['current'])
            if scenario == 'slow-write':
                state['clock'] += 13.0
            return len(value)

        def read(timeout=None):
            """ACK tới muộn phải bị fresh deadline check bắt dù queue.get vẫn trả thành công.

            Input
            Param: timeout — ngân sách còn lại từ trước write, không reset sau marker.
            Output: ACK exact hoặc dữ liệu lỗi synthetic, không đọc stdout thật.
            """
            self.assertIsNotNone(timeout)
            self.assertGreater(timeout, 0)
            maximum = 12.0 if state['current'] == 'HOLD' else 8.0 if state['current'] == 'STOP' else 5.0
            self.assertLessEqual(timeout, maximum)
            if scenario == 'missing':
                raise queue.Empty
            if scenario == 'late':
                state['clock'] += maximum + 1.0
            return reply if scenario == 'reply' else {
                'HOLD': 'POOL_HELD|8', 'CHECK_HELD': 'POOL_STILL_HELD|8',
                'RELEASE': 'POOL_RELEASED|8', 'STOP': 'POOL_STOPPED'}[state['current']]

        def wait(timeout=None):
            """Reap là invariant riêng; ACK STOPPED không che exit code lỗi hoặc child còn sống."""
            self.assertIsNotNone(timeout)
            self.assertGreater(timeout, 0)
            self.assertLessEqual(timeout, 5.0)
            events.append('wait')
            if scenario == 'wait-error':
                raise subprocess.TimeoutExpired('synthetic-owned-child', timeout)
            if scenario == 'late-reap':
                state['clock'] += 6.0
            state['exit'] = 1 if scenario == 'exit' else 0
            process.returncode = state['exit']
            return state['exit']

        def stop(owned):
            """Fallback chỉ dừng fake Popen đã truyền; phải diễn ra trước reader join khi protocol lỗi."""
            self.assertIs(owned, process)
            events.append('terminate-reap')
            state['exit'] = 0
            process.returncode = 0

        def join(timeout=None):
            """Ghi join hữu hạn để không dùng daemon hoặc abort-read làm bằng chứng cleanup."""
            self.assertIsNotNone(timeout)
            self.assertGreaterEqual(timeout, 0)
            events.append('join')

        process.stdin.write.side_effect = write
        process.poll.side_effect = poll
        process.wait.side_effect = wait
        lines.get.side_effect = read
        reader.join.side_effect = join
        with patch.object(budget.queue, 'Queue', return_value=lines), \
                patch.object(budget.threading, 'Thread', return_value=reader), \
                patch.object(budget.time, 'monotonic', side_effect=monotonic):
            child = budget.PoolBudgetChild(process, stop)
            process.stdin.write.assert_not_called()
            process.stdout.readline.assert_not_called()
            reader.start.assert_not_called()
            if scenario == 'early-check':
                child.command('CHECK_HELD')
            elif scenario == 'early-release':
                child.command('RELEASE')
            elif scenario == 'unknown':
                child.command('HOLD\nsynthetic-private-input')
            else:
                self.assertEqual(child.command('HOLD'), 'POOL_HELD|8')
                if scenario == 'double-hold':
                    child.command('HOLD')
                self.assertEqual(child.command('CHECK_HELD'), 'POOL_STILL_HELD|8')
                self.assertEqual(child.command('CHECK_HELD'), 'POOL_STILL_HELD|8')
                self.assertEqual(child.command('RELEASE'), 'POOL_RELEASED|8')
                if scenario == 'after-release':
                    child.command('CHECK_HELD')
                self.assertIsNone(child.stop())
                self.assertTrue(process.stdin.close.called)
                self.assertTrue(process.wait.called)
                self.assertTrue(reader.join.called)
        return written, events

    def test_exact_ack_phase_and_successful_stop_reap(self):
        """Cho phép hai proof cùng vector rồi RELEASE; success phải đóng stdin, join và reap."""
        commands, events = self.exercise()
        self.assertEqual(commands, ['HOLD', 'CHECK_HELD', 'CHECK_HELD', 'RELEASE', 'STOP'])
        self.assertIn('wait', events)

    def test_rejects_wrong_count_unknown_eof_and_secret_ack(self):
        """Không nhận count7, marker khác hoặc EOF làm bằng chứng held8; lỗi không lộ payload."""
        for reply in ('POOL_HELD|7', 'POOL_STILL_HELD|8', 'POOL_HELD|8|extra', '', None,
                      'synthetic-private-diagnostic'):
            with self.subTest(shape=type(reply).__name__):
                with self.assertRaises(RuntimeError) as error:
                    self.exercise('reply', reply)
                self.assertNotIn('synthetic-private', str(error.exception))
                self.assertIn('terminate-reap', self.protocol_events)

    def test_late_ack_write_budget_and_missing_ack_fail_closed(self):
        """Cùng deadline từ trước write; queue có marker sau deadline vẫn không được PASS."""
        for scenario in ('late', 'slow-write', 'missing'):
            with self.subTest(scenario=scenario), self.assertRaises(RuntimeError):
                self.exercise(scenario)
            self.assertIn('terminate-reap', self.protocol_events)
            if 'join' in self.protocol_events:
                self.assertLess(self.protocol_events.index('terminate-reap'), self.protocol_events.index('join'))

    def test_invalid_command_order_and_nonzero_exit_are_rejected(self):
        """Không ghi command ngoài state hợp lệ hoặc coi STOPPED+exit1 là đã shutdown thành công."""
        for scenario in ('early-check', 'early-release', 'unknown', 'double-hold', 'after-release', 'exit'):
            with self.subTest(scenario=scenario), self.assertRaises(RuntimeError):
                self.exercise(scenario)
            if scenario in ('early-check', 'early-release', 'unknown'):
                self.assertEqual(self.protocol_written, [])

    def test_late_reap_and_wait_exception_cannot_satisfy_stop(self):
        """Exit0 được wait trả muộn hoặc wait lỗi đều phải thu hồi child, không cho STOPPED che deadline."""
        for scenario in ('late-reap', 'wait-error'):
            with self.subTest(scenario=scenario), self.assertRaises(RuntimeError):
                self.exercise(scenario)
            self.assertIn('terminate-reap', self.protocol_events)
            self.assertLess(self.protocol_events.index('wait'), self.protocol_events.index('terminate-reap'))


class PoolBudgetFrameTests(unittest.TestCase):
    """Exercise reader thật với StringIO để fake protocol thread không che lỗi framing hoặc limit."""

    def test_actual_reader_requires_bounded_complete_lf_or_crlf_frames(self):
        """Reader chỉ lấy tối đa65ký tự để phát hiện frame>64, không nhận EOF hoặc dòng chưa hoàn tất."""
        for text, expected in [('POOL_HELD|8\n', 'POOL_HELD|8'), ('POOL_HELD|8\r\n', 'POOL_HELD|8'),
                               ('POOL_HELD|8', None), ('', None), ('x' * 64 + '\n', None),
                               ('POOL_HELD|8\nPOOL_STILL_HELD|8\n', 'POOL_HELD|8')]:
            process, replies = Mock(), queue.Queue(maxsize=1)
            stream = io.StringIO(text)
            process.stdout.readline = Mock(wraps=stream.readline)
            child = budget.PoolBudgetChild(process, Mock())
            child._read_ack(replies)
            with self.subTest(frame_length=len(text)):
                self.assertEqual(replies.get_nowait(), expected)
                process.stdout.readline.assert_called_once_with(65)
                self.assertTrue(replies.empty())

    def test_reader_pipe_failure_is_generic_without_raw_diagnostic(self):
        """OSError/decoder ValueError chỉ tạo None, không đẩy raw error hoặc dữ liệu pipe vào queue."""
        for error in (OSError('synthetic-private-diagnostic'), ValueError('synthetic-private-decoder')):
            process, replies = Mock(), queue.Queue(maxsize=1)
            process.stdout.readline.side_effect = error
            budget.PoolBudgetChild(process, Mock())._read_ack(replies)
            self.assertIsNone(replies.get_nowait())


class PoolBudgetLauncherTests(unittest.TestCase):
    """Đường startup mặc định/special dùng cùng config RAM, nhưng framing và pipe lifetime khác nhau."""

    def exercise(self, special, delayed=None):
        """Mô phỏng READY tới muộn hoặc join kéo dài bằng clock giả, không mở process/reader thread.

        Input
        Param: special — opt-in argv literal và stdin giữ mở cho command protocol.
        Param: delayed — ready hoặc join vượt startup45s, cả hai phải bị reject.
        Output: Popen fake và call args; Errors: startup deadline sai trả RuntimeError generic.
        """
        process, reader = MagicMock(), MagicMock()
        process.poll.return_value = None
        reader.is_alive.return_value = False
        state = {'clock': 0.0, 'output': None}
        config = {'databasePassword': 'synthetic-private-config', 'enableMeasurements': special}

        def create_reader(*args, **kwargs):
            """Giữ reference output của startup reader mà không thực thi target đọc stdout."""
            state['output'] = kwargs['args'][1]
            return reader

        def start():
            """READY bình thường đến trong budget; delayed-ready chỉ xuất hiện sau bước poll đầu."""
            if delayed != 'ready':
                state['output'].append('AUTH_LAB_READY')

        def sleep(duration):
            """Đẩy READY sang sau45s để chứng minh while-short-circuit không thay fresh deadline check."""
            state['clock'] = 46.0
            state['output'].append('AUTH_LAB_READY')

        def monotonic():
            """Cấp clock giả không đọc environment hoặc đợi thời gian thật."""
            return state['clock']

        def join(timeout=None):
            """Reader join có thể hoàn tất sau deadline dù is_alive=False."""
            if delayed == 'join':
                state['clock'] = 46.0

        reader.start.side_effect, reader.join.side_effect = start, join
        with patch.object(launcher.subprocess, 'Popen', return_value=process) as popen, \
                patch.object(launcher.threading, 'Thread', side_effect=create_reader), \
                patch.object(launcher.time, 'monotonic', side_effect=monotonic), \
                patch.object(launcher.time, 'sleep', side_effect=sleep), \
                patch.object(launcher, 'stop_lab') as stop:
            try:
                result = launcher.start_lab(config, pool_budget=special)
            except BaseException:
                stop.assert_called_once_with(process)
                raise
        self.assertIs(result, process)
        payload = process.stdin.write.call_args.args[0]
        self.assertEqual(json.loads(payload), config)
        self.assertEqual(payload.endswith('\n'), special)
        self.assertEqual(process.stdin.close.called, not special)
        self.assertEqual(process.stdin.flush.called, special)
        self.assertEqual(popen.call_args.args[0][1:], ['--pool-budget'] if special else [])
        self.assertNotIn('synthetic-private', ' '.join(popen.call_args.args[0]))
        self.assertTrue(reader.join.called)

    def test_special_and_default_startup_preserve_config_framing(self):
        """Normal EOF không bật special flag; special newline+flush giữ stdin cho owned commands."""
        for special in (False, True):
            with self.subTest(special=special):
                self.exercise(special)

    def test_late_ready_or_reader_join_cannot_pass_startup_deadline(self):
        """READY truthy sau45s hoặc reader join muộn không được bàn giao child cho verifier."""
        for delayed in ('ready', 'join'):
            with self.subTest(delayed=delayed), self.assertRaises(RuntimeError):
                self.exercise(True, delayed)


class PoolBudgetOrchestrationTests(unittest.TestCase):
    """State committed và holder lifetime được kiểm riêng; không gọi HTTP/DB/process/thread thật."""

    def exercise(self, fault=None):
        """Mô phỏng hai client trên cùng child/pool với snapshots và readback độc lập.

        Input
        Param: fault — một lỗi control/503/stage/state/recovery/deadline/proof/stop synthetic.
        Output: observations/checks/events; Errors: verifier phải FAIL và stop child trên mọi nhánh.
        """
        identities = [UUID(int=index + 1) for index in range(5)]
        emails = [f'synthetic-private-email-{index}' for index in range(5)]
        digests = [str(index) * 64 for index in range(5)]
        key, password = b'x' * 32, 'synthetic-private-password'
        checks, events = [], []
        state = {'clock': 10.0, 'held': False, 'released': False, 'stopped': False, 'window': False,
                 'generation': 0, 'client': None, 'faults': [], 'proofs': [], 'counts': [0, 0, 0]}
        child = Mock()
        self.orchestration_events, self.orchestration_checks = events, checks

        def clock_read():
            """Cấp monotonic giả, duration5s đến từ snapshot chứ không từ sleep."""
            return state['clock']

        def command(value):
            """Giữ vector8 xuyên hai windows; RELEASE trước proof thứ hai là vi phạm ownership."""
            events.append(value)
            if value == 'HOLD':
                self.assertFalse(state['window'])
                self.assertEqual(state['counts'][:2], [2, 2])
                state['held'] = True
            elif value == 'CHECK_HELD':
                self.assertTrue(state['held'])
                self.assertFalse(state['window'])
                self.assertTrue(state['faults'])
                if fault == 'proof':
                    raise RuntimeError('Synthetic held proof absent')
                state['proofs'].append(state['faults'][-1])
            elif value == 'RELEASE':
                self.assertEqual(state['faults'], ['WEB', 'ANDROID'])
                self.assertEqual(state['proofs'], ['WEB', 'ANDROID'])
                self.assertFalse(state['window'])
                state['held'], state['released'] = False, True
            else:
                raise AssertionError('Unexpected verifier command')
            return {'HOLD': 'POOL_HELD|8', 'CHECK_HELD': 'POOL_STILL_HELD|8',
                    'RELEASE': 'POOL_RELEASED|8'}[value]

        def stop():
            """Stop luôn thu hồi held state; lỗi stop không được append invariant reaped thành công."""
            events.append('stop')
            state['held'] = False
            if fault == 'stop':
                raise RuntimeError('Synthetic child shutdown unverified')
            state['stopped'] = True

        def login(port, email, supplied_password, client):
            """HTTP fake giữ đúng identity/client và chỉ healthy login mới đổi committed counts."""
            self.assertEqual((port, email, supplied_password), (3001, emails[3], password))
            self.assertIn(client, ('WEB', 'ANDROID'))
            state['client'] = client
            if state['held']:
                self.assertTrue(state['window'])
                state['faults'].append(client)
                events.append(client + '-503')
                state['clock'] += 9.0 if fault == 'late-result' else 5.0
                response = (503, {'Cache-Control': 'no-store'}, {'error': {
                    'code': 'SERVICE_UNAVAILABLE',
                    'message': 'Không thể hoàn tất yêu cầu. Vui lòng kiểm tra trạng thái và thử lại.',
                    'details': {}, 'correlationId': str(UUID(int=100 + len(state['faults'])))}})
                if fault == 'http-status':
                    return 401, response[1], response[2]
                if fault == 'cookie':
                    response[1]['Set-Cookie'] = ''
                if fault == 'token':
                    response[2]['token'] = 'synthetic-private-token'
                if fault == 'body-none':
                    return 503, response[1], None
                return response
            phase = 'recovery' if state['released'] else 'control'
            events.append(client + '-' + phase)
            self.assertFalse(state['window'])
            if fault == phase:
                return 503, {}, None
            state['counts'][0] += 1
            if not (fault == 'recovery-state' and phase == 'recovery'):
                state['counts'][1] += 1
            body = {'limited': False, 'me': {'id': str(identities[3])}}
            headers = {'Cache-Control': 'no-store'}
            if client == 'WEB':
                headers.update({'Set-Cookie': 'iot_session=synthetic-private-cookie; HttpOnly; Secure; SameSite=Lax; Path=/api/v1',
                                'X-Auth-Context-Id': str(UUID(int=20)), 'X-CSRF-Token': 'synthetic-private-csrf'})
            else:
                body['token'] = 'synthetic-private-token'
            return 200, headers, body

        def read_snapshot(user_id, digest, correlations=()):
            """Đối soát committed session/audit/counter riêng với HTTP503 và holder ACK."""
            self.assertEqual((user_id, digest), (identities[3], digests[3]))
            events.append('committed-read')
            counts = list(state['counts'])
            if fault == 'initial-counter':
                counts[2] = 1
            if fault == 'state' and state['faults']:
                counts[0] += 1
            if fault == 'counter' and state['faults']:
                counts[2] += 1
            return (*counts, 1 if fault == 'request-audit' and correlations else 0)

        def begin(port, received_key, previous=0):
            """Mở đúng hai generation tăng của special process sau HOLD, không trộn recorder normal."""
            self.assertEqual((port, received_key, previous), (3001, key, state['generation']))
            self.assertTrue(state['held'])
            self.assertFalse(state['window'])
            state['window'] = True
            state['generation'] += 1
            events.append('begin')
            return state['generation']

        def end(port, action, received_key):
            """End phải diễn ra khi vector8 còn held, chỉ có đúng một request trong window."""
            self.assertEqual((port, action, received_key), (3001, 'end', key))
            self.assertTrue(state['held'])
            self.assertTrue(state['window'])
            self.assertEqual(len(state['faults']), state['generation'])
            state['window'] = False
            events.append('end')
            value = pool_snapshot(state['generation'])
            if fault == 'stage':
                value['samples'][0]['stage'] = 'transaction_begin'
            elif fault == 'generation':
                value['windowId'] -= 1
            return value

        def submit(function, *args, **kwargs):
            """Chạy worker giả khi result được lấy, tránh tạo thread thật nếu verifier dùng executor."""
            future = Mock()
            future.done.return_value = False

            def result(timeout=None):
                """Trả HTTP fake trong budget còn lại; late-result cố tình cần fresh check sau return."""
                if timeout is not None:
                    self.assertGreater(timeout, 0)
                    self.assertLessEqual(timeout, 8.0)
                return function(*args, **kwargs)

            future.result.side_effect = result
            return future

        child.command.side_effect, child.stop.side_effect = command, stop
        executor = MagicMock()
        executor.__enter__.return_value = executor
        executor.submit.side_effect = submit
        # Chặn toàn bộ lớp I/O gốc: một patch thiếu không được vô tình chạm network/psql trong test.
        with ExitStack() as patches:
            patches.enter_context(patch('http.client.HTTPConnection', side_effect=AssertionError('Unpatched HTTP boundary')))
            patches.enter_context(patch('subprocess.Popen', side_effect=AssertionError('Unpatched process boundary')))
            patches.enter_context(patch('subprocess.run', side_effect=AssertionError('Unpatched SQL boundary')))
            patches.enter_context(patch.object(budget, 'login_request', side_effect=login))
            patches.enter_context(patch.object(budget, 'read_snapshot', side_effect=read_snapshot))
            patches.enter_context(patch.object(budget, 'begin_window', side_effect=begin))
            patches.enter_context(patch.object(budget, 'measurement_control', side_effect=end))
            patches.enter_context(patch.object(budget.time, 'monotonic', side_effect=clock_read))
            patches.enter_context(patch.object(budget, 'ThreadPoolExecutor', return_value=executor, create=True))
            try:
                result = budget.verify_pool_budget(child, 3001, emails, password, identities, digests, key, checks)
            finally:
                self.assertTrue(child.stop.called)
        self.assertTrue(state['stopped'])
        return result, checks, events

    def test_two_real_boundary_cases_hold_until_both_proofs_and_recover(self):
        """Hai HTTP lỗi tách window, vector chỉ RELEASE sau proof thứ hai, rồi recovery và stop/reap."""
        observations, checks, events = self.exercise()
        self.assertIs(type(observations), list)
        self.assertEqual([value['clientType'] for value in observations], ['WEB', 'ANDROID'])
        self.assertEqual(len(checks), 15)
        self.assertEqual(len(set(checks)), 15)
        self.assertEqual(events.count('CHECK_HELD'), 2)
        self.assertLess(events.index('ANDROID-503'), events.index('RELEASE'))
        self.assertLess(events.index('RELEASE'), events.index('WEB-recovery'))
        self.assertLess(events.index('ANDROID-recovery'), events.index('stop'))
        exported = json.dumps(observations)
        self.assertNotIn('synthetic-private', exported)
        self.assertNotIn(str(UUID(int=4)), exported)
        for generation, value in enumerate(observations, 1):
            self.assertEqual(value['snapshot']['windowId'], generation)
            self.assertEqual(budget.validate_pool_snapshot(value['snapshot'], generation), value['snapshot'])

    def test_bad_response_and_committed_mutation_fail_closed(self):
        """503 status không che credential, body sai, session/counter hoặc request audit đã commit."""
        for fault in ('http-status', 'cookie', 'token', 'body-none', 'state', 'counter', 'request-audit'):
            with self.subTest(fault=fault), self.assertRaises(RuntimeError):
                self.exercise(fault)
            self.assertIn('stop', self.orchestration_events)
            # Lỗi committed state phải bị chặn trước RELEASE; recovery không được bắt hộ guard này muộn hơn.
            self.assertNotIn('RELEASE', self.orchestration_events)

    def test_control_stage_generation_and_missing_proof_fail_closed(self):
        """Không dùng fixture/counter sai hoặc snapshot khác window/stage làm bằng chứng exhaustion."""
        for fault in ('control', 'initial-counter', 'stage', 'generation', 'proof'):
            with self.subTest(fault=fault), self.assertRaises(RuntimeError):
                self.exercise(fault)
            self.assertNotIn('RELEASE', self.orchestration_events)

    def test_late_result_and_failed_recovery_or_stop_cannot_report_success(self):
        """Fresh deadline và stopped-reaped là invariant thật, recovery200 cần delta session/audit đúng."""
        for fault in ('late-result', 'recovery', 'recovery-state', 'stop'):
            with self.subTest(fault=fault), self.assertRaises(RuntimeError):
                self.exercise(fault)
            self.assertLess(len(self.orchestration_checks), 15)


if __name__ == '__main__':
    unittest.main()
