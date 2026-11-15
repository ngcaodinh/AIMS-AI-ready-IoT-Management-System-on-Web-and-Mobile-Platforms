import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../lib/main.dart';
import '../../lib/features/auth/data/app_auth_failure.dart';
import '../../lib/features/auth/presentation/app_auth_application.dart';
import '../../lib/features/auth/presentation/login_screen.dart';
import '../../lib/features/auth/presentation/password_change_screen.dart';
import '../../lib/features/workspaces/data/workspace_access_detail.dart';
import '../../lib/features/workspaces/presentation/workspace_selection_screen.dart';
import '../contracts/workspace_access_detail_test.dart' as detail;
import 'app_auth_coordinator_test.dart' as coordinator;
import 'app_session_repository_test.dart' as session;
import 'password_change_screen_test.dart' as password;

/// Scenario giữ test logic riêng, còn scope chịu ownership của mọi coordinator và gate tổng hợp.
typedef ApplicationScenario = Future<void> Function(
  WidgetTester tester,
  ApplicationTestScope scope,
);

/// Một lifetime fixture cho từng widget test; không dùng global registry hoặc FakeAsync để chờ close SDK.
final class ApplicationTestScope {
  /// Nhận binding hiện hành để tách cleanup thật khỏi đồng hồ mô phỏng UI.
  /// Input
  /// Param: tester — runner của đúng case, không tái sử dụng giữa tests.
  ApplicationTestScope(this.tester);

  final WidgetTester tester;
  final _harnesses = <coordinator.CoordinatorHarness>[];
  final _gateReleases = <VoidCallback>[];
  bool _closed = false;

  /// Output: true chỉ sau ACK đóng toàn bộ coordinator và unmount hoàn tất.
  bool get isClosed => _closed;

  /// Output: fixture mới được theo dõi để assertion lỗi vẫn giải phóng đúng ownership.
  coordinator.CoordinatorHarness createHarness() {
    final harness = coordinator.CoordinatorHarness();
    _harnesses.add(harness);
    return harness;
  }

  /// Đăng ký xả source Future trước cleanup, không giả native Future bị hủy khi test lỗi.
  /// Input
  /// Param: release — chỉ complete gate synthetic do case sở hữu, không network hoặc credential thật.
  void releaseOnFinish(VoidCallback release) => _gateReleases.add(release);

  /// Tạo và quan sát close trong cùng real zone trước widget dispose, tránh deadlock xuyên FakeAsync.
  /// Input
  /// Param: harness — đúng coordinator/repository lifetime được scope theo dõi.
  Future<void> closeHarness(coordinator.CoordinatorHarness harness) async {
    var acknowledged = false;
    await tester.runAsync(
      /// Năm giây là cận cleanup fixture sau khi xả gate, không thay deadline API hoặc giả I/O đã hủy.
      () async {
        await harness.coordinator.close().timeout(const Duration(seconds: 5));
        acknowledged = true;
      },
    );
    expect(
      acknowledged,
      isTrue,
      reason: 'Cleanup phải có ACK thật trước khi kết thúc fixture.',
    );
  }

  /// Xả gates, drain coordinator rồi unmount ngay cả khi assertion business trước đó thất bại.
  Future<void> finish() async {
    if (_closed) return;
    for (final release in _gateReleases) {
      release();
    }
    await tester.pump();
    try {
      for (final harness in _harnesses) {
        await closeHarness(harness);
      }
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }
    _closed = true;
  }
}

/// Dựng host với real coordinator/repository; chỉ API/store fake được inject ở fixture.
/// Input
/// Param: tester — widget runner thực hiện interaction, không screenshot-only.
/// Param: harness — lifetime riêng cho test, không credentials thật.
/// Param: scale — cỡ chữ accessibility giữ nguyên, không clamp.
/// Param: dark — lựa chọn theme bằng button trong app, không sửa theme source.
Future<void> pumpApplication(
  WidgetTester tester,
  coordinator.CoordinatorHarness harness, {
  double scale = 1,
  bool dark = false,
}) async {
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData.fromView(
        tester.view,
      ).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
      child: AppAuthApplication(coordinator: harness.coordinator),
    ),
  );
  await tester.pumpAndSettle();
  if (dark) {
    await tapControl(tester, 'app-theme');
    await tester.pumpAndSettle();
  }
}

/// Cuộn và bấm control thật; missing/obscured target làm test fail.
/// Input
/// Param: tester — runtime widget case.
/// Param: key — key control host/component đã render.
Future<void> tapControl(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.tap(target);
  await tester.pump();
}

/// Nhập login qua form thật, không gọi coordinator trực tiếp để bỏ qua validation/UI.
/// Input
/// Param: tester — runner thực hiện bàn phím và CTA.
Future<void> submitLogin(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey('auth-email')),
    session.sessionEmail,
  );
  await tester.enterText(
    find.byKey(const ValueKey('auth-password')),
    session.privatePassword,
  );
  await tapControl(tester, 'auth-submit');
  await tester.pumpAndSettle();
}

/// Main flow phải đợi server detail và logout/delete ACK, không mở summary từ summary row.
/// Input
/// Param: tester — runner tương tác từ login tới logout.
/// Param: scope — ownership của harness/gates, được đóng trong finally của scenario.
Future<void> checkApplicationFlow(
  WidgetTester tester,
  ApplicationTestScope scope,
) async {
  final harness = scope.createHarness();
  harness.source.store.value = null;
  await pumpApplication(tester, harness);
  expect(find.byType(LoginScreen), findsOneWidget);
  await submitLogin(tester);
  expect(find.byType(WorkspaceSelectionScreen), findsOneWidget);
  expect(harness.source.capability.listCalls.length, 1);
  final detailGate = Completer<WorkspaceAccessDetail>();
  scope.releaseOnFinish(
    /// Assertion lỗi vẫn phải thả owned detail Future trước close để test không treo cleanup.
    () {
      if (!detailGate.isCompleted)
        detailGate.complete(harness.source.capability.selected);
    },
  );
  harness.source.capability.detailGate = detailGate;
  await tapControl(tester, 'workspace-select-${detail.workspaceIdentity}');
  expect(find.byKey(const ValueKey('session-summary')), findsNothing);
  detailGate.complete(harness.source.capability.selected);
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('session-summary')), findsOneWidget);
  expect(find.text(session.sessionEmail), findsOneWidget);
  expect(find.text(harness.source.capability.selected.name), findsOneWidget);
  final logoutGate = Completer<void>();
  final deleteGate = Completer<void>();
  scope.releaseOnFinish(
    /// Xả hai ACK tổng hợp kể cả case fail, không giả rằng logout Future đã bị hủy.
    () {
      if (!logoutGate.isCompleted) logoutGate.complete();
      if (!deleteGate.isCompleted) deleteGate.complete();
    },
  );
  harness.source.auth.logoutGate = logoutGate;
  harness.source.store.deleteGate = deleteGate;
  await tapControl(tester, 'session-logout');
  expect(find.byType(LoginScreen), findsNothing);
  logoutGate.complete();
  await tester.pump();
  expect(find.byType(LoginScreen), findsNothing);
  deleteGate.complete();
  await tester.pumpAndSettle();
  expect(find.byType(LoginScreen), findsOneWidget);
  expect(harness.source.store.value, isNull);
  expect(harness.source.auth.logoutTokens, [session.sessionToken]);
  await scope.finish();
  expect(
    scope.isClosed,
    isTrue,
    reason:
        'Fixture phải drain trước khi test kết thúc; không bỏ Future đang chờ.',
  );
}

/// Limited chỉ có đổi password/logout,204+cleanup đưa login và không gọi API workspace.
/// Input
/// Param: tester — runner form current/new/confirmation thật.
/// Param: scope — sở hữu fixture password-only và cleanup khi case kết thúc.
Future<void> checkLimitedPasswordFlow(
  WidgetTester tester,
  ApplicationTestScope scope,
) async {
  final harness = scope.createHarness();
  harness.source.store.value = null;
  harness.source.auth.result = session.issuedSession(limited: true);
  await pumpApplication(tester, harness);
  await submitLogin(tester);
  expect(find.byType(PasswordChangeScreen), findsOneWidget);
  expect(find.byKey(const ValueKey('app-back')), findsNothing);
  await password.fillPasswords(tester, 'old', 'NewPass123');
  await tapControl(tester, 'password-submit');
  await tester.pumpAndSettle();
  expect(find.byType(LoginScreen), findsOneWidget);
  expect(harness.source.capability.passwordCalls.length, 1);
  expect(harness.source.capability.listCalls, isEmpty);
  expect(harness.source.store.value, isNull);
}

/// Full known denial có đối soát thật, back tường minh tải picker mới, không POST lại password.
/// Input
/// Param: tester — runner native controls và lifecycle giả lập.
/// Param: scope — sở hữu fixture full session và cleanup đúng zone.
Future<void> checkFullPasswordRecovery(
  WidgetTester tester,
  ApplicationTestScope scope,
) async {
  final harness = scope.createHarness();
  await pumpApplication(tester, harness);
  await tapControl(tester, 'workspace-password');
  await tester.pumpAndSettle();
  harness.source.capability.failure = const AppAuthFailure(
    AppAuthFailureKind.permissionDenied,
  );
  await password.fillPasswords(tester, 'old', 'NewPass123');
  await tapControl(tester, 'password-submit');
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('password-recover')), findsOneWidget);
  harness.source.capability.failure = null;
  final previous = harness.source.auth.profileTokens.length;
  await tapControl(tester, 'password-recover');
  await tester.pumpAndSettle();
  expect(harness.source.auth.profileTokens.length, previous + 1);
  expect(harness.source.capability.passwordCalls.length, 1);
  expect(find.byKey(const ValueKey('password-current')), findsOneWidget);
  await tapControl(tester, 'app-back');
  await tester.pumpAndSettle();
  expect(find.byType(WorkspaceSelectionScreen), findsOneWidget);
  expect(harness.source.capability.listCalls.length, 2);
}

/// Countdown card không có form có thể gửi; hết giờ chỉ render form, không auto POST.
/// Input
/// Param: tester — runner clock/timer có kiểm soát.
/// Param: scope — hủy timer/đóng fixture sau khi kiểm cooldown.
Future<void> checkApplicationCooldown(
  WidgetTester tester,
  ApplicationTestScope scope,
) async {
  final harness = scope.createHarness();
  harness.source.store.value = null;
  harness.source.auth.loginFailure = const AppAuthFailure(
    AppAuthFailureKind.rateLimited,
    retryAfterSeconds: 2,
  );
  await pumpApplication(tester, harness);
  await submitLogin(tester);
  expect(find.byKey(const ValueKey('app-cooldown')), findsOneWidget);
  expect(find.text('Thử lại sau 2 giây'), findsOneWidget);
  expect(find.byKey(const ValueKey('auth-submit')), findsNothing);
  harness.seconds = 2;
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
  expect(find.byType(LoginScreen), findsOneWidget);
  expect(harness.source.auth.loginInputs.length, 1);
}

/// Lỗi storage không là empty/login; recovery có thao tác và không hiển thị logout no-op.
/// Input
/// Param: tester — runner kiểm safe copy và action availability.
/// Param: scope — đóng fixture storage-failure ngay cả khi assertion lỗi.
Future<void> checkApplicationRecovery(
  WidgetTester tester,
  ApplicationTestScope scope,
) async {
  final harness = scope.createHarness();
  harness.source.store.failRead = true;
  await pumpApplication(tester, harness);
  expect(find.byKey(const ValueKey('app-recovery')), findsOneWidget);
  expect(find.byKey(const ValueKey('recovery-logout')), findsNothing);
  harness.source.store.failRead = false;
  await tapControl(tester, 'app-recover');
  await tester.pumpAndSettle();
  expect(find.byType(LoginScreen), findsOneWidget);
  expect(harness.source.capability.listCalls, isEmpty);
}

/// Mount khi app đã inactive không được admit trước event resumed; background sau đó che picker ngay.
/// Input
/// Param: tester — binding gửi lifecycle theo đúng API framework.
/// Param: scope — theo dõi coordinator qua các event lifecycle của case.
Future<void> checkApplicationLifecycle(
  WidgetTester tester,
  ApplicationTestScope scope,
) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  final harness = scope.createHarness();
  await tester.pumpWidget(AppAuthApplication(coordinator: harness.coordinator));
  await tester.pump();
  expect(harness.source.store.reads, 0);
  expect(find.byType(WorkspaceSelectionScreen), findsNothing);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpAndSettle();
  expect(find.byType(WorkspaceSelectionScreen), findsOneWidget);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  await tester.pump();
  expect(find.byType(WorkspaceSelectionScreen), findsNothing);
  expect(find.byKey(const ValueKey('app-loading')), findsOneWidget);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpAndSettle();
  expect(harness.source.capability.listCalls.length, 2);
}

/// Recovery/cooldown cards giữ controls reachable ở375dp/ngang chữ200%, cả hai theme và reduced motion.
/// Input
/// Param: tester — view override chỉ trong test, không thay Android settings thật.
/// Param: scope — theo dõi từng fixture layout và drain trước unmount/chuyển theme.
Future<void> checkApplicationResponsive(
  WidgetTester tester,
  ApplicationTestScope scope,
) async {
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  for (final size in [const Size(375, 812), const Size(812, 375)]) {
    for (final dark in [false, true]) {
      tester.view.physicalSize = size;
      final harness = scope.createHarness();
      harness.source.store.failRead = true;
      await pumpApplication(tester, harness, scale: 2, dark: dark);
      await tester.ensureVisible(find.byKey(const ValueKey('app-recover')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byKey(const ValueKey('app-recover'))).height,
        greaterThanOrEqualTo(48),
      );
      await scope.closeHarness(harness);
      await tester.pumpWidget(const SizedBox());
    }
  }
}

/// Main thiếu origin phải chặn cấu hình, không dùng Hello World hoặc fake authenticated preview.
/// Input
/// Param: tester — runner startup main không thực hiện network/native storage.
/// Param: scope — bảo đảm root bị gỡ dù cấu hình không tạo coordinator.
Future<void> checkMissingConfiguration(
  WidgetTester tester,
  ApplicationTestScope scope,
) async {
  const origins = [
    '',
    'http://localhost:3000',
    'https://example.invalid/path',
    'https://example.invalid?query=1',
    'https://example.invalid#fragment',
  ];
  for (var index = 0; index < origins.length; index++) {
    // Origin là fixture không secret; key mới kiểm startup mỗi cấu hình, không đổi endpoint của lifetime cũ.
    await tester.pumpWidget(
      MainApp(key: ValueKey(index), apiOrigin: origins[index]),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('app-configuration')), findsOneWidget);
    expect(find.byType(LoginScreen), findsNothing);
    expect(find.text('Hello World!'), findsNothing);
  }
}

/// Đăng ký widget interactions; imported modules chỉ dùng fake/helpers, không gọi main của suite khác.
void main() {
  final scenarios = <(String, ApplicationScenario)>[
    (
      'app login to server-rechecked summary and logout waits both ACKs',
      checkApplicationFlow,
    ),
    (
      'limited app session changes password then requires login without workspace requests',
      checkLimitedPasswordFlow,
    ),
    (
      'full password permission recovery is actionable and back refreshes picker',
      checkFullPasswordRecovery,
    ),
    (
      'app countdown disables submit and never automatically retries login',
      checkApplicationCooldown,
    ),
    (
      'initial storage recovery has no ineffective logout action',
      checkApplicationRecovery,
    ),
    (
      'host mounted inactive waits resumed and hides protected UI on background',
      checkApplicationLifecycle,
    ),
    (
      'business status cards scroll at large text in both themes and orientations',
      checkApplicationResponsive,
    ),
    (
      'main missing API origin fails closed with configuration screen',
      checkMissingConfiguration,
    ),
  ];
  for (final (name, scenario) in scenarios) {
    testWidgets(
      name,

      /// Input
      /// Param: tester — runner riêng case; finally luôn đóng đúng các fixture scenario đã tạo.
      (tester) async {
        final scope = ApplicationTestScope(tester);
        try {
          await scenario(tester, scope);
        } finally {
          await scope.finish();
        }
      },
    );
  }
}
