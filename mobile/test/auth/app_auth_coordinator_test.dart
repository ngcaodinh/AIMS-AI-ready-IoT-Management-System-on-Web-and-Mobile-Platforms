import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import '../../lib/features/auth/data/app_auth_failure.dart';
import '../../lib/features/auth/data/full_session_profile.dart';
import '../../lib/features/auth/presentation/app_auth_coordinator.dart';
import '../../lib/features/workspaces/presentation/workspace_selection_state.dart';
import '../contracts/workspace_access_detail_test.dart' as detail;
import 'app_session_capability_test.dart' as capability;
import 'app_session_repository_test.dart' as session;

/// Dùng repository thật với API/store synthetic để kiểm coordinator không bypass admission.
final class CoordinatorHarness {
  /// Ghép một lifetime; clock test chỉ điều khiển cooldown, không expiry hoặc quyền.
  CoordinatorHarness() {
    coordinator = AppAuthCoordinator(
      repository: source.repository,
      elapsedSeconds: elapsedSeconds,
    );
  }
  final source = capability.CapabilityHarness();
  late final AppAuthCoordinator coordinator;
  int seconds = 0;

  /// Output: số giây monotonic giả lập kể từ khi fixture bắt đầu.
  int elapsedSeconds() => seconds;

  /// Output: epoch hiện tại dùng cho action mới; test stale giữ riêng bản cũ.
  int get epoch => coordinator.generation;

  /// Output: row summary hiện tại; đây không là quyền server cho detail.
  WorkspaceOption get option => WorkspaceOption(
    id: detail.workspaceIdentity,
    name: detail.workspaceIdentity,
    role: WorkspaceRole.user,
    revision: 1,
    status: WorkspaceStatus.active,
  );
}

/// Nhường microtask cho stream/real Future, không đợi timeout wallclock hoặc giả hủy I/O.
Future<void> flush() => Future<void>.delayed(Duration.zero);

/// Khởi động full/empty/limited và chỉ tự bootstrap list sau admission thành công.
Future<void> checkBootstrapRoutes() async {
  for (final mode in ['full', 'empty', 'limited', 'signedOut']) {
    final harness = CoordinatorHarness();
    addTearDown(harness.coordinator.close);
    if (mode == 'empty')
      harness.source.capability.page = capability.workspacePage([]);
    if (mode == 'limited')
      harness.source.auth.profileFailure = const AppAuthFailure(
        AppAuthFailureKind.passwordChangeRequired,
      );
    if (mode == 'signedOut') harness.source.store.value = null;
    await harness.coordinator.initialize();
    expect(
      harness.coordinator.page,
      mode == 'signedOut'
          ? AppAuthPage.login
          : mode == 'limited'
          ? AppAuthPage.password
          : AppAuthPage.workspaces,
    );
    expect(
      harness.source.capability.listCalls.length,
      mode == 'full' || mode == 'empty' ? 1 : 0,
    );
    expect(harness.coordinator.session.selectedWorkspace, isNull);
    if (mode == 'empty')
      expect(harness.coordinator.session.workspacesLoaded, isTrue);
    await harness.coordinator.initialize();
    expect(
      harness.source.capability.listCalls.length,
      mode == 'full' || mode == 'empty' ? 1 : 0,
    );
  }
}

/// Callback cũ, sai page/revision và double action không được phát API hoặc chuyển route.
Future<void> checkCallbackAdmission() async {
  final harness = CoordinatorHarness();
  addTearDown(harness.coordinator.close);
  harness.source.store.value = null;
  await harness.coordinator.initialize();
  final oldLoginEpoch = harness.epoch;
  final login = harness.coordinator.login(
    session.sessionEmail,
    session.privatePassword,
    expectedGeneration: oldLoginEpoch,
  );
  await harness.coordinator.login(
    session.sessionEmail,
    'second-secret',
    expectedGeneration: oldLoginEpoch,
  );
  await login;
  expect(harness.source.auth.loginInputs, [
    (session.sessionEmail, session.privatePassword),
  ]);
  expect(harness.coordinator.page, AppAuthPage.workspaces);
  await harness.coordinator.login(
    session.sessionEmail,
    'queued-old',
    expectedGeneration: oldLoginEpoch,
  );
  expect(harness.source.auth.loginInputs.length, 1);
  final staleOption = WorkspaceOption(
    id: harness.option.id,
    name: harness.option.name,
    role: WorkspaceRole.user,
    revision: 2,
    status: WorkspaceStatus.active,
  );
  await harness.coordinator.selectWorkspace(
    staleOption,
    expectedGeneration: harness.epoch,
  );
  expect(harness.source.capability.detailCalls, isEmpty);
  final pickerEpoch = harness.epoch;
  harness.coordinator.openPassword(expectedGeneration: pickerEpoch);
  expect(harness.coordinator.page, AppAuthPage.password);
  await harness.coordinator.selectWorkspace(
    harness.option,
    expectedGeneration: pickerEpoch,
  );
  expect(harness.source.capability.detailCalls, isEmpty);
  await harness.coordinator.refreshWorkspaces(
    expectedGeneration: harness.epoch,
  );
  expect(harness.coordinator.page, AppAuthPage.workspaces);
  await harness.coordinator.selectWorkspace(
    harness.option,
    expectedGeneration: harness.epoch,
  );
  expect(harness.source.capability.detailCalls.length, 1);
  expect(harness.coordinator.page, AppAuthPage.summary);
  await harness.coordinator.logout(expectedGeneration: harness.epoch);
  expect(harness.coordinator.page, AppAuthPage.login);
  expect(harness.source.store.value, isNull);
}

/// Retry-After khóa đúng operation; delayed tick không mở sớm và hết giờ không tự POST.
Future<void> checkCooldown() async {
  final harness = CoordinatorHarness();
  addTearDown(harness.coordinator.close);
  harness.source.store.value = null;
  await harness.coordinator.initialize();
  harness.source.auth.loginFailure = const AppAuthFailure(
    AppAuthFailureKind.rateLimited,
    retryAfterSeconds: 2,
  );
  await harness.coordinator.login(
    session.sessionEmail,
    session.privatePassword,
    expectedGeneration: harness.epoch,
  );
  expect(harness.coordinator.retryAfterSeconds, 2);
  await harness.coordinator.login(
    session.sessionEmail,
    'retry',
    expectedGeneration: harness.epoch,
  );
  expect(harness.source.auth.loginInputs.length, 1);
  harness.seconds = 1;
  expect(harness.coordinator.retryAfterSeconds, 1);
  await harness.coordinator.login(
    session.sessionEmail,
    'retry',
    expectedGeneration: harness.epoch,
  );
  expect(harness.source.auth.loginInputs.length, 1);
  harness.seconds = 2;
  expect(harness.coordinator.retryAfterSeconds, 0);
  expect(harness.source.auth.loginInputs.length, 1);
  harness.source.auth.loginFailure = null;
  await harness.coordinator.login(
    session.sessionEmail,
    session.privatePassword,
    expectedGeneration: harness.epoch,
  );
  harness.coordinator.openPassword(expectedGeneration: harness.epoch);
  harness.source.capability.failure = const AppAuthFailure(
    AppAuthFailureKind.rateLimited,
    retryAfterSeconds: 9223372036854775807,
  );
  await harness.coordinator.changePassword(
    'old',
    'new',
    expectedGeneration: harness.epoch,
  );
  expect(harness.coordinator.retryAfterSeconds, 9223372036854775807);
  await harness.coordinator.changePassword(
    'old',
    'new',
    expectedGeneration: harness.epoch,
  );
  expect(harness.source.capability.passwordCalls.length, 1);
}

/// Known list denial không loop/retry hoặc giả empty; refresh chủ động và selection recheck riêng.
Future<void> checkWorkspaceErrors() async {
  final harness = CoordinatorHarness();
  addTearDown(harness.coordinator.close);
  harness.source.capability.failure = const AppAuthFailure(
    AppAuthFailureKind.permissionDenied,
  );
  await harness.coordinator.initialize();
  expect(harness.coordinator.page, AppAuthPage.workspaces);
  expect(harness.coordinator.session.workspacesLoaded, isFalse);
  expect(
    harness.coordinator.session.failure?.kind,
    AppAuthFailureKind.permissionDenied,
  );
  await flush();
  expect(harness.source.capability.listCalls.length, 1);
  harness.source.capability.failure = null;
  await harness.coordinator.refreshWorkspaces(
    expectedGeneration: harness.epoch,
  );
  harness.source.capability.failure = const AppAuthFailure(
    AppAuthFailureKind.conflict,
  );
  await harness.coordinator.selectWorkspace(
    harness.option,
    expectedGeneration: harness.epoch,
  );
  expect(harness.coordinator.page, AppAuthPage.workspaces);
  expect(harness.coordinator.session.selectedWorkspace, isNull);
  expect(
    harness.coordinator.session.failure?.kind,
    AppAuthFailureKind.conflict,
  );
  expect(harness.source.capability.detailCalls.length, 1);
}

/// Password unknown không được dùng GET200 để promote/replay; chỉ user logout đúng token kết thúc.
Future<void> checkPasswordUnknown() async {
  final harness = CoordinatorHarness();
  addTearDown(harness.coordinator.close);
  await harness.coordinator.initialize();
  harness.coordinator.openPassword(expectedGeneration: harness.epoch);
  harness.source.capability.failure = const AppAuthFailure(
    AppAuthFailureKind.unavailable,
    outcomeUnknown: true,
  );
  await harness.coordinator.changePassword(
    'old',
    'new',
    expectedGeneration: harness.epoch,
  );
  expect(harness.coordinator.page, AppAuthPage.recovery);
  await harness.coordinator.recover(expectedGeneration: harness.epoch);
  expect(harness.coordinator.page, AppAuthPage.recovery);
  harness.coordinator.suspend();
  expect(harness.coordinator.page, AppAuthPage.loading);
  await harness.coordinator.resume();
  expect(harness.coordinator.page, AppAuthPage.recovery);
  await harness.coordinator.changePassword(
    'old',
    'new',
    expectedGeneration: harness.epoch,
  );
  expect(harness.source.capability.passwordCalls.length, 1);
  expect(harness.source.capability.listCalls.length, 1);
  await harness.coordinator.logout(expectedGeneration: harness.epoch);
  expect(harness.source.auth.logoutTokens, [session.sessionToken]);
  expect(harness.coordinator.page, AppAuthPage.login);
}

/// Latest resume phải đợi list cũ và /me mới, rồi bootstrap mới; stream không tự loop.
Future<void> checkLatestResumeDuringBootstrap() async {
  final harness = CoordinatorHarness();
  addTearDown(harness.coordinator.close);
  await harness.coordinator.initialize();
  harness.coordinator.suspend();
  harness.source.capability.pageGate = Completer();
  final oldPageGate = harness.source.capability.pageGate!;
  final resume1 = harness.coordinator.resume();
  await flush();
  expect(harness.source.capability.listCalls.length, 2);
  harness.coordinator.suspend();
  harness.source.auth.profileGate = Completer<FullSessionProfile>();
  final resume2 = harness.coordinator.resume();
  harness.source.capability.pageGate = null;
  oldPageGate.complete(capability.workspacePage([detail.workspaceIdentity]));
  await flush();
  expect(harness.coordinator.page, AppAuthPage.loading);
  expect(harness.source.capability.listCalls.length, 2);
  harness.source.auth.profileGate!.complete(session.serverProfile());
  await Future.wait([resume1, resume2]);
  expect(harness.source.capability.listCalls.length, 3);
  expect(harness.coordinator.page, AppAuthPage.workspaces);
  expect(harness.coordinator.session.workspacesLoaded, isTrue);
  harness.coordinator.suspend();
  await flush();
  expect(harness.coordinator.page, AppAuthPage.loading);
  expect(harness.source.capability.listCalls.length, 3);
}

/// Suspend/close xóa protected route ngay và completion muộn không notify hoặc admit.
Future<void> checkDisposeAndStorageFailure() async {
  final harness = CoordinatorHarness();
  await harness.coordinator.initialize();
  final gate = Completer<FullSessionProfile>();
  harness.source.auth.profileGate = gate;
  harness.coordinator.suspend();
  final pending = harness.coordinator.resume();
  await flush();
  final close = harness.coordinator.close();
  gate.complete(session.serverProfile());
  await Future.wait([pending, close]);
  expect(harness.coordinator.page, AppAuthPage.loading);
  expect(harness.source.capability.listCalls.length, 1);
  final broken = CoordinatorHarness();
  addTearDown(broken.coordinator.close);
  broken.source.store.failRead = true;
  await broken.coordinator.initialize();
  expect(broken.coordinator.page, AppAuthPage.recovery);
  expect(broken.source.capability.listCalls, isEmpty);
  broken.source.store.failRead = false;
  await broken.coordinator.recover(expectedGeneration: broken.epoch);
  expect(broken.coordinator.page, AppAuthPage.login);
}

/// Capability hiển thị phải bám private ownership, không gắn nút logout no-op vào read failure ban đầu.
Future<void> checkLogoutAvailability() async {
  final missing = CoordinatorHarness();
  addTearDown(missing.coordinator.close);
  missing.source.store.failRead = true;
  await missing.coordinator.initialize();
  expect(missing.coordinator.canLogout, isFalse);
  for (final limited in [false, true]) {
    final harness = CoordinatorHarness();
    addTearDown(harness.coordinator.close);
    if (limited)
      harness.source.auth.profileFailure = const AppAuthFailure(
        AppAuthFailureKind.passwordChangeRequired,
      );
    await harness.coordinator.initialize();
    expect(harness.coordinator.canLogout, isTrue);
    if (!limited)
      harness.coordinator.openPassword(expectedGeneration: harness.epoch);
    harness.source.capability.failure = const AppAuthFailure(
      AppAuthFailureKind.unavailable,
      outcomeUnknown: true,
    );
    await harness.coordinator.changePassword(
      'old',
      'new',
      expectedGeneration: harness.epoch,
    );
    expect(harness.coordinator.canLogout, isTrue);
    harness.coordinator.suspend();
    expect(harness.coordinator.canLogout, isFalse);
    await harness.coordinator.resume();
    expect(harness.coordinator.canLogout, isTrue);
    harness.source.store.failRead = true;
    await harness.coordinator.recover(expectedGeneration: harness.epoch);
    expect(harness.coordinator.canLogout, isTrue);
    harness.source.store.failRead = false;
    harness.source.store.value = null;
    await harness.coordinator.recover(expectedGeneration: harness.epoch);
    expect(harness.coordinator.canLogout, isTrue);
    harness.source.auth.logoutGate = Completer<void>();
    final logout = harness.coordinator.logout(
      expectedGeneration: harness.epoch,
    );
    expect(harness.coordinator.canLogout, isFalse);
    harness.source.auth.logoutGate!.complete();
    await logout;
    expect(harness.coordinator.canLogout, isFalse);
    await harness.coordinator.close();
    expect(harness.coordinator.canLogout, isFalse);
  }
  final candidate = CoordinatorHarness();
  addTearDown(candidate.coordinator.close);
  candidate.source.store.value = null;
  await candidate.coordinator.initialize();
  candidate.source.store.failWrite = true;
  candidate.source.store.writeBeforeAck = true;
  await candidate.coordinator.login(
    session.sessionEmail,
    session.privatePassword,
    expectedGeneration: candidate.epoch,
  );
  expect(candidate.coordinator.canLogout, isFalse);
}

/// Đăng ký tests business/lifecycle với repository thật, không khởi suite main của modules import.
void main() {
  test(
    'logout availability distinguishes known pending token from initial storage failure',
    checkLogoutAvailability,
  );
  test(
    'bootstrap full, empty, limited and signed-out routes without duplicate GET',
    checkBootstrapRoutes,
  );
  test(
    'queued generation, page, revision and busy callbacks cannot bypass admission',
    checkCallbackAdmission,
  );
  test(
    'cooldown exact boundary and delayed tick never auto replay mutations',
    checkCooldown,
  );
  test(
    'workspace permission and stale errors require explicit reload and recheck',
    checkWorkspaceErrors,
  );
  test(
    'password unknown remains locked through recover and resume until explicit logout',
    checkPasswordUnknown,
  );
  test(
    'latest resume during old bootstrap drains the new profile before fresh list',
    checkLatestResumeDuringBootstrap,
  );
  test(
    'dispose and storage errors remain closed without late bootstrap',
    checkDisposeAndStorageFailure,
  );
}
