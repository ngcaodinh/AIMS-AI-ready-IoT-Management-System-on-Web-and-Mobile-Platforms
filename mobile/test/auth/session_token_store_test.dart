import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../lib/features/auth/data/session_token_store.dart';

// Channel giả chỉ kiểm boundary Dart; không thay evidence Android KeyStore thật.
const storageChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);
const sessionKey = 'session_token';
const syntheticToken = 'synthetic-session-not-a-real-credential';
const unrelatedKey = 'synthetic-installation-proof';

/// Mô phỏng native I/O trong RAM, gồm lỗi trước/sau ghi để kiểm side effect chưa biết.
final class StorageChannelFake {
  final values = <String, String>{unrelatedKey: 'synthetic-proof'};
  final optionsSeen = <Map<Object?, Object?>>[];
  String? failureMethod;
  bool writeBeforeFailure = false;
  bool missingPlugin = false;
  Object? readOverride;
  Completer<void>? writeGate;
  int calls = 0;

  /// Nhận lệnh plugin bằng codec thật, chỉ thao tác dữ liệu tổng hợp của mỗi test.
  /// Input
  /// Param: call — method/arguments từ plugin, không đến từ provider hoặc account thật.
  /// Output: read value hoặc ACK; có thể trì hoãn ACK để kiểm caller phải await.
  /// Errors: lỗi giả có canary để xác nhận adapter không đưa detail ra ngoài.
  Future<Object?> handle(MethodCall call) async {
    calls++;
    if (missingPlugin) throw MissingPluginException(syntheticToken);
    final arguments = call.arguments as Map<Object?, Object?>;
    final key = arguments['key'] as String;
    optionsSeen.add(arguments['options'] as Map<Object?, Object?>);
    expect(key == sessionKey, isTrue, reason: 'Only session key is allowed');
    if (call.method == failureMethod) {
      if (writeBeforeFailure && call.method == 'write') {
        values[key] = arguments['value'] as String;
      }
      throw PlatformException(
        code: syntheticToken,
        message: syntheticToken,
        details: <String, String>{'canary': syntheticToken},
      );
    }
    switch (call.method) {
      case 'read':
        return readOverride ?? values[key];
      case 'write':
        await writeGate?.future;
        values[key] = arguments['value'] as String;
        return null;
      case 'delete':
        values.remove(key);
        return null;
      default:
        throw StateError('Unexpected storage operation');
    }
  }
}

/// Kiểm lỗi an toàn theo operation, không để matcher in object platform hoặc canary.
/// Input
/// Param: operation — tác vụ I/O đang được kiểm, chưa catch bên ngoài adapter.
/// Param: expectedOperation — nhánh lỗi công khai caller phải phân biệt.
Future<void> expectStorageFailure(
  Future<Object?> operation,
  SessionStorageOperation expectedOperation,
) async {
  try {
    await operation;
  } on SessionStorageException catch (error) {
    expect(error.operation, expectedOperation);
    expect(
      error.toString(),
      'SESSION_STORAGE_${expectedOperation.name.toUpperCase()}',
    );
    expect(error.toString().contains(syntheticToken), isFalse);
    return;
  }
  fail('Storage failure must not become success or an absent session');
}

/// Kiểm roundtrip không cache và xóa đúng key; dữ liệu installation phải còn nguyên.
Future<void> checkRoundTrip() async {
  final fake = StorageChannelFake();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(storageChannel, fake.handle);
  final store = SecureSessionTokenStore();
  expect(await store.read(), isNull);
  await store.write(syntheticToken);
  expect(await SecureSessionTokenStore().read() == syntheticToken, isTrue);
  await store.delete();
  expect(await store.read(), isNull);
  expect(fake.values[unrelatedKey] == 'synthetic-proof', isTrue);
  for (final options in fake.optionsSeen) {
    expect(options['resetOnError'], 'false');
    expect(options['storageNamespace'], 'nexa_auth_session_v1');
  }
}

/// Xác nhận lỗi native read/write/delete không bị nuốt hoặc tự retry/xóa toàn bộ.
Future<void> checkOperationFailures() async {
  for (final operation in SessionStorageOperation.values) {
    final fake = StorageChannelFake()..failureMethod = operation.name;
    fake.values[sessionKey] = syntheticToken;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storageChannel, fake.handle);
    final store = SecureSessionTokenStore();
    final future = switch (operation) {
      SessionStorageOperation.read => store.read(),
      SessionStorageOperation.write => store.write(syntheticToken),
      SessionStorageOperation.delete => store.delete(),
    };
    await expectStorageFailure(future, operation);
    expect(fake.calls, 1);
    expect(fake.values[sessionKey] == syntheticToken, isTrue);
    expect(fake.values[unrelatedKey] == 'synthetic-proof', isTrue);
  }
}

/// Write có thể đã lưu trước khi ACK lỗi; caller vẫn nhận thất bại và tự xử lý unknown.
Future<void> checkUnknownWrite() async {
  final fake = StorageChannelFake()
    ..failureMethod = 'write'
    ..writeBeforeFailure = true;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(storageChannel, fake.handle);
  await expectStorageFailure(
    SecureSessionTokenStore().write(syntheticToken),
    SessionStorageOperation.write,
  );
  expect(fake.values[sessionKey] == syntheticToken, isTrue);
  expect(
    fake.calls,
    1,
    reason: 'No implicit retry or cleanup after unknown ACK',
  );
}

/// Chặn dữ liệu storage hỏng và plugin thiếu; read lỗi không được coi như storage rỗng.
Future<void> checkInvalidReads() async {
  final fake = StorageChannelFake();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(storageChannel, fake.handle);
  for (final value in <Object>['', ' ', 'synthetic\r\nheader', 42]) {
    fake.readOverride = value;
    await expectStorageFailure(
      SecureSessionTokenStore().read(),
      SessionStorageOperation.read,
    );
  }
  fake.missingPlugin = true;
  await expectStorageFailure(
    SecureSessionTokenStore().read(),
    SessionStorageOperation.read,
  );
}

/// Chặn token không dùng được trước I/O mà không đính kèm giá trị vào lỗi.
Future<void> checkInvalidWrites() async {
  final fake = StorageChannelFake();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(storageChannel, fake.handle);
  for (final token in ['', ' ', 'synthetic\nheader']) {
    await expectStorageFailure(
      SecureSessionTokenStore().write(token),
      SessionStorageOperation.write,
    );
  }
  expect(fake.calls, 0);
}

/// Không báo write thành công khi plugin vẫn đang chờ ACK; không dựa timer tùy ý.
Future<void> checkPendingWrite() async {
  final fake = StorageChannelFake()..writeGate = Completer<void>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(storageChannel, fake.handle);
  var completed = false;
  final future = SecureSessionTokenStore().write(syntheticToken).then(
    /// Đánh dấu ACK đã đi qua adapter để kiểm trước/sau gate của plugin giả.
    (_) {
      completed = true;
    },
  );
  // Cho channel một vòng event loop; gate riêng đảm bảo không thể ACK sớm.
  await Future<void>.delayed(Duration.zero);
  expect(fake.calls, 1);
  expect(completed, isFalse);
  fake.writeGate!.complete();
  await future;
  expect(completed, isTrue);
}

/// Đăng ký các invariant boundary storage; mỗi test dùng state/channel fake độc lập.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'roundtrip preserves unrelated keys and disables implicit reset',
    checkRoundTrip,
  );
  test(
    'read write delete failures stay explicit and sanitized',
    checkOperationFailures,
  );
  test(
    'write ACK failure stays unknown even after persistence',
    checkUnknownWrite,
  );
  test('malformed reads and missing plugin fail closed', checkInvalidReads);
  test('invalid token is rejected before native I/O', checkInvalidWrites);
  test('write completion waits for native acknowledgement', checkPendingWrite);
}
