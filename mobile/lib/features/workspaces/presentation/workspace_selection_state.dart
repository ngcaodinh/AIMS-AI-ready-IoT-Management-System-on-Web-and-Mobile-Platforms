/// Vai trò hiển thị từ summary; không dùng enum phía client để cấp quyền tài nguyên.
enum WorkspaceRole {
  admin,
  user;

  /// Output: nhãn tiếng Việt cho đúng hai vai trò workspace của contract.
  String get label => switch (this) {
    admin => 'Quản trị viên',
    user => 'Thành viên',
  };
}

/// Trạng thái summary có thể có trong contract; bootstrap bình thường chỉ trả active.
enum WorkspaceStatus {
  active,
  suspended,
  archived;

  /// Output: giải thích vì sao một summary ngoài active không được chọn.
  String get label => switch (this) {
    active => 'Đang hoạt động',
    suspended => 'Đã tạm dừng',
    archived => 'Đã lưu trữ',
  };
}

/// Dữ liệu row bất biến do host map từ response đã validate; không chứa token/cursor hoặc dữ liệu thiết bị.
final class WorkspaceOption {
  /// Giữ nguyên identity/revision để callback cũ không chọn summary đã thay đổi.
  /// Input
  /// Param: id — UUID từ contract do boundary host kiểm, không tự tạo quyền từ định danh.
  /// Param: name — plain text tên workspace, không HTML.
  /// Param: role — membership role được host nhận từ server, chỉ hiển thị.
  /// Param: revision — revision của summary, chưa thay membership recheck.
  /// Param: status — chỉ active được phép phát intent lựa chọn.
  const WorkspaceOption({
    required this.id,
    required this.name,
    required this.role,
    required this.revision,
    required this.status,
  });

  final String id;
  final String name;
  final WorkspaceRole role;
  final int revision;
  final WorkspaceStatus status;
}

/// Presentation states không chứng nhận session hoặc quyền; host C1 chịu admission và navigation.
enum WorkspaceSelectionPhase {
  loading,
  ready,
  loadingMore,
  offline,
  error,
  permissionDenied,
  stale,
  pending,
  storageFailure,
  selected;

  /// Output: tiêu đề trạng thái cố định, không echo message thô từ API/exception.
  String get title => switch (this) {
    loading => 'Đang tải workspace',
    ready => 'Chọn workspace',
    loadingMore => 'Đang tải thêm workspace',
    offline => 'Không có kết nối',
    error => 'Không tải được danh sách',
    permissionDenied => 'Không thể truy cập workspace',
    stale => 'Danh sách đã thay đổi',
    pending => 'Cần xác minh trạng thái',
    storageFailure => 'Chưa thể bảo vệ phiên',
    selected => 'Đã chọn workspace',
  };

  /// Output: hướng xử lý cho người dùng, không biến error/offline thành list rỗng hoặc logout.
  String get description => switch (this) {
    loading => 'Vui lòng chờ trong khi danh sách được cập nhật.',
    ready => 'Chọn không gian làm việc bạn muốn sử dụng.',
    loadingMore => 'Các lựa chọn tạm khóa trong khi tải trang tiếp theo.',
    offline => 'Kiểm tra kết nối rồi tải lại danh sách.',
    error => 'Vui lòng tải lại để tiếp tục.',
    permissionDenied =>
      'Quyền truy cập có thể đã đổi. Tải lại danh sách trước khi chọn.',
    stale => 'Tải lại danh sách để dùng thông tin mới nhất.',
    pending =>
      'Kiểm tra trạng thái trước khi tiếp tục. Chưa thể chọn workspace.',
    storageFailure => 'Kiểm tra trạng thái phiên trước khi tiếp tục.',
    selected =>
      'Vui lòng chờ quá trình kiểm tra hoàn tất trước khi mở nội dung.',
  };

  /// Output: những snapshot cho phép host tải lại GET chủ động, không phải retry selection.
  bool get canRefresh => switch (this) {
    ready || offline || error || permissionDenied || stale => true,
    _ => false,
  };
}

/// Snapshot presentation độc lập với wire/repository; hasMore không đưa cursor opaque vào widget.
final class WorkspaceSelectionState {
  /// Chụp list để host không sửa ngầm dữ liệu của callback/frame đang render.
  /// Input
  /// Param: phase — trạng thái host đã đối soát cho account generation hiện tại.
  /// Param: options — các row typed, chỉ hiện ở ready/loadingMore.
  /// Param: hasMore — còn cursor hợp lệ; list rỗng khi true chưa phải empty cuối.
  /// Errors: ArgumentError cố định nếu row thiếu identity/revision hoặc trùng identity.
  WorkspaceSelectionState({
    required this.phase,
    List<WorkspaceOption> options = const [],
    this.hasMore = false,
  }) : options = List.unmodifiable(options) {
    final identities = <String>{};
    for (final option in this.options) {
      // Chống snapshot mơ hồ; validate JSON/UUID và authorization vẫn ở boundary host/backend.
      if (option.id.isEmpty ||
          option.name.trim().isEmpty ||
          option.revision < 1 ||
          !identities.add(option.id)) {
        throw ArgumentError('Invalid workspace presentation snapshot');
      }
    }
  }

  final WorkspaceSelectionPhase phase;
  final List<WorkspaceOption> options;
  final bool hasMore;

  /// Output: empty chỉ sau snapshot ready cuối, không suy từ loading hoặc cursor còn.
  bool get isEmpty =>
      phase == WorkspaceSelectionPhase.ready && options.isEmpty && !hasMore;
}
