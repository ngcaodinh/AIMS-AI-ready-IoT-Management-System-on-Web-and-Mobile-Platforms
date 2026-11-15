import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../lib/main.dart' as application;
import '../lib/features/auth/presentation/app_auth_application.dart';
import '../lib/features/auth/presentation/login_screen.dart';

/// Kiểm blocking page trên Android engine với main thật, không dùng auth preview hay credential.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native main blocks missing HTTPS configuration',

    /** Không cho lệnh vô tình mang origin thật mở I/O trong ca kiểm cấu hình thiếu.
     * Input
     * Param: tester — runner native để quan sát app được main khởi tạo.
     */
    (tester) async {
      expect(
        const String.fromEnvironment('AUTH_API_BASE_URL'),
        isEmpty,
        reason: 'Run this configuration suite without AUTH_API_BASE_URL.',
      );
      application.main();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('app-configuration')), findsOneWidget);
      expect(find.text('Ứng dụng chưa sẵn sàng'), findsOneWidget);
      expect(find.byType(AppAuthApplication), findsNothing);
      expect(find.byType(LoginScreen), findsNothing);
      expect(find.byKey(const ValueKey('auth-submit')), findsNothing);
      debugPrint('NATIVE_MAIN_CONFIG_MISSING_VERIFIED');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'native main rejects cleartext API origin',

    /** Dùng HTTP loopback để chứng minh negative config không thành form hoặc fallback mock.
     * Input
     * Param: tester — dựng composition main thật trên native engine, không gọi backend lab.
     */
    (tester) async {
      await tester.pumpWidget(
        const application.MainApp(apiOrigin: 'http://127.0.0.1:3000'),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('app-configuration')), findsOneWidget);
      expect(find.text('Ứng dụng chưa sẵn sàng'), findsOneWidget);
      expect(find.byType(AppAuthApplication), findsNothing);
      expect(find.byType(LoginScreen), findsNothing);
      expect(find.byKey(const ValueKey('auth-submit')), findsNothing);
      debugPrint('NATIVE_MAIN_CONFIG_HTTP_REJECTED_VERIFIED');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
