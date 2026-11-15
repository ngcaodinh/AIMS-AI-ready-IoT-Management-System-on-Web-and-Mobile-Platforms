import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../lib/features/auth/data/session_token_store.dart';

// Giá trị tổng hợp không hoạt động; namespace phiên phải rỗng trước PoC, không ghi đè credential.
const sessionMarker = 'synthetic-adapter-session-not-a-real-credential';
const proofMarker = 'synthetic-adapter-proof-not-a-real-installation';
const proofKey = 'nexa.auth.adapter-isolation-poc.v1';
const proofStorage = FlutterSecureStorage(aOptions: AndroidOptions());
const sessionStore = SecureSessionTokenStore();

/// Kiểm chính adapter cấu hình namespace/reset=false và giữ marker proof ở storage khác.
/// Input
/// Param: tester — runner Android thật; không khởi động app auth hoặc gọi backend.
/// Side effects: tạo hai marker PoC khi cả hai key rỗng, không ghi đè key có dữ liệu.
Future<void> persistAdapterProbe(WidgetTester tester) async {
  expect(Platform.isAndroid, isTrue);
  await tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: Text('Nexa IoT — adapter PoC'))),
  );
  expect(
    await sessionStore.read() == null,
    isTrue,
    reason: 'Session key must be empty',
  );
  expect(
    await proofStorage.read(key: proofKey) == null,
    isTrue,
    reason: 'Proof probe key must be empty',
  );
  await proofStorage.write(key: proofKey, value: proofMarker);
  await sessionStore.write(sessionMarker);
  expect(await sessionStore.read() == sessionMarker, isTrue);
  expect(await proofStorage.read(key: proofKey) == proofMarker, isTrue);
}

/// Kiểm marker cũ qua process/cold boot rồi xóa đúng key; không đụng dữ liệu ngoài PoC.
/// Input
/// Param: tester — runner cùng package/UID, stage trước phải dùng --no-uninstall.
/// Side effects: xóa marker phiên và proof chỉ sau khi xác minh đúng giá trị tổng hợp.
Future<void> restoreAdapterProbe(WidgetTester tester) async {
  expect(Platform.isAndroid, isTrue);
  await tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: Text('Nexa IoT — adapter PoC'))),
  );
  expect(await sessionStore.read() == sessionMarker, isTrue);
  expect(await proofStorage.read(key: proofKey) == proofMarker, isTrue);
  await sessionStore.delete();
  expect(await sessionStore.read() == null, isTrue);
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
