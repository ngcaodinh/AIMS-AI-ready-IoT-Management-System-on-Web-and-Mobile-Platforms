import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../lib/core/validation/password_policy.dart';

/// So cùng oracle Rust/Web, không lấy validation client làm bằng chứng server hoặc đăng nhập thật.
void checkPasswordPolicy() {
  final fixture = jsonDecode(
    File('../contracts/fixtures/auth/password-policy.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  expect(fixture['policyVersion'], 1);
  for (final example in fixture['cases'] as List<dynamic>) {
    for (final entry in {
      PasswordPurpose.login: 'loginError',
      PasswordPurpose.current: 'currentError',
      PasswordPurpose.newPassword: 'newError',
    }.entries) {
      final result = validatePassword(example['password'] as String, entry.key);
      expect(
        result?.code,
        example[entry.value],
        reason: '${example['id']}:${entry.value}',
      );
      if (result != null) expect(result.message, isNotEmpty);
    }
  }
}

/// Đăng ký validator contract test vào Flutter runner sẵn có, không dependency mới.
void main() {
  test(
    'password policy matches shared cross-platform cases',
    checkPasswordPolicy,
  );
}
