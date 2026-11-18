import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../lib/features/workspaces/data/available_workspace_page.dart';

/// Xác nhận boundary fail closed với code cố định, không giữ payload/cursor hoặc dữ liệu private.
/// Input
/// Param: value — JSON tổng hợp sai contract, không response từ account thật.
void expectWorkspaceProtocolError(Object? value) {
  try {
    AvailableWorkspacePage.fromJson(value);
  } on FormatException catch (error) {
    expect(error.message, 'PROTOCOL_ERROR');
    expect(error.source, isNull);
    return;
  }
  fail('Malformed workspace page was accepted');
}

/// Parse cùng response fixtures của contract 0.2.2; không giả provider/client đã tương thích runtime.
void checkWorkspaceConsumer() {
  final fixture = jsonDecode(
    // Chạy Flutter test từ mobile/ như README; chỉ đọc fixture synthetic trong contracts, không environment.
    File('../contracts/fixtures/auth/workspace-scenarios.json')
        .readAsStringSync(),
  ) as Map<String, dynamic>;
  expect(fixture['contractVersion'], '0.2.2');
  var successFixtures = 0;
  var cases = 0;
  Map<String, dynamic>? full;
  for (final scenario in fixture['scenarios'] as List<dynamic>) {
    if (scenario['operationId'] != 'listAvailableWorkspaces') continue;
    final response = scenario['response'] as Map<String, dynamic>;
    if (response['status'] == 200) {
      final body = response['body'] as Map<String, dynamic>;
      final page = AvailableWorkspacePage.fromJson(body);
      expect(page.items.length, (body['items'] as List).length);
      expect(page.nextCursor, body['nextCursor']);
      expect(page.hasMore, body['nextCursor'] != null);
      expect(
        page.isEmpty,
        (body['items'] as List).isEmpty && body['nextCursor'] == null,
      );
      for (var index = 0; index < page.items.length; index++) {
        final item = page.items[index];
        final wire = body['items'][index];
        expect(item.id, wire['id']);
        expect(item.name, wire['name']);
        expect(item.role, wire['role']);
        expect(item.status, 'ACTIVE');
        expect(item.revision, wire['revision']);
      }
      if (scenario['id'] == 'CT-BOOTSTRAP-TWO-WORKSPACES') full = body;
      successFixtures++;
    } else {
      expectWorkspaceProtocolError(response['body']);
    }
    cases++;
  }
  expect(successFixtures, 3);
  expect(full, isNotNull);
  final body = full!;
  final row = (body['items'] as List).first as Map<String, dynamic>;
  for (final value in <Object?>[null, [], 'body', 0, true]) {
    expectWorkspaceProtocolError(value);
    cases++;
  }
  for (final field in ['items', 'nextCursor']) {
    expectWorkspaceProtocolError({...body}..remove(field));
    cases++;
  }
  for (final value in <Object?>[null, 'items', 1, false, <String, Object?>{}]) {
    expectWorkspaceProtocolError({...body, 'items': value});
    cases++;
  }
  for (final value in <Object?>[0, true, [], <String, Object?>{}]) {
    expectWorkspaceProtocolError({...body, 'nextCursor': value});
    cases++;
  }
  for (final field in ['id', 'name', 'role', 'status', 'revision']) {
    final missing = {...row}..remove(field);
    expectWorkspaceProtocolError({
      ...body,
      'items': [missing],
    });
    cases++;
    for (final value in <Object?>[null, [], <String, Object?>{}, false]) {
      expectWorkspaceProtocolError({
        ...body,
        'items': [
          {...row, field: value},
        ],
      });
      cases++;
    }
  }
  for (final value in ['', 'bad-id', '33333333333343338333333333333333']) {
    expectWorkspaceProtocolError({
      ...body,
      'items': [
        {...row, 'id': value},
      ],
    });
    cases++;
  }
  for (final value in ['SUSPENDED', 'ARCHIVED', 'active', 'UNKNOWN']) {
    // Schema tổng hỗ trợ historical, nhưng consumer bootstrap này không mở capability historical.
    expectWorkspaceProtocolError({
      ...body,
      'items': [
        {...row, 'status': value},
      ],
    });
    cases++;
  }
  for (final value in ['OWNER', 'admin', 'GLOBAL_ADMIN']) {
    expectWorkspaceProtocolError({
      ...body,
      'items': [
        {...row, 'role': value},
      ],
    });
    cases++;
  }
  for (final value in <Object?>[0, -1, '1', 1.5]) {
    expectWorkspaceProtocolError({
      ...body,
      'items': [
        {...row, 'revision': value},
      ],
    });
    cases++;
  }
  for (final value in <Object?>[null, [], 'row', 1]) {
    expectWorkspaceProtocolError({
      ...body,
      'items': [value],
    });
    cases++;
  }
  final upperId = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
  expectWorkspaceProtocolError({
    ...body,
    'items': [
      {...row, 'id': upperId},
      {...row, 'id': upperId.toLowerCase()},
    ],
  });
  cases++;
  for (final cursor in ['', ' opaque cursor +/?= ', '<nonfunctional-cursor>']) {
    final page = AvailableWorkspacePage.fromJson({
      'items': <Object?>[],
      'nextCursor': cursor,
    });
    expect(page.hasMore, isTrue);
    expect(page.isEmpty, isFalse);
    expect(page.nextCursor, cursor);
    expect(
      page.toString(),
      isNot(contains(cursor.isEmpty ? 'nextCursor' : cursor)),
    );
    cases++;
  }
  final editableRow = {...row};
  final editableItems = [editableRow];
  final page = AvailableWorkspacePage.fromJson({
    'items': editableItems,
    'nextCursor': null,
  });
  editableRow['name'] = 'Changed after parse';
  editableItems.clear();
  expect(page.items.single.name, row['name']);
  expect(page.items.clear, throwsUnsupportedError);
  cases++;
  final extended = AvailableWorkspacePage.fromJson({
    ...body,
    'futureField': {'role': 'GLOBAL_ADMIN'},
    'items': [
      {...row, 'name': '  Giữ nguyên tên  ', 'futureGrant': 'ADMIN_ALL'},
    ],
  });
  expect(extended.items.single.name, '  Giữ nguyên tên  ');
  expect(extended.items.single.role, row['role']);
  cases++;
  stdout.writeln(
    'PASS $cases available-workspace consumer cases (synthetic contract; no API/storage/provider).',
  );
}

/// Đăng ký consumer factory checks vào runner Flutter có sẵn, không thêm package hoặc đổi fixture.
void main() {
  test(
    'available workspace page shared fixtures and malformed payloads',
    checkWorkspaceConsumer,
  );
}
