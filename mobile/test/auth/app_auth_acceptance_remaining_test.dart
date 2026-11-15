import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../lib/features/auth/data/app_auth_api.dart';
import '../../lib/features/auth/data/app_auth_failure.dart';
import '../../lib/features/auth/data/app_login_response.dart';
import '../../lib/features/auth/data/app_session_repository.dart';
import '../../lib/features/auth/data/app_session_state.dart';
import '../../lib/features/auth/data/full_session_profile.dart';
import '../../lib/features/auth/presentation/app_auth_application.dart';
import '../../lib/features/auth/presentation/app_auth_coordinator.dart';
import '../../lib/features/auth/presentation/login_screen.dart';
import '../../lib/features/auth/presentation/password_change_screen.dart';
import '../../lib/features/workspaces/data/available_workspace_page.dart';
import '../../lib/features/workspaces/presentation/workspace_selection_screen.dart';
import '../contracts/workspace_access_detail_test.dart' as detail;
import 'app_auth_api_test.dart' as wire;
import 'app_auth_application_test.dart' as application;
import 'app_session_capability_test.dart' as capability;
import 'app_session_repository_test.dart' as session;

/// Write lỗi sau side effect vẫn phải che nội dung và revoke đúng candidate trước recovery chủ động.
/// Input
/// Param: tester — runner tương tác form login và action recovery thật.
/// Param: scope — sở hữu coordinator và cleanup khi assertion lỗi.
Future<void> checkWriteFailureHost(
  WidgetTester tester,
  application.ApplicationTestScope scope,
) async {
  final harness = scope.createHarness();
  harness.source.store.value = null;
  harness.source.store.writeBeforeAck = true;
  harness.source.store.failWrite = true;
  await application.pumpApplication(tester, harness);
  await application.submitLogin(tester);
  expect(find.byKey(const ValueKey('app-recovery')), findsOneWidget);
  expect(find.byType(WorkspaceSelectionScreen), findsNothing);
  expect(find.byKey(const ValueKey('session-summary')), findsNothing);
  expect(harness.source.auth.profileTokens, isEmpty);
  expect(harness.source.capability.listCalls, isEmpty);
  expect(harness.source.auth.logoutTokens, [session.sessionToken]);
  expect(harness.source.store.value, isNull);
  expect(harness.coordinator.session.phase, AppSessionPhase.storageFailure);
  harness.source.store.failWrite = false;
  await application.tapControl(tester, 'app-recover');
  await tester.pumpAndSettle();
  expect(find.byType(LoginScreen), findsOneWidget);
  expect(harness.source.auth.loginInputs.length, 1);
  expect(harness.source.store.value, isNull);
}

/// B đăng nhập trong cùng lifetime sau logout A không được giữ summary/list/profile hoặc callback A.
/// Input
/// Param: tester — runner kiểm widget hiện hành qua các account boundary.
/// Param: scope — sở hữu một repository/store duy nhất cho cả A và B.
Future<void> checkAccountSwitchHost(
  WidgetTester tester,
  application.ApplicationTestScope scope,
) async {
  final harness = scope.createHarness();
  await application.pumpApplication(tester, harness);
  final oldPicker = tester.widget<WorkspaceSelectionScreen>(
    find.byType(WorkspaceSelectionScreen),
  );
  await application.tapControl(
    tester,
    'workspace-select-${detail.workspaceIdentity}',
  );
  await tester.pumpAndSettle();
  final previousWorkspaceName = harness.source.capability.selected.name;
  expect(find.text(previousWorkspaceName), findsOneWidget);
  expect(find.text(session.sessionEmail), findsOneWidget);
  await application.tapControl(tester, 'session-logout');
  await tester.pumpAndSettle();
  harness.source.auth.result = AppLoginResponse.fromJson({
    'me': {
      'id': session.alternateIdentity,
      'email': session.alternateEmail,
      'mustChangePassword': false,
    },
    'limited': false,
    'token': session.alternateToken,
    'expiresAt': '2030-01-01T00:00:00Z',
  });
  harness.source.auth.profileResult = session.serverProfile(
    id: session.alternateIdentity,
    email: session.alternateEmail,
  );
  harness.source.capability.page = capability.workspacePage([
    capability.secondWorkspaceId,
  ]);
  await tester.enterText(
    find.byKey(const ValueKey('auth-email')),
    session.alternateEmail,
  );
  await tester.enterText(
    find.byKey(const ValueKey('auth-password')),
    session.privatePassword,
  );
  await application.tapControl(tester, 'auth-submit');
  await tester.pumpAndSettle();
  final detailCalls = harness.source.capability.detailCalls.length;
  await oldPicker.onSelect(oldPicker.state.options.single);
  await tester.pumpAndSettle();
  expect(harness.source.capability.detailCalls.length, detailCalls);
  expect(find.text(previousWorkspaceName), findsNothing);
  expect(find.text(session.sessionEmail), findsNothing);
  expect(find.byKey(const ValueKey('session-summary')), findsNothing);
  expect(
    find.byKey(ValueKey('workspace-select-${detail.workspaceIdentity}')),
    findsNothing,
  );
  expect(
    find.byKey(ValueKey('workspace-select-${capability.secondWorkspaceId}')),
    findsOneWidget,
  );
  expect(harness.source.store.value, session.alternateToken);
  expect(harness.source.auth.profileTokens.last, session.alternateToken);
  expect(harness.source.capability.listCalls.last.$1, session.alternateToken);
  expect(harness.source.auth.logoutTokens, [session.sessionToken]);
}

/// Lifecycle giữa bootstrap phải bỏ page cũ và chờ profile server mới trước list/render mới.
/// Input
/// Param: tester — gửi event framework khi list còn pending, không giả process restart.
/// Param: scope — thả owned page/profile gates trước drain cả khi test lỗi.
Future<void> checkMidBootstrapHost(
  WidgetTester tester,
  application.ApplicationTestScope scope,
) async {
  final harness = scope.createHarness();
  final page = Completer<AvailableWorkspacePage>();
  final profile = Completer<FullSessionProfile>();
  harness.source.capability.pageGate = page;
  scope.releaseOnFinish(
    /// Gate chỉ thuộc fixture, cần complete trước coordinator.close để giữ ownership.
    () {
      if (!page.isCompleted) page.complete(capability.workspacePage([]));
      if (!profile.isCompleted) profile.complete(session.serverProfile());
    },
  );
  await application.pumpApplication(tester, harness);
  expect(harness.source.capability.listCalls.length, 1);
  expect(find.byType(WorkspaceSelectionScreen), findsNothing);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  await tester.pump();
  harness.source.auth.profileGate = profile;
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pump();
  harness.source.capability.pageGate = null;
  page.complete(capability.workspacePage([detail.workspaceIdentity]));
  await tester.pumpAndSettle();
  expect(harness.source.auth.profileTokens.length, 2);
  expect(harness.source.capability.listCalls.length, 1);
  expect(find.byType(WorkspaceSelectionScreen), findsNothing);
  expect(find.byKey(const ValueKey('session-summary')), findsNothing);
  profile.complete(session.serverProfile());
  await tester.pumpAndSettle();
  expect(harness.source.capability.listCalls.length, 2);
  expect(find.byType(WorkspaceSelectionScreen), findsOneWidget);
}

/// Tải trang kế tiếp qua control thật rồi denial khi chọn phải bỏ list cũ, không render summary.
/// Input
/// Param: tester — runner bấm tải thêm và chọn row đã tải.
/// Param: scope — sở hữu fixture synthetic, server authorization actual được kiểm riêng.
Future<void> checkPaginationDeniedHost(
  WidgetTester tester,
  application.ApplicationTestScope scope,
) async {
  final harness = scope.createHarness();
  harness.source.capability.page = capability.workspacePage([
    detail.workspaceIdentity,
  ], cursor: 'next-page');
  await application.pumpApplication(tester, harness);
  harness.source.capability.page = capability.workspacePage([
    capability.secondWorkspaceId,
  ]);
  await application.tapControl(tester, 'workspace-load-more');
  await tester.pumpAndSettle();
  expect(harness.source.capability.listCalls, [
    (session.sessionToken, null),
    (session.sessionToken, 'next-page'),
  ]);
  expect(harness.coordinator.session.workspaces.length, 2);
  harness.source.capability.failure = const AppAuthFailure(
    AppAuthFailureKind.permissionDenied,
  );
  await application.tapControl(
    tester,
    'workspace-select-${capability.secondWorkspaceId}',
  );
  await tester.pumpAndSettle();
  expect(harness.source.capability.detailCalls.single, (
    session.sessionToken,
    capability.secondWorkspaceId,
  ));
  expect(harness.coordinator.session.selectedWorkspace, isNull);
  expect(harness.coordinator.session.workspaces, isEmpty);
  expect(find.byKey(const ValueKey('session-summary')), findsNothing);
  expect(
    find.byKey(ValueKey('workspace-select-${detail.workspaceIdentity}')),
    findsNothing,
  );
  expect(
    find.byKey(ValueKey('workspace-select-${capability.secondWorkspaceId}')),
    findsNothing,
  );
}

/// Ghép HTTP adapter/parser/repository/coordinator/host thật; chỉ socket và secure storage là fake.
/// Input
/// Param: tester — runner nhập form thật và kiểm route/recovery.
/// Param: limited — true kiểm allowlist một login, false kiểm malformed200 matrix.
/// Param: offline — true tạo SocketException tại socket fake để kiểm lỗi kết nối và không replay.
Future<void> checkWireHost(
  WidgetTester tester, {
  required bool limited,
  bool offline = false,
}) async {
  final full = wire.loginBody();
  final bodies = limited
      ? <Object?>[
          {
            ...full,
            'limited': true,
            'me': {
              ...(full['me']! as Map<String, Object?>),
              'mustChangePassword': true,
            },
          },
        ]
      : offline
      ? <Object?>[full]
      : <Object?>[
          {...full}..remove('token'),
          {...full}..remove('expiresAt'),
          {...full, 'limited': 'false'},
        ];
  for (final body in bodies) {
    final events = <String>[];
    final store = session.SessionStoreFake(events);
    final client = wire.clientFor(body: body);
    if (offline) client.openError = const SocketException('SYNTHETIC_OFFLINE');
    final factory = wire.RecordingFactory([client]);
    var creationAttempts = 0;

    /// Đếm cả lần factory từ chối cấp client để replay bị catch vẫn không thoát oracle.
    /// Output: client synthetic đầu tiên; lần gọi thừa ném lỗi nhưng bộ đếm đã tăng trước đó.
    HttpClient createClient() {
      creationAttempts++;
      return factory.create();
    }

    final api = HttpAppAuthApi(wire.origin, createClient: createClient);
    final coordinator = AppAuthCoordinator(
      repository: AppSessionRepository(
        api: api,
        workspaceApi: api,
        passwordApi: api,
        tokenStore: store,
      ),
    );
    try {
      await tester.pumpWidget(AppAuthApplication(coordinator: coordinator));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('auth-email')),
        'synthetic@example.invalid',
      );
      await tester.enterText(
        find.byKey(const ValueKey('auth-password')),
        session.privatePassword,
      );
      await application.tapControl(tester, 'auth-submit');
      await tester.pumpAndSettle();
      expect(creationAttempts, 1);
      expect(factory.calls, 1);
      expect(client.methods, ['POST']);
      expect(client.uris.single.path, '/api/v1/auth/login');
      expect(find.byType(WorkspaceSelectionScreen), findsNothing);
      expect(find.byKey(const ValueKey('session-summary')), findsNothing);
      if (limited) {
        expect(find.byType(PasswordChangeScreen), findsOneWidget);
        expect(store.writtenTokens, [wire.bearer]);
        expect(coordinator.session.phase, AppSessionPhase.limited);
      } else {
        expect(store.writtenTokens, isEmpty);
        expect(store.value, isNull);
        // Socket lỗi ngay openUrl chưa gửi byte nên known-unsent khác malformed200 đã nhận ACK/body.
        expect(
          coordinator.session.phase,
          offline ? AppSessionPhase.signedOut : AppSessionPhase.pending,
        );
        expect(
          coordinator.session.failure?.kind,
          offline
              ? AppAuthFailureKind.networkUnavailable
              : AppAuthFailureKind.protocol,
        );
        if (offline) {
          expect(find.byType(LoginScreen), findsOneWidget);
          expect(find.text('Mất kết nối'), findsOneWidget);
          expect(coordinator.session.failure?.outcomeUnknown, isFalse);
          expect(client.request.closeCalls, 0);
        } else {
          expect(find.byKey(const ValueKey('app-recovery')), findsOneWidget);
        }
        await application.tapControl(
          tester,
          offline ? 'auth-recover' : 'app-recover',
        );
        await tester.pumpAndSettle();
        expect(find.byType(LoginScreen), findsOneWidget);
        expect(creationAttempts, 1);
        expect(factory.calls, 1);
        expect(store.value, isNull);
        final password = tester.widget<TextFormField>(
          find.byKey(const ValueKey('auth-password')),
        );
        expect(password.controller!.text, isEmpty);
      }
      expect(creationAttempts, 1);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.runAsync(coordinator.close);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }
  }
}

/// Kiểm malformed200 đến UI recovery mà không lưu phiên hoặc tự phát lại login.
/// Input
/// Param: tester — runner thực thi ba biến thể token/expiry/schema.
Future<void> checkMalformedWireHost(WidgetTester tester) =>
    checkWireHost(tester, limited: false);

/// Kiểm limited login chỉ phát một POST tới HTTP adapter, không bootstrap endpoint bảo vệ.
/// Input
/// Param: tester — runner nhập login và quan sát password-only host.
Future<void> checkLimitedWireHost(WidgetTester tester) =>
    checkWireHost(tester, limited: true);

/// Kiểm offline không ghi secret/session hoặc tự queue login sau đối soát chủ động.
/// Input
/// Param: tester — runner kiểm recover đưa form mới trống và không tạo HTTP operation thứ hai.
Future<void> checkOfflineWireHost(WidgetTester tester) =>
    checkWireHost(tester, limited: false, offline: true);

/// Đăng ký coverage acceptance còn thiếu, không gọi main suite được import hoặc chạy native/provider.
void main() {
  final scenarios = <(String, application.ApplicationScenario)>[
    (
      'write failure after native side effect stays recoverable without admission',
      checkWriteFailureHost,
    ),
    (
      'account B never renders account A protected cache or accepts its saved callback',
      checkAccountSwitchHost,
    ),
    (
      'background during bootstrap waits fresh profile before rendering refreshed picker',
      checkMidBootstrapHost,
    ),
    (
      'paginated picker selection denial clears stale rows without rendering summary',
      checkPaginationDeniedHost,
    ),
  ];
  for (final (name, scenario) in scenarios) {
    testWidgets(
      name,

      /// Fixture luôn drain trong finally, không bỏ gate khi assertion thất bại.
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
  testWidgets(
    'malformed login 200 has no store and explicit host recovery for token expiry schema',
    checkMalformedWireHost,
  );
  testWidgets(
    'limited login wire ledger contains only login before password-only render',
    checkLimitedWireHost,
  );
  testWidgets(
    'offline login stores no session and never queues password or login replay',
    checkOfflineWireHost,
  );
}
