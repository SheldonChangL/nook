import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/app_state.dart';
import 'ui/home_screen.dart';
import 'ui/lock_screen.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SecureManageApp());
}

class SecureManageApp extends StatefulWidget {
  const SecureManageApp({super.key, this.state});

  /// 測試用：讓測試可以塞一個指向暫存目錄、不碰 Touch ID 的狀態進來。
  /// 正式執行時是 null，自己建一個。
  final AppState? state;

  @override
  State<SecureManageApp> createState() => _SecureManageAppState();
}

class _SecureManageAppState extends State<SecureManageApp>
    with WidgetsBindingObserver {
  late final AppState _state = widget.state ?? AppState();
  final _navigator = GlobalKey<NavigatorState>();

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
    _state.boot();
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
    _state.onLocked = null;
    // 外面塞進來的狀態由外面負責釋放，這裡只收自己建的那個。
    if (widget.state == null) _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SecureManage',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigator,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
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
        },
      ),
    );
  }
}
