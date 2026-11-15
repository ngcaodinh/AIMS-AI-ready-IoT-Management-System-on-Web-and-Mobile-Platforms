import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../lib/features/auth/data/app_auth_api.dart';
import '../../lib/features/auth/data/app_auth_failure.dart';

const privateCanary = 'synthetic-private-network-data';
const bearer = 'Ab._~+/-09==';
const fixtureUser = '11111111-1111-4111-8111-111111111111';
final origin = Uri.parse('https://example.invalid:9443');

/// Tạo login success đúng DTO cũ; expiry không được dùng để admission session trong transport.
/// Input
/// Param: token — bearer tổng hợp cần kiểm thêm token68 ngoài DTO cũ.
/// Output: JSON fixture chỉ trong RAM, không credential thật.
Map<String, Object?> loginBody({String token = bearer}) => {
  'me': {
    'id': fixtureUser,
    'email': 'synthetic@example.invalid',
    'mustChangePassword': false,
  },
  'limited': false,
  'expiresAt': '2030-01-01T00:00:00Z',
  'token': token,
};

/// Tạo full profile trực tiếp của /me, không phải login wrapper hoặc quyền workspace.
Map<String, Object?> profileBody() => {
  'id': fixtureUser,
  'email': 'synthetic@example.invalid',
  'mustChangePassword': false,
  'displayTimezone': 'UTC',
  'preferencesRevision': 1,
};

/// Tạo error envelope opaque để kiểm status/code mà không áp UUID ngoài contract.
Map<String, Object?> errorBody(String code) => {
  'error': {
    'code': code,
    'message': privateCanary,
    'details': <String, Object?>{},
    'correlationId': 'corr_opaque',
  },
};

/// Header fake giữ multivalue case-insensitive; không biến duplicate header thành một giá trị sạch.
final class RecordingHeaders extends Fake implements HttpHeaders {
  final values = <String, List<String>>{};

  /// Nhận fixture headers, merge tên khác case để duplicate vẫn quan sát được.
  RecordingHeaders([Map<String, List<String>> initial = const {}]) {
    for (final entry in initial.entries) {
      values
          .putIfAbsent(entry.key.toLowerCase(), newValues)
          .addAll(entry.value);
    }
  }

  /// Cấp list riêng cho mỗi header, tránh chia sẻ mutable state giữa các operation.
  static List<String> newValues() => <String>[];

  /// Đọc multivalue của đúng header để adapter có thể reject transport không rõ ràng.
  @override
  List<String>? operator [](String name) => values[name.toLowerCase()];

  /// Đọc singleton; duplicate không được âm thầm chọn giá trị đầu tiên.
  @override
  String? value(String name) {
    final found = this[name];
    if (found == null) return null;
    if (found.length != 1) throw const HttpException('MULTIPLE_HEADERS');
    return found.single;
  }

  /// Ghi header request trong RAM, thay đúng tên mà không log bearer.
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value is Iterable
        ? value.map(stringValue).toList()
        : [value.toString()];
  }

  /// Chuyển scalar header tổng hợp thành string cho collection fixture.
  static String stringValue(Object? value) => value.toString();

  /// Thêm multivalue đúng semantics HttpHeaders để assertion phát hiện header trùng.
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    values.putIfAbsent(name.toLowerCase(), newValues).add(value.toString());
  }

  /// Cấp copy values để consumer không thay fixture bằng callback.
  @override
  void forEach(void Function(String, List<String>) action) {
    for (final entry in values.entries) {
      action(entry.key, List<String>.of(entry.value));
    }
  }

  /// Đọc media type bằng parser SDK, gồm charset khi consumer cần kiểm UTF-8.
  @override
  ContentType? get contentType {
    final raw = value(HttpHeaders.contentTypeHeader);
    return raw == null ? null : ContentType.parse(raw);
  }

  /// Ghi content type request như một singleton header.
  @override
  set contentType(ContentType? value) {
    if (value == null) {
      values.remove(HttpHeaders.contentTypeHeader);
    } else {
      set(HttpHeaders.contentTypeHeader, value.toString());
    }
  }
}

/// Response fake vẫn là Stream thật; force-close client không tự complete source future hay stream.
final class RecordingResponse extends Stream<List<int>>
    implements HttpClientResponse {
  /// Nhận byte stream tổng hợp và metadata wire; không tạo socket hoặc decoder riêng.
  RecordingResponse(
    this.statusCode,
    this.headers,
    this.body, {
    this.contentLength = -1,
  });

  @override
  final int statusCode;
  @override
  final RecordingHeaders headers;
  final Stream<List<int>> body;
  @override
  final int contentLength;
  int listenCalls = 0;
  Duration listenWork = Duration.zero;

  /// Cookie collection luôn rỗng ở fake; Set-Cookie wire vẫn phải được kiểm qua headers.
  @override
  List<Cookie> get cookies => <Cookie>[];

  /// Trả redirect state của status fixture, không tự mở endpoint mới.
  @override
  bool get isRedirect => statusCode >= 300 && statusCode < 400;

  /// Cấp reason cố định để không đưa native diagnostic vào test output.
  @override
  String get reasonPhrase => 'synthetic';

  /// Fake không giữ pooled connection sau response; ownership vẫn do từng client ghi nhận.
  @override
  bool get persistentConnection => false;

  /// Delegate subscription để timeout không bị fake biến thành cancellation của source stream.
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    listenCalls++;
    spendCpu(listenWork);
    return body.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  /// Các member chưa khai báo phải fail rõ, không mở I/O hoặc trả dữ liệu quyền giả.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected response member');
}

/// Request fake ghi riêng body/send/abort; abort không giả hủy một Completer đã được test cấp.
final class RecordingRequest extends Fake implements HttpClientRequest {
  /// Giữ response hoặc gate của đúng operation, không đọc credential ngoài input hiện tại.
  RecordingRequest(this.response);
  final RecordingResponse response;
  final bytes = <int>[];
  @override
  final headers = RecordingHeaders();
  @override
  final cookies = <Cookie>[];
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  @override
  bool persistentConnection = true;
  @override
  bool bufferOutput = true;
  @override
  int contentLength = -1;
  @override
  Encoding encoding = utf8;
  Completer<HttpClientResponse>? closeGate;
  int closeCalls = 0;
  int writeCalls = 0;
  int abortCalls = 0;

  /// Ghi byte request nguyên vẹn để kiểm UTF-8 limit thay vì số ký tự.
  @override
  void add(List<int> data) => bytes.addAll(data);

  /// Giữ khả năng quan sát write nếu adapter chọn IOSink API thay cho add.
  @override
  void write(Object? object) {
    writeCalls++;
    add(encoding.encode(object.toString()));
  }

  /// Chỉ đếm send một lần rồi trả source future thật, không tự retry khi gate còn pending.
  @override
  Future<HttpClientResponse> close() {
    closeCalls++;
    return closeGate?.future ?? Future<HttpClientResponse>.value(response);
  }

  /// Không dùng abort để tự complete gate: late completion phải vẫn xảy ra khi test chủ động thả.
  @override
  void abort([Object? exception, StackTrace? stackTrace]) => abortCalls++;

  /// Flush fake không có buffered socket nhưng vẫn là Future để giữ async boundary.
  @override
  Future<void> flush() async {}
}

/// Client fake trả open future thật và ghi policy; không tự mô phỏng cancellation của SDK.
final class RecordingClient extends Fake implements HttpClient {
  /// Cấp request riêng để kiểm không trộn bearer giữa hai client/operation.
  RecordingClient(this.request);
  final RecordingRequest request;
  Completer<HttpClientRequest>? openGate;
  Object? openError;
  int openCalls = 0;
  final methods = <String>[];
  final uris = <Uri>[];
  final closeModes = <bool>[];
  bool proxyWasSet = false;
  String Function(Uri)? proxy;
  int certificateOverrides = 0;
  @override
  Duration? connectionTimeout;
  @override
  bool autoUncompress = true;

  /// Ép direct bằng null phải được quan sát, không consult environment proxy.
  @override
  set findProxy(String Function(Uri)? callback) {
    proxyWasSet = true;
    proxy = callback;
  }

  /// Mọi TLS override bị đếm để test phát hiện bypass dù request fake không có certificate.
  @override
  set badCertificateCallback(
    bool Function(X509Certificate, String, int)? callback,
  ) {
    certificateOverrides++;
  }

  /// Nhận literal method/URI rồi trả gate không tự cancel khi client.close được gọi.
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    openCalls++;
    methods.add(method);
    uris.add(url);
    if (openError != null) return Future<HttpClientRequest>.error(openError!);
    return openGate?.future ?? Future<HttpClientRequest>.value(request);
  }

  /// Force-close chỉ ghi ownership; test phải kiểm source late completion vẫn bị transport fence.
  @override
  void close({bool force = false}) => closeModes.add(force);
}

/// Factory ghi số operation độc lập, không cấp lại implicit cookie/token state giữa hai calls.
final class RecordingFactory {
  /// Nhận danh sách client đúng thứ tự operation dự kiến, thiếu client là lỗi test thay vì mạng thật.
  RecordingFactory(this.clients);
  final List<RecordingClient> clients;
  int calls = 0;
  Duration work = Duration.zero;

  /// Có thể chiếm CPU để kiểm deadline đã bắt đầu trước factory khi timer chưa được xử lý.
  HttpClient create() {
    spendCpu(work);
    if (calls >= clients.length) throw StateError('Unexpected replay');
    return clients[calls++];
  }
}

/// Tạo response bytes/stream tổng hợp, giữ byte count không phụ thuộc Content-Length khai báo.
/// Input
/// Param: status — HTTP status của response tổng hợp.
/// Param: body — JSON fixture khi không cấp bytes riêng.
/// Param: bytes — wire bytes để kiểm malformed UTF-8 hoặc exact size.
/// Param: stream — source stream thật có thể hoàn tất sau timeout của operation.
/// Param: headers — response metadata thay thế default no-store/JSON.
/// Output: client riêng, không có socket hoặc external storage.
RecordingClient clientFor({
  int status = 200,
  Object? body,
  List<int>? bytes,
  Stream<List<int>>? stream,
  Map<String, List<String>> headers = const {},
}) {
  final payload = bytes ?? utf8.encode(body == null ? '' : jsonEncode(body));
  final response = RecordingResponse(
    status,
    RecordingHeaders({
      'cache-control': ['no-store'],
      if (status != 204) 'content-type': ['application/json; charset=utf-8'],
      ...headers,
    }),
    stream ?? Stream<List<int>>.value(payload),
  );
  return RecordingClient(RecordingRequest(response));
}

/// Chạy CPU hữu hạn để Stopwatch vượt deadline trước khi event-loop timer có cơ hội bắn.
/// Input
/// Param: duration — cận chiếm CPU tổng hợp, không thay budget production.
void spendCpu(Duration duration) {
  if (duration == Duration.zero) return;
  final clock = Stopwatch()..start();
  while (clock.elapsed < duration) {}
}

/// Chỉ nhận failure typed an toàn, không cho FormatException/native error làm UI giữ raw diagnostic.
/// Input
/// Param: operation — Future gốc của đúng một API call.
/// Param: kind — phân loại yêu cầu, hoặc null khi contract chỉ đòi fail trước network.
/// Param: unknown — trạng thái mutation đã chốt ở contract, bỏ qua khi chưa có yêu cầu cụ thể.
/// Output: failure an toàn để kiểm Retry-After, không trả raw response.
Future<AppAuthFailure> expectAuthFailure(
  Future<dynamic> operation, {
  AppAuthFailureKind? kind,
  bool? unknown,
}) async {
  try {
    await operation;
  } on AppAuthFailure catch (error) {
    if (kind != null) expect(error.kind, kind);
    if (unknown != null) expect(error.outcomeUnknown, unknown);
    expect(error.toString().contains(privateCanary), isFalse);
    return error;
  }
  fail('Unsafe auth response became success');
}

/// Mọi HTTP factory ngoài injected fake đều fail trước socket, kể cả production code bỏ qua injection.
/// Input
/// Param: context — SecurityContext do SDK truyền; test không đọc hoặc sửa trusted roots.
/// Errors: StateError cố định chứng minh adapter dùng sai factory.
HttpClient refuseNetwork(SecurityContext? context) =>
    throw StateError('UNINJECTED_HTTP_FORBIDDEN');

/// Đăng ký operation test trong zone cấm real HTTP; không thay global HttpOverrides của test khác.
/// Input
/// Param: name — mô tả invariant tĩnh của test.
/// Param: body — operation async cần giữ trong cùng HttpOverrides zone.
void guardedTest(String name, Future<void> Function() body) {
  /// Gắn override vào đúng asynchronous test lifetime, không để future muộn thoát ra mạng thật.
  Future<void> invoke() =>
      HttpOverrides.runZoned(body, createHttpClient: refuseNetwork);
  test(name, invoke);
}

/// Constructor chỉ nhận origin HTTPS và deadline dương không quá15s, lỗi không chứa URI nhạy cảm.
Future<void> checkConfigurationBoundary() async {
  for (final raw in [
    'http://example.invalid',
    'https://$privateCanary:p@example.invalid',
    'https://example.invalid/api/v1',
    'https://example.invalid?query=x',
    'https://example.invalid#fragment',
    'https:',
    'file:///private',
  ]) {
    final factory = RecordingFactory([]);
    var rejected = false;
    try {
      HttpAppAuthApi(Uri.parse(raw), createClient: factory.create);
    } on ArgumentError catch (error) {
      rejected = true;
      expect(error.toString().contains(privateCanary), isFalse);
    }
    expect(rejected, isTrue);
    expect(factory.calls, 0);
  }
  for (final timeout in [
    Duration.zero,
    const Duration(seconds: -1),
    const Duration(seconds: 16),
  ]) {
    // Closure chỉ tạo constructor để kiểm fail trước I/O, không gọi networking trong matcher.
    expect(() => HttpAppAuthApi(origin, timeout: timeout), throwsArgumentError);
  }
}

/// Login gửi nguyên email/password đúng ba fields và không Authorization/cookie/context/CSRF.
Future<void> checkLoginWireAndPolicy() async {
  final client = clientFor(body: loginBody());
  final factory = RecordingFactory([client]);
  final api = HttpAppAuthApi(origin, createClient: factory.create);
  final result = await api.login(
    '  Synthetic@Example.invalid  ',
    ' A😀\tPass1\n',
  );
  expect(result.token == bearer, isTrue);
  expect(client.methods, ['POST']);
  expect(client.uris, [origin.replace(path: '/api/v1/auth/login')]);
  expect(jsonDecode(utf8.decode(client.request.bytes)), {
    'email': '  Synthetic@Example.invalid  ',
    'password': ' A😀\tPass1\n',
    'clientType': 'ANDROID',
  });
  expect(client.request.headers.contentType?.mimeType, 'application/json');
  expect(client.request.followRedirects, isFalse);
  expect(client.proxyWasSet, isTrue);
  expect(client.proxy, isNull);
  expect(client.certificateOverrides, 0);
  expect(client.request.cookies, isEmpty);
  for (final header in [
    'authorization',
    'cookie',
    'x-auth-context-id',
    'x-csrf-token',
    'x-workspace-id',
  ]) {
    expect(client.request.headers[header], isNull);
  }
  expect(factory.calls, 1);
  expect(client.request.closeCalls, 1);
  expect(client.closeModes, isNotEmpty);
}

/// Dùng chung email OQ001 nhưng giữ boundary backend là authority; adapter gửi nguyên email/password scalar.
Future<void> checkSharedEmailWirePolicy() async {
  final fixture = jsonDecode(
    File('../contracts/fixtures/auth/email-policy.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  expect(fixture['policyVersion'], 1);
  const password = ' Aa1e\u0301xxxx ';
  for (final example in fixture['cases'] as List<dynamic>) {
    final rejected = example['error'] != null;
    final body = loginBody();
    if (!rejected) {
      body['me'] = {
        'id': fixtureUser,
        'email': example['canonical'],
        'mustChangePassword': false,
      };
    }
    final client = clientFor(
      status: rejected ? 422 : 200,
      body: rejected ? errorBody('VALIDATION_ERROR') : body,
    );
    final factory = RecordingFactory([client]);
    final api = HttpAppAuthApi(origin, createClient: factory.create);
    if (rejected) {
      await expectAuthFailure(
        api.login(example['email'] as String, password),
        kind: AppAuthFailureKind.validation,
        unknown: false,
      );
    } else {
      final result = await api.login(example['email'] as String, password);
      expect(result.email, example['canonical']);
    }
    expect(factory.calls, 1);
    expect(client.openCalls, 1);
    expect(jsonDecode(utf8.decode(client.request.bytes)), {
      'email': example['email'],
      'password': password,
      'clientType': 'ANDROID',
    });
  }
}

/// Profile/logout dùng đúng bearer riêng và client riêng; logout body thực sự vắng, không gửi {}.
Future<void> checkProfileAndLogoutWire() async {
  final profile = clientFor(body: profileBody());
  final logout = clientFor(status: 204);
  final factory = RecordingFactory([profile, logout]);
  final api = HttpAppAuthApi(origin, createClient: factory.create);
  expect((await api.getProfile(bearer)).userId, fixtureUser);
  await api.logout('Different/token==');
  expect(factory.calls, 2);
  expect(profile.methods, ['GET']);
  expect(profile.uris.single.path, '/api/v1/me');
  expect(logout.methods, ['POST']);
  expect(logout.uris.single.path, '/api/v1/auth/logout');
  expect(
    profile.request.headers.value('authorization') == 'Bearer $bearer',
    isTrue,
  );
  expect(
    logout.request.headers.value('authorization') == 'Bearer Different/token==',
    isTrue,
  );
  expect(profile.request.bytes, isEmpty);
  expect(logout.request.bytes, isEmpty);
  for (final client in [profile, logout]) {
    expect(client.request.followRedirects, isFalse);
    expect(client.request.closeCalls, 1);
    expect(client.closeModes, isNotEmpty);
    expect(client.proxyWasSet, isTrue);
    expect(client.proxy, isNull);
    expect(client.certificateOverrides, 0);
    expect(client.request.cookies, isEmpty);
    for (final name in [
      'cookie',
      'x-auth-context-id',
      'x-csrf-token',
      'x-workspace-id',
    ]) {
      expect(client.request.headers[name], isNull);
    }
  }
}

/// Error phải đúng operation; limited /me là typed failure chứ không full profile hoặc logout.
Future<void> checkOperationSpecificFailures() async {
  final limited = clientFor(
    status: 403,
    body: errorBody('PASSWORD_CHANGE_REQUIRED'),
  );
  await expectAuthFailure(
    HttpAppAuthApi(
      origin,
      createClient: RecordingFactory([limited]).create,
    ).getProfile(bearer),
    kind: AppAuthFailureKind.passwordChangeRequired,
    unknown: false,
  );
  for (final operation in ['login', 'profile', 'logout']) {
    final client = clientFor(
      status: 401,
      body: errorBody(
        operation == 'login' ? 'SESSION_EXPIRED' : 'AUTH_INVALID',
      ),
    );
    final api = HttpAppAuthApi(
      origin,
      createClient: RecordingFactory([client]).create,
    );
    final future = operation == 'login'
        ? api.login('e', 'p')
        : operation == 'profile'
        ? api.getProfile(bearer)
        : api.logout(bearer);
    await expectAuthFailure(
      future,
      kind: AppAuthFailureKind.protocol,
      unknown: operation != 'profile',
    );
  }
}

/// Redirect/status khác hoặc503 không được gây replay; 429 chỉ trả cooldown đã kiểm.
Future<void> checkStatusAndNoReplay() async {
  for (final status in [201, 204, 302, 307, 308]) {
    final client = clientFor(status: status, body: loginBody());
    final factory = RecordingFactory([client]);
    await expectAuthFailure(
      HttpAppAuthApi(origin, createClient: factory.create).login('e', 'p'),
      kind: AppAuthFailureKind.protocol,
      unknown: true,
    );
    expect(factory.calls, 1);
    expect(client.openCalls, 1);
    expect(client.request.closeCalls, 1);
  }
  final unavailable = clientFor(
    status: 503,
    body: errorBody('SERVICE_UNAVAILABLE'),
  );
  await expectAuthFailure(
    HttpAppAuthApi(
      origin,
      createClient: RecordingFactory([unavailable]).create,
    ).logout(bearer),
    kind: AppAuthFailureKind.unavailable,
    unknown: true,
  );
  final rate = clientFor(
    status: 429,
    body: errorBody('RATE_LIMITED'),
    headers: {
      'Retry-After': ['480'],
    },
  );
  final failure = await expectAuthFailure(
    HttpAppAuthApi(
      origin,
      createClient: RecordingFactory([rate]).create,
    ).login('e', 'p'),
    kind: AppAuthFailureKind.rateLimited,
    unknown: false,
  );
  expect(failure.retryAfterSeconds, 480);
}

/// Web transport metadata dù rỗng hoặc media/cache sai đều phải reject trước khi admit bearer DTO.
Future<void> checkResponseTransportAndDecoding() async {
  for (final headers in <Map<String, List<String>>>[
    {
      'set-cookie': [''],
    },
    {
      'x-auth-context-id': [''],
    },
    {
      'x-csrf-token': [''],
    },
    {'cache-control': []},
    {
      'cache-control': ['public'],
    },
    {
      'content-type': ['text/html'],
    },
    {
      'content-type': [':'],
    },
    {
      'content-type': ['application/json; charset=iso-8859-1'],
    },
  ]) {
    final client = clientFor(body: loginBody(), headers: headers);
    await expectAuthFailure(
      HttpAppAuthApi(
        origin,
        createClient: RecordingFactory([client]).create,
      ).login('e', 'p'),
      kind: AppAuthFailureKind.protocol,
      unknown: true,
    );
    expect(client.closeModes, isNotEmpty);
  }
  for (final bytes in [
    utf8.encode('{bad-json'),
    <int>[0xff, 0xfe],
    utf8.encode('null'),
  ]) {
    final client = clientFor(bytes: bytes);
    await expectAuthFailure(
      HttpAppAuthApi(
        origin,
        createClient: RecordingFactory([client]).create,
      ).login('e', 'p'),
      kind: AppAuthFailureKind.protocol,
      unknown: true,
    );
  }
  for (final operation in ['profile', 'logout']) {
    for (final name in ['set-cookie', 'x-auth-context-id', 'x-csrf-token']) {
      final client = clientFor(
        status: operation == 'profile' ? 200 : 204,
        body: operation == 'profile' ? profileBody() : null,
        headers: {
          name: [''],
        },
      );
      final api = HttpAppAuthApi(
        origin,
        createClient: RecordingFactory([client]).create,
      );
      await expectAuthFailure(
        operation == 'profile' ? api.getProfile(bearer) : api.logout(bearer),
        kind: AppAuthFailureKind.protocol,
        unknown: operation == 'logout',
      );
    }
  }
  final nonempty = clientFor(status: 204, bytes: utf8.encode('{}'));
  await expectAuthFailure(
    HttpAppAuthApi(
      origin,
      createClient: RecordingFactory([nonempty]).create,
    ).logout(bearer),
    kind: AppAuthFailureKind.protocol,
    unknown: true,
  );
}

/// Dùng JSON extension để chạm exact byte bound mà không thay DTO đã được duyệt.
/// Input
/// Param: length — byte length cần tạo, đủ chứa login envelope cơ sở.
/// Output: JSON UTF-8 đúng số bytes để kiểm boundary inclusivity.
List<int> paddedResponse(int length) {
  final body = {...loginBody(), 'extension': ''};
  final remaining = length - utf8.encode(jsonEncode(body)).length;
  body['extension'] = 'x' * remaining;
  return utf8.encode(jsonEncode(body));
}

/// Body limit tính bytes thực đọc; UTF-8 codepoint được phép chia qua nhiều stream chunks.
Future<void> checkResponseByteLimitAndSplitUtf8() async {
  final exact = clientFor(bytes: paddedResponse(128 * 1024));
  await HttpAppAuthApi(
    origin,
    createClient: RecordingFactory([exact]).create,
  ).login('e', 'p');
  final large = clientFor(bytes: paddedResponse(128 * 1024 + 1));
  await expectAuthFailure(
    HttpAppAuthApi(
      origin,
      createClient: RecordingFactory([large]).create,
    ).login('e', 'p'),
    kind: AppAuthFailureKind.protocol,
    unknown: true,
  );
  final body = loginBody();
  (body['me'] as Map<String, Object?>)['email'] = 'é@example.invalid';
  final bytes = utf8.encode(jsonEncode(body));
  final split = bytes.indexOf(0xc3) + 1;
  final client = clientFor(
    stream: Stream<List<int>>.fromIterable([
      bytes.sublist(0, split),
      bytes.sublist(split),
    ]),
  );
  expect(
    (await HttpAppAuthApi(
      origin,
      createClient: RecordingFactory([client]).create,
    ).login('e', 'p')).email,
    'é@example.invalid',
  );
}

/// Request64KiB kiểm trước tạo client, dùng multibyte để không nhầm limit là số ký tự.
Future<void> checkRequestByteLimitBeforeNetwork() async {
  final fixedBytes = utf8
      .encode(
        jsonEncode({'email': 'e', 'password': '', 'clientType': 'ANDROID'}),
      )
      .length;
  final exact = clientFor(body: loginBody());
  await HttpAppAuthApi(
    origin,
    createClient: RecordingFactory([exact]).create,
  ).login('e', 'x' * (64 * 1024 - fixedBytes));
  expect(exact.request.bytes.length, 64 * 1024);
  final factory = RecordingFactory([]);
  await expectAuthFailure(
    HttpAppAuthApi(
      origin,
      createClient: factory.create,
    ).login('e', 'é' * 40000),
  );
  expect(factory.calls, 0);
}

/// Bearer token68 được kiểm cả input và login DTO output, không chèn whitespace/header hoặc Unicode.
Future<void> checkBearerBoundary() async {
  for (final token in [
    '',
    ' ',
    'a b',
    'a\nb',
    'a:b',
    'é',
    '=a',
    'a=b',
    'a%20b',
  ]) {
    final factory = RecordingFactory([]);
    final api = HttpAppAuthApi(origin, createClient: factory.create);
    await expectAuthFailure(
      api.getProfile(token),
      kind: AppAuthFailureKind.protocol,
      unknown: false,
    );
    await expectAuthFailure(
      api.logout(token),
      kind: AppAuthFailureKind.protocol,
      unknown: false,
    );
    expect(factory.calls, 0);
    final client = clientFor(body: loginBody(token: token));
    await expectAuthFailure(
      HttpAppAuthApi(
        origin,
        createClient: RecordingFactory([client]).create,
      ).login('e', 'p'),
      kind: AppAuthFailureKind.protocol,
      unknown: true,
    );
  }
}

/// Lỗi socket/TLS/body phải là network failure an toàn; lỗi stream không bị catch nhầm thành protocol header.
Future<void> checkNetworkFailureNoReplay() async {
  for (final error in [
    const SocketException(privateCanary),
    HandshakeException(privateCanary),
  ]) {
    for (final operation in ['login', 'profile', 'logout']) {
      final client = clientFor(body: loginBody())..openError = error;
      final factory = RecordingFactory([client]);
      final api = HttpAppAuthApi(origin, createClient: factory.create);
      final future = operation == 'login'
          ? api.login('e', 'p')
          : operation == 'profile'
          ? api.getProfile(bearer)
          : api.logout(bearer);
      await expectAuthFailure(
        future,
        kind: AppAuthFailureKind.networkUnavailable,
      );
      expect(factory.calls, 1);
      expect(client.openCalls, 1);
      expect(client.closeModes, contains(true));
    }
  }
  for (final operation in ['login', 'profile', 'logout']) {
    final client = clientFor(
      status: operation == 'logout' ? 204 : 200,
      stream: Stream<List<int>>.error(const HttpException(privateCanary)),
    );
    final factory = RecordingFactory([client]);
    final api = HttpAppAuthApi(origin, createClient: factory.create);
    final future = operation == 'login'
        ? api.login('e', 'p')
        : operation == 'profile'
        ? api.getProfile(bearer)
        : api.logout(bearer);
    await expectAuthFailure(
      future,
      kind: AppAuthFailureKind.networkUnavailable,
      unknown: operation != 'profile',
    );
    expect(factory.calls, 1);
    expect(client.request.closeCalls, 1);
    expect(client.closeModes, contains(true));
  }
}

/// Sau timeout, Future open vẫn được thả thật: continuation muộn không được write hoặc send mutation.
Future<void> checkLateOpenDoesNotSend() async {
  final gate = Completer<HttpClientRequest>();
  final client = clientFor(body: loginBody())..openGate = gate;
  final api = HttpAppAuthApi(
    origin,
    createClient: RecordingFactory([client]).create,
    timeout: const Duration(milliseconds: 20),
  );
  await expectAuthFailure(
    api.login('e', 'p'),
    kind: AppAuthFailureKind.networkUnavailable,
  );
  expect(client.closeModes, contains(true));
  expect(gate.isCompleted, isFalse);
  gate.complete(client.request);
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
  expect(client.request.bytes, isEmpty);
  expect(client.request.writeCalls, 0);
  expect(client.request.closeCalls, 0);
  expect(client.openCalls, 1);
}

/// Headers/body đến muộn không biến timeout thành DTO success, và không để source bị fake tự cancel.
Future<void> checkLateHeadersAndBodyNeverSucceed() async {
  final headerGate = Completer<HttpClientResponse>();
  final headers = clientFor(body: loginBody());
  headers.request.closeGate = headerGate;
  final headerApi = HttpAppAuthApi(
    origin,
    createClient: RecordingFactory([headers]).create,
    timeout: const Duration(milliseconds: 20),
  );
  await expectAuthFailure(
    headerApi.login('e', 'p'),
    kind: AppAuthFailureKind.networkUnavailable,
  );
  expect(headerGate.isCompleted, isFalse);
  headerGate.complete(headers.request.response);
  await Future<void>.delayed(Duration.zero);
  final bodyGate = StreamController<List<int>>.broadcast();
  final client = clientFor(stream: bodyGate.stream);
  final api = HttpAppAuthApi(
    origin,
    createClient: RecordingFactory([client]).create,
    timeout: const Duration(milliseconds: 20),
  );
  await expectAuthFailure(
    api.login('e', 'p'),
    kind: AppAuthFailureKind.networkUnavailable,
  );
  expect(client.closeModes, contains(true));
  bodyGate.add(utf8.encode(jsonEncode(loginBody())));
  await bodyGate.close();
  await Future<void>.delayed(Duration.zero);
  expect(client.request.closeCalls, 1);
  expect(client.openCalls, 1);
}

/// Factory chiếm CPU vượt deadline trước timer phải bị fence trước openUrl, đồng thời đóng client đã tạo.
Future<void> checkSynchronousFactoryDeadline() async {
  final client = clientFor(body: loginBody());
  final factory = RecordingFactory([client])
    ..work = const Duration(milliseconds: 100);
  await expectAuthFailure(
    HttpAppAuthApi(
      origin,
      createClient: factory.create,
      timeout: const Duration(milliseconds: 50),
    ).login('e', 'p'),
    kind: AppAuthFailureKind.networkUnavailable,
  );
  expect(client.openCalls, 0);
  expect(client.closeModes, contains(true));
}

/// Stream callback chiếm CPU khiến timer trễ vẫn không cho synchronous decode/DTO success vượt deadline.
Future<void> checkSynchronousBodyDeadline() async {
  final client = clientFor(body: loginBody());
  client.request.response.listenWork = const Duration(milliseconds: 100);
  await expectAuthFailure(
    HttpAppAuthApi(
      origin,
      createClient: RecordingFactory([client]).create,
      timeout: const Duration(milliseconds: 50),
    ).login('e', 'p'),
    kind: AppAuthFailureKind.networkUnavailable,
  );
  expect(client.closeModes, contains(true));
}

/// Đăng ký transport tests thuần fake; không mở ADB/provider hoặc dùng storage để kiểm networking.
void main() {
  guardedTest(
    'shared email policy preserves raw wire and canonical or rejected provider outcome',
    checkSharedEmailWirePolicy,
  );
  guardedTest(
    'configuration rejects non origin URI and weakened deadline',
    checkConfigurationBoundary,
  );
  guardedTest(
    'login uses exact Android wire and direct TLS policy',
    checkLoginWireAndPolicy,
  );
  guardedTest(
    'profile and logout own separate client and bearer',
    checkProfileAndLogoutWire,
  );
  guardedTest(
    'operation specific errors do not cross login and session boundaries',
    checkOperationSpecificFailures,
  );
  guardedTest(
    'status redirects and outages never replay a request',
    checkStatusAndNoReplay,
  );
  guardedTest(
    'transport metadata JSON and logout body are strict',
    checkResponseTransportAndDecoding,
  );
  guardedTest(
    'response byte boundary and split UTF8 are preserved',
    checkResponseByteLimitAndSplitUtf8,
  );
  guardedTest(
    'oversized UTF8 request stops before client creation',
    checkRequestByteLimitBeforeNetwork,
  );
  guardedTest(
    'token68 is checked before networking and on login return',
    checkBearerBoundary,
  );
  guardedTest(
    'network failures close client and never retry',
    checkNetworkFailureNoReplay,
  );
  guardedTest(
    'late open completes source future without sending mutation',
    checkLateOpenDoesNotSend,
  );
  guardedTest(
    'late headers and body cannot turn timeout into success',
    checkLateHeadersAndBodyNeverSucceed,
  );
  guardedTest(
    'factory CPU time consumes total deadline before open',
    checkSynchronousFactoryDeadline,
  );
  guardedTest(
    'late scheduler timer cannot admit body after deadline',
    checkSynchronousBodyDeadline,
  );
}
