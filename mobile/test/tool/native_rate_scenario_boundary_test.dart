import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexa_iot/features/auth/presentation/app_auth_application.dart';
import 'package:nexa_iot/features/auth/presentation/app_auth_coordinator.dart';
import 'package:nexa_iot/features/auth/data/app_auth_api.dart';
import 'package:nexa_iot/features/auth/data/app_auth_failure.dart';
import 'package:nexa_iot/features/auth/data/app_login_response.dart';
import 'package:nexa_iot/features/auth/data/app_session_repository.dart';
import 'package:nexa_iot/features/auth/data/full_session_profile.dart';
import 'package:nexa_iot/features/auth/data/session_token_store.dart';

import '../../integration_test/support/native_rate_scenario.dart';

// Fixture cũ import lib bằng file URI làm Type khác package URI của native target.
// Dùng cùng package URI cho producer và host để find.byType kiểm đúng class thật.

/// Chỉ cung cấp typed rejection qua gate, không giữ input secret hoặc tạo phiên giả.
final class RateRejectionApi implements AppAuthApi {
  final events = <String>[];
  var loginCalls = 0;
  var profileCalls = 0;
  var gate = Completer<AppLoginResponse>();

  /// Nhận intent synthetic để kiểm một submit UI tương ứng một API call và chờ response gate.
  /// Input
  /// Param: email — email từ form đã validation, chỉ đi qua boundary test.
  /// Param: password — password synthetic của lần tap, chỉ đi qua boundary test.
  /// Output
  /// Future do case sở hữu để chốt lúc typed rejection được giao.
  /// Side effects
  /// Tăng loginCalls cho từng API intent.
  @override
  Future<AppLoginResponse> login(String email, String password) {
    loginCalls++;
    return gate.future;
  }

  /// Bắt profile request sai trước successful login bằng counter và lỗi fixed.
  /// Input
  /// Param: token — candidate bearer mà caller thử dùng tại boundary profile.
  /// Errors
  /// StateError fixed để bất kỳ profile request nào cũng làm case âm thất bại.
  /// Side effects
  /// Tăng profileCalls trước khi throw.
  @override
  Future<FullSessionProfile> getProfile(String token) async {
    profileCalls++;
    throw StateError('UNEXPECTED_PROFILE_READ');
  }

  /// Bắt revoke ngoài dự kiến trong scenario chỉ có rejected login.
  /// Input
  /// Param: token — candidate caller thử revoke tại API boundary.
  /// Errors
  /// StateError fixed chỉ rõ revoke sai.
  /// Side effects
  /// Ghi enum unexpected-logout vào ledger test.
  @override
  Future<void> logout(String token) async {
    events.add('unexpected-logout');
    throw StateError('UNEXPECTED_LOGOUT');
  }
}

/// Store rỗng chỉ hỗ trợ bootstrap/clear, không tạo bearer hoặc đọc plugin thật.
final class RejectedSessionStore implements SessionTokenStore {
  /// Không có phiên lưu, caller phải hiển thị login.
  @override
  Future<StoredSessionCredential?> readSession() async => null;

  /// Bắt ghi bearer ngoài dự kiến sau rejected login bằng lỗi fixed.
  /// Input
  /// Param: session — candidate caller thử đưa vào store test.
  /// Errors
  /// StateError fixed để chặn case âm ghi nhận thành công giả.
  @override
  Future<void> writeSession(StoredSessionCredential session) async =>
      throw StateError('UNEXPECTED_TOKEN_WRITE');

  /// Clear rỗng ACK ngay vì không có native storage hoặc key trong fixture.
  @override
  Future<void> deleteSession() async {}

  /// Outbox vắng vì test chỉ kiểm rejected login, chưa phát logout intent.
  @override
  Future<PendingLogoutIntent?> readLogoutIntent() async => null;

  /// Rejected-login scenario không được ghi revoke outbox.
  /// Input
  /// Param: intent — candidate unexpected, không được persist trong fixture này.
  @override
  Future<void> writeLogoutIntent(PendingLogoutIntent intent) async =>
      throw StateError('UNEXPECTED_LOGOUT_INTENT');

  /// Outbox rỗng nên cleanup ACK ngay mà không có native side effect.
  @override
  Future<void> deleteLogoutIntent() async {}
}

/// Chỉ giành gesture CTA đã được case xác nhận để tái hiện tap bị nuốt, vẫn cho input/scroll hoạt động.
final class SubmitOnlyEagerRecognizer extends EagerGestureRecognizer {
  /// Nhận predicate geometry/input của widget đang mount, giữ fault trong đúng submit thử nghiệm.
  /// Input
  /// Param: acceptsSubmitPointer — kiểm pointer thuộc CTA hợp lệ tại thời điểm down.
  SubmitOnlyEagerRecognizer(this.acceptsSubmitPointer);

  final bool Function(PointerDownEvent) acceptsSubmitPointer;

  /// Chỉ tham gia arena của pointer CTA đủ điều kiện, rồi dùng quy tắc nút chuột mặc định của SDK.
  /// Input
  /// Param: event — pointer down hiện hành được framework đưa tới detector.
  /// Output: true khi fault được phép nuốt gesture này.
  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      acceptsSubmitPointer(event) && super.isPointerAllowed(event);
}

/// Chạy producer thật trên widget/coordinator/repository thật, chỉ API/store synthetic.
/// Case tap bị nuốt đợi operation20s bằng Stopwatch, API/store vẫn synthetic. Các case khác dừng theo fault riêng.
void main() {
  for (final mode in [
    'invalid-form',
    'swallowed-tap',
    'early-rate',
    'missing-rate',
    'changed-epoch',
  ]) {
    testWidgets(
      'native rate producer fences $mode before the next ACK',

      /// Mỗi case sở hữu App và response timer riêng, luôn drain trước unmount.
      /// Input
      /// Param: tester — widget runtime của case, dùng pump/input/lookup và real-zone cleanup.
      (tester) async {
        final api = RateRejectionApi();
        final coordinator = AppAuthCoordinator(
          repository: AppSessionRepository(
            api: api,
            tokenStore: RejectedSessionStore(),
          ),
        );
        final clock = Stopwatch()..start();
        final checkpoints = <String>[];
        final marked = <String>[];
        Timer? replyTimer;
        Duration? requestObservedAt;
        var delivered = 0;
        var validationObserved = false;
        var epochChanged = false;
        final submitPointerDown = <int>[];
        final submitPointerUp = <int>[];
        Duration? firstSubmitMarkedAt;
        Duration? submitPointerUpAt;
        var postTapWaitObserved = false;

        /// Kiểm đúng CTA với input hợp lệ ngay khi down để fault không nuốt focus/scroll trước submit.
        /// Input
        /// Param: event — pointer cần đối chiếu với geometry của button hiện hành.
        /// Output: true chỉ cho submit đầu tiên, enabled/hit-testable, input synthetic đã đúng và chưa validation.
        bool acceptsSubmitPointer(PointerDownEvent event) {
          final submit = find.byKey(const ValueKey('auth-submit'));
          if (marked.isEmpty ||
              marked.last != 'rate-wrong-1' ||
              submit.evaluate().length != 1 ||
              submit.hitTestable().evaluate().length != 1 ||
              !tester.getRect(submit).contains(event.position) ||
              tester.widget<FilledButton>(submit).onPressed == null ||
              find
                  .byKey(const ValueKey('auth-validation-summary'))
                  .evaluate()
                  .isNotEmpty) {
            return false;
          }
          final email = tester.widget<TextFormField>(
            find.byKey(const ValueKey('auth-email')),
          );
          final password = tester.widget<TextFormField>(
            find.byKey(const ValueKey('auth-password')),
          );
          return email.controller!.text == 'test@example.invalid' &&
              password.controller!.text == 'Aa2${'b' * 32}';
        }

        try {
          final application = AppAuthApplication(coordinator: coordinator);
          await tester.pumpWidget(
            mode == 'swallowed-tap'
                ? RawGestureDetector(
                    gestures: {
                      SubmitOnlyEagerRecognizer:
                          GestureRecognizerFactoryWithHandlers<
                            SubmitOnlyEagerRecognizer
                          >(
                            /// Tạo interceptor test-only, chỉ predicate đúng CTA mới cấp quyền vào arena.
                            () =>
                                SubmitOnlyEagerRecognizer(acceptsSubmitPointer),

                            /// Recognizer không có mutable handler, factory giữ cùng predicate của case.
                            (_) {},
                          ),
                    },
                    child: Listener(
                      /// Ghi witness input/hit/enable đã đủ tại pointer down, không giữ giá trị field trong ledger.
                      /// Input
                      /// Param: event — pointer down đã đi qua hit path của App thật.
                      onPointerDown: (event) {
                        if (acceptsSubmitPointer(event))
                          submitPointerDown.add(event.pointer);
                      },

                      /// Chốt cùng pointer up để phân biệt tap hoàn chỉnh với drag/cancel.
                      /// Input
                      /// Param: event — pointer up của gesture đang được quan sát.
                      onPointerUp: (event) {
                        if (submitPointerDown.contains(event.pointer)) {
                          submitPointerUp.add(event.pointer);
                          submitPointerUpAt = clock.elapsed;
                        }
                      },
                      child: application,
                    ),
                  )
                : application,
          );
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('auth-email')), findsOneWidget);
          expect(find.byType(AppAuthApplication), findsOneWidget);
          await tester.runAsync(
            /// Timer ở real zone giữ loading đủ lâu để producer quan sát busy trước response.
            () async {
              replyTimer = Timer.periodic(
                const Duration(milliseconds: 10),

                /// Đáp đúng một typed failure cho mỗi UI intent, không gọi coordinator thay tap.
                /// Input
                /// Param: _ — tick timer thật; ownership hủy timer được giữ ở replyTimer bên ngoài.
                (_) {
                  if (api.loginCalls <= delivered) return;
                  requestObservedAt ??= clock.elapsed;
                  if (clock.elapsed - requestObservedAt! <
                      const Duration(milliseconds: 150))
                    return;
                  final gate = api.gate;
                  api.gate = Completer<AppLoginResponse>();
                  delivered++;
                  requestObservedAt = null;
                  final rate =
                      mode == 'early-rate' ||
                      (delivered == 6 && mode != 'missing-rate');
                  // Mỗi response tạo object mới để không giả replay failure cũ bằng const canonicalization.
                  gate.completeError(
                    rate
                        ? AppAuthFailure(
                            AppAuthFailureKind.rateLimited,
                            retryAfterSeconds: 900,
                          )
                        : AppAuthFailure(AppAuthFailureKind.invalidCredentials),
                  );
                },
              );
            },
          );
          await expectLater(
            verifyNativeRateScenario(
              tester,
              {
                'password': 'Aa1${'a' * 32}',
                'wrongPassword': 'Aa2${'b' * 32}',
                'emails': [
                  mode == 'invalid-form'
                      ? 'invalid-email'
                      : 'test@example.invalid',
                ],
              },

              /// Ca validation rút operation sau summary. Ca tap bị nuốt giữ Stopwatch thật và ghi wait sau pointer up.
              /// Output
              /// Duration host monotonic, chỉ cộng21s ở validation, cùng witness signedOut/loading absent sau tap bị nuốt.
              elapsed: () {
                validationObserved = find
                    .byKey(const ValueKey('auth-validation-summary'))
                    .evaluate()
                    .isNotEmpty;
                final current = clock.elapsed;
                if (mode == 'swallowed-tap' &&
                    submitPointerUpAt != null &&
                    current - submitPointerUpAt! >=
                        const Duration(milliseconds: 500) &&
                    coordinator.session.phase.name == 'signedOut' &&
                    find
                        .byKey(const ValueKey('app-loading'))
                        .evaluate()
                        .isEmpty) {
                  postTapWaitObserved = true;
                }
                return current +
                    (validationObserved
                        ? const Duration(seconds: 21)
                        : Duration.zero);
              },
              checkpoint:
                  /// Receipt trước lỗi phải giữ đúng stage, epoch thay ngay sau typed429 đã quan sát.
                  /// Input
                  /// Param: stage — enum producer đã quan sát, được ghi ledger trước fault injection.
                  (stage) async {
                    checkpoints.add(stage);
                    if (mode == 'swallowed-tap' && stage != 'rate-before') {
                      // Control bỏ interceptor phải chứng minh API1 đã được typed response trước fixed failure.
                      expect(api.loginCalls, 1);
                      expect(delivered, 1);
                      throw StateError('SWALLOWED_TAP_CONTROL_API_ONCE');
                    }
                    if (mode == 'changed-epoch' && stage == 'rate-limited') {
                      final before = coordinator.session;
                      final generation = coordinator.generation;
                      coordinator.suspend();
                      await coordinator.resume();
                      // Restore store rỗng trả signedOut, nên noProtected phải qua trước identity/epoch guard.
                      expect(coordinator.session.phase.name, 'signedOut');
                      expect(coordinator.page.name, 'login');
                      expect(identical(before, coordinator.session), isFalse);
                      expect(coordinator.generation, greaterThan(generation));
                      epochChanged = true;
                    }
                  },
              markStage:
                  /// Ghi enum intent hiện hành để kiểm lỗi xảy ra ở đúng submit.
                  /// Input
                  /// Param: stage — tên intent producer sắp thực hiện, dùng đối chiếu stage cuối.
                  (stage) {
                    marked.add(stage);
                    if (mode == 'swallowed-tap' && stage == 'rate-wrong-1') {
                      firstSubmitMarkedAt = clock.elapsed;
                    }
                  },
            ),
            throwsA(
              isA<StateError>().having(
                /// Trích fixed code của boundary để matcher phân biệt lỗi cần kiểm với timeout khác.
                /// Input
                /// Param: error — StateError được future scenario trả về.
                /// Output
                /// Chuỗi fixed error code của producer.
                (error) => error.message,
                'boundary',
                ['invalid-form', 'swallowed-tap'].contains(mode)
                    ? 'NATIVE_RATE_UI_TIMEOUT'
                    : mode == 'changed-epoch'
                    ? 'NATIVE_RATE_UNEXPECTED_INTENT'
                    : 'NATIVE_RATE_FRESH_REJECTION_INVALID',
              ),
            ),
          );
          final wrongStages = [
            for (var index = 1; index <= 5; index++) 'rate-wrong-$index',
          ];
          expect(
            checkpoints,
            mode == 'missing-rate'
                ? ['rate-before', ...wrongStages]
                : mode == 'changed-epoch'
                ? ['rate-before', ...wrongStages, 'rate-limited']
                : ['rate-before'],
          );
          expect(
            api.loginCalls,
            ['invalid-form', 'swallowed-tap'].contains(mode)
                ? 0
                : mode == 'early-rate'
                ? 1
                : 6,
          );
          expect(delivered, api.loginCalls);
          expect(validationObserved, mode == 'invalid-form');
          expect(epochChanged, mode == 'changed-epoch');
          if (mode == 'swallowed-tap') {
            expect(submitPointerDown, hasLength(1));
            expect(submitPointerUp, submitPointerDown);
            expect(firstSubmitMarkedAt, isNotNull);
            expect(submitPointerUpAt, isNotNull);
            expect(
              submitPointerUpAt! - firstSubmitMarkedAt!,
              lessThan(const Duration(seconds: 20)),
            );
            expect(
              clock.elapsed - firstSubmitMarkedAt!,
              greaterThanOrEqualTo(const Duration(seconds: 20)),
            );
            expect(postTapWaitObserved, isTrue);
          }
          expect(
            marked.last,
            ['missing-rate', 'changed-epoch'].contains(mode)
                ? 'rate-limited'
                : 'rate-wrong-1',
          );
          expect(api.profileCalls, 0);
          expect(api.events, isEmpty);
        } finally {
          replyTimer?.cancel();
          // Chỉ gate đã có API consumer mới được reject khi assertion fail giữa operation.
          if (api.loginCalls > delivered && !api.gate.isCompleted) {
            api.gate.completeError(
              const AppAuthFailure(AppAuthFailureKind.invalidCredentials),
            );
          }
          await tester.runAsync(
            /// Drain real repository Future trước unmount, không gọi close từ FakeAsync.
            () async {
              await coordinator.close().timeout(const Duration(seconds: 5));
            },
          );
          await tester.pumpWidget(const SizedBox());
          clock.stop();
        }
      },
    );
  }
}
