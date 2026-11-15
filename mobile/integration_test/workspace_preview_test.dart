import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../lib/features/workspaces/presentation/workspace_selection_screen.dart';
import '../tool/workspace_preview.dart';
import 'support/native_display_profile.dart';

/// Chạm control sau khi cuộn đến target, missed pointer là lỗi thay vì cảnh báo bị bỏ qua.
/// Input
/// Param: tester — runner engine thật.
/// Param: target — native control cần tương tác, không DOM hoặc tọa độ hardcode.
Future<void> tapVisible(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    160,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  expect(
    tester.getSize(find.byType(ListView)).height >=
        tester.getSize(target).height,
    isTrue,
    reason: 'Native list viewport must fit the complete action target',
  );
  await tester.tap(target);
  await tester.pumpAndSettle();
}

/// Chọn scenario rõ nhãn từ menu mock, không thay server/network state thật.
/// Input
/// Param: tester — runner preview đang sống.
/// Param: title — nhãn chính xác của scenario nội bộ.
Future<void> chooseScenario(WidgetTester tester, String title) async {
  await tester.tap(find.byKey(const ValueKey('workspace-preview-scenario')));
  await tester.pumpAndSettle();
  final row = find.ancestor(
    of: find.text(title).last,
    matching: find.byType(CheckedPopupMenuItem<String>),
  );
  await tester.ensureVisible(row);
  await tester.pumpAndSettle();
  await tester.tap(row);
  await tester.pumpAndSettle();
}

/// Kiểm engine/list intents bằng fixture; flow không có login, token, server recheck hoặc workspace resources.
/// Input
/// Param: tester — Android runner trên đúng AVD đã được host xác nhận.
Future<void> exerciseWorkspacePreview(WidgetTester tester) async {
  WidgetController.hitTestWarningShouldBeFatal = true;
  await tester.pumpWidget(const WorkspacePreview());
  await tester.pumpAndSettle();
  await waitForDisplayProfile(tester, find.byType(WorkspaceSelectionScreen));
  logDisplayMetrics(tester, find.byType(WorkspaceSelectionScreen), 'start');
  expect(find.text('BẢN THIẾT KẾ — DỮ LIỆU MÔ PHỎNG'), findsOneWidget);
  final context = tester.element(find.byType(WorkspaceSelectionScreen));
  final logical = MediaQuery.sizeOf(context);
  debugPrint(
    'NATIVE_WORKSPACE_VIEW width=${logical.width} height=${logical.height} text16=${MediaQuery.textScalerOf(context).scale(16)}',
  );
  // Marker chung cho host chỉ sau wait thật; JSON suite/testTarget phân biệt bằng chứng với login.
  debugPrint(
    'NATIVE_PREVIEW_VIEW width=${logical.width} height=${logical.height} text16=${MediaQuery.textScalerOf(context).scale(16)}',
  );
  // List lazy chưa dựng row ngoài viewport ở chữ lớn; cuộn như người dùng thay vì đòi cache eager.
  await tester.scrollUntilVisible(find.text('Workspace A'), 160);
  expect(find.text('Workspace A'), findsOneWidget);
  expect(find.text('Đã chọn workspace'), findsNothing);
  await tapVisible(tester, find.byKey(const ValueKey('workspace-load-more')));
  await tapVisible(
    tester,
    find.byKey(ValueKey('workspace-select-${previewWorkspaceB.id}')),
  );
  expect(find.text('Đã chọn workspace'), findsOneWidget);
  expect(find.text('Workspace A'), findsNothing);
  await chooseScenario(tester, 'Không có workspace khả dụng');
  final create = find.byKey(const ValueKey('workspace-create'));
  await tester.scrollUntilVisible(create, 160);
  expect(tester.widget<FilledButton>(create).onPressed, isNull);
  await chooseScenario(tester, 'Không có kết nối');
  expect(find.text('Workspace A'), findsNothing);
  await tapVisible(tester, find.byKey(const ValueKey('workspace-refresh')));
  await tester.scrollUntilVisible(find.text('Workspace A'), 160);
  expect(find.text('Workspace A'), findsOneWidget);
  await chooseScenario(tester, 'Cần xác minh trạng thái');
  await tapVisible(tester, find.byKey(const ValueKey('workspace-recover')));
  await tester.scrollUntilVisible(find.text('Workspace A'), 160);
  expect(find.text('Workspace A'), findsOneWidget);
  await tester.tap(find.byTooltip('Dùng giao diện tối'));
  await tester.pumpAndSettle();
  expect(
    Theme.of(tester.element(find.byType(WorkspaceSelectionScreen))).brightness,
    Brightness.dark,
  );
  expect(find.text('BẢN THIẾT KẾ — DỮ LIỆU MÔ PHỎNG'), findsOneWidget);
  logDisplayMetrics(tester, find.byType(WorkspaceSelectionScreen), 'end');
}

/// Đăng ký UI mock native, không đánh AT-WF hoặc G3/provider E2E PASS từ ca này.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'labelled workspace preview paginates selects and recovers',
    exerciseWorkspacePreview,
  );
}
