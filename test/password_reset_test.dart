import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:securemanage/app/app_state.dart';
import 'package:securemanage/main.dart';
import 'package:securemanage/services/biometric_gate.dart';
import 'package:securemanage/sync/sync_engine.dart';
import 'package:securemanage/vault/models.dart';
import 'package:securemanage/vault/vault_crypto.dart';
import 'package:securemanage/vault/vault_store.dart';

/// 忘了主密碼、但這台 Mac 開過 Touch ID：先用 Touch ID 登入，再到設定裡用 Touch ID
/// 代替舊密碼換上新的。全部用假資料。
const forgotten = 'fake-forgotten-master-password-1';
const fresh = 'fake-new-master-password-2';

/// 假的 Touch ID：記著一份 DEK，可以設定成「不通過」「macOS 不讓讀」。也記下有沒有人想刪掉它。
class FakeTouchId extends BiometricGate {
  FakeTouchId(this.dek, {bool supported = true, this.probeOk = true})
      : super(platformSupported: supported);
  List<int>? dek;
  bool approve = true;
  bool keychainDenied = false;

  /// 開機探測 Keychain 成不成功。換版後第一次讀要先允許，探測常常逾時。
  final bool probeOk;
  int forgetCalls = 0;
  final reasons = <String>[];

  /// 讀 Keychain 時順便發生的事（例如 Touch ID 對話框開著時自動上鎖）。
  void Function()? onRead;

  @override
  Future<bool> get isAvailable async => true;
  @override
  Future<bool> get hasStoredKey async => probeOk && dek != null;
  @override
  Future<KeychainDek> readDek({required String reason}) async {
    reasons.add(reason);
    onRead?.call();
    if (keychainDenied) {
      return const KeychainDek(KeychainDekStatus.keychainError,
          message: 'User canceled the operation');
    }
    if (dek == null) return const KeychainDek(KeychainDekStatus.notStored);
    if (!approve) return const KeychainDek(KeychainDekStatus.denied);
    return KeychainDek(KeychainDekStatus.ok, dek: dek);
  }

  @override
  Future<void> forget() async {
    forgetCalls++;
    dek = null;
  }
}

void main() {
  late Directory tmp;
  late Directory vault;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('nook_reset_');
    vault = Directory('${tmp.path}/vault');
  });
  tearDown(() async {
    // Windows 上檔案剛關閉時可能還被防毒或索引程式握著一下，稍等重試（CI 實測）。
    for (var attempt = 0; tmp.existsSync(); attempt++) {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        if (attempt >= 20) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  VaultStore newStore() => VaultStore(vault,
      kdfFactory: KdfParams.weakForTests, ownerOnlyPermissions: false);

  /// 建一個開過 Touch ID 的保險庫，回傳 Keychain 會存的那份 DEK。
  Future<List<int>> seed({bool biometricEnabled = true, int items = 1}) async {
    final s = newStore();
    await s.create(forgotten);
    for (var i = 0; i < items; i++) {
      await s.put(AccountItem(name: '假帳號 $i', password: 'fake-secret-$i'));
    }
    s.settings.biometricEnabled = biometricEnabled;
    await s.saveSettings();
    final dek = await s.exportDek();
    s.lock();
    return dek;
  }

  test('VaultStore.resetPassword：舊的失效、新的可用、資料與 DEK 不變、換密碼時間往前', () async {
    final dek = await seed();
    final s = newStore();
    final before = await s.readKeyMaterial();
    await s.unlockWithDek(dek);
    await s.resetPassword(fresh, dek: dek);
    final after = await s.readKeyMaterial();
    expect(after.keyChangedAt.isAfter(before.keyChangedAt), isTrue);
    expect(s.settings.biometricEnabled, isTrue, reason: '設定要保留');

    s.lock();
    await expectLater(s.unlock(forgotten), throwsA(isA<VaultOpenException>()));
    await s.unlock(fresh);
    expect((s.items.single as AccountItem).password, 'fake-secret-0');
    s.lock();
    await s.unlockWithDek(dek); // Touch ID 那份照樣能用
  });

  group('AppState', () {
    Future<AppState> boot(FakeTouchId gate) async {
      final state = AppState(store: newStore(), biometrics: gate);
      await state.boot();
      return state;
    }

    test('開機探測 Keychain 失敗（換版後要先允許）：照樣可以用 Touch ID 解鎖', () async {
      final gate = FakeTouchId(await seed(), probeOk: false);
      final state = await boot(gate);
      expect(state.biometricArmed, isFalse);
      expect(state.canUnlockWithBiometrics, isTrue);
      expect(await state.unlockWithBiometrics(), isTrue);
      expect(state.phase, VaultPhase.unlocked);
      expect(state.biometricArmed, isTrue, reason: '設定頁的開關要顯示成開著');
      state.dispose();
    });

    test('用 Touch ID 登入後，在設定用 Touch ID 代替舊密碼換上新的', () async {
      final gate = FakeTouchId(await seed());
      final state = await boot(gate);
      expect(state.canChangePasswordWithBiometrics, isFalse, reason: '鎖著不能改');
      expect(await state.unlockWithBiometrics(), isTrue);
      expect(state.canChangePasswordWithBiometrics, isTrue);

      expect(await state.changeMasterPasswordWithBiometrics(fresh), isNull);
      expect(gate.reasons.last, contains('更改 Nook 的主密碼'),
          reason: '改密碼時要再確認一次 Touch ID');
      state.lock();
      expect(await state.unlock(forgotten), isFalse);
      expect(await state.unlock(fresh), isTrue);
      expect(state.items.single.name, '假帳號 0');
      expect(gate.forgetCalls, 0);
      state.dispose();
    });

    test('改密碼時 Touch ID 沒過、鑰匙圈沒有金鑰或不讓讀：說明原因，什麼都不改', () async {
      final dek = await seed();
      final gate = FakeTouchId(dek);
      final state = await boot(gate);
      await state.unlockWithBiometrics();

      gate.approve = false;
      expect(await state.changeMasterPasswordWithBiometrics(fresh),
          contains('Touch ID 沒有通過'));
      gate.approve = true;
      gate.keychainDenied = true;
      expect(await state.changeMasterPasswordWithBiometrics(fresh),
          contains('沒讓 Nook 讀鑰匙圈'));
      gate.keychainDenied = false;
      gate.dek = null;
      expect(await state.changeMasterPasswordWithBiometrics(fresh),
          contains('鑰匙圈裡沒有'));
      gate.dek = List<int>.filled(32, 7);
      expect(await state.changeMasterPasswordWithBiometrics(fresh),
          contains('對不上'));

      state.lock();
      expect(await state.unlock(forgotten), isTrue, reason: '舊密碼還是有效');
      expect(gate.forgetCalls, 0);
      state.dispose();
    });

    test('設定頁的 Touch ID 開關：開機探測逾時也顯示成開著', () async {
      final gate = FakeTouchId(await seed(), probeOk: false);
      final state = await boot(gate);
      expect(state.biometricArmed, isFalse);
      expect(state.biometricSwitchOn, isTrue);
      expect(await state.unlock(forgotten), isTrue);
      expect(state.biometricSwitchOn, isTrue, reason: '用密碼解鎖後也一樣');
      state.dispose();
    });

    test('改密碼時 Touch ID 對話框開著就自動上鎖：回傳說明，不丟例外、不改任何東西', () async {
      final gate = FakeTouchId(await seed());
      final state = await boot(gate);
      await state.unlockWithBiometrics();
      gate.onRead = state.lock;
      final error = await state.changeMasterPasswordWithBiometrics(fresh);
      expect(error, contains('主密碼沒有變更'));
      gate.onRead = null;
      expect(await state.unlock(forgotten), isTrue);
      state.dispose();
    });

    test('空保險庫證明不了 Touch ID 那份金鑰：不能免舊密碼改密碼', () async {
      final gate = FakeTouchId(await seed(items: 0));
      final state = await boot(gate);
      expect(await state.unlockWithBiometrics(), isTrue);
      expect(await state.changeMasterPasswordWithBiometrics(fresh),
          contains('還沒有資料'));
      state.lock();
      expect(await state.unlock(forgotten), isTrue);
      state.dispose();
    });

    test('Touch ID 解鎖遇到壞掉的項目檔：絕不刪掉 Keychain 那份', () async {
      final dek = await seed(items: 3);
      final files = Directory('${vault.path}/items').listSync().whereType<File>().toList();
      files.first.writeAsBytesSync(files.first.readAsBytesSync().sublist(0, 10));
      final gate = FakeTouchId(dek);
      final state = await boot(gate);
      expect(await state.unlockWithBiometrics(), isFalse);
      expect(state.unlockError, contains('Touch ID 沒能打開'));
      expect(gate.forgetCalls, 0);
      expect(gate.dek, isNotNull);
      expect(state.canUnlockWithBiometrics, isTrue, reason: '按鈕還在，可以再試');
      state.dispose();
    });

    test('Touch ID 解鎖：沒通過就安靜退回主密碼；鑰匙圈沒有或不讓讀會說明', () async {
      final dek = await seed();
      final gate = FakeTouchId(dek)..approve = false;
      final state = await boot(gate);
      expect(await state.unlockWithBiometrics(), isFalse);
      expect(state.unlockError, isNull);

      gate.approve = true;
      gate.keychainDenied = true;
      expect(await state.unlockWithBiometrics(), isFalse);
      expect(state.unlockError, contains('沒讓 Nook 讀鑰匙圈'));

      gate.keychainDenied = false;
      gate.dek = null;
      expect(await state.unlockWithBiometrics(), isFalse);
      expect(state.unlockError, contains('鑰匙圈裡沒有'));
      expect(gate.forgetCalls, 0);
      state.dispose();
    });

    test('沒開過 Touch ID、或不是 Mac：沒有 Touch ID 解鎖，也不能免舊密碼改密碼', () async {
      final notEnabled = await boot(FakeTouchId(await seed(biometricEnabled: false)));
      expect(notEnabled.canUnlockWithBiometrics, isFalse);
      expect(await notEnabled.unlockWithBiometrics(), isFalse);
      expect(await notEnabled.unlock(forgotten), isTrue);
      expect(notEnabled.canChangePasswordWithBiometrics, isFalse);
      expect(await notEnabled.changeMasterPasswordWithBiometrics(fresh), isNotNull);
      notEnabled.dispose();

      tmp.deleteSync(recursive: true);
      tmp.createSync();
      final notMac = await boot(FakeTouchId(await seed(), supported: false));
      expect(notMac.canUnlockWithBiometrics, isFalse);
      notMac.dispose();
    });
  });

  test('用了同步：一台用 Touch ID 改了主密碼，另一台用新密碼就能解開', () async {
    final cloud = Directory('${tmp.path}/cloud/${SyncEngine.defaultSubfolder}');
    final dek = await seed();
    final a = newStore();
    await a.unlockWithDek(dek);
    final engineA = SyncEngine(
        store: a, folder: cloud, stateFile: File('${tmp.path}/a-state.bin'));
    await engineA.attach();
    await engineA.sync();

    final b = VaultStore(Directory('${tmp.path}/b/vault'),
        kdfFactory: KdfParams.weakForTests, ownerOnlyPermissions: false);
    await SyncEngine.join(store: b, folder: cloud, password: forgotten);
    final engineB = SyncEngine(
        store: b, folder: cloud, stateFile: File('${tmp.path}/b-state.bin'));
    await engineB.sync();
    b.lock();

    await a.resetPassword(fresh, dek: dek);
    await engineA.sync();
    expect(
        await SyncEngine.unlockWithNewerKey(store: b, folder: cloud, password: fresh),
        isTrue);
    expect(b.items.single.name, '假帳號 0');
  });

  Future<void> grind(WidgetTester tester, [int rounds = 12]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
  }

  /// 讓需要真實時間的非同步工作（金鑰衍生、檔案）跑完，同時推畫面。
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
  }

  testWidgets('畫面：探測失敗也有 Touch ID 按鈕 → 登入 → 設定改用 Touch ID 換主密碼', (tester) async {
    late List<int> dek;
    await tester.runAsync(() async => dek = await seed());
    final gate = FakeTouchId(dek, probeOk: false);
    final state = AppState(store: newStore(), biometrics: gate);
    await tester.runAsync(state.boot);
    await tester.pumpWidget(NookApp(state: state));
    await grind(tester);

    expect(find.textContaining('忘記主密碼'), findsNothing,
        reason: '鎖定畫面不該有重設入口');
    final touchId = find.text('用 Touch ID 解除鎖定');
    expect(touchId, findsOneWidget);
    await tester.tap(touchId);
    await settle(tester, () => state.phase == VaultPhase.unlocked);
    await grind(tester);
    expect(state.phase, VaultPhase.unlocked);

    await tester.tap(find.text('設定').first);
    await grind(tester);
    await tester.tap(find.text('更改主密碼'));
    await grind(tester);
    await tester.tap(find.byKey(const ValueKey('change-password-use-touch-id')));
    await grind(tester);
    expect(find.byKey(const ValueKey('change-password-touch-id-note')), findsOneWidget);
    final fields = find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextField));
    expect(fields, findsNWidgets(2), reason: '不再要求目前的主密碼');
    await tester.enterText(fields.at(0), fresh);
    await tester.enterText(fields.at(1), fresh);
    await tester.tap(find.widgetWithText(FilledButton, '更改'));
    await settle(tester, () => find.text('主密碼已更換').evaluate().isNotEmpty);
    await grind(tester);
    expect(find.text('主密碼已更換'), findsOneWidget);

    state.lock();
    await grind(tester);
    late bool ok;
    await tester.runAsync(() async => ok = await state.unlock(fresh));
    expect(ok, isTrue);
    state.lock();
    await grind(tester);
  });

  testWidgets('設定頁關掉 Touch ID 前會警告；取消就什麼都不刪', (tester) async {
    late List<int> dek;
    await tester.runAsync(() async => dek = await seed());
    final gate = FakeTouchId(dek, probeOk: false);
    final state = AppState(store: newStore(), biometrics: gate);
    await tester.runAsync(state.boot);
    await tester.pumpWidget(NookApp(state: state));
    await grind(tester);
    await tester.tap(find.text('用 Touch ID 解除鎖定'));
    await settle(tester, () => state.phase == VaultPhase.unlocked);
    await grind(tester);

    await tester.tap(find.text('設定').first);
    await grind(tester);
    final toggle = find.widgetWithText(SwitchListTile, '用 Touch ID 解鎖');
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await tester.tap(toggle);
    await grind(tester);
    expect(find.byKey(const ValueKey('disable-touch-id-warning')), findsOneWidget);
    await tester.tap(find.text('取消'));
    await grind(tester);
    expect(gate.forgetCalls, 0);
    expect(state.settings.biometricEnabled, isTrue);

    state.lock();
    await grind(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
