"""Kiểm guard và phục hồi của host display runner bằng boundary giả, không gọi ADB."""

import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

MODULE_PATH = Path(__file__).resolve().parents[2] / 'tool' / 'run_auth_display_test.py'
SPEC = importlib.util.spec_from_file_location('auth_display_runner', MODULE_PATH)
runner_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner_module)


class FakeDevice:
    """Giữ settings trong RAM để phát hiện host ghi sai target hoặc không restore."""

    def __init__(self, avd='Pixel_7'):
        """Khởi tạo target giả và cấu hình gốc để so sánh sau từng error path.

        Input
        Param: avd — tên identity do boundary trả về, cho phép kiểm target không khớp.
        """
        self.avd = avd
        self.settings = {'accelerometer_rotation': '1', 'user_rotation': '0', 'font_scale': '1.0'}
        self.policy = 'free'
        self.writes = []

    def command(self, *args):
        """Mô phỏng đúng các lệnh allowlist của runner; lệnh ngoài scope làm test fail.

        Input
        Param: args — argument ADB mà host muốn thực thi, chỉ xử lý trong RAM.
        Output: metadata hoặc ACK giả của thao tác đã được mô hình hóa.
        """
        if args == ('emu', 'avd', 'name'):
            return self.avd + '\nOK'
        if args == ('shell', 'getprop', 'ro.build.version.sdk'):
            return '36'
        if args[:4] == ('shell', 'settings', 'get', 'system'):
            return self.settings[args[4]]
        if args[:4] == ('shell', 'settings', 'put', 'system'):
            self.writes.append(args)
            self.settings[args[4]] = args[5]
            return ''
        if args[:3] == ('shell', 'wm', 'user-rotation'):
            if len(args) > 3:
                self.writes.append(args)
                self.policy = ' '.join(args[3:])
            return self.policy
        raise AssertionError('Unexpected fake device operation: ' + str(args))


class FakeChild:
    """Cung cấp log terminal giả, không tạo subprocess hoặc tiếp xúc emulator."""

    def __init__(self, *, exit_code=0, width=914.0, ready=True):
        """Tạo output của profile đúng/sai và mã thoát để kiểm acceptance phía host.

        Input
        Param: exit_code — kết quả terminal giả, không đại diện engine thật.
        Param: width — chiều rộng để tạo counterexample portrait dù flow exit0.
        Param: ready — có/không handshake nhằm kiểm admission của profile.
        """
        marker = 'NATIVE_PREVIEW_READY profile=landscape-large-text\n' if ready else ''
        self.stdout = io.StringIO(marker + f'NATIVE_PREVIEW_VIEW width={width} height=411.0 text16=32.0\n')
        self.returncode = exit_code

    def wait(self):
        """Trả kết quả đã kết thúc của fixture, không đợi tiến trình thật."""
        return self.returncode

    def poll(self):
        """Xác nhận fixture luôn terminal để cleanup không chạm PID hệ thống."""
        return self.returncode


class DisplayRunnerTests(unittest.TestCase):
    """Không dùng flow exit0 hoặc tên AVD làm bằng chứng profile nếu metrics sai."""

    def run_case(self, device, child, *, suite='login'):
        """Chạy runner với ADB/process giả và evidence tạm trong thư mục test tự sở hữu.

        Input
        Param: device — boundary cấu hình trong RAM, không ADB thật.
        Param: child — stdout/mã thoát giả, không được dùng PID hệ thống.
        Param: suite — tên suite allowlist cần chạy, không cho đường dẫn tùy ý.
        Output: verdict JSON và argument launch để test kiểm đúng suite/evidence identity.
        """
        with tempfile.TemporaryDirectory() as directory:
            runner = runner_module.DisplayTestRunner(
                device='emulator-5554', expected_avd='Pixel_7',
                profile='landscape-large-text', adb_path='fake-adb',
                flutter_path='fake-flutter', evidence_path=Path(directory) / 'result.json',
                suite=suite,
            )
            with patch.object(runner, 'adb', side_effect=device.command), patch.object(
                runner_module.subprocess, 'Popen', return_value=child
            ) as launch:
                runner.execute()
                return json.loads(runner.evidence_path.read_text(encoding='utf-8')), launch.call_args.args[0]

    def test_routes_workspace_suite_and_records_identity(self):
        """Workspace phải chạy test picker thật và ghi suite riêng, không gắn bằng chứng login sang picker."""
        report, arguments = self.run_case(FakeDevice(), FakeChild(), suite='workspace')
        self.assertIn('integration_test/workspace_preview_test.dart', arguments)
        self.assertNotIn('integration_test/auth_preview_test.dart', arguments)
        self.assertEqual(report['suite'], 'workspace')
        self.assertEqual(report['testTarget'], 'integration_test/workspace_preview_test.dart')

    def test_rejects_unsupported_suite_before_launch(self):
        """Đường dẫn hoặc suite ngoài allowlist không được thực thi như Flutter target tùy ý."""
        with self.assertRaisesRegex(ValueError, 'suite'):
            self.run_case(FakeDevice(), FakeChild(), suite='../other_test.dart')

    def test_routes_password_suite_and_records_identity(self):
        """Password phải chạy đúng limited-form target, không dùng log login/picker để nhận bằng chứng."""
        report, arguments = self.run_case(FakeDevice(), FakeChild(), suite='password')
        self.assertIn('integration_test/password_change_preview_test.dart', arguments)
        self.assertNotIn('integration_test/auth_preview_test.dart', arguments)
        self.assertNotIn('integration_test/workspace_preview_test.dart', arguments)
        self.assertEqual(report['suite'], 'password')
        self.assertEqual(report['testTarget'], 'integration_test/password_change_preview_test.dart')

    def test_rejects_other_target_before_mutation(self):
        """AVD không khớp phải bị chặn trước mọi setting write hoặc launch test."""
        device = FakeDevice('Another_AVD')
        with self.assertRaisesRegex(RuntimeError, 'target'):
            self.run_case(device, FakeChild())
        self.assertEqual(device.writes, [])

    def test_profile_success_restores_original_configuration(self):
        """Profile đúng được nhận khi handshake/metrics cùng khớp và cuối lượt restore gốc."""
        device = FakeDevice()
        original = dict(device.settings)
        self.run_case(device, FakeChild())
        self.assertEqual(device.settings, original)
        self.assertEqual(device.policy, 'free')
        self.assertIn(('shell', 'wm', 'user-rotation', 'lock', '1'), device.writes)

    def test_flutter_failure_still_restores_configuration(self):
        """Flutter fail không được bỏ finally hoặc biến bài test thành PASS."""
        device = FakeDevice()
        original = dict(device.settings)
        with self.assertRaisesRegex(RuntimeError, 'Flutter'):
            self.run_case(device, FakeChild(exit_code=1))
        self.assertEqual(device.settings, original)
        self.assertEqual(device.policy, 'free')

    def test_portrait_metrics_cannot_pass_landscape(self):
        """Exit0 với engine portrait vẫn bị từ chối và restore nguyên settings."""
        device = FakeDevice()
        with self.assertRaisesRegex(RuntimeError, 'metrics'):
            self.run_case(device, FakeChild(width=300.0))
        self.assertEqual(device.policy, 'free')
        self.assertEqual(device.settings['font_scale'], '1.0')

    def test_missing_handshake_cannot_pass(self):
        """Không READY thì metrics giả trông đúng cũng không được mở admission profile."""
        device = FakeDevice()
        with self.assertRaisesRegex(RuntimeError, 'handshake'):
            self.run_case(device, FakeChild(ready=False))
        self.assertNotIn(('shell', 'wm', 'user-rotation', 'lock', '1'), device.writes)

    def test_restore_failure_cannot_report_success(self):
        """Flow/metrics đúng nhưng cleanup chưa xác minh phải trả lỗi rõ, không PASS tổng."""
        with patch.object(runner_module.DisplayTestRunner, 'restore', side_effect=RuntimeError('target changed')):
            with self.assertRaisesRegex(RuntimeError, 'restoration unverified'):
                self.run_case(FakeDevice(), FakeChild())


if __name__ == '__main__':
    unittest.main()
