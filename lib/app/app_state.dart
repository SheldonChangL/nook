import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../services/biometric_gate.dart';
import 'instance_lock.dart';
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

  /// 不能安全開啟：別的 Nook 正在用同一個保險庫，或連單一執行個體鎖都拿不到。
  /// 這個狀態下完全不讀寫保險庫。原因在 [AppState.blockedReason]。
  blocked,
}

/// 取得單一執行個體鎖。回 null 代表別的程序握著；丟例外代表鎖檔本身開不了。
typedef InstanceLockAcquirer = InstanceLock? Function(Directory supportDir);

class AppState extends ChangeNotifier {
  AppState({
    VaultStore? store,
    BiometricGate? biometrics,
    ClipboardGuard? clipboard,
    InstanceLockAcquirer? acquireInstanceLock,
  }) : _injectedStore = store,
       _acquireInstanceLock = acquireInstanceLock,
       biometrics = biometrics ?? BiometricGate(),
       clipboard = clipboard ?? ClipboardGuard();

  final VaultStore? _injectedStore;

  /// 測試注入暫存目錄的 store 時預設不取鎖（測試可另外注入）；正式執行一定取。
  final InstanceLockAcquirer? _acquireInstanceLock;

  static InstanceLock? _defaultAcquire(Directory supportDir) =>
      InstanceLock.tryAcquire(
        File('${supportDir.path}${Platform.pathSeparator}nook.lock'),
      );

  /// 整個程序存活期間都握著，不主動釋放（程序結束時作業系統會收回）。
  InstanceLock? instanceLock;

  /// [VaultPhase.blocked] 時給使用者看的原因。
  String? blockedReason;

  /// 保險庫資料夾權限沒能收緊時的說明（只在 Linux 會檢查）。null 代表沒問題。
  String? permissionWarning;
  final BiometricGate biometrics;
  final ClipboardGuard clipboard;

  late VaultStore store;
  VaultPhase phase = VaultPhase.loading;

  /// 解鎖失敗的訊息。刻意不細分原因。
  String? unlockError;

  bool busy = false;
  bool biometricAvailable = false;
  bool biometricArmed = false;
  bool darkAppearance = true;

  /// 視窗是不是看得到。收進狀態列時是 false，由 main.dart 從原生端同步。
  /// 視窗藏著的時候不該跳 Touch ID 的系統對話框，等開回來再問。
  bool windowVisible = true;
  bool _autoUnlockPending = false;

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
    final injected = _injectedStore;
    final Directory? supportDir = injected == null
        ? await getApplicationSupportDirectory()
        : null;
    final acquire =
        _acquireInstanceLock ?? (injected == null ? _defaultAcquire : null);
    if (acquire != null) {
      // 先拿鎖再碰保險庫：拿不到就連讀都不讀，避免兩個程序交錯改寫 vault.json。
      final dir = supportDir ?? injected!.root.parent;
      try {
        instanceLock = acquire(dir);
        if (instanceLock == null) {
          blockedReason =
              'Nook 已經在執行中。請切換到已開啟的 Nook 視窗；'
              '同時開兩個可能讓保險庫的設定或主密碼互相覆蓋。';
        }
      } on FileSystemException catch (e) {
        blockedReason =
            '無法建立單一執行個體鎖（${e.path ?? dir.path}：'
            '${e.osError?.message ?? e.message}），為了不讓保險庫被同時改寫，'
            '這次不開啟。';
      }
      if (blockedReason != null) {
        phase = VaultPhase.blocked;
        notifyListeners();
        return;
      }
    }

    // 用平台的路徑分隔符號，設定頁顯示、複製出去的路徑在 Windows 上才不會混著 / 與 \。
    store =
        injected ??
        VaultStore(
          Directory('${supportDir!.path}${Platform.pathSeparator}vault'),
        );
    final exists = store.exists;
    if (exists) await _checkPermissions();
    phase = exists ? VaultPhase.locked : VaultPhase.needsSetup;
    notifyListeners();

    if (exists) store.loadSettingsSync();
    darkAppearance = store.settings.darkAppearance;
    biometricAvailable = await biometrics.isAvailable;
    biometricArmed = biometricAvailable && await biometrics.hasStoredKey;
    clipboard.clearAfter = const Duration(seconds: 30);
    notifyListeners();
  }

  // ------------------------------------------------------------ 解鎖 / 上鎖

  Future<bool> createVault(String password) async {
    return _guard(() async {
      final preferredAppearance = darkAppearance;
      await store.create(password);
      // create() 裡已經收過權限，這裡只把結果帶到畫面上。
      permissionWarning = store.permissionProblem;
      settings.darkAppearance = preferredAppearance;
      if (!preferredAppearance) await store.saveSettings();
      _afterUnlock();
      return true;
    });
  }

  Future<void> _checkPermissions() async {
    await store.restrictPermissions();
    permissionWarning = store.permissionProblem;
  }

  Future<bool> unlock(String password) async {
    return _guard(() async {
      await store.unlock(password);
      _afterUnlock();
      return true;
    });
  }

  void setWindowVisible(bool visible) {
    if (windowVisible == visible) return;
    windowVisible = visible;
    if (visible && _autoUnlockPending) {
      _autoUnlockPending = false;
      unawaited(unlockWithBiometrics());
    }
  }

  /// 鎖定畫面出現時先用 Touch ID 問一次。視窗藏在狀態列時先記著，
  /// 開回來的那一刻再問，不然系統對話框會無緣無故跳出來。
  void autoUnlockWithBiometrics() {
    if (phase != VaultPhase.locked || !biometricArmed) return;
    if (!windowVisible) {
      _autoUnlockPending = true;
      return;
    }
    unawaited(unlockWithBiometrics());
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
    _autoUnlockPending = false;
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
    // 被單一執行個體鎖擋下時根本沒有 store，也不能因為「上鎖」就跳到可以輸入主密碼的畫面。
    if (phase == VaultPhase.blocked) return;
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

  Future<void> toggleAppearance() async {
    darkAppearance = !darkAppearance;
    settings.darkAppearance = darkAppearance;
    notifyListeners();
    if (store.exists) await store.saveSettings();
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
      final error = await biometrics.enroll(dek);
      if (error != null) return error;
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

  Future<void> copySecret(
    String value, {
    required String label,
    VaultItem? item,
  }) async {
    touch();
    await clipboard.copy(value, label: label);
    if (item != null) await markAccessed(item);
    notifyListeners();
  }

  /// 記錄這筆被真的用過。不動 updatedAt，所以清單排序不會因為看一眼就亂跳。
  Future<void> markAccessed(VaultItem item) async {
    if (!store.isUnlocked) return;
    item.lastAccessedAt = DateTime.now();
    await store.put(item, bumpUpdated: false);
    notifyListeners();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    clipboard.dispose();
    super.dispose();
  }
}
