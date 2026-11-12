import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import '../app/platform_profile.dart';

/// Touch ID 解鎖。
///
/// 要講清楚它保護到什麼程度：主密碼仍然是唯一能解開資料的金鑰，這裡只是把
/// 資料金鑰（DEK）另外存一份在 macOS Keychain，通過 Touch ID 之後才拿出來用。
/// Keychain 那份是綁在你的 macOS 帳號下的，所以「你的 Mac 已登入且被別人碰到」
/// 這個情境下，它的保護力比主密碼弱。預設關閉，要自己去設定裡開。
///
/// 只有 macOS 啟用（見 [PlatformProfile.supportsQuickUnlock]）。Windows／Linux
/// 上所有查詢一律回「沒有」，也不會碰 local_auth 或安全儲存的通道 ——
/// Windows Hello 不會綁住存起來的 DEK，Linux 沒有 local_auth 實作，
/// 在另行設計金鑰保護之前不能把它們包裝成「快速解鎖」。
class BiometricGate {
  BiometricGate({
    LocalAuthentication? auth,
    FlutterSecureStorage? storage,
    bool? platformSupported,
  })  : _platformSupported =
            platformSupported ?? PlatformProfile.current.supportsQuickUnlock,
        _auth = auth ?? LocalAuthentication(),
        _storage = storage ??
            const FlutterSecureStorage(
              mOptions: MacOsOptions(
                accountName: 'tw.com.jetopto.nook',
                accessibility: KeychainAccessibility.first_unlock_this_device,
                synchronizable: false,
                // 預設走 data protection keychain，但那條路要有 Team ID 的簽章
                // （keychain-access-groups）才寫得進去；本機 ad-hoc 簽的 app
                // 會吃到 errSecMissingEntitlement (-34018)，Touch ID 永遠開不起來。
                // 走傳統的 login keychain，沙盒 app 存自己的項目不需要額外 entitlement。
                usesDataProtectionKeychain: false,
              ),
            );

  final bool _platformSupported;

  /// 這個平台有沒有 Touch ID 這條路（只有 macOS）。不探測硬體，也不碰 Keychain。
  bool get isPlatformSupported => _platformSupported;

  final LocalAuthentication _auth;
  final FlutterSecureStorage _storage;

  static const _dekKey = 'vault_dek_v1';

  /// 生物辨識與 Keychain 都是跨平台通道，卡住的話整個 app 會開不起來。
  /// 一律加逾時，超時就當作沒有，退回主密碼。
  static const _probeTimeout = Duration(seconds: 3);

  Future<T> _probe<T>(Future<T> Function() action, T fallback) async {
    try {
      return await action().timeout(_probeTimeout, onTimeout: () => fallback);
    } catch (_) {
      return fallback;
    }
  }

  /// 這台機器有沒有 Touch ID 可用。不支援的平台直接回 false，不探測。
  Future<bool> get isAvailable => _probe(() async {
        if (!_platformSupported) return false;
        if (!await _auth.isDeviceSupported()) return false;
        final kinds = await _auth.getAvailableBiometrics();
        return kinds.contains(BiometricType.strong) ||
            kinds.contains(BiometricType.fingerprint) ||
            kinds.contains(BiometricType.face);
      }, false);

  Future<bool> get hasStoredKey => _probe(() async {
        if (!_platformSupported) return false;
        return (await _storage.read(key: _dekKey)) != null;
      }, false);

  /// 開啟 Touch ID：先驗一次生物辨識，過了才把 DEK 放進 Keychain。
  /// 回 null 表示成功，否則是給使用者看的失敗原因。
  Future<String?> enroll(List<int> dek) async {
    if (!_platformSupported) return '這個平台沒有提供快速解鎖，請用主密碼';
    if (!await _authenticate('確認是本人，才會把解鎖金鑰交給 Touch ID')) {
      return 'Touch ID 沒有通過，維持關閉';
    }
    try {
      await _storage.write(key: _dekKey, value: base64Encode(dek));
    } catch (e) {
      // Keychain 寫不進去不能悄悄吞掉：開關會停在關閉，使用者卻不知道為什麼。
      return '寫入 Keychain 失敗，維持關閉（${_describe(e)}）';
    }
    return null;
  }

  static String _describe(Object e) {
    final text = e.toString();
    return text.length > 120 ? '${text.substring(0, 120)}…' : text;
  }

  /// 關閉 Touch ID，把 Keychain 裡那份刪掉。
  Future<void> forget() async {
    if (!_platformSupported) return;
    await _storage.delete(key: _dekKey);
  }

  /// Touch ID 解鎖。沒通過或 Keychain 裡沒東西就回 null，呼叫端退回主密碼。
  /// [reason] 是系統對話框上的說明。
  ///
  /// 讀 Keychain 這一步刻意不加逾時：換過版本的 app 第一次讀時，macOS 會先問
  /// 登入密碼，要等使用者回應。
  Future<List<int>?> unlock({String reason = '用 Touch ID 解鎖 Nook'}) async {
    if (!_platformSupported) return null;
    final stored = await _storage.read(key: _dekKey);
    if (stored == null) return null;
    if (!await _authenticate(reason)) return null;
    return base64Decode(stored);
  }

  /// 給「忘記主密碼」用：讀出 Keychain 裡的 DEK，並把失敗原因分清楚，
  /// 讓畫面說得出是「沒有存」「Touch ID 沒過」還是「macOS 不讓讀」。
  Future<KeychainDek> readDek({required String reason}) async {
    if (!_platformSupported) return const KeychainDek(KeychainDekStatus.notStored);
    final String? stored;
    try {
      stored = await _storage.read(key: _dekKey);
    } catch (e) {
      return KeychainDek(KeychainDekStatus.keychainError, message: _describe(e));
    }
    if (stored == null) return const KeychainDek(KeychainDekStatus.notStored);
    if (!await _authenticate(reason)) {
      return const KeychainDek(KeychainDekStatus.denied);
    }
    return KeychainDek(KeychainDekStatus.ok, dek: base64Decode(stored));
  }

  Future<bool> _authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        // 允許退回輸入 Mac 密碼，不然 Touch ID 認不出來就卡死。
        biometricOnly: false,
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      return false;
    }
  }
}

enum KeychainDekStatus { ok, notStored, denied, keychainError }

/// [BiometricGate.readDek] 的結果。
class KeychainDek {
  const KeychainDek(this.status, {this.dek, this.message});
  final KeychainDekStatus status;
  final List<int>? dek;

  /// [KeychainDekStatus.keychainError] 時，macOS 回報的原因。
  final String? message;
}
