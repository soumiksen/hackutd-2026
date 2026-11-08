import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Road-sign palette: parking-sign green, permit yellow, tow-away red on warm asphalt neutrals.
class P {
  // Neutrals
  static const ink = Color(0xFF101A15);
  static const inkSoft = Color(0xFF2A3630);
  static const muted = Color(0xFF66736C);
  static const faint = Color(0xFF9AA59F);
  static const ground = Color(0xFFF4F5F1);
  static const card = Color(0xFFFFFFFF);
  static const line = Color(0xFFE2E6E0);

  // Brand
  static const sign = Color(0xFF0B6B45);
  static const signDeep = Color(0xFF064A30);
  static const signBright = Color(0xFF14965F);
  static const signSoft = Color(0xFFDDF0E6);
  static const permit = Color(0xFFF4C430);
  static const permitSoft = Color(0xFFFCF2CF);
  static const tow = Color(0xFFC0362C);
  static const towSoft = Color(0xFFF9E3E1);
  static const agent = Color(0xFF2A5B88);
  static const agentSoft = Color(0xFFE3EDF6);

  static const heroGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [signBright, sign, signDeep],
  );
}

/// Spacing and radius tokens, so every screen lines up.
class S {
  static const xs = 4.0, sm = 8.0, md = 12.0, lg = 16.0, xl = 20.0, xxl = 28.0;
  static const page = EdgeInsets.fromLTRB(20, 8, 20, 32);
  static const rSm = 10.0, rMd = 14.0, rLg = 20.0, rXl = 28.0;
}

/// Soft, layered elevation used on cards instead of Material shadows.
const softShadow = [
  BoxShadow(color: Color(0x0F101A15), blurRadius: 2, offset: Offset(0, 1)),
  BoxShadow(color: Color(0x0D101A15), blurRadius: 16, offset: Offset(0, 6)),
];

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
    splashFactory: InkSparkle.splashFactory,
  );
  final body = base.textTheme.apply(fontFamily: GoogleFonts.barlow().fontFamily, bodyColor: P.ink, displayColor: P.ink);
  final display = GoogleFonts.barlowCondensed;
  return base.copyWith(
    textTheme: body.copyWith(
      displayMedium: display(fontSize: 48, fontWeight: FontWeight.w800, color: P.ink, height: 0.95, letterSpacing: -0.5),
      displaySmall: display(fontSize: 40, fontWeight: FontWeight.w800, color: P.ink, height: 1, letterSpacing: -0.3),
      headlineMedium: display(fontSize: 30, fontWeight: FontWeight.w800, color: P.ink, height: 1.05),
      headlineSmall: display(fontSize: 24, fontWeight: FontWeight.w700, color: P.ink),
      titleLarge: GoogleFonts.barlow(fontSize: 19, fontWeight: FontWeight.w700, color: P.ink),
      titleMedium: GoogleFonts.barlow(fontSize: 16, fontWeight: FontWeight.w700, color: P.ink),
      bodyLarge: GoogleFonts.barlow(fontSize: 16, fontWeight: FontWeight.w500, color: P.ink, height: 1.4),
      bodyMedium: GoogleFonts.barlow(fontSize: 14.5, fontWeight: FontWeight.w500, color: P.ink, height: 1.35),
      labelLarge: GoogleFonts.barlow(fontSize: 15, fontWeight: FontWeight.w700),
      labelMedium: GoogleFonts.barlow(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.1, color: P.muted),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: P.ground,
      foregroundColor: P.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: display(fontSize: 24, fontWeight: FontWeight.w800, color: P.ink),
    ),
    cardTheme: CardThemeData(
      color: P.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(S.rLg), side: const BorderSide(color: P.line)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 54),
        backgroundColor: P.sign,
        disabledBackgroundColor: P.line,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(S.rMd)),
        textStyle: GoogleFonts.barlow(fontSize: 17, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 52),
        foregroundColor: P.ink,
        backgroundColor: P.card,
        side: const BorderSide(color: P.line, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(S.rMd)),
        textStyle: GoogleFonts.barlow(fontSize: 16, fontWeight: FontWeight.w700),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: P.sign,
        textStyle: GoogleFonts.barlow(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.comfortable,
        side: const WidgetStatePropertyAll(BorderSide(color: P.line, width: 1.5)),
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? P.ink : P.card),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : P.ink),
        iconColor: const WidgetStatePropertyAll(Colors.white),
        textStyle: WidgetStatePropertyAll(GoogleFonts.barlow(fontSize: 14.5, fontWeight: FontWeight.w700)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: P.card,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      labelStyle: const TextStyle(color: P.muted, fontWeight: FontWeight.w600),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(S.rMd), borderSide: const BorderSide(color: P.line)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(S.rMd), borderSide: const BorderSide(color: P.line, width: 1.5)),
      focusedBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(S.rMd), borderSide: const BorderSide(color: P.sign, width: 2)),
    ),
    sliderTheme: const SliderThemeData(activeTrackColor: P.sign, thumbColor: P.sign, inactiveTrackColor: P.line),
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? P.sign : P.line),
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: P.card,
      side: const BorderSide(color: P.line, width: 1.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
      labelStyle: GoogleFonts.barlow(fontSize: 14, fontWeight: FontWeight.w700, color: P.ink),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: P.ink,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(S.rMd)),
      contentTextStyle: GoogleFonts.barlow(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: P.ground,
      showDragHandle: true,
      dragHandleColor: P.line,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(S.rXl))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: P.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(S.rLg)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: P.card,
      indicatorColor: P.signSoft,
      height: 68,
      elevation: 0,
      labelTextStyle: WidgetStateProperty.resolveWith((s) => GoogleFonts.barlow(
          fontSize: 12.5,
          fontWeight: s.contains(WidgetState.selected) ? FontWeight.w800 : FontWeight.w600,
          color: s.contains(WidgetState.selected) ? P.sign : P.muted)),
      iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(color: s.contains(WidgetState.selected) ? P.sign : P.muted, size: 24)),
    ),
    dividerTheme: const DividerThemeData(color: P.line, space: 1, thickness: 1),
    listTileTheme: const ListTileThemeData(iconColor: P.muted),
  );
}
