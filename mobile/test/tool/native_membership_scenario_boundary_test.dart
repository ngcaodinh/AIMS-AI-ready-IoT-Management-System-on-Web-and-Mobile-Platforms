import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexa_iot/features/auth/data/app_auth_api.dart';
import 'package:nexa_iot/features/auth/data/app_auth_failure.dart';
import 'package:nexa_iot/features/auth/data/app_login_response.dart';
import 'package:nexa_iot/features/auth/data/app_session_repository.dart';
import 'package:nexa_iot/features/auth/data/full_session_profile.dart';
import 'package:nexa_iot/features/auth/data/session_token_store.dart';
import 'package:nexa_iot/features/auth/presentation/app_auth_application.dart';
import 'package:nexa_iot/features/auth/presentation/app_auth_coordinator.dart';
import 'package:nexa_iot/features/workspaces/data/available_workspace_page.dart';
import 'package:nexa_iot/features/workspaces/data/workspace_access_detail.dart';

import '../../integration_test/support/native_membership_scenario.dart';
import '../../integration_test/support/native_rate_scenario.dart';

const _user = '10000000-0000-4000-8000-000000000001';
const _a = '20000000-0000-4000-8000-000000000001';
const _b = '20000000-0000-4000-8000-000000000002';
const _email = 'probe-30000000-0000-4000-8000-000000000001-0@example.invalid';

/// API synthetic chỉ cho host test, giữ response pending đủ một busy frame thật.
/// Không dùng kết quả này thay evidence PostgreSQL/TLS/emulator.
final class MembershipApi implements AppAuthApi, AppWorkspaceApi {
  /// Input
  /// Param: mode — fault cố định của case, không nhận network/SQL hoặc selector ngoài test.
  MembershipApi(this.mode);
  final String mode;
  final events = <String>[];
  final replies = <void Function()>[];
  var suspended = false;

  /// Giữ một response tới timer real-zone, giúp producer phải quan sát busy trước completion.
  /// Input
  /// Param: event — enum request để case đối chiếu không có auto login hoặc replay.
  /// Param: reply — DTO hoặc typed failure synthetic do case cung cấp.
  /// Output: Future chỉ resolve khi timer của case drain callback.
  Future<T> _pending<T>(String event, T Function() reply) {
    events.add(event);
    final result = Completer<T>();
    replies.add(
      /// Chốt đúng một response, chuyển typed failure qua Future như API thật.
      () {
        try {
          result.complete(reply());
        } catch (error, stack) {
          result.completeError(error, stack);
        }
      },
    );
    return result.future;
  }

  /// Nhận input form qua UI thật, chỉ trả candidate synthetic và ghi intent một lần.
  /// Input
  /// Param: email — identity test được so ở profile/summary của producer.
  /// Param: password — chuỗi test chỉ tồn tại trong RAM, không ghi ledger.
  @override
  Future<AppLoginResponse> login(String email, String password) => _pending(
    'login',

    /// DTO được parser thật kiểm schema trước khi repository nhận.
    () => AppLoginResponse.fromJson({
      'me': {'id': _user, 'email': email, 'mustChangePassword': false},
      'limited': false,
      'token': 'synthetic_session_A',
      'expiresAt': '2027-01-01T00:00:00Z',
    }),
  );

  /// Trả profile cùng identity candidate, không cấp quyền từ store synthetic.
  /// Input
  /// Param: token — candidate repository gửi tới API boundary, không lưu/log.
  @override
  Future<FullSessionProfile> getProfile(String token) => _pending(
    'profile',

    /// Profile chỉ có fields công khai theo schema, không bearer.
    () => FullSessionProfile.fromJson({
      'id': _user,
      'email': _email,
      'mustChangePassword': false,
      'displayTimezone': 'UTC',
      'preferencesRevision': 1,
    }),
  );

  /// ACK logout synthetic qua timer để bắt fresh loggingOut, không tự tạo server audit.
  /// Input
  /// Param: token — bearer của own session, chỉ đi qua boundary mock.
  @override
  Future<void> logout(String token) => _pending<void>(
    'logout',

    /// Không có body trong response logout.
    () {},
  );

  /// Tải hai row trước suspend, chỉ A sau refresh, trừ fault stale-list cố ý giữ B.
  /// Input
  /// Param: token — authority riêng repository, API test không persist.
  /// Param: cursor — producer không được tự phân trang trong case hai row này.
  @override
  Future<AvailableWorkspacePage> listWorkspaces(
    String token, {
    String? cursor,
  }) => _pending(
    'list',

    /// Fault role/list chỉ đổi wire snapshot, không sửa coordinator hoặc cây UI.
    () => AvailableWorkspacePage.fromJson({
      'items': [
        {
          'id': _a,
          'name': 'Phòng vận hành A',
          'role': mode == 'wrong-role' ? 'USER' : 'ADMIN',
          'revision': 1,
          'status': 'ACTIVE',
        },
        if (!suspended || mode == 'stale-list')
          {
            'id': _b,
            'name': 'Nhà kính B',
            'role': 'USER',
            'revision': 1,
            'status': 'ACTIVE',
          },
      ],
      'nextCursor': null,
    }),
  );

  /// Recheck B bị từ chối sau checkpoint, A vẫn operational.
  /// Input
  /// Param: token — own bearer tại boundary test.
  /// Param: workspaceId — identity được phát ra từ tap row thật.
  @override
  Future<WorkspaceAccessDetail> getWorkspace(
    String token,
    String workspaceId,
  ) => _pending(
    workspaceId == _b ? 'detail-b' : 'detail-a',

    /// Chỉ fault b-open bỏ deny để kiểm producer từ chối success sai.
    () {
      if (workspaceId == _b && suspended && mode != 'b-open') {
        throw const AppAuthFailure(AppAuthFailureKind.resourceNotFound);
      }
      return WorkspaceAccessDetail.fromJson({
        'id': workspaceId,
        'name': workspaceId == _a ? 'Phòng vận hành A' : 'Nhà kính B',
        'description': null,
        'defaultTimezone': 'UTC',
        'status': 'ACTIVE',
        'revision': 1,
        'role': workspaceId == _a ? 'ADMIN' : 'USER',
        'creatorId': _user,
        'membershipStatus': 'ACTIVE',
        'authzVersion': 1,
        'membershipRevision': 1,
        'membershipAuthzVersion': 1,
        'createdAt': '2026-01-01T00:00:00Z',
        'archivedAt': null,
      });
    },
  );
}

/// Store RAM synthetic giúp repository thật kiểm write/delete ACK, không secure-storage evidence.
final class MembershipStore implements SessionTokenStore {
  StoredSessionCredential? session;
  PendingLogoutIntent? logoutIntent;
  /// Đọc bearer synthetic để test khẳng định local key đã clear sau logout.
  String? get value => session?.token;

  /// Output: giá trị test hiện hành, bootstrap bắt đầu null.
  @override
  Future<StoredSessionCredential?> readSession() async => session;

  /// Input
  /// Param: value — bearer/expiry candidate synthetic sau API success.
  @override
  Future<void> writeSession(StoredSessionCredential value) async {
    session = value;
  }

  /// Xóa own candidate test sau logout ACK, không tác động key native.
  @override
  Future<void> deleteSession() async {
    session = null;
  }

  /// Trả tombstone fixture để restore không mở profile sau logout pending.
  /// Output: record synthetic hoặc null nếu chưa phát logout.
  @override
  Future<PendingLogoutIntent?> readLogoutIntent() async => logoutIntent;

  /// Ghi intent synthetic theo thứ tự logout repository.
  /// Input
  /// Param: intent — bearer đầy quyền chỉ được repository dùng trong worker logout và retry metadata của scenario.
  @override
  Future<void> writeLogoutIntent(PendingLogoutIntent intent) async {
    logoutIntent = intent;
  }

  /// Xóa tombstone fixture sau terminal response.
  @override
  Future<void> deleteLogoutIntent() async {
    logoutIntent = null;
  }
}

/// Kiểm producer qua App/coordinator/repository thật, API/store đều synthetic và có ledger riêng.
void main() {
  for (final fails in [false, true]) {
    test(
      'membership packet clears secret after body fails=$fails',

      /// Wrapper phải bỏ reference khi body thành công hoặc lỗi trước main.
      () async {
        final packet = <String, Object?>{'password': 'synthetic-only'};
        final run = withNativeMembershipCredentials(
          packet,

          /// Body chỉ mô phỏng early TLS/main failure, không network hoặc credential thật.
          () async {
            expect(packet['password'], isNotEmpty);
            if (fails) throw StateError('EARLY_NATIVE_FAILURE');
          },
        );
        if (fails) {
          await expectLater(run, throwsStateError);
        } else {
          await run;
        }
        expect(packet['password'], isEmpty);
      },
    );
  }
  testWidgets(
    'shared UI keeps rate default and fixed membership phase cap',

    /// Kiểm clock exact boundary độc lập với UI/network, không pump nhanh giả native phase.
    /// Input
    /// Param: tester — runtime host chỉ cung cấp instance, không mount App trong ca guard.
    (tester) async {
      var current = const Duration(seconds: 419);

      /// Output: clock trusted của test, không wallclock hoặc SDK packet input.
      Duration elapsed() => current;
      final rate = NativeScenarioUi(tester, elapsed);
      final membership = NativeScenarioUi(
        tester,
        elapsed,
        phaseLimit: const Duration(seconds: 420),
        timeoutCode: 'NATIVE_MEMBERSHIP_UI_TIMEOUT',
      );
      membership.guard();
      current = const Duration(seconds: 420);
      expect(membership.guard, throwsStateError);
      rate.guard();
      current = const Duration(seconds: 1260);
      expect(rate.guard, throwsStateError);
      current = const Duration(seconds: -1);
      expect(rate.guard, throwsStateError);
    },
  );
  for (final mode in [
    'success',
    'wrong-role',
    'b-open',
    'stale-list',
    'changed-epoch',
    'phase-timeout',
  ]) {
    testWidgets(
      'membership producer fences $mode',

      /// Sở hữu timer/response/App của một case, drain trước unmount kể cả assertion failure.
      /// Input
      /// Param: tester — host widget runtime, chỉ nhập và tap qua producer.
      (tester) async {
        final api = MembershipApi(mode);
        final store = MembershipStore();
        final coordinator = AppAuthCoordinator(
          repository: AppSessionRepository(
            api: api,
            workspaceApi: api,
            tokenStore: store,

            /// Clock cố định chỉ để candidate synthetic chưa hết hạn trong host case.
            now: () => DateTime.utc(2026, 11, 10),
          ),
        );
        final clock = Stopwatch()..start();
        final stages = <String>[];
        Timer? timer;
        try {
          await tester.pumpWidget(AppAuthApplication(coordinator: coordinator));
          await tester.pumpAndSettle();
          await tester.runAsync(
            /// Timer thật giải response theo FIFO, không gọi action coordinator thay gesture.
            () async {
              timer = Timer.periodic(
                const Duration(milliseconds: 150),

                /// Chỉ một response mỗi tick để login/profile/list giữ đủ busy frame.
                /// Input
                /// Param: tick — timer do case sở hữu và hủy trong finally.
                (tick) {
                  if (api.replies.isNotEmpty) api.replies.removeAt(0)();
                },
              );
            },
          );
          final run = verifyNativeMembershipScenario(
            tester,
            {
              'password': 'Aa1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
              'emails': [_email],
            },

            /// Monotonic thật, fault phase-timeout dùng offset có chủ đích sau packet.
            elapsed: () =>
                clock.elapsed +
                (mode == 'phase-timeout'
                    ? const Duration(seconds: 420)
                    : Duration.zero),
            checkpoint:
                /// Host mock chỉ đổi capability API ở picker, không giả SQL mutation evidence.
                /// Input
                /// Param: stage — fixed checkpoint producer đã quan sát từ UI/state hiện hành.
                (stage) async {
                  stages.add(stage);
                  if (stage == 'membership-picker') {
                    api.suspended = true;
                    if (mode == 'changed-epoch') coordinator.suspend();
                  }
                },

            /// Không giữ diagnostics ngoài stage ledger trong boundary test này.
            /// Input
            /// Param: stage — enum thao tác sản phẩm, không cần lưu thêm trong case.
            markStage: (stage) {},
          );
          if (mode == 'success') {
            await run;
            expect(stages, [
              'membership-before-login',
              'membership-picker',
              'membership-denied',
              'membership-only-a',
              'membership-a-opened',
              'membership-logged-out',
            ]);
            expect(api.events, [
              'login',
              'profile',
              'list',
              'detail-b',
              'list',
              'detail-a',
              'logout',
            ]);
            expect(store.value, isNull);
          } else {
            final code = switch (mode) {
              'wrong-role' => 'NATIVE_MEMBERSHIP_PICKER_INVALID',
              'b-open' => 'NATIVE_MEMBERSHIP_DENIAL_INVALID',
              'stale-list' => 'NATIVE_MEMBERSHIP_PICKER_INVALID',
              'changed-epoch' => 'NATIVE_MEMBERSHIP_UNEXPECTED_INTENT',
              _ => 'NATIVE_MEMBERSHIP_UI_TIMEOUT',
            };
            await expectLater(
              run,
              throwsA(
                isA<StateError>().having(
                  /// Chỉ đối chiếu fixed error code để failure không xuất input/password.
                  /// Input
                  /// Param: error — StateError do producer chặn invariant.
                  (error) => error.message,
                  'code',
                  code,
                ),
              ),
            );
            expect(stages, switch (mode) {
              'phase-timeout' => <String>[],
              'wrong-role' => ['membership-before-login'],
              'stale-list' => [
                'membership-before-login',
                'membership-picker',
                'membership-denied',
              ],
              _ => ['membership-before-login', 'membership-picker'],
            });
            expect(
              api.events
                  .where(
                    /// Đếm mutation login để các nhánh lỗi không được tự POST lại.
                    /// Input
                    /// Param: event — fixed enum trong ledger synthetic của API.
                    (event) => event == 'login',
                  )
                  .length,
              mode == 'phase-timeout' ? 0 : 1,
            );
          }
        } finally {
          await tester.runAsync(
            /// Hủy timer rồi drain pending callback do case sở hữu trước close repository.
            () async {
              timer?.cancel();
              while (api.replies.isNotEmpty) {
                api.replies.removeAt(0)();
              }
              await coordinator.close();
            },
          );
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
        }
      },
    );
  }
}
