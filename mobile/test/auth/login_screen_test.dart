import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../lib/features/auth/presentation/login_screen.dart';
import '../../lib/features/auth/presentation/login_view_state.dart';
import '../../lib/ui/nexa_auth_theme.dart';
import '../../tool/auth_preview.dart';

/// Boundary giả của widget test, không gửi network hoặc giữ password được nhập.
final class LoginProbe {
  int calls = 0;
  int recoveryCalls = 0;
  bool passwordPreserved = false;
  String expectedPassword = '  synthetic-01  ';
  Completer<void>? gate;
  bool throwOnSubmit = false;

  /// Đếm intent và so sánh boolean để assertion không log credential.
  /// Input
  /// Param: email — email tổng hợp của test, không là account có thể đăng nhập.
  /// Param: password — password tổng hợp, không ghi vào field hoặc log.
  Future<void> submit(String email, String password) async {
    calls++;
    passwordPreserved = password == expectedPassword;
    if (throwOnSubmit)
      throw StateError('synthetic-private-error-do-not-display');
    await gate?.future;
  }

  /// Đếm yêu cầu đối soát riêng, không tự gửi lại intent login.
  Future<void> recover() async {
    recoveryCalls++;
  }
}

/// Dựng component với theme Nexa và state điều khiển; chưa có API/secure storage.
/// Input
/// Param: tester — runner widget để kiểm interaction/layout.
/// Param: probe — boundary giả chỉ giữ outcome tổng hợp.
/// Param: state — trạng thái presentation do host cấp, không chứng minh session thật.
/// Param: brightness — theme được kiểm độc lập.
/// Param: textScale — mô phỏng cỡ chữ Android, không đổi system setting.
/// Param: keyboardInset — vùng IME mô phỏng theo logical pixels.
/// Param: reducedMotion — tùy chọn giảm chuyển động của người dùng.
Future<void> pumpLogin(
  WidgetTester tester,
  LoginProbe probe, {
  LoginViewState state = LoginViewState.ready,
  Brightness brightness = Brightness.light,
  double textScale = 1,
  double keyboardInset = 0,
  bool reducedMotion = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: nexaAuthTheme(brightness),
      home: MediaQuery(
        data: MediaQueryData.fromView(tester.view).copyWith(
          textScaler: TextScaler.linear(textScale),
          viewInsets: EdgeInsets.only(bottom: keyboardInset),
          disableAnimations: reducedMotion,
        ),
        child: LoginScreen(
          state: state,
          onSubmit: probe.submit,
          onRecover: probe.recover,
        ),
      ),
    ),
  );
}

/// Unknown/offline/storage/permission states không gửi login, recovery luôn là intent riêng.
/// Input
/// Param: tester — runner component, không provider hoặc session thật.
Future<void> checkStateMatrix(WidgetTester tester) async {
  final probe = LoginProbe();
  for (final state in [
    LoginViewState.networkUnavailable,
    LoginViewState.storageFailure,
    LoginViewState.pending,
    LoginViewState.conflict,
    LoginViewState.permissionDenied,
  ]) {
    await pumpLogin(tester, probe, state: state);
    expect(find.text(state.message), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('auth-submit')))
          .onPressed,
      isNull,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('auth-recover')));
    await tester.tap(find.byKey(const ValueKey('auth-recover')));
    await tester.pumpAndSettle();
  }
  expect(probe.recoveryCalls, 5);
  expect(probe.calls, 0);
  await pumpLogin(tester, probe, state: LoginViewState.confirmed);
  expect(find.text(LoginViewState.confirmed.message), findsOneWidget);
  expect(find.byKey(const ValueKey('auth-recover')), findsNothing);
}

/// Exception chưa map không lộ detail và không cho retry mutation trước reconciliation/generation mới.
/// Input
/// Param: tester — runner với callback cố ý ném lỗi tổng hợp.
Future<void> checkUnknownCallback(WidgetTester tester) async {
  final probe = LoginProbe()..throwOnSubmit = true;
  await pumpLogin(tester, probe);
  await tester.enterText(
    find.byKey(const ValueKey('auth-email')),
    'preview@example.invalid',
  );
  await tester.enterText(
    find.byKey(const ValueKey('auth-password')),
    probe.expectedPassword,
  );
  await tapSubmit(tester);
  await tester.pumpAndSettle();
  expect(find.text(LoginViewState.pending.message), findsOneWidget);
  expect(find.textContaining('synthetic-private-error'), findsNothing);
  expect(
    tester
        .widget<FilledButton>(find.byKey(const ValueKey('auth-submit')))
        .onPressed,
    isNull,
  );
  await tester.ensureVisible(find.byKey(const ValueKey('auth-recover')));
  await tester.tap(find.byKey(const ValueKey('auth-recover')));
  await tester.pumpAndSettle();
  expect(probe.calls, 1);
  expect(probe.recoveryCalls, 1);
  expect(
    tester
        .widget<FilledButton>(find.byKey(const ValueKey('auth-submit')))
        .onPressed,
    isNull,
  );
}

/// Kiểm cuộn/chữ lớn/IME và landscape ở cả theme, không suy screenshot là luồng nghiệp vụ PASS.
/// Input
/// Param: tester — view mô phỏng có thể đổi kích thước và text scale.
Future<void> checkResponsiveLayout(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  for (final brightness in Brightness.values) {
    for (final size in [const Size(375, 667), const Size(800, 375)]) {
      tester.view.physicalSize = size;
      await pumpLogin(
        tester,
        LoginProbe(),
        brightness: brightness,
        textScale: 2,
        keyboardInset: size.width == 375 ? 240 : 0,
        state: LoginViewState.rejected,
      );
      await tester.ensureVisible(find.byKey(const ValueKey('auth-submit')));
      await tester.pump();
      final target = tester.getSize(find.byKey(const ValueKey('auth-submit')));
      expect(target.width >= 48 && target.height >= 48, isTrue);
      expect(tester.takeException(), isNull);
    }
  }
  await pumpLogin(
    tester,
    LoginProbe(),
    state: LoginViewState.submitting,
    reducedMotion: true,
  );
  expect(find.byType(CircularProgressIndicator), findsNothing);
  expect(
    tester
        .widget<FilledButton>(find.byKey(const ValueKey('auth-submit')))
        .onPressed,
    isNull,
  );
}

/// Next/done và reveal dùng đúng một intent, semantics của control có nhãn dùng được.
/// Input
/// Param: tester — runner có IME test; chưa thay kiểm Android keyboard/TalkBack thật.
Future<void> checkKeyboardAndReveal(WidgetTester tester) async {
  final semantics = tester.ensureSemantics();
  try {
    final probe = LoginProbe();
    await pumpLogin(tester, probe);
    await tester.enterText(
      find.byKey(const ValueKey('auth-email')),
      'preview@example.invalid',
    );
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();
    expect(
      tester
          .widgetList<EditableText>(find.byType(EditableText))
          .last
          .focusNode
          .hasFocus,
      isTrue,
    );
    await tester.enterText(
      find.byKey(const ValueKey('auth-password')),
      probe.expectedPassword,
    );
    await tester.ensureVisible(find.byTooltip('Hiện mật khẩu'));
    await tester.tap(find.byTooltip('Hiện mật khẩu'));
    await tester.pump();
    expect(
      tester
          .widgetList<EditableText>(find.byType(EditableText))
          .last
          .obscureText,
      isFalse,
    );
    expect(find.byTooltip('Ẩn mật khẩu'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Email')), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('auth-password')));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(probe.calls, 1);
  } finally {
    // Binding kiểm handles trước addTearDown; phải dispose ngay trong body dù assertion thất bại.
    semantics.dispose();
  }
}

/// Bấm CTA sau khi cuộn tới nó, không giả định form luôn vừa chiều cao khi bàn phím mở.
/// Input
/// Param: tester — runner chứa LoginScreen.
Future<void> tapSubmit(WidgetTester tester) async {
  final button = find.byKey(const ValueKey('auth-submit'));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pump();
}

/// Empty/sai email và password ngắn không gọi boundary; Unicode đếm codepoint thay UTF16 units.
/// Input
/// Param: tester — runner form, chỉ dùng dữ liệu tổng hợp.
Future<void> checkValidation(WidgetTester tester) async {
  final probe = LoginProbe();
  await pumpLogin(tester, probe);
  await tapSubmit(tester);
  expect(probe.calls, 0);
  expect(find.text('Nhập địa chỉ email hợp lệ.'), findsOneWidget);
  expect(find.text('Mật khẩu cần từ 9 đến 128 ký tự.'), findsOneWidget);
  await tester.enterText(
    find.byKey(const ValueKey('auth-email')),
    'preview@example.invalid',
  );
  await tester.enterText(find.byKey(const ValueKey('auth-password')), '🧪' * 6);
  await tapSubmit(tester);
  expect(probe.calls, 0);
  probe.expectedPassword = '🧪' * 9;
  await tester.enterText(
    find.byKey(const ValueKey('auth-password')),
    probe.expectedPassword,
  );
  await tapSubmit(tester);
  await tester.pumpAndSettle();
  expect(probe.calls, 1);
  expect(probe.passwordPreserved, isTrue);
}

/// Gửi password nguyên chuỗi một lần, xóa controller ngay và giữ CTA khóa tới khi callback xong.
/// Input
/// Param: tester — runner form với boundary ACK bị trì hoãn có kiểm soát.
Future<void> checkSubmissionFence(WidgetTester tester) async {
  final probe = LoginProbe()..gate = Completer<void>();
  await pumpLogin(tester, probe);
  await tester.enterText(
    find.byKey(const ValueKey('auth-email')),
    'preview@example.invalid',
  );
  await tester.enterText(
    find.byKey(const ValueKey('auth-password')),
    probe.expectedPassword,
  );
  await tapSubmit(tester);
  expect(probe.calls, 1);
  expect(probe.passwordPreserved, isTrue);
  final password = tester.widget<TextFormField>(
    find.byKey(const ValueKey('auth-password')),
  );
  expect(password.controller!.text.isEmpty, isTrue);
  final button = tester.widget<FilledButton>(
    find.byKey(const ValueKey('auth-submit')),
  );
  expect(button.onPressed, isNull);
  probe.gate!.complete();
  await tester.pumpAndSettle();
  expect(probe.calls, 1);
}

/// Đăng ký invariant form; không dùng widget test làm bằng chứng auth provider hoặc Android device.
void main() {
  testWidgets(
    'short keyboard viewport keeps login controls reachable',
    checkShortKeyboardViewport,
  );
  testWidgets(
    'preview controls leave a usable viewport with large text',
    checkPreviewViewport,
  );
  testWidgets(
    'late callbacks cannot dispatch after state changed',
    checkLateCallbacks,
  );
  testWidgets(
    'validates empty fields and Unicode password length',
    checkValidation,
  );
  testWidgets(
    'one intent preserves password and clears it before ACK',
    checkSubmissionFence,
  );
  testWidgets('blocked states only expose separate recovery', checkStateMatrix);
  testWidgets(
    'callback exception stays unknown without leaking details',
    checkUnknownCallback,
  );
  testWidgets(
    'large text keyboard and landscape fit both themes',
    checkResponsiveLayout,
  );
  testWidgets(
    'keyboard next done and labelled reveal work',
    checkKeyboardAndReveal,
  );
}

/// Tái hiện host banner và IME chiếm phần lớn landscape; target phải còn chỗ mà không giảm chữ hoặc tắt resize.
/// Input
/// Param: tester — widget runner mô phỏng inset, native profiles vẫn phải được kiểm riêng.
Future<void> checkShortKeyboardViewport(WidgetTester tester) async {
  final previousHitTestPolicy = WidgetController.hitTestWarningShouldBeFatal;
  WidgetController.hitTestWarningShouldBeFatal = true;
  addTearDown(
    /// Khôi phục strict tap policy của runner sau case, không ảnh hưởng suite khác.
    () {
      WidgetController.hitTestWarningShouldBeFatal = previousHitTestPolicy;
    },
  );
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 375);
  tester.view.viewInsets = const FakeViewPadding(bottom: 240);
  tester.platformDispatcher.textScaleFactorTestValue = 2;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetViewInsets);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(const AuthPreview());
  await tester.pumpAndSettle();
  expect(
    tester.getSize(find.byType(SingleChildScrollView).first).height,
    // Viewport phải còn ít nhất target48dp; CTA chữ lớn vẫn giữ chiều cao tự nhiên và được kiểm bằng tap thật bên dưới.
    greaterThanOrEqualTo(48),
  );
  final reveal = find.byTooltip('Hiện mật khẩu');
  await tester.ensureVisible(reveal);
  await tester.pumpAndSettle();
  await tester.tap(reveal);
  await tester.pumpAndSettle();
  final submit = find.byKey(const ValueKey('auth-submit'));
  await tester.ensureVisible(submit);
  await tester.pumpAndSettle();
  await tester.tap(submit);
  await tester.pumpAndSettle();
  expect(find.text('Nhập địa chỉ email hợp lệ.'), findsOneWidget);
  expect(find.text('BẢN THIẾT KẾ — DỮ LIỆU MÔ PHỎNG'), findsOneWidget);
  tester.view.resetViewInsets();
  await tester.pumpAndSettle();
  expect(find.byType(NexaBrand), findsOneWidget);
  expect(tester.takeException(), isNull);
}

/// Kiểm toàn harness thay vì riêng form, vì control thiết kế cũng có thể che CTA khi xoay/chữ lớn.
/// Input
/// Param: tester — view mô phỏng, giữ nguyên200% text scale thay vì hạ accessibility để test xanh.
Future<void> checkPreviewViewport(WidgetTester tester) async {
  final previousHitTestPolicy = WidgetController.hitTestWarningShouldBeFatal;
  WidgetController.hitTestWarningShouldBeFatal = true;
  addTearDown(
    /// Không để policy chạm của ca preview làm thay đổi các suite khác.
    () {
      WidgetController.hitTestWarningShouldBeFatal = previousHitTestPolicy;
    },
  );
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 320);
  tester.platformDispatcher.textScaleFactorTestValue = 2;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(const AuthPreview());
  await tester.pumpAndSettle();
  final submit = find.byKey(const ValueKey('auth-submit'));
  await tester.ensureVisible(submit);
  await tester.pump();
  final viewport = tester.getSize(find.byType(SingleChildScrollView).first);
  final target = tester.getSize(submit);
  final scenarioTarget = tester.getSize(
    find.byKey(const ValueKey('preview-state')),
  );
  expect(scenarioTarget.width >= 48 && scenarioTarget.height >= 48, isTrue);
  expect(
    viewport.height >= target.height,
    isTrue,
    reason: 'Preview controls must not consume the entire form viewport',
  );
  expect(find.text('BẢN THIẾT KẾ — DỮ LIỆU MÔ PHỎNG'), findsOneWidget);
  await tester.tap(find.byKey(const ValueKey('preview-state')));
  await tester.pumpAndSettle();
  final pending = find.ancestor(
    of: find.text(LoginViewState.pending.label).last,
    matching: find.byType(CheckedPopupMenuItem<LoginViewState>),
  );
  await tester.ensureVisible(pending);
  await tester.pumpAndSettle();
  await tester.tap(pending);
  await tester.pumpAndSettle();
  expect(find.text(LoginViewState.pending.message), findsOneWidget);
  expect(tester.takeException(), isNull);
}

/// Callback control cũ phải kiểm state hiện hành lần nữa, không chỉ dựa button đã render từ frame trước.
/// Input
/// Param: tester — runner giữ callback cũ để mô phỏng event đến sau transition.
Future<void> checkLateCallbacks(WidgetTester tester) async {
  final probe = LoginProbe();
  await pumpLogin(tester, probe);
  final submit = tester
      .widget<FilledButton>(find.byKey(const ValueKey('auth-submit')))
      .onPressed!;
  await pumpLogin(tester, probe, state: LoginViewState.pending);
  submit();
  await tester.pump();
  expect(probe.calls, 0);
  final recover = tester
      .widget<OutlinedButton>(find.byKey(const ValueKey('auth-recover')))
      .onPressed!;
  await pumpLogin(tester, probe, state: LoginViewState.submitting);
  recover();
  await tester.pump();
  expect(probe.recoveryCalls, 0);
}
