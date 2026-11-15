import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../lib/features/auth/presentation/login_screen.dart';
import '../lib/features/auth/presentation/password_change_screen.dart';
import '../lib/features/auth/presentation/password_change_state.dart';
import '../tool/password_change_preview.dart';
import 'support/native_display_profile.dart';

/// Cuộn tới control và xác nhận viewport chứa đủ target, không bỏ qua missed tap.
/// Input
/// Param: tester — engine Android thật của AVD đã guard phía host.
/// Param: key — control bên trong màn password, không tọa độ hoặc dữ liệu auth.
Future<void> tapFormControl(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  final viewport = tester.getRect(find.byType(SingleChildScrollView).first);
  expect(viewport.height, greaterThanOrEqualTo(tester.getSize(target).height));
  await tester.tap(target);
  await tester.pumpAndSettle();
}

/// Chọn scenario có nhãn trong menu mock; không thay network/server state.
/// Input
/// Param: tester — runner preview đang sống.
/// Param: phase — scenario chỉ dùng thiết kế/test.
Future<void> choosePasswordScenario(
  WidgetTester tester,
  PasswordChangeState phase,
) async {
  await tester.tap(find.byKey(const ValueKey('password-preview-state')));
  await tester.pumpAndSettle();
  final item = find.ancestor(
    of: find.text(phase.label).last,
    matching: find.byType(PopupMenuItem<PasswordChangeState>),
  );
  await tester.ensureVisible(item);
  await tester.pumpAndSettle();
  await tester.tap(item);
  await tester.pumpAndSettle();
}

/// Kiểm limited-form intents/navigation mock bằng engine thật; không đổi password account hoặc gọi provider.
/// Input
/// Param: tester — integration runner trên một trong hai AVD lab.
Future<void> exercisePasswordPreview(WidgetTester tester) async {
  WidgetController.hitTestWarningShouldBeFatal = true;
  await tester.pumpWidget(const PasswordChangePreview());
  await tester.pumpAndSettle();
  await waitForDisplayProfile(tester, find.byType(PasswordChangeScreen));
  logDisplayMetrics(tester, find.byType(PasswordChangeScreen), 'start');
  final context = tester.element(find.byType(PasswordChangeScreen));
  final size = MediaQuery.sizeOf(context);
  debugPrint(
    'NATIVE_PREVIEW_VIEW width=${size.width} height=${size.height} text16=${MediaQuery.textScalerOf(context).scale(16)}',
  );
  expect(find.text('BẢN THIẾT KẾ — DỮ LIỆU MÔ PHỎNG'), findsOneWidget);
  await tapFormControl(tester, 'password-submit');
  expect(find.text('Nhập mật khẩu hiện tại (1–128 ký tự).'), findsOneWidget);
  await tester.enterText(
    find.byKey(const ValueKey('password-current')),
    'synthetic-current',
  );
  await tester.enterText(
    find.byKey(const ValueKey('password-new')),
    'Abcdefg12',
  );
  await tester.enterText(
    find.byKey(const ValueKey('password-confirm')),
    'Abcdefg12',
  );
  // Hoàn tất auto-scroll từ focus confirmation trước khi cuộn ngược tới suffix của field new.
  await tester.pumpAndSettle();
  final reveal = find.byTooltip('Hiện mật khẩu mới');
  await tester.ensureVisible(reveal);
  await tester.pumpAndSettle();
  // Chỉ ghi tọa độ/focus để phân biệt delayed focus-scroll với target bị clip; không đọc/log input.
  debugPrint(
    'PASSWORD_REVEAL_TARGET rect=${tester.getRect(reveal)} viewport=${tester.getRect(find.byType(SingleChildScrollView).first)} newField=${tester.getRect(find.byKey(const ValueKey('password-new')))} keyboard=${MediaQuery.viewInsetsOf(context)} scaffold=${tester.getRect(find.byType(Scaffold).first)}',
  );
  await tester.tap(reveal);
  await tester.pumpAndSettle();
  expect(
    tester.widget<EditableText>(find.byType(EditableText).at(1)).obscureText,
    isFalse,
  );
  await tapFormControl(tester, 'password-submit');
  expect(find.text(PasswordChangeState.rejected.message), findsOneWidget);
  for (final field in tester.widgetList<EditableText>(
    find.byType(EditableText),
  )) {
    expect(field.controller.text, isEmpty);
  }
  await choosePasswordScenario(tester, PasswordChangeState.pending);
  expect(find.byKey(const ValueKey('password-current')), findsNothing);
  await tapFormControl(tester, 'password-recover');
  expect(find.byKey(const ValueKey('password-current')), findsOneWidget);
  await tester.tap(find.byTooltip('Đổi giao diện sáng tối'));
  await tester.pumpAndSettle();
  expect(
    Theme.of(tester.element(find.byType(PasswordChangeScreen))).brightness,
    Brightness.dark,
  );
  await choosePasswordScenario(tester, PasswordChangeState.success);
  expect(find.byKey(const ValueKey('password-current')), findsNothing);
  await tapFormControl(tester, 'password-leave');
  expect(find.byType(LoginScreen), findsOneWidget);
  expect(find.text('BẢN THIẾT KẾ — DỮ LIỆU MÔ PHỎNG'), findsOneWidget);
  logDisplayMetrics(tester, find.byType(LoginScreen), 'end');
}

/// Đăng ký native mock UI case, không dùng làm AT-WF-004 hoặc auth-provider acceptance.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'labelled password preview validates recovers and returns to login',
    exercisePasswordPreview,
  );
}
