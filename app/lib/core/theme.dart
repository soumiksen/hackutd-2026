import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Road-sign palette: parking-sign green, permit yellow, tow-away red on warm asphalt neutrals.
class P {
  static const ink = Color(0xFF13201A);
  static const muted = Color(0xFF5B6A62);
  static const ground = Color(0xFFF3F4EF);
  static const card = Color(0xFFFFFFFF);
  static const line = Color(0xFFDCE1DA);
  static const sign = Color(0xFF0E6B45);
  static const signSoft = Color(0xFFDDEFE5);
  static const permit = Color(0xFFF2C230);
  static const permitSoft = Color(0xFFFCF1CC);
  static const tow = Color(0xFFB3261E);
  static const towSoft = Color(0xFFF8E2E0);
  static const agent = Color(0xFF24527A);
  static const agentSoft = Color(0xFFE1EBF4);
}

ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: P.sign,
      primary: P.sign,
      secondary: P.permit,
      error: P.tow,
      surface: P.ground,
    ),
    scaffoldBackgroundColor: P.ground,
  );
  final body = base.textTheme.apply(fontFamily: GoogleFonts.barlow().fontFamily, bodyColor: P.ink, displayColor: P.ink);
  return base.copyWith(
    textTheme: body.copyWith(
      displaySmall: GoogleFonts.barlowCondensed(fontSize: 40, fontWeight: FontWeight.w800, color: P.ink, height: 1),
      headlineMedium: GoogleFonts.barlowCondensed(fontSize: 30, fontWeight: FontWeight.w800, color: P.ink),
      headlineSmall: GoogleFonts.barlowCondensed(fontSize: 24, fontWeight: FontWeight.w700, color: P.ink),
      titleLarge: GoogleFonts.barlow(fontSize: 20, fontWeight: FontWeight.w700, color: P.ink),
      titleMedium: GoogleFonts.barlow(fontSize: 16, fontWeight: FontWeight.w700, color: P.ink),
      labelLarge: GoogleFonts.barlow(fontSize: 15, fontWeight: FontWeight.w700),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: P.ground,
      foregroundColor: P.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: GoogleFonts.barlowCondensed(fontSize: 24, fontWeight: FontWeight.w800, color: P.ink),
    ),
    cardTheme: CardThemeData(
      color: P.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: P.line)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: GoogleFonts.barlow(fontSize: 17, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 52),
        foregroundColor: P.ink,
        side: const BorderSide(color: P.line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: GoogleFonts.barlow(fontSize: 16, fontWeight: FontWeight.w700),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: P.card,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: P.line)),
      enabledBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: P.line)),
    ),
    navigationBarTheme: const NavigationBarThemeData(backgroundColor: P.card, indicatorColor: P.signSoft),
  );
}
