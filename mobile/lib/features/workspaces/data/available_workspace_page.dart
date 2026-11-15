import '../../../core/validation/uuid_validation.dart';

/// Summary bất biến của default ACTIVE bootstrap; không dùng role/revision như quyền truy cập tài nguyên.
final class AvailableWorkspaceSummary {
  /// Chỉ factory kiểm wire được tạo summary; giữ plain text và định danh nguyên bản.
  /// Input
  /// Param: id — UUID đã kiểm cùng policy consumer Web/login hiện hành.
  /// Param: name — tên dạng string, không trim/normalize hoặc render HTML.
  /// Param: role — ADMIN/USER từ membership summary, chỉ là dữ liệu hiển thị.
  /// Param: revision — số nguyên dương của summary, không thay server recheck.
  const AvailableWorkspaceSummary._({
    required this.id,
    required this.name,
    required this.role,
    required this.revision,
  });

  final String id;
  final String name;
  final String role;
  final int revision;

  /// Output: consumer này chỉ nhận ACTIVE; historical là capability/consumer riêng chưa triển khai.
  String get status => 'ACTIVE';

  /// Kiểm summary từ JSON đã decode mà không ép kiểu hoặc suy quyền từ extension.
  /// Input
  /// Param: value — row không đáng tin, chỉ từ response200 đã được caller kiểm.
  /// Output: DTO không có cache, callback, token hoặc cursor.
  /// Errors: FormatException cố định, không giữ payload/name/id trong source của lỗi.
  factory AvailableWorkspaceSummary.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('PROTOCOL_ERROR');
    }
    final id = value['id'];
    final name = value['name'];
    final role = value['role'];
    final revision = value['revision'];
    if (id is! String ||
        !isUuid(id) ||
        name is! String ||
        role is! String ||
        (role != 'ADMIN' && role != 'USER') ||
        revision is! int ||
        revision < 1 ||
        value['status'] != 'ACTIVE') {
      throw const FormatException('PROTOCOL_ERROR');
    }
    // Không nhận historical hoặc extension grants vào bootstrap mặc định; membership phải recheck khi chọn.
    return AvailableWorkspaceSummary._(
      id: id,
      name: name,
      role: role,
      revision: revision,
    );
  }
}

/// Trang workspace đã parse cho default bootstrap; cursor opaque chỉ đi qua RAM, không serialize/log.
final class AvailableWorkspacePage {
  /// Chụp list vào view bất biến để payload bên ngoài không sửa summary sau validation.
  /// Input
  /// Param: items — rows đã kiểm, không trùng UUID trong cùng page.
  /// Param: nextCursor — opaque string hoặc null đúng wire, không decode hay normalize.
  AvailableWorkspacePage._(
    List<AvailableWorkspaceSummary> items,
    this.nextCursor,
  ) : items = List.unmodifiable(items);

  final List<AvailableWorkspaceSummary> items;
  final String? nextCursor;

  /// Output: có cursor string là còn trang; string rỗng không được tự đổi thành null/empty cuối.
  bool get hasMore => nextCursor != null;

  /// Output: empty cuối chỉ từ page không item và không cursor; chưa là kiểm session hoặc account generation.
  bool get isEmpty => items.isEmpty && !hasMore;

  /// Parse WorkspacePage0.2.1 cho query default ACTIVE, không phải consumer historical hoặc HTTP client.
  /// Input
  /// Param: value — JSON không đáng tin; caller phải kiểm HTTP status/transport trước factory.
  /// Output: page bất biến, extension fields không có hiệu lực cấp quyền hoặc thay required fields.
  /// Errors: PROTOCOL_ERROR khi shape/row/cursor sai hoặc UUID trùng case-insensitive; không giữ raw payload.
  factory AvailableWorkspacePage.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        !value.containsKey('nextCursor') ||
        value['items'] is! List) {
      throw const FormatException('PROTOCOL_ERROR');
    }
    final cursor = value['nextCursor'];
    if (cursor != null && cursor is! String) {
      throw const FormatException('PROTOCOL_ERROR');
    }
    final items = <AvailableWorkspaceSummary>[];
    final identities = <String>{};
    for (final row in value['items'] as List) {
      final item = AvailableWorkspaceSummary.fromJson(row);
      // UUID khác hoa/thường vẫn là một identity; không để cùng page có hai callback/row keys mơ hồ.
      if (!identities.add(item.id.toLowerCase())) {
        throw const FormatException('PROTOCOL_ERROR');
      }
      items.add(item);
    }
    return AvailableWorkspacePage._(items, cursor as String?);
  }
}
