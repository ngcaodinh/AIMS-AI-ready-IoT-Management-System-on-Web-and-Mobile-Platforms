"""Kiểm completeness và percentile của baseline; fixture chỉ tổng hợp, không thay provider evidence."""

from copy import deepcopy
import ast
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_measurement_baseline as baseline
from verify_measurements import STAGES
import verify_measurements as measurements


class BaselineSummaryTests(unittest.TestCase):
    """Không cho percentile hợp lệ che mất một process/batch hoặc stage."""

    def windows(self):
        """Tạo20window đủ540samples, mỗi group15giá trị phân biệt để bắt off-by-one percentile.

        Output: snapshot tổng hợp với generation tăng và coverage2topology×5batch×2process.
        """
        windows = []
        for topology_index, topology in enumerate(('same_key', 'multi_key')):
            for batch in range(1, 6):
                for process_index, process in enumerate(('primary', 'peer')):
                    # Offset tách group để percentile không thể trộn stage/process/topology mà vẫn khớp vector.
                    windows.append({'topology': topology, 'batch': batch, 'process': process,
                                    'windowId': 2 + topology_index * 5 + batch,
                                    'valid': True, 'poisoned': False, 'droppedSamples': 0, 'staleSamples': 0,
                                    'samples': [{'stage': stage, 'outcome': 'completed',
                                                 'elapsedUs': topology_index * 100000 + process_index * 10000
                                                 + stage_index * 1000000 + 100 * (3 * (batch - 1) + index + 1)}
                                                for stage_index, stage in enumerate(STAGES) for index in range(3)]})
        return windows

    def test_nearest_rank_uses_all_fifteen_samples_per_group(self):
        """Vector15/group phân biệt cho p50=mẫu8/p95=mẫu15; offset riêng bắt trộn stage/process/topology."""
        summaries = baseline.summarize_baseline(self.windows())
        self.assertEqual(len(summaries), 36)
        self.assertEqual(len({(x['topology'], x['process'], x['stage']) for x in summaries}), 36)
        for summary in summaries:
            self.assertEqual(summary['outcome'], 'completed')
            offset = (100000 if summary['topology'] == 'multi_key' else 0)
            offset += 10000 if summary['process'] == 'peer' else 0
            offset += STAGES.index(summary['stage']) * 1000000
            self.assertEqual((summary['samples'], summary['p50Us'], summary['p95Us'], summary['maxUs']),
                             (15, offset + 800, offset + 1500, offset + 1500))

    def test_missing_or_duplicate_window_cannot_create_summary(self):
        """Giữ nguyên len20 nhưng duplicate coverage vẫn phải FAIL, cũng như mất hẳn window."""
        windows = self.windows()
        duplicate = deepcopy(windows)
        duplicate[1] = deepcopy(duplicate[0])
        # Chỉ duplicate coverage, giữ generation tăng và15mẫu/group; guard khác không được che test identity.
        duplicate_coverage = deepcopy(windows)
        duplicate_coverage[2]['batch'] = duplicate_coverage[0]['batch']
        for variant in (windows[:-1], duplicate, duplicate_coverage):
            with self.assertRaises(RuntimeError):
                baseline.summarize_baseline(variant)

    def test_invalid_stage_distribution_or_generation_is_rejected(self):
        """Đủ27mẫu nhưng trùng stage hoặc generation không tăng không được đưa vào percentile."""
        for kind in ('distribution', 'generation', 'invalid', 'outcome'):
            windows = self.windows()
            if kind == 'distribution':
                windows[0]['samples'][0]['stage'] = STAGES[1]
            elif kind == 'generation':
                windows[2]['windowId'] = windows[0]['windowId']
            elif kind == 'invalid':
                windows[0]['droppedSamples'] = 1
            else:
                windows[0]['samples'][0]['outcome'] = 'abandoned'
            with self.subTest(kind=kind), self.assertRaises(RuntimeError):
                baseline.summarize_baseline(windows)


class BaselineCancellationTests(unittest.TestCase):
    """Thực thi handler thật trong sandbox AST để kiểm cancellation mà không import launcher hoặc chạm DB."""

    def exercise(self, verify):
        """Đặt actual handler trong try/finally tổng hợp, quan sát cleanup và bước ghi report kế tiếp.

        Input
        Param: verify — chế độ verify phải lỗi; interactive giữ Ctrl+C kết thúc thường.
        Output: outcome và events phi bí mật; chỉ chứng minh control flow handler, không full launcher lifecycle.
        """
        source = ast.parse((Path(__file__).resolve().parents[1] / 'run_local.py').read_text(encoding='utf-8'))
        run = next(node for node in source.body if isinstance(node, ast.FunctionDef) and node.name == 'run')
        handler = next(node for node in ast.walk(run) if isinstance(node, ast.ExceptHandler)
                       and isinstance(node.type, ast.Name) and node.type.id == 'KeyboardInterrupt')
        probe = ast.parse("try:\n raise KeyboardInterrupt\nexcept KeyboardInterrupt:\n pass\nfinally:\n events.append('cleanup')\nevents.append('report')")
        probe.body[0].handlers = [deepcopy(handler)]
        state = {'verify': verify, 'events': []}
        outcome = 'returned'
        try:
            exec(compile(ast.fix_missing_locations(probe), '<owned-cancellation-probe>', 'exec'), state)
        except RuntimeError:
            outcome = 'failed'
        return outcome, state['events']

    def test_cancelled_verification_cleans_up_and_cannot_write_success(self):
        """Hủy verify phải propagate lỗi sau finally, không chạy bước ghi report như thành công."""
        self.assertEqual(self.exercise(True), ('failed', ['cleanup']))

    def test_interactive_ctrl_c_remains_normal_shutdown(self):
        """Interactive không bị đổi thành failure chỉ vì người dùng chủ động dừng lab."""
        self.assertEqual(self.exercise(False), ('returned', ['cleanup', 'report']))


class BaselineOrchestrationTests(unittest.TestCase):
    """Kiểm window bao quanh đúng6login, generation riêng và response không rò vào baseline."""

    def exercise(self, fault=None):
        """Chạy baseline với hai recorder/HTTP fake có state thay vì DB để kiểm completeness.

        Input
        Param: fault — nhánh HTTP/count/generation lỗi tổng hợp;None cho đủ60login.
        Output: report/checks/jobs hoặc RuntimeError; không có provider/session thật.
        """
        generations = {3001: 2, 3002: 7}
        active = set()
        batches = []

        def control(port, action, _key):
            """Giữ active/generation theo process để phát hiện begin/end sai thứ tự.

            Input
            Param: port — listener synthetic của một trong hai recorder.
            Param: action — begin/end chỉ được gọi đúng trạng thái.
            Param: _key — capability synthetic không xuất ra report.
            Output: generation hoặc27stage hợp lệ, trừ fault thiếu mẫu được chỉ định.
            """
            if action == 'begin':
                self.assertNotIn(port, active)
                active.add(port)
                generations[port] += 1
                return {'windowId': generations[port] if fault != 'generation' else 1}
            self.assertIn(port, active)
            active.remove(port)
            samples = [{'stage': stage, 'outcome': 'completed', 'elapsedUs': 100}
                       for stage in STAGES for _ in range(3)]
            if fault == 'count':
                samples.pop()
            return {'windowId': generations[port], 'valid': True, 'poisoned': False,
                    'droppedSamples': 0, 'staleSamples': 0, 'samples': samples}

        def batch(jobs):
            """Chỉ cho batch chạy khi cả hai window mở; giữ jobs trong RAM để test phân bố account.

            Input
            Param: jobs — sáu credential synthetic do orchestrator chọn, không ghi evidence.
            Output: sáu response thành công hoặc fault một response, không gọi network.
            """
            self.assertEqual(active, {3001, 3002})
            batches.append(jobs)
            responses = [(200, {}, {'token': 'synthetic-private-token', 'limited': False}, 1.0) for _ in jobs]
            if fault == 'status':
                responses[0] = (503, {}, {}, 1.0)
            elif fault == 'cookie':
                responses[0] = (200, {'Set-Cookie': 'synthetic-private-cookie'}, responses[0][2], 1.0)
            elif fault == 'token':
                responses[0] = (200, {}, {'token': '', 'limited': False}, 1.0)
            elif fault == 'limited':
                responses[0] = (200, {}, {'token': 'synthetic-private-token', 'limited': True}, 1.0)
            elif fault == 'token-type':
                responses[0] = (200, {}, {'token': ['synthetic-private-token'], 'limited': False}, 1.0)
            elif fault == 'body':
                responses[0] = (200, {}, None, 1.0)
            elif fault == 'responses':
                responses.pop()
            return responses

        checks = []
        emails = [f'synthetic-private-email-{index}' for index in range(5)]
        with patch.object(measurements, 'measurement_control', side_effect=control), \
                patch.object(baseline, 'measurement_control', side_effect=control), \
                patch.object(baseline, 'concurrent_batch', side_effect=batch):
            report = baseline.verify_measurement_baseline(3001, 3002, emails, 'synthetic-private-password',
                                                          b'x' * 32, {'primary': 2, 'peer': 7}, checks)
        self.assertFalse(active)
        return report, checks, batches

    def test_sixty_successes_have_exact_process_account_distribution(self):
        """Mỗi batch3request/process; same-key dùng account0, multi-key mỗi process đủ0/3/4."""
        report, checks, batches = self.exercise()
        self.assertEqual(len(batches), 10)
        self.assertEqual(len(checks), 10)
        self.assertEqual(len(report['windows']), 20)
        self.assertEqual(sum(len(w['samples']) for w in report['windows']), 540)
        self.assertEqual(len(report['summaries']), 36)
        for index, jobs in enumerate(batches):
            self.assertEqual(len(jobs), 6)
            for port in (3001, 3002):
                actual = sorted(email for listener, email, _ in jobs if listener == port)
                expected = ['synthetic-private-email-0'] * 3 if index < 5 else [
                    'synthetic-private-email-0', 'synthetic-private-email-3', 'synthetic-private-email-4']
                self.assertEqual(actual, expected)
        for value in ('synthetic-private-email', 'synthetic-private-password', 'synthetic-private-token'):
            self.assertNotIn(value, json.dumps(report))

    def test_bad_http_or_window_never_exports_baseline(self):
        """HTTP hoặc snapshot sai phải FAIL toàn phép đo; không retry hoặc xuất partial percentile."""
        for fault in ('status', 'cookie', 'token', 'token-type', 'body', 'limited', 'responses', 'count', 'generation'):
            with self.subTest(fault=fault), self.assertRaises(RuntimeError):
                self.exercise(fault)


if __name__ == '__main__':
    unittest.main()
