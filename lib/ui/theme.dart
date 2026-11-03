import 'package:flutter/material.dart';

import '../app/app_state.dart';

/// 動畫時長集中在這裡。這種每天開十幾次的工具，動畫寧可偏快。
class Motion {
  static const fast = Duration(milliseconds: 180);
  static const base = Duration(milliseconds: 260);
  static const panel = Duration(milliseconds: 380);
  static const curve = Cubic(0.2, 0.8, 0.3, 1);
  static const overshoot = Cubic(0.2, 0.9, 0.3, 1.1);

  /// 列表逐項浮現的間隔。
  static const stagger = Duration(milliseconds: 55);
}

class AppTheme {
  static const seed = Color(0xFF3F6E8C);

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData nook(bool dark) {
    final palette = NookPalette(dark);
    final scheme =
        ColorScheme.fromSeed(
          seedColor: palette.accent,
          brightness: dark ? Brightness.dark : Brightness.light,
        ).copyWith(
          primary: palette.accent,
          onPrimary: palette.onAccent,
          surface: palette.surface,
          onSurface: palette.text,
          onSurfaceVariant: palette.muted,
          outline: palette.border,
          outlineVariant: palette.border,
        );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: palette.background,
      visualDensity: VisualDensity.compact,
      dividerTheme: DividerThemeData(
        thickness: 0.5,
        space: 0.5,
        color: palette.border,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.surfaceRaised,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: palette.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: palette.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: palette.accent, width: 1.4),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: palette.accent,
          foregroundColor: palette.onAccent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: palette.text,
          side: BorderSide(color: palette.border),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: palette.muted),
      ),
    );
  }

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    final isDark = brightness == Brightness.dark;
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: isDark
          ? const Color(0xFF1C1C1E)
          : const Color(0xFFF6F6F4),
      visualDensity: VisualDensity.compact,
      dividerTheme: DividerThemeData(
        thickness: 0.5,
        space: 0.5,
        color: scheme.outlineVariant.withValues(alpha: 0.6),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 10,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }
}

/// 整個 app 共用的卡片外框。
BoxDecoration panelDecoration(BuildContext context, {bool strong = false}) {
  final scheme = Theme.of(context).colorScheme;
  return BoxDecoration(
    color: scheme.surface,
    borderRadius: BorderRadius.circular(12),
    border: Border.all(
      color: strong ? scheme.outline : scheme.outlineVariant,
      width: 0.5,
    ),
  );
}

/// 等寬字。硬寫 'Menlo' 在 macOS 沒問題，但之後移植到 Android 就沒這個字型，
/// 所以留備援清單。
const monoFamily = 'Menlo';
const monoFallback = <String>['SF Mono', 'Courier New', 'monospace'];

/// 給等寬欄位用的樣式。
TextStyle monoStyle({double fontSize = 13, double? height, Color? color}) =>
    TextStyle(
      fontFamily: monoFamily,
      fontFamilyFallback: monoFallback,
      fontSize: fontSize,
      height: height,
      color: color,
    );

/// SecureManage_UI_Assets/palette.json 的色票。鎖定畫面與主畫面共用。
///
/// 這些素材是固定的淺色設計，所以用到它們的畫面不跟系統深色模式走。
const brandBlueDark = Color(0xFF0D5C96);
const brandBlue = Color(0xFF1878BE);
const brandBlueBright = Color(0xFF2F8EDB);
const panelBlueLight = Color(0xFFDDF1FF);
const panelBlueMid = Color(0xFF9ED1FA);
const brandSurface = Color(0xFFFCFCFB);
const brandSurfaceAlt = Color(0xFFF3F6FA);
const brandTextPrimary = Color(0xFF17212B);
const brandTextSecondary = Color(0xFF66707A);
const brandBorder = Color(0xFFD7DEE7);
const brandGreen = Color(0xFF1D9E75);
const brandGreenBg = Color(0xFFE1F5EE);

/// 素材資料夾。檔名沿用使用者給的那包，沒有跟著 app 改名。
const brandAssets = 'SecureManage_UI_Assets';

/// 兩套 mock 共用的語意色票。元件只取用途，不各自判斷深淺色。
class NookPalette {
  const NookPalette(this.dark);

  final bool dark;

  Color get background =>
      dark ? const Color(0xFF071520) : const Color(0xFFF7F7F4);
  Color get sidebar => dark ? const Color(0xFF081824) : const Color(0xFFEAF2F6);
  Color get surface => dark ? const Color(0xFF0B1C29) : const Color(0xFFFCFCFA);
  Color get surfaceRaised =>
      dark ? const Color(0xFF102432) : const Color(0xFFF0F4F6);
  Color get border => dark ? const Color(0xFF29404F) : const Color(0xFFCAD5DB);
  Color get text => dark ? const Color(0xFFEAF2F6) : const Color(0xFF1C2730);
  Color get muted => dark ? const Color(0xFF9AAAB5) : const Color(0xFF64727C);
  Color get accent => dark ? const Color(0xFF50D4F4) : const Color(0xFF238FC3);
  Color get accentSoft =>
      dark ? const Color(0xFF0B5368) : const Color(0xFFD7EFF8);
  Color get onAccent => dark ? const Color(0xFF04212B) : Colors.white;
}

/// 深淺色切換共用同一個按鈕與可存取名稱，鎖定頁和主畫面才不會各做一套。
class AppearanceToggle extends StatelessWidget {
  const AppearanceToggle({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final dark = state.darkAppearance;
    return IconButton(
      tooltip: dark ? '切換為淺色模式' : '切換為深色模式',
      onPressed: state.toggleAppearance,
      icon: Icon(dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
    );
  }
}
