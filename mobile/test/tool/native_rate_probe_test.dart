import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/support/native_rate_probe.dart';

const stages = [
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

/// Clock giả chỉ thuộc host unit; scenario thật không truyền clock thay Stopwatch.
final class Clock {
  Duration elapsed = Duration.zero;

  /// Output: một sample monotonic hữu hạn do từng boundary test kiểm soát.
  Duration read() => elapsed;
}

/// Tạo observer ở cùng epoch cho bảng tolerance, không server/App clock override.
NativeRateObservation observation({int retry = 4}) => NativeRateObservation(
  submittedAt: const Duration(milliseconds: 990),
  observedAt: const Duration(seconds: 1),
  retryAfterSeconds: retry,
);

/// Sample private chỉ số/visibility, không UI text, identity hoặc credential.
void sample(
  NativeRateObservation probe,
  int milliseconds,
  int remaining, {
  bool card = true,
  bool form = false,
}) => probe.sample(
  at: Duration(milliseconds: milliseconds),
  remainingSeconds: remaining,
  cooldownVisible: card,
  formVisible: form,
);

void main() {
  test(
    'checkpoint commits once and receipt disappears before pause cleanup',
    () {
      final clock = Clock();
      final gate = NativeRateCheckpoint(elapsed: clock.read);
      for (final stage in stages) {
        gate.begin(stage);
        expect(gate.receipt(), {
          'checkpoint': stage,
          'checkpointRemainingMilliseconds': 5000,
        });
        expect(gate.acknowledge({'stage': stage, 'extra': 'x'}), isFalse);
        expect(gate.acknowledge({}), isFalse);
        expect(gate.acknowledge({'stage': 'invalid'}), isFalse);
        expect(
          gate.acknowledge({'stage': stage, 'isolateId': 'isolates/1'}),
          isTrue,
        );
        // Không pump hoặc endPause trước khi kiểm status/replay của cùng ACK.
        expect(gate.acknowledged, isTrue);
        expect(gate.receipt(), isEmpty);
        expect(gate.acknowledge({'stage': stage}), isFalse);
        clock.elapsed += const Duration(seconds: 6);
        expect(gate.expired, isFalse);
        gate.endPause();
      }
      expect(gate.complete, isTrue);
    },
  );

  test('checkpoint floor receipt and expiry reject late acknowledgement', () {
    for (final micros in [4999001, 5000000, 5000001]) {
      final clock = Clock();
      final gate = NativeRateCheckpoint(elapsed: clock.read);
      gate.begin(stages.first);
      clock.elapsed = Duration(microseconds: micros);
      expect(gate.receipt(), isEmpty);
      expect(gate.acknowledge({'stage': stages.first}), isFalse);
      expect(gate.expired, isTrue);
      expect(gate.complete, isFalse);
      expect(() => gate.begin(stages.first), throwsStateError);
    }
    final clock = Clock();
    final gate = NativeRateCheckpoint(elapsed: clock.read);
    gate.begin(stages.first);
    clock.elapsed = const Duration(microseconds: 4998999);
    expect(gate.receipt()['checkpointRemainingMilliseconds'], 1);
    expect(gate.acknowledge({'stage': stages.first}), isTrue);
  });

  test('checkpoint reads monotonic time again immediately before commit', () {
    var reads = 0;
    var expiryOnNextRead = false;
    Duration elapsed() {
      reads++;
      if (expiryOnNextRead && reads >= 4) return const Duration(seconds: 5);
      return Duration.zero;
    }

    final gate = NativeRateCheckpoint(elapsed: elapsed);
    gate.begin(stages.first);
    gate.receipt();
    expiryOnNextRead = true;
    expect(gate.acknowledge({'stage': stages.first}), isFalse);
    expect(gate.receipt(), isEmpty);
    expect(gate.complete, isFalse);
  });

  test('checkpoint rejects overlap, order changes and backward clock', () {
    final overlap = NativeRateCheckpoint();
    overlap.begin(stages.first);
    expect(() => overlap.begin(stages[1]), throwsStateError);
    expect(overlap.acknowledge({'stage': stages.first}), isFalse);
    final order = NativeRateCheckpoint();
    expect(() => order.begin(stages[1]), throwsStateError);
    expect(order.receipt(), isEmpty);
    final clock = Clock();
    final backward = NativeRateCheckpoint(elapsed: clock.read);
    backward.begin(stages.first);
    clock.elapsed = const Duration(microseconds: -1);
    expect(backward.receipt(), isEmpty);
    expect(backward.acknowledge({'stage': stages.first}), isFalse);
  });

  test('default checkpoint uses actual advancing Stopwatch', () async {
    final gate = NativeRateCheckpoint();
    gate.begin(stages.first);
    final initial = gate.receipt()['checkpointRemainingMilliseconds'] as int;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final later = gate.receipt()['checkpointRemainingMilliseconds'] as int;
    expect(initial, inInclusiveRange(1, 5000));
    expect(later, lessThan(initial));
    expect(gate.acknowledge({'stage': stages.first}), isTrue);
    gate.endPause();
  });

  test(
    'countdown supports second quantization without allowing early form',
    () {
      final probe = observation(retry: 1);
      sample(probe, 1000, 1);
      sample(probe, 1010, 0, card: false, form: true);
      expect(probe.complete, isFalse);
      final early = NativeRateObservation(
        submittedAt: Duration.zero,
        observedAt: const Duration(milliseconds: 100),
        retryAfterSeconds: 10,
      );
      sample(early, 100, 10);
      sample(early, 6000, 4);
      expect(
        () => sample(early, 7999, 0, card: false, form: true),
        throwsStateError,
      );
    },
  );

  test('observation finishes at max observed900 or form return plus2', () {
    final probe = observation();
    sample(probe, 1000, 4);
    sample(probe, 2000, 3);
    sample(probe, 3000, 2);
    sample(probe, 4000, 1);
    sample(probe, 5000, 0, card: false, form: true);
    // Không bỏ qua khoảng mù đến phút15: mỗi mẫu cách1s, không pump fake900s.
    for (var ms = 6000; ms <= 902000; ms += 1000) {
      sample(probe, ms, 0, card: false, form: true);
    }
    expect(probe.complete, isFalse);
    sample(probe, 902999, 0, card: false, form: true);
    expect(probe.complete, isFalse);
    sample(probe, 903000, 0, card: false, form: true);
    expect(probe.complete, isTrue);
  });

  test('late form return still requires two seconds after that sample', () {
    final probe = NativeRateObservation(
      submittedAt: Duration.zero,
      observedAt: Duration.zero,
      retryAfterSeconds: 900,
    );
    for (var second = 0; second <= 900; second++) {
      sample(probe, second * 1000, second == 900 ? 1 : 900 - second);
    }
    sample(probe, 901000, 0, card: false, form: true);
    expect(probe.complete, isFalse);
    sample(probe, 902000, 0, card: false, form: true);
    expect(probe.complete, isFalse);
    sample(probe, 903000, 0, card: false, form: true);
    expect(probe.complete, isTrue);
  });

  test(
    'countdown rejects stale, increase, late card and inconsistent visibility',
    () {
      final scenarios = <void Function(NativeRateObservation)>[
        (probe) => sample(probe, 4001, 4),
        (probe) {
          sample(probe, 2000, 3);
          sample(probe, 2100, 4);
        },
        (probe) {
          sample(probe, 5000, 1);
          sample(probe, 7001, 1);
        },
        (probe) => sample(probe, 1001, 4, form: true),
        (probe) => sample(probe, 1001, 0, card: false),
        (probe) => sample(probe, 1001, 0),
        (probe) => sample(probe, 1001, 5),
        (probe) => sample(probe, 1001, 1),
      ];
      for (final scenario in scenarios) {
        final probe = observation();
        sample(probe, 1000, 4);
        expect(() => scenario(probe), throwsStateError);
        expect(() => sample(probe, 1100, 4), throwsStateError);
        expect(probe.complete, isFalse);
      }
    },
  );

  test(
    'observation rejects invalid epoch, backwards samples and blind intervals',
    () {
      for (final retry in [0, -1, 901]) {
        expect(() => observation(retry: retry), throwsArgumentError);
      }
      expect(
        () => NativeRateObservation(
          submittedAt: const Duration(seconds: 2),
          observedAt: const Duration(seconds: 1),
          retryAfterSeconds: 1,
        ),
        throwsArgumentError,
      );
      final backward = observation();
      sample(backward, 1000, 4);
      expect(() => sample(backward, 999, 4), throwsStateError);
      final blind = observation();
      sample(blind, 1000, 4);
      expect(
        () => sample(blind, 7001, 0, card: false, form: true),
        throwsStateError,
      );
      final initialBlind = NativeRateObservation(
        submittedAt: Duration.zero,
        observedAt: Duration.zero,
        retryAfterSeconds: 900,
      );
      expect(() => sample(initialBlind, 6001, 894), throwsStateError);
    },
  );
  test(
    'countdown bounds have exact microsecond boundaries without blind gaps',
    () {
      for (final micros in [7999999, 8000000, 8000001]) {
        final probe = NativeRateObservation(
          submittedAt: Duration.zero,
          observedAt: const Duration(milliseconds: 100),
          retryAfterSeconds: 10,
        );
        sample(probe, 100, 10);
        sample(probe, 6000, 4);
        void unlock() => probe.sample(
          at: Duration(microseconds: micros),
          remainingSeconds: 0,
          cooldownVisible: false,
          formVisible: true,
        );
        if (micros < 8000000) {
          expect(unlock, throwsStateError);
        } else {
          unlock();
        }
      }
      for (final micros in [5999999, 6000000, 6000001]) {
        final probe = observation();
        sample(probe, 1000, 4);
        sample(probe, 5000, 1);
        void card() => probe.sample(
          at: Duration(microseconds: micros),
          remainingSeconds: 1,
          cooldownVisible: true,
          formVisible: false,
        );
        if (micros > 6000000) {
          expect(card, throwsStateError);
        } else {
          card();
        }
      }
      final stale = NativeRateObservation(
        submittedAt: Duration.zero,
        observedAt: Duration.zero,
        retryAfterSeconds: 900,
      );
      sample(stale, 0, 898);
      // Countdown còn trong bounds và gap<6s; chỉ plateau>3s làm fail, không dùng guard khác thay proof.
      expect(() => sample(stale, 3001, 898), throwsStateError);
    },
  );
}
