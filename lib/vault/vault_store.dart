import 'dart:convert';
import 'dart:io';
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
  });

  int autoLockSeconds;
  int clipboardClearSeconds;
  bool biometricEnabled;

  /// 一切換到別的 app 就立刻上鎖。預設關閉 —— macOS 只要焦點離開就會回報
  /// hidden，開著的話 ⌘Tab 一次就被鎖掉，日常用起來很痛苦。
  bool lockOnAppSwitch;

  Map<String, dynamic> toJson() => {
        'autoLockSeconds': autoLockSeconds,
        'clipboardClearSeconds': clipboardClearSeconds,
        'biometricEnabled': biometricEnabled,
        'lockOnAppSwitch': lockOnAppSwitch,
      };

  factory VaultSettings.fromJson(Map<String, dynamic>? json) {
    if (json == null) return VaultSettings();
    return VaultSettings(
      autoLockSeconds: json['autoLockSeconds'] as int? ?? 300,
      clipboardClearSeconds: json['clipboardClearSeconds'] as int? ?? 30,
      biometricEnabled: json['biometricEnabled'] as bool? ?? false,
      lockOnAppSwitch: json['lockOnAppSwitch'] as bool? ?? false,
    );
  }
}

/// 加密保險庫的讀寫。
///
/// 磁碟長這樣：
///   root 底下的 vault.json 是明文，只有版本、KDF 參數、被包住的 DEK、設定
///   root/items/「id」.item 每筆項目一個檔，整包密文，連名稱都在裡面
///
/// 每筆一個檔是為了之後要做跨機同步時好合併，現在不實作同步，但格式先留著。
class VaultStore {
  VaultStore(this.root, {KdfParams Function()? kdfFactory})
      : _kdfFactory = kdfFactory ?? KdfParams.fresh;

  final Directory root;

  /// 怎麼產生新的 KDF 參數。預設是正式強度；UI 測試會換成輕量版，
  /// 不然幾個測試檔平行跑的時候每個都在算 128 MiB，機器會被壓垮。
  /// 真正的強度由 vault_test 把關。
  final KdfParams Function() _kdfFactory;

  File get _manifestFile => File('${root.path}/vault.json');
  Directory get _itemsDir => Directory('${root.path}/items');

  KdfParams? _kdfParams;
  SecretKey? _dek;
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
  Future<void> create(String password) async {
    if (exists) {
      throw const VaultOpenException('這個位置已經有保險庫了');
    }
    await root.create(recursive: true);
    await _itemsDir.create(recursive: true);

    final params = _kdfFactory();
    final kek = await VaultCrypto.deriveKek(password, params);
    final dek = await VaultCrypto.newDek();
    final wrapped = await VaultCrypto.seal(kek, dek);

    _kdfParams = params;
    _dek = SecretKey(dek);
    _settings = VaultSettings();
    _items.clear();

    await _writeManifest(wrapped);
  }

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
    _settings = VaultSettings.fromJson(
        manifest['settings'] as Map<String, dynamic>?);
    await _loadItems();
  }

  /// 給 Touch ID 用：直接拿 Keychain 裡存的 DEK 解鎖，不經過主密碼。
  Future<void> unlockWithDek(List<int> dek) async {
    final manifest = await _readManifest();
    _kdfParams = KdfParams.fromJson(manifest['kdf'] as Map<String, dynamic>);
    _dek = SecretKey(dek);
    _settings = VaultSettings.fromJson(
        manifest['settings'] as Map<String, dynamic>?);
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
  Future<void> put(VaultItem item, {bool bumpUpdated = true}) async {
    _requireUnlocked();
    if (bumpUpdated) item.updatedAt = DateTime.now();
    await _itemsDir.create(recursive: true);
    final sealed = await VaultCrypto.seal(
      _dek!,
      utf8.encode(jsonEncode(item.toJson())),
    );
    await _writeAtomic(File('${_itemsDir.path}/${item.id}.item'), sealed);
    _items[item.id] = item;
  }

  Future<void> delete(String id) async {
    _requireUnlocked();
    final file = File('${_itemsDir.path}/$id.item');
    if (file.existsSync()) await file.delete();
    _items.remove(id);
  }

  // ---------------------------------------------------------------- 維護

  /// 換主密碼。只重新包一次 DEK，項目檔一個都不用動。
  Future<void> changePassword(String oldPassword, String newPassword) async {
    final manifest = await _readManifest();
    final params = KdfParams.fromJson(manifest['kdf'] as Map<String, dynamic>);
    final oldKek = await VaultCrypto.deriveKek(oldPassword, params);
    final wrapped = base64Decode(manifest['wrappedDek'] as String);
    final dek = await VaultCrypto.open(oldKek, wrapped);

    final freshParams = _kdfFactory();
    final newKek = await VaultCrypto.deriveKek(newPassword, freshParams);
    final rewrapped = await VaultCrypto.seal(newKek, dek);

    _kdfParams = freshParams;
    await _writeManifest(rewrapped);
  }

  Future<void> saveSettings() async {
    final manifest = await _readManifest();
    await _writeManifest(base64Decode(manifest['wrappedDek'] as String));
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
    final files = _itemsDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.item'));
    for (final file in files) {
      final sealed = await file.readAsBytes();
      final clear = await VaultCrypto.open(_dek!, sealed);
      final item = VaultItem.fromJson(
          jsonDecode(utf8.decode(clear)) as Map<String, dynamic>);
      _items[item.id] = item;
    }
  }

  /// 先寫暫存檔再 rename，避免寫到一半斷電把原檔毀掉。
  Future<void> _writeAtomic(File target, List<int> bytes) async {
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(target.path);
  }
}

/// 讓外部不必知道 Uint8List 細節。
typedef SealedBytes = Uint8List;
