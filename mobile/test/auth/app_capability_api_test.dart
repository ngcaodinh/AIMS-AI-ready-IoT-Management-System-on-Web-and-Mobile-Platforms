import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../lib/features/auth/data/app_auth_api.dart';
import '../../lib/features/auth/data/app_auth_failure.dart';
import '../contracts/workspace_access_detail_test.dart' as detail;
import 'app_auth_api_test.dart' as transport;

/// Kiểm Android bearer/client policy trên operation mới bằng fake gốc, không sao chép HTTP stack.
/// Input
/// Param: client — client riêng của đúng một operation cần kiểm ownership/wire.
void expectCapabilityPolicy(transport.RecordingClient client) {
  expect(client.proxyWasSet, isTrue);
  expect(client.proxy, isNull);
  expect(client.certificateOverrides, 0);
  expect(client.request.followRedirects, isFalse);
  expect(client.request.maxRedirects, 0);
  expect(
    client.request.headers.value(HttpHeaders.authorizationHeader),
    'Bearer ${transport.bearer}',
  );
  expect(
    client.request.headers.value(HttpHeaders.cacheControlHeader),
    'no-store',
  );
  expect(client.request.headers.value(HttpHeaders.cookieHeader), isNull);
  expect(client.request.headers.value('x-auth-context-id'), isNull);
  expect(client.request.headers.value('x-csrf-token'), isNull);
  expect(client.request.headers.value('x-workspace-id'), isNull);
  expect(client.request.cookies, isEmpty);
  expect(client.request.closeCalls, 1);
  expect(client.closeModes, [true]);
}

/// List dùng GET mặc định ACTIVE; cursor opaque/null/empty không bị mutate hoặc thêm historical filters.
Future<void> checkListWorkspaceWire() async {
  for (final cursor in <String?>[null, '', 'opaque +/=?&%#é']) {
    final client = transport.clientFor(
      body: {'items': <Object?>[], 'nextCursor': 'next opaque'},
    );
    final factory = transport.RecordingFactory([client]);
    final AppWorkspaceApi api = HttpAppAuthApi(
      transport.origin,
      createClient: factory.create,
    );
    final page = await api.listWorkspaces(transport.bearer, cursor: cursor);
    final uri = client.uris.single;
    expect(client.methods, ['GET']);
    expect(uri.scheme, 'https');
    expect(uri.authority, transport.origin.authority);
    expect(uri.path, '/api/v1/workspaces');
    expect(uri.fragment, isEmpty);
    expect(
      uri.queryParameters,
      cursor == null ? <String, String>{} : {'cursor': cursor},
    );
    expect(client.request.bytes, isEmpty);
    expect(page.items, isEmpty);
    expect(page.nextCursor, 'next opaque');
    expect(page.isEmpty, isFalse);
    expect(factory.calls, 1);
    expectCapabilityPolicy(client);
  }
}

/// Detail dùng path UUID gốc, binding UUID không phân biệt case; response account/workspace khác bị protocol.
Future<void> checkWorkspaceDetailBinding() async {
  final client = transport.clientFor(body: detail.detailBody());
  final AppWorkspaceApi api = HttpAppAuthApi(
    transport.origin,
    createClient: transport.RecordingFactory([client]).create,
  );
  final snapshot = await api.getWorkspace(
    transport.bearer,
    detail.workspaceIdentity.toUpperCase(),
  );
  expect(snapshot.id, detail.workspaceIdentity);
  expect(client.methods, ['GET']);
  expect(
    client.uris.single.path,
    '/api/v1/workspaces/${detail.workspaceIdentity.toUpperCase()}',
  );
  expect(client.uris.single.hasQuery, isFalse);
  expect(client.request.bytes, isEmpty);
  expectCapabilityPolicy(client);
  final mismatch = transport.clientFor(
    body: {...detail.detailBody(), 'id': transport.fixtureUser},
  );
  await transport.expectAuthFailure(
    HttpAppAuthApi(
      transport.origin,
      createClient: transport.RecordingFactory([mismatch]).create,
    ).getWorkspace(transport.bearer, detail.workspaceIdentity),
    kind: AppAuthFailureKind.protocol,
    unknown: false,
  );
}

/// Password chỉ encode raw current/new; legacy current1 và policy-invalid input vẫn để backend quyết định.
Future<void> checkPasswordWireAndRawInput() async {
  for (final passwords in [('x', ' Abc1234 '), (' old ', 'bad')]) {
    final client = transport.clientFor(status: 204);
    final factory = transport.RecordingFactory([client]);
    final AppPasswordApi api = HttpAppAuthApi(
      transport.origin,
      createClient: factory.create,
    );
    await api.changePassword(transport.bearer, passwords.$1, passwords.$2);
    expect(client.methods, ['POST']);
    expect(client.uris.single.path, '/api/v1/auth/password');
    expect(client.uris.single.hasQuery, isFalse);
    expect(jsonDecode(utf8.decode(client.request.bytes)), {
      'currentPassword': passwords.$1,
      'newPassword': passwords.$2,
    });
    expect(client.request.headers.contentType?.mimeType, 'application/json');
    expect(client.request.headers.contentType?.charset, 'utf-8');
    expect(factory.calls, 1);
    expectCapabilityPolicy(client);
  }
}

/// Hai failure kinds mới được map đúng status và chỉ hợp lệ ở capability tương ứng, không giữ raw error.
Future<void> checkNewFailureMappings() async {
  for (final entry in [
    (400, 'CURSOR_INVALID', AppAuthFailureKind.cursorInvalid),
    (404, 'RESOURCE_NOT_FOUND', AppAuthFailureKind.resourceNotFound),
  ]) {
    final failure = AppAuthFailure.fromResponse(entry.$1, {
      'cache-control': 'no-store',
    }, transport.errorBody(entry.$2));
    expect(failure.kind, entry.$3);
    expect(failure.outcomeUnknown, isFalse);
    expect(failure.toString().contains(transport.privateCanary), isFalse);
    final client = transport.clientFor(
      status: entry.$1,
      body: transport.errorBody(entry.$2),
    );
    final api = HttpAppAuthApi(
      transport.origin,
      createClient: transport.RecordingFactory([client]).create,
    );
    await transport.expectAuthFailure(
      entry.$1 == 400
          ? api.listWorkspaces(transport.bearer)
          : api.getWorkspace(transport.bearer, detail.workspaceIdentity),
      kind: entry.$3,
      unknown: false,
    );
  }
}

/// Password401 phân biệt wrong current với session invalid;429/503 đúng typed outcome và không auto replay.
Future<void> checkPasswordErrorSemantics() async {
  for (final entry in [
    (401, 'AUTH_INVALID', AppAuthFailureKind.invalidCredentials, false),
    (401, 'SESSION_REVOKED', AppAuthFailureKind.sessionExpired, false),
    (429, 'RATE_LIMITED', AppAuthFailureKind.rateLimited, false),
    (503, 'SERVICE_UNAVAILABLE', AppAuthFailureKind.unavailable, true),
  ]) {
    final client = transport.clientFor(
      status: entry.$1,
      body: transport.errorBody(entry.$2),
      headers: entry.$1 == 429
          ? {
              'retry-after': ['3'],
            }
          : {},
    );
    final factory = transport.RecordingFactory([client]);
    final api = HttpAppAuthApi(transport.origin, createClient: factory.create);
    final failure = await transport.expectAuthFailure(
      api.changePassword(transport.bearer, 'x', ' Abc1234 '),
      kind: entry.$3,
      unknown: entry.$4,
    );
    if (entry.$1 == 429) expect(failure.retryAfterSeconds, 3);
    expect(factory.calls, 1);
    expect(client.request.closeCalls, 1);
    expect(client.closeModes, [true]);
  }
}

/// Mở rộng mapper không được làm login/profile/logout chấp nhận error capability ngoài contract cũ.
Future<void> checkOriginalOperationIsolation() async {
  for (final entry in [(400, 'CURSOR_INVALID'), (404, 'RESOURCE_NOT_FOUND')]) {
    for (final operation in ['login', 'profile', 'logout']) {
      final client = transport.clientFor(
        status: entry.$1,
        body: transport.errorBody(entry.$2),
      );
      final api = HttpAppAuthApi(
        transport.origin,
        createClient: transport.RecordingFactory([client]).create,
      );
      final Future<dynamic> result = switch (operation) {
        'login' => api.login('synthetic@example.invalid', 'x'),
        'profile' => api.getProfile(transport.bearer),
        _ => api.logout(transport.bearer),
      };
      await transport.expectAuthFailure(
        result,
        kind: AppAuthFailureKind.protocol,
        unknown: operation != 'profile',
      );
    }
  }
}

/// Gọi một capability bằng input cố định để cùng matrix kiểm boundary, không fake parser hoặc request.
/// Input
/// Param: api — adapter thật dùng client fake riêng của ca kiểm tra.
/// Param: operation — tên list/detail/password thuộc allowlist test.
/// Output: Future thực của operation, không tự retry hoặc đổi error.
Future<dynamic> invokeCapability(HttpAppAuthApi api, String operation) =>
    switch (operation) {
      'list' => api.listWorkspaces(transport.bearer),
      'detail' => api.getWorkspace(transport.bearer, detail.workspaceIdentity),
      _ => api.changePassword(transport.bearer, 'x', ' Abc1234 '),
    };

/// Cap áp dụng encoded URI và UTF-8 JSON trước factory, không đếm ký tự cursor hoặc password.
Future<void> checkCapabilityRequestBounds() async {
  final prefix = transport.origin
      .replace(path: '/api/v1/workspaces', queryParameters: {'cursor': 'a'})
      .toString();
  // Empty query value có thể bỏ dấu '=' trong URI codec; đo nonempty rồi trừ đúng một byte mẫu.
  final length = 64 * 1024 - (utf8.encode(prefix).length - 1);
  for (final extra in [0, 1]) {
    final client = transport.clientFor(
      body: {'items': <Object?>[], 'nextCursor': null},
    );
    final factory = transport.RecordingFactory([client]);
    final api = HttpAppAuthApi(transport.origin, createClient: factory.create);
    final call = api.listWorkspaces(
      transport.bearer,
      cursor: 'a' * (length + extra),
    );
    if (extra == 0) {
      await call;
      expect(utf8.encode(client.uris.single.toString()).length, 64 * 1024);
    } else {
      await transport.expectAuthFailure(
        call,
        kind: AppAuthFailureKind.validation,
        unknown: false,
      );
    }
    expect(factory.calls, extra == 0 ? 1 : 0);
  }
  final factory = transport.RecordingFactory([]);
  await transport.expectAuthFailure(
    HttpAppAuthApi(
      transport.origin,
      createClient: factory.create,
    ).listWorkspaces(transport.bearer, cursor: 'é' * 12000),
    kind: AppAuthFailureKind.validation,
    unknown: false,
  );
  expect(factory.calls, 0);
  final bodyOverhead = utf8
      .encode(jsonEncode({'currentPassword': 'x', 'newPassword': ''}))
      .length;
  for (final extra in [0, 1]) {
    final client = transport.clientFor(status: 204);
    final bodyFactory = transport.RecordingFactory([client]);
    final call =
        HttpAppAuthApi(
          transport.origin,
          createClient: bodyFactory.create,
        ).changePassword(
          transport.bearer,
          'x',
          'a' * (64 * 1024 - bodyOverhead + extra),
        );
    if (extra == 0) {
      await call;
      expect(client.request.bytes.length, 64 * 1024);
    } else {
      await transport.expectAuthFailure(
        call,
        kind: AppAuthFailureKind.validation,
        unknown: false,
      );
    }
    expect(bodyFactory.calls, extra == 0 ? 1 : 0);
  }
  for (final id in [
    '../escape',
    '${detail.workspaceIdentity}\n',
    '',
    'not-a-uuid',
  ]) {
    final idFactory = transport.RecordingFactory([]);
    await transport.expectAuthFailure(
      HttpAppAuthApi(
        transport.origin,
        createClient: idFactory.create,
      ).getWorkspace(transport.bearer, id),
      kind: AppAuthFailureKind.validation,
      unknown: false,
    );
    expect(idFactory.calls, 0);
  }
  for (final operation in ['list', 'detail', 'password']) {
    final bearerFactory = transport.RecordingFactory([]);
    final api = HttpAppAuthApi(
      transport.origin,
      createClient: bearerFactory.create,
    );
    final call = switch (operation) {
      'list' => api.listWorkspaces('invalid#token'),
      'detail' => api.getWorkspace('invalid#token', detail.workspaceIdentity),
      _ => api.changePassword('invalid#token', 'x', 'new'),
    };
    await transport.expectAuthFailure(
      call,
      kind: AppAuthFailureKind.protocol,
      unknown: false,
    );
    expect(bearerFactory.calls, 0);
  }
}

/// Status/code allowlist độc lập từng capability; code đúng endpoint khác vẫn là protocol.
Future<void> checkCapabilityErrorIsolation() async {
  final cases = <(String, int, String, AppAuthFailureKind)>[
    ('list', 400, 'CURSOR_INVALID', AppAuthFailureKind.cursorInvalid),
    ('list', 422, 'VALIDATION_ERROR', AppAuthFailureKind.validation),
    (
      'list',
      403,
      'PASSWORD_CHANGE_REQUIRED',
      AppAuthFailureKind.passwordChangeRequired,
    ),
    ('list', 403, 'FORBIDDEN', AppAuthFailureKind.permissionDenied),
    ('detail', 404, 'RESOURCE_NOT_FOUND', AppAuthFailureKind.resourceNotFound),
    ('detail', 409, 'AUTH_CONTEXT_MISMATCH', AppAuthFailureKind.conflict),
    ('detail', 401, 'SESSION_EXPIRED', AppAuthFailureKind.sessionExpired),
    ('password', 413, 'VALIDATION_ERROR', AppAuthFailureKind.validation),
    ('password', 403, 'CSRF_INVALID', AppAuthFailureKind.permissionDenied),
  ];
  for (final entry in cases) {
    final client = transport.clientFor(
      status: entry.$2,
      body: transport.errorBody(entry.$3),
    );
    final api = HttpAppAuthApi(
      transport.origin,
      createClient: transport.RecordingFactory([client]).create,
    );
    await transport.expectAuthFailure(
      invokeCapability(api, entry.$1),
      kind: entry.$4,
      unknown: false,
    );
  }
  for (final entry in [
    ('list', 404, 'RESOURCE_NOT_FOUND'),
    ('list', 401, 'AUTH_INVALID'),
    ('list', 429, 'RATE_LIMITED'),
    ('detail', 400, 'CURSOR_INVALID'),
    ('detail', 422, 'VALIDATION_ERROR'),
    ('detail', 403, 'CSRF_INVALID'),
    ('password', 400, 'CURSOR_INVALID'),
    ('password', 404, 'RESOURCE_NOT_FOUND'),
    ('password', 403, 'PASSWORD_CHANGE_REQUIRED'),
  ]) {
    final client = transport.clientFor(
      status: entry.$2,
      body: transport.errorBody(entry.$3),
      headers: {
        'retry-after': ['3'],
      },
    );
    final api = HttpAppAuthApi(
      transport.origin,
      createClient: transport.RecordingFactory([client]).create,
    );
    await transport.expectAuthFailure(
      invokeCapability(api, entry.$1),
      kind: AppAuthFailureKind.protocol,
      unknown: entry.$1 == 'password',
    );
  }
}

/// Kiểm response byte cap và transport metadata trên operation mới, không suy success từ status đơn thuần.
Future<void> checkCapabilityResponseBoundary() async {
  for (final operation in ['list', 'detail', 'password']) {
    for (final header in [
      'set-cookie',
      'x-auth-context-id',
      'x-csrf-token',
      'cache-control',
    ]) {
      final client = transport.clientFor(
        status: operation == 'password' ? 204 : 200,
        body: operation == 'list'
            ? {'items': <Object?>[], 'nextCursor': null}
            : operation == 'detail'
            ? detail.detailBody()
            : null,
        headers: {
          header: [header == 'cache-control' ? 'max-age=60' : ''],
        },
      );
      await transport.expectAuthFailure(
        invokeCapability(
          HttpAppAuthApi(
            transport.origin,
            createClient: transport.RecordingFactory([client]).create,
          ),
          operation,
        ),
        kind: AppAuthFailureKind.protocol,
        unknown: operation == 'password',
      );
    }
    final streamError = transport.clientFor(
      status: operation == 'password' ? 204 : 200,
      stream: Stream<List<int>>.error(
        const HttpException(transport.privateCanary),
      ),
    );
    await transport.expectAuthFailure(
      invokeCapability(
        HttpAppAuthApi(
          transport.origin,
          createClient: transport.RecordingFactory([streamError]).create,
        ),
        operation,
      ),
      kind: AppAuthFailureKind.networkUnavailable,
      unknown: operation == 'password',
    );
  }
  final nonemptyAck = transport.clientFor(status: 204, bytes: [32]);
  await transport.expectAuthFailure(
    HttpAppAuthApi(
      transport.origin,
      createClient: transport.RecordingFactory([nonemptyAck]).create,
    ).changePassword(transport.bearer, 'x', 'new'),
    kind: AppAuthFailureKind.protocol,
    unknown: true,
  );
  for (final extra in [0, 1]) {
    final body = jsonEncode({'items': <Object?>[], 'nextCursor': null});
    final payload = utf8.encode(
      '$body${' ' * (128 * 1024 - utf8.encode(body).length + extra)}',
    );
    final client = transport.clientFor(bytes: payload);
    final call = HttpAppAuthApi(
      transport.origin,
      createClient: transport.RecordingFactory([client]).create,
    ).listWorkspaces(transport.bearer);
    if (extra == 0) {
      await call;
    } else {
      await transport.expectAuthFailure(
        call,
        kind: AppAuthFailureKind.protocol,
        unknown: false,
      );
    }
  }
}

/// Source Future vẫn hoàn tất sau timeout; late open không gửi password và late body không thành success.
Future<void> checkCapabilityLateFutures() async {
  for (final operation in ['list', 'password']) {
    final gate = Completer<HttpClientRequest>();
    final client = transport.clientFor(
      status: operation == 'password' ? 204 : 200,
      body: operation == 'list'
          ? {'items': <Object?>[], 'nextCursor': null}
          : null,
    )..openGate = gate;
    final api = HttpAppAuthApi(
      transport.origin,
      createClient: transport.RecordingFactory([client]).create,
      timeout: const Duration(milliseconds: 30),
    );
    await transport.expectAuthFailure(
      invokeCapability(api, operation),
      kind: AppAuthFailureKind.networkUnavailable,
      unknown: false,
    );
    expect(gate.isCompleted, isFalse);
    gate.complete(client.request);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(client.request.bytes, isEmpty);
    expect(client.request.closeCalls, 0);
    expect(client.closeModes, [true]);
  }
  final controller = StreamController<List<int>>.broadcast();
  final client = transport.clientFor(status: 204, stream: controller.stream);
  await transport.expectAuthFailure(
    HttpAppAuthApi(
      transport.origin,
      createClient: transport.RecordingFactory([client]).create,
      timeout: const Duration(milliseconds: 30),
    ).changePassword(transport.bearer, 'x', 'new'),
    kind: AppAuthFailureKind.networkUnavailable,
    unknown: true,
  );
  await controller.close();
  expect(client.request.closeCalls, 1);
  expect(client.closeModes, [true]);
  final cpuClient = transport.clientFor(
    body: {'items': <Object?>[], 'nextCursor': null},
  );
  final factory = transport.RecordingFactory([cpuClient])
    ..work = const Duration(milliseconds: 80);
  await transport.expectAuthFailure(
    HttpAppAuthApi(
      transport.origin,
      createClient: factory.create,
      timeout: const Duration(milliseconds: 40),
    ).listWorkspaces(transport.bearer),
    kind: AppAuthFailureKind.networkUnavailable,
    unknown: false,
  );
  expect(cpuClient.openCalls, 0);
  expect(cpuClient.closeModes, [true]);
}

/// Reuse zone cấm real HTTP và public fakes, không gọi main của file helper được import.
void main() {
  transport.guardedTest(
    'workspace list keeps opaque cursor and default query wire',
    checkListWorkspaceWire,
  );
  transport.guardedTest(
    'workspace detail binds UUID path to immutable server identity',
    checkWorkspaceDetailBinding,
  );
  transport.guardedTest(
    'password mutation preserves raw input and requires empty 204',
    checkPasswordWireAndRawInput,
  );
  transport.guardedTest(
    'capability failure kinds map only their declared errors',
    checkNewFailureMappings,
  );
  transport.guardedTest(
    'password failures distinguish credential session rate and unknown',
    checkPasswordErrorSemantics,
  );
  transport.guardedTest(
    'new error codes remain rejected by original auth operations',
    checkOriginalOperationIsolation,
  );
  transport.guardedTest(
    'capability input and encoded URI byte bounds precede client creation',
    checkCapabilityRequestBounds,
  );
  transport.guardedTest(
    'capability error allowlists reject codes from other endpoints',
    checkCapabilityErrorIsolation,
  );
  transport.guardedTest(
    'capability response bytes metadata and ACK are strict',
    checkCapabilityResponseBoundary,
  );
  transport.guardedTest(
    'capability late Futures cannot send or admit beyond deadline',
    checkCapabilityLateFutures,
  );
}
