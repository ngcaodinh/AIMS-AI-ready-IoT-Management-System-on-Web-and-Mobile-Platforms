import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import '../../lib/features/auth/data/app_auth_failure.dart';
import '../../lib/features/auth/data/app_session_state.dart';
import '../../lib/features/auth/presentation/app_auth_coordinator.dart';
import '../../lib/features/workspaces/data/available_workspace_page.dart';
import '../contracts/workspace_access_detail_test.dart' as detail;
import 'app_auth_coordinator_test.dart' as coordinator;
import 'app_session_capability_test.dart' as capability;

/// Kiểm recovery của form có known denial phải thật sự đối soát server, không là nút no-op.
/// Input
/// Param: limited — true giữ password-only scope, false mở form chủ động từ full.
Future<void> checkKnownPasswordRecovery({required bool limited}) async {
  // Cả permission và conflict đều có canRecover trong presentation, không được bỏ route password.
  for (final failureKind in [
    AppAuthFailureKind.permissionDenied,
    AppAuthFailureKind.conflict,
  ]) {
    final harness = coordinator.CoordinatorHarness();
    addTearDown(harness.coordinator.close);
    if (limited) {
      harness.source.auth.profileFailure = const AppAuthFailure(
        AppAuthFailureKind.passwordChangeRequired,
      );
    }
    await harness.coordinator.initialize();
    if (!limited) {
      harness.coordinator.openPassword(expectedGeneration: harness.epoch);
    }
    harness.source.capability.failure = AppAuthFailure(failureKind);
    await harness.coordinator.changePassword(
      'synthetic-old',
      'synthetic-new',
      expectedGeneration: harness.epoch,
    );
    expect(harness.coordinator.page, AppAuthPage.password);
    expect(harness.coordinator.session.failure?.kind, failureKind);
    final profileCalls = harness.source.auth.profileTokens.length;
    final deletes = harness.source.store.deletes;

    await harness.coordinator.recover(expectedGeneration: harness.epoch);

    expect(
      harness.source.auth.profileTokens.length,
      profileCalls + 1,
      reason: 'Recovery trên form password phải gọi /me đúng session.',
    );
    expect(harness.coordinator.page, AppAuthPage.password);
    expect(
      harness.coordinator.session.phase,
      limited ? AppSessionPhase.limited : AppSessionPhase.full,
    );
    expect(harness.coordinator.session.failure, isNull);
    expect(harness.source.capability.passwordCalls.length, 1);
    expect(harness.source.store.deletes, deletes);
  }
}

/// Form full phải recover được known denial mà không gửi lại password hoặc xóa stable session.
Future<void> checkFullPasswordRecovery() =>
    checkKnownPasswordRecovery(limited: false);

/// Form limited phải recover được known denial mà không nâng thành full hoặc gọi workspace API.
Future<void> checkLimitedPasswordRecovery() =>
    checkKnownPasswordRecovery(limited: true);

/// Close phải đợi late password effect và delete ACK, không báo drain xong khi native I/O còn giữ key.
Future<void> checkCloseDrainsPasswordCleanup() async {
  final harness = coordinator.CoordinatorHarness();
  final mutation = Completer<void>();
  final deletion = Completer<void>();
  Future<void>? passwordCall;
  Future<void>? closeCall;
  try {
    await harness.coordinator.initialize();
    harness.coordinator.openPassword(expectedGeneration: harness.epoch);
    harness.source.capability.passwordGate = mutation;
    harness.source.store.deleteGate = deletion;
    final epoch = harness.epoch;
    passwordCall = harness.coordinator.changePassword(
      'synthetic-old',
      'synthetic-new',
      expectedGeneration: epoch,
    );
    await coordinator.flush();
    harness.coordinator.suspend();
    var closed = false;
    closeCall = harness.coordinator.close().whenComplete(
      /// Chỉ ACK close thật mới đánh dấu drain đã kết thúc; không dựa vào protected page đã ẩn.
      () {
        closed = true;
      },
    );
    mutation.complete();
    await coordinator.flush();
    expect(harness.coordinator.page, AppAuthPage.loading);
    expect(closed, isFalse);
    expect(harness.source.store.value, isNotNull);
    await harness.coordinator.changePassword(
      'second-old',
      'second-new',
      expectedGeneration: epoch,
    );
    expect(harness.source.capability.passwordCalls.length, 1);
    deletion.complete();
    await Future.wait([passwordCall, closeCall]);
    expect(closed, isTrue);
    expect(harness.source.store.value, isNull);
    expect(harness.source.capability.listCalls.length, 1);
  } finally {
    // Assertion thất bại cũng phải thả owned Future để teardown không treo hoặc bỏ native ACK giả.
    if (!mutation.isCompleted) mutation.complete();
    if (!deletion.isCompleted) deletion.complete();
    await passwordCall;
    await closeCall;
    await harness.coordinator.close();
  }
}

/// Final suspend giữa bootstrap phải giữ khóa và không tạo L2 khi không có explicit resume mới.
Future<void> checkFinalSuspendDuringBootstrap() async {
  final harness = coordinator.CoordinatorHarness();
  final page = Completer<AvailableWorkspacePage>();
  Future<void>? resume;
  try {
    await harness.coordinator.initialize();
    harness.coordinator.suspend();
    harness.source.capability.pageGate = page;
    resume = harness.coordinator.resume();
    await coordinator.flush();
    expect(harness.source.capability.listCalls.length, 2);
    harness.coordinator.suspend();
    page.complete(capability.workspacePage([detail.workspaceIdentity]));
    await resume;
    expect(harness.coordinator.page, AppAuthPage.loading);
    expect(harness.coordinator.session.workspaces, isEmpty);
    expect(harness.source.capability.listCalls.length, 2);
  } finally {
    // Thả page gate trước close kể cả assertion lỗi, giữ ownership drain đúng repository.
    if (!page.isCompleted) {
      page.complete(capability.workspacePage([]));
    }
    await resume;
    await harness.coordinator.close();
  }
}

/// Đăng ký oracle độc lập; reuse fake boundaries nhưng không gọi main của các suite import.
void main() {
  test(
    'full password known denial allows explicit recovery without mutation replay',
    checkFullPasswordRecovery,
  );
  test(
    'limited password known denial allows explicit recovery without scope promotion',
    checkLimitedPasswordRecovery,
  );
  test(
    'close drains late password success through native delete ACK',
    checkCloseDrainsPasswordCleanup,
  );
  test(
    'final suspend during old bootstrap remains locked without fresh list',
    checkFinalSuspendDuringBootstrap,
  );
}
