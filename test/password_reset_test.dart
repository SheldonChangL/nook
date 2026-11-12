import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:securemanage/app/app_state.dart';
import 'package:securemanage/main.dart';
import 'package:securemanage/services/biometric_gate.dart';
import 'package:securemanage/sync/sync_engine.dart';
import 'package:securemanage/vault/models.dart';
import 'package:securemanage/vault/vault_crypto.dart';
import 'package:securemanage/vault/vault_store.dart';

/// 忘記主密碼、用 Touch ID 存的那份 DEK 設定新的主密碼。全部用假資料。
const forgotten = 'fake-forgotten-master-password-1';
const fresh = 'fake-new-master-password-2';

/// 假的 Touch ID：記著一份 DEK，可以設定成「不通過」。也記下有沒有人想刪掉它。
class FakeTouchId extends BiometricGate {
  FakeTouchId(this.dek, {bool supported = true})
      : super(platformSupported: supported);
  List<int>? dek;
  bool approve = true;

  /// 模擬 macOS 不讓讀鑰匙圈（例如使用者在存取對話框按了拒絕）。
  bool keychainDenied = false;
  int forgetCalls = 0;
  String? lastReason;

  @override
  Future<bool> get isAvailable async => true;
  @override
  Future<bool> get hasStoredKey async => dek != null;
  @override
  Future<List<int>?> unlock({String reason = ''}) async {
    lastReason = reason;
    return approve ? dek : null;
  }

  @override
  Future<KeychainDek> readDek({required String reason}) async {
    lastReason = reason;
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
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  VaultStore newStore() => VaultStore(vault,
      kdfFactory: KdfParams.weakForTests, ownerOnlyPermissions: false);

  /// 再加幾筆，好讓「壞一筆、其他還好」的情境成立。
  Future<void> addItems(List<int> dek, int n) async {
    final s = newStore();
    await s.unlockWithDek(dek);
    for (var i = 0; i < n; i++) {
      await s.put(AccountItem(name: '假帳號 $i', password: 'fake-$i'));
    }
    s.lock();
  }

  /// 建一個開過 Touch ID 的保險庫，回傳 Keychain 會存的那份 DEK。
  Future<List<int>> seed({bool biometricEnabled = true}) async {
    final s = newStore();
    await s.create(forgotten);
    await s.put(AccountItem(name: '假帳號', password: 'fake-secret'));
    s.settings.biometricEnabled = biometricEnabled;
    await s.saveSettings();
    final dek = await s.exportDek();
    s.lock();
    return dek;
  }

  group('VaultStore.resetPassword', () {
    test('換上新密碼：舊的失效、新的可用、資料與 DEK 不變、換密碼時間往前', () async {
      final dek = await seed();
      final s = newStore();
      final before = await s.readKeyMaterial();
      await s.resetPassword(fresh, dek: dek); // 上鎖狀態，不必先解鎖
      final after = await s.readKeyMaterial();
      expect(after.keyChangedAt.isAfter(before.keyChangedAt), isTrue);
      expect(s.settings.biometricEnabled, isTrue, reason: '設定要保留');

      s.lock();
      await expectLater(s.unlock(forgotten), throwsA(isA<VaultOpenException>()));
      await s.unlock(fresh);
      expect((s.items.single as AccountItem).password, 'fake-secret');
      s.lock();
      await s.unlockWithDek(dek); // Touch ID 那份照樣能用
      expect(s.items.single.name, '假帳號');
    });

    test('空保險庫證明不了金鑰是對的；有一筆壞掉也不影響證明', () async {
      final dek = await seed();
      final s = newStore();
      expect(await s.dekProvenByItems(dek), isTrue);
      expect(await s.dekProvenByItems(List<int>.filled(32, 7)), isFalse);
      await addItems(dek, 2);
      corruptOneItem(vault, keep: 1);
      expect(await s.dekProvenByItems(dek), isTrue);

      final empty = VaultStore(Directory('${tmp.path}/empty'),
          kdfFactory: KdfParams.weakForTests, ownerOnlyPermissions: false);
      await empty.create(forgotten);
      expect(await empty.dekProvenByItems(await empty.exportDek()), isFalse);
    });
  });

  group('AppState', () {
    Future<AppState> boot(FakeTouchId gate) async {
      final state = AppState(store: newStore(), biometrics: gate);
      await state.boot();
      return state;
    }

    test('開過 Touch ID：通過後換上新密碼並解鎖', () async {
      final gate = FakeTouchId(await seed());
      final state = await boot(gate);
      expect(state.phase, VaultPhase.locked);
      expect(state.canResetWithBiometrics, isTrue);

      expect(await state.resetPasswordWithBiometrics(fresh), isTrue);
      expect(state.phase, VaultPhase.unlocked);
      expect(gate.lastReason, contains('新的主密碼'));
      state.lock();
      expect(await state.unlock(forgotten), isFalse);
      expect(await state.unlock(fresh), isTrue);
      state.dispose();
    });

    test('開機探測 Keychain 失敗（例如換版後要先允許）也照樣看得到重設入口', () async {
      final gate = _ProbeFails(await seed());
      final state = AppState(store: newStore(), biometrics: gate);
      await state.boot();
      expect(state.biometricArmed, isFalse);
      expect(state.canResetWithBiometrics, isTrue);
      expect(await state.resetPasswordWithBiometrics(fresh), isTrue);
      state.dispose();
    });

    test('Touch ID 沒通過：維持上鎖，密碼不變，Keychain 那份不刪', () async {
      final gate = FakeTouchId(await seed())..approve = false;
      final state = await boot(gate);
      expect(await state.resetPasswordWithBiometrics(fresh), isFalse);
      expect(state.phase, VaultPhase.locked);
      expect(state.unlockError, contains('Touch ID 沒有通過'));
      expect(gate.forgetCalls, 0);
      expect(await state.unlock(forgotten), isTrue, reason: '舊密碼還是有效');
      state.dispose();
    });

    test('Keychain 那份跟保險庫對不上：不重設，也不刪掉它', () async {
      await seed();
      final gate = FakeTouchId(List<int>.filled(32, 7));
      final state = await boot(gate);
      expect(await state.resetPasswordWithBiometrics(fresh), isFalse);
      expect(state.phase, VaultPhase.locked);
      expect(gate.forgetCalls, 0);
      expect(gate.dek, isNotNull);
      expect(await state.unlock(forgotten), isTrue);
      state.dispose();
    });

    test('一般的 Touch ID 解鎖遇到壞掉的項目檔：絕不刪掉 Keychain 那份', () async {
      final dek = await seed();
      await addItems(dek, 2);
      corruptOneItem(vault, keep: 2);
      final gate = FakeTouchId(dek);
      final state = await boot(gate);
      expect(state.biometricArmed, isTrue);
      expect(await state.unlockWithBiometrics(), isFalse);
      expect(gate.forgetCalls, 0);
      expect(gate.dek, isNotNull);
      expect(state.phase, VaultPhase.locked);
      state.dispose();
    });

    test('有一筆壞掉也能重設：主密碼換好了，並說明有檔案讀不出來', () async {
      final dek = await seed();
      await addItems(dek, 2);
      corruptOneItem(vault, keep: 2);
      final gate = FakeTouchId(dek);
      final state = await boot(gate);
      expect(await state.resetPasswordWithBiometrics(fresh), isFalse);
      expect(state.unlockError, contains('主密碼已換成新的'));
      expect(state.store.isUnlocked, isFalse);
      expect(gate.forgetCalls, 0);
      // 新的包裝確實是用新密碼包住同一把 DEK。
      final km = await newStore().readKeyMaterial();
      final kek = await VaultCrypto.deriveKek(fresh, km.kdf);
      final opened = await VaultCrypto.open(kek, Uint8List.fromList(km.wrappedDek));
      expect(opened, dek);
      state.dispose();
    });

    test('Keychain 裡沒有金鑰、或 macOS 不讓讀：各有清楚的訊息，什麼都不改', () async {
      final dek = await seed();
      final missing = FakeTouchId(dek)..dek = null;
      final s1 = await boot(missing);
      expect(await s1.resetPasswordWithBiometrics(fresh), isFalse);
      expect(s1.unlockError, contains('鑰匙圈裡沒有'));
      s1.dispose();

      final denied = FakeTouchId(dek)..keychainDenied = true;
      final s2 = await boot(denied);
      expect(await s2.resetPasswordWithBiometrics(fresh), isFalse);
      expect(s2.unlockError, contains('沒讓 Nook 讀鑰匙圈'));
      expect(await s2.unlock(forgotten), isTrue, reason: '舊密碼還是有效');
      s2.dispose();
    });

    test('寫入新的包裝失敗：維持上鎖，記憶體裡沒有留下解開的資料', () async {
      final dek = await seed();
      final gate = FakeTouchId(dek);
      final state = await boot(gate);
      Process.runSync('chmod', ['555', vault.path]);
      addTearDown(() => Process.runSync('chmod', ['755', vault.path]));
      expect(await state.resetPasswordWithBiometrics(fresh), isFalse);
      expect(state.phase, VaultPhase.locked);
      expect(state.store.isUnlocked, isFalse);
      expect(state.items, isEmpty);
      Process.runSync('chmod', ['755', vault.path]);
      expect(await state.unlock(forgotten), isTrue, reason: '舊密碼還是有效');
      state.dispose();
    }, skip: Platform.isWindows);

    test('空保險庫：沒辦法證明金鑰是對的，不重設', () async {
      final s = newStore();
      await s.create(forgotten);
      s.settings.biometricEnabled = true;
      await s.saveSettings();
      s.lock();
      final gate = FakeTouchId(List<int>.filled(32, 9));
      final state = await boot(gate);
      expect(await state.resetPasswordWithBiometrics(fresh), isFalse);
      expect(state.unlockError, contains('打不開'));
      expect(await state.unlock(forgotten), isTrue);
      state.dispose();
    });

    test('沒開過 Touch ID、或不是 Mac：沒有重設入口', () async {
      final notEnabled = await boot(FakeTouchId(await seed(biometricEnabled: false)));
      expect(notEnabled.canResetWithBiometrics, isFalse);
      expect(await notEnabled.resetPasswordWithBiometrics(fresh), isFalse);
      notEnabled.dispose();

      tmp.deleteSync(recursive: true);
      tmp.createSync();
      final notMac = await boot(FakeTouchId(await seed(), supported: false));
      expect(notMac.canResetWithBiometrics, isFalse);
      notMac.dispose();
    });
  });

  test('用了同步：一台用 Touch ID 重設後，另一台用新密碼就能解開', () async {
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
    expect(b.items.single.name, '假帳號');
  });

  testWidgets('鎖定畫面：點「忘記主密碼」→ 輸入新密碼 → Touch ID → 解鎖', (tester) async {
    late List<int> dek;
    await tester.runAsync(() async => dek = await seed());
    // 開機探測 Keychain 失敗：也就是換版後的真實情境。（探測成功的話，鎖定畫面會直接
    // 自動跳 Touch ID 解鎖，根本輪不到按「忘記主密碼」。）
    final gate = _ProbeFails(dek);
    final state = AppState(store: newStore(), biometrics: gate);
    await tester.runAsync(state.boot);
    await tester.pumpWidget(NookApp(state: state));
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }

    final link = find.byKey(const ValueKey('reset-with-touch-id'));
    expect(link, findsOneWidget);
    await tester.tap(link);
    // 鎖定畫面有持續的動畫，pumpAndSettle 永遠等不到靜止；固定推幾格就好。
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(find.text('用 Touch ID 設定新的主密碼'), findsOneWidget);

    final fields = find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextField));
    // 太短會被擋下。
    await tester.enterText(fields.at(0), 'short');
    await tester.enterText(fields.at(1), 'short');
    await tester.tap(find.byKey(const ValueKey('new-password-confirm')));
    await tester.pump();
    expect(find.byKey(const ValueKey('new-password-error')), findsOneWidget);

    await tester.enterText(fields.at(0), fresh);
    await tester.enterText(fields.at(1), fresh);
    await tester.tap(find.byKey(const ValueKey('new-password-confirm')));
    // 對話框要先關掉（需要推畫面），重設才會開始；重設裡的金鑰衍生要真的時間。
    // 兩者交替，直到解鎖。
    for (var i = 0; i < 300 && state.phase != VaultPhase.unlocked; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(state.phase, VaultPhase.unlocked);
    expect(gate.lastReason, contains('新的主密碼'));
    state.lock();
    await tester.pump();
    await tester.runAsync(() async {
      expect(await state.unlock(fresh), isTrue);
    });
    state.lock();
    await tester.pump(const Duration(milliseconds: 200));
  });
}

/// 開機時探測 Keychain 逾時或失敗（例如換版後 macOS 先要求允許存取）。
class _ProbeFails extends FakeTouchId {
  _ProbeFails(super.dek);
  @override
  Future<bool> get hasStoredKey async => false;
}

/// 把保險庫裡的項目檔截斷到只剩幾個 byte（像是半同步、寫到一半），留下 [keep] 個完好的。
void corruptOneItem(Directory vault, {required int keep}) {
  final files = Directory('${vault.path}/items')
      .listSync()
      .whereType<File>()
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  expect(files.length, greaterThan(keep));
  final victim = files[keep];
  victim.writeAsBytesSync(victim.readAsBytesSync().sublist(0, 10));
}
