import 'package:flutter/material.dart';

import '../lib/features/workspaces/presentation/workspace_selection_screen.dart';
import '../lib/features/workspaces/presentation/workspace_selection_state.dart';
import '../lib/ui/nexa_auth_theme.dart';

// Fixture tổng hợp CT-BOOTSTRAP-TWO-WORKSPACES; không có session hoặc membership thật.
const previewWorkspaceA = WorkspaceOption(
  id: '33333333-3333-4333-8333-333333333333',
  name: 'Workspace A',
  role: WorkspaceRole.admin,
  revision: 1,
  status: WorkspaceStatus.active,
);
const previewWorkspaceB = WorkspaceOption(
  id: '44444444-4444-4444-8444-444444444444',
  name: 'Workspace B',
  role: WorkspaceRole.user,
  revision: 2,
  status: WorkspaceStatus.active,
);

/// Entry riêng cho thiết kế/test, không thay main auth app hoặc vượt gate provider.
void main() => runApp(const WorkspacePreview());

/// Scenario ngoài sản phẩm, banner luôn phân biệt summary giả với phiên/quyền thật.
class WorkspacePreview extends StatefulWidget {
  /// Tạo harness RAM, không API/storage, không account demo có thể dùng đăng nhập.
  const WorkspacePreview({super.key});

  /// Output: controller theme/scenario giả chỉ sống cùng preview.
  @override
  State<WorkspacePreview> createState() => _WorkspacePreviewState();
}

class _WorkspacePreviewState extends State<WorkspacePreview> {
  WorkspaceSelectionState _state = WorkspaceSelectionState(
    phase: WorkspaceSelectionPhase.ready,
    options: const [previewWorkspaceA],
    hasMore: true,
  );
  bool _dark = false;
  bool _running = false;
  int _generation = 0;

  /// Reset scope giả để không nối các scenario bằng một generation đã unknown.
  /// Input
  /// Param: scenario — menu nội bộ, empty riêng vì không phải phase API.
  void _chooseScenario(String scenario) {
    if (_running) return;
    final phase = scenario == 'empty'
        ? WorkspaceSelectionPhase.ready
        : WorkspaceSelectionPhase.values.byName(scenario);
    setState(
      /// Bỏ snapshot cũ; ready bắt đầu lại trang1, các phase khác không có row/cache.
      () {
        _generation++;
        _state = WorkspaceSelectionState(
          phase: phase,
          options: scenario == 'ready' || scenario == 'loadingMore'
              ? const [previewWorkspaceA]
              : const [],
          hasMore: scenario == 'ready' || scenario == 'loadingMore',
        );
      },
    );
  }

  /// Fake latency để nhìn tiến trình, không dùng làm policy timeout hoặc request backend.
  Future<void> _pause() async {
    setState(
      /// Khóa scenario picker trong khi callback giả đang chờ để không đổi scope giữa chừng.
      () {
        _running = true;
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (!mounted) return;
    setState(
      /// Chỉ kết thúc latency RAM, không chứng nhận bất kỳ trạng thái server nào.
      () {
        _running = false;
      },
    );
  }

  /// Chọn summary chỉ tạo notice mô phỏng; không load devices hoặc mở protected route.
  /// Input
  /// Param: option — row giả bị bỏ qua, không dùng làm quyền hoặc request.
  Future<void> _select(WorkspaceOption option) async {
    await _pause();
    if (!mounted) return;
    setState(
      /// Selected của preview không là bằng chứng recheck membership thành công.
      () {
        _state = WorkspaceSelectionState(
          phase: WorkspaceSelectionPhase.selected,
        );
      },
    );
  }

  /// Trang2 giả có row B và kết thúc phân trang; không tạo cursor hoặc query API.
  Future<void> _loadMore() async {
    await _pause();
    if (!mounted) return;
    setState(
      /// Hai role khác nhau lấy từ fixture, không suy quyền từ tên hoặc account.
      () {
        _state = WorkspaceSelectionState(
          phase: WorkspaceSelectionPhase.ready,
          options: const [previewWorkspaceA, previewWorkspaceB],
        );
      },
    );
  }

  /// Recovery/refresh/logout trong preview chỉ reset scenario, không revoke session hoặc retry auth.
  Future<void> _reset() async {
    await _pause();
    if (mounted) _chooseScenario('ready');
  }

  /// Đổi palette trong RAM; theme không thay snapshot hoặc admission.
  void _toggleTheme() => setState(
    /// Chỉ lựa chọn thị giác của công cụ thiết kế, không auth preference persistence.
    () {
      _dark = !_dark;
    },
  );

  /// Menu có nhãn đầy đủ và dấu checked, không lẫn vào luồng nghiệp vụ sản phẩm.
  /// Input
  /// Param: context — ngữ cảnh menu của Flutter, không session.
  /// Output: các scenario từ state matrix và empty cuối trang.
  List<PopupMenuEntry<String>> _scenarios(BuildContext context) => [
    for (final phase in WorkspaceSelectionPhase.values)
      CheckedPopupMenuItem(
        value: phase.name,
        checked: !_state.isEmpty && _state.phase == phase,
        child: Text(phase.title),
      ),
    CheckedPopupMenuItem(
      value: 'empty',
      checked: _state.isEmpty,
      child: const Text('Không có workspace khả dụng'),
    ),
  ];

  /// Dựng banner/control bên ngoài component, giữ mock rõ ràng ở mọi state kể cả selected.
  /// Input
  /// Param: context — framework host, không chứa account/token.
  /// Output: preview riêng có cùng theme Nexa và không navigation/auth giả.
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
                  PopupMenuButton<String>(
                    key: const ValueKey('workspace-preview-scenario'),
                    tooltip: 'Chọn trạng thái mô phỏng',
                    enabled: !_running,
                    onSelected: _chooseScenario,
                    itemBuilder: _scenarios,
                    icon: const Icon(Icons.tune_outlined),
                  ),
                ],
              ),
            ),
            Expanded(
              child: WorkspaceSelectionScreen(
                key: ValueKey(_generation),
                state: _state,
                onSelect: _select,
                onRefresh: _reset,
                onLoadMore: _loadMore,
                onRecover: _reset,
                onLogout: _reset,
                onToggleTheme: _toggleTheme,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
