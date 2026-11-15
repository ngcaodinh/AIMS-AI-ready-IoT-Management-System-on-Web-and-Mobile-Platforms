import '../../../core/validation/uuid_validation.dart';

/// Snapshot detail workspace từ server; không tự cấp quyền resource hoặc giữ raw response.
final class WorkspaceAccessDetail {
  /// Chỉ parser tạo snapshot sau kiểm required/types, không normalize dữ liệu hiển thị.
  /// Input
  /// Param: id — UUID workspace giữ nguyên case từ wire.
  /// Param: name — tên plain text, không HTML hoặc authority.
  /// Param: description — mô tả nullable, key vẫn required.
  /// Param: defaultTimezone — timezone string do provider kiểm catalogue.
  /// Param: status — lifecycle workspace theo contract.
  /// Param: revision — revision workspace dương.
  /// Param: role — role membership caller, không role global.
  /// Param: creatorId — UUID account tạo, không tự là membership hiện hành.
  /// Param: membershipStatus — lifecycle membership caller.
  /// Param: authzVersion — version authorization workspace, khác membership.
  /// Param: membershipRevision — revision membership caller.
  /// Param: membershipAuthzVersion — version authorization membership riêng.
  /// Param: createdAt — timestamp UTC đã kiểm lịch và timezone.
  /// Param: archivedAt — timestamp UTC nullable, không tự suy từ status.
  const WorkspaceAccessDetail._({
    required this.id,
    required this.name,
    required this.description,
    required this.defaultTimezone,
    required this.status,
    required this.revision,
    required this.role,
    required this.creatorId,
    required this.membershipStatus,
    required this.authzVersion,
    required this.membershipRevision,
    required this.membershipAuthzVersion,
    required this.createdAt,
    required this.archivedAt,
  });

  final String id;
  final String name;
  final String? description;
  final String defaultTimezone;
  final String status;
  final int revision;
  final String role;
  final String creatorId;
  final String membershipStatus;
  final int authzVersion;
  final int membershipRevision;
  final int membershipAuthzVersion;
  final DateTime createdAt;
  final DateTime? archivedAt;

  /// Output: snapshot có hai lifecycle ACTIVE; vẫn cần server authorization mỗi resource request.
  bool get isOperational => status == 'ACTIVE' && membershipStatus == 'ACTIVE';

  /// Kiểm snapshot đủ required/types và version riêng, bỏ extension tương thích không cấp quyền.
  /// Input
  /// Param: value — JSON chưa tin cậy từ đúng response200.
  /// Output: scalar snapshot bất biến, không raw map hoặc serialization chứa dữ liệu cá nhân.
  /// Errors: FormatException cố định, không raw payload/source.
  factory WorkspaceAccessDetail.fromJson(Object? value) {
    if (value is! Map<String, dynamic>)
      throw const FormatException('PROTOCOL_ERROR');
    final id = value['id'];
    final name = value['name'];
    final description = value['description'];
    final timezone = value['defaultTimezone'];
    final status = value['status'];
    final revision = value['revision'];
    final role = value['role'];
    final creatorId = value['creatorId'];
    final membershipStatus = value['membershipStatus'];
    final authzVersion = value['authzVersion'];
    final membershipRevision = value['membershipRevision'];
    final membershipAuthzVersion = value['membershipAuthzVersion'];
    if (id is! String ||
        id.length != 36 ||
        !isUuid(id) ||
        name is! String ||
        !value.containsKey('description') ||
        (description != null && description is! String) ||
        timezone is! String ||
        !const {'ACTIVE', 'SUSPENDED', 'ARCHIVED'}.contains(status) ||
        revision is! int ||
        revision < 1 ||
        !const {'ADMIN', 'USER'}.contains(role) ||
        creatorId is! String ||
        creatorId.length != 36 ||
        !isUuid(creatorId) ||
        !const {'ACTIVE', 'SUSPENDED', 'REMOVED'}.contains(membershipStatus) ||
        authzVersion is! int ||
        authzVersion < 1 ||
        membershipRevision is! int ||
        membershipRevision < 1 ||
        membershipAuthzVersion is! int ||
        membershipAuthzVersion < 1 ||
        !value.containsKey('archivedAt')) {
      throw const FormatException('PROTOCOL_ERROR');
    }
    // Không suy archivedAt từ status hoặc hoán đổi workspace/membership versions; schema là boundary.
    return WorkspaceAccessDetail._(
      id: id,
      name: name,
      description: description as String?,
      defaultTimezone: timezone,
      status: status as String,
      revision: revision,
      role: role as String,
      creatorId: creatorId,
      membershipStatus: membershipStatus as String,
      authzVersion: authzVersion,
      membershipRevision: membershipRevision,
      membershipAuthzVersion: membershipAuthzVersion,
      createdAt: _parseTimestamp(value['createdAt']),
      archivedAt: value['archivedAt'] == null
          ? null
          : _parseTimestamp(value['archivedAt']),
    );
  }
}

/// Kiểm lịch trước DateTime parse để không nhận ngày sai bị tự normalize; dùng subset AppLogin hiện hành.
/// Input
/// Param: value — timestamp untrusted, bắt buộc timezone, T/Z hoa hoặc numeric offset.
/// Output: UTC immutable; giây00–59, chưa hỗ trợ leap-second60 của RFC3339.
/// Errors: FormatException cố định không giữ value/source hoặc lỗi native.
DateTime _parseTimestamp(Object? value) {
  if (value is! String) throw const FormatException('PROTOCOL_ERROR');
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:Z|([+-])(\d{2}):(\d{2}))$',
  ).firstMatch(value);
  if (match == null || match.end != value.length)
    throw const FormatException('PROTOCOL_ERROR');
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  if (month < 1 ||
      month > 12 ||
      day < 1 ||
      day > DateTime.utc(year, month + 1, 0).day ||
      int.parse(match[4]!) > 23 ||
      int.parse(match[5]!) > 59 ||
      int.parse(match[6]!) > 59 ||
      int.parse(match[8] ?? '0') > 23 ||
      int.parse(match[9] ?? '0') > 59) {
    throw const FormatException('PROTOCOL_ERROR');
  }
  final result = DateTime.tryParse(value);
  if (result == null) throw const FormatException('PROTOCOL_ERROR');
  return result.toUtc();
}
