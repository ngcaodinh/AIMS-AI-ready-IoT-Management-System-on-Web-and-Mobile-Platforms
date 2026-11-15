"""Đo stage auth trong window lab có cận, chỉ xuất enum/numeric, không credential hoặc SQL."""

from collections import Counter
import hashlib
import hmac
import http.client
import json
import socket
import threading
import time

from verify_provider import expect, header, request

# Tên stage phải khớp port typed; không mở rộng nhãn bằng dữ liệu request/user/workspace.
STAGES = ('hash_queue', 'blocking_queue', 'hash_work', 'pool_acquire',
          'transaction_begin', 'bucket_acquire', 'account_acquire', 'fenced_work', 'commit_ack')
CONTROL_LABEL = b'auth-lab-measurement-v1'
CONTROL_TIMEOUT = 3.0
CONTROL_CLEANUP_TIMEOUT = 1.0
MAX_RESPONSE_BYTES = 1_048_576
MAX_SAMPLES = 4096


def unique_object(pairs):
    """Chặn JSON duplicate keys để response không mơ hồ về generation/count hoặc validity.

    Input
    Param: pairs — các cặp key/value do JSON decoder cung cấp, không được log value.
    Output: object duy nhất; Errors: RuntimeError generic khi key lặp, không echo field/data.
    """
    result = {}
    for key, value in pairs:
        if key in result:
            raise RuntimeError('Invalid measurement JSON')
        result[key] = value
    return result


def validate_snapshot(value, window_id, expected_per_stage, expected_stage_counts=None):
    """Chỉ nhận snapshot đầy đủ của đúng window; không giảm count hoặc bỏ Error để làm evidence PASS.

    Input
    Param: value — JSON đã bounded nhưng chưa tin cậy từ control route riêng của lab.
    Param: window_id — generation đã nhận từ begin của cùng process, không lấy lại từ end.
    Param: expected_per_stage — số successful logins hoàn tất;0 dùng kiểm window startup rỗng.
    Param: expected_stage_counts — map count hữu hạn cho denial có transaction audit riêng; None giữ success-count cũ.
    Output: snapshot chỉ enum/numeric đã kiểm; Errors: RuntimeError generic cho schema/count/completeness sai.
    """
    fields = {'windowId', 'valid', 'droppedSamples', 'staleSamples', 'poisoned', 'samples'}
    expected_counts = dict.fromkeys(STAGES, expected_per_stage)
    if expected_stage_counts is not None:
        if (type(expected_stage_counts) is not dict or set(expected_stage_counts) != set(STAGES)
                or any(type(count) is not int or not 0 <= count <= MAX_SAMPLES
                       for count in expected_stage_counts.values())
                or sum(expected_stage_counts.values()) > MAX_SAMPLES):
            raise RuntimeError('Invalid measurement stage expectations')
        expected_counts = expected_stage_counts
    valid = (type(value) is dict and set(value) == fields
             and type(window_id) is int and window_id > 0
             and type(expected_per_stage) is int and 0 <= expected_per_stage <= MAX_SAMPLES // len(STAGES)
             and type(value['windowId']) is int and value['windowId'] == window_id
             and value['valid'] is True and value['poisoned'] is False
             and type(value['droppedSamples']) is int and value['droppedSamples'] == 0
             and type(value['staleSamples']) is int and value['staleSamples'] == 0
             and type(value['samples']) is list
             and len(value['samples']) == sum(expected_counts.values()))
    if not valid:
        raise RuntimeError('Invalid measurement snapshot')
    counts = Counter()
    for sample in value['samples']:
        if (type(sample) is not dict or set(sample) != {'stage', 'outcome', 'elapsedUs'}
                or type(sample['stage']) is not str or sample['stage'] not in STAGES
                or sample['outcome'] != 'completed'
                or type(sample['elapsedUs']) is not int or not 0 <= sample['elapsedUs'] < 2**64):
            raise RuntimeError('Invalid measurement sample')
        counts[sample['stage']] += 1
    if any(counts[stage] != expected_counts[stage] for stage in STAGES):
        raise RuntimeError('Incomplete measurement stages')
    return value


def measurement_control(port, action, key, expected_status=200):
    """Gọi control loopback có deadline toàn exchange, không prefix API hoặc retry mutation có outcome chưa rõ.

    Input
    Param: port — listener của đúng child lab đã READY, luôn nối127.0.0.1 và không follow redirect.
    Param: action — literal begin/end, không nhận URL hoặc path tùy ý từ caller.
    Param: key — control key32byte trong RAM, không dùng signing key hoặc ghi vào report.
    Param: expected_status — mặc định200;409 chỉ dùng end lặp để xác nhận rejected export control đúng HTTP.
    Output: JSON object bounded1MiB đã chặn duplicate; Errors: RuntimeError generic, cleanup socket/watchdog.
    """
    if (type(port) is not int or not 1024 <= port <= 65535 or action not in ('begin', 'end')
            or type(key) is not bytes or len(key) != 32 or type(expected_status) is not int
            or expected_status not in (200, 409) or expected_status == 409 and action != 'end'):
        raise RuntimeError('Invalid measurement control input')
    deadline = time.monotonic() + CONTROL_TIMEOUT
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=CONTROL_TIMEOUT)
    response = None
    watchdog = None
    try:
        connection.connect()
        owned_socket = connection.sock
        remaining = deadline - time.monotonic()
        if owned_socket is None or remaining <= 0:
            raise RuntimeError('Measurement control deadline exceeded')

        def expire_socket():
            """Ngắt đúng socket sở hữu để header/body trickle không reset timeout theo từng recv.

            Side effects: shutdown socket của exchange này; lỗi already-closed được bỏ qua vì finally vẫn đóng handle.
            """
            try:
                owned_socket.shutdown(socket.SHUT_RDWR)
            except OSError:
                # Timer có thể chạy đồng thời close ở finally; không làm leak thread hoặc lộ error thô.
                pass

        watchdog = threading.Timer(remaining, expire_socket)
        watchdog.name = 'auth-measurement-control'
        watchdog.daemon = True
        watchdog.start()
        owned_socket.settimeout(remaining)
        proof = hmac.new(key, CONTROL_LABEL, hashlib.sha256).hexdigest()
        connection.request('POST', '/__auth_lab/measurements/' + action, body=None,
                           headers={'x-auth-lab-measurement': proof})
        response = connection.getresponse()
        headers = response.getheaders()
        # Chỉ nhận response không cache/cookie/CORS; header/value không được in vào lỗi.
        if (response.status != expected_status
                or [value.lower() for name, value in headers if name.lower() == 'cache-control'] != ['no-store']
                or any(name.lower() in ('set-cookie', 'access-control-allow-origin') for name, _ in headers)):
            raise RuntimeError('Measurement control rejected')
        payload = response.read(MAX_RESPONSE_BYTES + 1)
        if len(payload) > MAX_RESPONSE_BYTES:
            raise RuntimeError('Measurement response too large')
        value = json.loads(payload, object_pairs_hook=unique_object)
        # Fresh check chặn response muộn dù watchdog chưa được scheduler chạy; không chấp nhận late PASS.
        if time.monotonic() >= deadline or type(value) is not dict:
            raise RuntimeError('Measurement control deadline or schema invalid')
        if expected_status == 409 and value != {'error': 'MEASUREMENT_CONTROL_REJECTED'}:
            raise RuntimeError('Invalid measurement rejection')
        return value
    except (OSError, ValueError, http.client.HTTPException, RuntimeError, RecursionError):
        raise RuntimeError('Measurement control failed') from None
    finally:
        try:
            if response is not None:
                response.close()
        finally:
            try:
                connection.close()
            finally:
                if watchdog is not None:
                    watchdog.cancel()
                    watchdog.join(CONTROL_CLEANUP_TIMEOUT)
                    if watchdog.is_alive():
                        raise RuntimeError('Measurement watchdog cleanup failed')


def begin_window(port, key, previous=0):
    """Kiểm begin generation tăng đơn điệu trong cùng process, không lấy generation từ end để che stale.

    Input
    Param: port — listener loopback sở hữu của process.
    Param: key — capability control chỉ giữ trong RAM.
    Param: previous — generation window trước cùng process;0 cho lần begin đầu.
    Output: generation số; Errors: schema/bool/non-increasing làm fail và launcher dừng process, không retry.
    """
    value = measurement_control(port, 'begin', key)
    if (set(value) != {'windowId'} or type(value['windowId']) is not int
            or not previous < value['windowId'] < 2**64):
        raise RuntimeError('Invalid measurement generation')
    return value['windowId']


def verify_measurements(port, peer_port, email, password, key, checks):
    """Smoke enabled qua hai process thật, chỉ export snapshot đầy đủ sau HTTP success và không traffic khác.

    Input
    Param: port — primary lab đã seed/startup xong và READY.
    Param: peer_port — process riêng dùng cùng DB/auth key nhưng recorder độc lập.
    Param: email — account0 synthetic còn password hợp lệ, không dùng làm metric label.
    Param: password — credential TEST chỉ dùng trong RAM cho hai login.
    Param: key — control capability riêng của lab qua stdin/header, không serialize.
    Param: checks — chỉ append ID invariant tĩnh cho report không-secret.
    Output: windows enum/numeric cho từng process; Errors: thiếu/invalid sample hoặc HTTP lỗi làm fail toàn phép đo.
    Side effects: hai session fixture; launcher dừng children rồi cleanup dù window còn active khi lỗi.
    """
    processes = (('primary', port), ('peer', peer_port))
    previous = {}
    for role, listener in processes:
        generation = begin_window(listener, key)
        validate_snapshot(measurement_control(listener, 'end', key), generation, 0)
        previous[role] = generation
    expect(True, 'measurement-startup-empty-windows', checks)
    generations = {role: begin_window(listener, key, previous[role]) for role, listener in processes}
    # Không discovery/profile/fixture SQL trong window; exact9stage xác nhận chỉ một login mỗi process.
    for _, listener in processes:
        status, headers, body = request(listener, 'POST', '/auth/login',
                                        {'email': email, 'password': password, 'clientType': 'ANDROID'})
        if status != 200 or not body.get('token') or body.get('limited') is not False or header(headers, 'set-cookie'):
            raise RuntimeError('Measurement login failed')
    windows = []
    for role, listener in processes:
        snapshot = validate_snapshot(measurement_control(listener, 'end', key), generations[role], 1)
        expect(True, 'measurement-' + role + '-smoke', checks)
        windows.append({'process': role, **snapshot})
    return {'kind': 'internal stage smoke, not repeated baseline or production SLO', 'windows': windows}
