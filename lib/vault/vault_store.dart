import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'models.dart';
import 'vault_crypto.dart';

/// 不含機密的設定，跟 KDF 參數一起放在 vault.json 的明文區。
class VaultSettings {
  VaultSettings({
    this.autoLockSeconds = 300,
    this.clipboardClearSeconds = 30,
    this.biometricEnabled = false,
    this.lockOnAppSwitch = false,
    this.darkAppearance = true,
  });

  int autoLockSeconds;
  int clipboardClearSeconds;
  bool biometricEnabled;

  /// 一切換到別的 app 就立刻上鎖。預設關閉 —— macOS 只要焦點離開就會回報
  /// hidden，開著的話 ⌘Tab 一次就被鎖掉，日常用起來很痛苦。
  bool lockOnAppSwitch;

  /// UI 外觀不是機密，跟其他偏好一起放在 vault.json 的公開設定區。
  bool darkAppearance;

  Map<String, dynamic> toJson() => {
    'autoLockSeconds': autoLockSeconds,
    'clipboardClearSeconds': clipboardClearSeconds,
    'biometricEnabled': biometricEnabled,
    'lockOnAppSwitch': lockOnAppSwitch,
    'darkAppearance': darkAppearance,
  };

  factory VaultSettings.fromJson(Map<String, dynamic>? json) {
    if (json == null) return VaultSettings();
    return VaultSettings(
      autoLockSeconds: json['autoLockSeconds'] as int? ?? 300,
      clipboardClearSeconds: json['clipboardClearSeconds'] as int? ?? 30,
      biometricEnabled: json['biometricEnabled'] as bool? ?? false,
      lockOnAppSwitch: json['lockOnAppSwitch'] as bool? ?? false,
      darkAppearance: json['darkAppearance'] as bool? ?? true,
    );
  }
}

/// 加密保險庫的讀寫。
///
/// 磁碟長這樣：
///   root 底下的 vault.json 是明文，只有版本、KDF 參數、被包住的 DEK、設定
///   root/items/「id」.item 每筆項目一個檔，整包密文，連名稱都在裡面
///
/// 每筆一個檔是為了跨機同步時能逐筆合併（lib/sync/sync_engine.dart）。
class VaultStore {
  VaultStore(
    this.root, {
    KdfParams Function()? kdfFactory,
    bool? ownerOnlyPermissions,
    String chmodExecutable = '/bin/chmod',
  }) : _kdfFactory = kdfFactory ?? KdfParams.fresh,
       _ownerOnly = ownerOnlyPermissions ?? Platform.isLinux,
       _chmod = chmodExecutable;

  final Directory root;

  /// 把保險庫目錄收成只有自己能進（0700）。
  ///
  /// Linux 的 ~/.local/share 底下預設依 umask 建成 0755／0644，同機其他帳號
  /// 讀得到密文與 vault.json。內容雖然都加密了，也沒理由讓別人拿去離線暴力破解。
  /// macOS 有沙盒容器擋著、Windows 的 %APPDATA% 本來就只有本人有權限，所以預設
  /// 只在 Linux 做；測試可以強制打開來驗證。
  final bool _ownerOnly;

  /// 只為了讓測試能換成會失敗的指令，驗證失敗真的會被看見。
  final String _chmod;

  /// 上一次收權限沒成功的原因；成功或不適用時是 null。設定頁會顯示它。
  String? permissionProblem;

  /// vault.json 的「讀出 → 改 → 寫回」在同一個程序裡也要排隊。
  /// 換主密碼要算好幾百毫秒的 KDF，這段時間裡存設定若插隊，後寫的會蓋掉先寫的。
  /// 跨程序的部分由 InstanceLock（單一執行個體）擋。
  Future<void>? _manifestBusy;

  /// 怎麼產生新的 KDF 參數。預設是正式強度；UI 測試會換成輕量版，
  /// 不然幾個測試檔平行跑的時候每個都在算 128 MiB，機器會被壓垮。
  /// 真正的強度由 vault_test 把關。
  final KdfParams Function() _kdfFactory;

  File get _manifestFile => File('${root.path}/vault.json');
  Directory get _itemsDir => Directory('${root.path}/items');

  KdfParams? _kdfParams;
  SecretKey? _dek;

  /// 最後一次換主密碼（重新包 DEK）的時間。同步時用來決定哪一份金鑰包裝比較新：
  /// 一台換了主密碼，另一台要跟著換，而不是被舊的蓋回去。舊版保險庫沒有這個欄位，
  /// 當成 epoch。
  DateTime _keyChangedAt = _epoch;
  static final _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  /// 項目檔的寫入要排隊：同步會在背景套用別台的版本，跟使用者存檔同時發生時，
  /// 兩邊的暫存檔 rename 到同一個目標，誰後完成不一定 —— 磁碟上留的可能跟
  /// 記憶體裡的不是同一份。排成一列就不會。
  Future<void>? _itemsBusy;
  VaultSettings _settings = VaultSettings();
  final Map<String, VaultItem> _items = {};

  bool get exists => _manifestFile.existsSync();
  bool get isUnlocked => _dek != null;
  VaultSettings get settings => _settings;

  /// 解鎖後才有內容；上鎖時這裡是空的。
  List<VaultItem> get items {
    final list = _items.values.toList();
    list.sort((a, b) {
      final byTime = b.updatedAt.compareTo(a.updatedAt);
      // 同一毫秒寫進去的項目若不定序，列表每次重排都會跳動。
      return byTime != 0 ? byTime : a.name.compareTo(b.name);
    });
    return list;
  }

  VaultItem? byId(String id) => _items[id];

  // ---------------------------------------------------------------- 建立

  /// 建立全新的保險庫。目錄已經有 vault.json 就拒絕，免得蓋掉現有資料。
  Future<void> create(String password) => _serialized(() => _create(password));

  Future<void> _create(String password) async {
    if (exists) {
      throw const VaultOpenException('這個位置已經有保險庫了');
    }
    await root.create(recursive: true);
    await _itemsDir.create(recursive: true);
    await restrictPermissions();

    final params = _kdfFactory();
    final kek = await VaultCrypto.deriveKek(password, params);
    final dek = await VaultCrypto.newDek();
    final wrapped = await VaultCrypto.seal(kek, dek);

    _kdfParams = params;
    _dek = SecretKey(dek);
    _settings = VaultSettings();
    _keyChangedAt = DateTime.now().toUtc();
    _items.clear();

    await _writeManifest(wrapped);
  }

  /// 在新機器上加入既有的保險庫：金鑰包裝取自同步資料夾，DEK 由呼叫端用主密碼
  /// 解開並驗證過。設定用這台的預設值（設定不同步，各台各自保管）。
  /// 目錄已經有保險庫就拒絕 —— 兩個 DEK 不同的保險庫沒辦法合併。
  Future<void> createFromKeyMaterial({
    required KdfParams kdf,
    required List<int> wrappedDek,
    required DateTime keyChangedAt,
    required List<int> dek,
  }) => _serialized(() async {
    if (exists) {
      throw const VaultOpenException('這台機器已經有保險庫了');
    }
    await root.create(recursive: true);
    await _itemsDir.create(recursive: true);
    await restrictPermissions();
    _kdfParams = kdf;
    _dek = SecretKey(List<int>.of(dek));
    _settings = VaultSettings();
    _keyChangedAt = keyChangedAt.toUtc();
    _items.clear();
    await _writeManifest(wrappedDek);
  });

  // ---------------------------------------------------------------- 解鎖

  /// 用主密碼解鎖。密碼錯會丟 [VaultOpenException]，訊息不區分錯在哪。
  Future<void> unlock(String password) async {
    final manifest = await _readManifest();
    final params = KdfParams.fromJson(manifest['kdf'] as Map<String, dynamic>);
    final kek = await VaultCrypto.deriveKek(password, params);
    final wrapped = base64Decode(manifest['wrappedDek'] as String);
    final dek = await VaultCrypto.open(kek, wrapped);

    _kdfParams = params;
    _dek = SecretKey(dek);
    _keyChangedAt = _readKeyChangedAt(manifest);
    _settings = VaultSettings.fromJson(
      manifest['settings'] as Map<String, dynamic>?,
    );
    await _loadItems();
  }

  /// 給 Touch ID 用：直接拿 Keychain 裡存的 DEK 解鎖，不經過主密碼。
  Future<void> unlockWithDek(List<int> dek) async {
    final manifest = await _readManifest();
    _kdfParams = KdfParams.fromJson(manifest['kdf'] as Map<String, dynamic>);
    _keyChangedAt = _readKeyChangedAt(manifest);
    _dek = SecretKey(dek);
    _settings = VaultSettings.fromJson(
      manifest['settings'] as Map<String, dynamic>?,
    );
    try {
      await _loadItems();
    } catch (_) {
      // Keychain 裡那份跟保險庫對不上，當作沒解鎖。
      lock();
      rethrow;
    }
  }

  /// 清掉記憶體裡的金鑰與已解密的項目。
  void lock() {
    _dek = null;
    _items.clear();
  }

  /// 把 DEK 交出去存進 Keychain。只在使用者開啟 Touch ID 時呼叫。
  Future<List<int>> exportDek() async {
    _requireUnlocked();
    return _dek!.extractBytes();
  }

  // ---------------------------------------------------------------- 項目

  /// [bumpUpdated] 為 false 時不動 updatedAt —— 記錄「被存取過」用的，
  /// 看一眼不該讓它在清單裡跳到最前面。
  ///
  /// updatedAt 一律存 UTC，而且每次修改都比上一版大（至少 +1 ms）：同步靠它判斷
  /// 「這是不是比上次同步過的版本還新」，兩台機器的時鐘或時區不一致時，
  /// 用 DateTime.now() 直接蓋可能讓新版本的時間反而比舊版本早。
  /// 時間戳在呼叫的當下就改（同步的），寫檔才排隊 —— 背景同步要能立刻看出
  /// 「這筆剛被改過」，不能拿別台的版本蓋掉它。
  Future<void> put(VaultItem item, {bool bumpUpdated = true}) {
    _requireUnlocked();
    if (bumpUpdated) item.updatedAt = nextUpdatedAt(item.updatedAt);
    return _itemsSerialized(() => _writeItem(item));
  }

  /// 比 [previous] 晚、而且不早於現在的 UTC 時間。
  static DateTime nextUpdatedAt(DateTime previous) {
    final now = DateTime.now().toUtc();
    final floor = previous.toUtc().add(const Duration(milliseconds: 1));
    return now.isAfter(floor) ? now : floor;
  }

  Future<void> delete(String id) {
    _requireUnlocked();
    return _itemsSerialized(() async {
      final file = File('${_itemsDir.path}/$id.item');
      if (file.existsSync()) await file.delete();
      _items.remove(id);
    });
  }

  /// 同步專用：只有在本機這筆仍是 [expected]（同一個物件、updatedAt 也沒變；
  /// 或兩者都不存在）時，才換成 [replacement]（null 代表刪除）。回傳有沒有套用。
  ///
  /// 檢查放在排隊之後才做：同步決定要套用別台的版本，到真的寫進去之間，使用者
  /// 可能剛好存了檔。那種情況放棄這次，下一輪同步會再比一次。
  /// 換進來的版本保留本機的 lastAccessedAt —— 那是這台自己的使用紀錄，不同步。
  Future<bool> applySynced(
    String id, {
    required VaultItem? expected,
    required DateTime? expectedUpdatedAt,
    required VaultItem? replacement,
  }) {
    _requireUnlocked();
    return _itemsSerialized(() async {
      if (_dek == null) return false; // 排隊期間被上鎖了
      final current = _items[id];
      if (!identical(current, expected)) return false;
      // DateTime 的 == 連 UTC／本地旗標都比，同一刻也可能不相等；只比時刻。
      if (current != null &&
          (expectedUpdatedAt == null ||
              !current.updatedAt.isAtSameMomentAs(expectedUpdatedAt))) {
        return false;
      }
      if (replacement == null) {
        final file = File('${_itemsDir.path}/$id.item');
        if (file.existsSync()) await file.delete();
        _items.remove(id);
        return true;
      }
      replacement.lastAccessedAt = current?.lastAccessedAt;
      await _writeItem(replacement);
      return true;
    });
  }

  Future<void> _writeItem(VaultItem item) async {
    final dek = _dek;
    if (dek == null) throw const VaultOpenException('保險庫是鎖著的');
    await _itemsDir.create(recursive: true);
    final sealed = await VaultCrypto.seal(
      dek,
      utf8.encode(jsonEncode(item.toJson())),
    );
    await _writeAtomic(File('${_itemsDir.path}/${item.id}.item'), sealed);
    _items[item.id] = item;
  }

  // ---------------------------------------------------------------- 同步用

  /// 用 DEK 加密任意資料。同步資料夾裡的項目、刪除標記與金鑰包裝的認證都用它。
  Future<Uint8List> sealWithDek(List<int> plaintext) {
    _requireUnlocked();
    return VaultCrypto.seal(_dek!, plaintext);
  }

  /// [sealWithDek] 的反向。不是這把 DEK 封的、或被改過，丟 [VaultOpenException]。
  Future<Uint8List> openWithDek(Uint8List sealed) {
    _requireUnlocked();
    return VaultCrypto.open(_dek!, sealed);
  }

  /// [dek] 是不是這個保險庫的 DEK：拿它試解本機的一個項目檔。
  /// 沒有任何項目時無從比對，回 true（空保險庫換哪把都不會壞掉資料）。
  /// 不需要解鎖 —— 給「主密碼在別台換過」的解鎖備案用。
  Future<bool> dekMatchesLocalItems(List<int> dek) async {
    final (opened, total) = await _countOpenable(dek);
    return total == 0 || opened > 0;
  }

  /// [dek] 有沒有被證明是這個保險庫的：至少打開了一個項目檔。
  /// 空保險庫證明不了，回 false —— 重設主密碼時不能拿一把沒驗過的金鑰去換掉真的包裝。
  /// 某幾個檔壞了（被截斷、半同步）不影響判斷：只要有一個打得開就算數。
  Future<bool> dekProvenByItems(List<int> dek) async {
    final (opened, _) = await _countOpenable(dek);
    return opened > 0;
  }

  Future<(int, int)> _countOpenable(List<int> dek) async {
    if (!_itemsDir.existsSync()) return (0, 0);
    final files = _itemsDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.item'))
        .toList();
    var opened = 0;
    for (final file in files) {
      try {
        await VaultCrypto.open(SecretKey(dek), await file.readAsBytes());
        opened++;
        break; // 一個就夠證明了
      } on VaultOpenException {
        continue;
      }
    }
    return (opened, files.length);
  }

  /// 目前磁碟上的金鑰包裝（KDF 參數、被包住的 DEK、換密碼時間）。
  /// 一律從磁碟讀：另一個流程（例如剛套用了別台換過的主密碼）可能改過它。
  Future<KeyMaterial> readKeyMaterial() async {
    final manifest = await _readManifest();
    return KeyMaterial(
      kdf: KdfParams.fromJson(manifest['kdf'] as Map<String, dynamic>),
      wrappedDek: base64Decode(manifest['wrappedDek'] as String),
      keyChangedAt: _readKeyChangedAt(manifest),
    );
  }

  /// 換成別台機器換過主密碼後的金鑰包裝。DEK 不變，所以項目檔一個都不用動，
  /// Touch ID 存的那份也照樣能用；之後解鎖要用新的主密碼。
  /// 呼叫端必須先驗證過這份包裝出自持有同一把 DEK 的 Nook（見 SyncEngine）。
  Future<void> adoptKeyMaterial(KeyMaterial material) => _serialized(() async {
    final current = await _readManifest();
    if (!material.keyChangedAt.isAfter(_readKeyChangedAt(current))) return;
    _kdfParams = material.kdf;
    _keyChangedAt = material.keyChangedAt.toUtc();
    await _writeManifest(material.wrappedDek);
  });

  // ---------------------------------------------------------------- 維護

  /// 換主密碼。只重新包一次 DEK，項目檔一個都不用動。
  Future<void> changePassword(String oldPassword, String newPassword) =>
      _serialized(() => _changePassword(oldPassword, newPassword));

  Future<void> _changePassword(String oldPassword, String newPassword) async {
    final manifest = await _readManifest();
    final params = KdfParams.fromJson(manifest['kdf'] as Map<String, dynamic>);
    final oldKek = await VaultCrypto.deriveKek(oldPassword, params);
    final wrapped = base64Decode(manifest['wrappedDek'] as String);
    final dek = await VaultCrypto.open(oldKek, wrapped);

    final freshParams = _kdfFactory();
    final newKek = await VaultCrypto.deriveKek(newPassword, freshParams);
    final rewrapped = await VaultCrypto.seal(newKek, dek);

    _kdfParams = freshParams;
    _keyChangedAt = nextUpdatedAt(_readKeyChangedAt(manifest));
    await _writeManifest(rewrapped);
  }

  /// 忘記主密碼時換上新的：把 [dek] 用新密碼重新包一次，不需要舊密碼，上鎖狀態也能做。
  ///
  /// 只有已經用別的方式拿到 DEK 的時候才走得到（目前是 Touch ID 存在 Keychain 的那份），
  /// 呼叫端要先用 [dekProvenByItems] 確認它真的是這個保險庫的。拿得到 DEK 的人本來就
  /// 看得到全部資料，所以這不是新的後門，只是讓那條路也能換鎖。項目檔一個都不用動，
  /// DEK 不變，Touch ID 之後照樣能用。換密碼時間往前推，用了同步的話其他機器會跟著換。
  ///
  /// 刻意不先解鎖：解鎖要把每個項目都解開，只要有一個檔壞了就整個失敗 —— 那會讓
  /// 「主密碼忘了」加上「有一筆壞掉」變成連重設都做不了。
  Future<void> resetPassword(String newPassword, {required List<int> dek}) =>
      _serialized(() async {
    final manifest = await _readManifest();
    final freshParams = _kdfFactory();
    final newKek = await VaultCrypto.deriveKek(newPassword, freshParams);
    final rewrapped = await VaultCrypto.seal(newKek, dek);
    _kdfParams = freshParams;
    _keyChangedAt = nextUpdatedAt(_readKeyChangedAt(manifest));
    // 設定以磁碟上的為準（上鎖時記憶體裡可能是開機時讀的舊值）。
    _settings = VaultSettings.fromJson(
      manifest['settings'] as Map<String, dynamic>?,
    );
    await _writeManifest(rewrapped);
  });

  Future<void> saveSettings() => _serialized(_saveSettings);

  Future<void> _saveSettings() async {
    final manifest = await _readManifest();
    // KDF 參數一定要跟 wrappedDek 取自同一份 manifest。若沿用記憶體裡的舊值，
    // 磁碟上的 manifest 被換過主密碼之後（例如從備份還原、或單一執行個體保護失效），
    // 這裡會把舊 salt 配上新 wrappedDek 寫回去，新舊密碼就都打不開了。
    _kdfParams = KdfParams.fromJson(manifest['kdf'] as Map<String, dynamic>);
    _keyChangedAt = _readKeyChangedAt(manifest);
    await _writeManifest(base64Decode(manifest['wrappedDek'] as String));
  }

  /// 設定本來就在 vault.json 的明文區；鎖定畫面需要先知道外觀，因此不解密
  /// 任何項目也能讀取。這個方法不會設定 DEK，也不會載入項目。
  Future<void> loadSettings() async {
    loadSettingsSync();
  }

  /// 啟動畫面只需讀取很小的公開 manifest。同步版本讓 widget test 的假時鐘
  /// 與正式啟動流程都不必等待檔案事件迴圈；不會讀取或解密任何項目。
  void loadSettingsSync() {
    if (!exists) throw const VaultOpenException('這裡還沒有保險庫');
    final raw = _manifestFile.readAsStringSync();
    final manifest = jsonDecode(raw) as Map<String, dynamic>;
    final version = manifest['version'] as int? ?? 0;
    if (version != 1) {
      throw VaultOpenException('不認得的保險庫格式版本：$version');
    }
    _kdfParams = KdfParams.fromJson(manifest['kdf'] as Map<String, dynamic>);
    _keyChangedAt = _readKeyChangedAt(manifest);
    _settings = VaultSettings.fromJson(
      manifest['settings'] as Map<String, dynamic>?,
    );
  }

  /// 保險庫目錄存在時把權限收成 0700。從別台機器複製過來的資料夾也一樣處理，
  /// 所以開機時也會呼叫。
  ///
  /// 回傳 true 代表事後重新 stat 確認過權限就是 0700（或這個平台不適用）。
  /// 不只看 chmod 的退出碼：指令「成功」但檔案系統不支援（例如掛載的 FAT／SMB）
  /// 也會被抓到。失敗時回 false、把原因放進 [permissionProblem]，不擋解鎖 ——
  /// 權限是額外的一層，不是加密本身 —— 但絕不假裝已經收緊。
  ///
  /// 刻意用同步的 runSync：chmod 只要幾毫秒，而非同步的 Process.run 在
  /// widget test 的假時鐘下永遠不會完成，開機流程會卡在 loading（在 Linux 上實測踩到）。
  Future<bool> restrictPermissions() async {
    permissionProblem = null;
    if (!_ownerOnly || !root.existsSync()) return true;
    String? reason;
    try {
      final result = Process.runSync(_chmod, ['700', root.path]);
      if (result.exitCode != 0) {
        final err = '${result.stderr}'.trim();
        reason =
            'chmod 失敗（退出碼 ${result.exitCode}）${err.isEmpty ? '' : '：$err'}';
      }
    } on ProcessException catch (e) {
      reason = '無法執行 chmod：${e.message}';
    }
    final mode = root.statSync().mode & 0x1FF; // 0777
    if (reason == null && mode != 0x1C0) {
      // 0700
      reason = 'chmod 回報成功，但目錄權限仍是 ${mode.toRadixString(8).padLeft(3, '0')}';
    }
    if (reason != null) {
      permissionProblem =
          '保險庫資料夾沒能收成只限本人存取（0700）。$reason。'
          '同一台機器的其他帳號可能讀得到密文，請手動確認權限。';
      stderr.writeln('Nook: $permissionProblem');
      return false;
    }
    return true;
  }

  // ---------------------------------------------------------------- 內部

  void _requireUnlocked() {
    if (_dek == null) throw const VaultOpenException('保險庫是鎖著的');
  }

  Future<Map<String, dynamic>> _readManifest() async {
    if (!exists) throw const VaultOpenException('這裡還沒有保險庫');
    final raw = await _manifestFile.readAsString();
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final version = json['version'] as int? ?? 0;
    if (version != 1) {
      throw VaultOpenException('不認得的保險庫格式版本：$version');
    }
    return json;
  }

  Future<void> _writeManifest(List<int> wrappedDek) async {
    final json = {
      'version': 1,
      'kdf': _kdfParams!.toJson(),
      'wrappedDek': base64Encode(wrappedDek),
      'keyChangedAt': _keyChangedAt.toUtc().toIso8601String(),
      'settings': _settings.toJson(),
    };
    await _writeAtomic(
      _manifestFile,
      utf8.encode(const JsonEncoder.withIndent('  ').convert(json)),
    );
  }

  Future<void> _loadItems() async {
    _items.clear();
    if (!_itemsDir.existsSync()) return;
    final files = _itemsDir.listSync().whereType<File>().where(
      (f) => f.path.endsWith('.item'),
    );
    for (final file in files) {
      final sealed = await file.readAsBytes();
      final clear = await VaultCrypto.open(_dek!, sealed);
      final item = VaultItem.fromJson(
        jsonDecode(utf8.decode(clear)) as Map<String, dynamic>,
      );
      _items[item.id] = item;
    }
  }

  static DateTime _readKeyChangedAt(Map<String, dynamic> manifest) {
    final raw = manifest['keyChangedAt'] as String?;
    return raw == null ? _epoch : DateTime.parse(raw).toUtc();
  }

  /// 跟 [_serialized] 同一個寫法，排的是項目檔。
  Future<T> _itemsSerialized<T>(Future<T> Function() action) async {
    while (_itemsBusy != null) {
      await _itemsBusy;
    }
    final done = Completer<void>();
    _itemsBusy = done.future;
    try {
      return await action();
    } finally {
      _itemsBusy = null;
      done.complete();
    }
  }

  /// 沒有人在改 manifest 時直接執行，不先等任何既有的 Future —— 預先建好的
  /// Future 會綁在建立它的 zone 上，widget test 的假時鐘下會永遠等不到。
  Future<T> _serialized<T>(Future<T> Function() action) async {
    while (_manifestBusy != null) {
      await _manifestBusy;
    }
    final done = Completer<void>();
    _manifestBusy = done.future;
    try {
      return await action();
    } finally {
      _manifestBusy = null;
      done.complete();
    }
  }

  static final _tmpRandom = Random.secure();

  /// 先寫暫存檔再 rename，避免寫到一半斷電把原檔毀掉。
  ///
  /// 暫存檔名每次都不同（程序 ID＋亂數）：固定的 `.tmp` 會讓兩次寫入互相
  /// 蓋掉或搶 rename。失敗時把暫存檔清掉，不留垃圾在保險庫裡。
  Future<void> _writeAtomic(File target, List<int> bytes) async {
    final nonce = _tmpRandom.nextInt(1 << 32).toRadixString(16);
    final tmp = File('${target.path}.$pid.$nonce.tmp');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(target.path);
    } catch (_) {
      if (tmp.existsSync()) {
        try {
          tmp.deleteSync();
        } catch (_) {}
      }
      rethrow;
    }
  }
}

/// 讓外部不必知道 Uint8List 細節。
typedef SealedBytes = Uint8List;

/// 保險庫的金鑰包裝：從主密碼推出 KEK 的參數、被 KEK 包住的 DEK，以及最後一次
/// 換主密碼的時間。不含任何能直接解開資料的東西。
class KeyMaterial {
  const KeyMaterial({
    required this.kdf,
    required this.wrappedDek,
    required this.keyChangedAt,
  });

  final KdfParams kdf;
  final List<int> wrappedDek;
  final DateTime keyChangedAt;
}
