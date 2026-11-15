import 'package:flutter/material.dart';

import 'features/auth/data/app_auth_api.dart';
import 'features/auth/data/app_auth_tls_configuration.dart';
import 'features/auth/data/app_session_repository.dart';
import 'features/auth/data/session_token_store.dart';
import 'features/auth/presentation/app_auth_application.dart';
import 'features/auth/presentation/app_auth_coordinator.dart';
import 'ui/nexa_auth_theme.dart';

/// Khởi tạo binding trước secure storage; main dùng API thật, không chạy preview/mock.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MainApp());
}

class MainApp extends StatefulWidget {
  /**
   * Chốt public config khi build để main dùng API thật; không đọc process environment hoặc file env.
   * Input
   * Param: key — định danh widget lifetime do Flutter sở hữu.
   * Param: apiOrigin — HTTPS origin; mặc định dart-define AUTH_API_BASE_URL.
   * Param: labCertificate — public DER Base64 của lab debug, mặc định AUTH_LAB_CA_CERT; không credential.
   */
  const MainApp({
    super.key,
    this.apiOrigin = const String.fromEnvironment('AUTH_API_BASE_URL'),
    this.labCertificate = const String.fromEnvironment('AUTH_LAB_CA_CERT'),
  });
  final String apiOrigin;
  final String labCertificate;

  /// Output: composition giữ một repository/store suốt lifetime.
  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> {
  AppAuthCoordinator? _coordinator;

  /// Kiểm origin/trust trước repository và storage; lỗi cấu hình không dùng fallback mock hoặc HTTP.
  @override
  void initState() {
    super.initState();
    try {
      final uri = Uri.tryParse(widget.apiOrigin);
      if (uri == null) return;
      final createClient = createAuthHttpClientFactory(
        uri,
        labCertificate: widget.labCertificate,
      );
      final api = HttpAppAuthApi(uri, createClient: createClient);
      _coordinator = AppAuthCoordinator(
        repository: AppSessionRepository(
          api: api,
          workspaceApi: api,
          passwordApi: api,
          tokenStore: const SecureSessionTokenStore(),
        ),
      );
    } on ArgumentError catch (_) {
      // Không đưa URL/cấu hình/exception vào UI; thiếu/sai origin luôn khóa trước storage/network.
      _coordinator = null;
    }
  }

  /// Hiển thị App thật hoặc blocking config page; host chịu dispose/drain coordinator khi bị gỡ.
  /// Input
  /// Param: context — theme/constraints của root, không auth authority.
  @override
  Widget build(BuildContext context) {
    final coordinator = _coordinator;
    if (coordinator != null)
      return AppAuthApplication(coordinator: coordinator);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: nexaAuthTheme(Brightness.light),
      darkTheme: nexaAuthTheme(Brightness.dark),
      home: const AuthStatusScreen(
        key: ValueKey('app-configuration'),
        title: 'Ứng dụng chưa sẵn sàng',
        description: 'Chưa thể kết nối máy chủ. Liên hệ quản trị viên để cấu hình ứng dụng.',
        error: true,
      ),
    );
  }
}
