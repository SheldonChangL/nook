import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../services/biometric_gate.dart';
import '../services/clipboard_guard.dart';
import '../vault/models.dart';
import '../vault/vault_crypto.dart';
import '../vault/vault_store.dart';

enum VaultPhase {
  /// 還在找保險庫在不在。
  loading,

  /// 這台機器還沒有保險庫，要先設定主密碼。
  needsSetup,

  /// 有保險庫，鎖著。
  locked,

  /// 解開了。
  unlocked,
}

class AppState extends ChangeNotifier {
  AppState({
    VaultStore? store,
    BiometricGate? biometrics,
    ClipboardGuard? clipboard,
  }) : _injectedStore = store,
       biometrics = biometrics ?? BiometricGate(),
       clipboard = clipboard ?? ClipboardGuard();

  final VaultStore? _injectedStore;
  final BiometricGate biometrics;
  final ClipboardGuard clipboard;

  late VaultStore store;
  VaultPhase phase = VaultPhase.loading;

  /// 解鎖失敗的訊息。刻意不細分原因。
  String? unlockError;

  bool busy = false;
  bool biometricAvailable = false;
  bool biometricArmed = false;

  Timer? _idleTimer;
  DateTime _lastActivity = DateTime.now();

  /// 上鎖時要收掉畫面上還開著的對話框，不然編輯器或詳情面板會留在上鎖畫面
  /// 上面繼續顯示機密。由 main.dart 接上 Navigator。
  VoidCallback? onLocked;

  /// 距離自動上鎖還有幾秒。
  int secondsUntilLock = 0;

  /// 被當成「使用者還在操作」的次數。給測試確認鍵盤與對話框裡的動作真的有算到。
  int touchCount = 0;

  String get vaultPath => store.root.path;
  List<VaultItem> get items => store.items;
  VaultSettings get settings => store.settings;

  Future<void> boot() async {
    store =
        _injectedStore ??
        VaultStore(
          Directory('${(await getApplicationSupportDirectory()).path}/vault'),
        );
    biometricAvailable = await biometrics.isAvailable;
    biometricArmed = biometricAvailable && await biometrics.hasStoredKey;
    phase = store.exists ? VaultPhase.locked : VaultPhase.needsSetup;
    clipboard.clearAfter = Duration(seconds: store.exists ? 30 : 30);
    notifyListeners();
  }

  // ------------------------------------------------------------ 解鎖 / 上鎖

  Future<bool> createVault(String password) async {
    return _guard(() async {
      await store.create(password);
      _afterUnlock();
      return true;
    });
  }

  Future<bool> unlock(String password) async {
    return _guard(() async {
      await store.unlock(password);
      _afterUnlock();
      return true;
    });
  }

  /// Touch ID 解鎖。沒開、沒通過、或 Keychain 那份跟保險庫對不上，都回 false
  /// 讓畫面退回主密碼。
  Future<bool> unlockWithBiometrics() async {
    if (!biometricArmed) return false;
    return _guard(() async {
      final dek = await biometrics.unlock();
      if (dek == null) return false;
      try {
        await store.unlockWithDek(dek);
      } on VaultOpenException {
        await biometrics.forget();
        biometricArmed = false;
        throw const VaultOpenException('Touch ID 存的金鑰跟保險庫對不上，請用主密碼');
      }
      _afterUnlock();
      return true;
    });
  }

  void _afterUnlock() {
    phase = VaultPhase.unlocked;
    unlockError = null;
    clipboard.clearAfter = Duration(seconds: settings.clipboardClearSeconds);
    _lastActivity = DateTime.now();
    secondsUntilLock = settings.autoLockSeconds;
    _idleTimer?.cancel();
    _idleTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  Future<bool> _guard(Future<bool> Function() action) async {
    busy = true;
    unlockError = null;
    notifyListeners();
    try {
      return await action();
    } on VaultOpenException catch (e) {
      unlockError = e.message;
      return false;
    } catch (e) {
      unlockError = '出了點問題：$e';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void _tick() {
    final idle = DateTime.now().difference(_lastActivity).inSeconds;
    secondsUntilLock = settings.autoLockSeconds - idle;
    if (secondsUntilLock <= 0) {
      lock();
    } else {
      notifyListeners();
    }
  }

  /// 任何使用者操作都呼叫這個，把倒數推回去。
  void touch() {
    if (phase != VaultPhase.unlocked) return;
    _lastActivity = DateTime.now();
    secondsUntilLock = settings.autoLockSeconds;
    touchCount++;
  }

  void lock() {
    _idleTimer?.cancel();
    _idleTimer = null;
    store.lock();
    clipboard.clearNow();
    phase = VaultPhase.locked;
    secondsUntilLock = 0;
    onLocked?.call();
    notifyListeners();
  }

  // ------------------------------------------------------------ 項目

  Future<void> save(VaultItem item) async {
    touch();
    await store.put(item);
    notifyListeners();
  }

  Future<void> remove(String id) async {
    touch();
    await store.delete(id);
    notifyListeners();
  }

  /// 主機上引用的那把金鑰。找不到就回 null（金鑰被刪掉的情況）。
  SecureKeyItem? resolveKey(String? keyRef) {
    if (keyRef == null) return null;
    final item = store.byId(keyRef);
    return item is SecureKeyItem ? item : null;
  }

  // ------------------------------------------------------------ 設定

  Future<void> setAutoLockSeconds(int seconds) async {
    settings.autoLockSeconds = seconds;
    await store.saveSettings();
    secondsUntilLock = seconds;
    touch();
    notifyListeners();
  }

  Future<void> setLockOnAppSwitch(bool enabled) async {
    settings.lockOnAppSwitch = enabled;
    await store.saveSettings();
    touch();
    notifyListeners();
  }

  Future<void> setClipboardSeconds(int seconds) async {
    settings.clipboardClearSeconds = seconds;
    clipboard.clearAfter = Duration(seconds: seconds);
    await store.saveSettings();
    notifyListeners();
  }

  Future<String?> setBiometricEnabled(bool enabled) async {
    if (enabled) {
      final dek = await store.exportDek();
      final ok = await biometrics.enroll(dek);
      if (!ok) return 'Touch ID 沒有通過，維持關閉';
      biometricArmed = true;
    } else {
      await biometrics.forget();
      biometricArmed = false;
    }
    settings.biometricEnabled = enabled;
    await store.saveSettings();
    notifyListeners();
    return null;
  }

  Future<String?> changeMasterPassword(String oldPw, String newPw) async {
    try {
      await store.changePassword(oldPw, newPw);
      // 換了主密碼，Keychain 那份 DEK 沒變（DEK 本身沒換），不用重新註冊。
      return null;
    } on VaultOpenException catch (e) {
      return e.message;
    }
  }

  Future<void> copySecret(String value, {required String label}) async {
    touch();
    await clipboard.copy(value, label: label);
    notifyListeners();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    clipboard.dispose();
    super.dispose();
  }
}
