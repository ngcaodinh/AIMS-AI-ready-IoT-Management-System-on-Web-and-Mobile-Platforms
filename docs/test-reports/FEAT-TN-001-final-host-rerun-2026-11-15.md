# FEAT-TN-001 — final host regression rerun, 15/11/2026

**READY_FOR_QA cho host/auth regression và Android main-flow evidence đã có; toàn feature vẫn `VERIFY_IN_PROGRESS`.** Đây là host rerun sau Android API24 E2E trong [report](FEAT-TN-001-android-api24-full-resume-2026-11-15.md), không thay acceptance runtime còn mở.

## Source state

- Branch `dev`, HEAD `ba425ad9e5576ed3261f6df5b4a4731c96d98850`; working tree dirty, chưa commit/push tại thời điểm chạy.
- Lượt host rerun này không sửa production code/UI; chỉ cập nhật plan/report. Test harness Android đã được cập nhật trước E2E và được ghi riêng trong report Android.
- Acceptance `E2E-AUTH-003` / `AT-WF-001-03` còn `PARTIAL`: exact preselection request oracle đã PASS trên Web/Android, nhưng chưa seed device fixtures khác nhau ở A/B. Các acceptance mở khác giữ nguyên trong [matrix](FEAT-TN-001-acceptance-matrix-2026-11-13.md).

## Commands actually run

| Working directory | Command | Result |
| --- | --- | --- |
| Repository root | `node ops/auth/test_native_e2e_protocol.mjs` | Exit 0; 15 protocol markers PASS, including `NATIVE_FULL_PRESELECTION_CHECKPOINT_AND_REQUEST_ORACLE_PASS`. |
| Repository root | `python -X utf8 -B -m unittest discover -s ops/auth/tests -q` | Exit 0; 133 tests PASS. |
| `web` | `npm.cmd run test:auth` | Exit 0; 36/36 tests PASS, 0 failed. Node printed the expected experimental type-stripping warning. |
| `web` | `npx.cmd tsc --noEmit` | Exit 0. |
| Repository root | `git diff --check` | Exit 0. Git printed existing LF-to-CRLF worktree warnings. Git does not include untracked files in this check. |

The actual Android flow, PostgreSQL session delta/logout revoke, request oracle, and fixture cleanup are documented separately in the Android report and its redacted JSON evidence. The Chrome flow is documented in [browser report](FEAT-TN-001-web-chrome-login-picker-rerun-2026-11-15.md). These results are scoped evidence; they do not prove every acceptance row in the feature matrix.

## Remaining acceptance

- Seed owner-controlled device fixtures in workspaces A/B, then run `E2E-AUTH-003` / `AT-WF-001-03` through the real App/Web flow.
- Implement the protected resource dependency in FEAT-WF-010 before completing the corresponding resource authorization cases.
- Run remaining browser process-reopen/logout races, shared Web+App session/audit cases, remote-exporter fault and structured/debug sink scans listed in the acceptance matrix.

Do not mark the whole feature accepted until those rows have evidence meeting their original criteria.
