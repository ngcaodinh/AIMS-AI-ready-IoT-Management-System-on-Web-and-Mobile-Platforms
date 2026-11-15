"""Baseline stage auth lặp có exact counts; chỉ xuất enum/numeric, không tự ký production SLO."""

from collections import defaultdict
import math

from verify_concurrency import concurrent_batch
from verify_measurements import STAGES, begin_window, measurement_control, validate_snapshot
from verify_provider import expect, header

TOPOLOGIES = ('same_key', 'multi_key')
PROCESSES = ('primary', 'peer')
BATCHES = 5
LOGINS_PER_PROCESS = 3


def summarize_baseline(windows):
    """Chỉ tính percentile sau khi coverage/window/stage đầy đủ, không lọc lỗi để tạo baseline đẹp.

    Input
    Param: windows —20snapshot số/enum theo thứ tự chạy, gồm metadata topology/batch/process.
    Output:36group với15samples/group và p50/p95/max microseconds theo nearest-rank.
    Errors: duplicate/missing coverage, generation hoặc strict snapshot sai làm FAIL trước summary.
    """
    if type(windows) is not list or len(windows) != len(TOPOLOGIES) * BATCHES * len(PROCESSES):
        raise RuntimeError('Incomplete baseline windows')
    seen = set()
    previous = dict.fromkeys(PROCESSES, 0)
    groups = defaultdict(list)
    for window in windows:
        if (type(window) is not dict
                or set(window) != {'topology', 'batch', 'process', 'windowId', 'valid', 'poisoned',
                                   'droppedSamples', 'staleSamples', 'samples'}
                or window['topology'] not in TOPOLOGIES or window['process'] not in PROCESSES
                or type(window['batch']) is not int or not 1 <= window['batch'] <= BATCHES):
            raise RuntimeError('Invalid baseline metadata')
        topology, batch, process = window['topology'], window['batch'], window['process']
        identity = (topology, batch, process)
        if identity in seen or type(window['windowId']) is not int or not previous[process] < window['windowId'] < 2**64:
            raise RuntimeError('Duplicate or stale baseline window')
        seen.add(identity)
        previous[process] = window['windowId']
        snapshot = {name: value for name, value in window.items() if name not in ('topology', 'batch', 'process')}
        validate_snapshot(snapshot, window['windowId'], LOGINS_PER_PROCESS)
        for sample in snapshot['samples']:
            groups[(topology, process, sample['stage'])].append(sample['elapsedUs'])
    summaries = []
    for topology in TOPOLOGIES:
        for process in PROCESSES:
            for stage in STAGES:
                durations = sorted(groups[(topology, process, stage)])
                if len(durations) != BATCHES * LOGINS_PER_PROCESS:
                    raise RuntimeError('Incomplete baseline group')
                # Nearest-rank không nội suy: với15mẫu, p50 là mẫu8 và p95 là mẫu15.
                summaries.append({'topology': topology, 'process': process, 'stage': stage,
                                  'outcome': 'completed', 'samples': len(durations),
                                  'p50Us': durations[math.ceil(len(durations) * .5) - 1],
                                  'p95Us': durations[math.ceil(len(durations) * .95) - 1],
                                  'maxUs': durations[-1]})
    return summaries


def verify_measurement_baseline(port, peer_port, emails, password, key, previous, checks):
    """Đo60login thật qua hai process trong10batch riêng, chỉ bàn giao khi mọi window đầy đủ.

    Input
    Param: port — listener primary đã hoàn tất M3 smoke.
    Param: peer_port — listener process peer độc lập, cùng DB/auth key.
    Param: emails — năm account fixture; chỉ0/3/4 còn credential seed sau baseline provider.
    Param: password — credential TEST trong RAM, không dùng làm nhãn metric.
    Param: key — capability control M3, chỉ truyền qua header loopback.
    Param: previous — generation cuối primary/peer từ smoke M3 để chặn stale qua các batch.
    Param: checks — danh sách ID invariant tĩnh, chỉ thêm sau batch hợp lệ.
    Output:20raw windows bounded và36summary enum/numeric; không response HTTP/credential.
    Errors: HTTP/snapshot/generation sai thì fail toàn phép đo, không retry hoặc reset state.
    Side effects:60session fixture, launcher phải dừng process trước cleanup kể cả lỗi còn window mở.
    """
    if (type(previous) is not dict or set(previous) != set(PROCESSES)
            or any(type(previous[role]) is not int or not 0 < previous[role] < 2**64 for role in PROCESSES)):
        raise RuntimeError('Invalid baseline starting generation')
    generations = dict(previous)
    processes = (('primary', port), ('peer', peer_port))
    windows = []
    for topology in TOPOLOGIES:
        accounts = (0,) * 6 if topology == 'same_key' else (0, 3, 4, 0, 3, 4)
        for batch in range(1, BATCHES + 1):
            for role, listener in processes:
                generations[role] = begin_window(listener, key, generations[role])
            # Alternating listener giữ đúng3request/process; multi-key mỗi process có đủ0/3/4.
            jobs = [(port if index % 2 == 0 else peer_port, emails[account], password)
                    for index, account in enumerate(accounts)]
            responses = concurrent_batch(jobs)
            if len(responses) != 6:
                raise RuntimeError('Incomplete baseline HTTP batch')
            for status, headers, body, _ in responses:
                if (status != 200 or type(body) is not dict or type(body.get('token')) is not str
                        or not body['token'] or body.get('limited') is not False or header(headers, 'set-cookie')):
                    raise RuntimeError('Baseline login failed')
            # Chỉ end sau toàn bộ responses; không profile/SQL/traffic phụ trong window được đo.
            for role, listener in processes:
                snapshot = validate_snapshot(measurement_control(listener, 'end', key),
                                             generations[role], LOGINS_PER_PROCESS)
                windows.append({'topology': topology, 'batch': batch, 'process': role, **snapshot})
            expect(True, 'measurement-baseline-' + topology, checks)
    return {'kind': 'repeated local stage baseline, not production SLO or budget fault acceptance',
            'windows': windows, 'summaries': summarize_baseline(windows)}
