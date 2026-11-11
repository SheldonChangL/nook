import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 各桌面平台不一樣的地方集中在這裡，畫面與狀態只問「能不能」，不自己判斷平台。
///
/// 預設跟著 [defaultTargetPlatform] 走，所以測試可以用
/// `debugDefaultTargetPlatformOverride` 切換平台，不必真的在那台機器上跑。
class PlatformProfile {
  const PlatformProfile._(this.platform);

  factory PlatformProfile.of(TargetPlatform platform) =>
      PlatformProfile._(platform);

  static PlatformProfile get current =>
      PlatformProfile.of(defaultTargetPlatform);

  final TargetPlatform platform;

  bool get isMacOS => platform == TargetPlatform.macOS;
  bool get isWindows => platform == TargetPlatform.windows;
  bool get isLinux => platform == TargetPlatform.linux;

  /// 快速解鎖（把 DEK 另存一份、通過系統驗證才取出）只在 macOS 有經過設計與實測：
  /// Touch ID ＋ 本機 Keychain。
  ///
  /// Windows 的 Windows Hello 與安全儲存是兩個互不相干的介面，只在讀出 DEK
  /// 之後再跳 Hello，不能說 DEK 受到 Hello 保護；Linux 的 local_auth 沒有實作。
  /// 這兩個平台在另行設計金鑰保護之前一律只用主密碼。
  bool get supportsQuickUnlock => isMacOS;

  /// macOS runner 有實作 `nook/window` 通道（鎖定／保險庫兩種視窗尺寸、標題列
  /// 深淺色、狀態列收合）。Windows／Linux 的 runner 沒有，呼叫只會丟
  /// MissingPluginException，所以乾脆不叫。
  bool get hasWindowChannel => isMacOS;

  /// 中文字型的備援順序，加在主題與等寬字的 fontFamilyFallback 後面。
  ///
  /// Linux 上 Flutter 不會自己找到 CJK 字型：Ubuntu 24.04 乾淨容器裡已裝
  /// fonts-noto-cjk、fontconfig 也解析得到 Noto Sans CJK TC，介面中文仍全是方塊
  /// （C.UTF-8 與 zh_TW.UTF-8 都一樣，實測）。明確指名 family 之後，Flutter 會經
  /// fontconfig 依名稱載入。字型由 .deb 的 Depends: fonts-noto-cjk 保證存在。
  ///
  /// macOS／Windows 的系統備援本來就找得到中文（Windows 未實機確認），不改，
  /// 免得裝了 Noto CJK 的 Mac 換掉 PingFang。
  List<String> get cjkFontFallback => isLinux
      ? const ['Noto Sans CJK TC', 'Noto Sans CJK SC', 'Noto Sans CJK JP']
      : const [];

  /// macOS 用 ⌘，其他桌面平台慣例是 Ctrl。
  bool get usesCommandKey => isMacOS;

  /// 給畫面上提示用的修飾鍵寫法，例如「⌘K」或「Ctrl+K」。
  String get modifierLabel => usesCommandKey ? '⌘' : 'Ctrl+';

  String shortcutLabel(String key) => '$modifierLabel$key';

  /// 以該平台的主修飾鍵組合快捷鍵。
  SingleActivator shortcut(LogicalKeyboardKey key) => usesCommandKey
      ? SingleActivator(key, meta: true)
      : SingleActivator(key, control: true);

  /// 設定頁那個生命週期上鎖開關的標題。
  ///
  /// 程式只在 Flutter 回報 hidden／paused 時上鎖（main.dart），只失去焦點的
  /// inactive 不算。macOS 焦點一離開就會送 hidden（實測過），所以叫「切換到其他
  /// app」名副其實；Windows／Linux 依 Flutter 引擎的對應，焦點離開只會是 inactive，
  /// 要最小化／隱藏才是 hidden —— 這裡照程式實際行為命名，不宣稱切換焦點會鎖。
  /// （各平台引擎何時送 hidden 尚未在 Windows／Linux 實機確認。）
  String get appSwitchTitle => isMacOS ? '切換到其他 app 就立刻上鎖' : '視窗最小化或隱藏時立刻上鎖';

  /// 上面那個開關的說明。
  String get appSwitchHint {
    if (isMacOS) {
      return 'macOS 只要焦點離開就算切換，所以開了之後每次 ⌘Tab 都會被鎖，'
          '要重打主密碼。閒置自動上鎖本來就擋得住離開座位的情況，'
          '除非你的螢幕常被旁人看到，否則不建議開。';
    }
    return '只把焦點切到別的視窗不會上鎖；要把 Nook 最小化或隱藏才算。'
        '閒置自動上鎖本來就擋得住離開座位的情況，'
        '除非你的螢幕常被旁人看到，否則不建議開。';
  }
}
