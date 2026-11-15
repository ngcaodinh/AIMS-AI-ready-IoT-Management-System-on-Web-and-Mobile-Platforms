/// Gate riêng của offline integration; không điều khiển App, network, SQL hoặc cấp quyền session.
/// Host vẫn phải chứng minh HTTP/DB và drain các operation trước khi gửi ACK.
final class NativeOfflineCheckpoint {
  /// Tạo gate sau ARM hoặc nhận clock675s đã neo ARM từ entry; không neo lại theo sample đầu.
  /// Input
  /// Param: elapsed — monotonic elapsed cùng phase, injection chỉ cho host unit test.
  NativeOfflineCheckpoint({Duration Function()? elapsed}) {
    _watch.start();
    _elapsed = elapsed ?? _readElapsed;
  }

  static const _phaseLimit = Duration(seconds: 675);
  static const _stages = {
    'offline-ready': Duration(seconds: 110),
    'offline-result': Duration(seconds: 110),
    'offline-quiet': Duration(seconds: 170),
    'offline-picker': Duration(seconds: 170),
    'offline-logged-out': Duration(seconds: 5),
  };
  final _watch = Stopwatch();
  late final Duration Function() _elapsed;
  Duration _last = Duration.zero;
  Duration? _deadline;
  String? _stage;
  var _position = 0;
  var _acknowledged = false;
  var _failed = false;

  /// Output: Stopwatch thực của instance nếu caller không cung cấp clock neo ARM.
  Duration _readElapsed() => _watch.elapsed;

  /// Kiểm global675s và clock trên mọi admission/outcome, không phản chiếu raw clock exception.
  /// Output: elapsed hợp lệ hoặc null sau failure sticky.
  Duration? _sample() {
    if (_failed) return null;
    try {
      final current = _elapsed();
      if (current.isNegative || current < _last || current >= _phaseLimit) {
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

  /// Mở đúng stage kế, sau khi pause trước đã ACK và clear.
  /// Input
  /// Param: stage — fixed protocol enum, không nhận command từ field phụ.
  /// Errors: StateError cố định khi sai thứ tự/overlap/hết phase hoặc clock lỗi.
  void begin(String stage) {
    final current = _sample();
    if (current == null ||
        _stage != null ||
        _position >= _stages.length ||
        _stages.keys.elementAt(_position) != stage) {
      cancel();
      throw StateError('NATIVE_OFFLINE_CHECKPOINT_ORDER_INVALID');
    }
    _stage = stage;
    _acknowledged = false;
    final localDeadline = current + _stages[stage]!;
    // Cap stage không thể cấp thời gian vượt phase; polling/ACK sai không đổi hai anchor này.
    _deadline = localDeadline < _phaseLimit ? localDeadline : _phaseLimit;
  }

  /// Output: remaining floor của pause pending; dưới1ms không đủ để phát capability usable.
  int? _remaining() {
    final current = _sample();
    if (current == null || _stage == null || _acknowledged) return null;
    final remaining = (_deadline! - current).inMilliseconds;
    if (remaining < 1) {
      cancel();
      return null;
    }
    return remaining;
  }

  /// Trả bản sao receipt tối thiểu; empty không tự chứng minh host ACK hoặc SQL terminal.
  /// Output: fixed stage và remaining, không identity/credential/network payload.
  Map<String, Object> receipt() {
    final remaining = _remaining();
    if (remaining == null) return const {};
    return {
      'checkpoint': _stage!,
      'checkpointRemainingMilliseconds': remaining,
    };
  }

  /// Commit ACK đồng bộ đúng stage một lần, sample lại sát commit sau kiểm schema.
  /// Input
  /// Param: parameters — SDK metadata stage/isolateId; bridge phải tự pin isolate ownership.
  /// Output: false khi sai schema/replay/late/clock, không gia hạn hoặc làm effect nghiệp vụ.
  bool acknowledge(Map<String, String> parameters) {
    if (_remaining() == null ||
        parameters['stage'] != _stage ||
        parameters.keys.any(
          /// Field khác không được biến protocol local thành SQL/network control tùy ý.
          (key) => key != 'stage' && key != 'isolateId',
        )) {
      return false;
    }
    if (_remaining() == null) return false;
    _acknowledged = true;
    _position++;
    return true;
  }

  /// Output: local ACK đúng hạn giữ qua pump trễ, nhưng global phase expiry vẫn khóa outcome.
  bool get acknowledged => _sample() != null && _stage != null && _acknowledged;

  /// Output: failure/global timeout hoặc pause chưa ACK hết local cap; không coi timeout là raw-close.
  bool get expired {
    if (_sample() == null) return true;
    if (_stage == null || _acknowledged) return false;
    return _remaining() == null;
  }

  /// Clear local pause sau ACK, không nhả ownership của operation host còn pending.
  /// Errors: clear sớm hoặc global failure làm gate thất bại vĩnh viễn.
  void endPause() {
    if (!acknowledged) {
      cancel();
      throw StateError('NATIVE_OFFLINE_CHECKPOINT_NOT_ACKNOWLEDGED');
    }
    _stage = null;
    _deadline = null;
    _acknowledged = false;
  }

  /// Hủy local capability idempotent; owner SDK/network/SQL vẫn phải cleanup/drain riêng.
  void cancel() {
    _failed = true;
    _stage = null;
    _deadline = null;
    _acknowledged = false;
  }

  /// Output: đủ5ACK và final clear trước global675s, chưa thay framework/H2/DB/cleanup PASS.
  bool get complete =>
      _sample() != null && _position == _stages.length && _stage == null;
}
