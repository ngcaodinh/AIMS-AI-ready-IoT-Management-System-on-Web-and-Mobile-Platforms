import '../../../core/validation/uuid_validation.dart';

/// Body /me full đã kiểm cấu trúc; không là bằng chứng login intent hoặc phiên được admission.
/// Không cung cấp serialization hoặc toString chứa dữ liệu cá nhân.
final class FullSessionProfile {
  /// Giữ snapshot scalar bất biến, không giữ raw body hay metadata cấp quyền.
  /// Input
  /// Param: userId — UUID nguyên bản từ provider, chưa được đối chiếu với login intent.
  /// Param: email — string từ server, không chuẩn hóa hoặc suy quyền.
  /// Param: displayTimezone — string của preference, provider chịu kiểm catalogue IANA.
  /// Param: preferencesRevision — số nguyên dương, không tự quyết định cache đang mới.
  const FullSessionProfile._({
    required this.userId,
    required this.email,
    required this.displayTimezone,
    required this.preferencesRevision,
  });

  final String userId;
  final String email;
  final String displayTimezone;
  final int preferencesRevision;

  /// Output: full MeProfile chỉ cho false; limited response phải được xử lý ngoài factory này.
  bool get mustChangePassword => false;

  /// Kiểm body trực tiếp của MeProfile0.2.1, không nhận login wrapper hoặc ép kiểu dữ liệu.
  /// Input
  /// Param: value — JSON không đáng tin; caller phải kiểm HTTP status/transport trước factory.
  /// Output: DTO bất biến; caller vẫn kiểm identity, generation và trạng thái phiên trước điều hướng.
  /// Errors: FormatException cố định không chứa payload, email hoặc định danh.
  factory FullSessionProfile.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('PROTOCOL_ERROR');
    }
    final userId = value['id'];
    final email = value['email'];
    final displayTimezone = value['displayTimezone'];
    final preferencesRevision = value['preferencesRevision'];
    if (userId is! String ||
        !isUuid(userId) ||
        email is! String ||
        value['mustChangePassword'] != false ||
        displayTimezone is! String ||
        preferencesRevision is! int ||
        preferencesRevision < 1) {
      throw const FormatException('PROTOCOL_ERROR');
    }
    // Extension role/context không cấp quyền; discovery200 vẫn cần coordinator xác nhận đúng intent.
    return FullSessionProfile._(
      userId: userId,
      email: email,
      displayTimezone: displayTimezone,
      preferencesRevision: preferencesRevision,
    );
  }
}
