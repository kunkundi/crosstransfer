// CrossTransfer visual system.
//
// Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

const _brand = Color(0xFF4169E1);

bool isDesktopPlatform(TargetPlatform platform) => switch (platform) {
  TargetPlatform.macOS ||
  TargetPlatform.windows ||
  TargetPlatform.linux => true,
  _ => false,
};

bool isDesktopTheme(BuildContext context) =>
    isDesktopPlatform(Theme.of(context).platform);

bool isCompactDesktop(BuildContext context) =>
    isDesktopTheme(context) && MediaQuery.sizeOf(context).width < 340;

ThemeData buildAppTheme(Brightness brightness, {TargetPlatform? platform}) {
  platform ??= defaultTargetPlatform;
  if (isDesktopPlatform(platform)) return _desktopTheme(brightness, platform);
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: _brand, brightness: brightness)
      .copyWith(
        surface: dark ? const Color(0xFF111318) : const Color(0xFFF8F9FD),
        surfaceContainerLowest: dark
            ? const Color(0xFF0D0F13)
            : const Color(0xFFFFFFFF),
        surfaceContainerLow: dark
            ? const Color(0xFF181B21)
            : const Color(0xFFFFFFFF),
        surfaceContainer: dark
            ? const Color(0xFF1D2027)
            : const Color(0xFFF1F3F9),
      );
  final outline = scheme.outlineVariant.withValues(alpha: dark ? 0.62 : 0.72);
  final rounded = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(12),
  );

  return ThemeData(
    platform: platform,
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    splashFactory: InkSparkle.splashFactory,
    textTheme: Typography.material2021(platform: defaultTargetPlatform).black
        .apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface)
        .copyWith(
          headlineSmall: const TextStyle(
            fontSize: 25,
            height: 1.2,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.45,
          ),
          titleLarge: const TextStyle(
            fontSize: 19,
            height: 1.25,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
          ),
          titleMedium: const TextStyle(
            fontSize: 16,
            height: 1.35,
            fontWeight: FontWeight.w600,
          ),
          bodyMedium: const TextStyle(fontSize: 14, height: 1.45),
          bodySmall: const TextStyle(fontSize: 12.5, height: 1.4),
          labelLarge: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 0,
          ),
        ),
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 17,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: outline),
      ),
    ),
    dividerTheme: DividerThemeData(color: outline, thickness: 1, space: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
        shape: rounded,
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        shape: rounded,
        side: BorderSide(color: outline),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        shape: rounded,
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(40, 40),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLowest,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      hintStyle: TextStyle(
        color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.primary, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.error, width: 1.6),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainerLowest,
      indicatorColor: scheme.primaryContainer,
      indicatorShape: rounded,
      selectedIconTheme: IconThemeData(color: scheme.onPrimaryContainer),
      selectedLabelTextStyle: TextStyle(
        color: scheme.onSurface,
        fontWeight: FontWeight.w600,
      ),
      unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      unselectedLabelTextStyle: TextStyle(color: scheme.onSurfaceVariant),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 70,
      elevation: 0,
      backgroundColor: scheme.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primaryContainer,
      indicatorShape: rounded,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? scheme.onSurface
              : scheme.onSurfaceVariant,
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      elevation: 2,
      shape: rounded,
      insetPadding: const EdgeInsets.all(16),
    ),
    dialogTheme: DialogThemeData(
      elevation: 8,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 450),
      decoration: BoxDecoration(
        color: scheme.inverseSurface,
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: TextStyle(color: scheme.onInverseSurface, fontSize: 12),
    ),
  );
}

// Use fonts installed by each OS. Apple's system fonts are never bundled on
// Windows or Linux, and CJK text falls back to the platform's native sans face.
ThemeData _desktopTheme(Brightness brightness, TargetPlatform platform) {
  final dark = brightness == Brightness.dark;
  final primary = dark ? const Color(0xFF64A9FF) : const Color(0xFF0067D9);
  final surface = dark ? const Color(0xFF202124) : const Color(0xFFF7F7F9);
  final panel = dark ? const Color(0xFF2A2B2F) : Colors.white;
  final text = dark ? const Color(0xFFF3F3F5) : const Color(0xFF1D1D1F);
  final secondary = dark ? const Color(0xFFACADB5) : const Color(0xFF686970);
  final separator = dark ? const Color(0xFF414248) : const Color(0xFFE3E3E8);
  final scheme =
      ColorScheme.fromSeed(seedColor: primary, brightness: brightness).copyWith(
        primary: primary,
        onPrimary: dark ? const Color(0xFF102440) : Colors.white,
        primaryContainer: dark
            ? const Color(0xFF253B57)
            : const Color(0xFFE9F2FF),
        onPrimaryContainer: primary,
        surface: surface,
        onSurface: text,
        onSurfaceVariant: secondary,
        surfaceContainerLowest: panel,
        surfaceContainerLow: panel,
        surfaceContainer: dark
            ? const Color(0xFF303136)
            : const Color(0xFFF0F0F4),
        surfaceContainerHigh: dark
            ? const Color(0xFF35363B)
            : const Color(0xFFECECF0),
        surfaceContainerHighest: dark
            ? const Color(0xFF3B3C42)
            : const Color(0xFFE5E5EA),
        outline: secondary,
        outlineVariant: separator,
      );
  final family = switch (platform) {
    TargetPlatform.macOS => '.AppleSystemUIFont',
    TargetPlatform.windows => 'Segoe UI',
    _ => 'Ubuntu',
  };
  final fallbacks = switch (platform) {
    TargetPlatform.macOS => const ['PingFang SC', 'Heiti SC'],
    TargetPlatform.windows => const ['Microsoft YaHei UI', 'Microsoft YaHei'],
    _ => const ['Noto Sans', 'DejaVu Sans', 'Noto Sans CJK SC'],
  };
  TextStyle type(double size, FontWeight weight, {double height = 1.4}) =>
      TextStyle(
        fontSize: size,
        fontWeight: weight,
        height: height,
        letterSpacing: 0,
      );
  final textTheme =
      TextTheme(
        headlineSmall: type(24, FontWeight.w600, height: 1.2),
        titleLarge: type(18, FontWeight.w600, height: 1.3),
        titleMedium: type(14, FontWeight.w600),
        titleSmall: type(13, FontWeight.w600),
        bodyLarge: type(14, FontWeight.w400),
        bodyMedium: type(13, FontWeight.w400),
        bodySmall: type(12, FontWeight.w400),
        labelLarge: type(13, FontWeight.w500, height: 1.2),
        labelMedium: type(12, FontWeight.w500),
        labelSmall: type(11, FontWeight.w500),
      ).apply(
        fontFamily: family,
        fontFamilyFallback: fallbacks,
        bodyColor: text,
        displayColor: text,
      );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(8));
  final buttonText = textTheme.labelLarge!;
  final base = ThemeData(
    useMaterial3: true,
    platform: platform,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: family,
    fontFamilyFallback: fallbacks,
    textTheme: textTheme,
    scaffoldBackgroundColor: surface,
    canvasColor: surface,
    splashFactory: NoSplash.splashFactory,
    hoverColor: primary.withValues(alpha: 0.05),
    focusColor: primary.withValues(alpha: 0.14),
    dividerTheme: DividerThemeData(color: separator, thickness: 0.5, space: 1),
    iconTheme: IconThemeData(size: 20, color: secondary),
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      backgroundColor: surface,
      foregroundColor: text,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: textTheme.titleMedium,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: separator, width: 0.6),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        shape: shape,
        textStyle: buttonText,
        iconSize: 17,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
        backgroundColor: panel,
        foregroundColor: text,
        side: BorderSide(color: separator),
        shape: shape,
        textStyle: buttonText,
        iconSize: 17,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        shape: shape,
        textStyle: buttonText,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(32, 32),
        padding: const EdgeInsets.all(7),
        iconSize: 18,
        shape: shape,
        foregroundColor: secondary,
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        textStyle: buttonText,
        foregroundColor: secondary,
        selectedForegroundColor: text,
        backgroundColor: Colors.transparent,
        selectedBackgroundColor: panel,
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? scheme.surfaceContainer : const Color(0xFFFAFAFC),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      hintStyle: textTheme.bodyMedium?.copyWith(color: secondary),
      prefixIconColor: secondary,
      suffixIconColor: secondary,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: separator),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: separator),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: primary, width: 1.5),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: primary,
      linearTrackColor: scheme.surfaceContainerHighest,
      linearMinHeight: 5,
      borderRadius: BorderRadius.circular(4),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      contentTextStyle: textTheme.bodyMedium?.copyWith(
        color: scheme.onInverseSurface,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: panel,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: scheme.inverseSurface,
        borderRadius: BorderRadius.circular(6),
      ),
      textStyle: textTheme.bodySmall?.copyWith(color: scheme.onInverseSurface),
    ),
  );
  return base;
}
