import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../lib/features/auth/presentation/password_change_screen.dart';
import '../../lib/features/auth/presentation/password_change_state.dart';
import '../../lib/ui/nexa_auth_theme.dart';
import '../../tool/password_change_preview.dart';

/// Host không side effect dùng cho case chỉ kiểm layout/validation, không giả API thành công.
/// Input
/// Param: currentPassword — credential tổng hợp bị bỏ ngay.
/// Param: newPassword — credential tổng hợp không lưu hoặc gửi mạng.
Future<void> ignoreChange(String currentPassword, String newPassword) async {}

/// Callback điều hướng giả không tạo phiên hoặc protected route.
Future<void> ignoreAction() async {}

/// Dựng presentation với theme thật, không cần storage/provider để kiểm hành vi component.
/// Input
/// Param: state — phase đã quyết định bởi test host.
/// Param: onSubmit — callback quan sát intent, mặc định không làm gì.
/// Param: onRecover — đối soát giả riêng, không tự submit lại.
/// Param: onLeave — xác nhận hành vi thoát được user chọn, không logout server.
/// Param: generation — thay key sau host reconciliation; không là session ID.
/// Param: brightness — theme cần kiểm.
/// Param: scale — text scale để kiểm viewport, không metadata native.
/// Param: viewInsets — vùng bàn phím giả của layout test; không dữ liệu native.
/// Output: app harness dùng cùng theme Nexa với login/home.
Widget harness({
  PasswordChangeState state = PasswordChangeState.ready,
  Future<void> Function(String, String) onSubmit = ignoreChange,
  Future<void> Function() onRecover = ignoreAction,
  Future<void> Function() onLeave = ignoreAction,
  int generation = 0,
  Brightness brightness = Brightness.light,
  double scale = 1,
  EdgeInsets viewInsets = EdgeInsets.zero,
}) => MaterialApp(
  theme: nexaAuthTheme(brightness),
  home: MediaQuery(
    data: MediaQueryData(
      textScaler: TextScaler.linear(scale),
      viewInsets: viewInsets,
    ),
    child: PasswordChangeScreen(
      key: ValueKey(generation),
      state: state,
      onSubmit: onSubmit,
      onRecover: onRecover,
      onLeave: onLeave,
    ),
  ),
);

/// Điền credential tổng hợp nguyên chuỗi để kiểm không trim/cắt khi submit.
/// Input
/// Param: tester — runtime widget của case.
/// Param: currentPassword — input hiện tại.
/// Param: newPassword — input mới.
/// Param: confirmation — input xác nhận, null dùng đúng password mới.
Future<void> fillPasswords(
  WidgetTester tester,
  String currentPassword,
  String newPassword, {
  String? confirmation,
}) async {
  await tester.enterText(
    find.byKey(const ValueKey('password-current')),
    currentPassword,
  );
  await tester.enterText(
    find.byKey(const ValueKey('password-new')),
    newPassword,
  );
  await tester.enterText(
    find.byKey(const ValueKey('password-confirm')),
    confirmation ?? newPassword,
  );
}

/// Cuộn thật tới action rồi chờ animation để missed tap không bị bỏ qua.
/// Input
/// Param: tester — runtime widget của case.
/// Param: key — control presentation cần bấm.
Future<void> tapAction(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  // Scroll hữu hạn nhưng progress khi ACK pending là vô hạn; không chờ toàn app settle ở boundary này.
  await tester.pump(const Duration(milliseconds: 350));
  await tester.tap(target);
  await tester.pump();
}

/// Đăng ký các bất biến UI/password; mọi dữ liệu ở đây tổng hợp và không dùng với server.
void main() {
  setUp(
    /// Mọi tap bị che/khuất đều phải fail, không chấp nhận warning thay tương tác thật trong test.
    () {
      final previousPolicy = WidgetController.hitTestWarningShouldBeFatal;
      WidgetController.hitTestWarningShouldBeFatal = true;
      addTearDown(
        /// Khôi phục policy runner sau case, không làm thay đổi test ngoài scope.
        () {
          WidgetController.hitTestWarningShouldBeFatal = previousPolicy;
        },
      );
    },
  );
  testWidgets(
    'validation focuses first error and checks confirmation',

    /// Kiểm lỗi tại field trước khi callback được gọi và không dùng màu làm thông báo duy nhất.
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        harness(
          /// Đếm boundary để chứng minh composition sai không gửi request và9ký tự hợp lệ được nhận.
          onSubmit: (currentPassword, newPassword) async {
            calls++;
          },
        ),
      );
      await tapAction(tester, 'password-submit');
      expect(
        find.text('Nhập mật khẩu hiện tại (1–128 ký tự).'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText).first)
            .focusNode
            .hasFocus,
        isTrue,
      );
      await fillPasswords(
        tester,
        'current-value',
        'New-password9',
        confirmation: 'different',
      );
      await tapAction(tester, 'password-submit');
      expect(find.text('Mật khẩu xác nhận chưa khớp.'), findsOneWidget);
      await fillPasswords(tester, 'Same-password9', 'Same-password9');
      await tapAction(tester, 'password-submit');
      expect(
        find.text('Mật khẩu mới phải khác mật khẩu hiện tại.'),
        findsOneWidget,
      );
      await fillPasswords(tester, 'x', '😀' * 8);
      await tapAction(tester, 'password-submit');
      expect(find.text('Mật khẩu mới cần từ 9 đến 128 ký tự.'), findsOneWidget);
      for (final weak in ['abcdefghi1', 'ABCDEFGHI1', 'Abcdefghij']) {
        await fillPasswords(tester, 'x', weak);
        await tapAction(tester, 'password-submit');
        expect(
          find.text('Mật khẩu mới phải có chữ hoa, chữ thường và số (0–9).'),
          findsOneWidget,
        );
      }
      expect(calls, 0);
      await fillPasswords(tester, 'x', 'Abcdefg12');
      await tapAction(tester, 'password-submit');
      expect(calls, 1);
      await fillPasswords(tester, 'x' * 129, '😀' * 129);
      await tapAction(tester, 'password-submit');
      expect(
        find.text('Nhập mật khẩu hiện tại (1–128 ký tự).'),
        findsOneWidget,
      );
      expect(find.text('Mật khẩu mới cần từ 9 đến 128 ký tự.'), findsOneWidget);
    },
  );
  testWidgets(
    'one intent preserves raw passwords and clears before ACK',

    /// Pending ACK không cho callback lặp hoặc giữ secret trong controller để retry.
    (tester) async {
      final ack = Completer<void>();
      var calls = 0;
      String? receivedCurrent;
      String? receivedNew;
      var clearedAtCallback = true;
      addTearDown(
        /// Kể cả assertion fail vẫn giải phóng ACK tổng hợp, không để task chờ sang case khác.
        () {
          if (!ack.isCompleted) ack.complete();
        },
      );
      await tester.pumpWidget(
        harness(
          /// Quan sát đúng hai giá trị nguyên bản tại boundary, không đưa confirmation sang host.
          onSubmit: (currentPassword, newPassword) async {
            calls++;
            receivedCurrent = currentPassword;
            receivedNew = newPassword;
            for (final field in tester.widgetList<EditableText>(
              find.byType(EditableText),
            )) {
              clearedAtCallback =
                  clearedAtCallback && field.controller.text.isEmpty;
            }
            await ack.future;
          },
        ),
      );
      await fillPasswords(tester, ' current-value ', ' Aa1😀😀😀😀😀😀 ');
      await tapAction(tester, 'password-submit');
      // Assertion nằm ngoài callback để catch unknown của sản phẩm không nuốt chính test failure.
      expect(receivedCurrent, ' current-value ');
      expect(receivedNew, ' Aa1😀😀😀😀😀😀 ');
      expect(clearedAtCallback, isTrue);
      await tapAction(tester, 'password-submit');
      expect(calls, 1);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('password-submit')))
            .onPressed,
        isNull,
      );
      ack.complete();
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'blocked states hide form and success requires explicit leave',

    /// Không có phase nào tự gọi logout/login hoặc cấp workspace từ presentation.
    (tester) async {
      var leaves = 0;
      for (final state in PasswordChangeState.values) {
        await tester.pumpWidget(
          harness(
            state: state,
            generation: state.index,

            /// Chỉ quan sát việc thoát do user chọn, không cấp session.
            onLeave: () async {
              leaves++;
            },
          ),
        );
        await tester.pump();
        expect(
          find.byKey(const ValueKey('password-current')),
          const [
                PasswordChangeState.ready,
                PasswordChangeState.submitting,
                PasswordChangeState.rejected,
                PasswordChangeState.networkUnavailable,
              ].contains(state)
              ? findsOneWidget
              : findsNothing,
        );
        if (state != PasswordChangeState.ready) {
          expect(find.text(state.message), findsOneWidget);
        }
        expect(leaves, 0);
      }
      await tapAction(tester, 'password-leave');
      expect(leaves, 1);
    },
  );
  testWidgets(
    'callback failure stays unknown after recovery and same-key updates',

    /// Host phải tạo generation mới sau reconciliation; ACK recovery riêng không xác nhận mutation cũ.
    (tester) async {
      var calls = 0;
      var recoveries = 0;

      /// Lỗi tổng hợp có detail không được lọt vào UI.
      Future<void> failingSubmit(
        String currentPassword,
        String newPassword,
      ) async {
        calls++;
        throw StateError('private-test-detail');
      }

      /// Đếm đối soát riêng, không đổi outcome của request cũ.
      Future<void> recover() async {
        recoveries++;
      }

      await tester.pumpWidget(
        harness(onSubmit: failingSubmit, onRecover: recover),
      );
      await fillPasswords(tester, 'current-value', 'New-password9');
      await tapAction(tester, 'password-submit');
      await tester.pumpAndSettle();
      expect(find.text('private-test-detail'), findsNothing);
      expect(find.byKey(const ValueKey('password-current')), findsNothing);
      await tapAction(tester, 'password-recover');
      expect(recoveries, 1);
      await tester.pumpWidget(
        harness(onSubmit: failingSubmit, onRecover: recover),
      );
      expect(find.byKey(const ValueKey('password-current')), findsNothing);
      expect(calls, 1);
      await tester.pumpWidget(harness(generation: 1));
      expect(find.byKey(const ValueKey('password-current')), findsOneWidget);
    },
  );
  testWidgets(
    'host transition clears credentials and late ACK is safe',

    /// Không phục hồi password khi host chuyển phase và không setState lên widget đã dispose.
    (tester) async {
      await tester.pumpWidget(harness());
      await tapAction(tester, 'password-submit');
      await fillPasswords(tester, 'current-value', 'New-password9');
      await tester.pumpWidget(harness(state: PasswordChangeState.submitting));
      expect(find.text(PasswordChangeState.submitting.message), findsOneWidget);
      expect(find.text('Kiểm tra các trường được đánh dấu.'), findsNothing);
      for (final field in tester.widgetList<EditableText>(
        find.byType(EditableText),
      )) {
        expect(field.controller.text, isEmpty);
      }
      final ack = Completer<void>();
      await tester.pumpWidget(
        harness(
          generation: 1,

          /// Giữ ACK tới sau dispose để kiểm guard mounted.
          onSubmit: (currentPassword, newPassword) => ack.future,
        ),
      );
      await fillPasswords(tester, 'current-value', 'New-password9');
      await tapAction(tester, 'password-submit');
      await tester.pumpWidget(const SizedBox());
      ack.completeError(StateError('late-private-detail'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'large text form scrolls in both themes and orientations',

    /// Dùng layout test có inset bàn phím; không coi kích thước giả này là native evidence.
    (tester) async {
      for (final size in [const Size(375, 667), const Size(800, 375)]) {
        await tester.binding.setSurfaceSize(size);
        for (final brightness in Brightness.values) {
          await tester.pumpWidget(
            harness(
              brightness: brightness,
              scale: 2,
              viewInsets: const EdgeInsets.only(bottom: 200),
            ),
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const ValueKey('password-submit')),
          );
          await tester.pumpAndSettle();
          final rect = tester.getRect(
            find.byKey(const ValueKey('password-submit')),
          );
          expect(rect.height, greaterThanOrEqualTo(48));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(size.width));
          expect(tester.takeException(), isNull);
        }
      }
      await tester.binding.setSurfaceSize(null);
    },
  );
  testWidgets(
    'keyboard next done and labelled visibility toggles work',

    /// Reveal không đổi chuỗi; IME done đi qua cùng submit guard như nút.
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        harness(
          /// Quan sát submit từ bàn phím, không gọi provider.
          onSubmit: (currentPassword, newPassword) async {
            calls++;
          },
        ),
      );
      await fillPasswords(tester, 'current-value', 'New-password9');
      final reveal = find.byTooltip('Hiện mật khẩu mới');
      await tester.ensureVisible(reveal);
      await tester.pumpAndSettle();
      await tester.tap(reveal);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText).at(1))
            .obscureText,
        isFalse,
      );
      await tester.showKeyboard(find.byKey(const ValueKey('password-current')));
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pump();
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText).at(1))
            .focusNode
            .hasFocus,
        isTrue,
      );
      await tester.showKeyboard(find.byKey(const ValueKey('password-confirm')));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(calls, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'mock preview keeps banner and returns to login only on action',

    /// Kiểm cả harness ở landscape hẹp/chữ2×; không gọi đây là emulator hoặc auth E2E.
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 320);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(const PasswordChangePreview());
      await tester.pumpAndSettle();
      expect(find.text('BẢN THIẾT KẾ — DỮ LIỆU MÔ PHỎNG'), findsOneWidget);
      await tapAction(tester, 'password-submit');
      expect(
        find.text('Nhập mật khẩu hiện tại (1–128 ký tự).'),
        findsOneWidget,
      );
      await fillPasswords(
        tester,
        'synthetic-current',
        'Synthetic-new-password9',
      );
      // Focus của confirmation còn lịch auto-scroll; chờ frame đó xong trước khi cuộn ngược tới reveal của new.
      await tester.pumpAndSettle();
      final reveal = find.byTooltip('Hiện mật khẩu mới');
      await tester.ensureVisible(reveal);
      await tester.pumpAndSettle();
      await tester.tap(reveal);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText).at(1))
            .obscureText,
        isFalse,
      );
      await tapAction(tester, 'password-submit');
      await tester.pumpAndSettle();
      expect(find.text(PasswordChangeState.rejected.message), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('password-preview-state')));
      await tester.pumpAndSettle();
      final success = find.text('Đã đổi mật khẩu');
      await tester.ensureVisible(success);
      await tester.pumpAndSettle();
      await tester.tap(success);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('password-current')), findsNothing);
      await tapAction(tester, 'password-leave');
      await tester.pumpAndSettle();
      expect(find.text('BẢN THIẾT KẾ — DỮ LIỆU MÔ PHỎNG'), findsOneWidget);
      expect(find.byType(PasswordChangeScreen), findsNothing);
      expect(find.byKey(const ValueKey('auth-email')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'short keyboard viewport keeps reveal and action targets reachable',

    /// IME chiếm240dp trong landscape375dp/chữ2× phải còn vùng48dp cho thao tác, không tắt keyboard resize.
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 375);
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(const PasswordChangePreview());
      await tester.pumpAndSettle();
      final scroll = find.byType(SingleChildScrollView).first;
      expect(tester.getSize(scroll).height, greaterThanOrEqualTo(48));
      await fillPasswords(
        tester,
        'synthetic-current',
        'Synthetic-new-password9',
      );
      await tester.pumpAndSettle();
      final reveal = find.byTooltip('Hiện mật khẩu mới');
      await tester.ensureVisible(reveal);
      await tester.pumpAndSettle();
      await tester.tap(reveal);
      await tester.pumpAndSettle();
      await tapAction(tester, 'password-submit');
      await tester.pumpAndSettle();
      expect(find.text(PasswordChangeState.rejected.message), findsOneWidget);
      expect(find.text('BẢN THIẾT KẾ — DỮ LIỆU MÔ PHỎNG'), findsOneWidget);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(find.byType(NexaBrand), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
