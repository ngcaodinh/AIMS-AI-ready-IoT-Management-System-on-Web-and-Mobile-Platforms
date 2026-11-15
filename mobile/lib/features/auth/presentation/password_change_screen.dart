import 'package:flutter/material.dart';

import '../../../ui/nexa_auth_theme.dart';
import '../../../core/validation/password_policy.dart';
import 'password_change_state.dart';

/// Màn nghiệp vụ dùng cho full/limited session; không gọi API/storage hoặc mở protected route.
class PasswordChangeScreen extends StatefulWidget {
  /// Nhận trạng thái đã đối soát từ host; tạo key mới sau account/session generation hoặc unknown reconciliation.
  /// Input
  /// Param: state — phase hiển thị; success chỉ sau server204 và host cleanup đúng policy.
  /// Param: onSubmit — đúng hai password nguyên bản; host giữ timeout/outcome và không lưu để retry.
  /// Param: onRecover — kiểm phiên/outcome riêng, không submit lại mutation.
  /// Param: onLeave — host logout/cleanup rồi về login, không cấp session từ UI.
  /// Param: onToggleTheme — đổi theme ở host, không đổi quyền hoặc session.
  /// Param: onBack — chỉ full host cấp đường quay lại picker bằng GET mới; null với limited.
  const PasswordChangeScreen({
    super.key,
    required this.state,
    required this.onSubmit,
    required this.onRecover,
    required this.onLeave,
    this.onToggleTheme,
    this.onBack,
  });

  final PasswordChangeState state;
  final Future<void> Function(String currentPassword, String newPassword)
  onSubmit;
  final Future<void> Function() onRecover;
  final Future<void> Function() onLeave;
  final VoidCallback? onToggleTheme;
  final VoidCallback? onBack;

  /// Tạo controller/focus chỉ sống cùng component, không giữ credential qua generation.
  @override
  State<PasswordChangeScreen> createState() => _PasswordChangeScreenState();
}

class _PasswordChangeScreenState extends State<PasswordChangeScreen> {
  final _formKey = GlobalKey<FormState>();
  final _inputs = List.generate(
    3,

    /// Mỗi field có controller riêng để xóa toàn bộ credential tại cùng boundary.
    (_) => TextEditingController(),
  );
  final _focusNodes = List.generate(
    3,

    /// Focus riêng cho current/new/confirm giúp chuyển lỗi đầu tiên và IME next đúng thứ tự.
    (_) => FocusNode(),
  );
  final _visible = [false, false, false];
  bool _working = false;
  bool _unknown = false;
  bool _invalid = false;

  /// Host đổi phase thì bỏ credential, không phục hồi từ state trước đó khi request bị từ chối.
  /// Input
  /// Param: oldWidget — phase cũ để phát hiện boundary thay đổi.
  @override
  void didUpdateWidget(PasswordChangeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      _clearInputs();
      // Lỗi validation của form cũ không được che thông báo outcome/loading mới từ host.
      _invalid = false;
    }
  }

  /// Xóa input và tắt reveal; không thể đảm bảo zero hóa mọi bản sao String trong RAM của Dart.
  void _clearInputs() {
    for (final input in _inputs) {
      input.clear();
    }
    for (var index = 0; index < _visible.length; index++) {
      _visible[index] = false;
    }
  }

  /// Giải phóng mọi controller/focus, không lưu password khi màn bị thay hoặc đóng.
  @override
  void dispose() {
    _clearInputs();
    for (final input in _inputs) {
      input.dispose();
    }
    for (final focus in _focusNodes) {
      focus.dispose();
    }
    super.dispose();
  }

  /// Ánh xạ field sang kiểm UX theo ChangePasswordRequest0.2.1, dùng Unicode codepoints và so nguyên chuỗi.
  /// Input
  /// Param: index — current0/new1/confirm2, chỉ từ layout nội bộ.
  /// Param: value — password người dùng nhập, không log/trim/cắt.
  /// Output: lỗi cố định tại field hoặc null; backend vẫn phải kiểm lại boundary thật.
  String? _validate(int index, String? value) {
    final text = value ?? '';
    if (index == 0)
      return validatePassword(text, PasswordPurpose.current)?.message;
    if (index == 1) {
      final error = validatePassword(text, PasswordPurpose.newPassword);
      if (error != null) return error.message;
      if (text == _inputs[0].text)
        return 'Mật khẩu mới phải khác mật khẩu hiện tại.';
      return null;
    }
    return text.isNotEmpty && text == _inputs[1].text
        ? null
        : 'Mật khẩu xác nhận chưa khớp.';
  }

  /// Gửi một mutation chủ động sau validation; controller được xóa trước callback, không tự retry.
  Future<void> _submit() async {
    if (_working || _unknown || !widget.state.canSubmit) return;
    if (!_formKey.currentState!.validate()) {
      setState(
        /// Summary live region giúp lỗi được nhận biết ngoài viền màu của field.
        () {
          _invalid = true;
        },
      );
      for (var index = 0; index < _inputs.length; index++) {
        if (_validate(index, _inputs[index].text) != null) {
          _focusNodes[index].requestFocus();
          break;
        }
      }
      return;
    }
    final currentPassword = _inputs[0].text;
    final newPassword = _inputs[1].text;
    _clearInputs();
    FocusScope.of(context).unfocus();
    await _runIntent(
      /// Callback chỉ nhận hai field wire; confirmation không rời presentation.
      () => widget.onSubmit(currentPassword, newPassword),
    );
  }

  /// Khóa mọi action cùng một boundary; exception giữ unknown tới khi host thay generation sau đối soát.
  /// Input
  /// Param: action — callback submit/recover/leave đã được kiểm admission trình bày.
  Future<void> _runIntent(Future<void> Function() action) async {
    if (_working) return;
    setState(
      /// Khóa ngay trước await để không cần chờ host rebuild mới ngăn intent thứ hai.
      () {
        _working = true;
        _invalid = false;
      },
    );
    try {
      await action();
    } catch (_) {
      if (mounted)
        setState(
          /// Không hiển thị lỗi thô có thể chứa credential; ACK recovery không tự bỏ fence này.
          () {
            _unknown = true;
          },
        );
    } finally {
      if (mounted)
        setState(
          /// Chỉ tháo cờ in-flight; phase host và unknown fence vẫn quyết định action được phép.
          () {
            _working = false;
          },
        );
    }
  }

  /// Đối soát riêng không mang credential và không lặp POST vừa mất kết quả.
  Future<void> _recover() async {
    final phase = _unknown ? PasswordChangeState.pending : widget.state;
    if (!_working && phase.canRecover) await _runIntent(widget.onRecover);
  }

  /// Chỉ cho thoát khi outcome rõ; host chịu logout/revoke và dọn token/cache trước route login.
  Future<void> _leave() async {
    if (!_working && !_unknown && widget.state.canLeave) {
      _clearInputs();
      await _runIntent(widget.onLeave);
    }
  }

  /// Dựng field có label/reveal/focus/IME; không autocorrect hoặc gợi ý credential.
  /// Input
  /// Param: index — vị trí current/new/confirm để chọn controller, autofill và validator.
  /// Param: label — tên field đọc được bằng semantics.
  /// Param: enabled — chỉ cho chỉnh khi host cho phép mutation mới.
  /// Output: field wrap theo text scale, không giới hạn password bằng UTF16 code units.
  Widget _field(int index, String label, bool enabled) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextFormField(
        key: ValueKey(
          ['password-current', 'password-new', 'password-confirm'][index],
        ),
        controller: _inputs[index],
        focusNode: _focusNodes[index],
        enabled: enabled,
        obscureText: !_visible[index],
        autocorrect: false,
        enableSuggestions: false,
        autofillHints: [
          index == 0 ? AutofillHints.password : AutofillHints.newPassword,
        ],
        textInputAction:
            index == 2 ? TextInputAction.done : TextInputAction.next,
        validator:
            /// Validator field lấy cùng policy được dùng để tìm field lỗi đầu tiên.
            (value) => _validate(index, value),
        onFieldSubmitted:
            /// IME done đi qua guard chung; next không gửi request ngoài ý muốn.
            (_) {
              if (index == 2) {
                _submit();
              } else {
                _focusNodes[index + 1].requestFocus();
              }
            },
        decoration: InputDecoration(
          isDense: true,
          labelText: label,
          errorMaxLines: 4,
          suffixIcon: IconButton(
            tooltip:
                '${_visible[index] ? 'Ẩn' : 'Hiện'} ${label.toLowerCase()}',
            onPressed: enabled
                ?
                  /// Reveal chỉ thay cách hiển thị, không thay text hoặc lưu credential.
                  () => setState(
                    /// Rebuild đúng field state sau thao tác chủ động của người dùng.
                    () {
                      _visible[index] = !_visible[index];
                    },
                  )
                : null,
            icon: Icon(
              _visible[index]
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
            ),
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          ),
        ),
      ),
    );
  }

  /// Phần đầu thẻ đổi mật khẩu: huy hiệu chìa khóa gradient và tiêu đề đồng bộ với .auth-card-heading trên Web.
  /// Input
  /// Param: context — theme hiện tại.
  /// Output: khối tiêu đề gọn gàng không chiếm chiều cao viewport bàn phím.
  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = NexaAuthTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            ExcludeSemantics(
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  gradient: nexaActionGradient,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: tokens.glow,
                ),
                child: const Icon(
                  Icons.key_rounded,
                  color: nexaActionInk,
                  size: 20,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: NexaGradientHeading(
                text: 'Đổi mật khẩu',
                style: theme.textTheme.headlineMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'Phiên giới hạn chỉ cho phép đổi mật khẩu hoặc đăng xuất. Sau khi đổi, hãy đăng nhập lại.',
        ),
      ],
    );
  }

  /// Banner thông báo trạng thái hoặc lỗi kiểm tra form với màu ngữ nghĩa và icon trực quan.
  /// Input
  /// Param: context — bảng màu semantic của theme hiện hành.
  /// Param: phase — trạng thái đổi mật khẩu hiện tại.
  /// Output: banner có liveRegion trợ năng và viền tương phản rõ.
  Widget _buildNotice(BuildContext context, PasswordChangeState phase) {
    final scheme = Theme.of(context).colorScheme;
    final isSuccess = !_invalid && phase == PasswordChangeState.success;
    final isError =
        _invalid ||
        phase == PasswordChangeState.rejected ||
        phase == PasswordChangeState.permissionDenied ||
        phase == PasswordChangeState.storageFailure;
    final background = isError
        ? scheme.errorContainer
        : isSuccess
        ? scheme.primaryContainer
        : scheme.tertiaryContainer;
    final foreground = isError
        ? scheme.onErrorContainer
        : isSuccess
        ? scheme.onPrimaryContainer
        : scheme.onTertiaryContainer;
    final accent = isError ? scheme.error : foreground;
    final icon = isError
        ? Icons.error_outline_rounded
        : isSuccess
        ? Icons.verified_outlined
        : Icons.schedule_rounded;
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isError
                  ? Color.lerp(scheme.outlineVariant, accent, .32)!
                  : foreground.withValues(alpha: .24),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(icon, color: accent, size: 18),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _invalid
                      ? 'Kiểm tra các trường được đánh dấu.'
                      : phase.message,
                  style: TextStyle(
                    color: foreground,
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

  /// Dựng màn nghiệp vụ một cột với nền aurora và thẻ kính Nexa, giữ token/brand cùng home/login.
  /// Input
  /// Param: context — theme, safe area và chế độ reduced-motion hiện hành.
  /// Output: form cuộn được hoặc trạng thái recovery/success, không protected content.
  @override
  Widget build(BuildContext context) {
    final phase = _unknown ? PasswordChangeState.pending : widget.state;
    final busy = _working || phase == PasswordChangeState.submitting;
    final canSubmit = !busy && phase.canSubmit;
    final scheme = Theme.of(context).colorScheme;
    final tokens = NexaAuthTokens.of(context);
    return PopScope(
      // Form full do host xử lý back; limited chỉ thoát native khi kết quả rõ, unknown vẫn khóa.
      canPop: widget.onBack == null && phase.canLeave && !busy && !_unknown,
      child: LayoutBuilder(
        /// Dùng chiều cao parent sau banner/safe area và IME để header không chiếm hết vùng thao tác.
        /// Input
        /// Param: layoutContext — context chứa keyboard inset hiện hành.
        /// Param: constraints — không gian thật host dành cho screen.
        /// Output: giữ header72dp khi còn đủ chỗ, ẩn tạm khi cần ưu tiên form/keyboard.
        builder: (layoutContext, constraints) {
          // 168dp = toolbar72 + một target48 + gutter hai phía48; không thu nhỏ chữ hoặc vùng chạm để giữ logo.
          final showHeader =
              constraints.maxHeight -
                  MediaQuery.viewInsetsOf(layoutContext).bottom >=
              168;
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
                appBar: showHeader
                    ? AppBar(
                        automaticallyImplyLeading: false,
                        backgroundColor: Colors.transparent,
                        surfaceTintColor: Colors.transparent,
                        scrolledUnderElevation: 0,
                        elevation: 0,
                        leading: widget.onBack == null
                            ? null
                            : Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: Center(
                                  child: IconButton(
                                    key: const ValueKey('app-back'),
                                    tooltip: 'Quay lại workspace',
                                    onPressed:
                                        !busy && !_unknown && phase.canLeave
                                        ? widget.onBack
                                        : null,
                                    constraints: const BoxConstraints(
                                      minWidth: 48,
                                      minHeight: 48,
                                    ),
                                    style: IconButton.styleFrom(
                                      backgroundColor: scheme.surface
                                          .withValues(alpha: .82),
                                      side: BorderSide(
                                        color: tokens.line,
                                        width: 1.5,
                                      ),
                                    ),
                                    icon: const Icon(Icons.arrow_back_rounded),
                                  ),
                                ),
                              ),
                        toolbarHeight: 72,
                        title: const NexaBrand(),
                        actions: [
                          if (widget.onToggleTheme != null)
                            NexaThemeToggleButton(
                              onPressed: widget.onToggleTheme!,
                            ),
                          const SizedBox(width: 12),
                        ],
                      )
                    : null,
                body: SafeArea(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 480),
                        child: NexaSurfaceCard(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildHeader(context),
                              const SizedBox(height: 18),
                              if (phase.message.isNotEmpty || _invalid)
                                _buildNotice(context, phase),
                              if (busy)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 16),
                                  child: MediaQuery.disableAnimationsOf(context)
                                      ? const Icon(
                                          Icons.hourglass_top,
                                          semanticLabel: 'Đang xử lý',
                                        )
                                      : ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                          child: const LinearProgressIndicator(
                                            minHeight: 5,
                                            semanticsLabel: 'Đang xử lý',
                                          ),
                                        ),
                                ),
                              if (phase.showsForm)
                                Form(
                                  key: _formKey,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      _field(
                                        0,
                                        'Mật khẩu hiện tại',
                                        canSubmit,
                                      ),
                                      _field(1, 'Mật khẩu mới', canSubmit),
                                      _field(
                                        2,
                                        'Xác nhận mật khẩu mới',
                                        canSubmit,
                                      ),
                                      const Text(newPasswordHint),
                                      const SizedBox(height: 18),
                                      DecoratedBox(
                                        decoration: BoxDecoration(
                                          gradient: canSubmit
                                              ? nexaActionGradient
                                              : null,
                                          borderRadius: BorderRadius.circular(
                                            100,
                                          ),
                                          boxShadow: canSubmit
                                              ? tokens.glow
                                              : const [],
                                        ),
                                        child: FilledButton(
                                          key: const ValueKey(
                                            'password-submit',
                                          ),
                                          onPressed: canSubmit
                                              ? _submit
                                              : null,
                                          style: FilledButton.styleFrom(
                                            backgroundColor:
                                                Colors.transparent,
                                            foregroundColor: nexaActionInk,
                                            overlayColor: nexaActionInk,
                                            shape: const StadiumBorder(),
                                            textStyle: const TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.w700,
                                              letterSpacing: .2,
                                            ),
                                            minimumSize:
                                                const Size.fromHeight(48),
                                            padding:
                                                const EdgeInsets.symmetric(
                                                  horizontal: 20,
                                                  vertical: 10,
                                                ),
                                          ),
                                          child: Text(
                                            busy
                                                ? 'Đang xử lý…'
                                                : 'Đổi mật khẩu',
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              if (phase.canRecover)
                                OutlinedButton(
                                  key: const ValueKey('password-recover'),
                                  onPressed: busy ? null : _recover,
                                  style: OutlinedButton.styleFrom(
                                    minimumSize: const Size.fromHeight(48),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 20,
                                      vertical: 10,
                                    ),
                                  ),
                                  child: const Text('Kiểm tra trạng thái'),
                                ),
                              if (phase.canLeave)
                                Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: TextButton(
                                    key: const ValueKey('password-leave'),
                                    onPressed: busy ? null : _leave,
                                    style: TextButton.styleFrom(
                                      minimumSize: const Size.fromHeight(48),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 20,
                                        vertical: 10,
                                      ),
                                      foregroundColor:
                                          phase == PasswordChangeState.success
                                          ? scheme.primary
                                          : scheme.onSurfaceVariant,
                                      textStyle: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    child: Text(
                                      phase == PasswordChangeState.success
                                          ? 'Đăng nhập lại'
                                          : 'Đăng xuất',
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
