import 'dart:async';

import 'package:flutter/material.dart';

import '../../../ui/nexa_auth_theme.dart';
import '../../workspaces/presentation/workspace_selection_screen.dart';
import '../../workspaces/presentation/workspace_selection_state.dart';
import '../data/app_auth_failure.dart';
import '../data/app_session_state.dart';
import 'app_auth_coordinator.dart';
import 'login_screen.dart';
import 'login_view_state.dart';
import 'password_change_screen.dart';
import 'password_change_state.dart';

/// Host nghiệp vụ sở hữu coordinator suốt lifetime, không dùng preview hoặc route làm quyền.
class AppAuthApplication extends StatefulWidget {
  /// Nhận coordinator do composition tạo đúng một lần.
  /// Input
  /// Param: coordinator — chủ presentation lifetime, không bearer/password.
  const AppAuthApplication({super.key, required this.coordinator});
  final AppAuthCoordinator coordinator;

  /// Output: host lifecycle/theming, không tái tạo repository khi rebuild.
  @override
  State<AppAuthApplication> createState() => _AppAuthApplicationState();
}

class _AppAuthApplicationState extends State<AppAuthApplication>
    with WidgetsBindingObserver {
  ThemeMode _themeMode = ThemeMode.system;

  /// Output: một coordinator duy nhất được composition truyền vào lifetime hiện tại.
  AppAuthCoordinator get _coordinator => widget.coordinator;

  /// Đọc lifecycle đã có trước bootstrap để mount trong background không mở protected state.
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      _coordinator.suspend();
    } else {
      unawaited(_coordinator.initialize());
    }
  }

  /// Không cho thay repository qua rebuild để bypass unknown/quarantine của lifetime cũ.
  /// Input
  /// Param: oldWidget — coordinator host trước update, phải cùng instance hiện tại.
  @override
  void didUpdateWidget(AppAuthApplication oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.coordinator, _coordinator))
      throw StateError('AUTH_LIFETIME_CHANGED');
  }

  /// Native Future vẫn drain trong coordinator sau khi widget bị gỡ, không tự logout stable session.
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _coordinator.dispose();
    super.dispose();
  }

  /// Mọi non-resumed khóa ngay; foreground luôn recheck server trước trả nội dung.
  /// Input
  /// Param: state — event lifecycle từ Flutter binding, không metadata xác thực.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_coordinator.resume());
    } else {
      _coordinator.suspend();
    }
  }

  /// Đổi sáng/tối trong RAM theo Nexa, không thay session hoặc giữ cấu hình account.
  void _toggleTheme() => setState(
    /// Dùng brightness platform chỉ làm mặc định thị giác; không đọc biến môi trường hệ thống.
    () {
      final dark =
          _themeMode == ThemeMode.dark ||
          (_themeMode == ThemeMode.system &&
              WidgetsBinding.instance.platformDispatcher.platformBrightness ==
                  Brightness.dark);
      _themeMode = dark ? ThemeMode.light : ThemeMode.dark;
    },
  );

  /// Dựng theme dùng chung với home/login; ListenableBuilder chỉ render current snapshot.
  /// Input
  /// Param: context — root widget context, không account authority.
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Nexa IoT',
    debugShowCheckedModeBanner: false,
    theme: nexaAuthTheme(Brightness.light),
    darkTheme: nexaAuthTheme(Brightness.dark),
    themeMode: _themeMode,
    home: ListenableBuilder(listenable: _coordinator, builder: _buildPage),
  );

  /// Chụp epoch vào callback tại render; không lấy epoch mới khi event của frame cũ thực thi.
  /// Input
  /// Param: context — theme/semantics của route hiện tại.
  /// Param: child — child cố định của ListenableBuilder không dùng ở host động này.
  /// Output: một màn duy nhất, không giữ protected widgets trong animation hoặc history.
  Widget _buildPage(BuildContext context, Widget? child) {
    final epoch = _coordinator.generation;
    final page = _coordinator.page;
    final state = _coordinator.session;
    final canReturn =
        page == AppAuthPage.summary ||
        (page == AppAuthPage.password && state.phase == AppSessionPhase.full);
    final seconds = _coordinator.retryAfterSeconds;
    final key = ValueKey('${page.name}:$epoch');
    final Future<void> Function() recover =
        /// Đối soát riêng, không replay input hoặc nhận epoch mới cho callback cũ.
        () => _coordinator.recover(expectedGeneration: epoch);
    final Future<void> Function() logout =
        /// Repository tự kiểm known token/server proof và native delete ACK.
        () => _coordinator.logout(expectedGeneration: epoch);
    final Future<void> Function() refresh =
        /// Back/refresh luôn tải lại server, không mở selection cache.
        () => _coordinator.refreshWorkspaces(expectedGeneration: epoch);
    final VoidCallback back =
        /// Native/visible back full chỉ phát GET mới khi epoch còn hiện hành.
        () => unawaited(refresh());
    Widget screen;
    if (seconds > 0) {
      screen = AuthStatusScreen(
        key: const ValueKey('app-cooldown'),
        title: 'Thử lại sau $seconds giây',
        description: 'Đã có nhiều yêu cầu. Hãy chờ rồi chủ động thử lại.',
        waiting: true,
        onToggleTheme: _toggleTheme,
        actions: [
          if (_coordinator.canLogout)
            _action('cooldown-logout', 'Đăng xuất', logout),
        ],
      );
    } else {
      screen = switch (page) {
        AppAuthPage.loading => AuthStatusScreen(
          key: const ValueKey('app-loading'),
          title: 'Đang xác minh phiên',
          description: 'Vui lòng chờ trong giây lát.',
          loading: true,
          onToggleTheme: _toggleTheme,
        ),
        AppAuthPage.login => LoginScreen(
          key: key,
          state: _loginState(),
          onSubmit:
              /// Input
              /// Param: email — input gốc từ form, backend chuẩn hóa.
              /// Param: password — secret một lần, không lưu ở host.
              (email, password) => _coordinator.login(
                email,
                password,
                expectedGeneration: epoch,
              ),
          onRecover: recover,
          onToggleTheme: _toggleTheme,
        ),
        AppAuthPage.password => PasswordChangeScreen(
          key: key,
          state: _passwordState(),
          onSubmit:
              /// Input
              /// Param: currentPassword — secret cũ, không trim/replay.
              /// Param: newPassword — secret mới do shared policy kiểm ở form/server.
              (currentPassword, newPassword) => _coordinator.changePassword(
                currentPassword,
                newPassword,
                expectedGeneration: epoch,
              ),
          onRecover: recover,
          onLeave: logout,
          onBack: canReturn ? back : null,
          onToggleTheme: _toggleTheme,
        ),
        AppAuthPage.workspaces => WorkspaceSelectionScreen(
          key: key,
          state: _workspaceState(),
          onSelect:
              /// Input
              /// Param: option — row của frame hiện tại, coordinator/repository kiểm lại trước server detail.
              (option) => _coordinator.selectWorkspace(
                option,
                expectedGeneration: epoch,
              ),
          onRefresh: refresh,
          onLoadMore:
              /// Cursor private ở repository, không chuyển vào widget hoặc URL navigation.
              () => _coordinator.loadMore(expectedGeneration: epoch),
          onLogout: _coordinator.canLogout ? logout : null,
          onChangePassword:
              /// Chỉ full mới có route picker, epoch vẫn được kiểm lại lúc bấm.
              () => _coordinator.openPassword(expectedGeneration: epoch),
          onToggleTheme: _toggleTheme,
        ),
        AppAuthPage.summary => AuthStatusScreen(
          key: const ValueKey('session-summary'),
          title: 'Đã kết nối workspace',
          description: 'Phiên và quyền truy cập workspace đã được xác minh.',
          onToggleTheme: _toggleTheme,
          details: [
            _buildSessionSummaryCard(
              context,
              email: state.profile!.email,
              workspaceName: _workspaceName(state.selectedWorkspace!.name),
              isAdmin: state.selectedWorkspace!.role == 'ADMIN',
            ),
          ],
          actions: [
            _action('session-back', 'Đổi workspace', refresh),
            OutlinedButton(
              key: const ValueKey('session-password'),
              onPressed:
                  /// Mở form riêng; không gửi mutation từ nút navigation.
                  () => _coordinator.openPassword(expectedGeneration: epoch),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              child: const Text('Đổi mật khẩu'),
            ),
            if (_coordinator.canLogout)
              _action('session-logout', 'Đăng xuất', logout),
          ],
        ),
        AppAuthPage.recovery => AuthStatusScreen(
          key: const ValueKey('app-recovery'),
          title: state.phase == AppSessionPhase.storageFailure
              ? 'Chưa thể bảo vệ phiên'
              : state.phase == AppSessionPhase.offline
              ? 'Không có kết nối'
              : 'Cần xác minh trạng thái',
          description: state.phase == AppSessionPhase.storageFailure
              ? 'Chưa thể đọc hoặc dọn phiên an toàn trên thiết bị. Kiểm tra trạng thái trước khi tiếp tục.'
              : state.phase == AppSessionPhase.offline
              ? 'Kiểm tra kết nối rồi chủ động kiểm tra lại trạng thái phiên.'
              : 'Chưa xác nhận kết quả yêu cầu. Kiểm tra trạng thái hoặc đăng xuất phiên hiện tại; yêu cầu không được tự gửi lại.',
          error: state.phase == AppSessionPhase.storageFailure,
          waiting: state.phase != AppSessionPhase.storageFailure,
          onToggleTheme: _toggleTheme,
          actions: [
            _action('app-recover', 'Kiểm tra trạng thái', recover),
            if (_coordinator.canLogout)
              _action('recovery-logout', 'Đăng xuất', logout),
          ],
        ),
      };
    }
    return PopScope<Object?>(
      canPop:
          !canReturn &&
          page != AppAuthPage.loading &&
          page != AppAuthPage.recovery,
      onPopInvokedWithResult:
          /// Input
          /// Param: didPop — Navigator đã xử lý pop, không phát thêm action khi true.
          /// Param: result — kết quả route không dùng làm authority hoặc credential.
          (didPop, result) {
            if (!didPop && canReturn) back();
          },
      child: screen,
    );
  }

  /// Map chỉ lỗi login; failure của operation khác không biến thành credential rejection.
  /// Output: copy cố định của form,429 được countdown card xử lý riêng.
  LoginViewState _loginState() {
    if (_coordinator.intent != AppAuthIntent.login) return LoginViewState.ready;
    return switch (_coordinator.session.failure?.kind) {
      AppAuthFailureKind.invalidCredentials ||
      AppAuthFailureKind.validation => LoginViewState.rejected,
      AppAuthFailureKind.networkUnavailable =>
        LoginViewState.networkUnavailable,
      AppAuthFailureKind.permissionDenied => LoginViewState.permissionDenied,
      AppAuthFailureKind.conflict => LoginViewState.conflict,
      _ => LoginViewState.ready,
    };
  }

  /// Known password errors giữ đúng scope; unknown đã route recovery bởi repository.
  /// Output: phase có recover riêng khi chưa được phép gửi mutation mới.
  PasswordChangeState _passwordState() {
    if (_coordinator.intent != AppAuthIntent.password)
      return PasswordChangeState.ready;
    return switch (_coordinator.session.failure?.kind) {
      AppAuthFailureKind.invalidCredentials ||
      AppAuthFailureKind.validation => PasswordChangeState.rejected,
      AppAuthFailureKind.networkUnavailable =>
        PasswordChangeState.networkUnavailable,
      AppAuthFailureKind.permissionDenied =>
        PasswordChangeState.permissionDenied,
      AppAuthFailureKind.conflict => PasswordChangeState.conflict,
      AppAuthFailureKind.unavailable => PasswordChangeState.serviceUnavailable,
      _ => PasswordChangeState.ready,
    };
  }

  /// DTO đã validate trở thành plain presentation rows; error không bị giả thành confirmed empty.
  /// Output: immutable snapshot chỉ có label/id/revision, không bearer/cursor.
  WorkspaceSelectionState _workspaceState() {
    final state = _coordinator.session;
    final phase = switch (state.failure?.kind) {
      AppAuthFailureKind.permissionDenied ||
      AppAuthFailureKind.resourceNotFound =>
        WorkspaceSelectionPhase.permissionDenied,
      AppAuthFailureKind.conflict ||
      AppAuthFailureKind.cursorInvalid => WorkspaceSelectionPhase.stale,
      null =>
        state.workspacesLoaded
            ? WorkspaceSelectionPhase.ready
            : WorkspaceSelectionPhase.loading,
      _ => WorkspaceSelectionPhase.error,
    };
    return WorkspaceSelectionState(
      phase: phase,
      options: [
        for (final item in state.workspaces)
          WorkspaceOption(
            id: item.id,
            name: _workspaceName(item.name),
            role: item.role == 'ADMIN'
                ? WorkspaceRole.admin
                : WorkspaceRole.user,
            revision: item.revision,
            status: WorkspaceStatus.active,
          ),
      ],
      hasMore: state.nextWorkspaceCursor != null,
    );
  }

  /// Tên trống từ schema tương thích cần fallback plain text, không sửa identity hoặc dữ liệu server.
  /// Input
  /// Param: name — tên untrusted đã là string, không HTML.
  /// Output: giữ nguyên tên có nội dung, fallback khi chỉ whitespace.
  String _workspaceName(String name) =>
      name.trim().isEmpty ? 'Workspace chưa đặt tên' : name;

  /// Dựng bảng thông tin phiên đã kết nối đồng bộ với .auth-session-summary trên Web.
  /// Input
  /// Param: context — theme hiện tại để đọc token bề mặt và chữ.
  /// Param: email — địa chỉ tài khoản đã xác thực từ profile.
  /// Param: workspaceName — tên workspace đã chuẩn hóa fallback.
  /// Param: isAdmin — true nếu vai trò trong workspace là ADMIN.
  /// Output: thẻ tóm tắt phiên giữ nguyên các Text node đơn lẻ phục vụ kiểm thử E2E/widget.
  Widget _buildSessionSummaryCard(
    BuildContext context, {
    required String email,
    required String workspaceName,
    required bool isAdmin,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tokens = NexaAuthTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: tokens.surfaceAlt.withValues(alpha: .88),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: tokens.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(
                    Icons.workspaces_outlined,
                    size: 20,
                    color: colors.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'WORKSPACE ĐANG KẾT NỐI',
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.0,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(workspaceName, style: theme.textTheme.titleLarge),
                  ],
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Divider(height: 1, color: tokens.line),
          ),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ExcludeSemantics(
                    child: Icon(
                      Icons.person_outline_rounded,
                      size: 18,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      email,
                      style: TextStyle(
                        color: colors.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: isAdmin ? colors.primaryContainer : colors.surface,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: isAdmin
                        ? colors.primary.withValues(alpha: .32)
                        : tokens.line,
                  ),
                ),
                child: Text(
                  isAdmin ? 'Quản trị viên' : 'Thành viên',
                  style: TextStyle(
                    color: isAdmin
                        ? colors.onPrimaryContainer
                        : colors.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Action native48dp; callback đã capture đúng epoch tại nơi gọi.
  /// Input
  /// Param: key — key ổn định để kiểm interaction, không identity account.
  /// Param: label — nhãn tiếng Việt cố định.
  /// Param: operation — intent chủ động riêng, không password retry.
  Widget _action(String key, String label, Future<void> Function() operation) =>
      OutlinedButton(
        key: ValueKey(key),
        onPressed:
            /// Future được coordinator giữ ownership; widget không queue hoặc giữ credential.
            () => unawaited(operation()),
        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
        child: Text(label),
      );
}

/// Shell nghiệp vụ cho bootstrap/recovery/summary/config; cuộn cả header để chữ lớn không che control.
class AuthStatusScreen extends StatelessWidget {
  /// Nhận copy an toàn và actions đã admission; không nhận exception/payload/token.
  /// Input
  /// Param: title — tiêu đề có semantics heading.
  /// Param: description — hướng xử lý rõ ràng cho trạng thái.
  /// Param: loading — progress chờ server/ACK, không giả thành success.
  /// Param: waiting — màu amber cho unknown/cooldown.
  /// Param: error — error surface+ink cùng token login.
  /// Param: details — thông tin scalar đã được repository admission.
  /// Param: actions — controls có label và target48dp.
  /// Param: onToggleTheme — đổi thị giác ở host, null khi startup chưa có host.
  const AuthStatusScreen({
    super.key,
    required this.title,
    required this.description,
    this.loading = false,
    this.waiting = false,
    this.error = false,
    this.details = const [],
    this.actions = const [],
    this.onToggleTheme,
  });
  final String title;
  final String description;
  final bool loading;
  final bool waiting;
  final bool error;
  final List<Widget> details;
  final List<Widget> actions;
  final VoidCallback? onToggleTheme;

  /// Dựng card max640dp trên nền aurora Nexa, dùng safe scroll thay fixed-height hero, hỗ trợ200%text/ngang.
  /// Input
  /// Param: context — theme hiện tại và tùy chọn giảm chuyển động.
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final badgeBackground = error
        ? colors.errorContainer
        : waiting
        ? colors.tertiaryContainer
        : colors.primaryContainer;
    final badgeForeground = error
        ? colors.onErrorContainer
        : waiting
        ? colors.onTertiaryContainer
        : colors.onPrimaryContainer;
    final topAccent = error
        ? colors.error
        : waiting
        ? colors.tertiary
        : null;
    final titleColor = error
        ? colors.onErrorContainer
        : waiting
        ? colors.onTertiaryContainer
        : colors.onSurface;
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
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Expanded(child: NexaBrand()),
                          if (onToggleTheme != null)
                            NexaThemeToggleButton(onPressed: onToggleTheme!),
                        ],
                      ),
                      const SizedBox(height: 24),
                      NexaSurfaceCard(
                        accentColor: topAccent,
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                if (loading &&
                                    !MediaQuery.disableAnimationsOf(context))
                                  Container(
                                    width: 48,
                                    height: 48,
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: badgeBackground,
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    child: const CircularProgressIndicator(
                                      strokeWidth: 2.6,
                                      semanticsLabel: 'Đang xác minh phiên',
                                    ),
                                  )
                                else
                                  ExcludeSemantics(
                                    child: Container(
                                      width: 48,
                                      height: 48,
                                      decoration: BoxDecoration(
                                        color: badgeBackground,
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                      child: Icon(
                                        error
                                            ? Icons.error_outline_rounded
                                            : waiting
                                            ? Icons.schedule_rounded
                                            : loading
                                            ? Icons.hourglass_empty_rounded
                                            : Icons.verified_user_outlined,
                                        color: badgeForeground,
                                        size: 24,
                                      ),
                                    ),
                                  ),
                                const SizedBox(width: 14),
                                const Expanded(child: NexaEyebrow()),
                              ],
                            ),
                            const SizedBox(height: 18),
                            if (error || waiting)
                              Semantics(
                                header: true,
                                liveRegion: !loading,
                                child: Text(
                                  title,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineMedium
                                      ?.copyWith(color: titleColor),
                                ),
                              )
                            else
                              NexaGradientHeading(
                                text: title,
                                liveRegion: !loading,
                                style: Theme.of(
                                  context,
                                ).textTheme.headlineMedium,
                              ),
                            const SizedBox(height: 10),
                            Text(
                              description,
                              style: TextStyle(
                                color: colors.onSurfaceVariant,
                                fontSize: 16,
                                height: 1.5,
                              ),
                            ),
                            if (details.isNotEmpty) ...[
                              const SizedBox(height: 20),
                              ...details,
                            ],
                            for (final action in actions) ...[
                              const SizedBox(height: 14),
                              action,
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
