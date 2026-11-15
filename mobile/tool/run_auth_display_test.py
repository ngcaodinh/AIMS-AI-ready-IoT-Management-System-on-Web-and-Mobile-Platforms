"""Phối hợp ADB và Flutter để kiểm display thật sau app-start, không đọc OS environment."""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import sys
import time

MOBILE_ROOT = Path(__file__).resolve().parents[1]
TARGETS = {'Nexa_Auth_API24': '24', 'Pixel_7': '36'}
SUITES = {'login': 'integration_test/auth_preview_test.dart',
          'workspace': 'integration_test/workspace_preview_test.dart',
          'password': 'integration_test/password_change_preview_test.dart'}
SETTINGS = ('accelerometer_rotation', 'user_rotation', 'font_scale')
METRICS = re.compile(r'NATIVE_PREVIEW_VIEW width=([0-9.]+) height=([0-9.]+) text16=([0-9.]+)')


class DisplayTestRunner:
    """Chỉ tác động display của đúng AVD lab; kết quả phải có handshake, metrics và cleanup."""

    def __init__(self, *, device, expected_avd, profile, adb_path, flutter_path, evidence_path, suite='login'):
        """Nhận target/tool paths và profile tường minh để không tra biến môi trường hoặc đoán thiết bị.

        Input
        Param: device — serial emulator đã chọn, không hỗ trợ thiết bị thật.
        Param: expected_avd — một trong hai AVD lab có SDK được pin.
        Param: profile — portrait hoặc landscape-large-text phải được engine chứng minh.
        Param: adb_path — executable chính thức do operator cấu hình.
        Param: flutter_path — Flutter đã pin, không tải hoặc upgrade SDK.
        Param: evidence_path — file JSON cho riêng lượt chạy; log dùng cùng stem.
        Param: suite — login/workspace/password theo allowlist, không nhận path từ nội dung bên ngoài.
        """
        if not re.fullmatch(r'emulator-[0-9]+', device) or expected_avd not in TARGETS:
            raise ValueError('Unsupported lab target')
        if profile not in ('portrait', 'landscape-large-text'):
            raise ValueError('Unsupported display profile')
        if suite not in SUITES:
            raise ValueError('Unsupported preview suite')
        self.device = device
        self.expected_avd = expected_avd
        self.profile = profile
        self.adb_path = adb_path
        self.flutter_path = flutter_path
        self.evidence_path = Path(evidence_path)
        self.suite = suite

    def adb(self, *args):
        """Gọi đúng serial và trả stdout của lệnh allowlist nội bộ; lỗi không được xem như setting rỗng.

        Input
        Param: args — các argument riêng biệt, không shell interpolation hoặc credential.
        Output: metadata/settings thuộc AVD lab; không đọc toàn bộ properties/environment.
        """
        result = subprocess.run(
            [self.adb_path, '-s', self.device, *args], capture_output=True,
            text=True, encoding='utf-8', errors='replace', timeout=15,
        )
        if result.returncode:
            raise RuntimeError('ADB operation failed: ' + ' '.join(args[:4]))
        return result.stdout.strip()

    def verify_target(self):
        """Xác minh cả AVD và SDK trước mutation/restore để không ghi sang target vừa thay thế.

        Output: API level dạng chuỗi của đúng AVD lab đã pin.
        """
        name = self.adb('emu', 'avd', 'name').splitlines()[0]
        sdk = self.adb('shell', 'getprop', 'ro.build.version.sdk')
        if name != self.expected_avd or sdk != TARGETS[self.expected_avd]:
            raise RuntimeError('Lab target identity changed or mismatched')
        return sdk

    def apply_profile(self, sdk):
        """Đổi display chỉ sau READY của app để tránh policy portrait trong giai đoạn launch.

        Input
        Param: sdk — API đã kiểm từ target, API24 dùng settings vì chưa có WM user-rotation.
        """
        rotation, scale = ('0', '1.0') if self.profile == 'portrait' else ('1', '2.0')
        for key, value in zip(SETTINGS, ('0', rotation, scale)):
            self.adb('shell', 'settings', 'put', 'system', key, value)
        if sdk == '36':
            self.adb('shell', 'wm', 'user-rotation', 'lock', rotation)

    def restore(self, original, policy, sdk):
        """Khôi phục đúng giá trị đã capture và đọc lại từng key; không suy cleanup từ exit0.

        Input
        Param: original — đúng ba setting của lượt hiện hành, không import journal cũ.
        Param: policy — free/lock đã xác minh của display0, None cho API24.
        Param: sdk — SDK dùng để chọn giao diện WM đã có trên target.
        Output: danh sách kết quả từng setting/policy để báo cleanup chưa xác minh nếu có lỗi.
        """
        self.verify_target()
        results = []
        if sdk == '36':
            self.adb('shell', 'wm', 'user-rotation', *policy.split())
        for key, expected in original.items():
            actual = None
            for attempt in range(3):
                # SettingsProvider có thể chuẩn hóa font null thành1.0 ở frame sau; xóa lại đúng key đã sở hữu.
                if expected == 'null':
                    self.adb('shell', 'settings', 'delete', 'system', key)
                else:
                    self.adb('shell', 'settings', 'put', 'system', key, expected)
                time.sleep(0.2)
                actual = self.adb('shell', 'settings', 'get', 'system', key)
                if actual == expected:
                    break
            results.append({'key': key, 'expected': expected, 'actual': actual, 'verified': actual == expected})
        if sdk == '36':
            actual = self.adb('shell', 'wm', 'user-rotation')
            results.append({'key': 'wm user-rotation', 'expected': policy, 'actual': actual, 'verified': actual == policy})
        return results

    def stop_owned_child(self, child):
        """Khi bị ngắt chỉ dừng cây tiến trình vừa tạo, không kill ADB server/emulator hoặc PID từ journal.

        Input
        Param: child — handle Popen của chính lượt này, chỉ dùng PID nếu còn live qua poll.
        """
        if child.poll() is None:
            if sys.platform == 'win32':
                subprocess.run(['taskkill', '/PID', str(child.pid), '/T', '/F'], capture_output=True, check=True)
            else:
                child.terminate()
            child.wait()

    def execute(self):
        """Chạy flow mock trên engine thật và lưu verdict/cleanup ngay cả khi Flutter/profile lỗi.

        Errors: sai target, thiếu READY, flow lỗi, metrics sai hoặc restore chưa xác minh đều không được PASS.
        Side effects: cài/chạy test APK của app lab, đổi tạm display và ghi evidence không secret.
        """
        sdk = self.verify_target()
        original = {key: self.adb('shell', 'settings', 'get', 'system', key) for key in SETTINGS}
        if not all(value == 'null' or re.fullmatch(r'[0-9]+(?:\.[0-9]+)?', value) for value in original.values()):
            raise RuntimeError('Unexpected display setting; no mutation')
        policy = self.adb('shell', 'wm', 'user-rotation') if sdk == '36' else None
        if policy is not None and not re.fullmatch(r'free|lock [0-3]', policy):
            raise RuntimeError('Unexpected WindowManager policy; no mutation')
        report = {'device': self.device, 'avd': self.expected_avd, 'api': sdk, 'profile': self.profile,
                  'suite': self.suite, 'testTarget': SUITES[self.suite],
                  'originalSettings': original, 'originalPolicy': policy, 'profileVerified': False}
        self.evidence_path.parent.mkdir(parents=True, exist_ok=True)
        child = None
        try:
            child = subprocess.Popen([
                self.flutter_path, 'test', '--no-pub', '--no-uninstall',
                SUITES[self.suite], '-d', self.device,
                '--dart-define=NEXA_PREVIEW_DISPLAY_PROFILE=' + self.profile,
            ], cwd=MOBILE_ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, encoding='utf-8', errors='replace')
            output = []
            handshakes = 0
            with self.evidence_path.with_suffix('.txt').open('w', encoding='utf-8') as log:
                for line in child.stdout:
                    safe = re.sub(r'(?:https?|wss?)://\S+', '[debug URL redacted]', line)
                    log.write(safe)
                    log.flush()
                    print(safe.rstrip(), flush=True)
                    output.append(safe)
                    if 'NATIVE_PREVIEW_READY profile=' in safe:
                        if safe.strip() != 'NATIVE_PREVIEW_READY profile=' + self.profile or handshakes:
                            raise RuntimeError('Unexpected display handshake')
                        handshakes += 1
                        self.verify_target()
                        self.apply_profile(sdk)
                report['flutterExit'] = child.wait()
            if report['flutterExit'] != 0:
                raise RuntimeError('Flutter display flow failed')
            if handshakes != 1:
                raise RuntimeError('Missing display handshake')
            match = METRICS.search(''.join(output))
            if match is None:
                raise RuntimeError('Missing engine metrics')
            width, height, text = map(float, match.groups())
            positive_size = width > 0 and height > 0
            valid = width < height and abs(text - 16) < 0.5 if self.profile == 'portrait' else width > height and text >= 25
            if not positive_size or not valid or 'would not hit test' in ''.join(output):
                raise RuntimeError('Engine metrics or pointer verification failed')
            report.update(profileVerified=True, width=width, height=height, text16=text)
        finally:
            child_stopped = True
            if child is not None:
                try:
                    self.stop_owned_child(child)
                except Exception:
                    child_stopped = False
                finally:
                    child.stdout.close()
            try:
                report['restoration'] = self.restore(original, policy, sdk)
                report['restorationVerified'] = child_stopped and all(item['verified'] for item in report['restoration'])
            except Exception:
                # Không ghi exception thô từ tool/process; operator vẫn thấy cleanup cần kiểm từ verdict cố định.
                report['restorationVerified'] = False
            self.evidence_path.write_text(json.dumps(report, indent=2), encoding='utf-8')
            if not report['restorationVerified']:
                raise RuntimeError('Display restoration unverified; inspect owned target')
        print('PASS native mock profile; restoration verified. Evidence: ' + str(self.evidence_path), flush=True)


def main():
    """Nhận CLI config tường minh và chạy đúng một profile; không đọc .env, OS environment hoặc dependency folders."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--avd', required=True, choices=TARGETS)
    parser.add_argument('--profile', required=True, choices=('portrait', 'landscape-large-text'))
    parser.add_argument('--suite', default='login', choices=SUITES)
    parser.add_argument('--adb', default=r'C:\Users\LENOVO\AppData\Local\Android\sdk\platform-tools\adb.exe')
    parser.add_argument('--flutter', default=r'C:\src\flutter\bin\flutter.bat')
    args = parser.parse_args()
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    evidence = MOBILE_ROOT.parent / 'docs/test-reports/evidence' / f'android-display-{args.suite}-{args.avd}-{args.profile}-{stamp}.json'
    DisplayTestRunner(device=args.device, expected_avd=args.avd, profile=args.profile,
                      adb_path=args.adb, flutter_path=args.flutter, evidence_path=evidence, suite=args.suite).execute()


if __name__ == '__main__':
    main()
