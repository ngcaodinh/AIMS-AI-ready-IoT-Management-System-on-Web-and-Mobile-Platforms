import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../lib/features/auth/data/app_auth_failure.dart';

const failureCanary = 'synthetic-private-error-data';
const errorHeaders = <String, String>{
  'Cache-Control': 'no-store',
  'Content-Type': 'application/json',
};

/// Tạo envelope tổng hợp với correlation opaque hợp lệ theo contract, không áp UUID ngoài yêu cầu.
/// Input
/// Param: code — mã lỗi contract cần map theo đúng status.
/// Output: raw fixture chỉ ở test; failure không được giữ hoặc stringify dữ liệu này.
Map<String, dynamic> errorEnvelope(String code) => {
  'error': {
    'code': code,
    'message': failureCanary,
    'details': <String, Object?>{},
    'correlationId': 'corr_synthetic_opaque',
  },
};

/// Kiểm status/code cùng nhau để lỗi hạ tầng không giả thành credential rejected hoặc session expired.
void checkStatusCodeMapping() {
  final cases = <(int, String, AppAuthFailureKind)>[
    (401, 'AUTH_INVALID', AppAuthFailureKind.invalidCredentials),
    (401, 'SESSION_EXPIRED', AppAuthFailureKind.sessionExpired),
    (401, 'SESSION_REVOKED', AppAuthFailureKind.sessionExpired),
    (
      403,
      'PASSWORD_CHANGE_REQUIRED',
      AppAuthFailureKind.passwordChangeRequired,
    ),
    (403, 'FORBIDDEN', AppAuthFailureKind.permissionDenied),
    (403, 'CSRF_INVALID', AppAuthFailureKind.permissionDenied),
    (409, 'AUTH_CONTEXT_MISMATCH', AppAuthFailureKind.conflict),
    (400, 'VALIDATION_ERROR', AppAuthFailureKind.validation),
    (413, 'VALIDATION_ERROR', AppAuthFailureKind.validation),
    (415, 'VALIDATION_ERROR', AppAuthFailureKind.validation),
    (422, 'VALIDATION_ERROR', AppAuthFailureKind.validation),
    (503, 'SERVICE_UNAVAILABLE', AppAuthFailureKind.unavailable),
  ];
  for (final entry in cases) {
    final failure = AppAuthFailure.fromResponse(
      entry.$1,
      errorHeaders,
      errorEnvelope(entry.$2),
    );
    expect(failure.kind, entry.$3);
    expect(failure.retryAfterSeconds, isNull);
    expect(failure.outcomeUnknown, isFalse);
    expect(failure.toString().contains(failureCanary), isFalse);
  }
}

/// Không dùng riêng mã body để bỏ qua status sai hoặc body malformed của proxy/provider.
void checkInconsistentAndUnknownErrors() {
  for (final entry in <(int, String)>[
    (200, 'AUTH_INVALID'),
    (401, 'SERVICE_UNAVAILABLE'),
    (503, 'AUTH_INVALID'),
    (429, 'AUTH_INVALID'),
    (418, 'SERVICE_UNAVAILABLE'),
    (401, failureCanary),
  ]) {
    final failure = AppAuthFailure.fromResponse(
      entry.$1,
      errorHeaders,
      errorEnvelope(entry.$2),
      mutation: true,
    );
    expect(failure.kind, AppAuthFailureKind.protocol);
    expect(failure.outcomeUnknown, isTrue);
    expect(failure.toString().contains(failureCanary), isFalse);
  }
}

/// Envelope thiếu/type sai không được admitted; message/correlation chỉ string, details phải object.
void checkMalformedEnvelopes() {
  final cases = <Object?>[
    null,
    [],
    failureCanary,
    1,
    {'error': null},
  ];
  for (final field in ['code', 'message', 'details', 'correlationId']) {
    final missing = errorEnvelope('AUTH_INVALID');
    (missing['error'] as Map<String, dynamic>).remove(field);
    cases.add(missing);
    final wrong = errorEnvelope('AUTH_INVALID');
    (wrong['error'] as Map<String, dynamic>)[field] = field == 'details'
        ? <Object?>[]
        : 7;
    cases.add(wrong);
  }
  for (final details in <Object?>[
    {'token': failureCanary},
    {'fieldErrors': 'invalid'},
    {
      'fieldErrors': [
        <String, Object?>{'path': '/password', 'code': 'NOT_DECLARED'},
      ],
    },
    {
      'fieldErrors': [
        <String, Object?>{'path': 1, 'code': 'FORMAT'},
      ],
    },
  ]) {
    final body = errorEnvelope('AUTH_INVALID');
    (body['error'] as Map<String, dynamic>)['details'] = details;
    cases.add(body);
  }
  cases.add({...errorEnvelope('AUTH_INVALID'), 'token': failureCanary});
  for (final body in cases) {
    final failure = AppAuthFailure.fromResponse(401, errorHeaders, body);
    expect(failure.kind, AppAuthFailureKind.protocol);
    expect(failure.toString().contains(failureCanary), isFalse);
  }
}

/// Retry-After dùng ASCII integer dương, không ngày/sign/Unicode digits hoặc arbitrary cap.
void checkRetryAfterStrictness() {
  for (final seconds in [1, 480, 999999999]) {
    final failure = AppAuthFailure.fromResponse(
      429,
      {...errorHeaders, 'rEtRy-AfTeR': '$seconds'},
      errorEnvelope('RATE_LIMITED'),
      mutation: true,
    );
    expect(failure.kind, AppAuthFailureKind.rateLimited);
    expect(failure.retryAfterSeconds, seconds);
    expect(failure.outcomeUnknown, isFalse);
  }
  for (final invalid in <String?>[
    null,
    '',
    '0',
    '-1',
    '+1',
    '1.5',
    '1e3',
    ' 2',
    '2 ',
    '١',
    'Mon, 26 Oct 2026 00:00:00 GMT',
  ]) {
    final failure = AppAuthFailure.fromResponse(429, {
      ...errorHeaders,
      if (invalid != null) 'Retry-After': invalid,
    }, errorEnvelope('RATE_LIMITED'));
    expect(failure.kind, AppAuthFailureKind.protocol);
  }
  final duplicate = AppAuthFailure.fromResponse(429, {
    ...errorHeaders,
    'Retry-After': '1',
    'retry-after': '2',
  }, errorEnvelope('RATE_LIMITED'));
  expect(duplicate.kind, AppAuthFailureKind.protocol);
}

/// Header names case-insensitive nhưng thiếu no-store hoặc trùng tên khác case phải fail closed.
void checkResponseHeaders() {
  final lower = AppAuthFailure.fromResponse(401, const {
    'cache-control': 'no-store',
    'content-type': 'application/json; charset=utf-8',
  }, errorEnvelope('AUTH_INVALID'));
  expect(lower.kind, AppAuthFailureKind.invalidCredentials);
  for (final headers in <Map<String, String>>[
    {'Content-Type': 'application/json'},
    {...errorHeaders, 'Cache-Control': 'public'},
    {...errorHeaders, 'cache-control': 'no-store'},
  ]) {
    expect(
      AppAuthFailure.fromResponse(
        401,
        headers,
        errorEnvelope('AUTH_INVALID'),
      ).kind,
      AppAuthFailureKind.protocol,
    );
  }
}

/// 503/malformed POST giữ unknown; known401/429 không khiến caller tự gọi lại mutation.
void checkMutationUncertaintyAndRedaction() {
  final unavailable = AppAuthFailure.fromResponse(
    503,
    errorHeaders,
    errorEnvelope('SERVICE_UNAVAILABLE'),
    mutation: true,
  );
  expect(unavailable.kind, AppAuthFailureKind.unavailable);
  expect(unavailable.outcomeUnknown, isTrue);
  final denied = AppAuthFailure.fromResponse(
    401,
    errorHeaders,
    errorEnvelope('AUTH_INVALID'),
    mutation: true,
  );
  expect(denied.outcomeUnknown, isFalse);
  for (final kind in AppAuthFailureKind.values) {
    final failure = AppAuthFailure(
      kind,
      retryAfterSeconds: 7,
      outcomeUnknown: true,
    );
    expect(failure.toString(), 'APP_AUTH_${kind.name.toUpperCase()}');
    expect(failure.toString().contains(failureCanary), isFalse);
  }
}

/// Đọc error examples từ fixtures 0.2.2; các fixture không thay bằng chứng provider hoặc client network.
void checkSharedErrorFixtures() {
  var cases = 0;
  for (final path in [
    '../contracts/fixtures/auth/scenarios.json',
    '../contracts/fixtures/auth/logout-scenarios.json',
  ]) {
    final fixture =
        jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    expect(fixture['contractVersion'], '0.2.2');
    for (final item in fixture['scenarios'] as List<dynamic>) {
      final response = item['response'] as Map<String, dynamic>;
      final status = response['status'] as int;
      if (status < 400) continue;
      final rawHeaders = response['headers'] as Map<String, dynamic>;
      final headers = <String, String>{...errorHeaders};
      var webMetadata = false;
      for (final entry in rawHeaders.entries) {
        if ([
          'set-cookie',
          'x-auth-context-id',
          'x-csrf-token',
        ].contains(entry.key.toLowerCase()))
          webMetadata = true;
        headers[entry.key] = entry.value.toString();
      }
      if (webMetadata) continue;
      final failure = AppAuthFailure.fromResponse(
        status,
        headers,
        response['body'],
      );
      expect(failure.kind == AppAuthFailureKind.protocol, isFalse);
      expect(failure.toString().contains(failureCanary), isFalse);
      cases++;
    }
  }
  expect(cases, greaterThan(0));
}

/// Đăng ký pure contract tests; không mở HTTP client hoặc truy cập session storage.
void main() {
  test('status and code must agree', checkStatusCodeMapping);
  test(
    'inconsistent status and unknown codes are protocol failures',
    checkInconsistentAndUnknownErrors,
  );
  test(
    'malformed envelope never admits a typed rejection',
    checkMalformedEnvelopes,
  );
  test(
    'retry after is strict and uncapped within integer range',
    checkRetryAfterStrictness,
  );
  test(
    'response headers are case insensitive and unambiguous',
    checkResponseHeaders,
  );
  test(
    'mutation uncertainty and string redaction are explicit',
    checkMutationUncertaintyAndRedaction,
  );
  test(
    'shared versioned error fixtures remain consumable',
    checkSharedErrorFixtures,
  );
}
