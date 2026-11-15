"""Kiểm User lock timeout bằng holder sở hữu và committed readback; không thêm production fault hook."""

from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import time
from uuid import UUID

from user_fence_holder import UserFenceHolder
from verify_audit_faults import read_snapshot
from verify_measurements import begin_window, measurement_control
from verify_provider import expect, header
from verify_user_fence import login_request

# Các stage mong đợi phản ánh query AccountAcquire lỗi trước hash/session/COMMIT, không xác nhận rollback.
LOCK_OUTCOMES = {'pool_acquire': 'completed', 'transaction_begin': 'completed',
                 'bucket_acquire': 'completed', 'account_acquire': 'error', 'fenced_work': 'abandoned'}
# Query literal trong chính backend holder xác nhận transaction còn giữ table lock; không có input cần bind.
LOCK_PROOF_SQL = "SELECT 'FENCE_STILL_HELD' WHERE EXISTS(SELECT 1 FROM pg_locks WHERE pid=pg_backend_pid() AND relation='public.users'::regclass AND mode='RowShareLock' AND granted);"
# Cận kiểm harness quanh lock_timeout5s; không sửa budget của gateway hoặc dùng như SLO production.
MIN_LOCK_US = 4_900_000
MAX_LOCK_US = 7_000_000
RESULT_TIMEOUT = 8.0


def validate_unavailable(response):
    """Chỉ nhận503 generic không credential trước khi dùng correlation để đối soát DB.

    Input
    Param: response — status/header/body trong RAM từ login đang bị giữ User lock.
    Output: UUID correlation; Errors: RuntimeError cố định, không phản chiếu error/header/token.
    """
    status, headers, body = response
    error = body.get('error') if type(body) is dict else None
    if (status != 503 or type(error) is not dict or set(body) != {'error'}
            or set(error) != {'code', 'message', 'details', 'correlationId'}
            or error['code'] != 'SERVICE_UNAVAILABLE' or error['details'] != {}
            or error['message'] != 'Không thể hoàn tất yêu cầu. Vui lòng kiểm tra trạng thái và thử lại.'
            or header(headers, 'cache-control') != 'no-store'
            or any(header(headers, name) is not None for name in ('set-cookie', 'x-auth-context-id', 'x-csrf-token'))):
        raise RuntimeError('Unsafe lock budget response')
    try:
        return UUID(error['correlationId'])
    except (ValueError, TypeError, AttributeError):
        raise RuntimeError('Invalid lock budget correlation') from None


def validate_lock_snapshot(value, generation):
    """Đòi đúng5stage/outcome và account wait gần5s, không bỏ Error để tái dùng success parser M3.

    Input
    Param: value — end snapshot untrusted từ control bounded của cùng process.
    Param: generation — generation đã nhận từ begin, không lấy end làm expected.
    Output: snapshot enum/numeric nguyên vẹn đã kiểm; Errors: schema/count/duration/stale/loss sai đều FAIL.
    """
    if (type(value) is not dict
            or set(value) != {'windowId', 'valid', 'droppedSamples', 'staleSamples', 'poisoned', 'samples'}
            or type(generation) is not int or not 0 < generation < 2**64
            or type(value['windowId']) is not int or value['windowId'] != generation
            or value['valid'] is not True or value['poisoned'] is not False
            or type(value['droppedSamples']) is not int or value['droppedSamples'] != 0
            or type(value['staleSamples']) is not int or value['staleSamples'] != 0
            or type(value['samples']) is not list or len(value['samples']) != len(LOCK_OUTCOMES)):
        raise RuntimeError('Invalid lock budget snapshot')
    counts = Counter()
    for sample in value['samples']:
        if (type(sample) is not dict or set(sample) != {'stage', 'outcome', 'elapsedUs'}
                or type(sample['stage']) is not str or sample['stage'] not in LOCK_OUTCOMES
                or sample['outcome'] != LOCK_OUTCOMES[sample['stage']]
                or type(sample['elapsedUs']) is not int or not 0 <= sample['elapsedUs'] < 2**64):
            raise RuntimeError('Invalid lock budget stage')
        counts[sample['stage']] += 1
        if sample['stage'] == 'account_acquire' and not MIN_LOCK_US <= sample['elapsedUs'] <= MAX_LOCK_US:
            raise RuntimeError('Lock wait outside harness budget')
    if counts != Counter({stage: 1 for stage in LOCK_OUTCOMES}):
        raise RuntimeError('Incomplete lock budget stages')
    return value


def healthy_login(response, client, user_id):
    """Kiểm control/recovery đúng identity và credential channel trước khi coi dependency đã phục hồi.

    Input
    Param: response — response login fixture chỉ giữ RAM.
    Param: client — WEB/ANDROID literal quyết định cookie hoặc bearer.
    Param: user_id — identity fixture mong đợi, không dùng làm nhãn evidence.
    Output: boolean full login thành công; không xuất credential hoặc dữ liệu profile.
    """
    status, headers, body = response
    if (status != 200 or type(body) is not dict or body.get('limited') is not False
            or type(body.get('me')) is not dict or body['me'].get('id') != str(user_id)
            or header(headers, 'cache-control') != 'no-store'):
        return False
    if client == 'WEB':
        return bool(header(headers, 'set-cookie')) and 'token' not in body
    return client == 'ANDROID' and header(headers, 'set-cookie') is None and type(body.get('token')) is str and bool(body['token'])


def verify_lock_budget(port, emails, password, user_ids, digests, run_id, key, previous, checks, holders):
    """Giữ User lock qua response503 của từng client rồi đối chiếu DB và login phục hồi.

    Input
    Param: port — primary lab đã xong M4a và không có traffic auth khác trong window.
    Param: emails —5email fixture, chỉ dùng account3 ACTIVE/no membership cho fault này.
    Param: password — seed credential TEST trong RAM, không xuất vào report.
    Param: user_ids —5UUID fixture, account2 chỉ cấp constructor holder, không mutation.
    Param: digests — bucket selectors tương ứng, chỉ dùng readback có scope.
    Param: run_id — marker sở hữu role/fixture để holder kiểm trước start.
    Param: key — control capability M3 trong RAM/header loopback.
    Param: previous — generation primary cuối M4a, tăng qua cả WEB và ANDROID.
    Param: checks — nơi ghi8invariants tĩnh mỗi client, không dữ liệu request.
    Param: holders — registry launcher, append trước start để luôn còn quyền cleanup.
    Output: hai quan sát numeric/enum/flags; Errors: HTTP/wait/proof/state/stage/deadline sai đều FAIL.
    Side effects: control/recovery sessions thuộc fixture, owned holder được stop trước executor join khi lỗi.
    """
    observations = []
    for client in ('WEB', 'ANDROID'):
        prefix = 'lock-budget-' + client.lower()
        response = login_request(port, emails[3], password, client)
        expect(healthy_login(response, client, user_ids[3]), prefix + '-control', checks)
        before = read_snapshot(user_ids[3], digests[3])
        expect(before[2] == 0, prefix + '-fresh-bucket', checks)
        holder = UserFenceHolder(run_id, user_ids[3], user_ids[2])
        holders.append(holder)
        try:
            holder.start()
            previous = begin_window(port, key, previous)
            with ThreadPoolExecutor(max_workers=1) as workers:
                # Deadline tính trước submit và không reset sau metadata observation hoặc future wakeup.
                deadline = time.monotonic() + RESULT_TIMEOUT
                pending = workers.submit(login_request, port, emails[3], password, client)
                try:
                    holder.wait_for_blocked()
                    expect(not pending.done(), prefix + '-actual-wait', checks)
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise RuntimeError('Lock budget result deadline exceeded')
                    response = pending.result(timeout=remaining)
                    if time.monotonic() >= deadline:
                        raise RuntimeError('Lock budget result arrived late')
                    # READY đã khóa row; proof cùng backend sau response chống nhả sớm hoặc idle expiry.
                    holder.send(LOCK_PROOF_SQL)
                    holder.read_marker('FENCE_STILL_HELD', 1.0)
                    expect(True, prefix + '-held-after-response', checks)
                finally:
                    # Nhả khóa trước executor join nếu wait/proof/result lỗi, không chờ HTTP dưới holder cũ.
                    holder.stop()
            correlation = validate_unavailable(response)
            expect(True, prefix + '-safe-unavailable', checks)
            snapshot = validate_lock_snapshot(measurement_control(port, 'end', key), previous)
            expect(True, prefix + '-stages', checks)
            after = read_snapshot(user_ids[3], digests[3], (correlation,))
            expect(after[:3] == before[:3] and after[3] == 0, prefix + '-committed-unchanged', checks)
            recovery = login_request(port, emails[3], password, client)
            recovered = read_snapshot(user_ids[3], digests[3], (correlation,))
            expect(healthy_login(recovery, client, user_ids[3])
                   and recovered[:2] == (before[0] + 1, before[1] + 1)
                   and recovered[2] == before[2] and recovered[3] == 0, prefix + '-recovered', checks)
            observations.append({'clientType': client, 'waitObserved': True, 'holderHeldAfterResponse': True,
                                 'committedStateUnchanged': True, 'recovered': True, 'snapshot': snapshot})
        finally:
            holder.stop()
    return observations
