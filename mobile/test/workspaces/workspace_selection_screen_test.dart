import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../lib/features/workspaces/presentation/workspace_selection_screen.dart';
import '../../lib/features/workspaces/presentation/workspace_selection_state.dart';
import '../../lib/ui/nexa_auth_theme.dart';

// Hai summary tổng hợp từ contract fixture, không membership hoặc authorization thật.
const workspaceA = WorkspaceOption(
  id: '33333333-3333-4333-8333-333333333333',
  name: 'Workspace A',
  role: WorkspaceRole.admin,
  revision: 1,
  status: WorkspaceStatus.active,
);
const workspaceB = WorkspaceOption(
  id: '44444444-4444-4444-8444-444444444444',
  name: 'Workspace B',
  role: WorkspaceRole.user,
  revision: 2,
  status: WorkspaceStatus.active,
);

/// Boundary fake chỉ đếm intent, không API, storage hoặc điều hướng tài nguyên.
class WorkspaceProbe {
  int selections = 0;
  int refreshes = 0;
  int pages = 0;
  int recoveries = 0;
  WorkspaceOption? selected;
  Completer<void>? gate;
  bool reject = false;

  /// Giữ ACK theo test để kiểm không phát song song và không nuốt exception thành thành công.
  /// Input
  /// Param: option — summary hiện hành được widget chuyển cho host, chưa là quyền truy cập.
  Future<void> select(WorkspaceOption option) async {
    selections++;
    selected = option;
    if (reject) throw StateError('PRIVATE_BACKEND_DETAIL');
    if (gate != null) await gate!.future;
  }

  /// Ghi nhận GET refresh chủ động, không fetch dữ liệu thật.
  Future<void> refresh() async => refreshes++;

  /// Ghi nhận tải trang tiếp, không giữ cursor trong presentation.
  Future<void> loadMore() async => pages++;

  /// Đối soát giả không tự mở khóa generation đã unknown.
  Future<void> recover() async => recoveries++;
}

/// Dựng component với dữ liệu typed trong RAM, không biến widget test thành auth E2E.
/// Input
/// Param: tester — runner giao diện.
/// Param: probe — fake boundary nhận intent.
/// Param: phase — snapshot host đưa vào; phase đổi không reset local unknown.
/// Param: options — summary test, không parse JSON ở view.
/// Param: hasMore — metadata phân trang, khác với việc danh sách thật sự rỗng.
/// Param: generation — key để host bỏ scope cũ sau đối soát/account switch.
/// Param: brightness — palette cần kiểm độc lập.
/// Param: textScale — cỡ chữ mô phỏng riêng widget test, không giả metrics native.
/// Param: reducedMotion — kiểm bỏ spinner theo preference giảm chuyển động.
Future<void> pumpPicker(
  WidgetTester tester,
  WorkspaceProbe probe, {
  WorkspaceSelectionPhase phase = WorkspaceSelectionPhase.ready,
  List<WorkspaceOption> options = const [workspaceA, workspaceB],
  bool hasMore = false,
  int generation = 0,
  Brightness brightness = Brightness.light,
  double textScale = 1,
  bool reducedMotion = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: nexaAuthTheme(brightness),
      home: MediaQuery(
        data: MediaQueryData.fromView(tester.view).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: reducedMotion,
        ),
        child: WorkspaceSelectionScreen(
          key: ValueKey(generation),
          state: WorkspaceSelectionState(
            phase: phase,
            options: options,
            hasMore: hasMore,
          ),
          onSelect: probe.select,
          onRefresh: probe.refresh,
          onLoadMore: probe.loadMore,
          onRecover: probe.recover,
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Không tự chọn một summary; callback nhận đúng id/revision và chỉ một intent đang await.
/// Input
/// Param: tester — runner giữ callback cũ để thử double dispatch.
Future<void> checkSelectionFence(WidgetTester tester) async {
  final probe = WorkspaceProbe()..gate = Completer<void>();
  await pumpPicker(tester, probe);
  expect(probe.selections, 0);
  expect(find.text('Quản trị viên'), findsOneWidget);
  expect(find.text('Thành viên'), findsOneWidget);
  final button = find.byKey(ValueKey('workspace-select-${workspaceA.id}'));
  final oldCallback = tester.widget<OutlinedButton>(button).onPressed!;
  await tester.tap(button);
  oldCallback();
  await tester.pump();
  expect(probe.selections, 1);
  expect(probe.selected!.id, workspaceA.id);
  expect(probe.selected!.revision, 1);
  expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
  probe.gate!.complete();
  await tester.pumpAndSettle();
}

/// Chỉ trang cuối rỗng mới là empty/create; cursor còn không được tạo đường đi giả.
/// Input
/// Param: tester — runner empty và trang chưa tải xong.
Future<void> checkEmptyAndPagination(WidgetTester tester) async {
  final probe = WorkspaceProbe();
  await pumpPicker(tester, probe, options: const [], hasMore: true);
  expect(find.text('Không có workspace khả dụng'), findsNothing);
  expect(find.byKey(const ValueKey('workspace-create')), findsNothing);
  final more = find.byKey(const ValueKey('workspace-load-more'));
  await tester.ensureVisible(more);
  await tester.tap(more);
  await tester.pumpAndSettle();
  expect(probe.pages, 1);
  await pumpPicker(tester, probe, options: const []);
  expect(find.text('Không có workspace khả dụng'), findsOneWidget);
  final create = find.byKey(const ValueKey('workspace-create'));
  await tester.ensureVisible(create);
  expect(tester.widget<FilledButton>(create).onPressed, isNull);
  expect(
    find.text('Tạo workspace chưa khả dụng trong phiên bản này.'),
    findsOneWidget,
  );
}

/// Mọi state không ready phải che list được truyền vào, không lộ summary của scope cũ.
/// Input
/// Param: tester — runner ma trận presentation, không giả server đã revoke quyền.
Future<void> checkBlockedMatrix(WidgetTester tester) async {
  final probe = WorkspaceProbe();
  for (final phase in WorkspaceSelectionPhase.values) {
    if (phase == WorkspaceSelectionPhase.ready ||
        phase == WorkspaceSelectionPhase.loadingMore)
      continue;
    await pumpPicker(tester, probe, phase: phase);
    expect(find.text(workspaceA.name), findsNothing, reason: phase.name);
    expect(find.text(workspaceB.name), findsNothing, reason: phase.name);
    expect(probe.selections, 0);
  }
  await pumpPicker(
    tester,
    probe,
    phase: WorkspaceSelectionPhase.loadingMore,
    hasMore: true,
  );
  final row = find.byKey(ValueKey('workspace-select-${workspaceA.id}'));
  expect(tester.widget<OutlinedButton>(row).onPressed, isNull);
  expect(probe.pages, 0);
}

/// Event cũ phải so phase/id/revision hiện hành; inactive không thể dispatch dù host đưa vào.
/// Input
/// Param: tester — runner tái dựng snapshot cùng widget generation.
Future<void> checkStaleCallbacks(WidgetTester tester) async {
  final probe = WorkspaceProbe();
  await pumpPicker(tester, probe);
  final row = find.byKey(ValueKey('workspace-select-${workspaceA.id}'));
  final oldCallback = tester.widget<OutlinedButton>(row).onPressed!;
  await pumpPicker(tester, probe, options: const [workspaceB]);
  oldCallback();
  await tester.pump();
  expect(probe.selections, 0);
  const revised = WorkspaceOption(
    id: '33333333-3333-4333-8333-333333333333',
    name: 'Workspace A updated',
    role: WorkspaceRole.user,
    revision: 2,
    status: WorkspaceStatus.active,
  );
  await pumpPicker(tester, probe, options: const [revised]);
  oldCallback();
  await tester.pump();
  expect(probe.selections, 0);
  await pumpPicker(
    tester,
    probe,
    phase: WorkspaceSelectionPhase.permissionDenied,
  );
  oldCallback();
  await tester.pump();
  expect(probe.selections, 0);
  const inactive = WorkspaceOption(
    id: '33333333-3333-4333-8333-333333333333',
    name: 'Inactive workspace',
    role: WorkspaceRole.admin,
    revision: 2,
    status: WorkspaceStatus.suspended,
  );
  await pumpPicker(tester, probe, options: const [inactive]);
  oldCallback();
  await tester.pump();
  expect(tester.widget<OutlinedButton>(row).onPressed, isNull);
  expect(probe.selections, 0);
}

/// Exception khóa scope, không lộ detail và chỉ new key sau đối soát mới cho chọn lại.
/// Input
/// Param: tester — runner local unknown/recovery boundary.
Future<void> checkUnknownRecovery(WidgetTester tester) async {
  final probe = WorkspaceProbe()..reject = true;
  await pumpPicker(tester, probe);
  await tester.tap(find.byKey(ValueKey('workspace-select-${workspaceA.id}')));
  await tester.pumpAndSettle();
  expect(find.text('Cần xác minh trạng thái'), findsOneWidget);
  expect(find.textContaining('PRIVATE_BACKEND_DETAIL'), findsNothing);
  expect(find.text(workspaceA.name), findsNothing);
  final recovery = find.byKey(const ValueKey('workspace-recover'));
  await tester.ensureVisible(recovery);
  await tester.tap(recovery);
  await tester.pumpAndSettle();
  expect(probe.recoveries, 1);
  expect(find.text(workspaceA.name), findsNothing);
  await pumpPicker(tester, probe, generation: 1);
  expect(find.text(workspaceA.name), findsOneWidget);
}

/// Nút native hỗ trợ keyboard và label đầy đủ, không chỉ gesture hoặc icon.
/// Input
/// Param: tester — runner keyboard/semantics, chưa thay TalkBack trên thiết bị.
Future<void> checkKeyboardAndSemantics(WidgetTester tester) async {
  final probe = WorkspaceProbe();
  final semantics = tester.ensureSemantics();
  try {
    await pumpPicker(tester, probe);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(probe.selected!.id, workspaceA.id);
    expect(find.bySemanticsLabel(RegExp('Workspace A')), findsWidgets);
  } finally {
    semantics.dispose();
  }
}

/// Đăng ký các invariant UI; native preview/device và provider acceptance là checkpoint khác.
void main() {
  test(
    'workspace snapshot is immutable and unambiguous',
    checkSnapshotIntegrity,
  );
  testWidgets(
    'large text lists fit both themes and reduced motion',
    checkResponsivePicker,
  );
  testWidgets(
    'disposed generation ignores old actions and ACK',
    checkDisposedGeneration,
  );
  testWidgets(
    'workspace selection is explicit and fenced',
    checkSelectionFence,
  );
  testWidgets(
    'empty differs from an incomplete cursor page',
    checkEmptyAndPagination,
  );
  testWidgets('blocked phases hide scope summaries', checkBlockedMatrix);
  testWidgets(
    'old callbacks and inactive rows cannot select',
    checkStaleCallbacks,
  );
  testWidgets(
    'unknown callback requires reconciled generation',
    checkUnknownRecovery,
  );
  testWidgets(
    'keyboard and semantics expose workspace actions',
    checkKeyboardAndSemantics,
  );
}

/// Snapshot sao chụp list và từ chối duplicate identity để selection không mơ hồ.
void checkSnapshotIntegrity() {
  final source = [workspaceA, workspaceB];
  final state = WorkspaceSelectionState(
    phase: WorkspaceSelectionPhase.ready,
    options: source,
  );
  source.clear();
  expect(state.options.length, 2);
  expect(state.options.clear, throwsUnsupportedError);
  expect(
    /// Duplicate identity không được đi qua constructor, không đưa giá trị row vào lỗi.
    () => WorkspaceSelectionState(
      phase: WorkspaceSelectionPhase.ready,
      options: const [workspaceA, workspaceA],
    ),
    throwsArgumentError,
  );
}

/// Layout theo available width, chữ200% và màu/giảm chuyển động độc lập; controls vẫn cuộn và chạm được.
/// Input
/// Param: tester — view mô phỏng nhỏ/ngang, chưa thay native visual audit.
Future<void> checkResponsivePicker(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  const longOption = WorkspaceOption(
    id: '33333333-3333-4333-8333-333333333333',
    name: 'Không gian làm việc có tên dài để kiểm tra khả năng xuống dòng trên màn hình nhỏ',
    role: WorkspaceRole.admin,
    revision: 1,
    status: WorkspaceStatus.active,
  );
  for (final brightness in Brightness.values) {
    for (final size in [const Size(375, 667), const Size(800, 375)]) {
      tester.view.physicalSize = size;
      await pumpPicker(
        tester,
        WorkspaceProbe(),
        options: const [longOption, workspaceB],
        hasMore: true,
        brightness: brightness,
        textScale: 2,
        reducedMotion: true,
      );
      final refresh = find.byKey(const ValueKey('workspace-refresh'));
      await tester.scrollUntilVisible(refresh, 160);
      expect(tester.getSize(refresh).height >= 48, isTrue);
      expect(tester.getRect(refresh).right <= size.width, isTrue);
      expect(tester.takeException(), isNull);
      await pumpPicker(
        tester,
        WorkspaceProbe(),
        phase: WorkspaceSelectionPhase.loading,
        brightness: brightness,
        textScale: 2,
        reducedMotion: true,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byIcon(Icons.hourglass_empty_outlined), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  }
}

/// Response/callback của widget đã disposed không được sửa hoặc gửi intent từ generation account mới.
/// Input
/// Param: tester — runner thay key khi ACK tổng hợp còn đang chờ.
Future<void> checkDisposedGeneration(WidgetTester tester) async {
  final probe = WorkspaceProbe()..gate = Completer<void>();
  await pumpPicker(tester, probe);
  final row = find.byKey(ValueKey('workspace-select-${workspaceA.id}'));
  final oldCallback = tester.widget<OutlinedButton>(row).onPressed!;
  final oldRefresh = tester
      .widget<OutlinedButton>(find.byKey(const ValueKey('workspace-refresh')))
      .onPressed!;
  await tester.tap(row);
  await tester.pump();
  await pumpPicker(tester, probe, generation: 1);
  oldCallback();
  oldRefresh();
  probe.gate!.completeError(StateError('OLD_SCOPE_ACK'));
  await tester.pumpAndSettle();
  expect(probe.selections, 1);
  expect(probe.refreshes, 0);
  expect(tester.widget<OutlinedButton>(row).onPressed, isNotNull);
  expect(find.text('Cần xác minh trạng thái'), findsNothing);
  expect(tester.takeException(), isNull);
}
