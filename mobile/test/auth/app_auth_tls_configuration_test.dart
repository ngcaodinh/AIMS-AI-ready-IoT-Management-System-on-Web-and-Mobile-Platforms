import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../lib/main.dart';
import '../../lib/features/auth/data/app_auth_tls_configuration.dart';
import '../../lib/features/auth/presentation/app_auth_application.dart';
import '../../lib/features/auth/presentation/login_screen.dart';

/*
 * Chỉ public DER của certificate synthetic; private key đã bị hủy, không dùng fixture này cho server.
 * Test load trust không chứng minh certificate còn hạn hoặc native handshake thành công.
 */
const publicLabCertificate =
    'MIIDzzCCAjegAwIBAgIJAINZtDhYU6J4MA0GCSqGSIb3DQEBCwUAMBQxEjAQBgNVBAMTCWxvY2FsaG9zdDAeFw0yNjEwMjgxNjAwMTBaFw0yNjEwMjgxNjU2MTBaMBQxEjAQBgNVBAMTCWxvY2FsaG9zdDCCAaIwDQYJKoZIhvcNAQEBBQADggGPADCCAYoCggGBAM3fQ/TEgms/bjzedGAIPTLF1NSfaK0nNV/cVPsKaUdE35XUx60HvDsA0h6JLdI9PHzLBZzOljn3WRd5a2uJ0MvZYlyIwOiuWnpVYXGxNBLjz0BgpCci4G7XHICtJzvMikiuOIl40jrLekbnID8sqUUptsi3fhSw0vfnflq5xQNm8AhxM7GjtjTf20pOrnqf7tZ9oxDwl16miO/BCrjGs9A2+k4Ctfcb0A3Hh+gkczR3sGiOd9CTm+O3l6RfgCsy/osDem3B+RGccVph0yEfH1nvfOAm9sNh9b0MVGl784mq6/jwzsbQDFzTD2hG3IZKOYWsB4KavTf2CPPExESAZtS5rc4I3jLkSPw1TKdH25y73EWAw99G/aom3++pe0PIvGUPWuXSHAcFFcVuZjZruqNEwQ9g2UPShylFdfQ2MEQZ5o5HhgyuMjhBI0X/A6eXXkbxgui2fL2VEUY0uDkJ+pC/zasxdtaOvMg9YAbZYg6+575LkZAF97krB0SHH4V0/QIDAQABoyQwIjAgBgNVHREEGTAXgglsb2NhbGhvc3SHBH8AAAGHBAoAAgIwDQYJKoZIhvcNAQELBQADggGBACP+PqI5qSlvPCBtdEY7l6OHkBZ9RVzuJd83Qu5+P9E27i7FuwUZrIYhVOeBgMQbmK290Ip3BKTkLa95YthCLOBZyjc18nENGr5n1QNZG0Q7PKkKr51ogwk1UXZOcw+H7FKC6Z8jINkNpJmFyFhivPuz5zdLqAITu+QbM92jlsPu0657L4t1D/Bh7HkfA2S9on8mtYsWCtPhZSI8w0YxMUcIkxybM29x3HouWZhAeIuAvRDFByuzwBXoLVlartX9Kg6uso+auNNtMRD+Hd7v0xJY8D5pUGgt4CU4KnRhPhl4ZuRlqsc7Lu8zj/yJK48+Dpi6yEe+lO2kPdM494+4cjG0pxCKSwkj7JJV+7h7wWzMBVRefvBHScvA3XsPW4iURtvuNbhhkZj+GMWFE+eSiLRKPVvouBpl9h8lv9uD54PibojcJM40m3zgd0sC0iQ/sa1gMAbOBwDIP9XKPdzFRzEsZwb7+Q8Wo/lGIruGkzglRRcbjcEruAkh3spF29MC/Q==';
final labOrigin = Uri.parse('https://10.0.2.2:8443');
const storageChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

/// Handle synthetic để quan sát constructor context mà không tạo SDK socket hoặc kết nối thật.
final class CapturingHttpClient extends Fake implements HttpClient {}

/**
 * Kiểm lỗi cấu hình cố định để parser/SDK không phản chiếu bytes hoặc chi tiết nền tảng.
 * Input
 * Param: operation — boundary đồng bộ cần bị chặn trước I/O.
 */
void expectConfigurationFailure(void Function() operation) {
  expect(
    operation,
    throwsA(
      isA<ArgumentError>().having(
        /**
     * Đọc mã đã sanitize để assertion không cần giữ certificate hoặc exception parser gốc.
     * Input
     * Param: error — ArgumentError của boundary, message phải là mã cố định.
     * Output: message an toàn dùng đối chiếu contract lỗi.
     */
        (error) => error.message,
        'message',
        'INVALID_AUTH_LAB_TLS_CONFIGURATION',
      ),
    ),
  );
}

/// Kiểm trust/config riêng, không gửi password/token hoặc mở kết nối mạng.
void main() {
  test(
    'empty lab certificate keeps SDK client factory',
    /** Quan sát context constructor để default config không bị đổi sang trust rỗng/private của lab. */
    () {
      SecurityContext? capturedContext;
      var factoryCalls = 0;
      final capturedClient = CapturingHttpClient();
      final client = HttpOverrides.runZoned(
        /** Output: client được SDK factory yêu cầu trong đúng zone kiểm thử này. */
        () => createAuthHttpClientFactory(
          Uri.parse('https://api.example.invalid'),
        )(),
        createHttpClient:
            /**
             * Capture context được yêu cầu, không mở network hoặc thay trust toàn cục.
             * Input
             * Param: context — null phải được SDK dùng cho platform/default trust.
             * Output: handle synthetic chỉ để chứng minh factory đã đi qua constructor SDK.
             */
            (context) {
              capturedContext = context;
              factoryCalls++;
              return capturedClient;
            },
      );
      expect(factoryCalls, 1);
      expect(capturedContext, isNull);
      expect(identical(client, capturedClient), isTrue);
    },
  );

  test(
    'lab trust follows actual compiler build mode',
    /** Certificate hợp lệ chỉ load được trong debug; không giả mode qua bool runtime. */
    () {
      if (kDebugMode) {
        final createClient = createAuthHttpClientFactory(
          labOrigin,
          labCertificate: publicLabCertificate,
        );
        final client = createClient();
        client.close(force: true);
        debugPrint('AUTH_LAB_TRUST_DEBUG_ALLOWED');
      } else {
        expectConfigurationFailure(
          /** Chứng chỉ parse được trong debug cũng bị chặn ở non-debug. */
          () {
            createAuthHttpClientFactory(
              labOrigin,
              labCertificate: publicLabCertificate,
            );
          },
        );
        debugPrint('AUTH_LAB_TRUST_NONDEBUG_REJECTED');
      }
    },
  );

  test(
    'lab certificate is restricted to exact emulator origin',
    /** Các dạng origin gần giống không được hưởng CA riêng của lab. */
    () {
      for (final origin in [
        'http://10.0.2.2:8443',
        'https://10.0.2.2',
        'https://10.0.2.2:8443/',
        'https://10.0.2.2:8443/path',
        'https://10.0.2.2:8443?query',
        'https://10.0.2.2:8443#fragment',
        'https://user@10.0.2.2:8443',
        'https://localhost:8443',
        'https://127.0.0.1:8443',
        'https://api.example.invalid',
      ]) {
        expectConfigurationFailure(
          /** Mỗi biến thể đều phải fail closed trước khi client được tạo. */
          () {
            createAuthHttpClientFactory(
              Uri.parse(origin),
              labCertificate: publicLabCertificate,
            );
          },
        );
      }
    },
  );

  test(
    'malformed and noncanonical certificate configuration is rejected',
    /** Chặn format/bounds trước parser SDK và không nhận PEM/private container qua config. */
    () {
      for (final certificate in [
        ' ',
        'not-base64',
        'AAAA',
        '=' * 128,
        'A' * 8193,
        '$publicLabCertificate\n',
        '${publicLabCertificate}=',
        base64Encode(utf8.encode('synthetic invalid certificate content' * 5)),
        base64Encode(List<int>.filled(128, 0)),
        base64Encode([0x30, 0x80, ...List<int>.filled(128, 0)]),
        base64Encode([0x30, 0x81, 1, 0]),
        base64Encode([0x30, 0x82, 0, 128, ...List<int>.filled(128, 0)]),
      ]) {
        expectConfigurationFailure(
          /** Chứng chỉ không hợp lệ không được biến thành factory dùng default roots. */
          () {
            createAuthHttpClientFactory(labOrigin, labCertificate: certificate);
          },
        );
      }
    },
  );

  test(
    'valid DER with trailing material or second certificate is rejected',
    /** SDK có thể bỏ qua nội dung ngoài certificate; boundary phải yêu cầu đúng một DER object. */
    () {
      final bytes = base64Decode(publicLabCertificate);
      for (final combined in [
        [...bytes, 0],
        [...bytes, ...bytes],
      ]) {
        expectConfigurationFailure(
          /** Base64 canonical vẫn không cho phép dữ liệu sau certificate đã parse. */
          () {
            createAuthHttpClientFactory(
              labOrigin,
              labCertificate: base64Encode(combined),
            );
          },
        );
      }
    },
  );

  testWidgets(
    'invalid lab trust blocks main before storage or HTTP',
    /**
     * Quan sát main thật cùng hai I/O boundary, không dùng fake repository để suy pre-I/O.
     * Input
     * Param: tester — pump composition và kiểm blocking page trước form/session.
     */
    (tester) async {
      var storageCalls = 0;
      var clientCalls = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        storageChannel,
        /**
         * Ghi nhận mọi thao tác storage, không trả bearer hoặc giữ method arguments.
         * Input
         * Param: call — lời gọi plugin chỉ dùng đếm, không đọc payload.
         * Output: null synthetic, không phải evidence secure storage native.
         */
        (call) async {
          storageCalls++;
          return null;
        },
      );
      try {
        await HttpOverrides.runZoned(
          /** Pump các config lỗi trong cùng zone đếm client, rồi gỡ widget trước trả zone. */
          () async {
            for (final configuration in [
              (
                origin: 'https://api.example.invalid',
                certificate: publicLabCertificate,
              ),
              (origin: 'https://10.0.2.2:8443', certificate: 'not-base64'),
            ]) {
              await tester.pumpWidget(
                MainApp(
                  apiOrigin: configuration.origin,
                  labCertificate: configuration.certificate,
                ),
              );
              await tester.pumpAndSettle();
              expect(
                find.byKey(const ValueKey('app-configuration')),
                findsOneWidget,
              );
              expect(find.byType(AppAuthApplication), findsNothing);
              expect(find.byType(LoginScreen), findsNothing);
              expect(tester.takeException(), isNull);
              await tester.pumpWidget(const SizedBox());
              await tester.pumpAndSettle();
            }
          },
          createHttpClient:
              /**
             * Chặn và đếm cả việc tạo client, không mở HTTP thực khi config lỗi.
             * Input
             * Param: context — TLS context mà SDK caller yêu cầu, không cần đọc để kiểm pre-I/O.
             * Errors: lỗi cố định nếu main đi qua boundary không được phép.
             */
              (context) {
                clientCalls++;
                throw StateError('UNEXPECTED_CONFIG_HTTP');
              },
        );
        expect(storageCalls, 0);
        expect(clientCalls, 0);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        messenger.setMockMethodCallHandler(storageChannel, null);
      }
    },
  );
}
