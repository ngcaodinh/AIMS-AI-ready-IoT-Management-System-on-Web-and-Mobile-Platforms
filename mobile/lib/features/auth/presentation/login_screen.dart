import 'dart:async';

import 'package:flutter/material.dart';

import '../../../ui/nexa_auth_theme.dart';
import '../../../core/validation/password_policy.dart';
import 'login_view_state.dart';

// Bề rộng tối thiểu (dp) để tách hero và form thành hai cột; dưới mốc này điện thoại/tablet dọc giữ một cột tập trung vào form.
const double _wideLayoutMinWidth = 960;

// Ba năng lực cốt lõi đã nêu trên trang chủ Web; chỉ là copy giới thiệu, không phản ánh quyền của account đang đăng nhập.
const _heroFeatures = [
  (
    Icons.sensors_rounded,
    'Telemetry thời gian thực',
    'Theo dõi cảm biến và trạng thái thiết bị liên tục.',
  ),
  (
    Icons.auto_mode_rounded,
    'Tự động hóa theo quy tắc',
    'Lập lịch, điều kiện và hành động cho từng thiết bị.',
  ),
  (
    Icons.shield_outlined,
    'Tách biệt theo workspace',
    'Dữ liệu và quyền được giới hạn trong từng workspace.',
  ),
];

/// Form presentation không gọi API/storage, không điều hướng hoặc cấp quyền từ kết quả giả.
class LoginScreen extends StatefulWidget {
  /// Nhận state và callback từ host; generation mới phải dùng key mới sau callback exception/đối soát.
  /// Input
  /// Param: state — trạng thái hiển thị đã được host quyết định, không là admission token.
  /// Param: onSubmit — một intent với email/password nguyên chuỗi; host chịu trách nhiệm timeout/error/revoke.
  /// Param: onRecover — đối soát riêng, không tự retry login; null khi host chưa cung cấp phục hồi.
  /// Param: onToggleTheme — lựa chọn thị giác ở host, không ảnh hưởng auth state.
  const LoginScreen({
    super.key,
    required this.state,
    required this.onSubmit,
    this.onRecover,
    this.onToggleTheme,
  });

  final LoginViewState state;
  final Future<void> Function(String email, String password) onSubmit;
  final Future<void> Function()? onRecover;
  final VoidCallback? onToggleTheme;

  /// Tạo controller chỉ sống cùng form để không giữ credential qua màn hoặc account generation.
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _emailFocus = FocusNode();
  final _passwordFocus = FocusNode();
  bool _working = false;
  bool _showPassword = false;
  bool _validationFailed = false;
  bool _callbackFailed = false;
  // Trạng thái nhấn chỉ phục vụ hiệu ứng thu nhỏ của CTA, không tham gia quyết định gửi form.
  bool _buttonPressed = false;

  /// Host đổi trạng thái thì bỏ password đang nhập; callback đã nhận bản RAM trước khi controller bị xóa.
  /// Input
  /// Param: oldWidget — state presentation trước đó, không dùng để khôi phục credential.
  @override
  void didUpdateWidget(LoginScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) _password.clear();
  }

  /// Giải phóng input/focus của generation cũ, không lưu password để retry hoặc restore.
  @override
  void dispose() {
    _password.clear();
    _email.dispose();
    _password.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  /// Kiểm email phục vụ UX giống Web; backend vẫn chuẩn hóa và validate boundary thật.
  /// Input
  /// Param: value — text người dùng nhập, không là dữ liệu đã được tin cậy.
  /// Output: lỗi cố định hoặc null khi qua kiểm UX, không tiết lộ account tồn tại.
  String? _validateEmail(String? value) =>
      RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch((value ?? '').trim())
      ? null
      : 'Nhập địa chỉ email hợp lệ.';

  /// Đếm Unicode codepoint như contract JSON, không trim hoặc cắt password khi paste.
  /// Input
  /// Param: value — password trong controller, không ghi log hoặc serialize.
  /// Output: lỗi độ dài cố định; không đưa giá trị vào message.
  String? _validatePassword(String? value) {
    return validatePassword(value ?? '', PasswordPurpose.login)?.message;
  }

  /// Gửi đúng một intent sau validate, xóa password trước await và khóa khi kết quả chưa rõ.
  Future<void> _submit() async {
    if (_working || _callbackFailed || !widget.state.canSubmit) return;
    if (!_formKey.currentState!.validate()) {
      setState(
        /// Hiện summary song song lỗi từng trường để người dùng không phải đoán vị trí lỗi.
        () {
          _validationFailed = true;
        },
      );
      if (_validateEmail(_email.text) != null) {
        _emailFocus.requestFocus();
      } else {
        _passwordFocus.requestFocus();
      }
      return;
    }
    final submittedPassword = _password.text;
    _password.clear();
    FocusScope.of(context).unfocus();
    setState(
      /// Khóa ngay trong frame hiện tại để không chờ host rebuild mới chặn double-submit.
      () {
        _working = true;
        _validationFailed = false;
      },
    );
    try {
      await widget.onSubmit(_email.text, submittedPassword);
    } catch (_) {
      if (mounted)
        setState(
          /// Exception chưa map là unknown; không cho gửi intent mới hoặc in detail nhạy cảm.
          () {
            _callbackFailed = true;
          },
        );
    } finally {
      if (mounted)
        setState(
          /// Chỉ mở thao tác theo state host; callback exception vẫn giữ fence riêng tới generation mới.
          () {
            _working = false;
          },
        );
    }
  }

  /// Đối soát theo callback riêng; không giữ password hoặc gọi lại submit khi mạng phục hồi.
  Future<void> _recover() async {
    final currentState = _callbackFailed
        ? LoginViewState.pending
        : widget.state;
    if (_working || !currentState.canRecover || widget.onRecover == null)
      return;
    setState(
      /// Đối soát cũng chỉ có một intent đang chạy trong component này.
      () {
        _working = true;
      },
    );
    try {
      await widget.onRecover!();
    } catch (_) {
      if (mounted)
        setState(
          /// Giữ unknown tới khi host xác minh và tạo generation mới, không tự mở lại form.
          () {
            _callbackFailed = true;
          },
        );
    } finally {
      if (mounted)
        setState(
          /// Dừng spinner, không suy đối soát thành công từ việc Future đã kết thúc.
          () {
            _working = false;
          },
        );
    }
  }

  /// Chuyển focus qua password theo next của bàn phím, không submit email một mình.
  /// Input
  /// Param: value — text IME gửi kèm; controller vẫn là nguồn input hiện tại, không log value.
  void _nextField(String value) => _passwordFocus.requestFocus();

  /// Done của bàn phím dùng cùng fence với CTA, không tạo đường submit thứ hai.
  /// Input
  /// Param: value — password IME truyền kèm, không giữ hoặc dùng ngoài controller.
  void _doneField(String value) {
    unawaited(_submit());
  }

  /// Đổi cách hiển thị password trong RAM, không copy ra clipboard hoặc storage.
  void _togglePassword() => setState(
    /// Chỉ đổi obscureText, không làm mất selection hoặc chỉnh chuỗi password.
    () {
      _showPassword = !_showPassword;
    },
  );

  /// Ghi nhận ngón tay chạm CTA để chạy hiệu ứng nhấn; quyết định gửi vẫn do onPressed và fence của _submit.
  /// Input
  /// Param: event — sự kiện chạm của framework, không mang dữ liệu form.
  void _handleButtonPointerDown(PointerDownEvent event) =>
      _setButtonPressed(true);

  /// Trả CTA về kích thước gốc khi nhấc tay hoặc cử chỉ bị hủy (cuộn, hệ thống chen ngang).
  /// Input
  /// Param: event — sự kiện kết thúc chạm, không mang dữ liệu form.
  void _handleButtonPointerEnd(PointerEvent event) => _setButtonPressed(false);

  /// Cập nhật trạng thái nhấn khi thật sự thay đổi để tránh rebuild thừa trong lúc kéo ngón tay.
  /// Input
  /// Param: pressed — true khi ngón tay đang giữ trên CTA.
  void _setButtonPressed(bool pressed) {
    if (_buttonPressed == pressed) return;
    setState(
      /// Chỉ đổi tỉ lệ hiển thị của CTA, không chạm vào state nghiệp vụ.
      () {
        _buttonPressed = pressed;
      },
    );
  }

  /// Trả thời lượng chuyển động, hoặc 0 khi người dùng bật giảm chuyển động để mọi hiệu ứng tuân theo cài đặt trợ năng.
  /// Input
  /// Param: context — nguồn MediaQuery chứa tùy chọn giảm chuyển động.
  /// Param: milliseconds — thời lượng thiết kế khi chuyển động được phép.
  /// Output: Duration dùng cho widget implicit animation.
  Duration _motionDuration(BuildContext context, int milliseconds) =>
      nexaMotionDuration(context, milliseconds);

  /// Dựng screen auth nghiệp vụ với nền aurora, app bar trong suốt và vùng cuộn phù hợp keyboard/safe area.
  /// Input
  /// Param: context — theme/layout hiện tại, không nguồn dữ liệu phiên.
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: _buildScreen);

  /// Ưu tiên form khi parent và IME còn quá ít chiều cao; header trở lại khi đóng keyboard.
  /// Input
  /// Param: context — theme và inset keyboard hiện hành, không thay text scale hoặc native metrics.
  /// Param: constraints — vùng host thực còn lại sau banner/safe area.
  /// Output: giữ thiết kế Nexa/animation; chỉ ẩn tạm app bar khi nó che target thao tác.
  Widget _buildScreen(BuildContext context, BoxConstraints constraints) {
    // 190dp = header72 + CTA chữ2×70 + gutter48; giữ chữ/target, nhường chỗ bằng cách ẩn header.
    final showHeader =
        constraints.maxHeight - MediaQuery.viewInsetsOf(context).bottom >= 190;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Nền nằm sau cả Scaffold để AppBar trong suốt không tạo vệt cắt ngang các đốm sáng ở mép trên.
        const Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(child: NexaAuroraBackdrop()),
          ),
        ),
        Scaffold(
          backgroundColor: Colors.transparent,
          appBar: showHeader
              ? AppBar(
                  toolbarHeight: 72,
                  backgroundColor: Colors.transparent,
                  surfaceTintColor: Colors.transparent,
                  scrolledUnderElevation: 0,
                  elevation: 0,
                  title: const NexaBrand(),
                  actions: [
                    if (widget.onToggleTheme != null)
                      NexaThemeToggleButton(onPressed: widget.onToggleTheme!),
                    const SizedBox(width: 12),
                  ],
                )
              : null,
          body: SafeArea(child: LayoutBuilder(builder: _buildLayout)),
        ),
      ],
    );
  }

  /// Giới hạn form 480dp, thêm hero ở cột trái trên màn rộng; màn hẹp/keyboard thì cuộn thay vì khóa orientation.
  /// Input
  /// Param: context — theme và text scale hiện hành.
  /// Param: constraints — vùng body thực sau system bars/keyboard.
  Widget _buildLayout(BuildContext context, BoxConstraints constraints) {
    final isWide = constraints.maxWidth >= _wideLayoutMinWidth;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: constraints.maxHeight > 48
              ? constraints.maxHeight - 48
              : 0,
        ),
        child: Center(
          child: TweenAnimationBuilder<double>(
            // Hiệu ứng vào màn chạy một lần rồi dừng; không lặp vô hạn để tiết kiệm pin và không chặn pumpAndSettle.
            tween: Tween<double>(begin: 0, end: 1),
            duration: _motionDuration(context, 560),
            curve: Curves.easeOutCubic,
            builder: _buildEntrance,
            child: isWide
                ? ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1120),
                    child: Row(
                      children: [
                        Expanded(child: _buildHeroPanel(context)),
                        const SizedBox(width: 64),
                        SizedBox(width: 460, child: _buildFormCard(context)),
                      ],
                    ),
                  )
                : ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: _buildFormCard(context),
                  ),
          ),
        ),
      ),
    );
  }

  /// Hiệu ứng vào màn: mờ dần và trượt lên 24dp như reveal trên trang chủ Web.
  /// Input
  /// Param: context — ngữ cảnh build của TweenAnimationBuilder.
  /// Param: progress — tiến độ 0→1 sau curve.
  /// Param: child — nội dung tĩnh được tái sử dụng giữa các frame.
  /// Output: nội dung đã áp opacity và dịch chuyển.
  Widget _buildEntrance(BuildContext context, double progress, Widget? child) =>
      Opacity(
        opacity: progress,
        // Giữ semantics ngay frame đầu để TalkBack không mất nhãn form khi hiệu ứng chưa chạy xong.
        alwaysIncludeSemantics: true,
        child: Transform.translate(
          offset: Offset(0, 24 * (1 - progress)),
          child: child,
        ),
      );

  /// Cột giới thiệu cho màn rộng, nối mạch thị giác với hero trang chủ; không chứa thao tác hay dữ liệu account.
  /// Input
  /// Param: context — theme hiện tại.
  Widget _buildHeroPanel(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tokens = NexaAuthTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: colors.surface.withValues(alpha: .7),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: tokens.line),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ExcludeSemantics(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: nexaActionGradient,
                    shape: BoxShape.circle,
                  ),
                  child: SizedBox(width: 8, height: 8),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  'Nền tảng IoT cho workspace',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        NexaGradientHeading(
          text: 'Vận hành thiết bị IoT\ncủa bạn trong một nơi.',
          style: theme.textTheme.displaySmall,
        ),
        const SizedBox(height: 16),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Text(
            'Giám sát, điều khiển và tự động hóa thiết bị với phân quyền rõ ràng cho từng nhóm làm việc.',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 32),
        for (final (icon, title, description) in _heroFeatures)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: tokens.line),
                      boxShadow: tokens.shadow,
                    ),
                    child: Icon(icon, color: colors.primary, size: 22),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleSmall),
                      const SizedBox(height: 2),
                      Text(description, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// Thẻ form chính: gradient surface, viền mảnh, vạch thương hiệu; mọi control giữ key/fence như trước.
  /// Input
  /// Param: context — theme, text scale và tùy chọn giảm chuyển động hiện hành.
  Widget _buildFormCard(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tokens = NexaAuthTokens.of(context);
    final state = _callbackFailed ? LoginViewState.pending : widget.state;
    final canSubmit = state.canSubmit && !_working;
    final busy = _working || state == LoginViewState.submitting;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return NexaSurfaceCard(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
      child: AutofillGroup(
        // Preview/failed generation không tự yêu cầu password manager lưu credential khi rời màn.
        // API: https://api.flutter.dev/flutter/widgets/AutofillGroup-class.html
        onDisposeAction: AutofillContextAction.cancel,
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildFormHeader(context),
              const SizedBox(height: 28),
              AnimatedSwitcher(
                duration: _motionDuration(context, 280),
                transitionBuilder: _fadeSizeTransition,
                layoutBuilder: _stretchLayout,
                child: state != LoginViewState.ready
                    ? _buildNotice(context, state)
                    : const SizedBox.shrink(
                        key: ValueKey('auth-notice-empty'),
                      ),
              ),
              AnimatedSwitcher(
                duration: _motionDuration(context, 220),
                transitionBuilder: _fadeSizeTransition,
                layoutBuilder: _stretchLayout,
                child: _validationFailed
                    ? _buildValidationSummary(context)
                    : const SizedBox.shrink(
                        key: ValueKey('auth-validation-empty'),
                      ),
              ),
              TextFormField(
                key: const ValueKey('auth-email'),
                controller: _email,
                focusNode: _emailFocus,
                enabled: canSubmit,
                validator: _validateEmail,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.username],
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  hintText: 'ten@congty.vn',
                  prefixIcon: Icon(Icons.mail_outline_rounded),
                ),
                onFieldSubmitted: _nextField,
              ),
              const SizedBox(height: 18),
              TextFormField(
                key: const ValueKey('auth-password'),
                controller: _password,
                focusNode: _passwordFocus,
                enabled: canSubmit,
                validator: _validatePassword,
                obscureText: !_showPassword,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.visiblePassword,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.password],
                onFieldSubmitted: _doneField,
                decoration: InputDecoration(
                  labelText: 'Mật khẩu',
                  prefixIcon: const Icon(Icons.lock_outline_rounded),
                  suffixIcon: IconButton(
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    tooltip: _showPassword
                        ? 'Ẩn mật khẩu'
                        : 'Hiện mật khẩu',
                    onPressed: canSubmit ? _togglePassword : null,
                    icon: AnimatedSwitcher(
                      duration: _motionDuration(context, 180),
                      child: Icon(
                        _showPassword
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        key: ValueKey<bool>(_showPassword),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 28),
              AnimatedScale(
                // Thu nhỏ 2% khi nhấn như .btn:active của Web để phản hồi xúc giác tức thì.
                scale: _buttonPressed && canSubmit ? .98 : 1,
                duration: _motionDuration(context, 120),
                child: AnimatedContainer(
                  duration: _motionDuration(context, 260),
                  curve: Curves.easeOut,
                  decoration: BoxDecoration(
                    gradient: canSubmit ? nexaActionGradient : null,
                    borderRadius: BorderRadius.circular(100),
                    boxShadow: canSubmit ? tokens.glow : const [],
                  ),
                  child: Listener(
                    onPointerDown: _handleButtonPointerDown,
                    onPointerUp: _handleButtonPointerEnd,
                    onPointerCancel: _handleButtonPointerEnd,
                    child: FilledButton(
                      key: const ValueKey('auth-submit'),
                      onPressed: canSubmit ? _submit : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        foregroundColor: nexaActionInk,
                        overlayColor: nexaActionInk,
                        shape: const StadiumBorder(),
                        textStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          letterSpacing: .2,
                        ),
                        minimumSize: const Size.fromHeight(56),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 16,
                        ),
                      ),
                      child: AnimatedSwitcher(
                        duration: _motionDuration(context, 200),
                        child: Wrap(
                          key: ValueKey<bool>(busy),
                          alignment: WrapAlignment.center,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 10,
                          children: [
                            if (busy)
                              ExcludeSemantics(
                                child: SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: reducedMotion
                                      ? const Icon(
                                          Icons.hourglass_empty,
                                          size: 18,
                                        )
                                      : const CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                ),
                              ),
                            Text(busy ? 'Đang xử lý…' : 'Đăng nhập'),
                            if (!busy)
                              const ExcludeSemantics(
                                child: Icon(
                                  Icons.arrow_forward_rounded,
                                  size: 20,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (state.canRecover && widget.onRecover != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: OutlinedButton(
                    key: const ValueKey('auth-recover'),
                    onPressed: busy ? null : _recover,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    child: const Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      children: [
                        ExcludeSemantics(
                          child: Icon(Icons.sync_rounded, size: 18),
                        ),
                        Text('Kiểm tra trạng thái'),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              Divider(height: 1, color: tokens.line),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ExcludeSemantics(
                    child: Icon(
                      Icons.support_agent_outlined,
                      size: 18,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Cần hỗ trợ? Liên hệ quản trị viên của bạn.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Phần đầu thẻ: huy hiệu khóa gradient kèm eyebrow NEXA WORKSPACE, tiêu đề gradient và mô tả ngắn.
  /// Input
  /// Param: context — theme hiện tại.
  Widget _buildFormHeader(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = NexaAuthTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
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
                  Icons.lock_outline_rounded,
                  color: nexaActionInk,
                  size: 24,
                ),
              ),
            ),
            const SizedBox(width: 14),
            const Expanded(child: NexaEyebrow()),
          ],
        ),
        const SizedBox(height: 20),
        NexaGradientHeading(
          text: 'Đăng nhập',
          style: theme.textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        const Text('Truy cập workspace của bạn.'),
      ],
    );
  }

  /// Mờ và mở rộng theo chiều dọc khi notice/summary xuất hiện, tránh form bị giật vị trí đột ngột.
  /// Input
  /// Param: child — notice mới hoặc cũ do AnimatedSwitcher cung cấp.
  /// Param: animation — tiến độ vào/ra.
  /// Output: child đã gắn fade + size transition.
  Widget _fadeSizeTransition(Widget child, Animation<double> animation) =>
      FadeTransition(
        opacity: animation,
        // Live region phải có trong cây semantics ngay khi xuất hiện, không chờ opacity lớn hơn 0.
        alwaysIncludeSemantics: true,
        child: SizeTransition(
          sizeFactor: CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          ),
          // Neo mép trên để notice mở rộng xuống dưới, đẩy form nhẹ nhàng thay vì co giãn từ giữa.
          alignment: Alignment.topCenter,
          child: child,
        ),
      );

  /// Xếp notice cũ/mới chồng nhau nhưng vẫn kéo giãn hết bề ngang form, thay cho Stack mặc định co theo nội dung.
  /// Input
  /// Param: currentChild — notice đang hiển thị.
  /// Param: previousChildren — notice đang mờ dần.
  /// Output: Stack truyền nguyên ràng buộc ngang của Column cha.
  Widget _stretchLayout(Widget? currentChild, List<Widget> previousChildren) =>
      Stack(
        fit: StackFit.passthrough,
        alignment: Alignment.topCenter,
        children: [...previousChildren, ?currentChild],
      );

  /// Tóm tắt lỗi validate dạng banner coral có icon, song song lỗi tại từng trường.
  /// Input
  /// Param: context — semantic palette của theme.
  /// Output: banner nền lỗi nhẹ, chữ mực và icon coral; live region đọc cùng lỗi tại trường.
  Widget _buildValidationSummary(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      key: const ValueKey('auth-validation-summary'),
      padding: const EdgeInsets.only(bottom: 16),
      child: Semantics(
        liveRegion: true,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: colors.errorContainer,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: Color.lerp(colors.outlineVariant, colors.error, .32)!,
            ),
          ),
          child: Row(
            children: [
              ExcludeSemantics(
                child: Icon(
                  Icons.error_outline_rounded,
                  size: 20,
                  color: colors.error,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Kiểm tra các trường được đánh dấu bên dưới.',
                  style: TextStyle(
                    color: colors.onErrorContainer,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Notice có icon/text/live region; state chỉ điều khiển presentation, không mở protected route.
  /// Input
  /// Param: context — semantic palette của theme.
  /// Param: state — trạng thái cố định đã loại detail lỗi nhạy cảm.
  /// Output: banner có chữ, icon và màu theo nhóm lỗi/chờ/thành công để không chỉ dựa vào màu.
  Widget _buildNotice(BuildContext context, LoginViewState state) {
    final colors = Theme.of(context).colorScheme;
    final bad =
        state == LoginViewState.rejected ||
        state == LoginViewState.storageFailure ||
        state == LoginViewState.permissionDenied;
    final waiting =
        state == LoginViewState.pending ||
        state == LoginViewState.conflict ||
        state == LoginViewState.networkUnavailable;
    final foreground = bad
        ? colors.onErrorContainer
        : waiting
        ? colors.onTertiaryContainer
        : colors.onPrimaryContainer;
    final accent = bad ? colors.error : foreground;
    // Icon theo nhóm ngữ nghĩa giống bốn thẻ trạng thái trên Web: lỗi, chờ, đã xác minh, thông tin.
    final icon = bad
        ? Icons.error_outline_rounded
        : waiting
        ? Icons.schedule_rounded
        : state == LoginViewState.confirmed
        ? Icons.verified_outlined
        : Icons.info_outline_rounded;
    return Padding(
      key: ValueKey<LoginViewState>(state),
      padding: const EdgeInsets.only(bottom: 20),
      child: Semantics(
        liveRegion: true,
        child: Container(
          key: const ValueKey('auth-notice'),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: bad
                ? colors.errorContainer
                : waiting
                ? colors.tertiaryContainer
                : colors.primaryContainer,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: bad
                  ? Color.lerp(colors.outlineVariant, accent, .32)!
                  : foreground.withValues(alpha: .22),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: .12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: accent, size: 20),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      state.label,
                      style: TextStyle(
                        color: foreground,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(state.message, style: TextStyle(color: foreground)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
