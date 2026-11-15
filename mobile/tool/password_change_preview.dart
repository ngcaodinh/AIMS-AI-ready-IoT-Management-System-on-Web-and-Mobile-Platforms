import 'package:flutter/material.dart';

import '../lib/features/auth/presentation/login_screen.dart';
import '../lib/features/auth/presentation/login_view_state.dart';
import '../lib/features/auth/presentation/password_change_screen.dart';
import '../lib/features/auth/presentation/password_change_state.dart';
import '../lib/ui/nexa_auth_theme.dart';

/// Entry thiết kế độc lập; không thay main app, xác thực account hoặc gọi API/storage.
void main() => runApp(const PasswordChangePreview());

/// Harness có banner mock luôn hiện, cho xem limited form/recovery và quay về login mô phỏng.
class PasswordChangePreview extends StatefulWidget {
  /// Tạo preview không có credential demo hoặc dữ liệu account thật.
  const PasswordChangePreview({super.key});

  /// Lưu scenario/theme chỉ trong RAM, không ghi password/token.
  @override
  State<PasswordChangePreview> createState() => _PasswordChangePreviewState();
}

class _PasswordChangePreviewState extends State<PasswordChangePreview> {
  PasswordChangeState _state = PasswordChangeState.ready;
  bool _dark = false;
  bool _running = false;
  bool _atLogin = false;
  int _generation = 0;

  /// Chọn scenario nội bộ và bỏ form cũ; không nhận state từ URL/API để cấp quyền.
  /// Input
  /// Param: state — phase do tester chọn trong menu mock.
  void _selectState(PasswordChangeState state) {
    if (_running) return;
    setState(
      /// Key mới là generation của preview, không thể dùng thay phiên server.
      () {
        _state = state;
        _generation++;
        _atLogin = false;
      },
    );
  }

  /// Chỉ fake latency rồi từ chối; input không gửi, log, lưu hoặc dùng để tự retry.
  /// Input
  /// Param: currentPassword — dữ liệu thử bỏ ngay, không kiểm account thật.
  /// Param: newPassword — dữ liệu thử không lưu vào field của harness.
  Future<void> _simulateChange(
    String currentPassword,
    String newPassword,
  ) async {
    setState(
      /// Latency phục vụ nhìn loading, không là timeout/policy API.
      () {
        _running = true;
        _state = PasswordChangeState.submitting;
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 650));
    if (!mounted) return;
    setState(
      /// Không tạo session/full workspace hoặc giả đã đổi credential từ input thử.
      () {
        _running = false;
        _state = PasswordChangeState.rejected;
      },
    );
  }

  /// Reset scenario sau đối soát giả; không xác nhận commit/revoke hoặc retry password.
  Future<void> _simulateRecovery() async =>
      _selectState(PasswordChangeState.ready);

  /// Hiện LoginScreen mô phỏng sau action thoát; không logout/revoke server.
  Future<void> _simulateLeave() async => setState(
    /// Màn mới không giữ credential của password form.
    () {
      _atLogin = true;
      _generation++;
    },
  );

  /// Đi từ login mock sang nhánh limited để tester xem navigation, không xác thực credential.
  /// Input
  /// Param: email — dữ liệu thử không được sử dụng hoặc ghi log.
  /// Param: password — dữ liệu thử không được giữ cho submit lại.
  Future<void> _simulateLimitedLogin(String email, String password) async =>
      _selectState(PasswordChangeState.ready);

  /// Đổi palette ở RAM, không liên quan preferences hoặc auth state.
  void _toggleTheme() => setState(
    /// Dùng cùng theme Nexa cho cả hai màn preview.
    () {
      _dark = !_dark;
    },
  );

  /// Tạo menu scenario với nhãn rõ; success trong menu chỉ là mô phỏng hiển thị.
  /// Input
  /// Param: context — context của framework menu, không nguồn dữ liệu account.
  /// Output: danh sách lựa chọn mock có trạng thái checked.
  List<PopupMenuEntry<PasswordChangeState>> _buildScenarios(
    BuildContext context,
  ) => [
    for (final state in PasswordChangeState.values)
      // Row tự tăng chiều cao theo chữ2×; CheckedPopupMenuItem/ListTile có thể để text tràn vùng hit khi nhiều dòng.
      PopupMenuItem(
        value: state,
        child: Semantics(
          selected: !_atLogin && state == _state,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                ExcludeSemantics(
                  child: Icon(
                    !_atLogin && state == _state ? Icons.check : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(state.label)),
              ],
            ),
          ),
        ),
      ),
  ];

  /// Dựng banner ngoài component sản phẩm để không lẫn điều khiển thử nghiệm vào luồng thật.
  /// Input
  /// Param: context — framework context, không chứa account/session của ứng dụng thật.
  /// Output: preview có nhãn mock ở cả password screen và login screen.
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: nexaAuthTheme(Brightness.light),
    darkTheme: nexaAuthTheme(Brightness.dark),
    themeMode: _dark ? ThemeMode.dark : ThemeMode.light,
    home: Material(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 12, 0),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'BẢN THIẾT KẾ — DỮ LIỆU MÔ PHỎNG',
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.3,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  PopupMenuButton<PasswordChangeState>(
                    key: const ValueKey('password-preview-state'),
                    tooltip: 'Chọn trạng thái mô phỏng',
                    enabled: !_running,
                    onSelected: _selectState,
                    itemBuilder: _buildScenarios,
                    icon: const Icon(Icons.tune_outlined),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _atLogin
                  ? LoginScreen(
                      key: ValueKey('login-$_generation'),
                      state: LoginViewState.ready,
                      onSubmit: _simulateLimitedLogin,
                      onToggleTheme: _toggleTheme,
                    )
                  : PasswordChangeScreen(
                      key: ValueKey(_generation),
                      state: _state,
                      onSubmit: _simulateChange,
                      onRecover: _simulateRecovery,
                      onLeave: _simulateLeave,
                      onToggleTheme: _toggleTheme,
                    ),
            ),
          ],
        ),
      ),
    ),
  );
}
