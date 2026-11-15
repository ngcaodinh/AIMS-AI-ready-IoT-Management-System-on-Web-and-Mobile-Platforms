import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../lib/features/auth/presentation/login_screen.dart';
import '../lib/features/auth/presentation/login_view_state.dart';
import '../tool/auth_preview.dart';
import 'support/native_display_profile.dart';

/// Tương tác UI thật trên Android engine, nhưng boundary submit/recovery vẫn là preview giả đã gắn nhãn.
/// Input
/// Param: tester — runner emulator, không gọi auth backend hoặc lưu token.
Future<void> exercisePreview(WidgetTester tester) async {
  // Pointer bỏ lỡ target phải làm test thất bại, không chấp nhận flow xanh kèm cảnh báo tap.
  WidgetController.hitTestWarningShouldBeFatal = true;
  await tester.pumpWidget(const AuthPreview());
  await tester.pumpAndSettle();
  await waitForDisplayProfile(tester, find.byType(LoginScreen));
  expect(find.text('BẢN THIẾT KẾ — DỮ LIỆU MÔ PHỎNG'), findsOneWidget);
  logDisplayMetrics(tester, find.byType(LoginScreen), 'start');
  // Chỉ ghi kích thước/text scale của emulator để host xác minh display profile thật, không log input.
  final screenContext = tester.element(find.byType(LoginScreen));
  final window = MediaQuery.sizeOf(screenContext);
  final scaledText = MediaQuery.textScalerOf(screenContext).scale(16);
  debugPrint(
    'NATIVE_PREVIEW_VIEW width=${window.width} height=${window.height} text16=$scaledText',
  );
  final submit = find.byKey(const ValueKey('auth-submit'));
  await tester.ensureVisible(submit);
  // Source form có transition/scroll; chỉ lấy tọa độ khi layout đã ổn định, không tắt animation để làm test xanh.
  await tester.pumpAndSettle();
  final viewport = tester.getRect(find.byType(SingleChildScrollView).first);
  final button = tester.getRect(submit);
  expect(
    viewport.height >= button.height,
    isTrue,
    reason: 'Form viewport must fit the complete CTA',
  );
  await tester.tap(submit);
  await tester.pumpAndSettle();
  expect(find.text('Nhập địa chỉ email hợp lệ.'), findsOneWidget);
  await tester.enterText(
    find.byKey(const ValueKey('auth-email')),
    'preview@example.invalid',
  );
  await tester.enterText(
    find.byKey(const ValueKey('auth-password')),
    'Abcdefg12',
  );
  // Chờ auto-scroll từ focus input kết thúc trước khi cuộn tới reveal; tránh focus-scroll ghi đè vị trí vừa cuộn.
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byTooltip('Hiện mật khẩu'));
  await tester.pumpAndSettle();
  // Chỉ ghi hình học để phân biệt auto-scroll tới trễ với viewport quá thấp; không ghi input credential.
  debugPrint(
    'LOGIN_REVEAL_GEOMETRY target=${tester.getRect(find.byTooltip('Hiện mật khẩu'))} viewport=${tester.getRect(find.byType(SingleChildScrollView).first)} inset=${MediaQuery.viewInsetsOf(tester.element(find.byType(LoginScreen)))}',
  );
  await tester.tap(find.byTooltip('Hiện mật khẩu'));
  // Reveal đổi focus/selection và có thể gây auto-scroll; chờ xong trước khi tìm vị trí nút gửi.
  await tester.pumpAndSettle();
  expect(
    tester.widgetList<EditableText>(find.byType(EditableText)).last.obscureText,
    isFalse,
  );
  await tester.ensureVisible(submit);
  await tester.pumpAndSettle();
  await tester.tap(submit);
  await tester.pumpAndSettle();
  expect(find.text(LoginViewState.rejected.message), findsOneWidget);
  final password = tester.widget<TextFormField>(
    find.byKey(const ValueKey('auth-password')),
  );
  expect(password.controller!.text.isEmpty, isTrue);

  await tester.tap(find.byTooltip('Dùng giao diện tối'));
  await tester.pumpAndSettle();
  expect(
    Theme.of(tester.element(find.byType(LoginScreen))).brightness,
    Brightness.dark,
  );
  await tester.tap(find.byKey(const ValueKey('preview-state')));
  await tester.pumpAndSettle();
  // Chạm hàng menu có semantics/tap target; tâm đoạn chữ có thể nằm ngoài phần hit-test khi cuộn.
  final pending = find.ancestor(
    of: find.text(LoginViewState.pending.label).last,
    matching: find.byType(CheckedPopupMenuItem<LoginViewState>),
  );
  await tester.ensureVisible(pending);
  await tester.pumpAndSettle();
  await tester.tap(pending);
  await tester.pumpAndSettle();
  expect(find.text(LoginViewState.pending.message), findsOneWidget);
  expect(tester.widget<FilledButton>(submit).onPressed, isNull);
  await tester.ensureVisible(find.byKey(const ValueKey('auth-recover')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('auth-recover')));
  await tester.pumpAndSettle();
  expect(find.text(LoginViewState.pending.message), findsNothing);
  expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
  expect(
    tester
        .widget<TextFormField>(find.byKey(const ValueKey('auth-email')))
        .controller!
        .text
        .isEmpty,
    isTrue,
  );
  expect(find.text('BẢN THIẾT KẾ — DỮ LIỆU MÔ PHỎNG'), findsOneWidget);
  logDisplayMetrics(tester, find.byType(LoginScreen), 'end');
}

/// Đăng ký ca UI mock trên emulator, không gọi đây là AT-WF hoặc provider E2E đã nghiệm thu.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'labelled preview validates submits recovers and changes theme',
    exercisePreview,
  );
}
