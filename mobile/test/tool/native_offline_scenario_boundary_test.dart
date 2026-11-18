import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexa_iot/features/auth/data/app_auth_api.dart';
import 'package:nexa_iot/features/auth/data/app_auth_failure.dart';
import 'package:nexa_iot/features/auth/data/app_login_response.dart';
import 'package:nexa_iot/features/auth/data/app_session_repository.dart';
import 'package:nexa_iot/features/auth/data/full_session_profile.dart';
import 'package:nexa_iot/features/auth/data/session_token_store.dart';
import 'package:nexa_iot/features/workspaces/data/available_workspace_page.dart';
import 'package:nexa_iot/features/workspaces/data/workspace_access_detail.dart';
import 'package:nexa_iot/features/auth/presentation/app_auth_application.dart';
import 'package:nexa_iot/features/auth/presentation/app_auth_coordinator.dart';

import '../../integration_test/support/native_offline_scenario.dart';
// Chỉ tái sử dụng API/store synthetic đã có; import không gọi main của suite membership.
import 'native_membership_scenario_boundary_test.dart' as fixtures;

const _runId = '30000000-0000-4000-8000-000000000001';

/// API fixture chỉ giữ request đầu tới busy frame, rồi trả typed network failure hoặc fault đã chọn.
/// Các request tiếp theo dùng DTO/parser/shared synthetic ledger của membership fixture.
final class OfflineApi implements AppAuthApi, AppWorkspaceApi {
  /// Input
  /// Param: fault — fault test cố định, không URL/SQL hoặc credential thật.
  OfflineApi(this.fault)
    : _delegate = fixtures.MembershipApi(
        fault == 'wrong-role' ? 'wrong-role' : 'success',
      );
  final String fault;
  final fixtures.MembershipApi _delegate;
  var attempts = 0;

  /// Output: ledger synthetic chung của delegate để test đối chiếu thứ tự request.
  List<String> get events => _delegate.events;

  /// Output: queue response do case sở hữu và drain; không là SDK/HTTP callback thật.
  List<void Function()> get replies => _delegate.replies;

  /// Input Param: token — bearer synthetic chuyển nguyên tới fixture parser đã có.
  @override
  Future<FullSessionProfile> getProfile(String token) =>
      _delegate.getProfile(token);

  /// Giữ logout ở trạng thái chưa rõ kết quả như kết nối đứt sau khi gửi, để producer phải giữ outbox.
  /// Input
  /// Param: token — bearer synthetic, chỉ dùng để mô phỏng request và không ghi vào ledger.
  /// Errors: networkUnavailable/outcomeUnknown buộc repository lưu ý định thu hồi chờ đối soát.
  @override
  Future<void> logout(String token) {
    events.add('logout-offline');
    final result = Completer<void>();
    replies.add(
      /// Response giả có độ trễ transport hữu hạn để UI busy mới có thể được quan sát trong producer test.
      () => result.completeError(
        const AppAuthFailure(
          AppAuthFailureKind.networkUnavailable,
          outcomeUnknown: true,
        ),
      ),
    );
    return result.future;
  }

  /// Input Param: token — synthetic authority của repository test.
  /// Param: cursor — cursor test được chuyển nguyên, producer không tự phân trang.
  @override
  Future<AvailableWorkspacePage> listWorkspaces(
    String token, {
    String? cursor,
  }) => _delegate.listWorkspaces(token, cursor: cursor);

  /// Input Param: token — synthetic bearer, không log.
  /// Param: workspaceId — identity từ tap row để delegate kiểm detail/role.
  @override
  Future<WorkspaceAccessDetail> getWorkspace(
    String token,
    String workspaceId,
  ) => _delegate.getWorkspace(token, workspaceId);

  /// Input
  /// Param: email — synthetic identity qua form, không log payload.
  /// Param: password — synthetic credential chỉ RAM.
  /// Output: first failure có busy frame, hoặc candidate synthetic theo shared fixture.
  @override
  Future<AppLoginResponse> login(String email, String password) {
    attempts++;
    if (attempts != 1 || fault == 'unexpected-login-success') {
      return _delegate.login(email, password);
    }
    events.add('offline-login');
    final result = Completer<AppLoginResponse>();
    replies.add(
      /// Timer owned của case nhả failure; outcomeUnknown phải bị producer từ chối expected offline.
      () => result.completeError(
        AppAuthFailure(
          AppAuthFailureKind.networkUnavailable,
          outcomeUnknown: fault == 'pending',
        ),
      ),
    );
    return result.future;
  }
}

/// Store synthetic giữ delete ACK tới tick thật, để recovery không-token vẫn có busy frame như plugin native.
final class OfflineStore implements SessionTokenStore {
  /// Input Param: replies — queue owned chung, timer của case nhả một ACK mỗi tick.
  /// Param: immediateDelete — kiểm ACK hoàn tất trước frame, không giả plugin luôn có latency tối thiểu.
  OfflineStore(this.replies, {this.immediateDelete = false});
  final List<void Function()> replies;
  final bool immediateDelete;
  StoredSessionCredential? session;
  PendingLogoutIntent? logoutIntent;

  /// Đọc bearer synthetic để assertion ngoài repository kiểm session đã bị xóa.
  String? get value => session?.token;

  /// Output: giá trị RAM synthetic, không phải evidence secure storage.
  @override
  Future<StoredSessionCredential?> readSession() async => session;

  /// Lưu bearer/expiry synthetic của repository, không log hoặc gọi native storage.
  /// Input
  /// Param: value — candidate credential đã parse của luồng đang kiểm.
  @override
  Future<void> writeSession(StoredSessionCredential value) async {
    session = value;
  }

  /// Giữ ACK qua một busy frame để producer kiểm gesture recovery, không sửa clock/App.
  @override
  Future<void> deleteSession() {
    if (immediateDelete) {
      session = null;
      return Future<void>.value();
    }
    final result = Completer<void>();
    replies.add(
      /// Timer case sở hữu actual callback; chỉ ACK sau khi clear own RAM value.
      () {
        session = null;
        result.complete();
      },
    );
    return result.future;
  }

  /// Trả tombstone fixture nếu flow logout đã ghi durable intent.
  /// Output: record RAM synthetic hoặc null khi chưa có logout.
  @override
  Future<PendingLogoutIntent?> readLogoutIntent() async => logoutIntent;

  /// Ghi tombstone fixture trước khi repository xóa active session.
  /// Input
  /// Param: intent — bearer đầy quyền chỉ được repository dùng trong worker logout, cùng metadata retry synthetic.
  @override
  Future<void> writeLogoutIntent(PendingLogoutIntent intent) async {
    logoutIntent = intent;
  }

  /// Xóa record fixture sau terminal response.
  @override
  Future<void> deleteLogoutIntent() async {
    logoutIntent = null;
  }
}

/// Output: một packet synthetic đủ năm identity đúng schema, không gửi vào API/DB thật.
Map<String, Object?> packet() => {
  'password': 'Aa1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  'emails': List.generate(
    5,

    /// Giữ namespace/order5identities giống original fixture nhưng chỉ dùng trong host test.
    (index) => 'probe-$_runId-$index@example.invalid',
  ),
};

/// Chạy producer qua App/repository/coordinator thật với API/store/canary synthetic đã ghi rõ.
/// Side effects: chỉ RAM/host widget; không gọi plugin storage, Auth hoặc PostgreSQL.
void main() {
  for (final fails in [false, true]) {
    test(
      'offline credentials are released after body failure=$fails',

      /// Lỗi trước main cũng phải bỏ reference, không cần credential parser hoặc network.
      () async {
        final value = <String, Object?>{'password': 'synthetic-only'};
        final pending = withNativeOfflineCredentials(
          value,

          /// Fault wrapper độc lập, không giả framework/DB PASS.
          () async {
            if (fails) throw StateError('EARLY_NATIVE_FAILURE');
          },
        );
        if (fails) {
          await expectLater(pending, throwsStateError);
        } else {
          await pending;
        }
        expect(value['password'], isEmpty);
      },
    );
  }
  for (final mode in [
    'success',
    'fast-delete',
    'late-mount',
    'pending',
    'unexpected-login-success',
    'wrong-role',
    'changed-epoch',
    'route-ineffective',
    'mixed-packet',
  ]) {
    testWidgets(
      'offline producer fences $mode',

      /// Own timer và response queue được drain trước App close, cả khi producer fail.
      /// Input
      /// Param: tester — host widget runtime, không emulator/TLS/storage evidence.
      (tester) async {
        final api = OfflineApi(mode);
        final store = OfflineStore(
          api.replies,
          immediateDelete: mode == 'fast-delete',
        );
        final coordinator = AppAuthCoordinator(
          repository: AppSessionRepository(
            api: api,
            workspaceApi: api,
            tokenStore: store,

            retryTimerFactory:
                /// Timer giả giữ retry ngoài cửa sổ assertion để test đúng state pending hiện tại.
                (duration, callback) =>
                    Timer(const Duration(days: 30), callback),

            /// Candidate synthetic hợp lệ trong host case, không đổi server clock.
            now: () => DateTime.utc(2026, 11, 12),
          ),
        );
        final watch = Stopwatch()..start();
        final stages = <String>[];
        var probes = 0;
        Timer? timer;
        final value = packet();
        if (mode == 'mixed-packet')
          (value['emails'] as List)[1] = 'other@example.invalid';
        try {
          await tester.pumpWidget(AppAuthApplication(coordinator: coordinator));
          await tester.pumpAndSettle();
          await tester.runAsync(
            /// Response thứ tự FIFO qua timer thật để producer phải thấy fresh busy.
            () async {
              timer = Timer.periodic(
                const Duration(milliseconds: 150),

                /// Mỗi tick chỉ nhả một response, không gọi business action thay UI.
                (tick) {
                  if (api.replies.isNotEmpty) api.replies.removeAt(0)();
                },
              );
            },
          );
          final pending = verifyNativeOfflineScenario(
            tester,
            value,
            elapsed:
                /// Stopwatch thật của host; quiet30s không fast-forward bằng pump.
                () =>
                    watch.elapsed +
                    (mode == 'late-mount'
                        ? const Duration(seconds: 20)
                        : Duration.zero),
            checkpoint:
                /// Gate host synthetic chỉ giữ ledger hoặc inject lifecycle fault; không DB/network proof.
                (stage) async {
                  stages.add(stage);
                  if (mode == 'changed-epoch' && stage == 'offline-ready')
                    coordinator.suspend();
                },
            markStage:
                /// Không log input từ thao tác, diagnostics đã fixed enum trong producer.
                (stage) {},
            probe:
                /// Route enum injection chỉ cho host test; actual default dùng product TLS factory.
                () async {
                  probes++;
                  if (mode == 'late-mount')
                    return NativeOfflineRoute.unavailable;
                  return probes == 2 && mode != 'route-ineffective'
                      ? NativeOfflineRoute.unavailable
                      : NativeOfflineRoute.reachable;
                },
            tokenStore: store,
          );
          if (mode == 'success' || mode == 'fast-delete') {
            await pending;
            expect(stages, [
              'offline-ready',
              'offline-result',
              'offline-quiet',
              'offline-picker',
              'offline-outbox-ready',
              'offline-outbox-persisted',
            ]);
            expect(api.events, [
              'offline-login',
              'login',
              'profile',
              'list',
              'detail-a',
              'list',
              'detail-b',
              'logout-offline',
            ]);
            expect(probes, 3);
            expect(api.attempts, 2);
            expect(store.value, isNull);
            expect(store.logoutIntent?.sessionToken, isNotEmpty);
            expect(store.logoutIntent?.expiresAt, isNotNull);
            expect(
              watch.elapsed,
              greaterThanOrEqualTo(const Duration(seconds: 30)),
            );
          } else {
            final expected = switch (mode) {
              'mixed-packet' => 'INVALID_NATIVE_OFFLINE_PACKET',
              'late-mount' => 'NATIVE_OFFLINE_UI_TIMEOUT',
              'changed-epoch' => 'NATIVE_OFFLINE_UNEXPECTED_INTENT',
              'route-ineffective' => 'NATIVE_OFFLINE_ROUTE_INVALID',
              'wrong-role' => 'NATIVE_OFFLINE_PICKER_INVALID',
              _ => 'NATIVE_OFFLINE_SIGNED_OUT_INVALID',
            };
            await expectLater(
              pending,
              throwsA(
                isA<StateError>().having(
                  /// Chỉ đối chiếu fixed diagnostic, không đưa state/credential vào assertion output.
                  (error) => error.message,
                  'code',
                  expected,
                ),
              ),
            );
            expect(
              api.attempts,
              lessThanOrEqualTo(mode == 'wrong-role' ? 2 : 1),
            );
            if (mode == 'late-mount') {
              expect(probes, 0);
              expect(api.attempts, 0);
            }
          }
        } finally {
          await tester.runAsync(
            /// Không bỏ timer/response Future sau fault hoặc khi producer timeout.
            () async {
              try {
                // Close phải join response/delete Future; giữ timer sống tới ACK thật để không deadlock cleanup.
                await coordinator.close();
              } finally {
                timer?.cancel();
                while (api.replies.isNotEmpty) {
                  api.replies.removeAt(0)();
                }
              }
            },
          );
          value['password'] = '';
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}
