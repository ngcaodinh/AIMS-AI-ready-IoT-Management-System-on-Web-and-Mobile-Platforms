import '../../../core/validation/uuid_validation.dart';

/// Payload login Android đã kiểm kiểu; chỉ tồn tại trong RAM trước khi repository lưu an toàn.
/// Không cung cấp toJson/toString chứa token để tránh serialize hoặc log credential ngoài ý muốn.
final class AppLoginResponse {
  /// Chỉ factory kiểm contract được tạo giá trị; không dùng DTO làm bằng chứng quyền workspace.
  /// Input
  /// Param: userId — định danh người dùng đã kiểm UUID.
  /// Param: email — địa chỉ trả từ server, không dùng để suy quyền.
  /// Param: limited — chỉ cho phép đổi mật khẩu/logout khi true.
  /// Param: expiresAt — thời hạn UTC đã kiểm định dạng, chưa là kiểm phiên còn sống.
  /// Param: token — bearer chỉ giữ trong RAM tới khi repository ghi an toàn.
  const AppLoginResponse._({
    required this.userId,
    required this.email,
    required this.limited,
    required this.expiresAt,
    required this.token,
  });

  final String userId;
  final String email;
  final bool limited;
  final DateTime expiresAt;
  final String token;

  /// Kiểm response JSON thành công theo AppLoginSuccess0.2.1, không ép kiểu hoặc nhận Web cookie response.
  /// Input
  /// Param: value — JSON không đáng tin; caller phải kiểm HTTP status trước khi gọi factory.
  /// Output: DTO bất biến; expiry chỉ được parse, admission vẫn phải kiểm server/clock khi bootstrap.
  /// Errors: FormatException có mã cố định và không chứa payload, token hoặc email.
  factory AppLoginResponse.fromJson(Object? value) {
    if (value is! Map<String, dynamic>)
      throw const FormatException('PROTOCOL_ERROR');
    final profile = value['me'];
    final limited = value['limited'];
    final token = value['token'];
    if (profile is! Map<String, dynamic> ||
        limited is! bool ||
        token is! String ||
        token.isEmpty ||
        RegExp(r'\s|[\x00-\x1f\x7f]').hasMatch(token)) {
      throw const FormatException('PROTOCOL_ERROR');
    }
    final userId = profile['id'];
    final email = profile['email'];
    final mustChangePassword = profile['mustChangePassword'];
    if (userId is! String ||
        !isUuid(userId) ||
        email is! String ||
        mustChangePassword is! bool ||
        mustChangePassword != limited) {
      throw const FormatException('PROTOCOL_ERROR');
    }
    // Bỏ qua extension tương thích; role global hoặc context Web không thể cấp quyền cho DTO Android.
    return AppLoginResponse._(
      userId: userId,
      email: email,
      limited: limited,
      expiresAt: _parseExpiry(value['expiresAt']),
      token: token,
    );
  }
}

/// Parse RFC3339 có timezone và kiểm lịch trước vì DateTime.tryParse tự chuẩn hóa ngày/tháng vượt biên.
/// Input
/// Param: value — expiry từ wire, không tin string chỉ vì DateTime parse được.
/// Output: thời điểm UTC; không sửa expiry hoặc tự gia hạn phiên.
/// Errors: FormatException an toàn khi thiếu timezone, lịch sai hoặc kiểu không phải string.
DateTime _parseExpiry(Object? value) {
  if (value is! String) throw const FormatException('PROTOCOL_ERROR');
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:Z|([+-])(\d{2}):(\d{2}))$',
  ).firstMatch(value);
  if (match == null) throw const FormatException('PROTOCOL_ERROR');
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  final hour = int.parse(match[4]!);
  final minute = int.parse(match[5]!);
  final second = int.parse(match[6]!);
  final offsetHour = int.parse(match[8] ?? '0');
  final offsetMinute = int.parse(match[9] ?? '0');
  if (month < 1 ||
      month > 12 ||
      day < 1 ||
      day > DateTime.utc(year, month + 1, 0).day ||
      hour > 23 ||
      minute > 59 ||
      second > 59 ||
      offsetHour > 23 ||
      offsetMinute > 59) {
    throw const FormatException('PROTOCOL_ERROR');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw const FormatException('PROTOCOL_ERROR');
  return parsed.toUtc();
}
