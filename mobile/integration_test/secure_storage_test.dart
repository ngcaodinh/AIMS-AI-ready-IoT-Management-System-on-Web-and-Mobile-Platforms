import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Namespace/value chỉ dùng cho PoC, không là session hoặc credential hoạt động.
const probeKey = 'nexa.auth.storage-poc.v1';
const probeValue = 'synthetic-poc-not-an-auth-token';
const storage = FlutterSecureStorage(aOptions: AndroidOptions());

/// Ghi marker tổng hợp bằng plugin thật và chỉ so sánh boolean để failure output không in token.
/// Input
/// Param: tester — runner device; thao tác không gọi provider và không đọc key của tài khoản thật.
Future<void> persistProbe(WidgetTester tester) async {
  expect(Platform.isAndroid, isTrue, reason: 'Storage PoC requires Android');
  await tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: Text('Nexa IoT — storage PoC'))),
  );
  await storage.write(key: probeKey, value: probeValue);
  expect(await storage.read(key: probeKey) == probeValue, isTrue);
}

/// Đọc marker do stage trước tạo rồi dọn đúng key PoC; không xóa toàn bộ secure storage.
/// Input
/// Param: tester — runner device; chạy riêng --plain-name/--no-uninstall ở process sau để kiểm persistence qua relaunch.
Future<void> readAndDeleteProbe(WidgetTester tester) async {
  expect(Platform.isAndroid, isTrue, reason: 'Storage PoC requires Android');
  await tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: Text('Nexa IoT — storage PoC'))),
  );
  expect(await storage.read(key: probeKey) == probeValue, isTrue);
  await storage.delete(key: probeKey);
  expect(await storage.read(key: probeKey) == null, isTrue);
}

/// Đăng ký hai stage có thể chạy trong hai lần cài/khởi động APK test riêng biệt trên cùng target.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('persist probe', persistProbe);
  testWidgets('read persisted probe and delete', readAndDeleteProbe);
}
