import 'package:flutter/material.dart';
import '../core/settings.dart';

/// nPlayer 톤의 다크 테마. 색은 여기서만 바꾸면 전체에 반영된다.
class OColors {
  OColors(this.scheme);
  final ColorScheme scheme;
  static OColors of(BuildContext context) => OColors(Theme.of(context).colorScheme);
  Color get bg => scheme.brightness == Brightness.dark ? const Color(0xFF121214) : const Color(0xFFF6F7FA);
  Color get surface => scheme.surface;
  Color get surfaceHigh => scheme.surfaceContainerHigh;
  Color get divider => scheme.outlineVariant;
  Color get accent => scheme.primary;
  Color get textPrimary => scheme.onSurface;
  Color get textSecondary => scheme.onSurfaceVariant;
  static const playerOverlay = Color(0x99000000);
  static const panel = Color(0xE6151517);
}

class OTheme {
  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);
  static ThemeData _build(Brightness brightness) {
    final primary = Color(AppSettings.instance.primaryColor);
    final secondary = Color(AppSettings.instance.secondaryColor);
    Color on(Color c) => ThemeData.estimateBrightnessForColor(c) == Brightness.dark ? Colors.white : Colors.black;
    final scheme = ColorScheme.fromSeed(seedColor: primary, brightness: brightness).copyWith(
      primary: primary,
      onPrimary: on(primary),
      secondary: secondary,
      onSecondary: on(secondary),
      surface: brightness == Brightness.dark ? const Color(0xFF1C1C1F) : Colors.white,
    );
    final colors = OColors(scheme);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: colors.bg,
      canvasColor: colors.bg,
      dividerColor: colors.divider,
      appBarTheme: AppBarTheme(
        backgroundColor: colors.bg,
        foregroundColor: colors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: colors.textPrimary),
      ),
      drawerTheme: DrawerThemeData(backgroundColor: colors.surface),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating, showCloseIcon: true),
      listTileTheme: ListTileThemeData(iconColor: colors.textSecondary, textColor: colors.textPrimary),
      sliderTheme: SliderThemeData(
        activeTrackColor: primary,
        thumbColor: primary,
        inactiveTrackColor: scheme.surfaceContainerHighest,
        secondaryActiveTrackColor: secondary,
        trackHeight: 3,
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
      ),
    );
  }
}
