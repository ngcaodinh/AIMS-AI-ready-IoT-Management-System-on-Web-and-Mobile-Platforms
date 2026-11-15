import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import '../../lib/features/auth/data/app_auth_api.dart';
import '../../lib/features/auth/data/app_auth_failure.dart';
import '../../lib/features/auth/data/app_session_repository.dart';
import '../../lib/features/auth/data/app_session_state.dart';
import '../../lib/features/workspaces/data/available_workspace_page.dart';
import '../../lib/features/workspaces/data/workspace_access_detail.dart';
import '../contracts/workspace_access_detail_test.dart' as detail;
import 'app_session_repository_test.dart' as session;

const secondWorkspaceId = '22222222-2222-4222-8222-222222222222';

/// Tạo page schema thật từ synthetic ids, không bỏ qua parser để làm PASS giả.
/// Input
/// Param: ids — UUID summary của page, empty vẫn có thể còn cursor.
/// Param: cursor — opaque next cursor, null chỉ khi server xác nhận hết trang.
/// Output: immutable DTO dùng làm response của fake capability.
AvailableWorkspacePage workspacePage(List<String> ids, {String? cursor}) =>
    AvailableWorkspacePage.fromJson({
      'items': [
        for (final id in ids)
          {
            'id': id,
            'name': id,
            'status': 'ACTIVE',
            'role': 'USER',
            'revision': 1,
          },
      ],
      'nextCursor': cursor,
    });

/// Fake giữ Future gốc và token ledger để kiểm ownership, không gửi HTTP hoặc đọc secure storage thật.
final class CapabilityFake implements AppWorkspaceApi, AppPasswordApi {
  AvailableWorkspacePage page = workspacePage([detail.workspaceIdentity]);
  WorkspaceAccessDetail selected = WorkspaceAccessDetail.fromJson(
    detail.detailBody(),
  );
  final listCalls = <(String, String?)>[];
  final detailCalls = <(String, String)>[];
  final passwordCalls = <(String, String, String)>[];
  AppAuthFailure? failure;
  bool rawFailure = false;
  Completer<AvailableWorkspacePage>? pageGate;
  Completer<WorkspaceAccessDetail>? detailGate;
  Completer<void>? passwordGate;

  /// Trả page hoặc typed failure, không tự normalize cursor/token.
  /// Input
  /// Param: token — bearer nhận từ repository để đối chiếu đúng session.
  /// Param: cursor — query cursor nguyên bản, không decode từ fixture.
  /// Output: Future thật có thể còn pending sau suspend.
  @override
  Future<AvailableWorkspacePage> listWorkspaces(
    String token, {
    String? cursor,
  }) async {
    listCalls.add((token, cursor));
    if (pageGate != null) return pageGate!.future;
    if (failure != null) throw failure!;
    return page;
  }

  /// Recheck trả detail đã parse; test điều khiển permission/lifecycle độc lập summary cũ.
  /// Input
  /// Param: token — bearer của request detail, không lấy lại từ store.
  /// Param: workspaceId — id user chọn từ page hiện hành.
  /// Output: detail hoặc gate giữ late result.
  @override
  Future<WorkspaceAccessDetail> getWorkspace(
    String token,
    String workspaceId,
  ) async {
    detailCalls.add((token, workspaceId));
    if (detailGate != null) return detailGate!.future;
    if (failure != null) throw failure!;
    return selected;
  }

  /// Chỉ ghi đúng một POST intent và await ACK thật; error có thể xảy ra sau gate.
  /// Input
  /// Param: token — đúng bearer private của session được đổi password.
  /// Param: currentPassword — input gốc, không lưu ngoài ledger synthetic test.
  /// Param: newPassword — input gốc cho một mutation.
  @override
  Future<void> changePassword(
    String token,
    String currentPassword,
    String newPassword,
  ) async {
    passwordCalls.add((token, currentPassword, newPassword));
    await passwordGate?.future;
    if (rawFailure) throw StateError('synthetic-safe-unexpected');
    if (failure != null) throw failure!;
  }
}

/// Một repo/store/API lifetime cho mỗi test; reuse fake boundaries cũ, không gọi main suite import.
final class CapabilityHarness {
  /// Inject capability thật là fake trong test, stable token dùng restore server trước mọi operation.
  CapabilityHarness() {
    auth = session.SessionApiFake(events);
    store = session.SessionStoreFake(events)..value = session.sessionToken;
    repository = AppSessionRepository(
      api: auth,
      tokenStore: store,
      workspaceApi: capability,
      passwordApi: capability,
      now: now,
    );
  }
  final events = <String>[];
  final capability = CapabilityFake();
  late final session.SessionApiFake auth;
  late final session.SessionStoreFake store;
  late final AppSessionRepository repository;

  /// Output: clock synthetic không phụ thuộc giờ máy cho token DTO.
  DateTime now() => session.initialTime;

  /// Restore full/limited từ server, không gán trực tiếp state hoặc bearer của repository.
  /// Input
  /// Param: limited — tạo403PASSWORD_CHANGE_REQUIRED cho bootstrap, không full profile.
  Future<void> ready({bool limited = false}) async {
    if (limited)
      auth.profileFailure = const AppAuthFailure(
        AppAuthFailureKind.passwordChangeRequired,
      );
    await repository.restore();
    expect(
      repository.state.phase,
      limited ? AppSessionPhase.limited : AppSessionPhase.full,
    );
  }
}

/// Full list merge giữ dữ liệu tích lũy qua trang cuối rỗng, lựa chọn vẫn cần server recheck.
Future<void> checkFullWorkspaceFlow() async {
  final harness = CapabilityHarness();
  await harness.ready();
  harness.capability.page = workspacePage([
    detail.workspaceIdentity,
  ], cursor: 'opaque +');
  await harness.repository.loadWorkspaces();
  expect(harness.repository.state.workspacesLoaded, isTrue);
  expect(
    harness.repository.state.workspaces.single.id,
    detail.workspaceIdentity,
  );
  expect(harness.repository.state.selectedWorkspace, isNull);
  expect(harness.capability.listCalls.single, (session.sessionToken, null));
  harness.capability.page = workspacePage([], cursor: null);
  await harness.repository.loadWorkspaces(loadMore: true);
  expect(harness.capability.listCalls.last, (session.sessionToken, 'opaque +'));
  expect(harness.repository.state.workspaces.length, 1);
  expect(harness.repository.state.nextWorkspaceCursor, isNull);
  await harness.repository.selectWorkspace(detail.workspaceIdentity);
  expect(harness.capability.detailCalls.single, (
    session.sessionToken,
    detail.workspaceIdentity,
  ));
  expect(
    harness.repository.state.selectedWorkspace?.id,
    detail.workspaceIdentity,
  );
  expect(
    () => harness.repository.state.workspaces.clear(),
    throwsUnsupportedError,
  );
  await harness.repository.dispose();
}

/// Limited không list/select và invalid selection không tạo request, không suy quyền từ caller UUID.
Future<void> checkLimitedAndInvalidSelection() async {
  final harness = CapabilityHarness();
  await harness.ready(limited: true);
  await harness.repository.loadWorkspaces();
  await harness.repository.selectWorkspace(detail.workspaceIdentity);
  expect(harness.capability.listCalls, isEmpty);
  expect(harness.capability.detailCalls, isEmpty);
  expect(harness.repository.state.phase, AppSessionPhase.limited);
  await harness.repository.dispose();
  final full = CapabilityHarness();
  await full.ready();
  await full.repository.selectWorkspace(detail.workspaceIdentity);
  expect(full.capability.detailCalls, isEmpty);
  await full.repository.loadWorkspaces();
  await full.repository.selectWorkspace(secondWorkspaceId);
  expect(full.capability.detailCalls, isEmpty);
  await full.repository.dispose();
}

/// Cursor loop/duplicate/inactive/detail permissions không được thành selection hoặc endless pagination.
Future<void> checkWorkspaceNegativeResults() async {
  for (final variant in [
    'loop',
    'duplicate',
    'inactive',
    'denied',
    'missing',
    'conflict',
    'expired',
    'limited',
  ]) {
    final harness = CapabilityHarness();
    await harness.ready();
    harness.capability.page = workspacePage([
      detail.workspaceIdentity,
    ], cursor: '');
    await harness.repository.loadWorkspaces();
    if (variant == 'loop' || variant == 'duplicate') {
      harness.capability.page = workspacePage(
        variant == 'duplicate' ? [detail.workspaceIdentity] : [],
        cursor: variant == 'loop' ? '' : null,
      );
      await harness.repository.loadWorkspaces(loadMore: true);
    } else {
      harness.capability.selected = WorkspaceAccessDetail.fromJson({
        ...detail.detailBody(),
        'membershipStatus': variant == 'inactive' ? 'REMOVED' : 'ACTIVE',
      });
      harness.capability.failure = switch (variant) {
        'denied' => const AppAuthFailure(AppAuthFailureKind.permissionDenied),
        'missing' => const AppAuthFailure(AppAuthFailureKind.resourceNotFound),
        'conflict' => const AppAuthFailure(AppAuthFailureKind.conflict),
        'expired' => const AppAuthFailure(AppAuthFailureKind.sessionExpired),
        'limited' => const AppAuthFailure(
          AppAuthFailureKind.passwordChangeRequired,
        ),
        _ => null,
      };
      await harness.repository.selectWorkspace(detail.workspaceIdentity);
    }
    expect(harness.repository.state.selectedWorkspace, isNull);
    expect(harness.repository.state.workspaces, isEmpty);
    expect(harness.repository.state.phase, switch (variant) {
      'loop' || 'duplicate' => AppSessionPhase.pending,
      'expired' => AppSessionPhase.signedOut,
      'limited' => AppSessionPhase.limited,
      _ => AppSessionPhase.full,
    });
    await harness.repository.dispose();
  }
}

/// Late workspace results và thao tác trùng không publish protected data sau lifecycle lock.
Future<void> checkWorkspaceLateResults() async {
  for (final operation in ['list', 'detail']) {
    final harness = CapabilityHarness();
    await harness.ready();
    if (operation == 'detail') await harness.repository.loadWorkspaces();
    final page = Completer<AvailableWorkspacePage>();
    final selected = Completer<WorkspaceAccessDetail>();
    if (operation == 'list') harness.capability.pageGate = page;
    if (operation == 'detail') harness.capability.detailGate = selected;
    final call = operation == 'list'
        ? harness.repository.loadWorkspaces()
        : harness.repository.selectWorkspace(detail.workspaceIdentity);
    await session.settleSession();
    expect(harness.repository.busy, isTrue);
    await harness.repository.changePassword('x', 'new');
    expect(harness.capability.passwordCalls, isEmpty);
    harness.repository.suspend();
    if (operation == 'list') {
      page.complete(workspacePage([detail.workspaceIdentity]));
    } else {
      selected.complete(harness.capability.selected);
    }
    await call;
    expect(harness.repository.state.phase, AppSessionPhase.checking);
    expect(harness.repository.state.workspaces, isEmpty);
    expect(harness.repository.state.selectedWorkspace, isNull);
    await harness.repository.dispose();
  }
}

/// Password ACK hoặc session401 cần delete ACK, trong khi wrong current/429 không xóa hoặc nâng scope.
Future<void> checkPasswordResolution() async {
  for (final variant in [
    'success',
    'expired',
    'wrong',
    'limitedWrong',
    'rate',
  ]) {
    final harness = CapabilityHarness();
    await harness.ready(limited: variant == 'limitedWrong');
    harness.capability.failure = switch (variant) {
      'expired' => const AppAuthFailure(AppAuthFailureKind.sessionExpired),
      'wrong' || 'limitedWrong' => const AppAuthFailure(
        AppAuthFailureKind.invalidCredentials,
      ),
      'rate' => const AppAuthFailure(
        AppAuthFailureKind.rateLimited,
        retryAfterSeconds: 3,
      ),
      _ => null,
    };
    final deletion = Completer<void>();
    if (variant == 'success' || variant == 'expired')
      harness.store.deleteGate = deletion;
    final call = harness.repository.changePassword(' x ', ' Abc1234 ');
    await session.settleSession();
    expect(harness.capability.passwordCalls.single, (
      session.sessionToken,
      ' x ',
      ' Abc1234 ',
    ));
    if (variant == 'success' || variant == 'expired') {
      expect(harness.repository.busy, isTrue);
      expect(harness.repository.state.phase, isNot(AppSessionPhase.signedOut));
      deletion.complete();
    }
    await call;
    expect(harness.repository.state.phase, switch (variant) {
      'success' || 'expired' => AppSessionPhase.signedOut,
      'limitedWrong' => AppSessionPhase.limited,
      _ => AppSessionPhase.full,
    });
    expect(
      harness.store.value == null,
      variant == 'success' || variant == 'expired',
    );
    await harness.repository.dispose();
  }
}

/// Unknown/raw POST phải giữ latch qua recover/resume; user logout đúng token là đường resolution riêng.
Future<void> checkUnknownPasswordFence() async {
  for (final variant in ['unknown', 'raw', 'limited']) {
    final harness = CapabilityHarness();
    await harness.ready(limited: variant == 'limited');
    harness.capability.failure = const AppAuthFailure(
      AppAuthFailureKind.networkUnavailable,
      outcomeUnknown: true,
    );
    harness.capability.rawFailure = variant == 'raw';
    await harness.repository.changePassword('x', 'new');
    expect(harness.repository.state.phase, AppSessionPhase.pending);
    await harness.repository.restore();
    await harness.repository.recover();
    expect(harness.repository.state.phase, AppSessionPhase.pending);
    harness.repository.suspend();
    await harness.repository.resume();
    expect(harness.repository.state.phase, AppSessionPhase.pending);
    await harness.repository.changePassword('x', 'second');
    expect(harness.capability.passwordCalls.length, 1);
    await harness.repository.logout();
    expect(harness.auth.logoutTokens, [session.sessionToken]);
    expect(harness.repository.state.phase, AppSessionPhase.signedOut);
    await harness.repository.dispose();
  }
}

/// Late password effect phải drain đúng token trước resume/dispose, không phục hồi captured full phase cũ.
Future<void> checkLatePasswordEffects() async {
  for (final variant in [
    'success',
    'expired',
    'unknown',
    'wrong',
    'disposed',
  ]) {
    final harness = CapabilityHarness();
    await harness.ready();
    final gate = Completer<void>();
    harness.capability.passwordGate = gate;
    harness.capability.failure = switch (variant) {
      'expired' => const AppAuthFailure(AppAuthFailureKind.sessionExpired),
      'unknown' => const AppAuthFailure(
        AppAuthFailureKind.unavailable,
        outcomeUnknown: true,
      ),
      'wrong' => const AppAuthFailure(AppAuthFailureKind.invalidCredentials),
      _ => null,
    };
    final call = harness.repository.changePassword('x', 'new');
    await session.settleSession();
    harness.repository.suspend();
    final disposed = variant == 'disposed'
        ? harness.repository.dispose()
        : null;
    gate.complete();
    await call;
    expect(harness.repository.state.phase, AppSessionPhase.checking);
    expect(
      harness.store.value == null,
      ['success', 'expired', 'disposed'].contains(variant),
    );
    if (disposed != null) {
      await disposed;
    } else {
      await harness.repository.resume();
      expect(harness.repository.state.phase, switch (variant) {
        'success' || 'expired' => AppSessionPhase.signedOut,
        'unknown' => AppSessionPhase.pending,
        _ => AppSessionPhase.full,
      });
      await harness.repository.dispose();
    }
  }
}

/// Cấp UUID synthetic khác nhau để kiểm memory budget, không dùng số lượng lặp giả duplicate.
/// Input
/// Param: index — số thứ tự nhỏ trong fixture, chuyển thành suffix hex đủ12ký tự.
/// Output: UUID v4/variant8 hợp schema, không định danh resource thật.
String indexedWorkspaceId(int index) =>
    'abcdefab-cdef-4abc-8def-${index.toRadixString(16).padLeft(12, '0')}';

/// Giới hạn UI phải cho phép exact budget và fail explicit khi vượt, không giả đã hết danh sách.
Future<void> checkPaginationBudgets() async {
  for (final count in [1000, 1001]) {
    final harness = CapabilityHarness();
    await harness.ready();
    harness.capability.page = workspacePage([
      for (var index = 0; index < count; index++) indexedWorkspaceId(index),
    ]);
    await harness.repository.loadWorkspaces();
    expect(
      harness.repository.state.phase,
      count == 1000 ? AppSessionPhase.full : AppSessionPhase.pending,
    );
    expect(
      harness.repository.state.workspaces.length,
      count == 1000 ? count : 0,
    );
    await harness.repository.dispose();
  }
  final harness = CapabilityHarness();
  await harness.ready();
  for (var page = 0; page < 100; page++) {
    harness.capability.page = workspacePage([], cursor: 'cursor$page');
    await harness.repository.loadWorkspaces(loadMore: page > 0);
    expect(harness.repository.state.phase, AppSessionPhase.full);
    expect(harness.repository.state.workspacesLoaded, isTrue);
    expect(harness.repository.state.nextWorkspaceCursor, 'cursor$page');
  }
  await harness.repository.loadWorkspaces(loadMore: true);
  expect(harness.repository.state.phase, AppSessionPhase.pending);
  expect(harness.capability.listCalls.length, 100);
  await harness.repository.recover();
  harness.capability.page = workspacePage([]);
  await harness.repository.loadWorkspaces();
  expect(harness.repository.state.phase, AppSessionPhase.full);
  expect(harness.repository.state.workspacesLoaded, isTrue);
  expect(harness.repository.state.workspaces, isEmpty);
  expect(harness.repository.state.nextWorkspaceCursor, isNull);
  await harness.repository.dispose();
}

/// Lỗi native/key mất không thay proof POST outcome; giữ token để logout chủ động và chờ delete ACK.
Future<void> checkPasswordUnknownStorageRecovery() async {
  for (final variant in [
    'readError',
    'keyMissing',
    'sessionRevoked',
    'deleteFailure',
  ]) {
    final harness = CapabilityHarness();
    await harness.ready();
    harness.capability.failure = const AppAuthFailure(
      AppAuthFailureKind.networkUnavailable,
      outcomeUnknown: true,
    );
    await harness.repository.changePassword('x', 'new');
    if (variant == 'readError') harness.store.failRead = true;
    if (variant == 'keyMissing') harness.store.value = null;
    if (variant == 'sessionRevoked') {
      harness.auth.profileFailure = const AppAuthFailure(
        AppAuthFailureKind.sessionExpired,
      );
    }
    if (variant == 'sessionRevoked') {
      final deletion = Completer<void>();
      harness.store.deleteGate = deletion;
      final restore = harness.repository.restore();
      await session.settleSession();
      expect(harness.repository.busy, isTrue);
      expect(harness.repository.state.phase, isNot(AppSessionPhase.signedOut));
      deletion.complete();
      await restore;
      expect(harness.repository.state.phase, AppSessionPhase.signedOut);
    } else {
      await harness.repository.restore();
      await harness.repository.recover();
      expect(harness.repository.state.phase, AppSessionPhase.pending);
      final deletes = harness.store.deletes;
      if (variant == 'deleteFailure') harness.store.failDelete = true;
      await harness.repository.logout();
      expect(harness.auth.logoutTokens, [session.sessionToken]);
      expect(harness.store.deletes, deletes + 1);
      expect(
        harness.repository.state.phase,
        variant == 'deleteFailure'
            ? AppSessionPhase.storageFailure
            : AppSessionPhase.signedOut,
      );
      if (variant == 'deleteFailure') {
        harness.store.failDelete = false;
        await harness.repository.recover();
        expect(harness.repository.state.phase, AppSessionPhase.signedOut);
        expect(harness.capability.passwordCalls.length, 1);
      }
    }
    await harness.repository.dispose();
  }
}

/// Đăng ký repository tests root-authored; không nhận đây là independent tester execution.
void main() {
  test(
    'full workspace pagination preserves accumulated items before server selection',
    checkFullWorkspaceFlow,
  );
  test(
    'limited scope and invalid selections never call workspace capability',
    checkLimitedAndInvalidSelection,
  );
  test(
    'workspace negative results never become selected or stale empty',
    checkWorkspaceNegativeResults,
  );
  test(
    'workspace late results cannot survive suspend or duplicate intent',
    checkWorkspaceLateResults,
  );
  test(
    'password resolution waits delete ACK and known rejection preserves scope',
    checkPasswordResolution,
  );
  test(
    'password unknown remains locked across restore recover resume until logout',
    checkUnknownPasswordFence,
  );
  test(
    'password late effects drain before lifecycle recheck without stale admission',
    checkLatePasswordEffects,
  );
  test(
    'pagination exact budgets and manual refresh remain distinct from empty success',
    checkPaginationBudgets,
  );
  test(
    'password unknown native failures retain correct token until server and delete ACK',
    checkPasswordUnknownStorageRecovery,
  );
}
