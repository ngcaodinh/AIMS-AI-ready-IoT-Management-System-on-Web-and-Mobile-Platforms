"""Actual B1b diagnostic: original shim/launcher, positive bucket delta and terminal cleanup.

Credentials stay in parent/child RAM and private stdin. The only instrumentation is a
read-only projection at SNAPSHOT and a pending-STOP barrier before backend spawn.
This is not an Android/UI E2E test and does not enable the native rate CLI.
"""

import json
import queue
import secrets
import subprocess
import sys
import threading
import time
from pathlib import Path
from uuid import UUID

import native_lab_fixture as fixture
from verify_provider import header, request

ROOT = Path(__file__).resolve().parents[2]
KEYS = {'role', 'hba', 'users', 'sessions', 'workspaces', 'memberships', 'auditActor', 'limiterBuckets'}


def require(condition):
    """Never include packet, HTTP response, SQL output or child stderr in failures."""
    if not condition:
        raise RuntimeError('NATIVE_BUCKET_DIAGNOSTIC_FAILED')


def instrumented_child(pending):
    """Run original main; intercept read-only snapshots without changing mutation/cleanup."""
    original = fixture.NativeFixtureControl

    class DiagnosticControl(original):
        def start_lab(self, config, pool_budget=False):
            if pending:
                # The actual command reader must consume STOP before original handoff.
                require(self.stopping.wait(30))
                self.emit({'kind': 'PENDING_STOP_OBSERVED'})
            return super().start_lab(config, pool_budget)

        def snapshot(self, scope='full'):
            rows = super().snapshot(scope)
            with self.lock:
                require(self._cleanup_scope is not None and not self.stopping.is_set())
                users, digests = self._cleanup_scope
            result = fixture.launcher.lab.sql(
                fixture.CLEANUP_READBACK_SQL, role=fixture.launcher.lab.ADMIN,
                database=fixture.launcher.DATABASE, check=False,
                variables=(('auth_fault_correlations', ','.join(users)),
                           ('auth_lab_bucket_digests', ','.join(digests))))
            require(result.returncode == 0)
            counts = json.loads(result.stdout.strip())
            require(isinstance(counts, dict) and set(counts) == KEYS
                    and all(type(value) is int and value >= 0 for value in counts.values()))
            self.emit({'kind': 'BUCKET_READBACK', 'counts': counts})
            return rows

    fixture.NativeFixtureControl = DiagnosticControl
    original_argv = sys.argv
    try:
        sys.argv = [original_argv[0]]
        fixture.main()
    finally:
        sys.argv = original_argv
        fixture.NativeFixtureControl = original


class OwnedDiagnostic:
    """Bound output, keep actual child ownership through observer timeout and STOP."""
    def __init__(self, pending):
        self.password = 'Aa1' + secrets.token_hex(16)
        self.wrong_password = 'Aa2' + secrets.token_hex(16)
        self.events = queue.Queue(maxsize=32)
        self.invalid = threading.Event()
        self.pending = pending
        self.child = subprocess.Popen(
            [sys.executable, '-X', 'utf8', '-B', str(Path(__file__).resolve()),
             '--pending-child' if pending else '--child'],
            cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.readers = [threading.Thread(target=self.read, args=(stream, is_error), daemon=True)
                        for stream, is_error in [(self.child.stdout, False), (self.child.stderr, True)]]
        for reader in self.readers:
            reader.start()
        self.stopped = None
        self.stop_sent = False

    def read(self, stream, is_error):
        """Discard all raw text; public schema only is queued, secrets never forwarded."""
        total = 0
        try:
            while raw := stream.readline(16385):
                total += len(raw)
                if total > 16384 or is_error or any(secret.encode() in raw for secret in
                                                    (self.password, self.wrong_password)):
                    self.invalid.set()
                    continue
                frame = json.loads(raw)
                require(isinstance(frame, dict))
                self.events.put_nowait(frame)
        except (ValueError, RuntimeError, queue.Full, OSError):
            self.invalid.set()

    def send(self, value):
        self.child.stdin.write(value)
        self.child.stdin.flush()

    def start(self):
        packet = json.dumps({'version': 1, 'password': self.password}).encode() + b'\n'
        if self.pending:
            packet += b'STOP\n'
            self.stop_sent = True
        self.send(packet)

    def frame(self, kind, timeout=900):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            require(not self.invalid.is_set())
            try:
                frame = self.events.get(timeout=min(0.25, max(0.001, deadline - time.monotonic())))
            except queue.Empty:
                if self.child.poll() is None:
                    continue
                # Exit can arrive before the pipe readers publish the final buffered frame.
                for reader in self.readers:
                    reader.join()
                require(not self.invalid.is_set())
                try:
                    frame = self.events.get_nowait()
                except queue.Empty:
                    raise RuntimeError('NATIVE_BUCKET_DIAGNOSTIC_MISSING_FRAME') from None
            if frame.get('kind') == 'STOPPED':
                self.stopped = frame
            require(frame.get('kind') == kind)
            return frame
        raise RuntimeError('NATIVE_BUCKET_DIAGNOSTIC_OBSERVATION_TIMEOUT')

    def readback(self):
        self.send(b'SNAPSHOT\n')
        frame = self.frame('BUCKET_READBACK', 260)
        require(set(frame) == {'kind', 'counts'})
        counts = frame['counts']
        require(isinstance(counts, dict) and set(counts) == KEYS
                and all(type(value) is int and value >= 0 for value in counts.values())
                and counts['role'] == 1 and counts['users'] == 5
                and 0 <= counts['limiterBuckets'] <= 6)
        snapshot = self.frame('SNAPSHOT', 10)
        require(set(snapshot) == {'kind', 'scope', 'sessions'} and snapshot['scope'] == 'full')
        rows = snapshot['sessions']
        require(isinstance(rows, list) and len(rows) <= 16
                and all(isinstance(row, dict) and set(row) == {'sessionId', 'revoked'}
                        and str(UUID(row['sessionId'])) == row['sessionId']
                        and type(row['revoked']) is bool for row in rows)
                and len({row['sessionId'] for row in rows}) == len(rows))
        return counts['limiterBuckets'], rows

    def close(self):
        """A bounded observation failure remains failure; still await the same owned exit."""
        valid = True
        try:
            if self.child.poll() is None:
                if not self.stop_sent:
                    self.send(b'STOP\n')
                    self.stop_sent = True
                self.child.stdin.close()
            if self.stopped is None:
                self.frame('STOPPED', 18 * 60)
        except (RuntimeError, OSError, ValueError):
            valid = False
            try:
                self.child.stdin.close()  # EOF is a second STOP intent, never kill the shim.
            except (OSError, ValueError):
                pass
        try:
            code = self.child.wait(timeout=18 * 60)
        except subprocess.TimeoutExpired:
            valid = False
            print('NATIVE_BUCKET_OWNED_EXIT_UNCONFIRMED', flush=True)
            code = self.child.wait()
        for reader in self.readers:
            reader.join()
        self.child.stdout.close()
        self.child.stderr.close()
        self.password = ''
        self.wrong_password = ''
        require(valid and code == 0 and not self.invalid.is_set()
                and self.events.empty() and isinstance(self.stopped, dict)
                and set(self.stopped) == {'kind', 'cleanup'}
                and set(self.stopped['cleanup']) == KEYS
                and all(type(value) is int and value == 0
                        for value in self.stopped['cleanup'].values()))


def run_case(pending):
    owner = OwnedDiagnostic(pending)
    try:
        owner.start()
        if pending:
            require(owner.frame('PENDING_STOP_OBSERVED') == {'kind': 'PENDING_STOP_OBSERVED'})
        else:
            ready = owner.frame('READY')
            run_id = ready.get('runId')
            require(set(ready) == {'kind', 'runId', 'emails', 'userIds'}
                    and str(UUID(run_id)) == run_id
                    and ready['emails'] == [f'probe-{run_id}-{i}@example.invalid' for i in range(5)]
                    and len(ready['userIds']) == 5 and len(set(ready['userIds'])) == 5
                    and all(str(UUID(value)) == value for value in ready['userIds']))
            before, sessions_before = owner.readback()
            status, headers, body = request(3000, 'POST', '/auth/login', {
                'email': f'probe-{run_id}-unknown@example.invalid',
                'password': owner.wrong_password, 'clientType': 'ANDROID'})
            require(status == 401 and isinstance(body, dict)
                    and body.get('error', {}).get('code') == 'AUTH_INVALID'
                    and not header(headers, 'set-cookie'))
            after, sessions_after = owner.readback()
            require(after == before + 1 and sessions_after == sessions_before)
            print('NATIVE_BUCKET_ACTUAL_401_POSITIVE_DELTA_PASS', flush=True)
    finally:
        owner.close()
    print('NATIVE_BUCKET_PENDING_STOP_CLEANUP_PASS' if pending else
          'NATIVE_BUCKET_NORMAL_EIGHT_ZERO_CLEANUP_PASS', flush=True)


if __name__ == '__main__':
    try:
        require(len(sys.argv) <= 2 and (len(sys.argv) == 1 or sys.argv[1] in ('--child', '--pending-child')))
        if len(sys.argv) == 2:
            instrumented_child(sys.argv[1] == '--pending-child')
        else:
            fixture.launcher.lab.inspect_lab()
            run_case(False)
            run_case(True)
            print('NATIVE_BUCKET_ACTUAL_DIAGNOSTIC_PASS', flush=True)
    except (RuntimeError, ValueError, TypeError, KeyError, OSError, subprocess.SubprocessError):
        print('NATIVE_BUCKET_ACTUAL_DIAGNOSTIC_FAILED', flush=True)
        sys.exit(1)
