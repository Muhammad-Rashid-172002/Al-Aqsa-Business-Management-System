import 'package:flutter/material.dart';

class AppColors {
  final Color bg;
  final Color surface;
  final Color surfaceHigh;
  final Color border;
  final Color primary;
  final Color accent;
  final Color text;
  final Color textMuted;
  final Color warning;
  final Color danger;
  final bool dark;

  const AppColors({
    required this.bg,
    required this.surface,
    required this.surfaceHigh,
    required this.border,
    required this.primary,
    required this.accent,
    required this.text,
    required this.textMuted,
    required this.warning,
    required this.danger,
    required this.dark,
  });

  static const darkPalette = AppColors(
    bg: Color(0xFF07110E),
    surface: Color(0xFF101C17),
    surfaceHigh: Color(0xFF16261F),
    border: Color(0xFF1F3329),
    primary: Color(0xFF087F5B),
    accent: Color(0xFF19C784),
    text: Color(0xFFF5F7F6),
    textMuted: Color(0xFF9AA8A1),
    warning: Color(0xFFE9A23B),
    danger: Color(0xFFE05252),
    dark: true,
  );

  static const lightPalette = AppColors(
    bg: Color(0xFFF3F6F4),
    surface: Color(0xFFFFFFFF),
    surfaceHigh: Color(0xFFF7FAF8),
    border: Color(0xFFDCE5E0),
    primary: Color(0xFF087F5B),
    accent: Color(0xFF0FA36B),
    text: Color(0xFF0E1A15),
    textMuted: Color(0xFF5E6E66),
    warning: Color(0xFFC9861F),
    danger: Color(0xFFCC3D3D),
    dark: false,
  );
}

class AppTheme extends ThemeExtension<AppTheme> {
  final AppColors c;
  const AppTheme(this.c);

  @override
  AppTheme copyWith({AppColors? c}) => AppTheme(c ?? this.c);

  @override
  AppTheme lerp(covariant AppTheme? other, double t) =>
      t < 0.5 ? this : (other ?? this);

  static AppColors of(BuildContext context) =>
      Theme.of(context).extension<AppTheme>()!.c;

  static ThemeData build(AppColors c) {
    final base =
        c.dark
            ? ThemeData.dark(useMaterial3: true)
            : ThemeData.light(useMaterial3: true);
    final scheme = ColorScheme.fromSeed(
      seedColor: c.primary,
      brightness: c.dark ? Brightness.dark : Brightness.light,
      primary: c.accent,
      surface: c.surface,
      error: c.danger,
    );
    final text = base.textTheme.apply(
      fontFamily: 'Segoe UI',
      bodyColor: c.text,
      displayColor: c.text,
    );
    OutlineInputBorder border(Color col) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: col),
    );
    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: c.bg,
      textTheme: text.copyWith(
        bodyMedium: text.bodyMedium?.copyWith(fontSize: 14),
        bodySmall: text.bodySmall?.copyWith(fontSize: 12.5, color: c.textMuted),
        titleLarge: text.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
      ),
      extensions: [AppTheme(c)],
      dividerColor: c.border,
      cardColor: c.surface,
      dialogTheme: DialogThemeData(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: c.border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surfaceHigh,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        border: border(c.border),
        enabledBorder: border(c.border),
        focusedBorder: border(c.accent),
        errorBorder: border(c.danger),
        labelStyle: TextStyle(color: c.textMuted),
        hintStyle: TextStyle(color: c.textMuted.withValues(alpha: 0.7)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: c.primary,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.text,
          side: BorderSide(color: c.border),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: c.surfaceHigh,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.border),
        ),
        textStyle: TextStyle(color: c.text, fontSize: 12),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: c.surfaceHigh,
        contentTextStyle: TextStyle(color: c.text),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(c.border),
        radius: const Radius.circular(8),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.macOS: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
        },
      ),
    );
  }
}
