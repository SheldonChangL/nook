import 'package:flutter/material.dart';

import 'app/app_state.dart';
import 'ui/home_screen.dart';
import 'ui/lock_screen.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SecureManageApp());
}

class SecureManageApp extends StatefulWidget {
  const SecureManageApp({super.key});

  @override
  State<SecureManageApp> createState() => _SecureManageAppState();
}

class _SecureManageAppState extends State<SecureManageApp>
    with WidgetsBindingObserver {
  final _state = AppState();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _state.boot();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    // 切到背景就上鎖，不等閒置倒數。
    if (lifecycle == AppLifecycleState.hidden ||
        lifecycle == AppLifecycleState.paused) {
      if (_state.phase == VaultPhase.unlocked) _state.lock();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SecureManage',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: ListenableBuilder(
        listenable: _state,
        builder: (context, _) => switch (_state.phase) {
          VaultPhase.loading => const Scaffold(
              body: Center(
                  child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))),
            ),
          VaultPhase.needsSetup ||
          VaultPhase.locked =>
            LockScreen(key: const ValueKey('lock'), state: _state),
          VaultPhase.unlocked =>
            HomeScreen(key: const ValueKey('home'), state: _state),
        },
      ),
    );
  }
}
