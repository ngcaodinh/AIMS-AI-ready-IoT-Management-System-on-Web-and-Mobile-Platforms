import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/support/native_offline_probe.dart';

const _stages = [
  'offline-ready',
  'offline-result',
  'offline-quiet',
  'offline-picker',
  'offline-outbox-ready',
  'offline-outbox-persisted',
];
const _caps = [110000, 110000, 170000, 170000, 170000, 170000];
const _expiredStages = [
  'offline-expired-offline',
  'offline-expired-ready',
  'offline-expired-persisted',
];
const _expiredCaps = [110000, 170000, 170000];
const _resumeStages = ['offline-outbox-resumed', 'offline-logged-out'];
const _resumeCaps = [170000, 120000];

/// Clock synthetic của gate, không thay Stopwatch của App hoặc đồng hồ backend.
final class OfflineTestClock {
  Duration value = Duration.zero;
  bool broken = false;

  /// Output: sample do case điều khiển hoặc lỗi không được phản chiếu ra protocol.
  Duration read() {
    if (broken) throw StateError('SYNTHETIC_PRIVATE_DIAGNOSTIC');
    return value;
  }
}

/// Đi qua các pause trước bằng ACK thật của gate, không sửa state private.
/// Input
/// Param: gate — gate riêng của case, cùng clock chưa bị lỗi.
/// Param: count — số stage đầu cần hoàn tất để kiểm stage kế.
void finishStages(NativeOfflineCheckpoint gate, int count) {
  for (var index = 0; index < count; index++) {
    gate.begin(_stages[index]);
    expect(gate.acknowledge({'stage': _stages[index]}), isTrue);
    gate.endPause();
  }
}

/// Kiểm profile có đúng stage/cap theo thứ tự và chỉ complete sau khi từng pause được clear.
/// Input
/// Param: profile — tên profile checkpoint cố định của fixture native.
/// Param: stages — enum stage theo thứ tự mà runner được phép ACK.
/// Param: caps — timeout milliseconds tương ứng, không do packet cấp quyền.
void verifyProfile(String profile, List<String> stages, List<int> caps) {
  final gate = NativeOfflineCheckpoint(
    elapsed: () => Duration.zero,
    profile: profile,
  );
  for (var index = 0; index < stages.length; index++) {
    final stage = stages[index];
    gate.begin(stage);
    expect(gate.receipt()['checkpointRemainingMilliseconds'], caps[index]);
    expect(gate.acknowledge({'stage': stage}), isTrue);
    gate.endPause();
  }
  expect(gate.complete, isTrue);
}

/// Kiểm ordered local protocol; không dùng fake clock làm evidence mạng/DB/emulator.
void main() {
  test(
    'six ordered outbox stages have fixed caps and require final clear',

    /// Receipt là bản sao, ACK chỉ một lần; metadata không mang SQL/credential authority.
    () {
      final clock = OfflineTestClock();
      final gate = NativeOfflineCheckpoint(elapsed: clock.read);
      expect(gate.receipt(), isEmpty);
      expect(gate.acknowledge({'stage': _stages.first}), isFalse);
      for (var index = 0; index < _stages.length; index++) {
        final stage = _stages[index];
        gate.begin(stage);
        final receipt = gate.receipt();
        expect(receipt, {
          'checkpoint': stage,
          'checkpointRemainingMilliseconds': _caps[index],
        });
        receipt['checkpoint'] = 'untrusted';
        expect(gate.receipt()['checkpoint'], stage);
        expect(gate.acknowledge({'stage': stage, 'command': 'SQL'}), isFalse);
        expect(gate.acknowledge({'stage': 'wrong'}), isFalse);
        expect(gate.acknowledge({}), isFalse);
        expect(
          gate.acknowledge({'stage': stage, 'isolateId': 'isolates/1'}),
          isTrue,
        );
        expect(gate.acknowledge({'stage': stage}), isFalse);
        expect(gate.receipt(), isEmpty);
        expect(gate.complete, isFalse);
        gate.endPause();
      }
      expect(gate.complete, isTrue);
    },
  );

  test(
    'expired and resume profiles use their own fixed checkpoint sequences',

    /// Profile expired giữ pause offline/persisted; resume chỉ mở checkpoint restore/logout.
    () {
      verifyProfile('offline-expired', _expiredStages, _expiredCaps);
      verifyProfile('offline-resume', _resumeStages, _resumeCaps);
    },
  );

  for (var index = 0; index < _stages.length; index++) {
    test(
      'stage $index rejects sub-millisecond remaining and deadline extension',

      /// Poll và schema sai không được cấp lại cap, kể cả pause quiet/picker dài.
      () {
        for (final remaining in [999, 0, -1]) {
          final clock = OfflineTestClock();
          final gate = NativeOfflineCheckpoint(elapsed: clock.read);
          finishStages(gate, index);
          gate.begin(_stages[index]);
          clock.value = Duration(microseconds: _caps[index] * 1000 - remaining);
          expect(gate.receipt(), isEmpty);
          expect(gate.acknowledge({'stage': _stages[index]}), isFalse);
          expect(gate.expired, isTrue);
        }
        final clock = OfflineTestClock();
        final gate = NativeOfflineCheckpoint(elapsed: clock.read);
        finishStages(gate, index);
        gate.begin(_stages[index]);
        clock.value = Duration(milliseconds: _caps[index] - 1);
        expect(gate.receipt()['checkpointRemainingMilliseconds'], 1);
        expect(gate.acknowledge({'stage': 'wrong'}), isFalse);
        expect(gate.receipt()['checkpointRemainingMilliseconds'], 1);
        expect(gate.acknowledge({'stage': _stages[index]}), isTrue);
      },
    );
  }

  test(
    'global phase cap cuts local pause and cannot be reset by begin or polling',

    /// Clock neo ARM675s, không neo lại theo thời điểm gate được tạo hoặc stage mới.
    () {
      final clock = OfflineTestClock()..value = const Duration(seconds: 674);
      final gate = NativeOfflineCheckpoint(elapsed: clock.read);
      gate.begin(_stages.first);
      expect(gate.receipt()['checkpointRemainingMilliseconds'], 1000);
      clock.value = const Duration(milliseconds: 674999);
      expect(gate.receipt()['checkpointRemainingMilliseconds'], 1);
      clock.value = const Duration(seconds: 675);
      expect(gate.acknowledge({'stage': _stages.first}), isFalse);
      expect(gate.expired, isTrue);
      expect(gate.complete, isFalse);
    },
  );

  test(
    'out of order overlap and premature clear are sticky failures',

    /// Vi phạm protocol không được dùng lại gate để dựng proof sạch.
    () {
      final wrongOrder = NativeOfflineCheckpoint();
      expect(() => wrongOrder.begin(_stages[1]), throwsStateError);
      expect(() => wrongOrder.begin(_stages.first), throwsStateError);
      final overlap = NativeOfflineCheckpoint();
      overlap.begin(_stages.first);
      expect(() => overlap.begin(_stages.first), throwsStateError);
      expect(overlap.acknowledge({'stage': _stages.first}), isFalse);
      final early = NativeOfflineCheckpoint();
      early.begin(_stages.first);
      expect(early.endPause, throwsStateError);
      expect(early.expired, isTrue);
      final uncleared = NativeOfflineCheckpoint();
      uncleared.begin(_stages.first);
      expect(uncleared.acknowledge({'stage': _stages.first}), isTrue);
      expect(() => uncleared.begin(_stages[1]), throwsStateError);
    },
  );

  test(
    'negative rollback and throwing clocks fail closed without raw errors',

    /// Lỗi clock phải hủy mọi receipt và completion, kể cả sample sau phục hồi.
    () {
      for (final mode in ['negative', 'rollback', 'throw']) {
        final clock = OfflineTestClock();
        final gate = NativeOfflineCheckpoint(elapsed: clock.read);
        gate.begin(_stages.first);
        clock.value = const Duration(seconds: 2);
        expect(gate.receipt(), isNotEmpty);
        clock.value = Duration(seconds: mode == 'negative' ? -1 : 1);
        clock.broken = mode == 'throw';
        expect(gate.receipt(), isEmpty);
        clock.broken = false;
        clock.value = const Duration(seconds: 3);
        expect(gate.acknowledge({'stage': _stages.first}), isFalse);
        expect(gate.complete, isFalse);
        expect(gate.expired, isTrue);
      }
    },
  );

  test(
    'acknowledgement resamples immediately before commit',

    /// Clock đổi sau schema validation vẫn không được commit ACK tới muộn.
    () {
      var reads = 0;
      final gate = NativeOfflineCheckpoint(
        elapsed:
            /// Begin và validation hợp lệ, sample commit chạm global deadline.
            () => ++reads < 3 ? Duration.zero : const Duration(seconds: 675),
      );
      gate.begin(_stages.first);
      expect(gate.acknowledge({'stage': _stages.first}), isFalse);
      expect(gate.expired, isTrue);
    },
  );

  test(
    'local ack survives late pump but global expiry blocks completion',

    /// ACK đúng hạn không bị local timeout đổi outcome; global675 vẫn là fence cuối.
    () {
      final clock = OfflineTestClock();
      final gate = NativeOfflineCheckpoint(elapsed: clock.read);
      gate.begin(_stages.first);
      expect(gate.acknowledge({'stage': _stages.first}), isTrue);
      clock.value = const Duration(seconds: 111);
      expect(gate.acknowledged, isTrue);
      gate.endPause();
      finishStagesAfterFirst(gate, _stages);
      expect(gate.complete, isTrue);
      clock.value = const Duration(seconds: 675);
      expect(gate.complete, isFalse);
      expect(gate.expired, isTrue);
    },
  );

  test(
    'cancel is idempotent and prevents reuse after acknowledged pause',

    /// Cancel chỉ khóa local capability, không giả network/SQL đã dừng.
    () {
      final gate = NativeOfflineCheckpoint();
      gate.begin(_stages.first);
      expect(gate.acknowledge({'stage': _stages.first}), isTrue);
      gate.cancel();
      gate.cancel();
      expect(gate.acknowledged, isFalse);
      expect(gate.complete, isFalse);
      expect(gate.receipt(), isEmpty);
      expect(() => gate.begin(_stages[1]), throwsStateError);
    },
  );
}

/// Hoàn tất bốn stage cuối từ ACK đầu đã clear, giữ nguyên clock và global anchor.
/// Input
/// Param: gate — instance đã đi qua stage đầu bằng protocol công khai.
/// Param: stages — chuỗi profile mà test đang kiểm, không đổi order/cap nội bộ.
void finishStagesAfterFirst(NativeOfflineCheckpoint gate, List<String> stages) {
  for (final stage in stages.skip(1)) {
    gate.begin(stage);
    expect(gate.acknowledge({'stage': stage}), isTrue);
    gate.endPause();
  }
}
