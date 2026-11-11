import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/app_state.dart';
import 'app/platform_profile.dart';
import 'ui/home_screen.dart';
import 'ui/lock_screen.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NookApp());
}

class NookApp extends StatefulWidget {
  const NookApp({super.key, this.state});

  /// 測試用：讓測試可以塞一個指向暫存目錄、不碰 Touch ID 的狀態進來。
  /// 正式執行時是 null，自己建一個。
  final AppState? state;

  @override
  State<NookApp> createState() => _NookAppState();
}

class _NookAppState extends State<NookApp> with WidgetsBindingObserver {
  static const _windowChannel = MethodChannel('nook/window');

  late final AppState _state = widget.state ?? AppState();
  final _navigator = GlobalKey<NavigatorState>();
  bool? _lastCompactWindow;
  bool? _lastDarkWindow;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 打字也是活動。這裡要用 HardwareKeyboard 而不是某個 widget 的 Listener：
    // Listener 收不到鍵盤事件，而且掛在畫面裡的話，對話框是 Navigator 上另一個
    // route，事件根本不會經過它 —— 新增項目打到一半被上鎖就是這樣來的。
    HardwareKeyboard.instance.addHandler(_onKey);
    // 上鎖時把還開著的對話框收掉，不然編輯器會留在上鎖畫面上繼續顯示機密。
    _state.onLocked = () =>
        _navigator.currentState?.popUntil((route) => route.isFirst);
    _state.addListener(_syncWindowMode);
    // 原生端在視窗收進狀態列／開回來時通知，Touch ID 的自動提示靠這個判斷。
    if (widget.state == null) {
      _windowChannel.setMethodCallHandler((call) async {
        if (call.method == 'windowVisible') {
          _state.setWindowVisible(call.arguments == true);
        }
      });
    }
    _state.boot();
  }

  void _syncWindowMode() {
    // 測試注入的狀態沒有原生 Runner，不應呼叫 platform channel。
    if (widget.state != null) return;
    // 只有 macOS runner 實作了這個通道。Windows／Linux 用固定的初始視窗尺寸，
    // 標題列跟著系統外觀，關窗就結束程式（重新開啟時一定停在上鎖畫面）。
    if (!PlatformProfile.current.hasWindowChannel) return;
    final compact = _state.phase != VaultPhase.unlocked;
    if (_lastCompactWindow != compact) {
      _lastCompactWindow = compact;
      unawaited(
        _windowChannel
            .invokeMethod<void>('setMode', compact ? 'lock' : 'vault')
            .catchError((_) {}),
      );
    }
    // 標題列也要跟著深淺色走，不然深色鎖定畫面頂著一條白色標題列。
    final dark = _state.darkAppearance;
    if (_lastDarkWindow != dark) {
      _lastDarkWindow = dark;
      unawaited(
        _windowChannel
            .invokeMethod<void>('setAppearance', dark ? 'dark' : 'light')
            .catchError((_) {}),
      );
    }
  }

  /// 只是記錄「有人在操作」，不攔截任何按鍵。
  bool _onKey(KeyEvent event) {
    _state.touch();
    return false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (_state.phase != VaultPhase.unlocked) return;
    // macOS 只要焦點切到別的 app 就會送 hidden，視窗根本不用被遮住（實測過）。
    // Windows／Linux 送出 hidden 的時機依視窗系統而定（通常是最小化），未經實機確認。
    // 所以預設不靠生命週期上鎖，不然 ⌘Tab 一次就鎖一次，完全沒辦法用。
    // 要這個行為的人自己去設定裡開。
    //
    // 機器睡著的情況不必靠這裡：閒置判斷用的是真實經過時間，醒來第一次
    // tick 就會發現超時而上鎖。
    if (!_state.settings.lockOnAppSwitch) return;
    if (lifecycle == AppLifecycleState.hidden ||
        lifecycle == AppLifecycleState.paused) {
      _state.lock();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_onKey);
    _state.removeListener(_syncWindowMode);
    _state.onLocked = null;
    // 外面塞進來的狀態由外面負責釋放，這裡只收自己建的那個。
    if (widget.state == null) _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nook',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigator,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: _state.darkAppearance ? ThemeMode.dark : ThemeMode.light,
      // builder 包在 Navigator 外面，所以對話框裡的滑鼠動作也算數。
      builder: (context, child) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _state.touch(),
        onPointerMove: (_) => _state.touch(),
        onPointerHover: (_) => _state.touch(),
        onPointerSignal: (_) => _state.touch(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: ListenableBuilder(
        listenable: _state,
        builder: (context, _) => switch (_state.phase) {
          VaultPhase.loading => const Scaffold(
            body: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
          VaultPhase.needsSetup || VaultPhase.locked => LockScreen(
            key: const ValueKey('lock'),
            state: _state,
          ),
          VaultPhase.unlocked => HomeScreen(
            key: const ValueKey('home'),
            state: _state,
          ),
          VaultPhase.blocked => _BlockedScreen(
            message: _state.blockedReason ?? 'Nook 這次不能安全開啟。',
          ),
        },
      ),
    );
  }
}

/// 不能安全開啟時（多半是已經有一個 Nook 開著）的畫面。不碰保險庫，只說明原因。
class _BlockedScreen extends StatelessWidget {
  const _BlockedScreen({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      key: const ValueKey('blocked'),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_clock_outlined,
                  size: 32,
                  color: scheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.6,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () => SystemNavigator.pop(),
                  child: const Text('關閉'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
