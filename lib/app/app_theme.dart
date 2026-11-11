import 'package:flutter/material.dart';

abstract final class AppTheme {
  static const canvas = Color(0xFFF3F4F5);
  static const surface = Color(0xFFFFFFFF);
  static const raisedSurface = Color(0xFFE9ECEF);
  static const accent = Color(0xFF3C6489);
  static const text = Color(0xFF252A30);
  static const mutedText = Color(0xFF66717E);
  static const line = Color(0xFFD4D9DE);

  static ThemeData get light {
    const scheme = ColorScheme.light(
      primary: accent,
      onPrimary: Color(0xFFFFFFFF),
      secondary: Color(0xFF526170),
      onSecondary: Color(0xFFFFFFFF),
      surface: surface,
      onSurface: text,
      onSurfaceVariant: mutedText,
      outline: line,
      error: Color(0xFFB3261E),
      onError: Color(0xFFFFFFFF),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: canvas,
      dividerColor: line,
      textTheme: const TextTheme(
        displaySmall: TextStyle(
          color: text,
          fontSize: 48,
          height: 1.02,
          fontWeight: FontWeight.w600,
          letterSpacing: -1.8,
        ),
        headlineMedium: TextStyle(
          color: text,
          fontSize: 34,
          height: 1.08,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.8,
        ),
        titleLarge: TextStyle(
          color: text,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
        titleMedium: TextStyle(
          color: text,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: TextStyle(color: mutedText, fontSize: 16, height: 1.55),
        bodyMedium: TextStyle(color: mutedText, fontSize: 14, height: 1.45),
        labelLarge: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.1,
        ),
        labelSmall: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: canvas,
        foregroundColor: text,
        centerTitle: false,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: line),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(160, 52),
          backgroundColor: const Color(0xFF303841),
          foregroundColor: const Color(0xFFFFFFFF),
          disabledBackgroundColor: const Color(0xFFE0E4E8),
          disabledForegroundColor: const Color(0xFF66717E),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 15,
            letterSpacing: 0.1,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
      visualDensity: VisualDensity.standard,
    );
  }
}
