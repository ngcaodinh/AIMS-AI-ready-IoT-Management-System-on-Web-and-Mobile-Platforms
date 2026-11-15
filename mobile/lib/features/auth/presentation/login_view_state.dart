/// Trạng thái hiển thị do host cấp; enum này không chứng minh token hoặc quyền workspace.
enum LoginViewState {
  ready,
  submitting,
  rejected,
  networkUnavailable,
  storageFailure,
  pending,
  conflict,
  permissionDenied,
  confirmed;

  /// Chỉ hai trạng thái chắc chắn chưa có intent đang chờ mới cho người dùng gửi form.
  bool get canSubmit => this == ready || this == rejected;

  /// Đối soát chỉ dành cho trạng thái bị khóa; không chen intent khi host đang gửi hoặc đã xác minh.
  bool get canRecover => !canSubmit && this != submitting && this != confirmed;

  /// Nhãn ngắn dùng cho thông báo và bộ chọn scenario của công cụ thiết kế.
  String get label => switch (this) {
    ready => 'Sẵn sàng',
    submitting => 'Đang đăng nhập',
    rejected => 'Thông tin chưa hợp lệ',
    networkUnavailable => 'Mất kết nối',
    storageFailure => 'Chưa thể bảo vệ phiên',
    pending => 'Cần xác minh trạng thái',
    conflict => 'Trạng thái phiên đã thay đổi',
    permissionDenied => 'Không thể tiếp tục',
    confirmed => 'Đã xác minh phiên',
  };

  /// Copy cố định không chứa lỗi backend, tài khoản tồn tại hay dữ liệu phiên chưa được kiểm.
  String get message => switch (this) {
    ready => '',
    submitting => 'Đang xử lý yêu cầu. Vui lòng chờ trong giây lát.',
    rejected => 'Thông tin đăng nhập không hợp lệ. Kiểm tra email và mật khẩu.',
    networkUnavailable =>
      'Kiểm tra kết nối mạng rồi thử lại. Yêu cầu không được tự gửi lại.',
    storageFailure =>
      'Chưa thể lưu phiên an toàn. Bạn chưa được đăng nhập vào hệ thống.',
    pending => 'Chưa thể xác nhận kết quả. Kiểm tra trạng thái phiên trước khi tiếp tục.',
    conflict => 'Cần xác minh lại phiên trước khi gửi yêu cầu mới.',
    permissionDenied =>
      'Bạn chưa thể thực hiện thao tác này. Vui lòng xác minh lại phiên.',
    confirmed => 'Phiên đã được xác minh. Đang chuẩn bị bước tiếp theo.',
  };
}
