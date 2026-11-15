import 'package:flutter/material.dart';

import '../lib/features/auth/presentation/login_screen.dart';
import '../lib/features/auth/presentation/login_view_state.dart';
import '../lib/ui/nexa_auth_theme.dart';

/// Entry thiết kế riêng, không thay main app hoặc nối API/token thật khi checkpoint còn mở.
void main() => runApp(const AuthPreview());

/// Harness chỉ dùng thiết kế/test; banner luôn phân biệt rõ state mô phỏng với session thật.
class AuthPreview extends StatefulWidget {
  /// Tạo công cụ xem component dùng lại, không tạo tài khoản demo có thể đăng nhập hệ thống.
  const AuthPreview({super.key});

  /// Giữ lựa chọn scenario/theme trong RAM, không storage hoặc dữ liệu auth.
  @override
  State<AuthPreview> createState() => _AuthPreviewState();
}

class _AuthPreviewState extends State<AuthPreview> {
  LoginViewState _state = LoginViewState.ready;
  bool _dark = false;
  bool _requestRunning = false;
  int _generation = 0;

  /// Chọn state giả và tạo form generation mới, không xác nhận quyền hoặc thực thi request.
  /// Input
  /// Param: state — scenario nội bộ do tester chọn, không parse từ link hoặc response API.
  void _selectState(LoginViewState? state) {
    if (state == null || _requestRunning) return;
    setState(
      /// Bỏ input của scenario cũ để không giữ credential trong công cụ thiết kế.
      () {
        _state = state;
        _generation++;
      },
    );
  }

  /// Mô phỏng loading rồi từ chối; mọi input đều không gửi, không lưu hoặc log.
  /// Input
  /// Param: email — dữ liệu thử không được sử dụng để gọi backend.
  /// Param: password — dữ liệu thử không giữ trong field của harness hoặc dùng retry.
  Future<void> _simulateSubmit(String email, String password) async {
    setState(
      /// Chỉ fake latency để tester nhìn loading, không dùng timeout này làm policy API.
      () {
        _state = LoginViewState.submitting;
        _requestRunning = true;
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 650));
    if (!mounted) return;
    setState(
      /// Outcome giả cố định để không có credential demo nào tự mở protected UI.
      () {
        _state = LoginViewState.rejected;
        _requestRunning = false;
      },
    );
  }

  /// Reset scenario sau đối soát giả, không gọi lại submit hoặc tuyên bố đã revoke server.
  Future<void> _simulateRecovery() async {
    _selectState(LoginViewState.ready);
  }

  /// Đổi theme chỉ trong RAM của harness, không truy cập auth/preferences.
  void _toggleTheme() => setState(
    /// Cùng component được kiểm lại ở cả palette, không dùng theme để thay state nghiệp vụ.
    () {
      _dark = !_dark;
    },
  );

  /// Đưa scenario vào menu thay vì chiếm chiều cao form, vẫn giữ lựa chọn và nhãn đầy đủ.
  /// Input
  /// Param: context — ngữ cảnh menu của framework, không nguồn dữ liệu phiên.
  /// Output: lựa chọn nội bộ có dấu checked cho trạng thái mô phỏng hiện tại.
  List<PopupMenuEntry<LoginViewState>> _buildScenarios(BuildContext context) =>
      [
        for (final state in LoginViewState.values)
          CheckedPopupMenuItem<LoginViewState>(
            value: state,
            checked: state == _state,
            child: Text(state.label),
          ),
      ];

  /// Dựng banner/scenario controls ngoài component sản phẩm để không lẫn implementation vào flow thật.
  /// Input
  /// Param: context — chỉ dùng framework/theme, không account hoặc session.
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
                  Semantics(
                    label: 'Trạng thái mô phỏng: ${_state.label}',
                    child: PopupMenuButton<LoginViewState>(
                      key: const ValueKey('preview-state'),
                      tooltip: 'Chọn trạng thái mô phỏng',
                      initialValue: _state,
                      enabled: !_requestRunning,
                      onSelected: _selectState,
                      itemBuilder: _buildScenarios,
                      icon: const Icon(Icons.tune_outlined),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: LoginScreen(
                key: ValueKey(_generation),
                state: _state,
                onSubmit: _simulateSubmit,
                onRecover: _simulateRecovery,
                onToggleTheme: _toggleTheme,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
