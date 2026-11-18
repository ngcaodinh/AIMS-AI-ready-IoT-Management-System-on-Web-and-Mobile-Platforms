import 'package:flutter/foundation.dart';

/// Quét debugPrint trong isolate hiện hành mà không chuyển credential khỏi thiết bị.
final class NativeDebugSecretCanary {
  /// Chặn log trong RAM để quét credential mới phát sinh sau khi nhận bearer thật.
  ///
  /// Param: initialCanaries — password hoặc bearer đã có sẵn trong isolate.
  /// Errors: canary rỗng hoặc ngoài giới hạn làm test dừng bằng mã cố định.
  NativeDebugSecretCanary({required Iterable<String> initialCanaries})
    : _previousDebugPrint = debugPrint,
      _canaries = <String>{...initialCanaries} {
    if (_canaries.isEmpty ||
        _canaries.any(
          /// Không chấp nhận canary rỗng hoặc vượt giới hạn quét của test.
          (canary) => canary.isEmpty || canary.length > _maxCanaryCharacters,
        )) {
      throw StateError('NATIVE_DEBUG_CANARY_INVALID');
    }
    debugPrint = _capture;
  }

  // Giới hạn bộ nhớ test để log bất thường làm FAIL thay vì tăng RAM vô hạn.
  static const int _maxBufferedCharacters = 1024 * 1024;
  static const int _maxBufferedMessages = 8192;
  // Cùng cận 4096 ký tự của scanner backend để tail không giữ chuỗi vượt budget.
  static const int _maxCanaryCharacters = 4096;

  final DebugPrintCallback _previousDebugPrint;
  final Set<String> _canaries;
  final List<String?> _messages = [];
  int _bufferedCharacters = 0;
  String _tail = '';
  bool _overflowed = false;
  bool _leaked = false;
  bool _disposed = false;

  /// Bổ sung bearer mới và quét ngược log đã ghi trước khi biết giá trị đó.
  ///
  /// Param: canary — credential lấy trực tiếp từ secure storage trong isolate.
  /// Errors: giá trị rỗng/quá dài hoặc canary đã dispose làm test dừng bằng mã cố định.
  void addCanary(String canary) {
    if (_disposed || canary.isEmpty || canary.length > _maxCanaryCharacters) {
      throw StateError('NATIVE_DEBUG_CANARY_INVALID');
    }
    if (_canaries.add(canary)) {
      _leaked = _leaked || _bufferContains(canary);
      _refreshTail();
    }
  }

  /// Giữ và quét debug message; callback bỏ metadata printer và không phát log thô ra ngoài.
  ///
  /// Input
  /// Param: message — nội dung debug cần rà soát trước khi khôi phục printer.
  /// Param: wrapWidth — gợi ý định dạng cho printer gốc; không lưu vì log không được phát lại.
  void _capture(String? message, {int? wrapWidth}) {
    if (_disposed || _overflowed) return;
    final fragment = message ?? '';
    // Đã vượt budget thì test chắc chắn FAIL; dừng sớm để log lớn/lặp không tiêu tốn thêm CPU.
    if (_messages.length >= _maxBufferedMessages ||
        _bufferedCharacters + fragment.length > _maxBufferedCharacters) {
      _overflowed = true;
      return;
    }
    // Chỉ ghép phần đầu cần thiết; message lớn vẫn được quét mà không tạo bản sao không giới hạn.
    final overlap = _longestCanaryLength() - 1;
    final prefix = fragment.length <= overlap
        ? fragment
        : fragment.substring(0, overlap);
    final boundaryCandidate = '$_tail$prefix';
    if (_canaries.any(
      (canary) =>
          fragment.contains(canary) || boundaryCandidate.contains(canary),
    )) {
      _leaked = true;
    }
    _advanceTail(fragment);
    _messages.add(message);
    _bufferedCharacters += fragment.length;
  }

  /// Quét toàn bộ message đã đệm, kể cả khi canary chỉ được biết sau đăng nhập.
  ///
  /// Param: canary — chuỗi bí mật cần tìm trong các message nối tiếp nhau.
  /// Output: true nếu chuỗi xuất hiện trong phần đệm.
  bool _bufferContains(String canary) {
    var tail = '';
    for (final message in _messages) {
      final combined = '$tail${message ?? ''}';
      if (combined.contains(canary)) return true;
      final retained = canary.length - 1;
      tail = retained <= 0 || combined.length <= retained
          ? combined
          : combined.substring(combined.length - retained);
    }
    return false;
  }

  /// Trả chiều dài lớn nhất để xác định số ký tự cần giữ qua hai callback.
  ///
  /// Output: độ dài lớn nhất trong các canary đang được theo dõi.
  int _longestCanaryLength() {
    var longestCanary = 0;
    for (final canary in _canaries) {
      if (canary.length > longestCanary) longestCanary = canary.length;
    }
    return longestCanary;
  }

  /// Giữ đủ phần cuối để phát hiện canary bị chia qua ranh hai callback.
  ///
  /// Param: fragment — message vừa nhận; chỉ phần cuối cần cho callback sau được giữ.
  void _advanceTail(String fragment) {
    final retained = _longestCanaryLength() - 1;
    if (retained <= 0) {
      _tail = '';
    } else if (fragment.length >= retained) {
      _tail = fragment.substring(fragment.length - retained);
    } else {
      final combined = '$_tail$fragment';
      _tail = combined.length <= retained
          ? combined
          : combined.substring(combined.length - retained);
    }
  }

  /// Tính lại tail sau khi đăng ký bearer dài hơn các canary ban đầu.
  void _refreshTail() {
    var tail = '';
    for (final message in _messages) {
      _tail = tail;
      _advanceTail(message ?? '');
      tail = _tail;
    }
  }

  /// Dừng bằng mã cố định khi có credential hoặc log vượt giới hạn, rồi bỏ toàn bộ message đã đệm.
  ///
  /// Errors: rò rỉ canary hoặc vượt budget làm test FAIL mà không in dữ liệu thô.
  void verify() {
    if (_disposed) throw StateError('NATIVE_DEBUG_CANARY_DISPOSED');
    final failed = _overflowed || _leaked;
    dispose();
    if (failed) throw StateError('NATIVE_DEBUG_SECRET_CANARY_FAILED');
  }

  /// Khôi phục debugPrint và xóa mọi tham chiếu log/canary khỏi helper.
  void dispose() {
    if (_disposed) return;
    debugPrint = _previousDebugPrint;
    _messages.clear();
    _canaries.clear();
    _tail = '';
    _bufferedCharacters = 0;
    _disposed = true;
  }
}
