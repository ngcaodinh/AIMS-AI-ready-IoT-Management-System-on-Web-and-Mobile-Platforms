"""Runner cố định cho unit suite domain liên quan đến membership."""

import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CARGO_COMMAND = [
    'cargo', 'test', '--manifest-path', 'Cargo.toml',
    '--package', 'iot-domain', '--locked', '--offline',
]
RESULT_PATTERN = re.compile(
    r'test result:\s*(?:ok|FAILED)\.\s*(?P<passed>\d+) passed;\s*'
    r'(?P<failed>\d+) failed;\s*(?P<ignored>\d+) ignored;\s*'
    r'(?P<measured>\d+) measured;\s*(?P<filtered>\d+) filtered out',
)
ERROR_CODE_PATTERN = re.compile(r'error\[(E\d{4})\]')
FAILED_TEST_PATTERN = re.compile(r'^test ([A-Za-z0-9_:]+) \.\.\. FAILED$', re.MULTILINE)
PACKAGE_COMPILE_PATTERN = re.compile(
    r"^error: could not compile [`']([A-Za-z0-9_-]+)[`']", re.MULTILINE
)


def run():
    """Chạy duy nhất unit suite iot-domain offline để kiểm invariant member/reset.

    Output
    Trả exit code cố định và tổng số test từ các summary Rust test harness.
    Errors
    Fail closed nếu Cargo không chạy, hết thời gian, có test lỗi hoặc thiếu summary.
    Side effects
    Cargo chỉ dùng backend/target trong tiến trình runner đã được owner cho phép.
    """
    print('MEMBER_UNIT_STAGE_DOMAIN', flush=True)
    try:
        completed = subprocess.run(
            CARGO_COMMAND,
            # Cargo phải chạy từ backend để nạp linker/target trong backend/.cargo/config.toml.
            cwd=ROOT / 'backend',
            capture_output=True,
            text=True,
            encoding='utf-8',
            errors='replace',
            timeout=600,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        print('FAIL MEMBER_UNIT_RUNNER_UNAVAILABLE')
        return 2

    # Chuẩn hóa CRLF/ANSI để summary Rust trên Windows vẫn được đếm mà không in nội dung thô.
    output = f'{completed.stdout}\n{completed.stderr}'.replace('\r\n', '\n').replace('\r', '\n')
    output = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', output)
    summaries = [
        {name: int(value) for name, value in match.groupdict().items()}
        for match in RESULT_PATTERN.finditer(output)
    ]
    totals = {
        name: sum(summary[name] for summary in summaries)
        for name in ('passed', 'failed', 'ignored', 'measured', 'filtered')
    }
    if completed.returncode != 0 or not summaries or totals['failed']:
        categories = []
        if completed.returncode == 0 and not summaries:
            categories.append('summary_missing')
        if 'did not match any packages' in output or 'package ID specification' in output:
            categories.append('package_selection_error')
        if 'no matching package named' in output:
            categories.append('offline_dependency_missing')
        if 'failed to download' in output:
            categories.append('offline_dependency_fetch')
        if 'failed to run custom build command' in output:
            categories.append('build_script_failure')
        if 'error: could not compile' in output:
            categories.append('compile_failure')
        if 'linking with' in output or 'linker' in output and 'not found' in output:
            categories.append('linker_failure')
        if 'mismatched types' in output:
            categories.append('compiler_type_error')
        if 'not found in this scope' in output or "cannot find" in output:
            categories.append('compiler_name_resolution_error')
        if 'unclosed delimiter' in output or 'unexpected closing delimiter' in output:
            categories.append('compiler_parse_error')
        if 'test result: FAILED.' in output:
            categories.append('test_failure')
        error_codes = sorted(set(ERROR_CODE_PATTERN.findall(output)))
        failed_tests = sorted(set(FAILED_TEST_PATTERN.findall(output)))
        failed_packages = sorted(set(PACKAGE_COMPILE_PATTERN.findall(output)))
        print(
            'FAIL MEMBER_DOMAIN_UNIT_TESTS '
            f'exit={completed.returncode} suites={len(summaries)} '
            f'passed={totals["passed"]} failed={totals["failed"]} '
            f'categories={",".join(categories) or "unclassified"} '
            f'errorCodes={",".join(error_codes) or "none"} '
            f'failedPackages={",".join(failed_packages) or "none"} '
            f'failedTests={",".join(failed_tests) or "none"}'
        )
        return 1

    print(
        'PASS MEMBER_DOMAIN_UNIT_TESTS '
        f'suites={len(summaries)} passed={totals["passed"]} '
        f'failed={totals["failed"]} ignored={totals["ignored"]}'
    )
    return 0


def main():
    """Chỉ chấp nhận cờ chạy tường minh để tránh vô tình dùng lane target."""
    if sys.argv[1:] != ['--run']:
        print('Usage: python -B -E -S ops/auth/run_member_unit_test.py --run')
        return 2
    return run()


if __name__ == '__main__':
    sys.exit(main())
