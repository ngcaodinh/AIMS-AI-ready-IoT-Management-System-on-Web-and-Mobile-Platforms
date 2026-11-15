import 'package:flutter/material.dart';

import '../../../ui/nexa_auth_theme.dart';
import 'workspace_selection_state.dart';

/// Picker thuần presentation; host phải cấp key generation mới sau account switch/đối soát unknown.
class WorkspaceSelectionScreen extends StatefulWidget {
  /// Nhận snapshot và intent host, không parse wire, lưu session hoặc điều hướng protected UI.
  /// Input
  /// Param: state — dữ liệu chỉ thuộc account generation đã được host xác nhận.
  /// Param: onSelect — recheck summary trên server rồi host mới quyết định route.
  /// Param: onRefresh — tải lại GET chủ động, không retry auth mutation.
  /// Param: onLoadMore — host giữ cursor opaque và thứ tự các trang.
  /// Param: onRecover — đối soát riêng, không tự unlock generation khi Future hoàn tất.
  /// Param: onLogout — capability đăng xuất do host cung cấp khi phiên đủ điều kiện.
  /// Param: onCreate — chỉ nối khi dependency065 sẵn sàng, null hiện lý do chưa khả dụng.
  /// Param: onToggleTheme — tùy chọn thị giác, không thay trạng thái phiên.
  /// Param: onChangePassword — full host cấp navigation, không phát mutation hoặc nâng quyền.
  const WorkspaceSelectionScreen({
    super.key,
    required this.state,
    required this.onSelect,
    this.onRefresh,
    this.onLoadMore,
    this.onRecover,
    this.onLogout,
    this.onCreate,
    this.onToggleTheme,
    this.onChangePassword,
  });

  final WorkspaceSelectionState state;
  final Future<void> Function(WorkspaceOption option) onSelect;
  final Future<void> Function()? onRefresh;
  final Future<void> Function()? onLoadMore;
  final Future<void> Function()? onRecover;
  final Future<void> Function()? onLogout;
  final Future<void> Function()? onCreate;
  final VoidCallback? onToggleTheme;
  final VoidCallback? onChangePassword;

  /// Output: controller UI chỉ sống cùng generation, không repository hoặc cache account.
  @override
  State<WorkspaceSelectionScreen> createState() =>
      _WorkspaceSelectionScreenState();
}

class _WorkspaceSelectionScreenState extends State<WorkspaceSelectionScreen> {
  bool _working = false;
  bool _unknown = false;
  String _progressText = '';

  /// Mở form password theo snapshot hiện tại; host vẫn kiểm epoch/full scope khi event tới.
  void _changePassword() {
    if (!_working && !_unknown && _phase.canRefresh)
      widget.onChangePassword?.call();
  }

  /// Output: exception luôn khóa snapshot hiện tại cho tới generation mới đã được host đối soát.
  WorkspaceSelectionPhase get _phase =>
      _unknown ? WorkspaceSelectionPhase.pending : widget.state.phase;

  /// Chỉ nhận một intent đang sống và xử lý exception bằng unknown an toàn, không leak detail.
  /// Input
  /// Param: intent — thao tác capability của host, null thì không có thao tác.
  /// Param: allowed — điều kiện đọc từ snapshot hiện hành lúc event tới, không chỉ từ button đã render.
  /// Param: progressText — nhãn UI cố định trong khi chờ, không lấy từ exception.
  Future<void> _runIntent(
    Future<void> Function()? intent, {
    required bool allowed,
    required String progressText,
  }) async {
    if (!mounted || _working || !allowed || intent == null) return;
    setState(
      /// Khóa đồng bộ trước await để double tap hoặc callback cũ không phát intent thứ hai.
      () {
        _working = true;
        _progressText = progressText;
      },
    );
    try {
      await intent();
    } catch (_) {
      if (mounted) {
        setState(
          /// Không suy exception thành fail chắc chắn hoặc reset ready; host phải đối soát riêng.
          () {
            _unknown = true;
          },
        );
      }
    } finally {
      if (mounted) {
        setState(
          /// Callback account cũ không được setState khi widget generation đã disposed.
          () {
            _working = false;
          },
        );
      }
    }
  }

  /// So lại row hiện hành để event đến muộn không chọn item đã xóa/đổi revision hoặc mất active.
  /// Input
  /// Param: candidate — row gắn vào event cũ, không được dùng trực tiếp làm quyền.
  Future<void> _select(WorkspaceOption candidate) async {
    if (!mounted || _phase != WorkspaceSelectionPhase.ready || _working) return;
    for (final current in widget.state.options) {
      if (current.id == candidate.id &&
          current.revision == candidate.revision &&
          current.status == WorkspaceStatus.active) {
        await _runIntent(
          /// Host nhận snapshot mới nhất; server membership recheck vẫn bắt buộc trước route/data.
          () => widget.onSelect(current),
          allowed: true,
          progressText: 'Đang kiểm tra workspace',
        );
        return;
      }
    }
  }

  /// Tải lại chỉ theo phase hiện hành, không cho event refresh cũ thoát pending/storage failure.
  Future<void> _refresh() => _runIntent(
    widget.onRefresh,
    allowed: _phase.canRefresh,
    progressText: 'Đang tải lại danh sách',
  );

  /// Host chịu cursor; nếu metadata trang đã đổi thì event tải thêm cũ không còn hiệu lực.
  Future<void> _loadMore() => _runIntent(
    widget.onLoadMore,
    allowed: _phase == WorkspaceSelectionPhase.ready && widget.state.hasMore,
    progressText: 'Đang tải thêm workspace',
  );

  /// Đối soát riêng, giữ local unknown kể cả callback trả về mà host chưa cấp generation mới.
  Future<void> _recover() => _runIntent(
    widget.onRecover,
    allowed:
        _phase == WorkspaceSelectionPhase.pending ||
        _phase == WorkspaceSelectionPhase.storageFailure,
    progressText: 'Đang kiểm tra trạng thái',
  );

  /// Create chỉ thuộc empty thật và capability065 do host cấp, không có link giả.
  Future<void> _create() => _runIntent(
    widget.onCreate,
    allowed: !_unknown && widget.state.isEmpty,
    progressText: 'Đang mở tạo workspace',
  );

  /// Không phát logout mutation mới khi scope đang unknown hoặc storage chưa bảo vệ được phiên.
  Future<void> _logout() => _runIntent(
    widget.onLogout,
    allowed:
        !_unknown &&
        (_phase.canRefresh || _phase == WorkspaceSelectionPhase.selected),
    progressText: 'Đang đăng xuất',
  );

  /// Dựng business list trong vùng cuộn có max width, nền aurora và header/controls theo Nexa theme.
  /// Input
  /// Param: context — theme/constraints hiện tại, không account authority.
  /// Output: màn picker không tự chọn item hoặc mở protected route.
  @override
  Widget build(BuildContext context) {
    final showRows =
        _phase == WorkspaceSelectionPhase.ready ||
        _phase == WorkspaceSelectionPhase.loadingMore;
    final rows = showRows ? widget.state.options : const <WorkspaceOption>[];
    return Stack(
      fit: StackFit.expand,
      children: [
        const Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(child: NexaAuroraBackdrop()),
          ),
        ),
        Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            automaticallyImplyLeading: false,
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            scrolledUnderElevation: 0,
            elevation: 0,
            toolbarHeight: 72,
            title: const NexaBrand(),
            actions: [
              if (widget.onToggleTheme != null)
                NexaThemeToggleButton(onPressed: widget.onToggleTheme!),
              const SizedBox(width: 12),
            ],
          ),
          body: SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: ListView.builder(
                  // List đang phân trang giữ offset; status/empty mới phải về đầu để không giấu lỗi/progress sau scroll cũ.
                  key: ValueKey(
                    showRows && !widget.state.isEmpty
                        ? 'workspace-rows'
                        : 'workspace-status-${_phase.name}',
                  ),
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
                  itemCount: rows.length + 2,
                  itemBuilder:
                      /// Giữ row list snapshot của frame, không index vào list mới có thể ngắn hơn.
                      /// Input
                      /// Param: context — theme của list item.
                      /// Param: index — header0, các row và footer cuối.
                      (context, index) {
                        if (index == 0) return _header(context);
                        if (index == rows.length + 1) return _footer(context);
                        return _row(context, rows[index - 1]);
                      },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Đưa heading/mô tả và live status trước danh sách theo thứ tự đọc, đồng bộ nhận diện thẻ Nexa.
  /// Input
  /// Param: context — theme dùng typography và palette đã có.
  /// Output: header cuộn được ở text scale lớn.
  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = NexaAuthTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ExcludeSemantics(
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    gradient: nexaActionGradient,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: tokens.glow,
                  ),
                  child: const Icon(
                    Icons.grid_view_rounded,
                    color: nexaActionInk,
                    size: 24,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              const Expanded(child: NexaEyebrow()),
            ],
          ),
          const SizedBox(height: 18),
          NexaGradientHeading(
            text: 'Chọn workspace',
            style: theme.textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          const Text('Chọn không gian làm việc bạn muốn sử dụng.'),
          const SizedBox(height: 20),
          if (_phase == WorkspaceSelectionPhase.ready &&
              !_working &&
              !widget.state.isEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: scheme.surface.withValues(alpha: .85),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: tokens.line),
                  boxShadow: tokens.shadow,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ExcludeSemantics(
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        widget.state.options.isEmpty
                            ? 'Chưa tải xong danh sách'
                            : '${widget.state.options.length} workspace đã tải',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: scheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            _notice(context),
        ],
      ),
    );
  }

  /// Status bằng chữ và màu semantic; ẩn toàn bộ row khi pending/error thay vì coi cache là quyền.
  /// Input
  /// Param: context — palette và reduced-motion preference của Android.
  /// Output: live region không lấy focus hoặc tiết lộ error payload.
  Widget _notice(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = NexaAuthTokens.of(context);
    final isEmpty = !_unknown && widget.state.isEmpty && !_working;
    final isBusy =
        _working ||
        _phase == WorkspaceSelectionPhase.loading ||
        _phase == WorkspaceSelectionPhase.loadingMore;
    final failed =
        _phase == WorkspaceSelectionPhase.error ||
        _phase == WorkspaceSelectionPhase.permissionDenied ||
        _phase == WorkspaceSelectionPhase.storageFailure;
    final waiting =
        _phase == WorkspaceSelectionPhase.pending ||
        _phase == WorkspaceSelectionPhase.stale ||
        _phase == WorkspaceSelectionPhase.offline;
    final (background, foreground) = switch (_phase) {
      _ when isBusy => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
      _ when failed => (scheme.errorContainer, scheme.onErrorContainer),
      _ when waiting => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
      WorkspaceSelectionPhase.selected => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      _ => (scheme.surface, scheme.onSurface),
    };
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: failed
                ? Color.lerp(scheme.outlineVariant, scheme.error, .35)!
                : foreground.withValues(alpha: .22),
          ),
          boxShadow: tokens.shadow,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: foreground.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(14),
                ),
                alignment: Alignment.center,
                child: isBusy && !MediaQuery.disableAnimationsOf(context)
                    ? SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: foreground,
                        ),
                      )
                    : Icon(
                        isBusy
                            ? Icons.hourglass_empty_outlined
                            : isEmpty
                            ? Icons.workspaces_outline
                            : _phase == WorkspaceSelectionPhase.selected
                            ? Icons.check_circle_outline
                            : Icons.info_outline,
                        color: foreground,
                      ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              isEmpty
                  ? 'Không có workspace khả dụng'
                  : _working
                  ? _progressText
                  : _phase.title,
              style: TextStyle(
                color: foreground,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              isEmpty
                  ? 'Bạn chưa có workspace khả dụng. Hãy tải lại danh sách hoặc tạo workspace khi tính năng sẵn sàng.'
                  : _working
                  ? 'Vui lòng chờ trong khi thao tác được hoàn tất.'
                  : _phase.description,
              style: TextStyle(color: foreground, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  /// Row native có label đầy đủ, icon đại diện, chip vai trò, wrap tên dài; inactive chỉ giải thích và không phát intent.
  /// Input
  /// Param: context — màu chữ/viền của theme.
  /// Param: option — summary của snapshot frame, được kiểm lại khi event thực thi.
  /// Output: nút chạm/keyboard tối thiểu48dp đồng bộ với .auth-workspaces li trên Web.
  Widget _row(BuildContext context, WorkspaceOption option) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = NexaAuthTokens.of(context);
    final isAdmin = option.role == WorkspaceRole.admin;
    final isActive = option.status == WorkspaceStatus.active;
    final enabled =
        !_working && _phase == WorkspaceSelectionPhase.ready && isActive;
    return Padding(
      key: ValueKey('workspace-row-${option.id}'),
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          boxShadow: tokens.shadow,
        ),
        child: OutlinedButton(
          key: ValueKey('workspace-select-${option.id}'),
          onPressed: enabled
              ?
                /// Event luôn qua guard hiện hành thay vì tin trạng thái button cũ.
                () => _select(option)
              : null,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(double.infinity, 48),
            padding: const EdgeInsets.all(16),
            backgroundColor: scheme.surface.withValues(alpha: .94),
            foregroundColor: scheme.onSurface,
            side: BorderSide(
              color: enabled && isAdmin
                  ? scheme.primary.withValues(alpha: .35)
                  : tokens.line,
              width: 1.5,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
          ),
          child: Row(
            children: [
              ExcludeSemantics(
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(13),
                    border: Border.all(
                      color: scheme.primary.withValues(alpha: .22),
                    ),
                  ),
                  child: Icon(
                    isAdmin ? Icons.hub_outlined : Icons.workspaces_outlined,
                    color: scheme.onPrimaryContainer,
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      option.name,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: isAdmin
                                ? scheme.primaryContainer
                                : tokens.surfaceAlt,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: isAdmin
                                  ? scheme.primary.withValues(alpha: .28)
                                  : tokens.line,
                            ),
                          ),
                          child: Text(
                            option.role.label,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: isAdmin
                                  ? scheme.onPrimaryContainer
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        if (!isActive)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.tertiaryContainer,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              option.status.label,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: scheme.onTertiaryContainer,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ExcludeSemantics(
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: tokens.surfaceAlt,
                    shape: BoxShape.circle,
                    border: Border.all(color: tokens.line),
                  ),
                  child: Icon(
                    Icons.chevron_right_rounded,
                    color: enabled ? scheme.primary : scheme.onSurfaceVariant,
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Footer chỉ nối capability thật của host; empty create bị khóa rõ ràng khi065 chưa có.
  /// Input
  /// Param: context — layout/theming nhất quán với list.
  /// Output: control48dp cuộn cùng nội dung để không che focus trên màn hẹp/chữ lớn.
  Widget _footer(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = NexaAuthTokens.of(context);
    final canRecover =
        _phase == WorkspaceSelectionPhase.pending ||
        _phase == WorkspaceSelectionPhase.storageFailure;
    final canLogout =
        !_unknown &&
        (_phase.canRefresh || _phase == WorkspaceSelectionPhase.selected);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_phase == WorkspaceSelectionPhase.loadingMore)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_phase.title),
            ),
          if (!_unknown && widget.state.isEmpty) ...[
            FilledButton(
              key: const ValueKey('workspace-create'),
              onPressed: !_working && widget.onCreate != null ? _create : null,
              style: FilledButton.styleFrom(
                minimumSize: const Size(48, 52),
                shape: const StadiumBorder(),
              ),
              child: const Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  ExcludeSemantics(child: Icon(Icons.add_rounded, size: 20)),
                  Text('Tạo workspace'),
                ],
              ),
            ),
            if (widget.onCreate == null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'Tạo workspace chưa khả dụng trong phiên bản này.',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
          ],
          if (_phase == WorkspaceSelectionPhase.ready &&
              widget.state.hasMore) ...[
            OutlinedButton(
              key: const ValueKey('workspace-load-more'),
              onPressed: !_working && widget.onLoadMore != null
                  ? _loadMore
                  : null,
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              child: const Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  ExcludeSemantics(
                    child: Icon(Icons.expand_more_rounded, size: 20),
                  ),
                  Text('Tải thêm workspace'),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (canRecover) ...[
            OutlinedButton(
              key: const ValueKey('workspace-recover'),
              onPressed: !_working && widget.onRecover != null
                  ? _recover
                  : null,
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              child: const Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  ExcludeSemantics(child: Icon(Icons.sync_rounded, size: 18)),
                  Text('Kiểm tra trạng thái'),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          OutlinedButton(
            key: const ValueKey('workspace-refresh'),
            onPressed: !_working && _phase.canRefresh && widget.onRefresh != null
                ? _refresh
                : null,
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            child: const Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                ExcludeSemantics(child: Icon(Icons.refresh_rounded, size: 18)),
                Text('Tải lại danh sách'),
              ],
            ),
          ),
          if (widget.onChangePassword != null || widget.onLogout != null) ...[
            const SizedBox(height: 20),
            Divider(height: 1, color: tokens.line),
            const SizedBox(height: 16),
          ],
          if (widget.onChangePassword != null) ...[
            OutlinedButton(
              key: const ValueKey('workspace-password'),
              onPressed: !_working && !_unknown && _phase.canRefresh
                  ? _changePassword
                  : null,
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              child: const Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  ExcludeSemantics(child: Icon(Icons.key_rounded, size: 18)),
                  Text('Đổi mật khẩu'),
                ],
              ),
            ),
            if (widget.onLogout != null) const SizedBox(height: 12),
          ],
          if (widget.onLogout != null)
            TextButton(
              key: const ValueKey('workspace-logout'),
              onPressed: !_working && canLogout ? _logout : null,
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                foregroundColor: scheme.onSurfaceVariant,
                textStyle: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: const Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  ExcludeSemantics(child: Icon(Icons.logout_rounded, size: 18)),
                  Text('Đăng xuất'),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
