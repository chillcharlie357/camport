import 'package:flutter/material.dart';

abstract final class AppTheme {
  static const canvas = Color(0xFF111310);
  static const surface = Color(0xFF1B1E19);
  static const raisedSurface = Color(0xFF22261F);
  static const accent = Color(0xFFFFB454);
  static const text = Color(0xFFF2F0E9);
  static const mutedText = Color(0xFFB4B7AD);
  static const line = Color(0xFF393D35);

  static ThemeData get dark {
    const scheme = ColorScheme.dark(
      primary: accent,
      onPrimary: Color(0xFF241607),
      secondary: Color(0xFFC5C9BB),
      onSecondary: Color(0xFF20231D),
      surface: surface,
      onSurface: text,
      onSurfaceVariant: mutedText,
      outline: line,
      error: Color(0xFFFFB4A9),
      onError: Color(0xFF690005),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
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
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: line),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(160, 52),
          backgroundColor: accent,
          foregroundColor: const Color(0xFF241607),
          disabledBackgroundColor: const Color(0xFF34372F),
          disabledForegroundColor: const Color(0xFF92958C),
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
