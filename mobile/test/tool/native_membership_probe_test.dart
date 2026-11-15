import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/support/native_membership_probe.dart';

const stages = [
  'membership-before-login',
  'membership-picker',
  'membership-denied',
  'membership-only-a',
  'membership-a-opened',
  'membership-logged-out',
];

/// Clock chỉ thuộc host test, không thay clock API hoặc App.
final class MembershipTestClock {
  Duration elapsed = Duration.zero;

  /// Output: sample monotonic do case chủ động điều khiển để kiểm deadline.
  Duration read() => elapsed;
}

/**
 * Đi qua stage đầu để test picker210s bằng đúng protocol, không sửa state private.
 * Input
 * Param: gate — instance riêng của case với clock đã chốt.
 */
void beginPicker(NativeMembershipCheckpoint gate) {
  gate.begin(stages.first);
  expect(gate.acknowledge({'stage': stages.first}), isTrue);
  gate.endPause();
  gate.begin(stages[1]);
}

/** Kiểm protocol local trước khi host được phép dùng pause cho owned DB operation. */
void main() {
  test(
    'ordered stages use fixed budgets and complete only after final clear',
    /** Các ACK đúng thứ tự phải commit một lần và giữ receipt copy độc lập. */
    () {
      final clock = MembershipTestClock();
      final gate = NativeMembershipCheckpoint(elapsed: clock.read);
      expect(gate.receipt(), isEmpty);
      expect(gate.expired, isFalse);
      expect(gate.complete, isFalse);
      expect(gate.acknowledge({}), isFalse);
      expect(gate.acknowledge({'stage': stages.first}), isFalse);
      for (final stage in stages) {
        gate.begin(stage);
        final cap = stage == 'membership-picker' ? 210000 : 5000;
        expect(gate.receipt(), {
          'checkpoint': stage,
          'checkpointRemainingMilliseconds': cap,
        });
        final receipt = gate.receipt();
        receipt['checkpoint'] = 'SYNTHETIC_UNTRUSTED_STAGE';
        receipt['checkpointRemainingMilliseconds'] = 999999;
        expect(gate.receipt()['checkpoint'], stage);
        expect(gate.receipt()['checkpointRemainingMilliseconds'], cap);
        expect(gate.acknowledge({'stage': stage, 'extra': 'x'}), isFalse);
        expect(gate.acknowledge({'stage': 'wrong'}), isFalse);
        expect(gate.acknowledge({}), isFalse);
        expect(
          gate.acknowledge({'stage': stage, 'isolateId': 'isolates/1'}),
          isTrue,
        );
        expect(gate.acknowledged, isTrue);
        expect(gate.receipt(), isEmpty);
        expect(gate.complete, isFalse);
        expect(gate.acknowledge({'stage': stage}), isFalse);
        // ACK đã commit trước hạn vẫn giữ kết quả khi native pump trễ.
        clock.elapsed += Duration(milliseconds: cap + 1);
        expect(gate.expired, isFalse);
        gate.endPause();
      }
      expect(gate.complete, isTrue);
      expect(
        /** Begin sau complete phải khóa admission và hủy completion cũ. */
        () => gate.begin(stages.first),
        throwsStateError,
      );
      expect(gate.complete, isFalse);
    },
  );

  test(
    'millisecond floor rejects fast and picker acknowledgements at boundary',
    /** Cả5s và210s đều chỉ phát receipt khi còn ít nhất1ms thực. */
    () {
      for (final picker in [false, true]) {
        final maximum = picker ? 210000000 : 5000000;
        for (final microseconds in [maximum - 999, maximum, maximum + 1]) {
          final clock = MembershipTestClock();
          final gate = NativeMembershipCheckpoint(elapsed: clock.read);
          if (picker) {
            beginPicker(gate);
          } else {
            gate.begin(stages.first);
          }
          clock.elapsed = Duration(microseconds: microseconds);
          expect(gate.receipt(), isEmpty);
          expect(
            gate.acknowledge({'stage': picker ? stages[1] : stages.first}),
            isFalse,
          );
          expect(gate.expired, isTrue);
          expect(gate.complete, isFalse);
        }
        final clock = MembershipTestClock();
        final gate = NativeMembershipCheckpoint(elapsed: clock.read);
        if (picker) {
          beginPicker(gate);
        } else {
          gate.begin(stages.first);
        }
        clock.elapsed = Duration(microseconds: maximum - 1000);
        expect(gate.receipt()['checkpointRemainingMilliseconds'], 1);
        expect(
          gate.acknowledge({'stage': picker ? stages[1] : stages.first}),
          isTrue,
        );
      }
    },
  );

  test(
    'invalid acknowledgement cannot reset the picker deadline',
    /** Poll và schema sai chỉ đọc remaining, không mở lại210s. */
    () {
      final clock = MembershipTestClock();
      final gate = NativeMembershipCheckpoint(elapsed: clock.read);
      beginPicker(gate);
      clock.elapsed = const Duration(seconds: 150);
      expect(gate.acknowledge({'stage': stages[1], 'extra': 'x'}), isFalse);
      expect(gate.receipt()['checkpointRemainingMilliseconds'], 60000);
      clock.elapsed = const Duration(seconds: 180);
      expect(gate.receipt()['checkpointRemainingMilliseconds'], 30000);
      expect(gate.acknowledge({'stage': stages[1], 'extra': 'x'}), isFalse);
      clock.elapsed = const Duration(seconds: 210);
      expect(gate.acknowledge({'stage': stages[1]}), isFalse);
      expect(gate.expired, isTrue);
    },
  );

  test(
    'overlap and out of order begin fail permanently',
    /** Mỗi instance chỉ có một pending stage, sai begin không thể retry để phục hồi proof. */
    () {
      final overlap = NativeMembershipCheckpoint();
      overlap.begin(stages.first);
      expect(
        /** Begin chồng không được thay pending capability hiện hành. */
        () => overlap.begin(stages.first),
        throwsStateError,
      );
      expect(overlap.acknowledge({'stage': stages.first}), isFalse);
      expect(overlap.expired, isTrue);
      final order = NativeMembershipCheckpoint();
      expect(
        /** Không bỏ qua stage đầu dù stage picker có budget dài hơn. */
        () => order.begin(stages[1]),
        throwsStateError,
      );
      expect(order.receipt(), isEmpty);
      expect(
        /** Failed latch không được reset bởi một begin hợp thứ tự về sau. */
        () => order.begin(stages.first),
        throwsStateError,
      );
    },
  );

  test(
    'next stage cannot begin before acknowledged pause is cleared',
    /** ACK đã commit vẫn giữ pending ownership tới endPause, không overwrite pause bằng stage kế. */
    () {
      final gate = NativeMembershipCheckpoint();
      gate.begin(stages.first);
      expect(gate.acknowledge({'stage': stages.first}), isTrue);
      expect(
        /** Stage kế đúng thứ tự cũng phải bị chặn khi pause cũ chưa clear. */
        () => gate.begin(stages[1]),
        throwsStateError,
      );
      expect(gate.acknowledged, isFalse);
      expect(gate.expired, isTrue);
      expect(gate.complete, isFalse);
    },
  );

  test(
    'second clock read before acknowledgement catches expiry rollback and throw',
    /** Sample ngay trước commit phải chặn clock thay đổi sau schema validation. */
    () {
      for (final fault in ['expired', 'backward', 'throw']) {
        var reads = 0;
        var inject = false;
        /** Chỉ sample thứ4 lỗi để test bắt đúng guard cuối trước ACK.
         * Output: elapsed giả hoặc lỗi synthetic, không phải clock App.
         */
        Duration read() {
          reads++;
          if (inject && reads >= 4) {
            if (fault == 'throw') {
              throw StateError('SYNTHETIC_UNTRUSTED_CLOCK_MESSAGE');
            }
            return fault == 'expired'
                ? const Duration(seconds: 6)
                : Duration.zero;
          }
          return const Duration(seconds: 1);
        }

        final gate = NativeMembershipCheckpoint(elapsed: read);
        gate.begin(stages.first);
        gate.receipt();
        inject = true;
        expect(gate.acknowledge({'stage': stages.first}), isFalse);
        expect(gate.expired, isTrue);
        expect(gate.receipt(), isEmpty);
        expect(gate.acknowledged, isFalse);
      }
    },
  );

  test(
    'clock throw at admission is contained by a fixed error',
    /** Raw exception từ clock test không được ra SDK status hoặc lỗi begin. */
    () {
      final gate = NativeMembershipCheckpoint(
        elapsed:
            /** Clock fault chỉ thuộc dependency test, không có credential thật. */
            () => throw StateError('SYNTHETIC_UNTRUSTED_CLOCK_MESSAGE'),
      );
      StateError? failure;
      try {
        gate.begin(stages.first);
      } on StateError catch (error) {
        failure = error;
      }
      expect(failure?.message, 'NATIVE_MEMBERSHIP_CHECKPOINT_ORDER_INVALID');
      expect(gate.expired, isTrue);
      expect(gate.receipt(), isEmpty);
    },
  );

  test(
    'receipt sampling detects backward clock before acknowledgement',
    /** Clock từng tiến rồi lùi phải hủy local proof vĩnh viễn. */
    () {
      final clock = MembershipTestClock();
      final gate = NativeMembershipCheckpoint(elapsed: clock.read);
      gate.begin(stages.first);
      clock.elapsed = const Duration(seconds: 2);
      expect(gate.receipt()['checkpointRemainingMilliseconds'], 3000);
      clock.elapsed = const Duration(seconds: 1);
      expect(gate.receipt(), isEmpty);
      expect(gate.acknowledge({'stage': stages.first}), isFalse);
      expect(gate.expired, isTrue);
    },
  );

  test(
    'premature clear and cancel invalidate a committed local acknowledgement',
    /** Local cancel không được để getter complete hoặc ACK cũ còn được dùng. */
    () {
      final early = NativeMembershipCheckpoint();
      early.begin(stages.first);
      expect(
        /** Clear trước ACK là lỗi protocol, chưa phải timeout hay terminal DB. */
        early.endPause,
        throwsStateError,
      );
      expect(early.expired, isTrue);
      final canceled = NativeMembershipCheckpoint();
      canceled.begin(stages.first);
      expect(canceled.acknowledge({'stage': stages.first}), isTrue);
      canceled.cancel();
      canceled.cancel();
      expect(canceled.acknowledged, isFalse);
      expect(canceled.complete, isFalse);
      expect(canceled.receipt(), isEmpty);
      expect(canceled.expired, isTrue);
    },
  );

  test(
    'committed acknowledgement stays stable until next admission',
    /** Clock fault sau ACK chỉ được quan sát khi có admission mới, không đổi ACK đã trả. */
    () {
      var throwClock = false;
      final gate = NativeMembershipCheckpoint(
        elapsed:
            /** Sample ban đầu hợp lệ, case chủ động bật lỗi sau commit. */
            () {
              if (throwClock) {
                throw StateError('SYNTHETIC_UNTRUSTED_CLOCK_MESSAGE');
              }
              return Duration.zero;
            },
      );
      gate.begin(stages.first);
      expect(gate.acknowledge({'stage': stages.first}), isTrue);
      throwClock = true;
      expect(gate.acknowledged, isTrue);
      expect(gate.expired, isFalse);
      expect(gate.receipt(), isEmpty);
      gate.endPause();
      expect(
        /** Stage kế phải sample clock lại và fail-closed nếu clock hỏng. */
        () => gate.begin(stages[1]),
        throwsStateError,
      );
      expect(gate.complete, isFalse);
    },
  );

  test(
    'default elapsed source is an advancing real Stopwatch',
    /** Clock mặc định phải tiến thực, không phụ thuộc tester pump hoặc wallclock chỉnh tay. */
    () async {
      final gate = NativeMembershipCheckpoint();
      gate.begin(stages.first);
      final before = gate.receipt()['checkpointRemainingMilliseconds'] as int;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final after = gate.receipt()['checkpointRemainingMilliseconds'] as int;
      expect(before, inInclusiveRange(1, 5000));
      expect(after, lessThan(before));
      expect(gate.acknowledge({'stage': stages.first}), isTrue);
      gate.endPause();
    },
  );
}
