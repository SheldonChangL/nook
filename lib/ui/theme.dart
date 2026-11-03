import 'package:flutter/material.dart';

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

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    final isDark = brightness == Brightness.dark;
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor:
          isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF6F6F4),
      visualDensity: VisualDensity.compact,
      dividerTheme: DividerThemeData(
        thickness: 0.5,
        space: 0.5,
        color: scheme.outlineVariant.withValues(alpha: 0.6),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
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
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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
