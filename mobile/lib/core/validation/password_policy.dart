/// Vai trò credential quyết định boundary; không áp composition mới lên password cũ khi login/verify.
enum PasswordPurpose { login, current, newPassword }

typedef PasswordValidationError = ({String code, String message});

const newPasswordHint =
    '9–128 ký tự, có chữ hoa, chữ thường và số (0–9). Khoảng trắng là một phần của mật khẩu.';

final _uppercase = RegExp(r'\p{Uppercase}', unicode: true);
final _lowercase = RegExp(r'\p{Lowercase}', unicode: true);
final _digit = RegExp(r'[0-9]');

/// Kiểm UX đúng shared policy version1 bằng codepoints, không sửa hoặc giữ credential sau validation.
/// Input
/// Param: value — input nguyên bản, không trim/normalize hoặc log.
/// Param: purpose — login/current chỉ kiểm độ dài; newPassword cần hoa/thường/số như backend.
/// Output: lỗi code/message cố định hoặc null; không chứng minh entropy, auth hoặc quyền.
PasswordValidationError? validatePassword(
  String value,
  PasswordPurpose purpose,
) {
  final length = value.runes.length;
  final minimum = purpose == PasswordPurpose.current ? 1 : 9;
  if (length < minimum || length > 128) {
    final message = switch (purpose) {
      PasswordPurpose.current => 'Nhập mật khẩu hiện tại (1–128 ký tự).',
      PasswordPurpose.newPassword => 'Mật khẩu mới cần từ 9 đến 128 ký tự.',
      PasswordPurpose.login => 'Mật khẩu cần từ 9 đến 128 ký tự.',
    };
    return (code: 'LENGTH', message: message);
  }
  // Dùng Unicode binary properties giống Rust/Web, bao gồm tiếng Việt; chỉ thành phần số yêu cầu0–9.
  if (purpose == PasswordPurpose.newPassword &&
      (!_uppercase.hasMatch(value) ||
          !_lowercase.hasMatch(value) ||
          !_digit.hasMatch(value))) {
    return (
      code: 'FORMAT',
      message: 'Mật khẩu mới phải có chữ hoa, chữ thường và số (0–9).',
    );
  }
  return null;
}
