import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Đây là cấu hình biên dịch của riêng test, không đọc biến môi trường process hoặc dữ liệu auth.
const displayProfile = String.fromEnvironment(
  'NEXA_PREVIEW_DISPLAY_PROFILE',
  defaultValue: 'current',
);

/// Chờ host thiết lập display sau app-start; chỉ tiếp tục khi engine thực khớp profile đã yêu cầu.
/// Input
/// Param: tester — runner native, không override MediaQuery hoặc surface để làm xanh profile.
/// Param: screen — root component đang sống cần đối chiếu MediaQuery/native view.
/// Errors: sai profile hoặc không nhận metrics đúng trong20s thì fail trước mọi tương tác UI.
Future<void> waitForDisplayProfile(WidgetTester tester, Finder screen) async {
  if (displayProfile == 'current') return;
  expect(
    displayProfile,
    anyOf('portrait', 'landscape-large-text'),
    reason: 'Unsupported native display test profile',
  );
  debugPrint('NATIVE_PREVIEW_READY profile=$displayProfile');
  final elapsed = Stopwatch()..start();
  var matchingFrames = 0;
  // Deadline đo thời gian thực; pumpAndSettle đơn lẻ không chứng minh host đã đổi policy/metrics.
  while (elapsed.elapsed < const Duration(seconds: 20)) {
    await tester.pump(const Duration(milliseconds: 100));
    final context = tester.element(screen);
    final logical = MediaQuery.sizeOf(context);
    final view = WidgetsBinding.instance.platformDispatcher.implicitView!;
    final native = view.physicalSize / view.devicePixelRatio;
    final text = MediaQuery.textScalerOf(context).scale(16);
    final validSize = logical.width > 0 && logical.height > 0;
    final sameView =
        (logical.width - native.width).abs() < 1 &&
        (logical.height - native.height).abs() < 1;
    final correctProfile = displayProfile == 'portrait'
        ? logical.width < logical.height && (text - 16).abs() < 0.5
        : logical.width > logical.height && text >= 25;
    matchingFrames = validSize && sameView && correctProfile
        ? matchingFrames + 1
        : 0;
    if (matchingFrames >= 2) return;
  }
  fail('Native display profile did not arrive: $displayProfile');
}

/// Đối chiếu MediaQuery với view native để tìm race metrics, không ghi credential hoặc nội dung form.
/// Input
/// Param: tester — runner chứa component preview đang sống trên emulator.
/// Param: screen — component hiện hành, không tên account hoặc input.
/// Param: phase — nhãn trước/sau flow chỉ phục vụ liên kết observation phía host.
void logDisplayMetrics(WidgetTester tester, Finder screen, String phase) {
  final context = tester.element(screen);
  final logical = MediaQuery.sizeOf(context);
  final native = WidgetsBinding.instance.platformDispatcher.implicitView!;
  debugPrint(
    'NATIVE_PREVIEW_METRICS phase=$phase logicalWidth=${logical.width} '
    'logicalHeight=${logical.height} physicalWidth=${native.physicalSize.width} '
    'physicalHeight=${native.physicalSize.height} ratio=${native.devicePixelRatio}',
  );
}
