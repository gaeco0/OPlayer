import 'package:flutter/material.dart';

/// nPlayer 톤의 다크 테마. 색은 여기서만 바꾸면 전체에 반영된다.
class OColors {
  static const bg = Color(0xFF121214);
  static const surface = Color(0xFF1C1C1F);
  static const surfaceHigh = Color(0xFF26262A);
  static const divider = Color(0xFF2E2E33);
  static const accent = Color(0xFF2D9CFF);
  static const textPrimary = Color(0xFFEDEDED);
  static const textSecondary = Color(0xFF9A9AA0);
  static const playerOverlay = Color(0x99000000);
  static const panel = Color(0xE6151517);
}

class OTheme {
  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: OColors.accent,
      brightness: Brightness.dark,
    ).copyWith(
      primary: OColors.accent,
      surface: OColors.surface,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: OColors.bg,
      canvasColor: OColors.bg,
      dividerColor: OColors.divider,
      appBarTheme: const AppBarTheme(
        backgroundColor: OColors.bg,
        foregroundColor: OColors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: OColors.textPrimary,
        ),
      ),
      drawerTheme: const DrawerThemeData(backgroundColor: OColors.surface),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating, showCloseIcon: true),
      listTileTheme: const ListTileThemeData(
        iconColor: OColors.textSecondary,
        textColor: OColors.textPrimary,
      ),
      sliderTheme: const SliderThemeData(
        activeTrackColor: OColors.accent,
        thumbColor: OColors.accent,
        inactiveTrackColor: Color(0x55FFFFFF),
        secondaryActiveTrackColor: Color(0x99FFFFFF),
        trackHeight: 3,
        overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7),
      ),
    );
  }
}
