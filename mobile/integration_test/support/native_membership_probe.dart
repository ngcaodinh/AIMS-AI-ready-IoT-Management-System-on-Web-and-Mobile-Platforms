/**
 * Checkpoint chỉ dành native membership integration, giữ pause và ACK local theo thứ tự cố định.
 * Host vẫn chịu trách nhiệm ownership isolate, deadline toàn phase và terminal SQL/SDK.
 */
final class NativeMembershipCheckpoint {
  /**
   * Chốt clock cùng epoch cho lifetime của gate để status polling không mở lại deadline.
   * Input
   * Param: elapsed — clock injection chỉ cho host unit test, mặc định Stopwatch thực.
   */
  NativeMembershipCheckpoint({Duration Function()? elapsed}) {
    _watch.start();
    _elapsed = elapsed ?? _readElapsed;
  }

  static const _stages = [
    'membership-before-login',
    'membership-picker',
    'membership-denied',
    'membership-only-a',
    'membership-a-opened',
    'membership-logged-out',
  ];
  final _watch = Stopwatch();
  late final Duration Function() _elapsed;
  Duration _last = Duration.zero;
  Duration? _deadline;
  String? _stage;
  var _position = 0;
  var _acknowledged = false;
  var _failed = false;

  /// Output: elapsed monotonic của clock mặc định, độc lập tester pump và wallclock.
  Duration _readElapsed() => _watch.elapsed;

  /**
   * Chỉ nhận sample không âm và không lùi, clock exception được chặn ở boundary local.
   * Output: elapsed hợp lệ hoặc null sau sticky failure, không truyền raw clock error.
   */
  Duration? _sample() {
    if (_failed) return null;
    try {
      final current = _elapsed();
      if (current.isNegative || current < _last) {
        cancel();
        return null;
      }
      _last = current;
      return current;
    } catch (_) {
      cancel();
      return null;
    }
  }

  /**
   * Cấp đúng một pending stage sau stage trước đã ACK và clear.
   * Input
   * Param: stage — một enum fixed tiếp theo, không chứa identity hoặc command DB.
   * Errors: sai thứ tự, overlap hoặc clock lỗi gây StateError cố định và failed sticky.
   */
  void begin(String stage) {
    final current = _sample();
    if (current == null ||
        _stage != null ||
        _position >= _stages.length ||
        _stages[_position] != stage) {
      cancel();
      throw StateError('NATIVE_MEMBERSHIP_CHECKPOINT_ORDER_INVALID');
    }
    _stage = stage;
    _acknowledged = false;
    // Picker gồm snapshot130s +suspend20s +shared ACK RPC30s +headroom20s +margin10s, chưa phải tổng phase budget.
    final cap = stage == 'membership-picker'
        ? const Duration(seconds: 210)
        : const Duration(seconds: 5);
    _deadline = current + cap;
  }

  /**
   * Chỉ phát remaining floor còn ít nhất1ms, không dùng status poll để gia hạn pause.
   * Output: remaining milliseconds hoặc null khi không pending/đã ACK/failed/hết hạn.
   */
  int? _remaining() {
    if (_failed || _stage == null || _acknowledged) return null;
    final current = _sample();
    if (current == null) return null;
    final remaining = (_deadline! - current).inMilliseconds;
    if (remaining < 1) {
      cancel();
      return null;
    }
    return remaining;
  }

  /**
   * Chụp receipt copy tối thiểu của pending stage, biến mất ngay sau ACK commit.
   * Output: fixed stage và remaining, hoặc empty map chưa đủ kết luận ACK thành công.
   */
  Map<String, Object> receipt() {
    final remaining = _remaining();
    if (remaining == null) return const {};
    return {
      'checkpoint': _stage!,
      'checkpointRemainingMilliseconds': remaining,
    };
  }

  /**
   * Commit ACK đồng bộ một lần sau kiểm schema/stage và clock ngay trước state transition.
   * Input
   * Param: parameters — metadata SDK chỉ stage/isolateId, isolate ownership phải do bridge xác minh riêng.
   * Output: true khi commit đúng hạn, false khi sai/replay/late hoặc clock lỗi, không reset deadline.
   */
  bool acknowledge(Map<String, String> parameters) {
    if (_remaining() == null ||
        parameters['stage'] != _stage ||
        parameters.keys.any(
          /**
           * Tránh biến metadata phụ thành command hoặc authority của protocol.
           * Input
           * Param: key — tên field RPC cần đối chiếu allowlist.
           * Output: field không được phép.
           */
          (key) => key != 'stage' && key != 'isolateId',
        )) {
      return false;
    }
    // Schema validation không phải commit, sample lại để chặn clock đổi ngay trước ACK.
    if (_remaining() == null) return false;
    _acknowledged = true;
    _position++;
    return true;
  }

  /// Output: ACK đã commit trong pending pause, giữ ổn định khi pump tới sau local deadline.
  bool get acknowledged => !_failed && _stage != null && _acknowledged;

  /// Output: failed hoặc pause pending đã hết hạn, ACK đúng hạn chưa bị pump trễ đổi outcome.
  bool get expired {
    if (_failed) return true;
    if (_stage == null || _acknowledged) return false;
    return _remaining() == null;
  }

  /**
   * Clear local pause sau ACK để stage kế được admission, chưa khẳng định SQL/SDK terminal.
   * Errors: clear trước ACK hoặc sau failure gây fixed StateError và failed sticky.
   */
  void endPause() {
    if (!acknowledged) {
      cancel();
      throw StateError('NATIVE_MEMBERSHIP_CHECKPOINT_NOT_ACKNOWLEDGED');
    }
    _stage = null;
    _deadline = null;
    _acknowledged = false;
  }

  /// Hủy gate local vĩnh viễn, caller vẫn phải drain operation SQL/SDK thuộc ownership của nó.
  void cancel() {
    _failed = true;
    _stage = null;
    _deadline = null;
    _acknowledged = false;
  }

  /// Output: đủ6ACK đúng thứ tự và pause cuối đã clear, chưa thay completion toàn phase/fixture.
  bool get complete =>
      !_failed && _position == _stages.length && _stage == null;
}
