import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../lib/features/auth/data/app_auth_api.dart';
import '../../lib/features/auth/data/app_auth_failure.dart';
import '../../lib/features/auth/data/app_login_response.dart';
import '../../lib/features/auth/data/full_session_profile.dart';
import '../../lib/features/workspaces/data/available_workspace_page.dart';

/// Kiểm invariant bằng lỗi cố định để không gắn payload hoặc credential vào diagnostic.
void verify(bool condition) {
  if (!condition) throw StateError('PROBE_FAILED');
}

/// Parse đúng DTO production từ body RAM; không HTTP/plugin/storage hoặc Flutter import.
/// Input
/// Param: operation — tên cố định appLogin/profile/workspaces của packet.
/// Param: body — JSON provider hoặc mutation cần kiểm.
/// Output: DTO đã kiểm schema, chưa là session admission hoặc authorization.
Object parse(String operation, Object? body) => switch (operation) {
  'appLogin' => AppLoginResponse.fromJson(body),
  'profile' => FullSessionProfile.fromJson(body),
  'workspaces' => AvailableWorkspacePage.fromJson(body),
  _ => throw StateError('PROBE_FAILED'),
};

/// Chụp projection scalar trong RAM để extension không thay giá trị DTO; không dùng stdout/log.
/// Input
/// Param: value — DTO production đã qua parser, có thể chứa token trong memory.
/// Output: JSON để so nội bộ, tuyệt đối không xuất ra ngoài probe.
String projection(Object value) => jsonEncode(switch (value) {
  AppLoginResponse() => [
    value.userId,
    value.email,
    value.limited,
    value.expiresAt.toIso8601String(),
    value.token,
  ],
  FullSessionProfile() => [
    value.userId,
    value.email,
    value.displayTimezone,
    value.preferencesRevision,
  ],
  AvailableWorkspacePage() => [
    [
      for (final row in value.items)
        [row.id, row.name, row.status, row.role, row.revision],
    ],
    value.nextCursor,
  ],
  _ => throw StateError('PROBE_FAILED'),
});

/// Chỉ nhận lỗi parser cố định, không raw source hoặc error giữ lại dữ liệu đầu vào.
/// Input
/// Param: operation — parser tương ứng schema đang kiểm.
/// Param: body — mutation tổng hợp từ provider body chỉ trong RAM.
void expectRejected(String operation, Object? body) {
  var rejected = false;
  try {
    parse(operation, body);
  } on FormatException catch (error) {
    rejected = error.message == 'PROTOCOL_ERROR' && error.source == null;
  }
  verify(rejected);
}

/// Clone JSON trong RAM để mỗi mutation độc lập và không sửa response provider gốc.
/// Input
/// Param: value — body JSON cần sao chép, có thể chứa credential nên không ghi file.
/// Output: object độc lập chỉ sống trong lifetime probe.
Map<String, dynamic> clone(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

/// Kiểm baseline, extension tương thích và required keys thiếu/null/sai kiểu.
/// Input
/// Param: operation — schema của envelope provider trong packet.
/// Param: envelope — response status/body được caller thu trực tiếp trong RAM.
/// Param: fields — required key; nextCursor cho phép null nhưng không được thiếu.
Object check(
  String operation,
  Map<String, dynamic> envelope,
  List<String> fields,
) {
  verify(envelope['status'] == 200);
  final body = envelope['body'] as Map<String, dynamic>;
  final baseline = parse(operation, body);
  final extended = clone(body)..['compatibilityExtension'] = true;
  verify(projection(parse(operation, extended)) == projection(baseline));
  for (final field in fields) {
    for (final mutation in [
      'missing',
      if (field != 'nextCursor') 'null',
      'type',
    ]) {
      final changed = clone(body);
      if (mutation == 'missing') {
        changed.remove(field);
      } else {
        changed[field] = mutation == 'null'
            ? null
            : field == 'items' || field == 'nextCursor'
            ? 17
            : <Object?>[];
      }
      expectRejected(operation, changed);
    }
  }
  return baseline;
}

/// Header RAM giữ multivalue để adapter production tự kiểm transport/content type như HTTP thật.
final class ProbeHeaders implements HttpHeaders {
  /// Nhận header nguyên bản từ provider, chỉ lowercase tên header theo HttpHeaders.
  ProbeHeaders(Map<String, dynamic> input) {
    for (final entry in input.entries) {
      final value = entry.value;
      values[entry.key.toLowerCase()] = value is List
          ? [for (final item in value) item as String]
          : [value as String];
    }
  }
  final values = <String, List<String>>{};

  /// Output: mọi value của tên header, giữ duplicate để production parser từ chối.
  @override
  List<String>? operator [](String name) => values[name.toLowerCase()];

  /// Ghi header request trong RAM, không serialize ra log hoặc file.
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = [value.toString()];
  }

  /// Ghi Content-Type của request đúng đường adapter, không mô phỏng response validation.
  @override
  set contentType(ContentType? value) {
    if (value != null) set(HttpHeaders.contentTypeHeader, value.toString());
  }

  /// Bất kỳ API SDK ngoài surface đã dùng đều fail bằng lỗi cố định.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('PROBE_FAILED');
}

/// Response là stream bytes JSON thực từ envelope RAM, để production transport decode và classify.
final class ProbeResponse extends Stream<List<int>>
    implements HttpClientResponse {
  /// Nhận status/header/body provider mà không sửa header thiếu hoặc credential sai transport.
  ProbeResponse(Map<String, dynamic> envelope)
    : statusCode = envelope['status'] as int,
      headers = ProbeHeaders(envelope['headers'] as Map<String, dynamic>),
      bytes = utf8.encode(jsonEncode(envelope['body']));
  @override
  final int statusCode;
  @override
  final ProbeHeaders headers;
  final List<int> bytes;
  @override
  int get contentLength => bytes.length;

  /// Delegate stream hữu hạn để API thực kiểm byte cap, UTF8, JSON và status.
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  /// Chặn surface SDK không được fixture cung cấp bằng diagnostic cố định.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('PROBE_FAILED');
}

/// Request fake chỉ ghi số send và số byte, không giữ bản sao password từ adapter.
final class ProbeRequest implements HttpClientRequest {
  /// Gắn đúng một response vào request do operation hiện tại sở hữu.
  ProbeRequest(this.response);
  final ProbeResponse response;
  @override
  final headers = ProbeHeaders({});
  @override
  final cookies = <Cookie>[];
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  @override
  bool persistentConnection = true;
  @override
  int contentLength = -1;
  int sends = 0;

  /// Input bytes đã thuộc adapter production, probe không sao chép hoặc xuất credential.
  @override
  void add(List<int> data) {}

  /// Output: response nguồn sau đúng một send, request lặp luôn bị đếm trước khi fail.
  @override
  Future<HttpClientResponse> close() async {
    sends++;
    verify(sends == 1);
    return response;
  }

  /// Chặn request SDK ngoài surface cần cho adapter bằng lỗi cố định.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('PROBE_FAILED');
}

/// HttpClient in-memory xác nhận đúng method/path và đếm attempt trước mọi refusal.
final class ProbeClient implements HttpClient {
  /// Nhận một request riêng cùng route dự kiến, không mở socket hoặc consult environment.
  ProbeClient(this.request, this.operation);
  final ProbeRequest request;
  final String operation;
  int opens = 0;
  @override
  Duration? connectionTimeout;

  /// Production vô hiệu proxy, probe chỉ nhận null để tránh bỏ qua kiểm direct policy.
  @override
  set findProxy(String Function(Uri)? callback) => verify(callback == null);

  /// Nhận đúng route login/profile hiện hành, tăng counter trước khi từ chối request thừa.
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    opens++;
    verify(opens == 1 && url.host == 'example.invalid');
    verify(method == (operation == 'login' ? 'POST' : 'GET'));
    verify(
      url.path == (operation == 'login' ? '/api/v1/auth/login' : '/api/v1/me'),
    );
    return request;
  }

  /// Client không có socket, production vẫn phải kết thúc ownership của operation.
  @override
  void close({bool force = false}) {}

  /// API SDK ngoài surface fake luôn fail bằng lỗi cố định.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('PROBE_FAILED');
}

/// Chạy response provider qua HTTP adapter thật và kiểm đúng outcome/status-derived kind, không replay.
/// Input
/// Param: envelope — status/header/body nguyên bản, chỉ từ stdin RAM.
/// Param: operation — login hoặc profile để kiểm allowlist operation thực.
/// Param: expected — null cho limited login success, hoặc enum lỗi public đã duyệt.
Future<void> checkTransport(
  Map<String, dynamic> envelope,
  String operation,
  AppAuthFailureKind? expected,
) async {
  // Request được production adapter đóng qua close(); analyzer không theo dõi ownership xuyên factory.
  // ignore: close_sinks
  final request = ProbeRequest(ProbeResponse(envelope));
  final client = ProbeClient(request, operation);
  var creations = 0;

  /// Đếm cả factory attempt bị từ chối để lỗi bị catch không che một lần replay.
  HttpClient createClient() {
    creations++;
    verify(creations == 1);
    return client;
  }

  final api = HttpAppAuthApi(
    Uri.parse('https://example.invalid'),
    createClient: createClient,
  );
  var matched = false;
  try {
    final result = operation == 'login'
        ? await api.login('probe@example.invalid', 'synthetic-probe-input')
        : await api.getProfile('synthetic_probe_bearer');
    matched =
        expected == null &&
        result is AppLoginResponse &&
        result.limited &&
        result.token == envelope['body']['token'];
  } on AppAuthFailure catch (error) {
    matched = expected != null && error.kind == expected;
    verify(
      error.outcomeUnknown ==
          (operation == 'login' && expected == AppAuthFailureKind.unavailable),
    );
    verify(error.toString() == 'APP_AUTH_${error.kind.name.toUpperCase()}');
    if (expected == AppAuthFailureKind.rateLimited) {
      final retry = request.response.headers['retry-after'];
      verify(
        retry != null &&
            retry.length == 1 &&
            error.retryAfterSeconds == int.parse(retry.single) &&
            error.retryAfterSeconds! > 0,
      );
    }
  }
  verify(matched && creations == 1 && client.opens == 1 && request.sends == 1);
}

/// Kiểm năm loại lỗi actual bằng HttpAppAuthApi với operation và classification cố định.
/// Input
/// Param: errors — envelopes validation/auth/rate/service/context nguyên bản.
Future<void> checkTransportErrors(Map<String, dynamic> errors) async {
  for (final entry in <(String, int, String, AppAuthFailureKind)>[
    ('validation', 422, 'VALIDATION_ERROR', AppAuthFailureKind.validation),
    ('auth', 401, 'AUTH_INVALID', AppAuthFailureKind.invalidCredentials),
    ('rate', 429, 'RATE_LIMITED', AppAuthFailureKind.rateLimited),
    ('service', 503, 'SERVICE_UNAVAILABLE', AppAuthFailureKind.unavailable),
    ('context', 409, 'AUTH_CONTEXT_MISMATCH', AppAuthFailureKind.conflict),
  ]) {
    final envelope = errors[entry.$1] as Map<String, dynamic>;
    verify(
      envelope['status'] == entry.$2 &&
          envelope['body']['error']['code'] == entry.$3,
    );
    await checkTransport(
      envelope,
      entry.$1 == 'context' ? 'profile' : 'login',
      entry.$4,
    );
  }
}

/// Nhận đúng packet4envelopes từ stdin; chỉ output boolean cố định, bắt lỗi trước khi có diagnostic tự động.
Future<void> main() async {
  try {
    final bytes = <int>[];
    await for (final chunk in stdin) {
      verify(bytes.length + chunk.length <= 1024 * 1024);
      bytes.addAll(chunk);
    }
    final input = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final loginEnvelope = input['appLogin'] as Map<String, dynamic>;
    final login = check('appLogin', loginEnvelope, [
      'me',
      'limited',
      'expiresAt',
      'token',
    ]) as AppLoginResponse;
    final loginBody = loginEnvelope['body'] as Map<String, dynamic>;
    verify(
      login.userId == loginBody['me']['id'] &&
          login.token == loginBody['token'],
    );
    final profileEnvelope = input['profile'] as Map<String, dynamic>;
    final profile = check('profile', profileEnvelope, [
      'id',
      'email',
      'mustChangePassword',
      'displayTimezone',
      'preferencesRevision',
    ]) as FullSessionProfile;
    verify(profile.userId == profileEnvelope['body']['id']);
    final pageEnvelope = input['workspaces'] as Map<String, dynamic>;
    final page = check('workspaces', pageEnvelope, [
      'items',
      'nextCursor',
    ]) as AvailableWorkspacePage;
    final pageBody = pageEnvelope['body'] as Map<String, dynamic>;
    // Ít nhất một row thật bảo đảm các mutation summary không trở thành vòng lặp rỗng.
    verify(
      page.items.isNotEmpty &&
          page.items.length == (pageBody['items'] as List).length,
    );
    for (final field in ['id', 'name', 'status', 'role', 'revision']) {
      for (final mutation in ['missing', 'null', 'type']) {
        final changed = clone(pageBody);
        final row = (changed['items'] as List).first as Map<String, dynamic>;
        if (mutation == 'missing')
          row.remove(field);
        else
          row[field] = mutation == 'null' ? null : <Object?>[];
        expectRejected('workspaces', changed);
      }
    }
    expectRejected('appLogin', input['webLogin']['body']);
    final result = <String, bool>{
      'appLogin': true,
      'profile': true,
      'workspaces': true,
      'compatibility': true,
      'webCookieRejected': true,
    };
    if (input.containsKey('appLimitedLogin') ||
        input.containsKey('appLimitedMe')) {
      final limited = input['appLimitedLogin'] as Map<String, dynamic>;
      verify(limited['status'] == 200 && limited['body']['limited'] == true);
      await checkTransport(limited, 'login', null);
      final limitedMe = input['appLimitedMe'] as Map<String, dynamic>;
      verify(
        limitedMe['status'] == 403 &&
            limitedMe['body']['error']['code'] == 'PASSWORD_CHANGE_REQUIRED',
      );
      await checkTransport(
        limitedMe,
        'profile',
        AppAuthFailureKind.passwordChangeRequired,
      );
      result['limited'] = true;
    }
    if (input.containsKey('appErrors')) {
      await checkTransportErrors(input['appErrors'] as Map<String, dynamic>);
      result['errors'] = true;
    }
    stdout.writeln(jsonEncode(result));
  } catch (_) {
    stdout.writeln(
      '{"appLogin":false,"profile":false,"workspaces":false,"compatibility":false,"webCookieRejected":false}',
    );
    exitCode = 1;
  }
}
