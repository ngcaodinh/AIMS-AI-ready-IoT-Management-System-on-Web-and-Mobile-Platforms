import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/**
 * Chọn TLS mặc định hoặc trust riêng của lab; không thay đổi trust toàn cục hoặc xác minh hostname.
 * Input
 * Param: apiOrigin — origin auth đã cấu hình; custom trust chỉ cho exact emulator endpoint.
 * Param: labCertificate — public DER Base64 canonical, rỗng dùng SDK roots; không nhận key/PFX/PEM.
 * Output: factory tạo client riêng từng operation; context lab chỉ chứa certificate được cấp.
 * Errors: ArgumentError cố định nếu mode/origin/bytes không hợp lệ, không mang parser detail.
 */
HttpClient Function() createAuthHttpClientFactory(
  Uri apiOrigin, {
  String labCertificate = '',
}) {
  if (labCertificate.isEmpty) return HttpClient.new;
  // SECURITY: guard thực của compiler, không nhận bool override từ caller hoặc test.
  if (!kDebugMode || apiOrigin.toString() != 'https://10.0.2.2:8443') {
    throw ArgumentError('INVALID_AUTH_LAB_TLS_CONFIGURATION');
  }
  // Một public certificate vừa giới hạn8KiB Base64; từ chối whitespace và container tùy ý.
  if (labCertificate.length < 128 ||
      labCertificate.length > 8192 ||
      !RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(labCertificate)) {
    throw ArgumentError('INVALID_AUTH_LAB_TLS_CONFIGURATION');
  }
  try {
    final bytes = base64Decode(labCertificate);
    if (base64Encode(bytes) != labCertificate || !_isSingleDerSequence(bytes)) {
      throw ArgumentError('INVALID_AUTH_LAB_TLS_CONFIGURATION');
    }
    // SDK Android nhận PEM; wrapper chỉ chứa đúng một DER, không cho loader bỏ qua tail/container khác.
    final certificate = StringBuffer('-----BEGIN CERTIFICATE-----\n');
    for (var offset = 0; offset < labCertificate.length; offset += 64) {
      final end = offset + 64 < labCertificate.length
          ? offset + 64
          : labCertificate.length;
      certificate.writeln(labCertificate.substring(offset, end));
    }
    certificate.writeln('-----END CERTIFICATE-----');
    final context = SecurityContext(withTrustedRoots: false);
    context.setTrustedCertificatesBytes(ascii.encode(certificate.toString()));
    // Không cài callback chấp nhận lỗi; SDK vẫn kiểm chain, expiry và hostname khi handshake.
    /// Tạo client thuộc operation, dùng context lab riêng và không chia sẻ cookie/token giữa intent.
    return () => HttpClient(context: context);
  } on FormatException catch (_) {
    throw ArgumentError('INVALID_AUTH_LAB_TLS_CONFIGURATION');
  } on TlsException catch (_) {
    throw ArgumentError('INVALID_AUTH_LAB_TLS_CONFIGURATION');
  } on ArgumentError catch (_) {
    throw ArgumentError('INVALID_AUTH_LAB_TLS_CONFIGURATION');
  }
}

/**
 * Kiểm framing DER hữu hạn trước SDK để không nhận tail/DER thứ hai hoặc indefinite/nonminimal length.
 * Input
 * Param: bytes — public bytes đã decode trong giới hạn8KiB Base64.
 * Output: true nếu đúng một outer SEQUENCE tiêu thụ toàn input; SDK vẫn phải kiểm cấu trúc X509.
 */
bool _isSingleDerSequence(List<int> bytes) {
  // 0x30 là tag SEQUENCE trong DER; chỉ kiểm framing, không thay parser X509 của SDK.
  if (bytes.length < 2 || bytes[0] != 0x30) return false;
  var length = bytes[1];
  var headerLength = 2;
  if (length >= 0x80) {
    final lengthOctets = length & 0x7f;
    // Tối đa6144 decoded bytes chỉ cần hai length octets; cấm indefinite và leading zero của DER.
    if (lengthOctets == 0 ||
        lengthOctets > 2 ||
        bytes.length < 2 + lengthOctets ||
        bytes[2] == 0) {
      return false;
    }
    length = 0;
    for (var index = 0; index < lengthOctets; index++) {
      length = (length << 8) | bytes[2 + index];
    }
    if (length < 128) return false;
    headerLength += lengthOctets;
  }
  return length > 0 && headerLength + length == bytes.length;
}
