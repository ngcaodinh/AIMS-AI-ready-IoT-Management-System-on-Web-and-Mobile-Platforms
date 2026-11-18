import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../lib/features/auth/data/session_token_store.dart';

// Giá trị tổng hợp không hoạt động; namespace phiên phải rỗng trước PoC, không ghi đè credential.
const sessionMarker = 'synthetic-adapter-session-not-a-real-credential';
const proofMarker = 'synthetic-adapter-proof-not-a-real-installation';
const logoutIntentMarker = 'synthetic-adapter-logout-intent';
const proofKey = 'nexa.auth.adapter-isolation-poc.v1';
const proofStorage = FlutterSecureStorage(aOptions: AndroidOptions());
const sessionStore = SecureSessionTokenStore();

/// Kiểm adapter lưu active session/outbox trong secure namespace và giữ proof ở storage khác.
/// Input
/// Param: tester — runner Android thật; không khởi động app auth hoặc gọi backend.
/// Side effects: tạo session/outbox/proof marker tổng hợp khi các key rỗng, không ghi đè key có dữ liệu.
Future<void> persistAdapterProbe(WidgetTester tester) async {
  expect(Platform.isAndroid, isTrue);
  await tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: Text('Nexa IoT — adapter PoC'))),
  );
  expect(
    await sessionStore.readSession() == null,
    isTrue,
    reason: 'Session key must be empty',
  );
  expect(
    await proofStorage.read(key: proofKey) == null,
    isTrue,
    reason: 'Proof probe key must be empty',
  );
  expect(
    await sessionStore.readLogoutIntent() == null,
    isTrue,
    reason: 'Logout intent key must be empty',
  );
  await proofStorage.write(key: proofKey, value: proofMarker);
  final session = StoredSessionCredential(
    token: sessionMarker,
    expiresAt: DateTime.utc(2099, 1, 1),
  );
  await sessionStore.writeSession(session);
  await sessionStore.writeLogoutIntent(
    PendingLogoutIntent(
      intentId: logoutIntentMarker,
      sessionToken: sessionMarker,
      expiresAt: session.expiresAt,
      attemptCount: 1,
      nextAttemptAt: DateTime.utc(2026, 11, 16),
    ),
  );
  final restoredSession = await sessionStore.readSession();
  // So sánh boolean để lỗi assertion không thể in bearer khỏi secure storage.
  expect(
    restoredSession?.token == sessionMarker,
    isTrue,
    reason: 'Restored token must match the synthetic marker',
  );
  expect(restoredSession?.expiresAt, session.expiresAt);
  final restoredIntent = await sessionStore.readLogoutIntent();
  expect(
    restoredIntent?.intentId == logoutIntentMarker,
    isTrue,
    reason: 'Logout intent marker must be preserved',
  );
  expect(
    restoredIntent?.sessionToken == sessionMarker,
    isTrue,
    reason: 'Logout intent must retain only the synthetic session marker',
  );
  expect(await proofStorage.read(key: proofKey) == proofMarker, isTrue);
}

/// Kiểm khôi phục active session và outbox sau process stop rồi xóa đúng key.
/// Input
/// Param: tester — runner cùng package/UID, stage trước phải dùng --no-uninstall.
/// Side effects: xóa session, outbox và proof marker chỉ sau khi xác minh giá trị tổng hợp.
Future<void> restoreAdapterProbe(WidgetTester tester) async {
  expect(Platform.isAndroid, isTrue);
  await tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: Text('Nexa IoT — adapter PoC'))),
  );
  final restoredSession = await sessionStore.readSession();
  // So sánh boolean để lỗi assertion không thể in bearer khỏi secure storage.
  expect(
    restoredSession?.token == sessionMarker,
    isTrue,
    reason: 'Restored token must match the synthetic marker',
  );
  expect(restoredSession?.expiresAt, DateTime.utc(2099, 1, 1));
  final restoredIntent = await sessionStore.readLogoutIntent();
  expect(
    restoredIntent?.intentId == logoutIntentMarker,
    isTrue,
    reason: 'Pending logout intent must survive the process stop',
  );
  expect(
    restoredIntent?.sessionToken == sessionMarker,
    isTrue,
    reason: 'Restored logout intent must retain only the synthetic marker',
  );
  expect(restoredIntent?.expiresAt, DateTime.utc(2099, 1, 1));
  expect(restoredIntent?.attemptCount, 1);
  expect(restoredIntent?.nextAttemptAt, DateTime.utc(2026, 11, 16));
  expect(await proofStorage.read(key: proofKey) == proofMarker, isTrue);
  await sessionStore.deleteSession();
  await sessionStore.deleteLogoutIntent();
  expect(await sessionStore.readSession(), isNull);
  expect(await sessionStore.readLogoutIntent(), isNull);
  // Xóa phiên không được làm mất proof dùng qua logout; đây chỉ là marker mô phỏng proof.
  expect(await proofStorage.read(key: proofKey) == proofMarker, isTrue);
  await proofStorage.delete(key: proofKey);
  expect(await proofStorage.read(key: proofKey) == null, isTrue);
}

/// Đăng ký hai stage native cần chạy riêng với --no-uninstall trên cùng AVD/UID.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('persist adapter probe', persistAdapterProbe);
  testWidgets('restore adapter probe and preserve proof', restoreAdapterProbe);
}
