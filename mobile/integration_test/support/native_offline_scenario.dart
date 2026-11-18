import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexa_iot/features/auth/data/app_auth_failure.dart';
import 'package:nexa_iot/features/auth/data/app_auth_tls_configuration.dart';
import 'package:nexa_iot/features/auth/data/app_session_state.dart';
import 'package:nexa_iot/features/auth/data/session_token_store.dart';
import 'package:nexa_iot/features/auth/presentation/app_auth_application.dart';
import 'package:nexa_iot/features/auth/presentation/app_auth_coordinator.dart';
import 'package:nexa_iot/features/auth/presentation/login_screen.dart';
import 'package:nexa_iot/features/auth/presentation/login_view_state.dart';
import 'package:nexa_iot/features/workspaces/presentation/workspace_selection_screen.dart';
import 'package:nexa_iot/features/workspaces/presentation/workspace_selection_state.dart';

import 'native_rate_scenario.dart';

/// Kết quả route không credential;401 đúng contract là reachable, không phải login success.
enum NativeOfflineRoute { reachable, unavailable }

/// Kiểm route trong cùng engine với main, dùng TLS factory thật và endpoint fixed không bearer.
/// Output: reachable khi nhận/đóng401 SESSION_EXPIRED; unavailable chỉ SocketException hoặc timeout đã drain.
/// Errors: TLS/redirect/schema/status sai giữ failure, không được suy là offline.
Future<NativeOfflineRoute> observeNativeOfflineRoute() async {
  final origin = Uri.parse('https://10.0.2.2:8443');
  final client = createAuthHttpClientFactory(
    origin,
    labCertificate: const String.fromEnvironment('AUTH_LAB_CA_CERT'),
  )();
  // Giống transport sản phẩm: không đọc proxy environment hoặc chuyển canary ra ngoài origin lab đã pin.
  client.findProxy = null;
  client.connectionTimeout = const Duration(seconds: 10);

  /// Nhận response bounded tới stream terminal, không lưu/log message/correlation/header.
  Future<NativeOfflineRoute> exchange() async {
    final request = await client.getUrl(origin.resolve('/api/v1/me'));
    request.followRedirects = false;
    request.persistentConnection = false;
    request.cookies.clear();
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    final response = await request.close();
    final body = <int>[];
    await for (final chunk in response) {
      if (body.length + chunk.length > 2048) {
        throw StateError('NATIVE_OFFLINE_CANARY_INVALID');
      }
      body.addAll(chunk);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(body));
    } on FormatException {
      throw StateError('NATIVE_OFFLINE_CANARY_INVALID');
    }
    final error = decoded is Map ? decoded['error'] : null;
    if (response.statusCode != 401 ||
        decoded is! Map ||
        decoded.length != 1 ||
        error is! Map ||
        error.length != 4 ||
        error['code'] != 'SESSION_EXPIRED' ||
        error['message'] is! String ||
        error['details'] is! Map ||
        (error['details'] as Map).isNotEmpty ||
        error['correlationId'] is! String ||
        !RegExp(r'^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$')
            .hasMatch(error['correlationId'] as String)) {
      throw StateError('NATIVE_OFFLINE_CANARY_INVALID');
    }
    return NativeOfflineRoute.reachable;
  }

  final pending = exchange();
  unawaited(
    pending.catchError(
      /// Observer sớm chỉ tránh unhandled; Future gốc vẫn quyết định outcome và phải được drain.
      (Object error) => NativeOfflineRoute.unavailable,
    ),
  );
  try {
    return await pending.timeout(const Duration(seconds: 15));
  } on SocketException {
    return NativeOfflineRoute.unavailable;
  } on TimeoutException {
    client.close(force: true);
    try {
      await pending;
    } on Object {
      // Force-close chưa là terminal; chờ Future gốc trước khi trả unavailable.
    }
    return NativeOfflineRoute.unavailable;
  } finally {
    client.close(force: true);
  }
}

/// Bỏ reference password/token kể cả lỗi trước main; không tuyên bố zeroization chuỗi Dart.
/// Input
/// Param: packet — owned RAM packet từ SDK pipe, không nhận tài khoản thật.
/// Param: body — operation native được giữ tới completion/cleanup thật.
Future<void> withNativeOfflineCredentials(
  Map<String, Object?> packet,
  Future<void> Function() body,
) async {
  try {
    await body();
  } finally {
    packet['password'] = '';
    packet['expiredSessionToken'] = '';
  }
}

/// Thực hiện offline→quiet30s→explicit recover/login→A/B→logout bằng input/tap của App sản phẩm.
/// Input
/// Param: tester — engine main, không launch integration target thứ hai trong cùng AVD.
/// Param: packet — năm identities synthetic cùng run và password CSPRNG RAM.
/// Param: elapsed — monotonic elapsed neo ARM, global675s không reset qua checkpoint.
/// Param: checkpoint — năm fixed pauses; host chịu HTTP/DB/network và pending-owner proof trước ACK.
/// Param: markStage — enum diagnostics không input/credential.
/// Param: probe — canary thật mặc định; injection enum chỉ cho host boundary tests được ghi rõ.
/// Param: tokenStore — secure store của sản phẩm; boundary test có thể cấp store synthetic in-memory.
/// Errors: fixed StateError khi stale epoch, business state, gesture hoặc budget không đạt.
Future<void> verifyNativeOfflineScenario(
  WidgetTester tester,
  Map<String, Object?> packet, {
  required Duration Function() elapsed,
  required Future<void> Function(String stage) checkpoint,
  required void Function(String stage) markStage,
  Future<NativeOfflineRoute> Function() probe = observeNativeOfflineRoute,
  SessionTokenStore? tokenStore,
}) async {
  final password = packet['password'];
  final emails = packet['emails'];
  final first = emails is List && emails.isNotEmpty ? emails.first : null;
  final match = first is String
      ? RegExp(
          r'^probe-([0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})-0@example\.invalid$',
        ).firstMatch(first)
      : null;
  if (password is! String ||
      !RegExp(r'^Aa1[0-9a-f]{32}$').hasMatch(password) ||
      emails is! List ||
      emails.length != 5 ||
      match == null) {
    throw StateError('INVALID_NATIVE_OFFLINE_PACKET');
  }
  for (var index = 0; index < 5; index++) {
    if (emails[index] != 'probe-${match.group(1)}-$index@example.invalid') {
      throw StateError('INVALID_NATIVE_OFFLINE_PACKET');
    }
  }
  final email = first as String;
  final ui = NativeScenarioUi(
    tester,
    elapsed,
    phaseLimit: const Duration(seconds: 675),
    timeoutCode: 'NATIVE_OFFLINE_UI_TIMEOUT',
  );
  await ui.wait(
    /// Main phải mount form thật trước canary/off; không lấy spinner làm signed-out readiness.
    () =>
        find.byType(AppAuthApplication).evaluate().length == 1 &&
        find.byKey(const ValueKey('auth-email')).evaluate().length == 1,
    // Shared initial deadline neo ARM: noCA và mount không được nhận thêm20s sau mỗi await.
    const Duration(seconds: 20),
  );
  final coordinator = tester
      .widget<AppAuthApplication>(find.byType(AppAuthApplication))
      .coordinator;
  final store = tokenStore ?? const SecureSessionTokenStore();

  /// Snapshot/epoch chốt trước await không được bị lifecycle hoặc intent khác thay thế.
  /// Input
  /// Param: state — immutable public state trước operation/pause.
  /// Param: generation — presentation epoch cùng snapshot, không lấy lại sau await để hợp thức hóa.
  void unchanged(AppSessionState state, int generation) {
    ui.guard();
    if (!identical(state, coordinator.session) ||
        coordinator.generation != generation) {
      throw StateError('NATIVE_OFFLINE_UNEXPECTED_INTENT');
    }
  }

  /// Không admission/profile/list/selection khi signed-out, field không giữ credential từ lần submit cũ.
  /// Input
  /// Param: failed — true chỉ sau offline typed failure; ready không được giữ lỗi cũ.
  void signedOut({bool failed = false}) {
    ui.guard();
    final state = coordinator.session;
    final screens = find.byType(LoginScreen);
    if (coordinator.page != AppAuthPage.login ||
        state.phase != AppSessionPhase.signedOut ||
        state.profile != null ||
        state.selectedWorkspace != null ||
        state.workspacesLoaded ||
        state.workspaces.isNotEmpty ||
        state.nextWorkspaceCursor != null ||
        screens.evaluate().length != 1 ||
        find.byType(WorkspaceSelectionScreen).evaluate().isNotEmpty ||
        find.byKey(const ValueKey('session-summary')).evaluate().isNotEmpty ||
        (failed
            ? state.failure?.kind != AppAuthFailureKind.networkUnavailable ||
                  state.failure!.outcomeUnknown
            : state.failure != null)) {
      throw StateError('NATIVE_OFFLINE_SIGNED_OUT_INVALID');
    }
    final view = tester.widget<LoginScreen>(screens).state;
    if (view !=
            (failed
                ? LoginViewState.networkUnavailable
                : LoginViewState.ready) ||
        (failed && (view.canSubmit || !view.canRecover)) ||
        tester
                .widget<TextFormField>(find.byKey(const ValueKey('auth-email')))
                .controller
                ?.text !=
            '' ||
        tester
                .widget<TextFormField>(
                  find.byKey(const ValueKey('auth-password')),
                )
                .controller
                ?.text !=
            '' ||
        (failed &&
            (tester
                        .widget<FilledButton>(
                          find.byKey(const ValueKey('auth-submit')),
                        )
                        .onPressed !=
                    null ||
                tester
                        .widget<OutlinedButton>(
                          find.byKey(const ValueKey('auth-recover')),
                        )
                        .onPressed ==
                    null))) {
      throw StateError('NATIVE_OFFLINE_FORM_INVALID');
    }
  }

  /** Kiểm từng lớp outbox sau logout; stage cố định giúp cô lập failure mà không lộ bearer.
   * Input
   * Param: expectedExpiry — expiry ban đầu cần giữ nguyên qua thao tác ghi outbox, nếu có.
   * Param: expectedIntentId — identity bền vững cần giữ qua retry nền, nếu có.
   * Output: id intent cần đối chiếu sau pause offline.
   * Errors: StateError cố định nếu intent/token, storage hoặc protected UI không khớp.
   */
  Future<String> pendingLogout({
    DateTime? expectedExpiry,
    String? expectedIntentId,
  }) async {
    ui.guard();
    final intent = await store.readLogoutIntent();
    markStage('offline-outbox-check-intent');
    if (intent == null ||
        intent.sessionToken.isEmpty ||
        intent.intentId.isEmpty ||
        intent.expiresAt == null ||
        (expectedExpiry != null && intent.expiresAt != expectedExpiry) ||
        (expectedIntentId != null && intent.intentId != expectedIntentId)) {
      throw StateError('NATIVE_OFFLINE_LOGOUT_INTENT_INVALID');
    }
    markStage('offline-outbox-check-session');
    if (await store.readSession() != null) {
      throw StateError('NATIVE_OFFLINE_LOGOUT_SESSION_RETAINED');
    }
    markStage('offline-outbox-check-state');
    if (!coordinator.logoutPending ||
        coordinator.page != AppAuthPage.recovery ||
        coordinator.session.profile != null ||
        coordinator.session.selectedWorkspace != null ||
        coordinator.session.workspaces.isNotEmpty) {
      throw StateError('NATIVE_OFFLINE_LOGOUT_LOCK_INVALID');
    }
    markStage('offline-outbox-check-protected-ui');
    if (find.byType(WorkspaceSelectionScreen).evaluate().isNotEmpty ||
        find.byKey(const ValueKey('session-summary')).evaluate().isNotEmpty) {
      throw StateError('NATIVE_OFFLINE_LOGOUT_OUTBOX_INVALID');
    }
    return intent.intentId;
  }

  /// Pause giữ state/epoch; checkpoint lưu outbox cho phép retry nền đổi generation, caller revalidate sau ACK.
  /// Input
  /// Param: stage — fixed stage của gate offline.
  Future<void> pause(String stage) async {
    final before = coordinator.session;
    final generation = coordinator.generation;
    ui.guard();
    await checkpoint(stage);
    if (stage == 'offline-outbox-persisted') {
      // Retry nền có thể tăng generation; kiểm intent và vùng protected ngay sau pause thay vì cấm retry.
      return;
    }
    unchanged(before, generation);
  }

  /// Kiểm canary cùng engine xong mới đi tiếp; TLS/protocol failure giữ nguyên, không đổi thành offline.
  /// Input
  /// Param: expected — reachable trước/sau fault, unavailable khi guest-off đã ACK.
  Future<void> canary(NativeOfflineRoute expected) async {
    ui.guard();
    final result = await tester.runAsync(probe);
    ui.guard();
    if (result != expected) throw StateError('NATIVE_OFFLINE_ROUTE_INVALID');
  }

  /// Một gesture có absolute20s xuyên input/IME/scroll/busy/completion, không gọi coordinator trực tiếp.
  /// Input
  /// Param: key — control sản phẩm đã mount.
  /// Param: busyPhase — busy enum phải mới thật sau gesture, không chỉ spinner cũ.
  /// Param: deadline — anchor trước nhập credential nếu là login, null với gesture khác.
  Future<void> act(
    String key,
    AppSessionPhase busyPhase, {
    Duration? deadline,
  }) async {
    final before = coordinator.session;
    final generation = coordinator.generation;
    final limit = deadline ?? elapsed() + const Duration(seconds: 20);
    markStage(key.startsWith('workspace-select-') ? 'offline-select' : key);
    var observedRecoveryChecking = false;

    /// Ghi transition checking thật giữa các frame; không gọi action hoặc yêu cầu plugin cố tình chậm.
    void observeRecovery() {
      if (key == 'auth-recover' &&
          coordinator.page == AppAuthPage.loading &&
          coordinator.session.phase == AppSessionPhase.checking &&
          coordinator.generation > generation &&
          coordinator.session.generation > before.generation) {
        observedRecoveryChecking = true;
      }
    }

    coordinator.addListener(observeRecovery);
    try {
      await ui.tap(
        key,
        limit,

        /// Không sử dụng callback của frame stale khi scroll/IME đã gây intent khác.
        beforeTap: () => unchanged(before, generation),
      );
      await ui.wait(
        /// Recovery no-token có thể ACK trước frame; network intents vẫn phải render busy mới.
        () => key == 'auth-recover'
            ? observedRecoveryChecking
            : find.byKey(const ValueKey('app-loading')).evaluate().length ==
                      1 &&
                  coordinator.page == AppAuthPage.loading &&
                  coordinator.session.phase == busyPhase &&
                  coordinator.generation > generation &&
                  coordinator.session.generation > before.generation,
        limit,
      );
      await ui.wait(
        /// Caller kiểm business outcome sau completion, không coi spinner mất là success.
        () => coordinator.page != AppAuthPage.loading,
        limit,
      );
      if (identical(before, coordinator.session) ||
          coordinator.generation <= generation ||
          coordinator.session.generation <= before.generation) {
        throw StateError('NATIVE_OFFLINE_FRESH_COMPLETION_INVALID');
      }
    } finally {
      coordinator.removeListener(observeRecovery);
    }
  }

  /// Nhập một lần, giữ snapshot/epoch trước và sau từng input, không trim password.
  Future<void> login() async {
    final before = coordinator.session;
    final generation = coordinator.generation;
    final deadline = elapsed() + const Duration(seconds: 20);
    ui.guard(deadline);
    await tester.enterText(find.byKey(const ValueKey('auth-email')), email);
    ui.guard(deadline);
    unchanged(before, generation);
    await tester.enterText(
      find.byKey(const ValueKey('auth-password')),
      password,
    );
    ui.guard(deadline);
    unchanged(before, generation);
    await act('auth-submit', AppSessionPhase.submitting, deadline: deadline);
  }

  /// Kiểm hai workspace đúng name/role và identity; UUID được pin lại qua lần refresh.
  /// Input
  /// Param: expected — UUID A/B từ lần picker đầu, null khi chưa pin.
  /// Output: hai UUID khác nhau của rows render từ server snapshot.
  ({String a, String b}) picker([({String a, String b})? expected]) {
    ui.guard();
    final state = coordinator.session;
    final screen = find.byType(WorkspaceSelectionScreen);
    if (coordinator.page != AppAuthPage.workspaces ||
        state.phase != AppSessionPhase.full ||
        state.profile?.email != email ||
        state.failure != null ||
        state.selectedWorkspace != null ||
        !state.workspacesLoaded ||
        state.workspaces.length != 2 ||
        state.nextWorkspaceCursor != null ||
        screen.evaluate().length != 1)
      throw StateError('NATIVE_OFFLINE_PICKER_INVALID');
    final shown = tester.widget<WorkspaceSelectionScreen>(screen).state;
    final byName = {for (final option in shown.options) option.name: option};
    final a = byName['Phòng vận hành A'];
    final b = byName['Nhà kính B'];
    if (shown.phase != WorkspaceSelectionPhase.ready ||
        shown.hasMore ||
        shown.options.length != 2 ||
        a == null ||
        b == null ||
        a.id == b.id ||
        a.role != WorkspaceRole.admin ||
        b.role != WorkspaceRole.user ||
        a.status != WorkspaceStatus.active ||
        b.status != WorkspaceStatus.active ||
        (expected != null && (a.id != expected.a || b.id != expected.b)) ||
        find.byKey(ValueKey('workspace-row-${a.id}')).evaluate().length != 1 ||
        find.byKey(ValueKey('workspace-row-${b.id}')).evaluate().length != 1) {
      throw StateError('NATIVE_OFFLINE_PICKER_INVALID');
    }
    return (a: a.id, b: b.id);
  }

  /// Summary chỉ hợp lệ khi identity/UUID/role và text sản phẩm đều khớp lựa chọn hiện tại.
  /// Input
  /// Param: id — UUID đã pin từ picker.
  /// Param: name — fixed tên workspace dự kiến.
  /// Param: role — server role ADMIN/USER, không suy từ nhãn UI.
  void summary(String id, String name, String role) {
    ui.guard();
    final state = coordinator.session;
    final selected = state.selectedWorkspace;
    if (coordinator.page != AppAuthPage.summary ||
        state.phase != AppSessionPhase.full ||
        state.profile?.email != email ||
        state.failure != null ||
        selected?.id != id ||
        selected?.name != name ||
        selected?.role != role ||
        selected?.isOperational != true ||
        find.byKey(const ValueKey('session-summary')).evaluate().length != 1 ||
        find.text(name).evaluate().length != 1 ||
        find.text(email).evaluate().length != 1 ||
        find
                .text(role == 'ADMIN' ? 'Quản trị viên' : 'Thành viên')
                .evaluate()
                .length !=
            1) {
      throw StateError('NATIVE_OFFLINE_SUMMARY_INVALID');
    }
  }

  signedOut();
  await canary(NativeOfflineRoute.reachable);
  await pause('offline-ready');
  await canary(NativeOfflineRoute.unavailable);
  await login();
  signedOut(failed: true);
  await pause('offline-result');
  await canary(NativeOfflineRoute.reachable);
  final quietState = coordinator.session;
  final quietGeneration = coordinator.generation;
  final quiet = Stopwatch()..start();
  // Stopwatch thực không dùng tester pump để tua30s; kiểm state/epoch liên tục tới joined host ACK.
  while (quiet.elapsed < const Duration(seconds: 30)) {
    unchanged(quietState, quietGeneration);
    signedOut(failed: true);
    await ui.frame(const Duration(milliseconds: 50));
  }
  quiet.stop();
  unchanged(quietState, quietGeneration);
  signedOut(failed: true);
  await pause('offline-quiet');
  signedOut(failed: true);
  await act('auth-recover', AppSessionPhase.checking);
  signedOut();
  await login();
  final choices = picker();
  await pause('offline-picker');
  picker(choices);
  await act('workspace-select-${choices.a}', AppSessionPhase.checking);
  summary(choices.a, 'Phòng vận hành A', 'ADMIN');
  await act('session-back', AppSessionPhase.checking);
  picker(choices);
  await act('workspace-select-${choices.b}', AppSessionPhase.checking);
  summary(choices.b, 'Nhà kính B', 'USER');
  final storedExpiry = (await store.readSession())?.expiresAt;
  if (storedExpiry == null) {
    throw StateError('NATIVE_OFFLINE_SESSION_EXPIRY_MISSING');
  }
  await pause('offline-outbox-ready');
  summary(choices.b, 'Nhà kính B', 'USER');
  await act('session-logout', AppSessionPhase.loggingOut);
  final logoutIntentId = await pendingLogout(expectedExpiry: storedExpiry);
  await pause('offline-outbox-persisted');
  await pendingLogout(
    expectedExpiry: storedExpiry,
    expectedIntentId: logoutIntentId,
  );
}

/** Kiểm logout của phiên Android expired khi offline, lưu intent bền vững rồi giữ toàn bộ UI bị khóa.
 * Input
 * Param: tester — integration engine đã mount App composition thật.
 * Param: packet — token, expiry và email synthetic đã strict validate từ private fixture.
 * Param: elapsed — monotonic clock phase để giữ deadline chung sau no-CA/main.
 * Param: checkpoint — host gate chỉ ACK sau network/HTTP/DB ownership checks.
 * Param: observeUi — stage cùng trạng thái enum/boolean để chẩn đoán lỗi mà không lộ nội dung UI.
 * Errors: StateError cố định khi UI, session store hoặc outbox không giữ đúng phiên expired.
 */
Future<void> verifyNativeOfflineExpiredLogoutScenario(
  WidgetTester tester,
  Map<String, Object?> packet, {
  required Duration Function() elapsed,
  required void Function(String stage, String snapshot) observeUi,
  required Future<void> Function(String stage) checkpoint,
}) async {
  final token = packet['expiredSessionToken'];
  final expiryText = packet['expiredSessionExpiresAt'];
  final expiry = expiryText is String ? DateTime.tryParse(expiryText) : null;
  if (token is! String ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(token) ||
      expiry == null ||
      !expiry.isUtc ||
      expiry.toIso8601String() != expiryText) {
    throw StateError('INVALID_NATIVE_OFFLINE_EXPIRED_PACKET');
  }
  const store = SecureSessionTokenStore();
  final ui = NativeScenarioUi(
    tester,
    elapsed,
    phaseLimit: const Duration(seconds: 675),
    timeoutCode: 'NATIVE_OFFLINE_EXPIRED_TIMEOUT',
  );
  late AppAuthCoordinator coordinator;
  await ui.wait(
    /// Đợi restore của App thật phân loại lỗi kết nối trước khi cho user tạo intent logout.
    () {
      final application = find.byType(AppAuthApplication);
      final applicationCount = application.evaluate().length;
      if (applicationCount != 1) {
        observeUi('WAIT_READY', applicationCount == 0 ? 'MISSING' : 'MULTIPLE');
        return false;
      }
      coordinator = tester.widget<AppAuthApplication>(application).coordinator;
      observeUi(
        'WAIT_READY',
        '${coordinator.page.name}:${coordinator.session.phase.name}:'
            '${coordinator.session.failure?.kind.name ?? 'NONE'}:'
            '${coordinator.logoutPending}:${coordinator.canLogout}',
      );
      return coordinator.page == AppAuthPage.recovery &&
          coordinator.session.phase == AppSessionPhase.offline &&
          coordinator.session.failure?.kind ==
              AppAuthFailureKind.networkUnavailable &&
          !coordinator.logoutPending &&
          coordinator.canLogout;
    },
    const Duration(seconds: 30),
  );
  final stored = await store.readSession();
  if (stored == null ||
      stored.token != token ||
      stored.expiresAt != expiry ||
      await store.readLogoutIntent() != null ||
      find.byType(WorkspaceSelectionScreen).evaluate().isNotEmpty ||
      find.byKey(const ValueKey('session-summary')).evaluate().isNotEmpty) {
    throw StateError('NATIVE_OFFLINE_EXPIRED_SESSION_RESTORE_INVALID');
  }
  // Mốc này phân biệt ACK checkpoint bị chặn với lỗi xảy ra sau khi app quay lại gesture.
  observeUi(
    'READY_CHECKPOINT',
    '${coordinator.page.name}:${coordinator.session.phase.name}:'
        '${coordinator.session.failure?.kind.name ?? 'NONE'}:'
        '${coordinator.logoutPending}:${coordinator.canLogout}',
  );
  await checkpoint('offline-expired-ready');
  observeUi(
    'READY_ACKED',
    '${coordinator.page.name}:${coordinator.session.phase.name}:'
        '${coordinator.session.failure?.kind.name ?? 'NONE'}:'
        '${coordinator.logoutPending}:${coordinator.canLogout}',
  );

  final logout = find.byKey(const ValueKey('recovery-logout'));
  if (logout.evaluate().length != 1) {
    throw StateError('NATIVE_OFFLINE_EXPIRED_LOGOUT_CONTROL_MISSING');
  }
  observeUi(
    'LOGOUT_TAP',
    '${coordinator.page.name}:${coordinator.session.phase.name}:'
        '${coordinator.session.failure?.kind.name ?? 'NONE'}:'
        '${coordinator.logoutPending}:${coordinator.canLogout}',
  );
  await tester.tap(logout);
  await tester.pump();
  observeUi(
    'LOGOUT_TAPPED',
    '${coordinator.page.name}:${coordinator.session.phase.name}:'
        '${coordinator.session.failure?.kind.name ?? 'NONE'}:'
        '${coordinator.logoutPending}:${coordinator.canLogout}',
  );
  await ui.wait(
    /// Logout chỉ qua persisted pending sau write outbox và active-key delete ACK.
    /** Ghi enum/boolean cuối của coordinator để phân biệt gesture, storage và worker timeout mà không lộ payload. */
    () {
      observeUi(
        'WAIT_OUTBOX',
        '${coordinator.page.name}:${coordinator.session.phase.name}:'
            '${coordinator.session.failure?.kind.name ?? 'NONE'}:'
            '${coordinator.logoutPending}:${coordinator.canLogout}',
      );
      return coordinator.page == AppAuthPage.recovery &&
          coordinator.logoutPending;
    },
    const Duration(seconds: 20),
  );
  observeUi(
    'OUTBOX_PENDING',
    '${coordinator.page.name}:${coordinator.session.phase.name}:'
        '${coordinator.session.failure?.kind.name ?? 'NONE'}:'
        '${coordinator.logoutPending}:${coordinator.canLogout}',
  );
  await _assertOfflineLogoutLocked(ui, coordinator, store);
  final intent = await store.readLogoutIntent();
  if (intent == null ||
      intent.sessionToken != token ||
      intent.expiresAt != expiry ||
      await store.readSession() != null) {
    throw StateError('NATIVE_OFFLINE_EXPIRED_OUTBOX_INVALID');
  }
  await checkpoint('offline-expired-persisted');
  await _assertOfflineLogoutLocked(ui, coordinator, store);
}

/** Khôi phục app offline có outbox, giữ màn khóa trước khi host bật mạng và chờ retry terminal của server.
 * Input
 * Param: tester — integration engine đang sở hữu app thật sau process restart.
 * Param: elapsed — đồng hồ monotonic neo lúc host gửi packet, dùng chung cap phase.
 * Param: checkpoint — host gate chỉ ACK sau khi DB/HTTP/network owner đã xác nhận stage.
 * Errors: StateError cố định khi outbox mất, protected UI mở, retry không terminal hoặc cleanup sai.
 */
Future<void> verifyNativeOfflineLogoutResumeScenario(
  WidgetTester tester, {
  required Duration Function() elapsed,
  required Future<void> Function(String stage) checkpoint,
}) async {
  const store = SecureSessionTokenStore();
  final ui = NativeScenarioUi(
    tester,
    elapsed,
    phaseLimit: const Duration(seconds: 675),
    timeoutCode: 'NATIVE_OFFLINE_LOGOUT_RESUME_TIMEOUT',
  );
  late AppAuthCoordinator coordinator;
  await ui.wait(() {
    final application = find.byType(AppAuthApplication);
    if (application.evaluate().length != 1) return false;
    coordinator = tester.widget<AppAuthApplication>(application).coordinator;
    return coordinator.page == AppAuthPage.recovery &&
        coordinator.logoutPending;
  }, const Duration(seconds: 30));
  await _assertOfflineLogoutLocked(ui, coordinator, store);
  await checkpoint('offline-outbox-resumed');

  // Host bật mạng trước ACK checkpoint; retry hợp lệ có thể xóa outbox trước khi callback trả về.
  await ui.wait(
    () => coordinator.page == AppAuthPage.login && !coordinator.logoutPending,
    elapsed() + const Duration(seconds: 90),
  );
  if (await store.readSession() != null ||
      await store.readLogoutIntent() != null ||
      find.byType(WorkspaceSelectionScreen).evaluate().isNotEmpty ||
      find.byKey(const ValueKey('session-summary')).evaluate().isNotEmpty) {
    throw StateError('NATIVE_OFFLINE_LOGOUT_TERMINAL_CLEANUP_INVALID');
  }
  await checkpoint('offline-logged-out');
}

/** Recheck secure state qua startup/pause, không cho identity cũ mở workspace khi intent chờ revoke.
 * Input
 * Param: ui — deadline guard neo cùng native phase, không gia hạn sau mỗi storage read.
 * Param: coordinator — state công khai của composition app hiện tại.
 * Param: store — secure store của app, không đọc bearer ra khỏi adapter.
 * Errors: StateError fixed khi tombstone/session key hoặc protected UI không khớp trạng thái khóa.
 */
Future<void> _assertOfflineLogoutLocked(
  NativeScenarioUi ui,
  AppAuthCoordinator coordinator,
  SecureSessionTokenStore store,
) async {
  ui.guard();
  final intent = await store.readLogoutIntent();
  if (intent == null ||
      intent.sessionToken.isEmpty ||
      intent.expiresAt == null ||
      await store.readSession() != null ||
      !coordinator.logoutPending ||
      coordinator.page != AppAuthPage.recovery ||
      coordinator.session.profile != null ||
      coordinator.session.selectedWorkspace != null ||
      coordinator.session.workspaces.isNotEmpty ||
      find.byType(WorkspaceSelectionScreen).evaluate().isNotEmpty ||
      find.byKey(const ValueKey('session-summary')).evaluate().isNotEmpty) {
    throw StateError('NATIVE_OFFLINE_LOGOUT_RESUME_STATE_INVALID');
  }
}
