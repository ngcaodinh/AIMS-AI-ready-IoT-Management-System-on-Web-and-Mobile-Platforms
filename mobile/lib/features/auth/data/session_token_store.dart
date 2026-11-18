import 'dart:convert';

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

/// Giá trị phiên được lưu cùng expiry để logout offline có thể giới hạn thời gian credential.
final class StoredSessionCredential {
  /// Giữ bearer và thời hạn do server trả về, không suy expiry từ cấu trúc token.
  /// Input
  /// Param: token — bearer riêng của phiên; không được log hoặc chuyển cho UI.
  /// Param: expiresAt — expiry server đã parse; null chỉ dành cho key legacy chưa có metadata.
  const StoredSessionCredential({required this.token, required this.expiresAt});

  final String token;
  final DateTime? expiresAt;
}

/// Revoke intent bền vững; token chỉ được worker gửi tới endpoint logout đã định.
final class PendingLogoutIntent {
  /// Tạo snapshot bất biến để retry chỉ có thể nhắm đúng phiên ban đầu.
  /// Input
  /// Param: intentId — định danh local của lần logout, không chứa danh tính người dùng.
  /// Param: sessionToken — bearer cần thu hồi; phải luôn ở secure storage khi pending.
  /// Param: expiresAt — expiry server nếu biết; null chỉ có thể đến từ phiên legacy.
  /// Param: attemptCount — số lần đã ghi bền vững trong chu kỳ retry hiện tại.
  /// Param: nextAttemptAt — thời điểm sớm nhất worker được phép gửi lại.
  const PendingLogoutIntent({
    required this.intentId,
    required this.sessionToken,
    required this.expiresAt,
    required this.attemptCount,
    required this.nextAttemptAt,
  });

  final String intentId;
  final String sessionToken;
  final DateTime? expiresAt;
  final int attemptCount;
  final DateTime nextAttemptAt;

  /// Parse đúng schema đóng của secure outbox, không mặc định record hỏng là không tồn tại.
  /// Input
  /// Param: value — JSON đã giải mã từ key riêng trong secure storage.
  /// Output: intent bất biến hoặc lỗi read an toàn nếu field thiếu/sai kiểu.
  factory PendingLogoutIntent.fromJson(Object? value) {
    // Schema đóng giữ expiresAt bắt buộc và ngăn field thay thế làm record legacy giả dạng hợp lệ.
    if (value is! Map<String, dynamic> ||
        value.length != 6 ||
        !value.keys.toSet().containsAll({
          'version',
          'intentId',
          'sessionToken',
          'expiresAt',
          'attemptCount',
          'nextAttemptAt',
        }) ||
        value['version'] != 1 ||
        value['intentId'] is! String ||
        value['sessionToken'] is! String ||
        (value['expiresAt'] != null && value['expiresAt'] is! String) ||
        value['attemptCount'] is! int ||
        value['nextAttemptAt'] is! String) {
      throw const SessionStorageException(SessionStorageOperation.read);
    }
    final expiresAt = _parseStoredUtc(value['expiresAt']);
    final nextAttemptAt = _parseStoredUtc(value['nextAttemptAt']);
    final intent = PendingLogoutIntent(
      intentId: value['intentId'] as String,
      sessionToken: value['sessionToken'] as String,
      expiresAt: expiresAt,
      attemptCount: value['attemptCount'] as int,
      nextAttemptAt: nextAttemptAt!,
    );
    if (!_isUsableIntent(intent)) {
      throw const SessionStorageException(SessionStorageOperation.read);
    }
    return intent;
  }

  /// Tạo payload cố định chỉ để mã hóa trực tiếp vào secure outbox.
  /// Output: map có thể encode nhưng vẫn chứa bearer secret; không log hoặc gửi ra khỏi storage boundary.
  Map<String, Object?> _toJson() => {
    'version': 1,
    'intentId': intentId,
    'sessionToken': sessionToken,
    'expiresAt': expiresAt?.toUtc().toIso8601String(),
    'attemptCount': attemptCount,
    'nextAttemptAt': nextAttemptAt.toUtc().toIso8601String(),
  };
}

/// Boundary giữ phiên và revoke outbox trong cùng OS secure storage, theo thứ tự ACK của repository.
abstract interface class SessionTokenStore {
  /// Đọc token cùng metadata để restore hoặc tạo revoke intent sau restart.
  /// Output: phiên lưu cục bộ hoặc null khi key thật sự vắng; không xác nhận server còn hiệu lực.
  /// Errors: SessionStorageException khi read/decode lỗi, không giả thành phiên mới.
  Future<StoredSessionCredential?> readSession();

  /// Lưu token sau response đã parse; caller chỉ admission sau khi plugin xác nhận write.
  /// Input
  /// Param: session — bearer và expiry server; không chứa profile hoặc quyền workspace.
  /// Errors: SessionStorageException; write có thể đã có side effect trước khi mất ACK.
  Future<void> writeSession(StoredSessionCredential session);

  /// Xóa riêng key phiên hiện hành, không đụng tới outbox hoặc installation proof.
  /// Errors: SessionStorageException; caller phải giữ state khóa tới khi nhận ACK.
  Future<void> deleteSession();

  /// Đọc revoke intent trước active session để startup không khôi phục account đang logout.
  /// Output: intent cần xử lý hoặc null; record hỏng là lỗi, không phải absent.
  /// Errors: SessionStorageException nếu key không giải mã/validate được.
  Future<PendingLogoutIntent?> readLogoutIntent();

  /// Ghi durable tombstone trước khi xóa active credential hoặc gửi request.
  /// Input
  /// Param: intent — đúng bearer/expiry cần thu hồi cùng trạng thái retry an toàn.
  /// Errors: SessionStorageException; caller không được xóa active key nếu write ACK chưa có.
  Future<void> writeLogoutIntent(PendingLogoutIntent intent);

  /// Xóa outbox chỉ sau 204 hoặc 401 terminal và active-key cleanup ACK.
  /// Errors: SessionStorageException; nếu thất bại startup sẽ retry cùng intent.
  Future<void> deleteLogoutIntent();
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
  static const _logoutIntentKey = 'logout_intent';

  /// Đọc token và expiry; raw token cũ được nhận diện như metadata legacy không rõ expiry.
  /// Output: session credential hoặc null thật; caller vẫn phải hỏi server trước admission.
  /// Errors: lỗi cố định khi native I/O hoặc schema persisted không hợp lệ.
  @override
  Future<StoredSessionCredential?> readSession() async {
    try {
      final stored = await _storage.read(key: _sessionKey);
      if (stored == null) return null;
      final decoded = _decodeSession(stored);
      if (decoded == null || !_isUsableToken(decoded.token)) {
        throw const SessionStorageException(SessionStorageOperation.read);
      }
      return decoded;
    } catch (_) {
      // Dữ liệu cũ/hỏng và lỗi native đều khóa restore; không fallback sang phiên rỗng.
      throw const SessionStorageException(SessionStorageOperation.read);
    }
  }

  /// Ghi token với expiry trong một giá trị secure duy nhất để tránh record nửa chừng.
  /// Input
  /// Param: session — dữ liệu đã parse; token không được sửa trước khi lưu.
  /// Errors: lỗi write cố định, bao gồm token không dùng được hoặc lỗi native.
  @override
  Future<void> writeSession(StoredSessionCredential session) async {
    if (!_isUsableToken(session.token) ||
        (session.expiresAt != null && !session.expiresAt!.isUtc)) {
      throw const SessionStorageException(SessionStorageOperation.write);
    }
    try {
      await _storage.write(
        key: _sessionKey,
        value: jsonEncode({
          'version': 1,
          'token': session.token,
          'expiresAt': session.expiresAt?.toIso8601String(),
        }),
      );
    } catch (_) {
      // ACK mất có thể xảy ra sau lưu; repository phải giữ quarantine và xử lý candidate.
      throw const SessionStorageException(SessionStorageOperation.write);
    }
  }

  /// Xóa đúng active-session key và chờ ACK; không xóa tombstone cần retry sau restart.
  /// Errors: lỗi delete cố định, không báo rằng server đã revoke.
  @override
  Future<void> deleteSession() async {
    try {
      await _storage.delete(key: _sessionKey);
    } catch (_) {
      throw const SessionStorageException(SessionStorageOperation.delete);
    }
  }

  /// Đọc tombstone secure trước token, reject record hỏng thay vì mở lại account cũ.
  /// Output: pending intent hoặc null; bearer chỉ đi vào repository để gọi logout.
  /// Errors: lỗi read cố định, không chứa payload/native detail.
  @override
  Future<PendingLogoutIntent?> readLogoutIntent() async {
    try {
      final stored = await _storage.read(key: _logoutIntentKey);
      if (stored == null) return null;
      return PendingLogoutIntent.fromJson(jsonDecode(stored));
    } catch (_) {
      throw const SessionStorageException(SessionStorageOperation.read);
    }
  }

  /// Kiểm record rồi ghi bearer trước active-key cleanup; quyền server chỉ mất sau khi revoke.
  /// Input
  /// Param: intent — bearer được giới hạn vào worker logout; expiry/retry không làm giảm quyền server.
  /// Errors: lỗi write cố định, kể cả record sai hoặc plugin lỗi.
  @override
  Future<void> writeLogoutIntent(PendingLogoutIntent intent) async {
    if (!_isUsableIntent(intent)) {
      throw const SessionStorageException(SessionStorageOperation.write);
    }
    try {
      await _storage.write(
        key: _logoutIntentKey,
        value: jsonEncode(intent._toJson()),
      );
    } catch (_) {
      throw const SessionStorageException(SessionStorageOperation.write);
    }
  }

  /// Xóa riêng tombstone sau terminal server response; không dùng deleteAll.
  /// Errors: lỗi delete cố định để caller giữ UI/recovery khóa.
  @override
  Future<void> deleteLogoutIntent() async {
    try {
      await _storage.delete(key: _logoutIntentKey);
    } catch (_) {
      throw const SessionStorageException(SessionStorageOperation.delete);
    }
  }
}

/// Giải mã credential JSON mới hoặc raw bearer legacy, kể cả chuỗi trùng JSON scalar; object mới phải đúng schema đã phát hành.
/// Input
/// Param: value — chuỗi đọc từ key secure, không được log khi parse lỗi.
/// Output: credential đầy đủ hoặc null khi schema không được nhận diện.
StoredSessionCredential? _decodeSession(String value) {
  Object? decoded;
  try {
    decoded = jsonDecode(value);
  } on FormatException {
    // Raw bearer là format trước khi expiry được persist; token vẫn được kiểm ở boundary.
    return _isUsableToken(value)
        ? StoredSessionCredential(token: value, expiresAt: null)
        : null;
  }
  if (decoded is! Map<String, dynamic>) {
    // Token legacy theo token68 có thể trông như bool/null/number; giữ nguyên chuỗi làm bearer.
    return _isUsableToken(value)
        ? StoredSessionCredential(token: value, expiresAt: null)
        : null;
  }
  if (decoded.length != 3 ||
      decoded['version'] != 1 ||
      decoded['token'] is! String ||
      (decoded['expiresAt'] != null && decoded['expiresAt'] is! String)) {
    return null;
  }
  final expiresAt = _parseStoredUtc(decoded['expiresAt']);
  return StoredSessionCredential(
    token: decoded['token'] as String,
    expiresAt: expiresAt,
  );
}

/// Parse timestamp canonical UTC để thiết bị không đổi timezone hoặc chuẩn hóa dữ liệu hỏng.
/// Input
/// Param: value — null cho legacy expiry, hoặc chuỗi UTC do server DTO đã kiểm.
/// Output: DateTime UTC hoặc null khi không có expiry; dữ liệu sai ném lỗi nội bộ đã được sanitize.
DateTime? _parseStoredUtc(Object? value) {
  if (value == null) return null;
  if (value is! String || !value.endsWith('Z')) {
    throw const SessionStorageException(SessionStorageOperation.read);
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null || !parsed.isUtc || parsed.toIso8601String() != value) {
    throw const SessionStorageException(SessionStorageOperation.read);
  }
  return parsed;
}

/// Kiểm invariants của outbox trước read/write để record hỏng không được retry bearer tùy ý.
/// Input
/// Param: intent — dữ liệu revoke intent đang nằm trong RAM.
/// Output: true khi identity, bearer, counter và timestamp có cấu trúc hợp lệ.
bool _isUsableIntent(PendingLogoutIntent intent) =>
    RegExp(r'^[A-Za-z0-9._-]{1,128}$').hasMatch(intent.intentId) &&
    _isUsableToken(intent.sessionToken) &&
    intent.attemptCount >= 0 &&
    intent.attemptCount <= 5 &&
    intent.nextAttemptAt.isUtc &&
    (intent.expiresAt == null || intent.expiresAt!.isUtc);

/// Kiểm token opaque không rỗng và không chứa ký tự có thể tách header.
/// Input
/// Param: token — secret trong RAM; không cố giải mã cấu trúc hoặc suy quyền từ nội dung.
/// Output: true khi không rỗng và không chứa ký tự whitespace/control.
bool _isUsableToken(String token) =>
    RegExp(r'^[A-Za-z0-9._~+/\-]+=*$').hasMatch(token);
