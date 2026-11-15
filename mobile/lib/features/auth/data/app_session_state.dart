import 'app_auth_failure.dart';
import 'full_session_profile.dart';
import '../../workspaces/data/available_workspace_page.dart';
import '../../workspaces/data/workspace_access_detail.dart';

/// Các trạng thái admission; chỉ full/limited đã được repository xác minh mới mở UI tương ứng.
enum AppSessionPhase {
  signedOut,
  checking,
  submitting,
  full,
  limited,
  loggingOut,
  pending,
  storageFailure,
  offline,
}

/// Snapshot công khai không có bearer/password hoặc DTO login chứa secret.
final class AppSessionState {
  /// Giữ thông tin hiển thị bất biến, không suy quyền từ cache hoặc dữ liệu lỗi thô.
  /// Input
  /// Param: phase — trạng thái đã được repository quyết định.
  /// Param: generation — phiên intent để consumer bỏ snapshot đã lỗi thời.
  /// Param: profile — chỉ có khi full đã admission, không dùng thay server authorization.
  /// Param: failure — mã lỗi đã khử dữ liệu nhạy cảm, không exception native.
  /// Param: workspaces — các summary tích lũy đã kiểm, copy immutable để UI không sửa snapshot.
  /// Param: nextWorkspaceCursor — cursor opaque trong RAM, null khi hết trang đã xác nhận.
  /// Param: workspacesLoaded — phân biệt chưa tải với confirmed empty.
  /// Param: selectedWorkspace — detail đã server recheck, không thay resource guard tiếp theo.
  AppSessionState({
    required this.phase,
    required this.generation,
    this.profile,
    this.failure,
    List<AvailableWorkspaceSummary> workspaces = const [],
    this.nextWorkspaceCursor,
    this.workspacesLoaded = false,
    this.selectedWorkspace,
  }) : workspaces = List.unmodifiable(workspaces);

  final AppSessionPhase phase;
  final int generation;
  final FullSessionProfile? profile;
  final AppAuthFailure? failure;
  final List<AvailableWorkspaceSummary> workspaces;
  final String? nextWorkspaceCursor;
  final bool workspacesLoaded;
  final WorkspaceAccessDetail? selectedWorkspace;
}
