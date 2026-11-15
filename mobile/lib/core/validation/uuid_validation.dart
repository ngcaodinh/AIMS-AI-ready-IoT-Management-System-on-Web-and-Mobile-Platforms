// Giữ cùng policy UUID version1–8/variant8–b với consumer Web; không normalize định danh từ wire.
final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  caseSensitive: false,
);

/// Kiểm cấu trúc UUID dùng chung cho ba consumer để không lệch policy khi sửa boundary.
/// Input
/// Param: value — chuỗi định danh chưa đáng tin; caller kiểm kiểu trước khi gọi.
/// Output: true khi đúng cấu trúc hiện hành, không chứng minh identity tồn tại hoặc có quyền.
bool isUuid(String value) => _uuidPattern.hasMatch(value);
