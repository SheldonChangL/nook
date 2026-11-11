import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../services/biometric_gate.dart';
import 'instance_lock.dart';
import '../services/clipboard_guard.dart';
import '../sync/sync_engine.dart';
import '../sync/sync_setup.dart';
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
    FolderAccess? folderAccess,
  }) : _injectedStore = store,
       _acquireInstanceLock = acquireInstanceLock,
       biometrics = biometrics ?? BiometricGate(),
       clipboard = clipboard ?? ClipboardGuard(),
       folderAccess = folderAccess ?? PlatformFolderAccess();

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
  final FolderAccess folderAccess;

  // ------------------------------------------------------------ 同步的狀態

  /// 放 nook.lock、sync.json、sync-state.bin 的地方（保險庫資料夾的上一層）。
  late Directory _supportDir;
  SyncConfig? _syncConfig;
  SyncEngine? _syncEngine;

  /// 同步資料夾的實際路徑（設定頁顯示用）。沒設定同步時是 null。
  String? get syncFolderPath => _syncEngine?.folder.path;
  bool get syncEnabled => _syncEngine != null;
  bool syncing = false;
  SyncReport? lastSync;

  /// 最近一次同步失敗的原因；成功後清掉。
  String? syncError;

  /// 需要使用者知道的事（例如主密碼在另一台換過了）。看過就可以清掉。
  String? syncNotice;

  /// 設定好同步、但這次開機沒能恢復資料夾存取權時的原因。
  String? syncSetupProblem;

  /// 加入流程：選好、確認裡面有同步資料的資料夾，等使用者輸入主密碼。
  Directory? pendingJoinFolder;
  PickedFolder? _pendingJoinPick;

  Timer? _syncTimer;
  Timer? _syncDebounce;
  static const syncInterval = Duration(seconds: 30);

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
    _supportDir = supportDir ?? injected!.root.parent;
    final exists = store.exists;
    if (exists) await _restoreSync();
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
      try {
        await store.unlock(password);
      } on VaultOpenException {
        // 主密碼可能在另一台換過了、這台還沒同步到：用輸入的密碼試同步資料夾裡
        // 比較新的金鑰包裝。解不開就照原本的錯誤回報，不透露試過什麼。
        final engine = _syncEngine;
        var recovered = false;
        if (engine != null) {
          try {
            recovered = await SyncEngine.unlockWithNewerKey(
              store: store,
              folder: engine.folder,
              password: password,
            );
          } catch (_) {
            // 同步資料夾不在、讀不到：照原本的「密碼不對」處理。
          }
        }
        if (!recovered) rethrow;
        syncNotice = '主密碼已在另一台機器更換過，這台也已改用新的主密碼。';
      }
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
    _startSyncLoop();
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
    _stopSyncTimers();
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
    final current = store.byId(item.id);
    if (_syncEngine != null && current != null && !identical(current, item)) {
      // 編輯器開著的這段時間，同步把別台改過的版本拉進來了（換成了新物件）。
      // 照樣存使用者的修改，但別台那份另存成衝突副本，不默默蓋掉。
      final copy = await SyncEngine.conflictCopyOf(current);
      if (store.byId(copy.id) == null) {
        await store.put(copy, bumpUpdated: false);
        syncNotice = '「${current.name}」在你編輯時被另一台機器改過，'
            '那個版本另存為「${copy.name}」。';
      }
      // 編輯器的物件還帶著開啟時的舊時間；別台的時鐘若比較快，從舊時間往上加
      // 可能還是比剛拉進來的版本早，同步會把這次修改當成舊檔丟掉。從兩者較晚的往上蓋。
      if (current.updatedAt.isAfter(item.updatedAt)) {
        item.updatedAt = current.updatedAt;
      }
    }
    await store.put(item);
    notifyListeners();
    _scheduleSync();
  }

  Future<void> remove(String id) async {
    touch();
    await store.delete(id);
    notifyListeners();
    _scheduleSync();
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
      _scheduleSync();
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

  // ------------------------------------------------------------ 同步

  /// 開機時：有設定同步就恢復資料夾存取權。失敗不擋開機，只在設定頁說明。
  Future<void> _restoreSync() async {
    final config = SyncConfig.load(_supportDir);
    if (config == null) return;
    try {
      final restored = await folderAccess.restore(config);
      if (restored.path != config.folder ||
          restored.bookmark != config.bookmark) {
        _syncConfig = SyncConfig(
          folder: restored.path,
          bookmark: restored.bookmark,
        );
        await _syncConfig!.save(_supportDir);
      } else {
        _syncConfig = config;
      }
      _syncEngine = _engineFor(
        SyncEngine.resolveExchange(Directory(restored.path)),
      );
    } on FolderAccessException catch (e) {
      _syncConfig = config;
      syncSetupProblem = e.message;
    }
  }

  SyncEngine _engineFor(Directory exchange) => SyncEngine(
    store: store,
    folder: exchange,
    stateFile: File('${_supportDir.path}${Platform.pathSeparator}sync-state.bin'),
  );

  /// 設定頁「選擇同步資料夾」。回傳錯誤訊息；null 代表成功。
  Future<String?> chooseSyncFolder() async {
    touch();
    final PickedFolder? picked;
    try {
      picked = await folderAccess.pick(prompt: '選一個雲端硬碟裡的資料夾當同步資料夾');
    } catch (e) {
      return '沒辦法開啟資料夾選擇視窗：$e';
    }
    if (picked == null) return null;
    final engine = _engineFor(
      SyncEngine.resolveExchange(Directory(picked.path)),
    );
    try {
      await engine.attach();
    } on SyncException catch (e) {
      return e.message;
    } on FileSystemException catch (e) {
      return '沒辦法寫入這個資料夾：${e.osError?.message ?? e.message}';
    }
    _syncConfig = SyncConfig(folder: picked.path, bookmark: picked.bookmark);
    await _syncConfig!.save(_supportDir);
    _syncEngine = engine;
    syncSetupProblem = null;
    syncError = null;
    _startSyncLoop();
    notifyListeners();
    return null;
  }

  /// 停止同步：這台不再讀寫同步資料夾。本機資料與同步資料夾都原封不動。
  Future<void> stopSync() async {
    _stopSyncTimers();
    await _syncEngine?.forgetState();
    await SyncConfig.clear(_supportDir);
    _syncEngine = null;
    _syncConfig = null;
    lastSync = null;
    syncError = null;
    syncNotice = null;
    syncSetupProblem = null;
    notifyListeners();
  }

  void dismissSyncNotice() {
    syncNotice = null;
    notifyListeners();
  }

  /// 設定好同步後的節奏：解鎖時跑一次，之後每 [syncInterval] 一次，
  /// 改了東西的 2 秒後再一次。上鎖時全部停掉（沒有 DEK 也比對不了）。
  void _startSyncLoop() {
    _stopSyncTimers();
    if (_syncEngine == null || phase != VaultPhase.unlocked) return;
    unawaited(syncNow());
    _syncTimer = Timer.periodic(syncInterval, (_) => unawaited(syncNow()));
  }

  void _scheduleSync() {
    if (_syncEngine == null || phase != VaultPhase.unlocked) return;
    _syncDebounce?.cancel();
    _syncDebounce = Timer(
      const Duration(seconds: 2),
      () => unawaited(syncNow()),
    );
  }

  void _stopSyncTimers() {
    _syncTimer?.cancel();
    _syncTimer = null;
    _syncDebounce?.cancel();
    _syncDebounce = null;
  }

  /// 立刻同步一輪。不算使用者操作，不會把自動上鎖的倒數推回去。
  Future<void> syncNow() async {
    final engine = _syncEngine;
    if (engine == null || !store.isUnlocked) return;
    syncing = true;
    notifyListeners();
    try {
      final report = await engine.sync();
      lastSync = report;
      syncError = null;
      if (report.keyAdopted) {
        syncNotice = '主密碼已在另一台機器更換，下次解鎖請用新的主密碼。';
      } else if (report.conflictCopies.isNotEmpty) {
        syncNotice = '兩台機器改了同一筆，較舊的版本另存為：'
            '${report.conflictCopies.join('、')}。確認後可以刪掉。';
      }
    } on SyncException catch (e) {
      syncError = e.message;
    } on VaultOpenException {
      // 同步到一半被上鎖：這輪作廢，下次解鎖再來。
    } on FileSystemException catch (e) {
      syncError = '讀寫同步資料夾失敗：${e.osError?.message ?? e.message}';
    } catch (e) {
      syncError = '同步失敗：$e';
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  // ------------------------------------------------------------ 加入既有保險庫

  /// 建立畫面「從同步資料夾加入」的第一步：選資料夾，確認裡面真的有同步資料。
  /// 回傳錯誤訊息；null 代表選好了（或使用者取消）。
  Future<String?> pickJoinFolder() async {
    final PickedFolder? picked;
    try {
      picked = await folderAccess.pick(prompt: '選另一台機器設定的那個同步資料夾');
    } catch (e) {
      return '沒辦法開啟資料夾選擇視窗：$e';
    }
    if (picked == null) return null;
    final exchange = SyncEngine.resolveExchange(Directory(picked.path));
    if (!SyncEngine.isExchange(exchange)) {
      return '這個資料夾裡沒有 Nook 的同步資料。請選在另一台機器上設定的那個同步資料夾'
          '（雲端硬碟還在下載的話，等它下載完再試）。';
    }
    pendingJoinFolder = exchange;
    _pendingJoinPick = picked;
    unlockError = null;
    notifyListeners();
    return null;
  }

  void cancelJoin() {
    pendingJoinFolder = null;
    _pendingJoinPick = null;
    unlockError = null;
    notifyListeners();
  }

  /// 用主密碼加入同步資料夾裡的保險庫，成功後解鎖並開始同步（項目會被拉下來）。
  Future<bool> joinVault(String password) async {
    final folder = pendingJoinFolder;
    final picked = _pendingJoinPick;
    if (folder == null || picked == null) return false;
    return _guard(() async {
      final preferredAppearance = darkAppearance;
      await SyncEngine.join(store: store, folder: folder, password: password);
      permissionWarning = store.permissionProblem;
      settings.darkAppearance = preferredAppearance;
      await store.saveSettings();
      _syncConfig = SyncConfig(folder: picked.path, bookmark: picked.bookmark);
      await _syncConfig!.save(_supportDir);
      _syncEngine = _engineFor(folder);
      pendingJoinFolder = null;
      _pendingJoinPick = null;
      _afterUnlock();
      return true;
    });
  }

  bool _disposed = false;

  /// 背景同步可能在 app 收掉（dispose）之後才跑完，那時不能再通知畫面。
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _idleTimer?.cancel();
    _stopSyncTimers();
    clipboard.dispose();
    super.dispose();
  }
}
