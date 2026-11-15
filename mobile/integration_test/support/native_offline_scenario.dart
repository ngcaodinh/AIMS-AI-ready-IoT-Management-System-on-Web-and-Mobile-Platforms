import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexa_iot/features/auth/data/app_auth_failure.dart';
import 'package:nexa_iot/features/auth/data/app_auth_tls_configuration.dart';
import 'package:nexa_iot/features/auth/data/app_session_state.dart';
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

/// Bỏ reference credential kể cả lỗi trước main; không tuyên bố zeroization chuỗi Dart.
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
/// Errors: fixed StateError khi stale epoch, business state, gesture hoặc budget không đạt.
Future<void> verifyNativeOfflineScenario(
  WidgetTester tester,
  Map<String, Object?> packet, {
  required Duration Function() elapsed,
  required Future<void> Function(String stage) checkpoint,
  required void Function(String stage) markStage,
  Future<NativeOfflineRoute> Function() probe = observeNativeOfflineRoute,
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

  /// Pause giữ state/epoch, ACK không tự chứng minh HTTP/SQL và không mở thêm intent.
  /// Input
  /// Param: stage — fixed stage của gate offline.
  Future<void> pause(String stage) async {
    final before = coordinator.session;
    final generation = coordinator.generation;
    ui.guard();
    await checkpoint(stage);
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
  await act('session-logout', AppSessionPhase.loggingOut);
  signedOut();
  await pause('offline-logged-out');
  signedOut();
}
