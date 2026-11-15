import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../../core/validation/uuid_validation.dart';
import '../../workspaces/data/available_workspace_page.dart';
import '../../workspaces/data/workspace_access_detail.dart';
import 'app_auth_failure.dart';
import 'app_login_response.dart';
import 'full_session_profile.dart';

/// Boundary mạng không admission session; repository vẫn phải xác minh identity và storage ACK.
abstract interface class AppAuthApi {
  /// Gửi đúng một login Android, không lưu credential hoặc tự retry.
  /// Input
  /// Param: email — input gốc để provider chuẩn hóa/validate.
  /// Param: password — secret nguyên chuỗi chỉ trong RAM của intent.
  /// Output: DTO success đã kiểm hoặc AppAuthFailure an toàn.
  Future<AppLoginResponse> login(String email, String password);

  /// Kiểm bearer với server;403 limited là typed failure, không full profile.
  /// Input
  /// Param: token — đúng bearer của intent/session đang được repository giữ.
  /// Output: full profile đã kiểm cấu trúc, chưa là admission của login intent.
  Future<FullSessionProfile> getProfile(String token);

  /// Thu hồi đúng bearer đã cấp, không thay bằng token của account mới hoặc tự replay.
  /// Input
  /// Param: token — bearer cần revoke, không nhận identity/workspace làm authority.
  /// Errors: failure typed; unknown không chứng minh đã logout server.
  Future<void> logout(String token);
}

/// Capability bootstrap/recheck workspace, tách khỏi base auth và không giữ bearer.
abstract interface class AppWorkspaceApi {
  /// Đọc trang ACTIVE bằng bearer của repository, không suy quyền từ summary.
  /// Input
  /// Param: token — bearer thuộc intent hiện tại, không cookie/context Web.
  /// Param: cursor — opaque cursor nguyên bản, null cho trang đầu.
  /// Output: trang đã kiểm wire/schema, chưa là workspace selection đã recheck.
  Future<AvailableWorkspacePage> listWorkspaces(String token, {String? cursor});

  /// Recheck workspace đã chọn với server trước khi coordinator mở session summary.
  /// Input
  /// Param: token — bearer hiện tại do repository sở hữu.
  /// Param: workspaceId — UUID cần đọc, không là bằng chứng membership.
  /// Output: detail đúng định danh request, chưa thay guard server cho resource tiếp theo.
  Future<WorkspaceAccessDetail> getWorkspace(String token, String workspaceId);
}

/// Capability đổi password tách khỏi base auth để limited flow không có quyền workspace mặc định.
abstract interface class AppPasswordApi {
  /// Gửi đúng một mutation; backend quyết policy và credential đúng/sai, không trim/replay.
  /// Input
  /// Param: token — bearer full/limited của intent hiện tại.
  /// Param: currentPassword — secret nguyên bản; legacy ngắn không bị transport tự loại.
  /// Param: newPassword — secret mới nguyên bản, không lưu/log hoặc tự nâng scope sau ACK.
  /// Errors: typed failure; unknown không chứng minh mutation chưa áp dụng.
  Future<void> changePassword(
    String token,
    String currentPassword,
    String newPassword,
  );
}

/// Adapter HTTPS dùng chung guards, sở hữu client riêng và không giữ token/cookie giữa các intent.
final class HttpAppAuthApi
    implements AppAuthApi, AppWorkspaceApi, AppPasswordApi {
  /// Chốt origin cố định và boundary tạo client để kiểm lỗi mạng mà không dùng server giả làm E2E.
  /// Input
  /// Param: baseUri — origin-only HTTPS đã được cấu hình, không query/path/userInfo/fragment.
  /// Param: createClient — factory client riêng mỗi operation; mặc định kiểm TLS của SDK.
  /// Param: timeout — total deadline UX dương tối đa15s; test có thể giảm, không tăng budget.
  HttpAppAuthApi(
    Uri baseUri, {
    HttpClient Function()? createClient,
    Duration timeout = const Duration(seconds: 15),
  }) : _baseUri = baseUri,
       _createClient = createClient ?? HttpClient.new,
       _timeout = timeout {
    if (baseUri.scheme != 'https' ||
        !baseUri.hasAuthority ||
        baseUri.host.isEmpty ||
        baseUri.userInfo.isNotEmpty ||
        baseUri.hasQuery ||
        baseUri.hasFragment ||
        (baseUri.path.isNotEmpty && baseUri.path != '/') ||
        baseUri.port < 1 ||
        baseUri.port > 65535) {
      throw ArgumentError('INVALID_AUTH_API_ORIGIN');
    }
    if (timeout <= Duration.zero || timeout > const Duration(seconds: 15)) {
      throw ArgumentError('INVALID_AUTH_REQUEST_TIMEOUT');
    }
  }

  final Uri _baseUri;
  final HttpClient Function() _createClient;
  final Duration _timeout;

  /// Gửi login bearer-channel của Android; chưa lưu token hoặc đổi UI từ adapter.
  /// Input
  /// Param: email — input email nguyên bản cho provider.
  /// Param: password — secret trong RAM, không trim/normalize/log.
  /// Output: DTO Android đã kiểm hoặc failure an toàn.
  @override
  Future<AppLoginResponse> login(String email, String password) => _request(
    _AuthOperation.login,

    /// Param: value — body200 đã kiểm transport; Output: DTO có token68, không admission session.
    (value) {
      final result = AppLoginResponse.fromJson(value);
      if (!_isBearer(result.token))
        throw const FormatException('PROTOCOL_ERROR');
      return result;
    },
    body: {'email': email, 'password': password, 'clientType': 'ANDROID'},
  );

  /// Đọc full profile bằng đúng bearer, không cho limited response trở thành full.
  /// Input
  /// Param: token — bearer của session cần kiểm, không lấy từ cookie.
  /// Output: full profile hoặc typed failure để repository xử lý restore.
  @override
  Future<FullSessionProfile> getProfile(String token) => _request(
    _AuthOperation.profile,
    FullSessionProfile.fromJson,
    token: token,
  );

  /// Revoke đúng token và chỉ xác nhận khi204/empty/no-store, không tự gửi lại mutation.
  /// Input
  /// Param: token — bearer cũ cần revoke, không đọc token khác từ storage.
  /// Errors: failure an toàn; timeout/malformed có thể unknown.
  @override
  Future<void> logout(String token) async {
    await _request<Object?>(
      _AuthOperation.logout,

      /// Param: value — null chỉ sau204/zero bytes; Output: không giữ response metadata.
      (value) => value,
      token: token,
    );
  }

  /// Đọc trang ACTIVE mặc định bằng đúng bearer; cursor được URI codec giữ nguyên nghĩa.
  /// Input
  /// Param: token — bearer của intent cần kiểm.
  /// Param: cursor — opaque query cursor không normalize.
  /// Output: page đã kiểm schema; lỗi typed không biến offline thành empty.
  @override
  Future<AvailableWorkspacePage> listWorkspaces(
    String token, {
    String? cursor,
  }) => _request(
    _AuthOperation.workspaceList,
    AvailableWorkspacePage.fromJson,
    token: token,
    cursor: cursor,
  );

  /// Recheck detail theo UUID path, đối chiếu identity không phân biệt hex case của provider.
  /// Input
  /// Param: token — bearer hiện tại.
  /// Param: workspaceId — UUID path cần recheck.
  /// Output: detail bất biến đúng UUID; Errors: validation trước factory hoặc protocol khi response lệch id.
  @override
  Future<WorkspaceAccessDetail> getWorkspace(
    String token,
    String workspaceId,
  ) => _request(
    _AuthOperation.workspaceDetail,

    /// Chặn response workspace khác trước khi repository/coordinator nhận snapshot.
    /// Input
    /// Param: value — body200 đã kiểm wire, chưa tin identity chỉ vì HTTP success.
    /// Output: snapshot giữ nguyên id wire, binding theo UUID semantics.
    (value) {
      final result = WorkspaceAccessDetail.fromJson(value);
      if (result.id.toLowerCase() != workspaceId.toLowerCase()) {
        throw const FormatException('PROTOCOL_ERROR');
      }
      return result;
    },
    token: token,
    workspaceId: workspaceId,
  );

  /// Gửi một password mutation nguyên chuỗi;204 là ACK server, không tự đổi admission/storage.
  /// Input
  /// Param: token — bearer của intent.
  /// Param: currentPassword — secret hiện tại chỉ trong RAM.
  /// Param: newPassword — secret mới chỉ trong RAM.
  /// Errors: typed failure, unknown không được auto POST lại hoặc tự promote limited.
  @override
  Future<void> changePassword(
    String token,
    String currentPassword,
    String newPassword,
  ) async {
    await _request<Object?>(
      _AuthOperation.password,

      /// Input
      /// Param: value — null sau204/zero bytes; Output: không giữ metadata hoặc password.
      (value) => value,
      token: token,
      body: {'currentPassword': currentPassword, 'newPassword': newPassword},
    );
  }

  /// Sở hữu deadline/client tới cuối một operation; không chia sẻ state hoặc tự retry.
  /// Input
  /// Param: operation — enum nội bộ giữ method/path/success status cố định.
  /// Param: decode — parser DTO thuần chỉ gọi sau kiểm wire và deadline.
  /// Param: token — bearer của operation, null riêng login.
  /// Param: body — body JSON literal của operation, không là URL hoặc authority.
  /// Param: cursor — opaque cursor chỉ dùng list, null không tự thành empty query.
  /// Param: workspaceId — UUID detail, kiểm trước URI build/factory để không chèn path.
  /// Output: DTO/empty ACK; Errors: failure an toàn, POST mất kết quả giữ unknown.
  Future<T> _request<T>(
    _AuthOperation operation,
    T Function(Object?) decode, {
    String? token,
    Map<String, Object?>? body,
    String? cursor,
    String? workspaceId,
  }) async {
    final budget = _RequestBudget(_timeout);
    HttpClient? client;
    try {
      if (token != null && !_isBearer(token)) {
        throw const AppAuthFailure(AppAuthFailureKind.protocol);
      }
      if (operation == _AuthOperation.workspaceDetail &&
          (workspaceId == null ||
              workspaceId.length != 36 ||
              !isUuid(workspaceId))) {
        throw const AppAuthFailure(AppAuthFailureKind.validation);
      }
      // URI build/percent-encoding nằm trong Stopwatch chung; không nối cursor untrusted vào URL thô.
      // https://api.dart.dev/dart-core/Uri/replace.html
      final uri = _baseUri.replace(
        path: operation == _AuthOperation.workspaceDetail
            ? '${operation.path}/$workspaceId'
            : operation.path,
        queryParameters: cursor == null ? null : {'cursor': cursor},
      );
      if (utf8.encode(uri.toString()).length > 64 * 1024) {
        throw const AppAuthFailure(AppAuthFailureKind.validation);
      }
      final bytes = body == null ? null : utf8.encode(jsonEncode(body));
      //64KiB của request contract tính UTF-8 bytes, không đếm Dart code units hoặc codepoints.
      if (bytes != null && bytes.length > 64 * 1024) {
        throw const AppAuthFailure(AppAuthFailureKind.validation);
      }
      budget.check();
      client = _createClient();
      budget.check();
      // Tắt proxy mặc định của SDK để không đọc environment hoặc chuyển bearer qua proxy ngoài cấu hình.
      client.findProxy = null;
      client.connectionTimeout = _timeout;
      final pending = _exchange(
        client,
        operation,
        uri,
        decode,
        token,
        bytes,
        budget,
      );
      final remaining = _timeout - budget.watch.elapsed;
      final result = await pending.timeout(
        remaining > Duration.zero ? remaining : Duration.zero,
      );
      budget.check(); // Timer có thể đến muộn khi event loop bận; không nhận success quá hạn.
      return result;
    } on AppAuthFailure {
      rethrow;
    } catch (_) {
      // Không giữ exception SDK/TLS/URL; mất ACK chỉ unknown sau khi bắt đầu gửi POST.
      throw AppAuthFailure(
        AppAuthFailureKind.networkUnavailable,
        outcomeUnknown: operation.isMutation && budget.sent,
      );
    } finally {
      budget.cancelled = true;
      client?.close(force: true);
    }
  }

  /// Thực hiện đúng một request và kiểm từng async boundary để late Future không gửi/nhận intent mới.
  /// Input
  /// Param: client — HTTP client chỉ thuộc operation này, TLS mặc định không bypass.
  /// Param: operation — route/method/status literal, không nhận Location từ server.
  /// Param: uri — URL cùng origin đã build/encode/cap trong request budget, không do response quyết định.
  /// Param: decode — parser không có storage hoặc navigation side effect.
  /// Param: token — bearer đã kiểm, không đưa vào query/cookie.
  /// Param: bytes — JSON bytes đã cap64KiB, null khi body phải vắng.
  /// Param: budget — Stopwatch/cancellation fence chung, không reset theo read.
  /// Output: result đã kiểm hoặc failure; body cap áp dụng sau decompression của SDK.
  Future<T> _exchange<T>(
    HttpClient client,
    _AuthOperation operation,
    Uri uri,
    T Function(Object?) decode,
    String? token,
    List<int>? bytes,
    _RequestBudget budget,
  ) async {
    final request = await client.openUrl(operation.method, uri);
    budget.check(); // openUrl có thể hoàn tất sau timeout dù client đã được force-close.
    request.followRedirects = false;
    request.maxRedirects = 0;
    request.persistentConnection = false;
    request.cookies.clear();
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    if (token != null)
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.contentLength = bytes?.length ?? 0;
    if (bytes != null) request.headers.contentType = ContentType.json;
    budget.check();
    budget.sent = true; // Đặt trước first write/close vì lỗi socket không chứng minh server chưa nhận dữ liệu.
    if (bytes != null) request.add(bytes);
    budget.check();
    final response = await request.close();
    budget.check();
    try {
      final headers = response.headers;
      if (_singleHeader(headers, HttpHeaders.cacheControlHeader) !=
              'no-store' ||
          headers[HttpHeaders.setCookieHeader] != null ||
          headers['x-auth-context-id'] != null ||
          headers['x-csrf-token'] != null) {
        throw const FormatException('PROTOCOL_ERROR');
      }
      //128KiB là cap byte stream thực được consume, không tin Content-Length hoặc số ký tự JSON.
      const maxResponseBytes = 128 * 1024;
      if (response.contentLength > maxResponseBytes)
        throw const FormatException('PROTOCOL_ERROR');
      final payload = BytesBuilder(copy: false);
      await for (final chunk in response) {
        budget.check();
        if (chunk.length > maxResponseBytes - payload.length) {
          throw const FormatException('PROTOCOL_ERROR');
        }
        payload.add(chunk);
      }
      budget.check();
      Object? body;
      if (response.statusCode == operation.successStatus &&
          operation.successStatus == 204) {
        if (payload.length != 0) throw const FormatException('PROTOCOL_ERROR');
      } else {
        final contentType = _contentType(headers);
        final charset = contentType.charset?.toLowerCase();
        if (contentType.mimeType != 'application/json' ||
            (charset != null && charset != 'utf-8')) {
          throw const FormatException('PROTOCOL_ERROR');
        }
        body = jsonDecode(
          utf8.decode(payload.takeBytes(), allowMalformed: false),
        );
      }
      budget.check();
      if (response.statusCode != operation.successStatus) {
        if (!operation.acceptsError(response.statusCode, body))
          throw const FormatException('PROTOCOL_ERROR');
        throw AppAuthFailure.fromResponse(
          response.statusCode,
          {
            'cache-control': 'no-store',
            if (headers['retry-after'] != null)
              'retry-after': _singleHeader(headers, 'retry-after')!,
          },
          body,
          mutation: operation.isMutation,
        );
      }
      final result = decode(body);
      budget.check(); // Parse/DTO có thể chiếm CPU tới sau deadline khi timeout callback chưa chạy.
      return result;
    } on FormatException {
      throw AppAuthFailure(
        AppAuthFailureKind.protocol,
        outcomeUnknown: operation.isMutation,
      );
    }
  }
}

/// Các operation đã có provider contract; enum không cho caller truyền URL/method/status tùy ý.
enum _AuthOperation {
  login('POST', '/api/v1/auth/login', 200),
  profile('GET', '/api/v1/me', 200),
  logout('POST', '/api/v1/auth/logout', 204),
  workspaceList('GET', '/api/v1/workspaces', 200),
  workspaceDetail('GET', '/api/v1/workspaces', 200),
  password('POST', '/api/v1/auth/password', 204);

  /// Ghép route literal với đúng status để response của operation khác không bị nhận nhầm.
  /// Input
  /// Param: method — HTTP verb nội bộ, không do input user chọn.
  /// Param: path — path absolute bắt đầu/api/v1 trên origin cố định.
  /// Param: successStatus — status duy nhất được parse thành success.
  const _AuthOperation(this.method, this.path, this.successStatus);
  final String method;
  final String path;
  final int successStatus;

  /// Output: POST có thể commit khi mất response; GET không được coi là mutation.
  bool get isMutation => method == 'POST';

  /// Chặn status/code đúng toàn cục nhưng sai operation, trước khi coordinator suy session hoặc credential.
  /// Input
  /// Param: status — HTTP status thật, không lấy từ JSON.
  /// Param: body — JSON bounded đã decode; chỉ đọc code, không lưu raw body.
  /// Output: true khi cặp code/status có trong response contract của operation này.
  bool acceptsError(int status, Object? body) {
    if (body is! Map<String, dynamic> || body['error'] is! Map<String, dynamic>)
      return false;
    final code = (body['error'] as Map<String, dynamic>)['code'];
    // Capability mới có allowlist riêng; không dùng predicate kiểu !=profile làm nới ba endpoint cũ.
    if (this == workspaceList) {
      return switch ((status, code)) {
        (400, 'CURSOR_INVALID' || 'VALIDATION_ERROR') ||
        (401, 'SESSION_EXPIRED' || 'SESSION_REVOKED') ||
        (403, 'PASSWORD_CHANGE_REQUIRED' || 'FORBIDDEN') ||
        (409, 'AUTH_CONTEXT_MISMATCH') ||
        (422, 'VALIDATION_ERROR') ||
        (503, 'SERVICE_UNAVAILABLE') => true,
        _ => false,
      };
    }
    if (this == workspaceDetail) {
      return switch ((status, code)) {
        (400, 'VALIDATION_ERROR') ||
        (401, 'SESSION_EXPIRED' || 'SESSION_REVOKED') ||
        (403, 'PASSWORD_CHANGE_REQUIRED' || 'FORBIDDEN') ||
        (409, 'AUTH_CONTEXT_MISMATCH') ||
        (404, 'RESOURCE_NOT_FOUND') ||
        (503, 'SERVICE_UNAVAILABLE') => true,
        _ => false,
      };
    }
    if (this == password) {
      return switch ((status, code)) {
        (400 || 413 || 415 || 422, 'VALIDATION_ERROR') ||
        (401, 'AUTH_INVALID' || 'SESSION_EXPIRED' || 'SESSION_REVOKED') ||
        (403, 'CSRF_INVALID') ||
        (409, 'AUTH_CONTEXT_MISMATCH') ||
        (429, 'RATE_LIMITED') ||
        (503, 'SERVICE_UNAVAILABLE') => true,
        _ => false,
      };
    }
    return switch ((status, code)) {
      (400, 'VALIDATION_ERROR') || (503, 'SERVICE_UNAVAILABLE') => true,
      (413 || 415 || 422, 'VALIDATION_ERROR') => this != profile,
      (401, 'AUTH_INVALID') => this == login,
      (401, 'SESSION_EXPIRED' || 'SESSION_REVOKED') => this != login,
      (403, 'PASSWORD_CHANGE_REQUIRED') => this == profile,
      (403, 'CSRF_INVALID') => this != profile,
      (409, 'AUTH_CONTEXT_MISMATCH') => this != login,
      (429, 'RATE_LIMITED') => this != profile,
      _ => false,
    };
  }
}

/// Deadline process-local, không phụ thuộc giờ tường/clock user và không tự nhận late completion.
final class _RequestBudget {
  /// Bắt đầu Stopwatch trước serialization/factory để không reset budget ở async boundary.
  /// Input
  /// Param: limit — total deadline đã kiểm trong constructor API.
  _RequestBudget(this.limit);
  final Duration limit;
  final watch = Stopwatch()..start();
  bool cancelled = false;
  bool sent = false;

  /// Chặn continuation sau timeout hoặc quá hạn do timer bị trễ, trước send/parse/return.
  /// Errors: TimeoutException chỉ có mã cố định và được outer boundary map thành failure an toàn.
  void check() {
    if (cancelled || watch.elapsed >= limit)
      throw TimeoutException('AUTH_REQUEST_DEADLINE');
  }
}

/// Kiểm Bearer token68 theo RFC6750; full-match chống newline/control và không sửa secret để gửi lại.
/// Input
/// Param: token — bearer trong RAM, không log vào lỗi.
/// Output: false trước openUrl hoặc trước return login DTO nếu không thể dùng trong Authorization.
bool _isBearer(String token) {
  final match = RegExp(r'^[A-Za-z0-9._~+/\-]+=*$').firstMatch(token);
  return match != null && match.start == 0 && match.end == token.length;
}

/// Đọc duy nhất một header value, không làm sạch multivalue không rõ ràng để tạo PASS giả.
/// Input
/// Param: headers — metadata của đúng response, không xuất sang model/UI.
/// Param: name — tên header literal cần kiểm.
/// Output: null khi vắng; Errors: FormatException khi header trùng hoặc list rỗng.
String? _singleHeader(HttpHeaders headers, String name) {
  final values = headers[name];
  if (values == null) return null;
  if (values.length != 1) throw const FormatException('PROTOCOL_ERROR');
  return values.single;
}

/// Chỉ đổi lỗi parser header thành protocol; lỗi stream/connection vẫn do outer boundary phân loại mạng.
/// Input
/// Param: headers — header response đang xử lý, không đọc hoặc giữ metadata Web.
/// Output: media type đã parse; Errors: FormatException cố định khi thiếu/sai Content-Type.
ContentType _contentType(HttpHeaders headers) {
  try {
    return ContentType.parse(
      _singleHeader(headers, HttpHeaders.contentTypeHeader) ?? '',
    );
  } on HttpException {
    throw const FormatException('PROTOCOL_ERROR');
  }
}
