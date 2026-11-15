/// Lỗi được phép đi tới repository/UI, không chứa response hoặc nguyên nhân native.
enum AppAuthFailureKind {
  invalidCredentials,
  sessionExpired,
  passwordChangeRequired,
  rateLimited,
  permissionDenied,
  conflict,
  cursorInvalid,
  resourceNotFound,
  validation,
  unavailable,
  networkUnavailable,
  protocol,
}

/// Chỉ giữ enum, số giây chờ và trạng thái mutation; không giữ raw error/token/profile.
final class AppAuthFailure implements Exception {
  /// Tạo lỗi an toàn cho các boundary đã phân loại, không phản chiếu dữ liệu không tin cậy.
  /// Input
  /// Param: kind — phân loại cố định để coordinator chọn state.
  /// Param: retryAfterSeconds — số giây từ Retry-After đã kiểm khi429.
  /// Param: outcomeUnknown — mutation có thể đã tới server, không được tự replay.
  const AppAuthFailure(
    this.kind, {
    this.retryAfterSeconds,
    this.outcomeUnknown = false,
  });

  final AppAuthFailureKind kind;
  final int? retryAfterSeconds;
  final bool outcomeUnknown;

  /// Đọc error envelope đúng status/header, chỉ giữ giá trị allowlist cần cho UI.
  /// Input
  /// Param: status — HTTP status của response đang xử lý.
  /// Param: headers — headers trong RAM, kiểm case-insensitive và không giữ lại.
  /// Param: body — JSON untrusted đã bị giới hạn byte ở transport.
  /// Param: mutation — true cho POST để lỗi protocol/503 giữ trạng thái chưa chắc chắn.
  /// Output: failure cố định; malformed không bị giả là credential rejected hoặc success.
  factory AppAuthFailure.fromResponse(
    int status,
    Map<String, String> headers,
    Object? body, {
    bool mutation = false,
  }) {
    final malformed = AppAuthFailure(
      AppAuthFailureKind.protocol,
      outcomeUnknown: mutation,
    );
    final normalized = <String, String>{};
    for (final entry in headers.entries) {
      final name = entry.key.toLowerCase();
      if (normalized.containsKey(name)) return malformed;
      normalized[name] = entry.value;
    }
    // App không nhận cookie hoặc capability Web, kể cả giá trị header rỗng.
    if (normalized['cache-control'] != 'no-store' ||
        normalized.containsKey('set-cookie') ||
        normalized.containsKey('x-auth-context-id') ||
        normalized.containsKey('x-csrf-token') ||
        body is! Map<String, dynamic> ||
        body.containsKey('token')) {
      return malformed;
    }
    final error = body['error'];
    if (error is! Map<String, dynamic> ||
        error['code'] is! String ||
        error['message'] is! String ||
        error['correlationId'] is! String ||
        !_validDetails(error['details'])) {
      return malformed;
    }
    final kind = switch ((status, error['code'])) {
      (401, 'AUTH_INVALID') => AppAuthFailureKind.invalidCredentials,
      (401, 'SESSION_EXPIRED' || 'SESSION_REVOKED') =>
        AppAuthFailureKind.sessionExpired,
      (403, 'PASSWORD_CHANGE_REQUIRED') =>
        AppAuthFailureKind.passwordChangeRequired,
      (403, 'FORBIDDEN' || 'CSRF_INVALID') =>
        AppAuthFailureKind.permissionDenied,
      (409, 'AUTH_CONTEXT_MISMATCH') => AppAuthFailureKind.conflict,
      (400, 'CURSOR_INVALID') => AppAuthFailureKind.cursorInvalid,
      (404, 'RESOURCE_NOT_FOUND') => AppAuthFailureKind.resourceNotFound,
      (400 || 413 || 415 || 422, 'VALIDATION_ERROR') =>
        AppAuthFailureKind.validation,
      (429, 'RATE_LIMITED') => AppAuthFailureKind.rateLimited,
      (503, 'SERVICE_UNAVAILABLE') => AppAuthFailureKind.unavailable,
      _ => AppAuthFailureKind.protocol,
    };
    if (kind == AppAuthFailureKind.protocol) return malformed;
    int? retryAfter;
    if (kind == AppAuthFailureKind.rateLimited) {
      final raw = normalized['retry-after'];
      if (raw == null || !RegExp(r'^[0-9]+$').hasMatch(raw)) return malformed;
      retryAfter = int.tryParse(raw);
      if (retryAfter == null || retryAfter < 1) return malformed;
    }
    return AppAuthFailure(
      kind,
      retryAfterSeconds: retryAfter,
      // 503 không chứng minh POST chưa commit;401/429 hợp lệ không bị đổi thành lỗi mạng.
      outcomeUnknown: mutation && kind == AppAuthFailureKind.unavailable,
    );
  }

  /// Output: mã enum an toàn, không có payload/header, token hoặc exception gốc.
  @override
  String toString() => 'APP_AUTH_${kind.name.toUpperCase()}';
}

/// Kiểm đúng schema details đóng của contract, không giữ fieldErrors hoặc nội dung để echo ra UI.
/// Input
/// Param: value — object details untrusted; fieldErrors là extension duy nhất đã định nghĩa.
/// Output: true khi required/type/enum đúng; unknown field trong details không được hợp thức hóa.
bool _validDetails(Object? value) {
  if (value is! Map<String, dynamic> ||
      value.keys.any(
        /// Param: key — tên field không tin cậy; Output: chỉ fieldErrors đã có trong contract.
        (key) => key != 'fieldErrors',
      )) {
    return false;
  }
  if (!value.containsKey('fieldErrors')) return true;
  final fields = value['fieldErrors'];
  if (fields is! List) return false;
  const codes = {
    'REQUIRED',
    'TYPE',
    'FORMAT',
    'LENGTH',
    'ENUM',
    'UNKNOWN_FIELD',
    'MALFORMED_JSON',
    'DUPLICATE_FIELD',
    'BODY_TOO_LARGE',
    'CONTENT_TYPE',
    'SAME_AS_CURRENT',
  };
  for (final field in fields) {
    if (field is! Map<String, dynamic> ||
        field.length != 2 ||
        field['path'] is! String ||
        field['code'] is! String ||
        !codes.contains(field['code'])) {
      return false;
    }
  }
  return true;
}
