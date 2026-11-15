import 'dart:async';
import 'dart:math' as math;

/// Protocol chỉ dành integration target; production main không import hoặc nhận SDK test command.
final class NativeRateCheckpoint {
  /// Clock mặc định là Stopwatch; injection chỉ cho host unit, không thay clock App/server.
  NativeRateCheckpoint({Duration Function()? elapsed}) {
    _watch.start();
    _elapsed = elapsed ?? _readElapsed;
  }

  static const _stages = [
    'rate-before',
    'rate-wrong-1',
    'rate-wrong-2',
    'rate-wrong-3',
    'rate-wrong-4',
    'rate-wrong-5',
    'rate-limited',
    'rate-mid-cooldown',
    'rate-expired',
    'rate-login',
    'rate-logout',
  ];
  final _watch = Stopwatch();
  late final Duration Function() _elapsed;
  Duration _last = Duration.zero;
  Duration? _deadline;
  Completer<void>? _release;
  String? _stage;
  var _position = 0;
  var _failed = false;

  /// Output: elapsed thật cùng epoch trong lifetime của helper.
  Duration _readElapsed() => _watch.elapsed;

  /// Clock lùi hoặc âm hủy ownership, không cho ACK tiếp bằng một sample có lợi hơn.
  Duration? _sample() {
    if (_failed) return null;
    final current = _elapsed();
    if (current.isNegative || current < _last) {
      cancel();
      return null;
    }
    _last = current;
    return current;
  }

  /// Begin duy nhất sau pause trước đã clear; sai stage/overlap làm test fail vĩnh viễn.
  void begin(String stage) {
    final current = _sample();
    if (current == null ||
        _release != null ||
        _position >= _stages.length ||
        _stages[_position] != stage) {
      cancel();
      throw StateError('NATIVE_RATE_CHECKPOINT_ORDER_INVALID');
    }
    _stage = stage;
    _release = Completer<void>();
    _deadline = current + const Duration(seconds: 5);
  }

  /// Chỉ positive floor milliseconds cấp receipt; dưới1ms không đủ để công bố checkpoint usable.
  int? _remaining() {
    if (_failed || _release == null || _release!.isCompleted) return null;
    final current = _sample();
    if (current == null) return null;
    final remaining = (_deadline! - current).inMilliseconds;
    if (remaining < 1) {
      cancel();
      return null;
    }
    return remaining;
  }

  /// Status omit cả stage/remaining ngay sau complete, không chờ native pump hoặc finally.
  Map<String, Object> receipt() {
    final remaining = _remaining();
    if (remaining == null) return const {};
    return {
      'checkpoint': _stage!,
      'checkpointRemainingMilliseconds': remaining,
    };
  }

  /// ACK kiểm schema/stage và clock lần cuối ngay trước synchronous commit; replay không tiến position.
  bool acknowledge(Map<String, String> parameters) {
    if (_remaining() == null ||
        parameters['stage'] != _stage ||
        parameters.keys.any((key) => key != 'stage' && key != 'isolateId')) {
      return false;
    }
    if (_remaining() == null) return false;
    _release!.complete();
    _position++;
    return true;
  }

  /// ACK đã committed đúng hạn không bị pump trễ biến thành expired sau response.
  bool get acknowledged => !_failed && _release?.isCompleted == true;

  /// Poll expiry cũng dùng cùng Stopwatch, không reset5s từ status hoặc mỗi ACK sai.
  bool get expired {
    if (_failed) return true;
    if (_release == null || _release!.isCompleted) return false;
    return _remaining() == null;
  }

  /// Clear chỉ sau ACK; timeout/cancel không được gọi endPause để mở stage tiếp theo.
  void endPause() {
    if (!acknowledged) {
      cancel();
      throw StateError('NATIVE_RATE_CHECKPOINT_TIMEOUT');
    }
    _release = null;
    _deadline = null;
    _stage = null;
  }

  /// Bỏ capability cũ vĩnh viễn; đây chỉ là local pause, không tuyên bố đã hủy SDK/SQL.
  void cancel() {
    _failed = true;
    _release = null;
    _deadline = null;
    _stage = null;
  }

  /// Chỉ đủ11 ACK và pause cuối đã clear mới cho framework kết thúc scenario.
  bool get complete =>
      !_failed && _position == _stages.length && _release == null;
}

/// Kiểm samples từ UI thật theo Stopwatch; không gọi action, không tự tua App/server clock.
final class NativeRateObservation {
  /// observedAt phải được lấy sau fresh typed429 VÀ cooldown card đã render, để chứa đúng mốc start.
  NativeRateObservation({
    required this.submittedAt,
    required this.observedAt,
    required this.retryAfterSeconds,
  }) {
    if (submittedAt.isNegative ||
        observedAt < submittedAt ||
        retryAfterSeconds < 1 ||
        retryAfterSeconds > 900) {
      throw ArgumentError('INVALID_NATIVE_RATE_OBSERVATION');
    }
  }

  final Duration submittedAt;
  final Duration observedAt;
  final int retryAfterSeconds;
  Duration? _lastSample;
  Duration? _plateauAt;
  Duration? _formReturnedAt;
  int? _lastRemaining;
  var _decreased = false;
  var _failed = false;

  /// Vi phạm làm proof fail vĩnh viễn; sample sau không được xóa một khoảng mù/lệch clock đã thấy.
  Never _reject() {
    _failed = true;
    throw StateError('NATIVE_RATE_OBSERVATION_INVALID');
  }

  /// Input là số/visibility private, không UI text/token. Maxgap6s bao checkpoint5s và tối đa1s xử lý.
  void sample({
    required Duration at,
    required int remainingSeconds,
    required bool cooldownVisible,
    required bool formVisible,
  }) {
    if (_failed ||
        at.isNegative ||
        at < observedAt ||
        (_lastSample != null && at < _lastSample!) ||
        at - (_lastSample ?? observedAt) > const Duration(seconds: 6) ||
        cooldownVisible == formVisible ||
        remainingSeconds < 0 ||
        remainingSeconds > retryAfterSeconds ||
        (cooldownVisible && remainingSeconds == 0) ||
        (formVisible && remainingSeconds != 0) ||
        (_lastSample == null && !cooldownVisible) ||
        (_lastRemaining != null && remainingSeconds > _lastRemaining!)) {
      _reject();
    }
    final original = Duration(seconds: retryAfterSeconds).inMicroseconds;
    final lower = math.max(
      0,
      original - (at - submittedAt).inMicroseconds - 2000000,
    );
    final upper = math.max(
      0,
      original - (at - observedAt).inMicroseconds + 2000000,
    );
    final shown = Duration(seconds: remainingSeconds).inMicroseconds;
    if (shown < lower || shown > upper) _reject();
    if (cooldownVisible) {
      if (_lastRemaining == remainingSeconds) {
        if (at - _plateauAt! > const Duration(seconds: 3)) _reject();
      } else {
        _plateauAt = at;
      }
    } else {
      _formReturnedAt ??= at;
    }
    if (_lastRemaining != null && remainingSeconds < _lastRemaining!) {
      _decreased = true;
    }
    _lastSample = at;
    _lastRemaining = remainingSeconds;
  }

  /// Chỉ sample mới nhất mới chứng minh elapsed: max(observed429+900s, form return)+2s, không skip thời gian.
  bool get complete {
    if (_failed ||
        !_decreased ||
        _lastSample == null ||
        _formReturnedAt == null) {
      return false;
    }
    final windowEnd = observedAt + const Duration(seconds: 900);
    final later = windowEnd > _formReturnedAt! ? windowEnd : _formReturnedAt!;
    return _lastSample! >= later + const Duration(seconds: 2);
  }
}
