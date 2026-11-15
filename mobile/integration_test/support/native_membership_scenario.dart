import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexa_iot/features/auth/data/app_auth_failure.dart';
import 'package:nexa_iot/features/auth/data/app_session_state.dart';
import 'package:nexa_iot/features/auth/presentation/app_auth_application.dart';
import 'package:nexa_iot/features/auth/presentation/app_auth_coordinator.dart';
import 'package:nexa_iot/features/workspaces/presentation/workspace_selection_screen.dart';
import 'package:nexa_iot/features/workspaces/presentation/workspace_selection_state.dart';

import 'native_rate_scenario.dart';

/// Bỏ reference secret cả khi TLS/main/teardown lỗi, không kéo dài lifetime password của packet.
/// Input
/// Param: packet — map RAM riêng do SDK nhận một lần.
/// Param: body — toàn operation native, lỗi giữ nguyên sau cleanup reference.
/// Side effects: xóa reference, không chứng minh xóa vùng nhớ hoặc HTTP terminal.
Future<void> withNativeMembershipCredentials(
  Map<String, Object?> packet,
  Future<void> Function() body,
) async {
  try {
    await body();
  } finally {
    packet['password'] = '';
  }
}

/// Kiểm stale membership bằng input/tap sản phẩm, fresh busy và snapshot/epoch trước intent.
/// Input
/// Param: tester — engine main thật, host boundary test có API/store synthetic được ghi rõ.
/// Param: packet — synthetic identities/password RAM, không URL/SQL/selector.
/// Param: elapsed — Stopwatch neo valid fixture packet, fixed420s.
/// Param: checkpoint — fixed pause cho host HTTP/session oracle và suspend B trước ACK picker.
/// Param: markStage — enum diagnostics, không raw input/state.
/// Errors: fixed StateError khi timeout, stale intent hoặc business invariant sai.
Future<void> verifyNativeMembershipScenario(
  WidgetTester tester,
  Map<String, Object?> packet, {
  required Duration Function() elapsed,
  required Future<void> Function(String stage) checkpoint,
  required void Function(String stage) markStage,
}) async {
  final password = packet['password'];
  final emails = packet['emails'];
  if (password is! String ||
      !RegExp(r'^Aa1[0-9a-f]{32}$').hasMatch(password) ||
      emails is! List ||
      emails.isEmpty ||
      emails.first is! String) {
    throw StateError('INVALID_NATIVE_MEMBERSHIP_PACKET');
  }
  final email = emails.first as String;
  final ui = NativeScenarioUi(
    tester,
    elapsed,
    phaseLimit: const Duration(seconds: 420),
    timeoutCode: 'NATIVE_MEMBERSHIP_UI_TIMEOUT',
  );
  await ui.wait(
    /// Chỉ admission main thật đã mount login, không preview/spinner bootstrap.
    () =>
        find.byType(AppAuthApplication).evaluate().length == 1 &&
        find.byKey(const ValueKey('auth-email')).evaluate().length == 1,
    elapsed() + const Duration(seconds: 20),
  );
  final coordinator = tester
      .widget<AppAuthApplication>(find.byType(AppAuthApplication))
      .coordinator;

  /// Login sạch phải hết profile/list/selected/failure và protected widgets.
  void signedOut() {
    ui.guard();
    final state = coordinator.session;
    if (coordinator.page != AppAuthPage.login ||
        state.phase != AppSessionPhase.signedOut ||
        state.failure != null ||
        state.profile != null ||
        state.selectedWorkspace != null ||
        state.workspacesLoaded ||
        state.workspaces.isNotEmpty ||
        find.byType(WorkspaceSelectionScreen).evaluate().isNotEmpty ||
        find.byKey(const ValueKey('session-summary')).evaluate().isNotEmpty ||
        find.byKey(const ValueKey('auth-email')).evaluate().length != 1 ||
        find.byKey(const ValueKey('auth-password')).evaluate().length != 1) {
      throw StateError('NATIVE_MEMBERSHIP_SIGNED_OUT_INVALID');
    }
    final emailField = tester.widget<TextFormField>(
      find.byKey(const ValueKey('auth-email')),
    );
    final passwordField = tester.widget<TextFormField>(
      find.byKey(const ValueKey('auth-password')),
    );
    if (emailField.controller?.text != '' ||
        passwordField.controller?.text != '') {
      throw StateError('NATIVE_MEMBERSHIP_SIGNED_OUT_INVALID');
    }
  }

  /// Chặn lifecycle/intent chen vào pause hoặc trước pointer, không lấy epoch mới để hợp thức hóa.
  /// Input
  /// Param: before — immutable snapshot đã quan sát.
  /// Param: generation — presentation epoch cùng lúc chụp snapshot.
  void unchanged(AppSessionState before, int generation) {
    ui.guard();
    if (!identical(before, coordinator.session) ||
        generation != coordinator.generation) {
      throw StateError('NATIVE_MEMBERSHIP_UNEXPECTED_INTENT');
    }
  }

  /// Pause sau business assertion, ACK không thay evidence UI đã hoàn tất.
  /// Input
  /// Param: stage — một trong sáu fixed checkpoint của membership gate.
  Future<void> pause(String stage) async {
    final before = coordinator.session;
    final generation = coordinator.generation;
    ui.guard();
    await checkpoint(stage);
    ui.guard();
    unchanged(before, generation);
  }

  /// Kiểm identity full riêng với selection, không suy authority từ row/role hiển thị.
  void fullIdentity() {
    ui.guard();
    if (coordinator.session.phase != AppSessionPhase.full ||
        coordinator.session.profile?.email != email) {
      throw StateError('NATIVE_MEMBERSHIP_IDENTITY_INVALID');
    }
  }

  /// Đối chiếu picker ready render với snapshot, số row/name/role và identity A ban đầu.
  /// Input
  /// Param: onlyA — sau refresh phải hết B.
  /// Param: expectedA — UUID đã quan sát trước suspend, null ở baseline.
  /// Output: UUID A/B của rows, B null sau refresh.
  ({String a, String? b}) picker({required bool onlyA, String? expectedA}) {
    fullIdentity();
    final screen = find.byType(WorkspaceSelectionScreen);
    if (coordinator.page != AppAuthPage.workspaces ||
        coordinator.session.failure != null ||
        coordinator.session.selectedWorkspace != null ||
        !coordinator.session.workspacesLoaded ||
        coordinator.session.nextWorkspaceCursor != null ||
        screen.evaluate().length != 1) {
      throw StateError('NATIVE_MEMBERSHIP_PICKER_INVALID');
    }
    final state = tester.widget<WorkspaceSelectionScreen>(screen).state;
    final byName = {for (final option in state.options) option.name: option};
    final a = byName['Phòng vận hành A'];
    final b = byName['Nhà kính B'];
    if (state.phase != WorkspaceSelectionPhase.ready ||
        state.hasMore ||
        state.options.length != (onlyA ? 1 : 2) ||
        byName.length != state.options.length ||
        coordinator.session.workspaces.length != state.options.length ||
        a == null ||
        a.role != WorkspaceRole.admin ||
        a.status != WorkspaceStatus.active ||
        (expectedA != null && a.id != expectedA) ||
        (onlyA
            ? b != null
            : b == null ||
                  b.role != WorkspaceRole.user ||
                  b.status != WorkspaceStatus.active ||
                  b.id == a.id) ||
        find.byKey(ValueKey('workspace-row-${a.id}')).evaluate().length != 1 ||
        (!onlyA &&
            find.byKey(ValueKey('workspace-row-${b!.id}')).evaluate().length !=
                1)) {
      throw StateError('NATIVE_MEMBERSHIP_PICKER_INVALID');
    }
    return (a: a.id, b: b?.id);
  }

  /// Một absolute20s xuyên input/scroll/IME/tap/busy/completion, không reset tại busy.
  /// Input
  /// Param: key — control thật, không gọi callback trực tiếp.
  /// Param: phase — session busy dự kiến của intent.
  /// Param: deadline — budget đã chốt trước input login, null với operation không nhập.
  Future<void> act(
    String key,
    AppSessionPhase phase, {
    Duration? deadline,
  }) async {
    final before = coordinator.session;
    final generation = coordinator.generation;
    final limit = deadline ?? elapsed() + const Duration(seconds: 20);
    markStage(key.startsWith('workspace-select-') ? 'membership-select' : key);
    await ui.tap(
      key,
      limit,

      /// Kiểm epoch ngay trước pointer để stale frame không thành intent mới.
      beforeTap: () => unchanged(before, generation),
    );
    await ui.wait(
      /// Fresh busy phải thực sự render sau intent hiện hành.
      () =>
          find.byKey(const ValueKey('app-loading')).evaluate().length == 1 &&
          coordinator.page == AppAuthPage.loading &&
          coordinator.session.phase == phase &&
          coordinator.generation > generation &&
          coordinator.session.generation > before.generation &&
          !identical(before, coordinator.session),
      limit,
    );
    await ui.wait(
      /// Spinner biến mất chưa tự là success, caller tiếp tục kiểm business invariant.
      () => coordinator.page != AppAuthPage.loading,
      limit,
    );
    if (identical(before, coordinator.session) ||
        coordinator.generation <= generation ||
        coordinator.session.generation <= before.generation) {
      throw StateError('NATIVE_MEMBERSHIP_FRESH_COMPLETION_INVALID');
    }
  }

  signedOut();
  await pause('membership-before-login');
  final beforeInput = coordinator.session;
  final inputGeneration = coordinator.generation;
  final inputDeadline = elapsed() + const Duration(seconds: 20);
  ui.guard(inputDeadline);
  await tester.enterText(find.byKey(const ValueKey('auth-email')), email);
  ui.guard(inputDeadline);
  unchanged(beforeInput, inputGeneration);
  await tester.enterText(find.byKey(const ValueKey('auth-password')), password);
  ui.guard(inputDeadline);
  unchanged(beforeInput, inputGeneration);
  await act('auth-submit', AppSessionPhase.submitting, deadline: inputDeadline);
  final initial = picker(onlyA: false);
  await pause('membership-picker');
  picker(onlyA: false, expectedA: initial.a);

  await act('workspace-select-${initial.b}', AppSessionPhase.checking);
  fullIdentity();
  final denied = coordinator.session;
  final failure = denied.failure;
  final deniedScreen = find.byType(WorkspaceSelectionScreen);
  if (coordinator.page != AppAuthPage.workspaces ||
      failure?.kind != AppAuthFailureKind.resourceNotFound ||
      failure!.outcomeUnknown ||
      denied.selectedWorkspace != null ||
      denied.workspacesLoaded ||
      denied.workspaces.isNotEmpty ||
      denied.nextWorkspaceCursor != null ||
      deniedScreen.evaluate().length != 1 ||
      tester.widget<WorkspaceSelectionScreen>(deniedScreen).state.phase !=
          WorkspaceSelectionPhase.permissionDenied ||
      tester
          .widget<WorkspaceSelectionScreen>(deniedScreen)
          .state
          .options
          .isNotEmpty ||
      find.byKey(const ValueKey('session-summary')).evaluate().isNotEmpty ||
      find.text('Nhà kính B').evaluate().isNotEmpty ||
      find.byKey(const ValueKey('workspace-refresh')).evaluate().length != 1) {
    throw StateError('NATIVE_MEMBERSHIP_DENIAL_INVALID');
  }
  await pause('membership-denied');

  await act('workspace-refresh', AppSessionPhase.checking);
  picker(onlyA: true, expectedA: initial.a);
  if (find.text('Nhà kính B').evaluate().isNotEmpty ||
      find
          .byKey(ValueKey('workspace-select-${initial.b}'))
          .evaluate()
          .isNotEmpty) {
    throw StateError('NATIVE_MEMBERSHIP_PICKER_INVALID');
  }
  await pause('membership-only-a');

  await act('workspace-select-${initial.a}', AppSessionPhase.checking);
  fullIdentity();
  final selected = coordinator.session.selectedWorkspace;
  if (coordinator.page != AppAuthPage.summary ||
      coordinator.session.failure != null ||
      selected?.id != initial.a ||
      selected?.role != 'ADMIN' ||
      selected?.name != 'Phòng vận hành A' ||
      selected?.isOperational != true ||
      find.byKey(const ValueKey('session-summary')).evaluate().length != 1 ||
      find.text(email).evaluate().length != 1 ||
      find.text('Phòng vận hành A').evaluate().length != 1 ||
      find.text('Quản trị viên').evaluate().length != 1 ||
      find.text('Nhà kính B').evaluate().isNotEmpty) {
    throw StateError('NATIVE_MEMBERSHIP_SUMMARY_INVALID');
  }
  await pause('membership-a-opened');

  await act('session-logout', AppSessionPhase.loggingOut);
  signedOut();
  await pause('membership-logged-out');
  signedOut();
}
