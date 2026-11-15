import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../lib/features/auth/data/full_session_profile.dart';

/// Kiểm lỗi boundary cố định để payload hoặc email không bị đính kèm khi parse thất bại.
/// Input
/// Param: value — body tổng hợp không hợp lệ, không dữ liệu account thật.
void expectProfileProtocolError(Object? value) {
  try {
    FullSessionProfile.fromJson(value);
  } on FormatException catch (error) {
    expect(error.message, 'PROTOCOL_ERROR');
    expect(error.source, isNull);
    return;
  }
  fail('Malformed full profile was accepted');
}

/// Kiểm body /me theo fixture chung; parse discovery không có nghĩa login intent đã được xác nhận.
void checkFullProfileConsumer() {
  final fixture = jsonDecode(
    File('../contracts/fixtures/auth/scenarios.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  expect(fixture['contractVersion'], '0.2.1');
  var cases = 0;
  var successes = 0;
  var failures = 0;
  Map<String, dynamic>? full;
  for (final scenario in fixture['scenarios'] as List<dynamic>) {
    if (scenario['operationId'] != 'getMe') continue;
    final response = scenario['response'] as Map<String, dynamic>;
    if (response['status'] == 200) {
      final body = response['body'] as Map<String, dynamic>;
      final profile = FullSessionProfile.fromJson(body);
      expect(profile.userId, body['id']);
      expect(profile.email, body['email']);
      expect(profile.mustChangePassword, isFalse);
      expect(profile.displayTimezone, body['displayTimezone']);
      expect(profile.preferencesRevision, body['preferencesRevision']);
      if (scenario['id'] == 'CT-AUTH-ME-FULL') full = body;
      successes++;
    } else {
      expectProfileProtocolError(response['body']);
      failures++;
    }
    cases++;
  }
  expect(successes, 2);
  expect(failures, 6);
  expect(full, isNotNull);
  final body = full!;
  for (final value in <Object?>[null, [], 'body', 0, true]) {
    expectProfileProtocolError(value);
    cases++;
  }
  for (final field in [
    'id',
    'email',
    'mustChangePassword',
    'displayTimezone',
    'preferencesRevision',
  ]) {
    expectProfileProtocolError({...body}..remove(field));
    cases++;
    for (final value in <Object?>[null, [], <String, Object?>{}]) {
      expectProfileProtocolError({...body, field: value});
      cases++;
    }
  }
  for (final field in ['id', 'email', 'displayTimezone']) {
    for (final value in <Object?>[true, 1]) {
      expectProfileProtocolError({...body, field: value});
      cases++;
    }
  }
  for (final value in [
    '',
    'bad-id',
    '11111111111141118111111111111111',
    '11111111-1111-9111-8111-111111111111',
    '11111111-1111-4111-7111-111111111111',
    ' 11111111-1111-4111-8111-111111111111',
  ]) {
    expectProfileProtocolError({...body, 'id': value});
    cases++;
  }
  for (final value in <Object?>[true, 'false', 0, 1]) {
    expectProfileProtocolError({...body, 'mustChangePassword': value});
    cases++;
  }
  for (final value in <Object?>[false, 0, -1, '1', 1.5]) {
    expectProfileProtocolError({...body, 'preferencesRevision': value});
    cases++;
  }
  expectProfileProtocolError({'me': body, 'limited': false});
  cases++;
  final editable = {
    ...body,
    'id': 'AAAAAAAA-AAAA-8AAA-BAAA-AAAAAAAAAAAA',
    'email': '  Member@Example.test  ',
    'displayTimezone': 'Asia/Ho_Chi_Minh',
    'preferencesRevision': 2,
    'role': 'GLOBAL_ADMIN',
    'futureField': <String, Object?>{'grant': 'ALL'},
  };
  final profile = FullSessionProfile.fromJson(editable);
  editable['email'] = 'changed@example.test';
  expect(profile.userId, 'AAAAAAAA-AAAA-8AAA-BAAA-AAAAAAAAAAAA');
  expect(profile.email, '  Member@Example.test  ');
  expect(profile.displayTimezone, 'Asia/Ho_Chi_Minh');
  expect(profile.preferencesRevision, 2);
  expect(profile.mustChangePassword, isFalse);
  expect(profile.toString(), isNot(contains(profile.email)));
  cases++;
  // Catalogue IANA và ngữ nghĩa địa chỉ do provider kiểm; DTO chỉ giữ string giống consumer Web.
  final structural = FullSessionProfile.fromJson({
    ...body,
    'email': '',
    'displayTimezone': '',
  });
  expect(structural.email, isEmpty);
  expect(structural.displayTimezone, isEmpty);
  cases++;
  stdout.writeln(
    'PASS $cases full-profile consumer cases (synthetic body; no session admission/API/storage).',
  );
}

/// Đăng ký kiểm contract consumer vào runner Flutter hiện có, không thêm dependency.
void main() {
  test(
    'full session profile shared fixtures and malformed payloads',
    checkFullProfileConsumer,
  );
}
