"""Kiểm pool exhaustion qua TCP thật; private stdin chỉ điều khiển owned lab child."""

import queue
import threading
import time

from verify_audit_faults import read_snapshot
from verify_lock_budget import healthy_login, validate_unavailable
from verify_measurements import begin_window, measurement_control
from verify_provider import expect
from verify_user_fence import login_request


def validate_pool_snapshot(value, generation):
    """Kiểm snapshot exact1pool/error gần5s để không dùng closed pool làm timeout evidence.

    Input
    Param: value — snapshot bounded từ control của cùng process.
    Param: generation — generation đã nhận từ begin.
    Output: snapshot enum/numeric hợp lệ; Errors: dữ liệu sai bị từ chối generic.
    """
    if (type(value) is not dict
            or set(value) != {'windowId', 'valid', 'droppedSamples', 'staleSamples', 'poisoned', 'samples'}
            or type(generation) is not int or not 0 < generation < 2**64
            or type(value['windowId']) is not int or value['windowId'] != generation
            or value['valid'] is not True or value['poisoned'] is not False
            or type(value['droppedSamples']) is not int or value['droppedSamples'] != 0
            or type(value['staleSamples']) is not int or value['staleSamples'] != 0
            or type(value['samples']) is not list or len(value['samples']) != 1):
        raise RuntimeError('Invalid pool budget snapshot')
    sample = value['samples'][0]
    if (type(sample) is not dict or set(sample) != {'stage', 'outcome', 'elapsedUs'}
            or sample['stage'] != 'pool_acquire' or sample['outcome'] != 'error'
            or type(sample['elapsedUs']) is not int or not 4_900_000 <= sample['elapsedUs'] <= 7_000_000):
        raise RuntimeError('Invalid pool acquire error sample')
    return value


class PoolBudgetChild:
    """Sở hữu protocol của Popen đã READY; không tạo process hoặc I/O trong constructor."""

    def __init__(self, process, stop_process):
        """Ghi nhận ownership để mọi protocol failure đều thu hồi đúng child trước cleanup.

        Input
        Param: process — Popen special child đã READY và đăng ký ở launcher.
        Param: stop_process — callback terminate/reap đúng handle, không nhận PID ngoài.
        """
        self.process = process
        self.stop_process = stop_process
        self.phase = 'READY'
        self.reader = None
        self.stopped = False

    def _read_ack(self, replies):
        """Đọc một frame bounded ngoài caller để ACK mất không treo test vô hạn.

        Input
        Param: replies — queue1 thuộc command hiện tại, chỉ nhận literal hoặc None khi pipe lỗi.
        Side effects: đọc stdout owned child, không echo marker lạ hoặc raw exception.
        """
        try:
            line = self.process.stdout.readline(65)
            if len(line) > 64 or not line.endswith('\n'):
                replies.put_nowait(None)
            else:
                replies.put_nowait(line[:-2] if line.endswith('\r\n') else line[:-1])
        except (OSError, ValueError):
            replies.put_nowait(None)

    def _abort(self):
        """Thu hồi exact child trước join reader khi protocol thất bại, không ghi graceful PASS.

        Errors: child hoặc reader chưa thu hồi được làm fail cleanup, không mở normal processes tiếp.
        """
        self.phase = 'FAILED'
        try:
            self.process.stdin.close()
        except (OSError, ValueError):
            pass  # Pipe đã hỏng vẫn phải reap đúng child trước khi chờ stdout reader.
        self.stop_process(self.process)
        if self.reader is not None:
            self.reader.join(timeout=5)
            if self.reader.is_alive():
                raise RuntimeError('Pool budget reader shutdown unverified')
        self.stopped = True

    def command(self, literal):
        """Gửi command allowlist rồi kiểm ACK/order/deadline không reset.

        Input
        Param: literal — HOLD/CHECK_HELD/RELEASE/STOP nội bộ.
        Output: ACK literal; Errors: protocol sai/timeout đều FAIL và thu hồi child.
        """
        transitions = {('READY', 'HOLD'): ('HELD', 'POOL_HELD|8'),
                       ('HELD', 'CHECK_HELD'): ('HELD', 'POOL_STILL_HELD|8'),
                       ('HELD', 'RELEASE'): ('RELEASED', 'POOL_RELEASED|8')}
        try:
            if literal == 'STOP' and self.phase in ('READY', 'HELD', 'RELEASED'):
                next_phase, expected = 'STOPPED', 'POOL_STOPPED'
            else:
                next_phase, expected = transitions[(self.phase, literal)]
            if self.process.poll() is not None:
                raise RuntimeError('Pool budget child exited early')
            # Deadline bao cả write/flush/read/join, không reset khi stdout reader hoàn tất muộn.
            deadline = time.monotonic() + (12.0 if literal == 'HOLD' else 8.0 if literal == 'STOP' else 5.0)
            replies = queue.Queue(maxsize=1)
            self.reader = threading.Thread(target=self._read_ack, args=(replies,))
            self.reader.start()
            self.process.stdin.write(literal + '\n')
            self.process.stdin.flush()
            if literal == 'STOP':
                self.process.stdin.close()
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError('Pool budget command deadline exceeded')
            reply = replies.get(timeout=remaining)
            if time.monotonic() >= deadline or reply != expected:
                raise RuntimeError('Pool budget acknowledgment invalid')
            self.reader.join(timeout=max(0, deadline - time.monotonic()))
            if self.reader.is_alive() or time.monotonic() >= deadline:
                raise RuntimeError('Pool budget acknowledgment arrived late')
            self.phase = next_phase
            return reply
        except BaseException:
            self._abort()
            raise RuntimeError('Pool budget command failed') from None

    def stop(self):
        """Dừng và reap owned child; chỉ success khi STOPPED rồi exit0 trong cận."""
        if self.stopped:
            return
        try:
            if self.phase != 'STOPPED':
                self.command('STOP')
            deadline = time.monotonic() + 5.0
            code = self.process.wait(timeout=5.0)
            if code != 0 or self.process.poll() != 0 or time.monotonic() >= deadline:
                raise RuntimeError('Pool budget child shutdown unverified')
            self.stopped = True
        except BaseException:
            if not self.stopped:
                self._abort()
            raise RuntimeError('Pool budget stop failed') from None


def verify_pool_budget(child, port, emails, password, user_ids, digests, key, checks):
    """Chạy control→held8→hai503/windows→release→recovery trên cùng pool/router.

    Input
    Param: child — protocol owner của process đã READY, luôn stop trong finally.
    Param: port — loopback TCP listener của chính child.
    Param: emails — năm email synthetic, chỉ account3 dùng cho nhánh pool.
    Param: password — TEST credential chỉ RAM, không export response.
    Param: user_ids — identity fixture để kiểm control/recovery và scoped readback.
    Param: digests — HMAC fixture chỉ dùng scoped read_snapshot, không ghi evidence.
    Param: key — capability recorder của đúng child.
    Param: checks — nơi append invariant IDs tĩnh, không selector hoặc credential.
    Output: hai observations enum/numeric; Errors: bất kỳ invariant sai đều FAIL.
    Side effects: thêm control/recovery sessions; dừng/reap child trước bàn giao normal suite.
    """
    observations, correlations = [], []
    try:
        for client in ('WEB', 'ANDROID'):
            control = login_request(port, emails[3], password, client)
            expect(healthy_login(control, client, user_ids[3]), 'pool-budget-' + client.lower() + '-control', checks)
        before = read_snapshot(user_ids[3], digests[3])
        if before[2] != 0:
            raise RuntimeError('Pool budget fixture counter is not fresh')
        expect(child.command('HOLD') == 'POOL_HELD|8', 'pool-budget-held-eight', checks)
        previous = 0
        for client in ('WEB', 'ANDROID'):
            prefix = 'pool-budget-' + client.lower()
            previous = begin_window(port, key, previous)
            # Chỉ chấp nhận response trong8s; request helper giữ watchdog20s, không claim total shutdown8s.
            deadline = time.monotonic() + 8.0
            response = login_request(port, emails[3], password, client)
            if time.monotonic() >= deadline:
                raise RuntimeError('Pool budget HTTP result arrived late')
            correlations.append(validate_unavailable(response))
            expect(True, prefix + '-safe-unavailable', checks)
            snapshot = validate_pool_snapshot(measurement_control(port, 'end', key), previous)
            expect(True, prefix + '-stages', checks)
            # Proof sau cả HTTP và end: vector vẫn8leases; chưa RELEASE hoặc đóng pool để tạo503 giả.
            expect(child.command('CHECK_HELD') == 'POOL_STILL_HELD|8', prefix + '-held-after-end', checks)
            after = read_snapshot(user_ids[3], digests[3], correlations)
            expect(after[:3] == before[:3] and after[3] == 0, prefix + '-committed-unchanged', checks)
            observations.append({'clientType': client, 'heldConnections': 8, 'heldAfterEnd': True,
                                 'committedStateUnchanged': True, 'snapshot': snapshot})
        expect(child.command('RELEASE') == 'POOL_RELEASED|8', 'pool-budget-released-eight', checks)
        for observation in observations:
            client = observation['clientType']
            recovery = login_request(port, emails[3], password, client)
            recovered = read_snapshot(user_ids[3], digests[3], correlations)
            expect(healthy_login(recovery, client, user_ids[3])
                   and recovered[:2] == (before[0] + 1, before[1] + 1)
                   and recovered[2] == before[2] and recovered[3] == 0,
                   'pool-budget-' + client.lower() + '-recovered', checks)
            before = recovered
            observation['recoveredOnSamePool'] = True
    finally:
        child.stop()
    expect(True, 'pool-budget-stopped-reaped', checks)
    return observations
