/// Phase do host quyết định; không dùng presentation state làm bằng chứng server đã đổi password/revoke.
enum PasswordChangeState {
  ready,
  submitting,
  rejected,
  networkUnavailable,
  rateLimited,
  serviceUnavailable,
  pending,
  conflict,
  permissionDenied,
  storageFailure,
  success;

  /// Output: chỉ phase có kết quả rõ mới cho người dùng nhập và chủ động gửi mutation mới.
  bool get canSubmit => switch (this) {
    ready || rejected || networkUnavailable => true,
    _ => false,
  };

  /// Output: loading giữ form khóa; unknown hoặc phiên không chắc chắn không hiện credential input.
  bool get showsForm => canSubmit || this == submitting;

  /// Output: đối soát riêng không được tự gửi lại password hoặc tự bỏ fence unknown cục bộ.
  bool get canRecover => !showsForm && this != success;

  /// Output: thoát sau kết quả rõ hoặc204; host vẫn chịu revoke/cleanup, không phải route bypass.
  bool get canLeave => canSubmit || this == success;

  /// Output: nhãn cố định cho menu preview và semantics, không chứa lỗi thô hoặc thông tin account.
  String get label => switch (this) {
    ready => 'Sẵn sàng',
    submitting => 'Đang đổi mật khẩu',
    rejected => 'Chưa đổi được mật khẩu',
    networkUnavailable => 'Mất kết nối',
    rateLimited => 'Cần chờ trước khi thử lại',
    serviceUnavailable => 'Dịch vụ chưa sẵn sàng',
    pending => 'Chưa xác nhận kết quả',
    conflict => 'Trạng thái phiên đã thay đổi',
    permissionDenied => 'Không thể tiếp tục',
    storageFailure => 'Chưa thể dọn phiên an toàn',
    success => 'Đã đổi mật khẩu',
  };

  /// Output: copy an toàn cho live region; unknown không khẳng định commit hoặc rollback.
  String get message => switch (this) {
    ready => '',
    submitting => 'Đang xử lý. Vui lòng chờ, không gửi thêm yêu cầu.',
    rejected => 'Kiểm tra mật khẩu hiện tại rồi nhập lại thông tin để thử.',
    networkUnavailable => 'Kiểm tra kết nối. Yêu cầu không được tự gửi lại.',
    rateLimited => 'Hãy chờ hết thời gian giới hạn rồi kiểm tra lại.',
    serviceUnavailable =>
      'Chưa thể thực hiện lúc này. Kiểm tra trạng thái trước khi thử lại.',
    pending =>
      'Chưa xác nhận mật khẩu đã đổi hay chưa. Không tự gửi lại yêu cầu.',
    conflict => 'Cần xác minh lại phiên trước khi tiếp tục.',
    permissionDenied =>
      'Phiên hiện tại chưa cho phép thao tác này. Hãy xác minh lại.',
    storageFailure =>
      'Chưa thể dọn phiên trên thiết bị. Nội dung được bảo vệ vẫn khóa.',
    success =>
      'Hãy đăng nhập lại bằng mật khẩu mới. Các phiên cũ đã bị thu hồi.',
  };
}
