import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nexa_iot/features/auth/data/app_auth_tls_configuration.dart';

/// Quan sát đúng một GET không credential qua TLS factory sản phẩm để kiểm capability modem.
/// Output: REACHABLE hoặc UNAVAILABLE, mọi lỗi TLS/status/body giữ failure riêng.
/// Side effects: client riêng, không cookie/token và luôn đóng sau operation hoặc timeout.
Future<String> observeNativeProbeRoute() async {
  final origin = Uri.parse('https://10.0.2.2:8443');
  final client = createAuthHttpClientFactory(
    origin,
    labCertificate: const String.fromEnvironment('AUTH_LAB_CA_CERT'),
  )();
  client.connectionTimeout = const Duration(seconds: 10);

  /// Gửi request fixed không bearer, chỉ nhận body401synthetic đã chốt từ host owner.
  /// Output: REACHABLE khi HTTP/TLS/body đúng, không diễn giải401 là lỗi kết nối.
  Future<String> exchange() async {
    final request = await client.getUrl(origin.resolve('/api/v1/me'));
    request.persistentConnection = false;
    final response = await request.close();
    var length = 0;
    final body = <int>[];
    await for (final chunk in response) {
      length += chunk.length;
      if (length > 256)
        throw StateError('NATIVE_NETWORK_PROBE_RESPONSE_INVALID');
      body.addAll(chunk);
    }
    if (response.statusCode != 401 ||
        utf8.decode(body) != '{"error":{"code":"AUTH_REQUIRED"}}') {
      throw StateError('NATIVE_NETWORK_PROBE_RESPONSE_INVALID');
    }
    return 'REACHABLE';
  }

  final pending = exchange();
  // Observer được gắn trước timeout, pending network vẫn được drain sau force-close.
  unawaited(
    pending.catchError(
      /// Giữ rejection observer sớm, awaited future gốc vẫn quyết định outcome.
      /// Input
      /// Param: error — lỗi SDK không được log hoặc phản chiếu vào marker.
      (Object error) => 'OBSERVED_ERROR',
    ),
  );
  try {
    return await pending.timeout(const Duration(seconds: 15));
  } on SocketException {
    debugPrint('NATIVE_NETWORK_FAILURE_SOCKET');
    return 'UNAVAILABLE';
  } on TimeoutException {
    client.close(force: true);
    try {
      await pending;
    } on Object {
      // Force-close chỉ yêu cầu đóng, phải đợi raw future settle trước trả route observation.
    }
    debugPrint('NATIVE_NETWORK_FAILURE_TIMEOUT');
    return 'UNAVAILABLE';
  } finally {
    client.close(force: true);
  }
}

/// Entry integration riêng, không mở login hoặc dùng fixture DB trong feasibility gate.
void main() {
  if (!kDebugMode) throw StateError('INVALID_NATIVE_NETWORK_PROBE_MODE');
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native modem route observation',

    /// Chạy I/O thật trong engine, chỉ xuất enum route và fixed failure khi protocol/TLS sai.
    /// Input
    /// Param: tester — framework native của integration_test, chưa mount main sản phẩm.
    (tester) async {
      try {
        final result = await tester.runAsync(observeNativeProbeRoute);
        if (result != 'REACHABLE' && result != 'UNAVAILABLE') {
          throw StateError('NATIVE_NETWORK_PROBE_RESULT_INVALID');
        }
        debugPrint('NATIVE_NETWORK_PROBE_$result');
      } on Object {
        throw StateError('NATIVE_NETWORK_PROBE_FAILED');
      }
    },
  );
}
