import 'dart:convert';
import 'dart:io' show HttpHeaders, HttpStatus;

import 'package:nexa_iot/features/auth/data/app_auth_tls_configuration.dart';
import 'package:nexa_iot/features/auth/data/session_token_store.dart';

import 'native_debug_secret_canary.dart';

// Giới hạn 4 KiB đủ dư cho response theo hợp đồng và chặn body bất thường tăng RAM trong isolate.
const _maximumTicketResponseBytes = 4096;

/** Gọi mutation ticket bằng S2 trong integration isolate để xác nhận Web S1 logout không thu hồi phiên Android.
 * Input
 * Param: credential — bearer vừa khôi phục trực tiếp từ secure storage của Android S2.
 * Param: workspaceId — workspace đang chọn, chỉ là selector để server kiểm tra membership hiện hành.
 * Param: canary — bộ quét debugPrint cùng isolate, phát hiện bearer hoặc ticket bị log.
 * Errors: request hoặc response sai status/schema/cache policy bị chuyển thành mã cố định, không lộ body/credential.
 * Side effects: tạo ticket tạm thời; caller tiếp tục logout S2 ngay sau đó để ticket không được sử dụng.
 */
Future<void> verifyNativeS2RealtimeTicket({
  required StoredSessionCredential credential,
  required String workspaceId,
  required NativeDebugSecretCanary canary,
}) async {
  final apiOrigin = Uri.parse('https://10.0.2.2:8443');
  final client = createAuthHttpClientFactory(
    apiOrigin,
    labCertificate: const String.fromEnvironment('AUTH_LAB_CA_CERT'),
  )()
    // Gọi thẳng emulator bridge đã pin; proxy môi trường không được nhận bearer S2.
    ..findProxy = null
    ..connectionTimeout = const Duration(seconds: 10);

  try {
    canary.addCanary(credential.token);
    final request = await client.postUrl(
      apiOrigin.resolve('/api/v1/realtime/tickets'),
    );
    request.followRedirects = false;
    request.persistentConnection = false;
    request.cookies.clear();
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${credential.token}',
    );
    request.headers.set('X-Workspace-Id', workspaceId);
    request.contentLength = 0;

    final response = await request.close().timeout(
      const Duration(seconds: 10),
    );
    if (response.statusCode != HttpStatus.created ||
        response.headers.value(HttpHeaders.cacheControlHeader) != 'no-store' ||
        response.headers.contentType?.mimeType != 'application/json') {
      throw StateError('NATIVE_S2_REALTIME_TICKET_RESPONSE_INVALID');
    }

    // Body chỉ được đọc có giới hạn trong isolate; không chuyển raw response vào channel, log hoặc lỗi test.
    final responseBytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 10))) {
      if (responseBytes.length + chunk.length > _maximumTicketResponseBytes) {
        throw StateError('NATIVE_S2_REALTIME_TICKET_RESPONSE_INVALID');
      }
      responseBytes.addAll(chunk);
    }
    final decoded = jsonDecode(utf8.decode(responseBytes));
    if (decoded is! Map<String, dynamic> ||
        decoded.length != 2 ||
        decoded['ticket'] is! String ||
        decoded['expiresAt'] is! String) {
      throw StateError('NATIVE_S2_REALTIME_TICKET_RESPONSE_INVALID');
    }

    final ticket = decoded['ticket'] as String;
    final expiresAt = decoded['expiresAt'] as String;
    // Đăng ký ticket để canary quét ngược log đã đệm trước khi response được kiểm tra xong.
    canary.addCanary(ticket);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(ticket) ||
        !RegExp(
          r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$',
        ).hasMatch(expiresAt) ||
        DateTime.tryParse(expiresAt) == null) {
      throw StateError('NATIVE_S2_REALTIME_TICKET_RESPONSE_INVALID');
    }
  } on StateError {
    rethrow;
  } catch (_) {
    throw StateError('NATIVE_S2_REALTIME_TICKET_REQUEST_FAILED');
  } finally {
    client.close(force: true);
  }
}
