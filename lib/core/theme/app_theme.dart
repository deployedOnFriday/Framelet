import 'package:flutter/material.dart';

/// 拾帧的语义化调色板：一组字段、浅深两套取值。
///
/// 组件里不要直接写死颜色，统一通过 `context.colors.xxx` 取色，
/// 这样切换主题时整树重建即可自动换肤。
class AppColors {
  const AppColors({
    required this.background,
    required this.sidebar,
    required this.surface,
    required this.primary,
    required this.primarySoft,
    required this.accent,
    required this.text,
    required this.muted,
    required this.border,
    required this.danger,
    required this.hover,
    required this.iconMuted,
    required this.iconHover,
    required this.success,
  });

  /// 页面底色
  final Color background;

  /// 侧栏底色
  final Color sidebar;

  /// 卡片/浮层底色
  final Color surface;

  /// 品牌主色
  final Color primary;

  /// 主色的浅底衬（选中态、提示条）
  final Color primarySoft;

  /// 点缀色（评分、强调）
  final Color accent;

  /// 正文色
  final Color text;

  /// 次要文字
  final Color muted;

  /// 描边/分隔线
  final Color border;

  /// 危险/错误
  final Color danger;

  /// 悬停底色
  final Color hover;

  /// 次要图标
  final Color iconMuted;

  /// 悬停图标
  final Color iconHover;

  /// 成功/已连接
  final Color success;

  /// 晨光极简（浅色）
  static const light = AppColors(
    background: Color(0xFFFFFFFF),
    sidebar: Color(0xFFF5F6F8),
    surface: Color(0xFFFFFFFF),
    primary: Color(0xFF2B65FF),
    primarySoft: Color(0xFFEDF2FF),
    accent: Color(0xFFD58E43),
    text: Color(0xFF253A34),
    muted: Color(0xFF7D837D),
    border: Color(0xFFE3E3DA),
    danger: Color(0xFFB4543E),
    hover: Color(0xFFF1F5F9),
    iconMuted: Color(0xFF94A3B8),
    iconHover: Color(0xFF475569),
    success: Color(0xFF4F8C68),
  );

  /// 暮色极简（深色）：延续浅色版的暖灰骨架，主色提亮保证对比度
  static const dark = AppColors(
    background: Color(0xFF15171A),
    sidebar: Color(0xFF1B1E22),
    surface: Color(0xFF1F2328),
    primary: Color(0xFF5B8CFF),
    primarySoft: Color(0xFF25304A),
    accent: Color(0xFFD58E43),
    text: Color(0xFFE7E9E4),
    muted: Color(0xFF8B9189),
    border: Color(0xFF32373C),
    danger: Color(0xFFD97E66),
    hover: Color(0xFF272C33),
    iconMuted: Color(0xFF6E7680),
    iconHover: Color(0xFFB9C0C9),
    success: Color(0xFF63A87F),
  );

  static AppColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

/// 取色入口：`context.colors.primary`
extension AppColorsExtension on BuildContext {
  AppColors get colors => AppColors.of(this);
}

abstract final class AppTheme {
  static ThemeData get light => _build(Brightness.light);

  static ThemeData get dark => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final colors = brightness == Brightness.dark
        ? AppColors.dark
        : AppColors.light;
    final scheme = brightness == Brightness.dark
        ? ColorScheme.dark(
            primary: colors.primary,
            onPrimary: Colors.white,
            secondary: colors.accent,
            onSecondary: Colors.white,
            surface: colors.surface,
            onSurface: colors.text,
            outline: colors.border,
          )
        : ColorScheme.light(
            primary: colors.primary,
            onPrimary: Colors.white,
            secondary: colors.accent,
            onSecondary: Colors.white,
            surface: colors.surface,
            onSurface: colors.text,
            outline: colors.border,
          );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: colors.background,
      fontFamily: 'Microsoft YaHei UI',
      visualDensity: VisualDensity.standard,
      // 页面转场用轻量 fade+上滑：桌面默认的 Zoom 转场带 3D 变换
      // shader 群，Skia 下首次触发要现场编译（实测最大 1.3s 尖峰）。
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.macOS: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
        },
      ),
      // InkSparkle 的 sparkle shader 首次点击也要现场编译，桌面端
      // 换传统 InkRipple：反馈仍清晰，shader 面积小得多。
      splashFactory: InkRipple.splashFactory,
      // 水波纹统一用品牌色，避免 M3 默认色在暗色下泛出杂色
      splashColor: colors.primary.withValues(alpha: 0.10),
      highlightColor: colors.primary.withValues(alpha: 0.06),
      textTheme: TextTheme(
        headlineLarge: TextStyle(
          fontSize: 30,
          fontWeight: FontWeight.w700,
          color: colors.text,
          letterSpacing: -0.5,
        ),
        headlineSmall: TextStyle(
          fontSize: 23,
          fontWeight: FontWeight.w700,
          color: colors.text,
        ),
        titleLarge: TextStyle(
          fontSize: 19,
          fontWeight: FontWeight.w600,
          color: colors.text,
        ),
        titleMedium: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: colors.text,
        ),
        bodyMedium: TextStyle(fontSize: 14, color: colors.text),
        bodySmall: TextStyle(fontSize: 12, color: colors.muted),
      ),
      scrollbarTheme: ScrollbarThemeData(
        // 桌面端：平时收起，悬浮到滚动区边缘时显现
        thumbVisibility: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered),
        ),
        thickness: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered) ? 8 : 5,
        ),
        radius: const Radius.circular(4),
        crossAxisMargin: 3,
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered)
              ? const Color(0xFF94A3B8).withValues(alpha: 0.75)
              : const Color(0xFF94A3B8).withValues(alpha: 0.45),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: colors.text,
      ),
      dividerTheme: DividerThemeData(
        color: colors.border,
        thickness: 1,
        space: 1,
      ),
      dialogTheme: DialogThemeData(backgroundColor: colors.surface),
      popupMenuTheme: PopupMenuThemeData(
        color: colors.surface,
        textStyle: TextStyle(color: colors.text, fontSize: 13.5),
      ),
    );
  }
}
