import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/support/native_debug_secret_canary.dart';

const _passwordCanary = 'fixture-password-canary-1234567890';
const _bearerCanary = 'fixture-android-bearer-canary-0987654321';

/// Ghi nhận message chỉ sau khi canary khôi phục printer gốc.
final class _DebugPrintRecorder {
  final List<String?> messages = [];

  /// Ghi nhận message được chuyển tới printer gốc sau khi capture kết thúc.
  ///
  /// Param: message — nội dung debug mà printer nhận.
  /// Param: wrapWidth — cấu hình wrap của callback; phép ghi nhận chỉ kiểm nội dung.
  void record(String? message, {int? wrapWidth}) {
    messages.add(message);
  }
}

/// Đăng ký các test hành vi cho canary `debugPrint`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'discards captured messages and restores the previous printer',
    discardsMessagesAndRestoresPrinter,
  );
  test(
    'rejects password without forwarding raw messages',
    rejectsPasswordWithoutForwardingRawMessages,
  );
  test(
    'rejects a bearer split across debug callbacks',
    rejectsBearerSplitAcrossCallbacks,
  );
  test(
    'scans buffered messages after the bearer becomes known',
    scansBufferedBearerAfterRegistration,
  );
  test(
    'fails closed when the bounded buffer overflows',
    failsClosedOnBufferOverflow,
  );
}

/// Xác nhận message trong buffer bị bỏ và printer cũ nhận được log mới sau khi khôi phục.
void discardsMessagesAndRestoresPrinter() {
  final previous = debugPrint;
  final recorder = _DebugPrintRecorder();
  debugPrint = recorder.record;
  final installed = debugPrint;
  final canary = NativeDebugSecretCanary(initialCanaries: [_passwordCanary]);
  try {
    debugPrint('captured synthetic message');
    canary.verify();
    expect(recorder.messages, isEmpty);
    expect(debugPrint, same(installed));
    debugPrint('printer restored');
    expect(recorder.messages, ['printer restored']);
  } finally {
    canary.dispose();
    debugPrint = previous;
  }
}

/// Xác nhận password bị phát hiện và message thô không tới printer bên ngoài.
void rejectsPasswordWithoutForwardingRawMessages() {
  final previous = debugPrint;
  final recorder = _DebugPrintRecorder();
  debugPrint = recorder.record;
  final canary = NativeDebugSecretCanary(initialCanaries: [_passwordCanary]);
  try {
    debugPrint(_passwordCanary);
    var failureMarker = '';
    try {
      canary.verify();
    } on StateError catch (failure) {
      failureMarker = failure.message;
    }
    expect(failureMarker, 'NATIVE_DEBUG_SECRET_CANARY_FAILED');
    expect(recorder.messages, isEmpty);
    debugPrint('printer restored');
    expect(recorder.messages, ['printer restored']);
  } finally {
    canary.dispose();
    debugPrint = previous;
  }
}

/// Xác nhận ghép phần đuôi/đầu nhận ra bearer bị chia và không phát lại hai phần.
void rejectsBearerSplitAcrossCallbacks() {
  final previous = debugPrint;
  final recorder = _DebugPrintRecorder();
  debugPrint = recorder.record;
  final canary = NativeDebugSecretCanary(initialCanaries: [_bearerCanary]);
  try {
    final splitAt = _bearerCanary.length ~/ 2;
    debugPrint(_bearerCanary.substring(0, splitAt));
    debugPrint(_bearerCanary.substring(splitAt));
    var failureMarker = '';
    try {
      canary.verify();
    } on StateError catch (failure) {
      failureMarker = failure.message;
    }
    expect(failureMarker, 'NATIVE_DEBUG_SECRET_CANARY_FAILED');
    expect(recorder.messages, isEmpty);
  } finally {
    canary.dispose();
    debugPrint = previous;
  }
}

/// Xác nhận bearer trong log cũ được phát hiện khi secure storage mới cấp canary đó.
void scansBufferedBearerAfterRegistration() {
  final previous = debugPrint;
  final recorder = _DebugPrintRecorder();
  debugPrint = recorder.record;
  final canary = NativeDebugSecretCanary(initialCanaries: [_passwordCanary]);
  try {
    debugPrint(_bearerCanary);
    canary.addCanary(_bearerCanary);
    var failureMarker = '';
    try {
      canary.verify();
    } on StateError catch (failure) {
      failureMarker = failure.message;
    }
    expect(failureMarker, 'NATIVE_DEBUG_SECRET_CANARY_FAILED');
    expect(recorder.messages, isEmpty);
  } finally {
    canary.dispose();
    debugPrint = previous;
  }
}

/// Xác nhận vượt giới hạn RAM dừng kín, không phát message dù nội dung không khớp canary.
void failsClosedOnBufferOverflow() {
  final previous = debugPrint;
  final recorder = _DebugPrintRecorder();
  debugPrint = recorder.record;
  final canary = NativeDebugSecretCanary(initialCanaries: [_passwordCanary]);
  try {
    final chunk = List<String>.filled(1024, 'x').join();
    for (var index = 0; index < 1025; index++) {
      debugPrint(chunk);
    }
    var failureMarker = '';
    try {
      canary.verify();
    } on StateError catch (failure) {
      failureMarker = failure.message;
    }
    expect(failureMarker, 'NATIVE_DEBUG_SECRET_CANARY_FAILED');
    expect(recorder.messages, isEmpty);
  } finally {
    canary.dispose();
    debugPrint = previous;
  }
}
