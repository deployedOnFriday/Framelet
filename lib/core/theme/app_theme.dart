import 'package:flutter/material.dart';

abstract final class AppColors {
  static const background = Color(0xFFFFFFFF);
  static const sidebar = Color(0xFFF5F6F8);
  static const surface = Color(0xFFFFFFFF);
  static const primary = Color(0xFF2B65FF);
  static const primarySoft = Color(0xFFEDF2FF);
  static const accent = Color(0xFFD58E43);
  static const text = Color(0xFF253A34);
  static const muted = Color(0xFF7D837D);
  static const border = Color(0xFFE3E3DA);
  static const danger = Color(0xFFB4543E);
}

abstract final class AppTheme {
  static ThemeData get light {
    const scheme = ColorScheme.light(
      primary: AppColors.primary,
      onPrimary: Colors.white,
      secondary: AppColors.accent,
      onSecondary: Colors.white,
      surface: AppColors.surface,
      onSurface: AppColors.text,
      outline: AppColors.border,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.background,
      fontFamily: 'Microsoft YaHei UI',
      visualDensity: VisualDensity.standard,
      splashFactory: InkSparkle.splashFactory,
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
          fontSize: 30,
          fontWeight: FontWeight.w700,
          color: AppColors.text,
          letterSpacing: -0.5,
        ),
        headlineSmall: TextStyle(
          fontSize: 23,
          fontWeight: FontWeight.w700,
          color: AppColors.text,
        ),
        titleLarge: TextStyle(
          fontSize: 19,
          fontWeight: FontWeight.w600,
          color: AppColors.text,
        ),
        titleMedium: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: AppColors.text,
        ),
        bodyMedium: TextStyle(fontSize: 14, color: AppColors.text),
        bodySmall: TextStyle(fontSize: 12, color: AppColors.muted),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.text,
      ),
    );
  }
}
