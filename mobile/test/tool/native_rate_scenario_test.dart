import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/support/native_rate_scenario.dart';

import 'package:nexa_iot/features/auth/data/app_auth_failure.dart';
import 'package:nexa_iot/features/auth/data/app_session_state.dart';
import 'package:nexa_iot/features/auth/presentation/app_auth_application.dart';
import 'package:nexa_iot/features/auth/presentation/login_screen.dart';
import 'package:nexa_iot/features/auth/presentation/login_view_state.dart';
import 'package:nexa_iot/ui/nexa_auth_theme.dart';

/// Metadata synthetic để kiểm freshness; không API/token/store hoặc account thật.
AppSessionState state(int generation, {AppAuthFailure? failure}) =>
    AppSessionState(
      phase: AppSessionPhase.signedOut,
      generation: generation,
      failure: failure,
    );

/// Parser sản phẩm thật đọc envelope tổng hợp, không mock typed mapping theo kết quả muốn có.
AppAuthFailure rateFailure({
  int status = 429,
  String code = 'RATE_LIMITED',
  String? retry = '900',
}) => AppAuthFailure.fromResponse(
  status,
  {'cache-control': 'no-store', if (retry != null) 'retry-after': retry},
  {
    'error': {
      'code': code,
      'message': 'synthetic',
      'correlationId': 'synthetic',
      'details': <String, Object?>{},
    },
  },
  mutation: true,
);

/// Render component sản phẩm với theme đã có; chỉ test card parser, không gọi đây là auth E2E.
Widget card(String title, {List<Widget> details = const []}) => MaterialApp(
  theme: nexaAuthTheme(Brightness.dark),
  home: AuthStatusScreen(
    key: const ValueKey('app-cooldown'),
    title: title,
    description: 'Đã có nhiều yêu cầu. Hãy chờ rồi chủ động thử lại.',
    waiting: true,
    details: details,
  ),
);

void main() {
  test(
    'rate packet references clear even when TLS or main fails before UI',
    () async {
      final packet = <String, Object?>{
        'password': 'Aa1${'a' * 32}',
        'wrongPassword': 'Aa2${'b' * 32}',
      };
      await expectLater(
        withNativeRateCredentials(packet, () async {
          throw StateError('EARLY_SYNTHETIC_FAILURE');
        }),
        throwsStateError,
      );
      expect(packet['password'], '');
      expect(packet['wrongPassword'], '');
    },
  );
  test(
    'credential cleanup awaits the same body operation before clearing',
    () async {
      final packet = <String, Object?>{
        'password': 'Aa1${'a' * 32}',
        'wrongPassword': 'Aa2${'b' * 32}',
      };
      final source = Completer<void>();
      final operation = withNativeRateCredentials(packet, () => source.future);
      await Future<void>.delayed(Duration.zero);
      expect(packet['password'], isNotEmpty);
      expect(packet['wrongPassword'], isNotEmpty);
      source.complete();
      await operation;
      expect(packet['password'], '');
      expect(packet['wrongPassword'], '');
    },
  );
  test(
    'fresh failure needs busy, two generations and distinct state/failure',
    () {
      final failure = AppAuthFailure(AppAuthFailureKind.invalidCredentials);
      final before = state(1);
      final after = state(2, failure: failure);
      verifyNativeRateRejection(
        before: before,
        after: after,
        generationBefore: 3,
        generationAfter: 5,
        observedBusy: true,
        expected: AppAuthFailureKind.invalidCredentials,
      );
      for (final entry in [
        (before, after, 3, 3, true),
        (before, after, 3, 5, false),
        (after, after, 3, 5, true),
        (state(1, failure: failure), after, 3, 5, true),
        (
          before,
          state(
            1,
            failure: AppAuthFailure(AppAuthFailureKind.invalidCredentials),
          ),
          3,
          5,
          true,
        ),
        (before, state(2, failure: rateFailure()), 3, 5, true),
      ]) {
        expect(
          () => verifyNativeRateRejection(
            before: entry.$1,
            after: entry.$2,
            generationBefore: entry.$3,
            generationAfter: entry.$4,
            observedBusy: entry.$5,
            expected: AppAuthFailureKind.invalidCredentials,
          ),
          throwsStateError,
        );
      }
    },
  );

  test('typed429 requires status/code/header agreement from actual parser', () {
    final before = state(1);
    final valid = rateFailure();
    verifyNativeRateRejection(
      before: before,
      after: state(2, failure: valid),
      generationBefore: 1,
      generationAfter: 3,
      observedBusy: true,
      expected: AppAuthFailureKind.rateLimited,
    );
    for (final invalid in [
      rateFailure(status: 401),
      rateFailure(code: 'AUTH_INVALID'),
      rateFailure(retry: null),
      rateFailure(retry: '0'),
      rateFailure(retry: '901'),
      rateFailure(retry: 'bad'),
    ]) {
      expect(
        () => verifyNativeRateRejection(
          before: before,
          after: state(2, failure: invalid),
          generationBefore: 1,
          generationAfter: 3,
          observedBusy: true,
          expected: AppAuthFailureKind.rateLimited,
        ),
        throwsStateError,
      );
    }
  });

  test('rate fixture rejects missing or reused synthetic wrong secret', () {
    final packet = {
      'password': 'Aa1${'a' * 32}',
      'wrongPassword': 'Aa2${'b' * 32}',
    };
    expect(validNativeRateCredentials(packet), isTrue);
    expect(
      validNativeRateCredentials({'password': packet['password']}),
      isFalse,
    );
    expect(
      validNativeRateCredentials({
        'password': packet['password'],
        'wrongPassword': packet['password'],
      }),
      isFalse,
    );
    expect(
      validNativeRateCredentials({
        'password': packet['password'],
        'wrongPassword': 'short',
      }),
      isFalse,
    );
  });

  testWidgets('countdown reads rendered card and cross-checks coordinator', (
    tester,
  ) async {
    await tester.pumpWidget(card('Thử lại sau 899 giây'));
    final sample = readNativeRateUi(tester, coordinatorSeconds: 900);
    expect(sample.remainingSeconds, 899);
    expect(sample.cooldownVisible, isTrue);
    expect(sample.formVisible, isFalse);
    expect(
      () => readNativeRateUi(tester, coordinatorSeconds: 897),
      throwsStateError,
    );
    await tester.pumpWidget(card('Thử lại sau 1 giây'));
    expect(readNativeRateUi(tester, coordinatorSeconds: 0).remainingSeconds, 1);
    await tester.pumpWidget(card('Thử lại sau 2 giây'));
    expect(
      () => readNativeRateUi(tester, coordinatorSeconds: 0),
      throwsStateError,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'malformed, duplicate or missing rendered countdown fail closed',
    (tester) async {
      for (final title in [
        'Thử lại sau 0 giây',
        'Thử lại sau 901 giây',
        'Thử lại sau 01 giây',
        'Đang chờ',
      ]) {
        await tester.pumpWidget(card(title));
        expect(
          () => readNativeRateUi(tester, coordinatorSeconds: 1),
          throwsStateError,
        );
      }
      await tester.pumpWidget(
        card('Thử lại sau 4 giây', details: const [Text('Thử lại sau 4 giây')]),
      );
      expect(
        () => readNativeRateUi(tester, coordinatorSeconds: 4),
        throwsStateError,
      );
      await tester.pumpWidget(
        card('Tiêu đề sai', details: const [Text('Thử lại sau 4 giây')]),
      );
      expect(
        () => readNativeRateUi(tester, coordinatorSeconds: 4),
        throwsStateError,
      );
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      expect(
        () => readNativeRateUi(tester, coordinatorSeconds: 0),
        throwsStateError,
      );
    },
  );

  testWidgets(
    'form is only observable after cooldown has actually reached zero',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: nexaAuthTheme(Brightness.dark),
          home: LoginScreen(
            state: LoginViewState.ready,
            onSubmit: (email, password) async {},
          ),
        ),
      );
      final sample = readNativeRateUi(tester, coordinatorSeconds: 0);
      expect(sample.remainingSeconds, 0);
      expect(sample.formVisible, isTrue);
      expect(
        () => readNativeRateUi(tester, coordinatorSeconds: 1),
        throwsStateError,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('whole native cap prevents UI effects before main is ready', (
    tester,
  ) async {
    var checkpoints = 0;
    await expectLater(
      verifyNativeRateScenario(
        tester,
        {'password': 'Aa1${'a' * 32}', 'wrongPassword': 'Aa2${'b' * 32}'},
        elapsed: () => const Duration(seconds: 1260),
        checkpoint: (stage) async {
          checkpoints++;
        },
        markStage: (stage) {},
      ),
      throwsStateError,
    );
    expect(checkpoints, 0);
  });
}
