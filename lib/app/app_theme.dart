import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

ThemeData splavTheme() {
  final font = defaultTargetPlatform == TargetPlatform.windows
      ? 'Segoe UI'
      : 'Roboto';
  final colors =
      ColorScheme.fromSeed(
        seedColor: const Color(0xff087f83),
        surface: Colors.white,
        onSurface: const Color(0xff1d3343),
      ).copyWith(
        surfaceContainerLowest: Colors.white,
        surfaceContainerLow: Colors.white,
        surfaceContainer: Colors.white,
        surfaceContainerHigh: Colors.white,
        surfaceContainerHighest: Colors.white,
      );
  final button = ButtonStyle(
    alignment: Alignment.center,
    minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    ),
    textStyle: WidgetStatePropertyAll(
      TextStyle(
        fontFamily: font,
        fontSize: 14,
        fontWeight: FontWeight.w600,
        height: 1.2,
        leadingDistribution: TextLeadingDistribution.even,
      ),
    ),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
  return ThemeData(
    useMaterial3: true,
    fontFamily: font,
    colorScheme: colors,
    scaffoldBackgroundColor: Colors.white,
    canvasColor: Colors.white,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 1,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xffd9e3ec)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xffc5d4df)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xffc5d4df)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: button.copyWith(
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled) ? Colors.white : null,
        ),
        side: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? const BorderSide(color: Color(0xffd9e3ec))
              : null,
        ),
      ),
    ),
    chipTheme: const ChipThemeData(disabledColor: Colors.white),
    outlinedButtonTheme: OutlinedButtonThemeData(style: button),
    textButtonTheme: TextButtonThemeData(style: button),
    dataTableTheme: const DataTableThemeData(
      headingRowColor: WidgetStatePropertyAll(Colors.white),
      headingTextStyle: TextStyle(
        fontWeight: FontWeight.w700,
        color: Color(0xff334f63),
      ),
      dataRowMinHeight: 76,
      dataRowMaxHeight: 86,
      horizontalMargin: 20,
      columnSpacing: 28,
      dividerThickness: 1,
    ),
    dividerTheme: const DividerThemeData(
      color: Color(0xffdce5ed),
      thickness: 1,
    ),
  );
}
