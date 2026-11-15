import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nexa_iot/features/auth/data/app_auth_failure.dart';
import 'package:nexa_iot/features/auth/data/app_session_state.dart';
import 'package:nexa_iot/features/auth/presentation/app_auth_application.dart';
import 'package:nexa_iot/features/auth/presentation/app_auth_coordinator.dart';
import 'package:nexa_iot/features/auth/presentation/login_screen.dart';
import 'package:nexa_iot/features/auth/presentation/login_view_state.dart';
import 'package:nexa_iot/features/workspaces/presentation/workspace_selection_screen.dart';
import 'package:nexa_iot/features/workspaces/presentation/workspace_selection_state.dart';

import 'native_rate_probe.dart';

/// Chỉ synthetic secrets qua private SDK packet; production credential parser không dùng quy tắc test này.
bool validNativeRateCredentials(Map<String, Object?> packet) =>
    packet['password'] is String &&
    RegExp(r'^Aa1[0-9a-f]{32}$').hasMatch(packet['password']! as String) &&
    packet['wrongPassword'] is String &&
    RegExp(r'^Aa2[0-9a-f]{32}$').hasMatch(packet['wrongPassword']! as String) &&
    packet['wrongPassword'] != packet['password'];

/// Bao cả TLS/main/teardown ngay từ khi nhận packet; lỗi sớm cũng bỏ cả hai references trước framework outcome.
Future<void> withNativeRateCredentials(
  Map<String, Object?> packet,
  Future<void> Function() body,
) async {
  try {
    await body();
  } finally {
    packet['password'] = '';
    packet['wrongPassword'] = '';
  }
}

/// Freshness đọc snapshot công khai của App thật; không token, callback nghiệp vụ hoặc raw response.
void verifyNativeRateRejection({
  required AppSessionState before,
  required AppSessionState after,
  required int generationBefore,
  required int generationAfter,
  required bool observedBusy,
  required AppAuthFailureKind expected,
}) {
  final failure = after.failure;
  final rate = expected == AppAuthFailureKind.rateLimited;
  if (!observedBusy ||
      before.phase != AppSessionPhase.signedOut ||
      after.phase != AppSessionPhase.signedOut ||
      identical(before, after) ||
      identical(before.failure, failure) ||
      after.generation <= before.generation ||
      generationAfter <= generationBefore ||
      failure?.kind != expected ||
      failure!.outcomeUnknown ||
      after.profile != null ||
      after.selectedWorkspace != null ||
      after.workspacesLoaded ||
      after.workspaces.isNotEmpty ||
      (rate
          ? failure.retryAfterSeconds == null ||
                failure.retryAfterSeconds! < 1 ||
                failure.retryAfterSeconds! > 900
          : expected != AppAuthFailureKind.invalidCredentials ||
                failure.retryAfterSeconds != null)) {
    throw StateError('NATIVE_RATE_FRESH_REJECTION_INVALID');
  }
}

/// Đọc số đang render trong chính card, không thay bằng coordinator clock khi Text stale/sai.
({int remainingSeconds, bool cooldownVisible, bool formVisible})
readNativeRateUi(WidgetTester tester, {required int coordinatorSeconds}) {
  final card = find.byKey(const ValueKey('app-cooldown'));
  final cards = card.evaluate().length;
  final forms = find.byKey(const ValueKey('auth-submit')).evaluate().length;
  if (cards == 0 && forms == 1 && coordinatorSeconds == 0) {
    return (remainingSeconds: 0, cooldownVisible: false, formVisible: true);
  }
  if (cards != 1 ||
      forms != 0 ||
      coordinatorSeconds < 0 ||
      coordinatorSeconds > 900) {
    throw StateError('NATIVE_RATE_RENDERED_COUNTDOWN_INVALID');
  }
  final widget = tester.widget<Widget>(card);
  if (widget is! AuthStatusScreen ||
      !widget.waiting ||
      widget.loading ||
      !RegExp(r'^Thử lại sau ([1-9][0-9]{0,2}) giây$').hasMatch(widget.title)) {
    throw StateError('NATIVE_RATE_RENDERED_COUNTDOWN_INVALID');
  }
  final header = find.descendant(
    of: card,
    matching: find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.header == true,
    ),
  );
  final headerTexts = tester.widgetList<Text>(
    find.descendant(of: header, matching: find.byType(Text)),
  );
  if (header.evaluate().length != 1 ||
      headerTexts.length != 1 ||
      headerTexts.single.data != widget.title) {
    throw StateError('NATIVE_RATE_RENDERED_COUNTDOWN_INVALID');
  }
  final titles = tester
      .widgetList<Text>(find.descendant(of: card, matching: find.byType(Text)))
      .map(
        /// Chỉ đọc Text node đã mount; không giữ hoặc log chuỗi UI ngoài title số cần kiểm.
        (text) =>
            RegExp(r'^Thử lại sau ([1-9][0-9]{0,2}) giây$')
                .firstMatch(text.data ?? ''),
      )
      .whereType<RegExpMatch>()
      .toList();
  if (titles.length != 1 || titles.single.group(0) != widget.title)
    throw StateError('NATIVE_RATE_RENDERED_COUNTDOWN_INVALID');
  final shown = int.parse(titles.single.group(1)!);
  if (shown > 900 || (shown - coordinatorSeconds).abs() > 1) {
    throw StateError('NATIVE_RATE_RENDERED_COUNTDOWN_INVALID');
  }
  return (remainingSeconds: shown, cooldownVisible: true, formVisible: false);
}

/// Thao tác UI dùng absolute deadline của caller, phase default1260s cho rate hoặc fixed420s cho membership.
final class NativeScenarioUi {
  /// Chốt engine/clock và cap riêng, default giữ rate1260s.
  /// Input
  /// Param: tester — engine đang sở hữu App sản phẩm.
  /// Param: elapsed — monotonic clock neo valid packet.
  /// Param: phaseLimit — fixed budget do scenario chọn, không nhận packet tùy ý.
  /// Param: timeoutCode — fixed diagnostics không chứa credential.
  NativeScenarioUi(
    this.tester,
    this.elapsed, {
    this.phaseLimit = const Duration(seconds: 1260),
    this.timeoutCode = 'NATIVE_RATE_UI_TIMEOUT',
  });
  final Duration phaseLimit;
  final String timeoutCode;
  final WidgetTester tester;
  final Duration Function() elapsed;

  /// Guard trước/sau mỗi await; timeout không chứng minh HTTP/SDK I/O terminal.
  /// Input
  /// Param: deadline — absolute operation budget của caller, null chỉ kiểm phase.
  void guard([Duration? deadline]) {
    final current = elapsed();
    if (current.isNegative ||
        current >= phaseLimit ||
        (deadline != null && current >= deadline))
      throw StateError(timeoutCode);
  }

  /// Real async yield giữ timer/Stopwatch tiến, pump chỉ dựng frame sau đó.
  /// Input
  /// Param: delay — thời gian thật cho SDK/network/timer tiến.
  /// Param: deadline — cùng operation budget, không reset sau yield.
  Future<void> frame(Duration delay, [Duration? deadline]) async {
    guard(deadline);
    await tester.runAsync(
      /// Delay thật giữ test/native clock cùng tiến, không fast-forward cooldown/pause.
      () => Future<void>.delayed(delay),
    );
    guard(deadline);
    await tester.pump();
    guard(deadline);
  }

  /// Poll UI/state hiện hành, không reset operation deadline khi finder chưa xuất hiện.
  /// Input
  /// Param: ready — predicate read-only của UI/state đã mount.
  /// Param: deadline — absolute limit xuyên các lần poll.
  Future<void> wait(bool Function() ready, Duration deadline) async {
    while (true) {
      guard(deadline);
      if (ready()) return;
      await frame(const Duration(milliseconds: 50), deadline);
    }
  }

  /// Strict hit-test/tap UI thật, scroll/IME stabilization nằm trong cùng deadline.
  /// Input
  /// Param: key — key control sản phẩm cần lookup/tap.
  /// Param: deadline — budget của operation, không cộng thêm khi re-scroll.
  /// Param: beforeTap — guard snapshot/epoch ngay trước pointer, không callback nghiệp vụ.
  Future<void> tap(
    String key,
    Duration deadline, {
    VoidCallback? beforeTap,
  }) async {
    final finder = find.byKey(ValueKey(key));
    await wait(
      /// Chỉ một target hiện hành mới được hit-test, không chọn tùy tiện widget trùng key.
      () => finder.evaluate().length == 1,
      deadline,
    );
    guard(deadline);
    await tester.ensureVisible(finder);
    guard(deadline);
    await frame(const Duration(milliseconds: 350), deadline);
    while (finder.hitTestable().evaluate().length != 1) {
      guard(deadline);
      await tester.ensureVisible(finder);
      guard(deadline);
      await frame(const Duration(milliseconds: 50), deadline);
    }
    guard(deadline);
    beforeTap?.call();
    guard(deadline);
    await tester.tap(finder);
    guard(deadline);
    await tester.pump();
    guard(deadline);
  }
}

/// Native actual scenario: main/API/storage đã được target dựng; chỉ WidgetTester nhập/tap và đọc state công khai.
Future<void> verifyNativeRateScenario(
  WidgetTester tester,
  Map<String, Object?> packet, {
  required Duration Function() elapsed,
  required Future<void> Function(String stage) checkpoint,
  required void Function(String stage) markStage,
}) async {
  if (!validNativeRateCredentials(packet))
    throw StateError('INVALID_NATIVE_RATE_PACKET');
  final ui = NativeScenarioUi(tester, elapsed);
  final initialDeadline = elapsed() + const Duration(seconds: 20);
  await ui.wait(
    () =>
        find.byType(AppAuthApplication).evaluate().length == 1 &&
        find.byKey(const ValueKey('auth-email')).evaluate().length == 1,
    initialDeadline,
  );
  final coordinator = tester
      .widget<AppAuthApplication>(find.byType(AppAuthApplication))
      .coordinator;
  final email = (packet['emails'] as List).first as String;

  /// Không có protected UI/state trước login hoặc trong toàn bộ observation.
  void noProtected() {
    ui.guard();
    if (coordinator.session.phase != AppSessionPhase.signedOut ||
        coordinator.session.profile != null ||
        coordinator.session.selectedWorkspace != null ||
        coordinator.session.workspacesLoaded ||
        coordinator.session.workspaces.isNotEmpty ||
        find.byType(WorkspaceSelectionScreen).evaluate().isNotEmpty ||
        find.byKey(const ValueKey('session-summary')).evaluate().isNotEmpty) {
      throw StateError('NATIVE_RATE_PRELOGIN_PROTECTED_STATE');
    }
  }

  /// Một operation20s xuyên input/tap/fresh busy/completion; trước tap không được có intent nền đổi epoch.
  Future<
    ({
      AppSessionState before,
      int generation,
      Duration submittedAt,
      Duration deadline,
    })
  >
  submit(String password) async {
    final deadline = elapsed() + const Duration(seconds: 20);
    final before = coordinator.session;
    final generation = coordinator.generation;
    void unchanged() {
      if (!identical(before, coordinator.session) ||
          generation != coordinator.generation ||
          coordinator.page != AppAuthPage.login)
        throw StateError('NATIVE_RATE_UNEXPECTED_INTENT');
    }

    noProtected();
    unchanged();
    await ui.wait(
      () => find.byKey(const ValueKey('auth-email')).evaluate().length == 1,
      deadline,
    );
    unchanged();
    ui.guard(deadline);
    await tester.enterText(find.byKey(const ValueKey('auth-email')), email);
    ui.guard(deadline);
    unchanged();
    await tester.enterText(
      find.byKey(const ValueKey('auth-password')),
      password,
    );
    ui.guard(deadline);
    unchanged();
    final submittedAt = elapsed();
    await ui.tap('auth-submit', deadline, beforeTap: unchanged);
    await ui.wait(
      () =>
          find.byKey(const ValueKey('app-loading')).evaluate().length == 1 &&
          coordinator.page == AppAuthPage.loading &&
          coordinator.session.phase == AppSessionPhase.submitting,
      deadline,
    );
    await ui.wait(() => coordinator.page != AppAuthPage.loading, deadline);
    return (
      before: before,
      generation: generation,
      submittedAt: submittedAt,
      deadline: deadline,
    );
  }

  ui.guard();
  noProtected();
  await checkpoint('rate-before');
  ui.guard();
  NativeRateObservation? observation;
  AppSessionState? limited;
  int? limitedGeneration;
  Duration? observedAt;
  for (var index = 1; index <= 6; index++) {
    markStage(index == 6 ? 'rate-limited' : 'rate-wrong-$index');
    final attempt = await submit(packet['wrongPassword'] as String);
    final expected = index == 6
        ? AppAuthFailureKind.rateLimited
        : AppAuthFailureKind.invalidCredentials;
    ui.guard(attempt.deadline);
    verifyNativeRateRejection(
      before: attempt.before,
      after: coordinator.session,
      generationBefore: attempt.generation,
      generationAfter: coordinator.generation,
      observedBusy: true,
      expected: expected,
    );
    noProtected();
    if (index < 6) {
      final rejected = find.byWidgetPredicate(
        (widget) =>
            widget is LoginScreen && widget.state == LoginViewState.rejected,
      );
      await ui.wait(() => rejected.evaluate().length == 1, attempt.deadline);
      final messages = tester.widgetList<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('auth-notice')),
          matching: find.byType(Text),
        ),
      );
      if (messages.isEmpty ||
          messages.last.data !=
              'Thông tin đăng nhập không hợp lệ. Kiểm tra email và mật khẩu.') {
        throw StateError('NATIVE_RATE_GENERIC_REJECTION_INVALID');
      }
      await checkpoint('rate-wrong-$index');
      ui.guard();
    } else {
      await ui.wait(
        () =>
            find.byKey(const ValueKey('app-cooldown')).evaluate().length == 1 &&
            coordinator.page == AppAuthPage.login,
        attempt.deadline,
      );
      limited = coordinator.session;
      limitedGeneration = coordinator.generation;
      observedAt = elapsed();
      observation = NativeRateObservation(
        submittedAt: attempt.submittedAt,
        observedAt: observedAt,
        retryAfterSeconds: limited.failure!.retryAfterSeconds!,
      );
    }
  }

  /// Cùng immutable429/epoch phải tồn tại đến explicit correct intent; chỉ timer redraw được phép xảy ra.
  void observe() {
    ui.guard();
    noProtected();
    if (!identical(limited, coordinator.session) ||
        coordinator.generation != limitedGeneration ||
        coordinator.page != AppAuthPage.login)
      throw StateError('NATIVE_RATE_UNEXPECTED_INTENT');
    final sample = readNativeRateUi(
      tester,
      coordinatorSeconds: coordinator.retryAfterSeconds,
    );
    observation!.sample(
      at: elapsed(),
      remainingSeconds: sample.remainingSeconds,
      cooldownVisible: sample.cooldownVisible,
      formVisible: sample.formVisible,
    );
  }

  observe();
  await checkpoint('rate-limited');
  ui.guard();
  observe();
  var mid = false;
  while (!observation!.complete) {
    await ui.frame(const Duration(milliseconds: 250));
    observe();
    if (!mid && elapsed() - observedAt! >= const Duration(seconds: 450)) {
      observe();
      await checkpoint('rate-mid-cooldown');
      ui.guard();
      observe();
      mid = true;
    }
  }
  if (!mid) throw StateError('NATIVE_RATE_MID_CHECKPOINT_MISSING');
  observe();
  await checkpoint('rate-expired');
  ui.guard();
  observe();
  markStage('rate-login');
  final success = await submit(packet['password'] as String);
  final picker = find.byWidgetPredicate(
    (widget) =>
        widget is WorkspaceSelectionScreen && widget.state.options.length == 2,
  );
  await ui.wait(() => picker.evaluate().length == 1, success.deadline);
  final options = tester.widget<WorkspaceSelectionScreen>(picker).state.options;
  final roles = {for (final option in options) option.name: option.role};
  if (roles.length != 2 ||
      roles['Phòng vận hành A'] != WorkspaceRole.admin ||
      roles['Nhà kính B'] != WorkspaceRole.user ||
      coordinator.session.phase != AppSessionPhase.full ||
      coordinator.session.failure != null ||
      identical(success.before, coordinator.session) ||
      coordinator.generation <= success.generation ||
      find.byKey(const ValueKey('session-summary')).evaluate().isNotEmpty)
    throw StateError('NATIVE_RATE_LOGIN_INVALID');
  await checkpoint('rate-login');
  ui.guard();
  markStage('rate-logout');
  final logoutDeadline = elapsed() + const Duration(seconds: 20);
  await ui.tap('workspace-logout', logoutDeadline);
  await ui.wait(
    () =>
        find.byKey(const ValueKey('auth-email')).evaluate().length == 1 &&
        coordinator.page == AppAuthPage.login,
    logoutDeadline,
  );
  noProtected();
  if (coordinator.session.failure != null)
    throw StateError('NATIVE_RATE_LOGOUT_INVALID');
  await checkpoint('rate-logout');
  ui.guard();
}
