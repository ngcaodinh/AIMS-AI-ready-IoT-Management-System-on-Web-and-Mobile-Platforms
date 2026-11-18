import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../lib/features/workspaces/data/workspace_access_detail.dart';

const workspaceIdentity = 'abcdefab-cdef-4abc-8def-abcdefabcdef';
const creatorIdentity = '11111111-1111-4111-8111-111111111111';

/// Cấp full detail synthetic với các version khác nhau để phát hiện hoán đổi workspace/membership.
/// Output: map mới cho mỗi test; không mang credential hoặc quyền ngoài schema.
Map<String, Object?> detailBody() => {
  'id': workspaceIdentity,
  'name': '  Workspace <b>A</b>  ',
  'description': '  Synthetic description  ',
  'defaultTimezone': 'Asia/Bangkok',
  'status': 'ACTIVE',
  'revision': 11,
  'role': 'USER',
  'creatorId': creatorIdentity,
  'membershipStatus': 'ACTIVE',
  'authzVersion': 23,
  'membershipRevision': 37,
  'membershipAuthzVersion': 41,
  'createdAt': '2026-10-22T07:00:00+07:00',
  'archivedAt': null,
};

/// Kiểm lỗi parser cố định, không giữ map hoặc nội dung field chưa tin cậy trong exception.
/// Input
/// Param: value — payload synthetic thiếu/sai contract cần bị từ chối.
void expectDetailProtocol(Object? value) {
  try {
    WorkspaceAccessDetail.fromJson(value);
  } on FormatException catch (error) {
    expect(error.message, 'PROTOCOL_ERROR');
    expect(error.source, isNull);
    return;
  }
  fail('Malformed workspace detail became a snapshot');
}

/// Snapshot giữ nguyên scalar và bốn version riêng, UTC timestamps và không giữ mutable raw map.
void checkFullDetailSnapshot() {
  final body = detailBody();
  final detail = WorkspaceAccessDetail.fromJson(body);
  expect(detail.id, workspaceIdentity);
  expect(detail.name, '  Workspace <b>A</b>  ');
  expect(detail.description, '  Synthetic description  ');
  expect(detail.defaultTimezone, 'Asia/Bangkok');
  expect(detail.status, 'ACTIVE');
  expect(detail.role, 'USER');
  expect(detail.creatorId, creatorIdentity);
  expect(detail.membershipStatus, 'ACTIVE');
  expect(detail.revision, 11);
  expect(detail.authzVersion, 23);
  expect(detail.membershipRevision, 37);
  expect(detail.membershipAuthzVersion, 41);
  expect(detail.createdAt, DateTime.utc(2026, 10, 22));
  expect(detail.createdAt.isUtc, isTrue);
  expect(detail.archivedAt, isNull);
  expect(detail.isOperational, isTrue);
  body['name'] = 'changed after parse';
  body['authzVersion'] = 99;
  expect(detail.name, '  Workspace <b>A</b>  ');
  expect(detail.authzVersion, 23);
}

/// Detail response trong shared fixtures được parse theo schema, không coi fixture WEB là native evidence.
void checkSharedDetailFixtures() {
  final fixture = jsonDecode(
    File('../contracts/fixtures/auth/workspace-scenarios.json')
        .readAsStringSync(),
  ) as Map<String, dynamic>;
  expect(fixture['contractVersion'], '0.2.2');
  var matched = 0;
  for (final raw in fixture['scenarios'] as List<dynamic>) {
    final scenario = raw as Map<String, dynamic>;
    if (scenario['operationId'] != 'getWorkspaceDetail' &&
        scenario['operationId'] != 'createWorkspace')
      continue;
    final response = scenario['response'] as Map<String, dynamic>;
    if (response['status'] != 200 && response['status'] != 201) continue;
    final body = response['body'] as Map<String, dynamic>;
    final detail = WorkspaceAccessDetail.fromJson(body);
    expect(detail.id, body['id']);
    expect(detail.creatorId, body['creatorId']);
    expect(detail.description, body['description']);
    expect(detail.isOperational, isTrue);
    matched++;
  }
  expect(matched, 2);
}

/// Inactive enum vẫn là snapshot hợp lệ; operational chỉ từ hai lifecycle ACTIVE, không suy từ role.
void checkNullableAndInactiveDetail() {
  for (final status in ['ACTIVE', 'SUSPENDED', 'ARCHIVED']) {
    for (final membership in ['ACTIVE', 'SUSPENDED', 'REMOVED']) {
      final detail = WorkspaceAccessDetail.fromJson({
        ...detailBody(),
        'description': null,
        'status': status,
        'membershipStatus': membership,
        'role': 'ADMIN',
        'archivedAt': '2026-10-23T01:30:00+01:30',
      });
      expect(detail.description, isNull);
      expect(detail.archivedAt, DateTime.utc(2026, 10, 23));
      expect(detail.archivedAt!.isUtc, isTrue);
      expect(
        detail.isOperational,
        status == 'ACTIVE' && membership == 'ACTIVE',
      );
    }
  }
}

/// Required nullable khác missing; parser không ép enum, UUID hoặc version bool/string thành quyền.
void checkRequiredDetailBoundaries() {
  final body = detailBody();
  for (final field in body.keys) {
    expectDetailProtocol({...body}..remove(field));
  }
  for (final field in [
    'revision',
    'authzVersion',
    'membershipRevision',
    'membershipAuthzVersion',
  ]) {
    for (final invalid in <Object?>[null, 0, -1, true, 1.5, '1']) {
      expectDetailProtocol({...body, field: invalid});
    }
  }
  expectDetailProtocol({...body, 'status': 'active'});
  expectDetailProtocol({...body, 'membershipStatus': 'ADMIN'});
  expectDetailProtocol({...body, 'role': 'OWNER'});
  expectDetailProtocol({...body, 'id': '$workspaceIdentity/extra'});
  expectDetailProtocol({...body, 'creatorId': false});
  expectDetailProtocol({...body, 'archivedAt': 1});
}

/// Không nhận lịch bị DateTime tự normalize hoặc ký tự thừa; parser không giả hỗ trợ leap second.
void checkDetailTimestampBoundaries() {
  for (final field in ['createdAt', 'archivedAt']) {
    for (final invalid in <Object?>[
      '',
      1,
      true,
      '2026-02-30T00:00:00Z',
      '2026-13-01T00:00:00Z',
      '2026-01-00T00:00:00Z',
      '2026-01-01T24:00:00Z',
      '2026-01-01T00:60:00Z',
      '2026-01-01T00:00:60Z',
      '2026-01-01T00:00:00',
      '2026-01-01T00:00:00+24:00',
      '2026-01-01T00:00:00+00:60',
      '2026-01-01T00:00:00Z\n',
    ]) {
      expectDetailProtocol({...detailBody(), field: invalid});
    }
  }
  final leapDay = WorkspaceAccessDetail.fromJson({
    ...detailBody(),
    'createdAt': '2024-02-29T23:59:59.123456-03:00',
  });
  expect(leapDay.createdAt, DateTime.utc(2024, 3, 1, 2, 59, 59, 123, 456));
  for (final field in ['id', 'creatorId']) {
    expectDetailProtocol({...detailBody(), field: '$workspaceIdentity\n'});
  }
  final extended = WorkspaceAccessDetail.fromJson({
    ...detailBody(),
    'untrustedGrant': {'role': 'ADMIN'},
    'name': '<script>synthetic</script>',
  });
  expect(extended.role, 'USER');
  expect(extended.name, '<script>synthetic</script>');
}

/// Đăng ký consumer tests thuần schema; không khởi tạo app, HTTP hoặc storage plugin.
void main() {
  test(
    'detail snapshot preserves distinct versions and raw scalar values',
    checkFullDetailSnapshot,
  );
  test(
    'detail parses the existing shared success fixtures',
    checkSharedDetailFixtures,
  );
  test(
    'detail keeps inactive lifecycle values without granting operation',
    checkNullableAndInactiveDetail,
  );
  test(
    'detail rejects missing nullable fields and invalid typed authority',
    checkRequiredDetailBoundaries,
  );
  test(
    'detail timestamps reject overflow missing timezone and trailing input',
    checkDetailTimestampBoundaries,
  );
}
