"""Kiểm limiter liên instance bằng HTTP thật; report chỉ outcome/latency không có credential."""

from concurrent.futures import ThreadPoolExecutor
import math
import secrets
import threading
import time

from verify_provider import expect, header, read_persisted_session, request


def concurrent_batch(jobs):
    """Phát sáu login sau cùng một barrier để không nhầm vòng lặp tuần tự là race.

    Input
    Param: jobs — sáu tuple port/email/password tổng hợp từ launcher; không log chúng.
    Output: response và HTTP duration ms chỉ giữ trong RAM, caller lọc trước report.
    Errors: timeout barrier/HTTP được truyền lên để launcher cleanup, không tự retry login.
    """
    # Sáu attempt là ca boundary 5failures/15phút, không là cấu hình load benchmark.
    barrier = threading.Barrier(6, timeout=10)

    def attempt(job):
        """Chờ đủ worker rồi đo HTTP wall time, không gồm thời gian đợi barrier.

        Input
        Param: job — port và credential TEST của một request, chỉ dùng trong RAM.
        Output: status/headers/body cùng duration ms cho kiểm invariant và tổng hợp.
        """
        port, email, password = job
        barrier.wait()
        started = time.perf_counter()
        response = request(port, 'POST', '/auth/login', {'email': email, 'password': password, 'clientType': 'ANDROID'})
        return (*response, (time.perf_counter() - started) * 1000)

    with ThreadPoolExecutor(max_workers=6) as workers:
        return list(workers.map(attempt, jobs))


def summarize_durations(responses, keys):
    """Loại credential/body khỏi kết quả, chỉ giữ số liệu HTTP quan sát của sáu sample.

    Input
    Param: responses — response trong RAM; chỉ phần duration được đọc để xuất report.
    Param: keys — số email key tổng hợp khác nhau trong batch, không xuất giá trị key.
    Output: min/max/p50/p95 theo nearest-rank, ms; không diễn giải thành budget nội bộ.
    """
    durations = sorted(response[3] for response in responses)
    return {'samples': len(durations), 'instances': 2, 'keys': keys,
            'minMs': round(durations[0], 2), 'maxMs': round(durations[-1], 2),
            'p50Ms': round(durations[math.ceil(len(durations) * .5) - 1], 2),
            'p95Ms': round(durations[math.ceil(len(durations) * .95) - 1], 2)}


def verify_concurrency(port, peer_port, emails, password, user_ids, checks):
    """Chứng minh session/limiter dùng chung qua hai process nối canonical DB và cùng key.

    Input
    Param: port — listener primary đã seed xong bởi launcher.
    Param: peer_port — listener peer skip seed, cùng DB/key nhưng process độc lập.
    Param: emails — đúng năm identity fixture của lượt chạy đã được phép.
    Param: password — credential seed TEST còn hợp lệ cho account0/3/4.
    Param: user_ids — UUID fixture để discovery qua peer phải giữ đúng identity.
    Param: checks — danh sách ID invariant tĩnh, không chứa dữ liệu response.
    Output: hai nhóm HTTP latency tổng hợp; sáu sample không đủ chứng nhận performance.
    Errors: sai outcome/transport/count làm fail closed; không retry hoặc reset limiter.
    Side effects: tạo session fixture và tăng limiter account4, launcher dọn đúng graph.
    """
    status, _, body = request(port, 'POST', '/auth/login', {'email': emails[0], 'password': password, 'clientType': 'ANDROID'})
    expect(status == 200 and body.get('token') and body['limited'] is False, 'two-instance-session-issued', checks)
    status, _, profile = request(peer_port, 'GET', '/me', headers={'Authorization': 'Bearer ' + body['token']})
    expect(status == 200 and profile['id'] == str(user_ids[0]), 'two-instance-session-discovery', checks)
    # Không dùng disabled account1 hoặc account2 đã đổi password trong baseline59checks.
    jobs = [(port if index % 2 == 0 else peer_port, emails[account], password) for index, account in enumerate((0, 3, 4, 0, 3, 4))]
    success = concurrent_batch(jobs)
    expect(all(status == 200 and body.get('token') and body['limited'] is False and not header(headers, 'set-cookie') for status, headers, body, _ in success), 'concurrent-multi-key-logins', checks)
    # Hai intent cùng account phải có hai row durable riêng; digest/TTL được đối chiếu trước khi so UUID.
    session_ids = [read_persisted_session(response[2]['token'], user_ids[account], 'ANDROID', False,
                                          response[2]['expiresAt'])
                   for account, response in zip((0, 3, 4, 0, 3, 4), success)]
    expect(len(set(session_ids)) == 6, 'concurrent-same-account-distinct-durable-sessions', checks)
    # Account4 chưa có failed attempt; success không reset fixed-window còn hiệu lực của domain.
    wrong_password = 'Aa1' + secrets.token_hex(32)
    failures = concurrent_batch([(port if index % 2 == 0 else peer_port, emails[4], wrong_password) for index in range(6)])
    expect(sorted(response[0] for response in failures) == [401] * 5 + [429], 'concurrent-shared-limiter-counts', checks)
    for status, headers, body, _ in failures:
        retry_after = header(headers, 'retry-after')
        expect(not header(headers, 'set-cookie') and body['error']['code'] == ('AUTH_INVALID' if status == 401 else 'RATE_LIMITED') and (status != 429 or (retry_after is not None and retry_after.isdigit() and int(retry_after) > 0)), 'concurrent-shared-limiter-safe-response', checks)
    return {'kind': 'HTTP wall time observations, not hash/queue/pool/lock or load acceptance',
            'multiKey': summarize_durations(success, 3), 'sameKey': summarize_durations(failures, 1)}
