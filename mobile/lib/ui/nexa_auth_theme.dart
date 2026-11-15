import 'dart:math' as math;

import 'package:flutter/material.dart';

// Token từ docs/UI web/home (2).html; màu CTA navy có contrast tối thiểu5.05:1 trên gradient.
const nexaActionGradient = LinearGradient(
  colors: [Color(0xFF14C9A6), Color(0xFF0E9F85), Color(0xFF1AA6D8)],
  stops: [0, .4, 1],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);
const nexaActionInk = Color(0xFF05221C);

/// Token thị giác phụ của trang chủ Web (surface-2, line, aurora, shadow, glow) mà ColorScheme không có vai trò tương ứng.
/// Tách thành ThemeExtension để widget auth đọc theo theme hiện hành và nội suy mượt khi đổi sáng/tối.
@immutable
class NexaAuthTokens extends ThemeExtension<NexaAuthTokens> {
  /// Tạo bộ token cố định cho một theme.
  /// Input
  /// Param: surfaceAlt — `--surface-2`, điểm cuối gradient của thẻ.
  /// Param: line — `--line`, viền mảnh của thẻ và đường chia.
  /// Param: headingEnd — `--teal-deep`, điểm cuối gradient tiêu đề.
  /// Param: auroraTeal — đốm sáng teal của nền, đã kèm alpha.
  /// Param: auroraSky — đốm sáng sky của nền, đã kèm alpha.
  /// Param: auroraIris — đốm sáng iris của nền, đã kèm alpha.
  /// Param: shadow — `--shadow`, bóng mềm của bề mặt nổi.
  /// Param: glow — ánh teal dưới nút chính và huy hiệu gradient.
  const NexaAuthTokens({
    required this.surfaceAlt,
    required this.line,
    required this.headingEnd,
    required this.auroraTeal,
    required this.auroraSky,
    required this.auroraIris,
    required this.shadow,
    required this.glow,
  });

  final Color surfaceAlt;
  final Color line;
  final Color headingEnd;
  final Color auroraTeal;
  final Color auroraSky;
  final Color auroraIris;
  final List<BoxShadow> shadow;
  final List<BoxShadow> glow;

  // Giá trị lấy từ :root của docs/UI web/home (2).html; alpha aurora (≈22%/16%/12%) giữ nền đủ nhạt cho chữ đạt contrast.
  static const light = NexaAuthTokens(
    surfaceAlt: Color(0xFFF7FBFA),
    line: Color(0xFFD8E5E3),
    headingEnd: Color(0xFF0A6F66),
    auroraTeal: Color(0x3814C9A6),
    auroraSky: Color(0x292F9BFF),
    auroraIris: Color(0x1F7C6CFF),
    shadow: [
      BoxShadow(color: Color(0x0D0C2233), offset: Offset(0, 1), blurRadius: 2),
      BoxShadow(
        color: Color(0x2E0C2233),
        offset: Offset(0, 12),
        blurRadius: 32,
        spreadRadius: -12,
      ),
    ],
    glow: [
      BoxShadow(
        color: Color(0x7314C9A6),
        offset: Offset(0, 14),
        blurRadius: 32,
        spreadRadius: -12,
      ),
    ],
  );

  // Giá trị lấy từ [data-theme="dark"] của trang chủ; bóng đậm hơn vì nền tối hấp thụ độ tương phản của bóng.
  static const dark = NexaAuthTokens(
    surfaceAlt: Color(0xFF122A3A),
    line: Color(0xFF1E3A4B),
    headingEnd: Color(0xFF5BE3C6),
    auroraTeal: Color(0x2E2DD4B0),
    auroraSky: Color(0x245BB4FF),
    auroraIris: Color(0x249A8CFF),
    shadow: [
      BoxShadow(color: Color(0x66000000), offset: Offset(0, 1), blurRadius: 2),
      BoxShadow(
        color: Color(0x99000000),
        offset: Offset(0, 16),
        blurRadius: 36,
        spreadRadius: -14,
      ),
    ],
    glow: [
      BoxShadow(
        color: Color(0x592DD4B0),
        offset: Offset(0, 14),
        blurRadius: 32,
        spreadRadius: -12,
      ),
    ],
  );

  /// Đọc token của theme hiện hành; theme không đăng ký extension vẫn có bộ mặc định theo độ sáng thay vì lỗi null.
  /// Input
  /// Param: context — vị trí widget dùng để tra Theme gần nhất.
  /// Output: bộ token tương ứng theme sáng/tối.
  static NexaAuthTokens of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<NexaAuthTokens>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  /// Tạo bản sao thay một phần token, theo hợp đồng ThemeExtension của Flutter.
  /// Input
  /// Param: surfaceAlt — bề mặt phụ mới, null giữ giá trị cũ.
  /// Param: line — màu viền mới, null giữ giá trị cũ.
  /// Param: headingEnd — điểm cuối gradient tiêu đề mới, null giữ giá trị cũ.
  /// Param: auroraTeal — đốm teal mới, null giữ giá trị cũ.
  /// Param: auroraSky — đốm sky mới, null giữ giá trị cũ.
  /// Param: auroraIris — đốm iris mới, null giữ giá trị cũ.
  /// Param: shadow — bóng bề mặt mới, null giữ giá trị cũ.
  /// Param: glow — ánh nút chính mới, null giữ giá trị cũ.
  /// Output: bộ token mới, không thay đổi bản gốc.
  @override
  NexaAuthTokens copyWith({
    Color? surfaceAlt,
    Color? line,
    Color? headingEnd,
    Color? auroraTeal,
    Color? auroraSky,
    Color? auroraIris,
    List<BoxShadow>? shadow,
    List<BoxShadow>? glow,
  }) => NexaAuthTokens(
    surfaceAlt: surfaceAlt ?? this.surfaceAlt,
    line: line ?? this.line,
    headingEnd: headingEnd ?? this.headingEnd,
    auroraTeal: auroraTeal ?? this.auroraTeal,
    auroraSky: auroraSky ?? this.auroraSky,
    auroraIris: auroraIris ?? this.auroraIris,
    shadow: shadow ?? this.shadow,
    glow: glow ?? this.glow,
  );

  /// Nội suy token khi MaterialApp chuyển theme để nền, viền và bóng đổi màu mượt thay vì nhảy cứng.
  /// Input
  /// Param: other — token của theme đích; khác kiểu thì giữ nguyên token hiện tại.
  /// Param: t — tiến độ chuyển cảnh từ 0 đến 1.
  /// Output: token trung gian tại thời điểm t.
  @override
  NexaAuthTokens lerp(ThemeExtension<NexaAuthTokens>? other, double t) {
    if (other is! NexaAuthTokens) return this;
    return NexaAuthTokens(
      surfaceAlt: Color.lerp(surfaceAlt, other.surfaceAlt, t)!,
      line: Color.lerp(line, other.line, t)!,
      headingEnd: Color.lerp(headingEnd, other.headingEnd, t)!,
      auroraTeal: Color.lerp(auroraTeal, other.auroraTeal, t)!,
      auroraSky: Color.lerp(auroraSky, other.auroraSky, t)!,
      auroraIris: Color.lerp(auroraIris, other.auroraIris, t)!,
      shadow: BoxShadow.lerpList(shadow, other.shadow, t)!,
      glow: BoxShadow.lerpList(glow, other.glow, t)!,
    );
  }
}

/// Màu icon trong ô nhập theo trạng thái để người dùng nhận ra ô đang focus hoặc lỗi mà không chỉ dựa vào viền.
/// Input
/// Param: scheme — bảng màu Material đã ánh xạ token Nexa.
/// Output: màu phụ thuộc trạng thái cho prefix/suffix icon.
WidgetStateColor _fieldIconColor(ColorScheme scheme) =>
    WidgetStateColor.resolveWith(
      /// Ưu tiên disabled rồi lỗi trước focus để lỗi vẫn nổi bật khi người dùng quay lại sửa ô.
      (states) {
        if (states.contains(WidgetState.disabled)) {
          return scheme.onSurface.withValues(alpha: .38);
        }
        if (states.contains(WidgetState.error)) return scheme.error;
        if (states.contains(WidgetState.focused)) return scheme.primary;
        return scheme.onSurfaceVariant;
      },
    );

/// Kiểu nhãn nổi của ô nhập: đổi màu theo focus/lỗi để vị trí nhập hiện tại luôn rõ ràng.
/// Input
/// Param: scheme — bảng màu Material đã ánh xạ token Nexa.
/// Output: text style phụ thuộc trạng thái cho floating label.
WidgetStateTextStyle _floatingLabelStyle(ColorScheme scheme) =>
    WidgetStateTextStyle.resolveWith(
      /// Nhãn đậm hơn khi focus để mắt bắt được ô đang nhập trên màn nhỏ.
      (states) => TextStyle(
        color: states.contains(WidgetState.error)
            ? scheme.error
            : states.contains(WidgetState.focused)
            ? scheme.primary
            : scheme.onSurfaceVariant,
        fontWeight: states.contains(WidgetState.focused)
            ? FontWeight.w600
            : FontWeight.w500,
      ),
    );

/// Ánh xạ token Nexa sang Material để form sáng/tối giữ cùng vai trò với trang chủ.
/// Input
/// Param: brightness — theme host chọn, không lưu lựa chọn vào storage của auth.
/// Output: theme Android với font hệ thống dự phòng; không tải font/package qua mạng.
ThemeData nexaAuthTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final ink = Color(dark ? 0xFFE7F2F1 : 0xFF0C2233);
  final surface = Color(dark ? 0xFF0F2331 : 0xFFFFFFFF);
  // Đồng bộ Web: nền chỉ pha 8% coral, accent pha 25% mực để sáng/tối đều dễ đọc.
  const coral = Color(0xFFE5533F);
  final errorAccent = Color.lerp(coral, ink, .25)!;
  final errorSurface = Color.lerp(surface, coral, .08)!;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF0E9F85),
        brightness: brightness,
      ).copyWith(
        primary: Color(dark ? 0xFF5BE3C6 : 0xFF0A6F66),
        onPrimary: dark ? const Color(0xFF05221C) : Colors.white,
        surface: surface,
        onSurface: ink,
        onSurfaceVariant: Color(dark ? 0xFF8FA8B5 : 0xFF566B7A),
        outline: Color(dark ? 0xFF8FA8B5 : 0xFF566B7A),
        outlineVariant: Color(dark ? 0xFF1E3A4B : 0xFFD8E5E3),
        error: errorAccent,
        errorContainer: errorSurface,
        onErrorContainer: ink,
        primaryContainer: Color(dark ? 0xFF0F3A3A : 0xFFD6F3EC),
        onPrimaryContainer: Color(dark ? 0xFF5BE3C6 : 0xFF0A6F66),
        tertiaryContainer: Color(dark ? 0xFF3A2B0E : 0xFFFFF0D2),
        onTertiaryContainer: Color(dark ? 0xFFF0A020 : 0xFF8A5A00),
      );
  final tokens = dark ? NexaAuthTokens.dark : NexaAuthTokens.light;
  final fieldRadius = BorderRadius.circular(16);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Color(dark ? 0xFF07141D : 0xFFF3F8F7),
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    extensions: [tokens],
    // Letter-spacing âm ≈ -0.025em như tiêu đề Web; font hệ thống được giữ vì app chưa đóng gói Bricolage/Be Vietnam Pro.
    textTheme: TextTheme(
      displaySmall: TextStyle(
        fontSize: 40,
        height: 1.08,
        letterSpacing: -1,
        fontWeight: FontWeight.w800,
        color: ink,
      ),
      headlineMedium: TextStyle(
        fontSize: 28,
        height: 1.15,
        letterSpacing: -.7,
        fontWeight: FontWeight.w700,
        color: ink,
      ),
      titleSmall: TextStyle(
        fontSize: 16,
        height: 1.35,
        fontWeight: FontWeight.w700,
        color: ink,
      ),
      bodyLarge: TextStyle(fontSize: 16, height: 1.5, color: ink),
      bodyMedium: TextStyle(
        fontSize: 16,
        height: 1.5,
        color: scheme.onSurfaceVariant,
      ),
      bodySmall: TextStyle(
        fontSize: 14,
        height: 1.5,
        color: scheme.onSurfaceVariant,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      // Dark dùng --bg-2 để ô nhập trông "lõm" vào thẻ; light giữ trắng nổi trên gradient surface → surface-2.
      fillColor: dark ? const Color(0xFF0B1E2B) : surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      prefixIconColor: _fieldIconColor(scheme),
      suffixIconColor: _fieldIconColor(scheme),
      floatingLabelStyle: _floatingLabelStyle(scheme),
      border: OutlineInputBorder(borderRadius: fieldRadius),
      // Viền outline (muted) thay vì --line để ranh giới ô nhập đạt tối thiểu 3:1 theo WCAG 1.4.11.
      enabledBorder: OutlineInputBorder(
        borderRadius: fieldRadius,
        borderSide: BorderSide(color: scheme.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: fieldRadius,
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: fieldRadius,
        borderSide: BorderSide(color: scheme.error, width: 1.5),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: fieldRadius,
        borderSide: BorderSide(color: scheme.error, width: 2),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: fieldRadius,
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      errorMaxLines: 3,
    ),
    // Nút phụ dạng viên thuốc viền 1.5dp theo .btn-ghost của trang chủ.
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: const StadiumBorder(),
        side: BorderSide(color: tokens.line, width: 1.5),
        foregroundColor: scheme.primary,
        backgroundColor: surface.withValues(alpha: .6),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      ),
    ),
  );
}

/// Trả về thời lượng chuyển động chuẩn hoặc Duration.zero khi người dùng bật giảm chuyển động.
/// Input
/// Param: context — ngữ cảnh chứa MediaQuery.disableAnimationsOf.
/// Param: milliseconds — thời lượng thiết kế (ms) khi cho phép chạy hiệu ứng.
/// Output: Duration dùng cho các widget animation để luôn tuân thủ trợ năng.
Duration nexaMotionDuration(BuildContext context, int milliseconds) =>
    MediaQuery.disableAnimationsOf(context)
    ? Duration.zero
    : Duration(milliseconds: milliseconds);

/// Nút chuyển đổi giao diện sáng/tối đồng bộ với .auth-theme-toggle trên Web.
class NexaThemeToggleButton extends StatelessWidget {
  /// Tạo nút đổi theme dùng chung cho AppBar và header các màn hình.
  /// Input
  /// Param: onPressed — callback đổi trạng thái sáng/tối ở host.
  const NexaThemeToggleButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  /// Xoay nhẹ và mờ dần icon mặt trời/mặt trăng khi đổi theme giống nút trên header Web.
  /// Input
  /// Param: child — icon mới hoặc cũ do AnimatedSwitcher cung cấp.
  /// Param: animation — tiến độ chuyển cảnh của icon.
  /// Output: widget icon đã gắn hiệu ứng xoay và mờ dần.
  Widget _buildTransition(Widget child, Animation<double> animation) =>
      RotationTransition(
        turns: Tween<double>(begin: .75, end: 1).animate(animation),
        child: FadeTransition(opacity: animation, child: child),
      );

  /// Dựng nút 48×48dp có viền mảnh, nền bán trong suốt và nhãn trợ năng theo trạng thái hiện tại.
  /// Input
  /// Param: context — theme hiện hành dùng để xác định chế độ sáng/tối.
  /// Output: IconButton chuẩn vùng chạm 48dp có key 'app-theme'.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final tokens = NexaAuthTokens.of(context);
    return IconButton(
      key: const ValueKey('app-theme'),
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      style: IconButton.styleFrom(
        backgroundColor: theme.colorScheme.surface.withValues(alpha: .82),
        side: BorderSide(color: tokens.line, width: 1.5),
      ),
      tooltip: isDark ? 'Dùng giao diện sáng' : 'Dùng giao diện tối',
      onPressed: onPressed,
      icon: AnimatedSwitcher(
        duration: nexaMotionDuration(context, 320),
        transitionBuilder: _buildTransition,
        child: Icon(
          isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
          key: ValueKey<bool>(isDark),
        ),
      ),
    );
  }
}

/// Nhãn eyebrow chữ in hoa kèm chấm tròn phát sáng theo .auth-eyebrow của trang Web.
class NexaEyebrow extends StatelessWidget {
  /// Tạo nhãn phụ nhận diện không gian làm việc Nexa.
  /// Input
  /// Param: text — nội dung nhãn chữ in hoa.
  /// Param: dotColor — màu chấm tròn tín hiệu, mặc định dùng màu primary của theme.
  const NexaEyebrow({
    super.key,
    this.text = 'NEXA WORKSPACE',
    this.dotColor,
  });

  final String text;
  final Color? dotColor;

  /// Vẽ chấm tròn có quầng sáng mờ và chữ khoảng cách rộng, tự co giãn khi chữ lớn.
  /// Input
  /// Param: context — theme cung cấp màu chữ phụ và màu nhấn.
  /// Output: hàng eyebrow trang trí đồng bộ với thiết kế Web.
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final activeDot = dotColor ?? scheme.primary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ExcludeSemantics(
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: activeDot,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: activeDot.withValues(alpha: .28),
                  spreadRadius: 3,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 11,
              height: 1.4,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w700,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// Tiêu đề phủ gradient mực → teal đậm như tiêu đề section và .auth-card h1 trên Web.
class NexaGradientHeading extends StatelessWidget {
  /// Tạo tiêu đề có ngữ nghĩa header và hiệu ứng chuyển màu thương hiệu.
  /// Input
  /// Param: text — nội dung tiêu đề.
  /// Param: style — kiểu chữ lấy từ textTheme; màu sẽ được phủ bởi ShaderMask.
  /// Param: liveRegion — đánh dấu liveRegion khi tiêu đề đóng vai trò thông báo trạng thái mới.
  const NexaGradientHeading({
    super.key,
    required this.text,
    required this.style,
    this.liveRegion = false,
  });

  final String text;
  final TextStyle? style;
  final bool liveRegion;

  /// Vẽ chữ trắng làm mặt nạ rồi phủ gradient theo theme hiện hành để giữ độ tương phản ở cả hai chế độ.
  /// Input
  /// Param: context — theme cung cấp màu onSurface và headingEnd.
  /// Output: widget tiêu đề có gắn Semantics(header: true).
  @override
  Widget build(BuildContext context) {
    final gradient = LinearGradient(
      colors: [
        Theme.of(context).colorScheme.onSurface,
        NexaAuthTokens.of(context).headingEnd,
      ],
    );
    return Semantics(
      header: true,
      liveRegion: liveRegion,
      child: ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: gradient.createShader,
        child: Text(text, style: style?.copyWith(color: Colors.white)),
      ),
    );
  }
}

/// Bề mặt thẻ kính chuẩn Nexa với nền gradient, viền mảnh, bóng mềm và vạch màu 4dp trên đỉnh.
class NexaSurfaceCard extends StatelessWidget {
  /// Tạo khung thẻ dùng chung cho Login, Đổi mật khẩu, Trạng thái phiên và Summary.
  /// Input
  /// Param: child — nội dung bên trong thẻ.
  /// Param: padding — khoảng đệm nội dung bên trong thẻ.
  /// Param: backgroundColor — màu nền tùy chỉnh khi thẻ mang ngữ nghĩa lỗi/cảnh báo.
  /// Param: borderColor — màu viền tùy chỉnh, mặc định dùng tokens.line.
  /// Param: accentColor — màu vạch đỉnh 4dp khi không dùng gradient thương hiệu mặc định.
  const NexaSurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(24, 26, 24, 24),
    this.backgroundColor,
    this.borderColor,
    this.accentColor,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? backgroundColor;
  final Color? borderColor;
  final Color? accentColor;

  /// Dựng thẻ bo góc 28dp kèm dải màu 4dp cắt khớp viền trong 27dp.
  /// Input
  /// Param: context — theme cung cấp màu surface, surfaceAlt, line và shadow.
  /// Output: thẻ hoàn chỉnh đồng bộ với .auth-card trên Web.
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tokens = NexaAuthTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: backgroundColor,
        gradient: backgroundColor == null
            ? LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [colors.surface, tokens.surfaceAlt],
              )
            : null,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: borderColor ?? tokens.line),
        boxShadow: tokens.shadow,
      ),
      child: ClipRRect(
        // Bo nhỏ hơn 1dp so với viền ngoài để vạch màu đỉnh không đè lên nét viền.
        borderRadius: BorderRadius.circular(27),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: accentColor,
                gradient: accentColor == null ? nexaActionGradient : null,
              ),
              child: const SizedBox(height: 4),
            ),
            Padding(padding: padding, child: child),
          ],
        ),
      ),
    );
  }
}

/// Nền aurora tĩnh kết hợp lưới chấm bi mờ (dot-grid) lấy cảm hứng từ hero và auth-page trên Web.
class NexaAuroraBackdrop extends StatelessWidget {
  /// Tạo lớp nền trang trí không giữ state hay dữ liệu phiên.
  const NexaAuroraBackdrop({super.key});

  /// Truyền màu nền và token theme hiện hành cho painter để chuyển màu mượt khi đổi sáng/tối.
  /// Input
  /// Param: context — theme hiện tại.
  /// Output: CustomPaint phủ toàn màn hình.
  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _NexaAuroraPainter(
      background: Theme.of(context).scaffoldBackgroundColor,
      tokens: NexaAuthTokens.of(context),
    ),
  );
}

/// Vẽ nền đặc, ba đốm sáng radial gradient và lưới chấm trang trí nhẹ, không cần đọc lại framebuffer.
class _NexaAuroraPainter extends CustomPainter {
  /// Khởi tạo painter với màu nền và bộ token sáng/tối.
  /// Input
  /// Param: background — màu nền trang (`--bg`).
  /// Param: tokens — bộ token chứa màu đốm sáng và màu đường kẻ.
  const _NexaAuroraPainter({required this.background, required this.tokens});

  final Color background;
  final NexaAuthTokens tokens;

  /// Vẽ nền, ba đốm sáng teal/sky/iris và lưới chấm bi mờ ở vùng trung tâm phía trên như .auth-page::before.
  /// Input
  /// Param: canvas — bề mặt vẽ của nền.
  /// Param: size — kích thước vùng nền hiện tại.
  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRect(bounds, Paint()..color = background);
    final extent = size.longestSide;
    // Teal trên-trái, sky trên-phải, iris dưới-giữa giống bố cục aurora trang chủ; đốm tràn mép để không lộ biên tròn.
    for (final (center, radius, color) in [
      (
        Offset(size.width * .05, size.height * .02),
        extent * .55,
        tokens.auroraTeal,
      ),
      (
        Offset(size.width * .98, size.height * .14),
        extent * .45,
        tokens.auroraSky,
      ),
      (
        Offset(size.width * .55, size.height * 1.02),
        extent * .6,
        tokens.auroraIris,
      ),
    ]) {
      final circle = Rect.fromCircle(center: center, radius: radius);
      canvas.drawRect(
        bounds,
        Paint()
          ..shader = RadialGradient(colors: [color, color.withValues(alpha: 0)])
              .createShader(circle),
      );
    }
    // Vẽ lưới chấm bi 26dp mờ dần về rìa như .hero::before / .auth-page::before để nối mạch thị giác với Web.
    const step = 26.0;
    final focusCenter = Offset(size.width * .5, size.height * .32);
    final maxDistance = extent * .48;
    if (maxDistance <= 0) return;
    final dotPaint = Paint()..style = PaintingStyle.fill;
    for (double y = step / 2; y < size.height * .72; y += step) {
      for (double x = step / 2; x < size.width; x += step) {
        final point = Offset(x, y);
        final ratio = (point - focusCenter).distance / maxDistance;
        if (ratio >= 1) continue;
        final fade = (1 - ratio) * (1 - ratio);
        dotPaint.color = tokens.line.withValues(alpha: .55 * fade);
        canvas.drawCircle(point, 1.15, dotPaint);
      }
    }
  }

  /// Chỉ vẽ lại khi màu nền hoặc bộ token thay đổi (khi chuyển chế độ sáng/tối).
  /// Input
  /// Param: oldDelegate — painter của frame trước đó.
  /// Output: true khi màu nền hoặc token khác trước.
  @override
  bool shouldRepaint(_NexaAuroraPainter oldDelegate) =>
      oldDelegate.background != background || oldDelegate.tokens != tokens;
}

/// Logo vector Nexa cùng radio mark34dp như Web; icon trang trí không lặp tên thương hiệu.
class NexaBrand extends StatelessWidget {
  /// Tạo brand dùng chung cho màn auth; không là nút điều hướng giả tới dashboard.
  const NexaBrand({super.key});

  /// Vẽ brand theo theme hiện tại và giữ chữ có thể co giãn với text scale của Android.
  /// Input
  /// Param: context — theme chứa màu chữ, không nguồn dữ liệu account.
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      ExcludeSemantics(
        child: Container(
          width: 34,
          height: 34,
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            gradient: nexaActionGradient,
            borderRadius: BorderRadius.circular(10),
          ),
          child: const CustomPaint(painter: _NexaRadioPainter()),
        ),
      ),
      const SizedBox(width: 10),
      const Flexible(
        child: Text(
          'Nexa IoT',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
      ),
    ],
  );
}

/// Dựng lại circle/arcs từ symbol i-radio của Web, không thêm dependency SVG.
class _NexaRadioPainter extends CustomPainter {
  /// Mark bất biến nên không giữ state hoặc cấp quyền qua logo.
  const _NexaRadioPainter();

  /// Vẽ nét1.8 trong hệ24×24 đúng sprite Web, độc lập mật độ pixel thiết bị.
  /// Input
  /// Param: canvas — bề mặt vector của logo.
  /// Param: size — kích thước layout cho phép, được chuẩn hóa về viewBox.
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final pen = Paint()
      ..color = nexaActionInk
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(const Offset(12, 12), 2, pen);
    for (final radius in [6.0, 10.0]) {
      final arc = Rect.fromCircle(center: const Offset(12, 12), radius: radius);
      canvas.drawArc(arc, -math.pi / 4, math.pi / 2, false, pen);
      canvas.drawArc(arc, math.pi * 3 / 4, math.pi / 2, false, pen);
    }
    canvas.restore();
  }

  /// Painter bất biến không cần redraw vì dữ liệu cũ không khác mark hiện tại.
  /// Input
  /// Param: oldDelegate — painter cùng loại của frame trước, không chứa state thay đổi.
  @override
  bool shouldRepaint(_NexaRadioPainter oldDelegate) => false;
}
