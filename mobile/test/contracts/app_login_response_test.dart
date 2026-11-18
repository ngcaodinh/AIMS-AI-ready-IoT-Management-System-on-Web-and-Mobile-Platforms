import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../lib/features/auth/data/app_login_response.dart';

/// Kiểm bất biến test mà không phụ thuộc assert vốn có thể bị tắt trong Dart CLI.
/// Input
/// Param: condition — điều kiện cần đúng, kiểm cả khi assert của CLI bị tắt.
/// Param: label — tên ca tổng hợp cố định, không có credential.
void verify(bool condition, String label) {
  if (!condition) throw StateError('FAILED: $label');
}

/// Xác nhận payload sai bị từ chối và lỗi không giữ body/token đầu vào.
/// Input
/// Param: value — JSON tổng hợp dùng kiểm boundary.
/// Param: label — tên ca cố định để báo lỗi an toàn.
void expectProtocolError(Object? value, String label) {
  try {
    AppLoginResponse.fromJson(value);
  } on FormatException catch (error) {
    verify(error.message == 'PROTOCOL_ERROR' && error.source == null, label);
    return;
  }
  throw StateError('Parser accepted invalid case: $label');
}

/// Chạy consumer contract bằng fixture dùng chung; không gọi API hay lưu token.
void runContractChecks() {
  final fixture = jsonDecode(
    // Flutter test dùng script bootstrap khác source; cwd theo lệnh chuẩn là mobile/.
    File('../contracts/fixtures/auth/scenarios.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  verify(fixture['contractVersion'] == '0.2.2', 'fixture version');
  final scenarios = fixture['scenarios'] as List<dynamic>;
  var count = 0;
  Map<String, dynamic>? full;
  for (final scenario in scenarios) {
    final id = scenario['id'] as String;
    if (id == 'CT-AUTH-ANDROID-FULL' || id == 'CT-AUTH-ANDROID-LIMITED') {
      final body = scenario['response']['body'] as Map<String, dynamic>;
      final result = AppLoginResponse.fromJson(body);
      verify(result.limited == body['limited'], '$id limited');
      verify(result.userId == body['me']['id'], '$id identity');
      verify(result.email == body['me']['email'], '$id email');
      verify(result.token == body['token'], '$id opaque token');
      verify(result.expiresAt.isUtc, '$id UTC');
      verify(!result.toString().contains(result.token), '$id no token logging');
      if (id == 'CT-AUTH-ANDROID-FULL') full = body;
      count++;
    } else if (id == 'CT-AUTH-WEB-FULL' || id == 'CT-AUTH-WEB-LIMITED') {
      expectProtocolError(scenario['response']['body'], id);
      count++;
    }
  }
  verify(count == 4 && full != null, 'required fixtures present');
  final body = full!;
  for (final field in ['me', 'expiresAt', 'limited', 'token']) {
    for (final value in [null, <String, Object?>{}, 17, <Object?>[]]) {
      expectProtocolError({...body, field: value}, 'invalid $field');
      count++;
    }
    expectProtocolError({...body}..remove(field), 'missing $field');
    count++;
  }
  for (final value in <Object?>[null, <Object?>[], 'body', 0]) {
    expectProtocolError(value, 'invalid root');
    count++;
  }
  for (final value in [
    '',
    'not-date',
    '2026-02-30T00:00:00Z',
    '2026-10-24',
    '2026-10-24T24:00:00Z',
    '2026-10-24T00:00:00+99:00',
  ]) {
    expectProtocolError({...body, 'expiresAt': value}, 'invalid expiry');
    count++;
  }
  for (final value in ['', ' ', 'token\r\nheader']) {
    expectProtocolError({...body, 'token': value}, 'invalid token');
    count++;
  }
  final profile = body['me'] as Map<String, dynamic>;
  for (final entry in <String, Object?>{
    'id': 'bad-id',
    'email': null,
    'mustChangePassword': 'false',
  }.entries) {
    expectProtocolError({
      ...body,
      'me': {...profile, entry.key: entry.value},
    }, 'invalid profile ${entry.key}');
    count++;
  }
  expectProtocolError({...body, 'limited': true}, 'limited mismatch');
  count++;
  final extended = AppLoginResponse.fromJson({
    ...body,
    'role': 'ADMIN',
    'extension': true,
  });
  verify(extended.userId == profile['id'], 'extensions do not grant authority');
  count++;
  stdout.writeln(
    'PASS $count Android login consumer cases (synthetic fixtures; no provider/storage/device).',
  );
}

/// Đăng ký consumer checks vào runner SDK sau khi scaffold có flutter_test; không thêm package test ngoài.
void main() {
  test(
    'Android login shared fixture and malformed response contract',
    runContractChecks,
  );
}
