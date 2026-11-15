import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Thao tác thất bại được công khai; không đưa mã/detail native vào UI hoặc log.
enum SessionStorageOperation { read, write, delete }

/// Lỗi boundary không giữ token, payload, exception gốc hoặc nguyên nhân nhạy cảm.
final class SessionStorageException implements Exception {
  /// Gắn lỗi với thao tác để caller khóa luồng phù hợp mà không cần đọc lỗi native.
  /// Input
  /// Param: operation — thao tác lỗi; không bảo đảm I/O chưa có side effect.
  const SessionStorageException(this.operation);

  final SessionStorageOperation operation;

  /// Trả mã ổn định chỉ chứa operation, an toàn khi trình bày lỗi kỹ thuật đã kiểm soát.
  /// Output: không chứa key, token hoặc thông tin nền tảng.
  @override
  String toString() => 'SESSION_STORAGE_${operation.name.toUpperCase()}';
}

/// Boundary lưu duy nhất bearer; repository phải tuần tự hóa theo account generation.
/// Giá trị đọc không chứng minh session còn hiệu lực hoặc quyền workspace.
abstract interface class SessionTokenStore {
  /// Đọc bearer để bootstrap với server; null chỉ có nghĩa key chưa tồn tại.
  /// Output: bearer trong RAM hoặc null; caller không được log hoặc serialize.
  /// Errors: SessionStorageException khi đọc/giải mã lỗi, không trả null giả.
  Future<String?> read();

  /// Lưu bearer đã parse; caller phải await trước khi hoàn tất bước lưu phiên.
  /// Input
  /// Param: token — bearer mới; không phải password, profile hoặc metadata quyền.
  /// Errors: SessionStorageException; write có thể đã có side effect trước lỗi ACK.
  Future<void> write(String token);

  /// Xóa bearer riêng của auth; không xóa installation proof hoặc key khác.
  /// Errors: SessionStorageException; caller phải giữ UI đóng dù cleanup chưa chắc chắn.
  Future<void> delete();
}

/// Adapter plugin Android, không cache plaintext, tự retry hoặc đổi trạng thái đăng nhập.
final class SecureSessionTokenStore implements SessionTokenStore {
  /// Dùng cấu hình cố định đã review; binding Flutter cần được khởi tạo trước I/O.
  const SecureSessionTokenStore();

  // Tách namespace và không tự reset khi key lỗi để bảo toàn dữ liệu/installation proof khác.
  // API11.2.0: https://pub.dev/documentation/flutter_secure_storage/latest/flutter_secure_storage/AndroidOptions/AndroidOptions.html
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      resetOnError: false,
      storageNamespace: 'nexa_auth_session_v1',
    ),
  );
  static const _sessionKey = 'session_token';

  /// Chỉ trả token có thể dùng trong header; lỗi native/dữ liệu hỏng không thành phiên vắng mặt.
  /// Output: bearer hoặc null thực từ plugin, chưa kiểm expiry/revocation với server.
  /// Errors: lỗi read cố định, không giữ exception/payload từ boundary nền tảng.
  @override
  Future<String?> read() async {
    try {
      final token = await _storage.read(key: _sessionKey);
      if (token != null && !_isUsableToken(token)) {
        throw const SessionStorageException(SessionStorageOperation.read);
      }
      return token;
    } catch (_) {
      // Codec/type/key errors đều đến từ boundary; không phát tán detail hoặc fallback plaintext.
      throw const SessionStorageException(SessionStorageOperation.read);
    }
  }

  /// Chặn bearer sai trước I/O và chỉ ACK sau plugin; không giả rollback nếu write lỗi.
  /// Input
  /// Param: token — bearer đã parse; không trim hoặc sửa secret để thử ghi lại.
  /// Errors: lỗi write cố định, bao gồm token không dùng được và lỗi native.
  @override
  Future<void> write(String token) async {
    if (!_isUsableToken(token)) {
      throw const SessionStorageException(SessionStorageOperation.write);
    }
    try {
      await _storage.write(key: _sessionKey, value: token);
    } catch (_) {
      // ACK mất có thể xảy ra sau khi đã lưu; repository xử lý unknown/revoke đúng phiên.
      throw const SessionStorageException(SessionStorageOperation.write);
    }
  }

  /// Xóa đúng key auth và chờ ACK; không dùng deleteAll vì có thể xóa proof cần giữ qua logout.
  /// Errors: lỗi delete cố định; không tự báo logout server hoặc cleanup đã hoàn tất.
  @override
  Future<void> delete() async {
    try {
      await _storage.delete(key: _sessionKey);
    } catch (_) {
      throw const SessionStorageException(SessionStorageOperation.delete);
    }
  }
}

/// Kiểm tối thiểu cho bearer opaque theo contract, ngăn whitespace/control trong Authorization.
/// Input
/// Param: token — secret trong RAM; không cố giải mã cấu trúc hoặc suy quyền từ nội dung.
/// Output: true khi không rỗng và không chứa ký tự có thể tách header.
bool _isUsableToken(String token) =>
    token.isNotEmpty && !RegExp(r'\s|[\x00-\x1f\x7f]').hasMatch(token);
