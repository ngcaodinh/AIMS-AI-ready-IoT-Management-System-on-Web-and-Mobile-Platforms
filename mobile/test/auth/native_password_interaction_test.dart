import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/app_auth_e2e_test.dart' as native;
import 'password_change_screen_test.dart' as presentation;

/** Kiểm helper native trên component thật bằng input tổng hợp, không SDK device/API/storage/fixture DB. */
void main() {
  testWidgets(
    'native password helpers establish fresh local validation errors',
    /**
     * Tái hiện cùng chuỗi short→complexity→confirm bằng helper đang dùng trên Android để phân biệt harness/UI.
     * Input
     * Param: tester — host widget engine với viewport/IME giả; không thay native runtime evidence.
     */
    (tester) async {
      tester.view.physicalSize = const Size(411, 891);
      tester.view.devicePixelRatio = 1;
      final previousPolicy = WidgetController.hitTestWarningShouldBeFatal;
      WidgetController.hitTestWarningShouldBeFatal = true;
      addTearDown(
        /** Trả viewport/pointer policy về giá trị ban đầu để không ảnh hưởng test khác. */
        () {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          WidgetController.hitTestWarningShouldBeFatal = previousPolicy;
        },
      );
      var calls = 0;
      await tester.pumpWidget(
        presentation.harness(
          viewInsets: const EdgeInsets.only(bottom: 300),
          onSubmit:
              /**
           * Chỉ đếm intent; mọi input đều synthetic và phải bị chặn trước boundary trong ca này.
           * Input
           * Param: current — input tổng hợp không giữ hoặc in.
           * Param: next — input tổng hợp không gửi API hoặc lưu.
           */
              (current, next) async {
                calls++;
              },
        ),
      );
      const lengthMessage = 'Mật khẩu mới cần từ 9 đến 128 ký tự.';
      for (final scenario in [
        ('Aa1aaaaa', 'Aa1aaaaa', lengthMessage),
        (
          'aa1aaaaaaaa',
          'aa1aaaaaaaa',
          'Mật khẩu mới phải có chữ hoa, chữ thường và số (0–9).',
        ),
        (
          'AA1AAAAAAAA',
          'AA1AAAAAAAA',
          'Mật khẩu mới phải có chữ hoa, chữ thường và số (0–9).',
        ),
        (
          'Aaaaaaaaaaa',
          'Aaaaaaaaaaa',
          'Mật khẩu mới phải có chữ hoa, chữ thường và số (0–9).',
        ),
        ('New-password9', 'Other-password9', 'Mật khẩu xác nhận chưa khớp.'),
      ]) {
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        if (scenario.$3 != lengthMessage) {
          await native.fillNativePasswordForm(
            tester,
            'Existing-pass9',
            'Aa1aaaaa',
            'Aa1aaaaa',
            deadline,
          );
          await native.tapNative(tester, 'password-submit', deadline: deadline);
          await native.waitForNative(
            tester,
            find.text(lengthMessage),
            deadline: deadline,
          );
        }
        await native.fillNativePasswordForm(
          tester,
          'Existing-pass9',
          scenario.$1,
          scenario.$2,
          deadline,
        );
        expect(find.text(scenario.$3), findsNothing);
        if (scenario.$3 != lengthMessage)
          expect(find.text(lengthMessage), findsOneWidget);
        await native.tapNative(tester, 'password-submit', deadline: deadline);
        await native.waitForNative(
          tester,
          find.text(scenario.$3),
          deadline: deadline,
        );
        if (scenario.$3 != lengthMessage)
          expect(find.text(lengthMessage), findsNothing);
        expect(calls, 0);
      }
    },
  );

  testWidgets(
    'native submit remains reachable when a competing scroll moves it',
    /**
     * Mô phỏng một lần cuộn cạnh tranh sau khi nút đã hiện để kiểm tap thật vẫn tới form.
     * Input
     * Param: tester — widget engine với màn hẹp và bàn phím giả, không chứng minh nguồn cuộn trên thiết bị.
     */
    (tester) async {
      tester.view.physicalSize = const Size(411, 891);
      tester.view.devicePixelRatio = 1;
      final previousPolicy = WidgetController.hitTestWarningShouldBeFatal;
      WidgetController.hitTestWarningShouldBeFatal = true;
      addTearDown(
        /** Trả viewport và policy để ca khác không bị ảnh hưởng. */
        () {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          WidgetController.hitTestWarningShouldBeFatal = previousPolicy;
        },
      );
      var calls = 0;
      await tester.pumpWidget(
        presentation.harness(
          viewInsets: const EdgeInsets.only(bottom: 300),
          onSubmit:
              /**
               * Phát hiện mutation không mong đợi; input không hợp lệ phải bị chặn ở form.
               * Input
               * Param: current — mật khẩu tổng hợp, không gửi hoặc lưu.
               * Param: next — giá trị tổng hợp không hợp lệ.
               */
              (current, next) async {
                calls++;
              },
        ),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      await native.fillNativePasswordForm(
        tester,
        'Existing-pass9',
        'Aa1aaaaa',
        'Aa1aaaaa',
        deadline,
      );
      final submit = find.byKey(const ValueKey('password-submit'));
      await tester.ensureVisible(submit);
      await tester.pump();
      expect(submit.hitTestable(), findsOneWidget);
      final scroll = Scrollable.of(tester.element(submit)).position;
      expect(scroll.pixels, greaterThan(scroll.minScrollExtent));
      // Cuộn sau khi đã kiểm vị trí ban đầu để mô phỏng focus/IME đổi vị trí trước tap, không giả lập Android.
      final competingScroll = Timer(
        const Duration(milliseconds: 100),
        /** Di chuyển viewport bằng scroll thật để tái hiện xung đột vị trí trong ca tổng hợp. */
        () {
          scroll.jumpTo(scroll.minScrollExtent);
        },
      );
      addTearDown(
        /** Hủy timer nếu ca kết thúc sớm để không tác động widget đã dispose. */
        competingScroll.cancel,
      );
      await native.tapNative(tester, 'password-submit', deadline: deadline);
      await native.waitForNative(
        tester,
        find.text('Mật khẩu mới cần từ 9 đến 128 ký tự.'),
        deadline: deadline,
      );
      expect(calls, 0);
    },
  );

  testWidgets(
    'native submit fails at its deadline when pointer is blocked',
    /**
     * Giữ nút thật bị chặn pointer để kiểm retry hữu hạn và không gọi callback ngoài ý muốn.
     * Input
     * Param: tester — widget engine với form tổng hợp, không API hoặc dữ liệu thiết bị.
     */
    (tester) async {
      final previousPolicy = WidgetController.hitTestWarningShouldBeFatal;
      WidgetController.hitTestWarningShouldBeFatal = true;
      addTearDown(
        /** Trả policy ban đầu để ca khác không bị ảnh hưởng. */
        () {
          WidgetController.hitTestWarningShouldBeFatal = previousPolicy;
        },
      );
      var calls = 0;
      await tester.pumpWidget(
        AbsorbPointer(
          child: presentation.harness(
            onSubmit:
                /**
                 * Đếm callback để chứng minh nút bị chặn không phát mutation.
                 * Input
                 * Param: current — giá trị tổng hợp, không lưu hoặc gửi mạng.
                 * Param: next — giá trị tổng hợp, không lưu hoặc gửi mạng.
                 */
                (current, next) async {
                  calls++;
                },
          ),
        ),
      );
      final submit = find.byKey(const ValueKey('password-submit'));
      expect(submit, findsOneWidget);
      expect(submit.hitTestable(), findsNothing);
      // Deadline chung ngắn buộc retry dừng khi pointer vẫn bị chặn, không dùng elapsed-time làm oracle.
      final deadline = DateTime.now().add(const Duration(seconds: 1));
      await expectLater(
        native.tapNative(tester, 'password-submit', deadline: deadline),
        throwsA(
          isA<StateError>().having(
            /** Kiểm đúng lỗi cố định, không đối chiếu exception chứa dữ liệu form. */
            (error) => error.message,
            'message',
            'NATIVE_UI_STATE_TIMEOUT',
          ),
        ),
      );
      expect(calls, 0);
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );
}
