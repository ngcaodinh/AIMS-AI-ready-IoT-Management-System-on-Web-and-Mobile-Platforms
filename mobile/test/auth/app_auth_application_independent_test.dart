import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../lib/features/auth/data/app_auth_failure.dart';
import '../../lib/features/auth/presentation/login_screen.dart';
import '../../lib/features/auth/presentation/password_change_screen.dart';
import '../../lib/features/workspaces/data/workspace_access_detail.dart';
import '../../lib/features/workspaces/presentation/workspace_selection_screen.dart';
import '../contracts/workspace_access_detail_test.dart' as detail;
import 'app_auth_application_test.dart' as application;
import 'app_session_repository_test.dart' as session;
import 'password_change_screen_test.dart' as password;

/// Unknown password giữ recovery qua cả GET200 và limited403; chỉ logout đúng token mới về login.
/// Input
/// Param: tester — tương tác form thật và quan sát widget host sau mỗi server response synthetic.
/// Param: scope — sở hữu fixture full/limited, đóng ACK trước đổi lifetime.
Future<void> checkUnknownPasswordHost(
  WidgetTester tester,
  application.ApplicationTestScope scope,
) async {
  for (final limited in [false, true]) {
    final harness = scope.createHarness();
    harness.source.store.value = null;
    harness.source.auth.result = session.issuedSession(limited: limited);
    await application.pumpApplication(tester, harness);
    await application.submitLogin(tester);
    if (!limited) {
      await application.tapControl(tester, 'workspace-password');
      await tester.pumpAndSettle();
    }
    final workspaceCalls = harness.source.capability.listCalls.length;
    harness.source.capability.failure = const AppAuthFailure(
      AppAuthFailureKind.unavailable,
      outcomeUnknown: true,
    );
    await password.fillPasswords(tester, 'old', 'NewPass123');
    await application.tapControl(tester, 'password-submit');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('app-recovery')), findsOneWidget);
    harness.source.capability.failure = null;
    for (final limitedResponse in [false, true]) {
      harness.source.auth.profileFailure = limitedResponse
          ? const AppAuthFailure(AppAuthFailureKind.passwordChangeRequired)
          : null;
      final profileCalls = harness.source.auth.profileTokens.length;
      await application.tapControl(tester, 'app-recover');
      await tester.pumpAndSettle();
      expect(harness.source.auth.profileTokens.length, profileCalls + 1);
      expect(find.byKey(const ValueKey('app-recovery')), findsOneWidget);
      expect(find.byType(PasswordChangeScreen), findsNothing);
      expect(find.byType(WorkspaceSelectionScreen), findsNothing);
      expect(harness.source.capability.passwordCalls.length, 1);
      expect(harness.source.capability.listCalls.length, workspaceCalls);
    }
    await application.tapControl(tester, 'recovery-logout');
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(harness.source.auth.logoutTokens, [session.sessionToken]);
    expect(harness.source.store.value, isNull);
    await scope.closeHarness(harness);
    await tester.pumpWidget(const SizedBox());
  }
}

/// Callback của frame cũ không được nhận epoch mới sau lifecycle, refresh hoặc chuyển sang password.
/// Input
/// Param: tester — giữ callback từ widget thật rồi mô phỏng boundary framework.
/// Param: scope — đóng đúng coordinator của case mà không tạo repository thay thế.
Future<void> checkSavedHostCallbacks(
  WidgetTester tester,
  application.ApplicationTestScope scope,
) async {
  final harness = scope.createHarness();
  harness.source.store.value = null;
  await application.pumpApplication(tester, harness);
  final oldLogin = tester
      .widget<LoginScreen>(find.byType(LoginScreen))
      .onSubmit;
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  await tester.pump();
  expect(find.byType(LoginScreen), findsNothing);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpAndSettle();
  await oldLogin(session.sessionEmail, session.privatePassword);
  await tester.pumpAndSettle();
  expect(harness.source.auth.loginInputs, isEmpty);
  expect(find.byType(LoginScreen), findsOneWidget);
  await application.submitLogin(tester);
  final oldPicker = tester.widget<WorkspaceSelectionScreen>(
    find.byType(WorkspaceSelectionScreen),
  );
  final oldOption = oldPicker.state.options.single;
  await application.tapControl(tester, 'workspace-refresh');
  await tester.pumpAndSettle();
  await oldPicker.onSelect(oldOption);
  await tester.pumpAndSettle();
  expect(harness.source.capability.detailCalls, isEmpty);
  final currentPicker = tester.widget<WorkspaceSelectionScreen>(
    find.byType(WorkspaceSelectionScreen),
  );
  await application.tapControl(tester, 'workspace-password');
  await tester.pumpAndSettle();
  await currentPicker.onSelect(currentPicker.state.options.single);
  await tester.pumpAndSettle();
  expect(find.byType(PasswordChangeScreen), findsOneWidget);
  expect(harness.source.capability.detailCalls, isEmpty);
  expect(harness.source.auth.loginInputs.length, 1);
}

/// Back do binding dispatch phải tải picker mới cho full, còn limited không được gọi workspace API.
/// Input
/// Param: tester — dispatch handlePopRoute của Flutter, không giả đây là thao tác hệ điều hành thật.
/// Param: scope — giữ và đóng hai lifetime full/limited độc lập.
Future<void> checkFrameworkBackHost(
  WidgetTester tester,
  application.ApplicationTestScope scope,
) async {
  final full = scope.createHarness();
  await application.pumpApplication(tester, full);
  await application.tapControl(
    tester,
    'workspace-select-${detail.workspaceIdentity}',
  );
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('session-summary')), findsOneWidget);
  final initialLists = full.source.capability.listCalls.length;
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
  expect(find.byType(WorkspaceSelectionScreen), findsOneWidget);
  expect(full.source.capability.listCalls.length, initialLists + 1);
  expect(full.coordinator.session.selectedWorkspace, isNull);
  await application.tapControl(tester, 'workspace-password');
  await tester.pumpAndSettle();
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
  expect(find.byType(WorkspaceSelectionScreen), findsOneWidget);
  expect(full.source.capability.listCalls.length, initialLists + 2);
  expect(full.source.capability.passwordCalls, isEmpty);
  await scope.closeHarness(full);
  await tester.pumpWidget(const SizedBox());

  final limited = scope.createHarness();
  limited.source.auth.profileFailure = const AppAuthFailure(
    AppAuthFailureKind.passwordChangeRequired,
  );
  await application.pumpApplication(tester, limited);
  expect(find.byType(PasswordChangeScreen), findsOneWidget);
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
  expect(limited.source.capability.listCalls, isEmpty);
  expect(limited.source.capability.detailCalls, isEmpty);
  expect(limited.source.capability.passwordCalls, isEmpty);
  expect(find.byType(WorkspaceSelectionScreen), findsNothing);
}

/// Password429 bỏ form và hết giờ chỉ render lại form; limited vẫn không được bootstrap workspace.
/// Input
/// Param: tester — điều khiển clock/timer widget và nhập password qua component thật.
/// Param: scope — hủy timer và drain mỗi fixture trước unmount.
Future<void> checkPasswordCooldownHost(
  WidgetTester tester,
  application.ApplicationTestScope scope,
) async {
  for (final limited in [false, true]) {
    final harness = scope.createHarness();
    harness.source.store.value = null;
    harness.source.auth.result = session.issuedSession(limited: limited);
    await application.pumpApplication(tester, harness);
    await application.submitLogin(tester);
    if (!limited) {
      await application.tapControl(tester, 'workspace-password');
      await tester.pumpAndSettle();
    }
    final workspaceCalls = harness.source.capability.listCalls.length;
    harness.source.capability.failure = const AppAuthFailure(
      AppAuthFailureKind.rateLimited,
      retryAfterSeconds: 2,
    );
    await password.fillPasswords(tester, 'old', 'NewPass123');
    await application.tapControl(tester, 'password-submit');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('app-cooldown')), findsOneWidget);
    expect(find.byKey(const ValueKey('password-submit')), findsNothing);
    expect(find.byType(PasswordChangeScreen), findsNothing);
    expect(harness.source.capability.passwordCalls.length, 1);
    harness.seconds = 2;
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.byType(PasswordChangeScreen), findsOneWidget);
    expect(harness.source.capability.passwordCalls.length, 1);
    expect(harness.source.capability.listCalls.length, workspaceCalls);
    if (limited) {
      expect(workspaceCalls, 0);
      expect(find.byKey(const ValueKey('app-back')), findsNothing);
    }
    await scope.closeHarness(harness);
    await tester.pumpWidget(const SizedBox());
  }
}

/// Assertion thất bại vẫn phải thả detail gate và drain fixture trước khi rời case.
/// Input
/// Param: tester — giữ operation thật của repository đang chờ fake server ACK.
/// Param: scope — chủ sở hữu gate/coordinator và cleanup trong finally.
Future<void> checkCleanupAfterExpectedAssertion(
  WidgetTester tester,
  application.ApplicationTestScope scope,
) async {
  final harness = scope.createHarness();
  await application.pumpApplication(tester, harness);
  final detailGate = Completer<WorkspaceAccessDetail>();
  harness.source.capability.detailGate = detailGate;
  scope.releaseOnFinish(
    /// Chỉ thả source Future do fixture sở hữu, không giả operation đã bị hủy.
    () {
      if (!detailGate.isCompleted) {
        detailGate.complete(harness.source.capability.selected);
      }
    },
  );
  await application.tapControl(
    tester,
    'workspace-select-${detail.workspaceIdentity}',
  );
  expect(harness.source.repository.busy, isTrue);
  expect(detailGate.isCompleted, isFalse);
  var expectedFailureObserved = false;
  try {
    // Chỉ oracle cleanup này bắt đúng TestFailure cố ý; acceptance scenarios khác vẫn fail bình thường.
    expect(
      false,
      isTrue,
      reason: 'Assertion tổng hợp để kiểm finally cleanup.',
    );
  } on TestFailure {
    expectedFailureObserved = true;
  } finally {
    await scope.finish();
  }
  expect(expectedFailureObserved, isTrue);
  expect(detailGate.isCompleted, isTrue);
  expect(scope.isClosed, isTrue);
  expect(harness.source.repository.busy, isFalse);
  expect(find.byKey(const ValueKey('session-summary')), findsNothing);
}

/// Đăng ký QA độc lập và luôn drain fixture trong finally, không gọi main của modules import.
void main() {
  final scenarios = <(String, application.ApplicationScenario)>[
    (
      'host unknown password cannot reopen scope after full or limited recovery',
      checkUnknownPasswordHost,
    ),
    (
      'saved host callbacks cannot act after lifecycle refresh or route change',
      checkSavedHostCallbacks,
    ),
    (
      'framework back refreshes full picker without granting limited workspace access',
      checkFrameworkBackHost,
    ),
    (
      'password cooldown removes form and never replays in either session scope',
      checkPasswordCooldownHost,
    ),
    (
      'expected assertion failure still releases owned gate and closes fixture',
      checkCleanupAfterExpectedAssertion,
    ),
  ];
  for (final (name, scenario) in scenarios) {
    testWidgets(
      name,

      /// Input
      /// Param: tester — binding riêng từng case, scope bảo đảm ACK kể cả khi assertion lỗi.
      (tester) async {
        final scope = application.ApplicationTestScope(tester);
        try {
          await scenario(tester, scope);
        } finally {
          await scope.finish();
        }
      },
    );
  }
}
