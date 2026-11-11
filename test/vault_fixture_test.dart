import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:securemanage/vault/models.dart';
import 'package:securemanage/vault/vault_crypto.dart';
import 'package:securemanage/vault/vault_store.dart';

/// 凍結的測試保險庫（test/fixtures/vault_v1，由 tool/make_vault_fixture.dart 產生）。
///
/// 守兩件事：
///   1. 現行程式碼還打得開既有格式（vault.json 版本 1、SM01 檔頭）。改了格式卻
///      沒做相容，這裡會先壞，而不是使用者升級後才發現打不開。
///   2. 跨平台搬移就是「整個 vault/ 複製過去」。同一個測試在 macOS、Windows、
///      Linux 各跑一次，就是在驗那台機器能解開別台產生的檔案。
///
/// 樣本與主密碼都是捏造的公開測試資料。
const fixturePassword = 'fixture-master-pw-not-a-secret';
final fixtureDir = Directory('test/fixtures/vault_v1');

/// 模擬使用者手動搬資料夾：逐檔複製，不保留任何中繼資料。
void copyTree(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final entity in from.listSync(recursive: true)) {
    final relative = entity.path.substring(from.path.length + 1);
    final target = '${to.path}${Platform.pathSeparator}$relative';
    if (entity is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (entity is File) {
      File(target).parent.createSync(recursive: true);
      entity.copySync(target);
    }
  }
}

void main() {
  late Directory tmp;
  late Directory copied;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('securemanage_fixture_');
    copied = Directory('${tmp.path}${Platform.pathSeparator}vault');
    copyTree(fixtureDir, copied);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('樣本檔還是版本 1、每個 .item 都以 SM01 開頭', () {
    final manifest =
        jsonDecode(File('${fixtureDir.path}/vault.json').readAsStringSync())
            as Map<String, dynamic>;
    expect(manifest['version'], 1);
    expect((manifest['kdf'] as Map)['algorithm'], 'argon2id');

    final items = Directory('${fixtureDir.path}/items')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.item'))
        .toList();
    expect(items, hasLength(3));
    for (final file in items) {
      expect(utf8.decode(file.readAsBytesSync().sublist(0, 4)), 'SM01');
    }
  });

  test('複製過來的保險庫用原本的主密碼解得開，內容一字不差', () async {
    final store = VaultStore(copied, ownerOnlyPermissions: false);
    expect(store.exists, isTrue);
    await store.unlock(fixturePassword);

    final key = store.byId('fixture-key-0001') as SecureKeyItem;
    expect(key.name, '樣本金鑰');
    expect(key.secret, 'FAKE-FIXTURE-KEY-BODY');
    expect(key.passphrase, 'fake-fixture-passphrase');

    final account = store.byId('fixture-account-0001') as AccountItem;
    expect(account.url, 'https://example.test/login');
    expect(account.username, 'fixture-user');
    expect(account.password, 'fake-fixture-password');

    final host = store.byId('fixture-host-0001') as HostItem;
    expect(host.hostname, '198.51.100.7');
    expect(host.port, 2222);
    expect(host.keyRef, key.id);
    expect(host.sudoPassword, 'fake-fixture-sudo');
    expect(host.env.map((e) => '${e.name}:${e.secret}'), [
      'APP_ENV:false',
      'API_TOKEN:true',
    ]);
  });

  test('主密碼錯就打不開', () async {
    final store = VaultStore(copied, ownerOnlyPermissions: false);
    await expectLater(
      store.unlock('fixture-master-pw-WRONG'),
      throwsA(isA<VaultOpenException>()),
    );
    expect(store.isUnlocked, isFalse);
  });

  test('在新機器上改寫、換主密碼之後，重開仍然讀得回來', () async {
    final store = VaultStore(
      copied,
      kdfFactory: KdfParams.weakForTests,
      ownerOnlyPermissions: false,
    );
    await store.unlock(fixturePassword);
    final account = store.byId('fixture-account-0001') as AccountItem;
    account.password = 'fake-rotated-password';
    await store.put(account);
    await store.changePassword(fixturePassword, 'fake-new-master-pw');
    store.lock();

    final reopened = VaultStore(copied, ownerOnlyPermissions: false);
    await reopened.unlock('fake-new-master-pw');
    expect(
      (reopened.byId('fixture-account-0001') as AccountItem).password,
      'fake-rotated-password',
    );
    expect(reopened.items, hasLength(3));

    // 改的是複本，樣本本身不能被動到。
    final original = VaultStore(fixtureDir, ownerOnlyPermissions: false);
    await original.unlock(fixturePassword);
    expect(
      (original.byId('fixture-account-0001') as AccountItem).password,
      'fake-fixture-password',
    );
  });

  test('記憶體裡的 KDF 已過期時存設定，不能把舊 salt 配上新 wrappedDek', () async {
    // 這是「先後」執行的回歸測試，不是並發測試：兩個 store 輪流動同一份 manifest。
    // 真正的跨程序並發由 InstanceLock（單一執行個體）擋下，見 instance_lock_test。
    final a = VaultStore(
      copied,
      kdfFactory: KdfParams.weakForTests,
      ownerOnlyPermissions: false,
    );
    final b = VaultStore(copied, ownerOnlyPermissions: false);
    await a.unlock(fixturePassword);
    await b.unlock(fixturePassword);

    await a.changePassword(fixturePassword, 'fake-new-master-pw');
    b.settings.autoLockSeconds = 600;
    await b.saveSettings();

    final reopened = VaultStore(copied, ownerOnlyPermissions: false);
    await reopened.unlock('fake-new-master-pw');
    expect(reopened.items, hasLength(3));
    expect(reopened.settings.autoLockSeconds, 600);
  });

  test('同一個程序裡換主密碼與存設定同時發出，會排隊而不是互相覆蓋', () async {
    final store = VaultStore(
      copied,
      kdfFactory: KdfParams.weakForTests,
      ownerOnlyPermissions: false,
    );
    await store.unlock(fixturePassword);

    // 不 await 第一個就送出第二個。沒有排隊的話，saveSettings 會在 changePassword
    // 算 KDF 的空檔讀到舊 manifest 並先寫完；兩邊的「讀出 → 寫回」交錯，誰後寫
    // 誰贏。排隊之後，後送出的一定等前一個寫完才開始讀。
    final order = <String>[];
    store.settings.autoLockSeconds = 900;
    final rotate = store
        .changePassword(fixturePassword, 'fake-queued-pw')
        .then((_) => order.add('rotate'));
    final save = store.saveSettings().then((_) => order.add('save'));
    await Future.wait([rotate, save]);
    expect(order, ['rotate', 'save']);

    final reopened = VaultStore(copied, ownerOnlyPermissions: false);
    await reopened.unlock('fake-queued-pw');
    expect(reopened.items, hasLength(3));
    expect(reopened.settings.autoLockSeconds, 900);
    await expectLater(
      VaultStore(copied, ownerOnlyPermissions: false).unlock(fixturePassword),
      throwsA(isA<Object>()),
    );
  });

  test('寫入不留下暫存檔，也不再使用固定的 .tmp 路徑', () async {
    final store = VaultStore(
      copied,
      kdfFactory: KdfParams.weakForTests,
      ownerOnlyPermissions: false,
    );
    await store.unlock(fixturePassword);
    // 舊版固定寫 vault.json.tmp；若有殘留檔佔著那個名字，新版也不能受影響。
    // 用平台分隔符組路徑：Windows 上 listSync 回的是 `\`，混用 `/` 下面的路徑
    // 比對會對不上，把這個刻意放的殘留檔誤判成新留下的暫存檔。
    final legacyTmp = File(
      '${copied.path}${Platform.pathSeparator}vault.json.tmp',
    )..writeAsStringSync('leftover');
    await Future.wait([
      for (var i = 0; i < 8; i++) store.saveSettings(),
      for (final item in store.items) store.put(item, bumpUpdated: false),
    ]);
    final leftovers = copied
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.tmp') && f.path != legacyTmp.path);
    expect(leftovers, isEmpty);
    expect(legacyTmp.readAsStringSync(), 'leftover');

    final reopened = VaultStore(copied, ownerOnlyPermissions: false);
    await reopened.unlock(fixturePassword);
    expect(reopened.items, hasLength(3));
  });

  group('只限本人存取（Linux 預設開啟）', () {
    test(
      '新建保險庫的目錄是 0700',
      () async {
        final root = Directory('${tmp.path}/fresh');
        final store = VaultStore(
          root,
          kdfFactory: KdfParams.weakForTests,
          ownerOnlyPermissions: true,
        );
        await store.create('fake-perm-test-pw');
        expect(root.statSync().modeString(), 'rwx------');
      },
      skip: Platform.isWindows
          ? 'Windows 靠 %APPDATA% 的 ACL，沒有 POSIX 權限'
          : false,
    );

    test(
      '從別台機器複製過來、權限太寬的保險庫，開啟時會被收緊',
      () async {
        await Process.run('/bin/chmod', ['755', copied.path]);
        expect(copied.statSync().modeString(), 'rwxr-xr-x');

        final store = VaultStore(copied, ownerOnlyPermissions: true);
        expect(await store.restrictPermissions(), isTrue);
        expect(store.permissionProblem, isNull);
        expect(copied.statSync().modeString(), 'rwx------');

        await store.unlock(fixturePassword);
        expect(store.items, hasLength(3));
      },
      skip: Platform.isWindows
          ? 'Windows 靠 %APPDATA% 的 ACL，沒有 POSIX 權限'
          : false,
    );

    test(
      'chmod 失敗（非零退出碼）時回報失敗，不宣稱已收緊',
      () async {
        await Process.run('/bin/chmod', ['755', copied.path]);
        // /usr/bin/false 一定以 1 結束，模擬 chmod 被拒。
        final store = VaultStore(
          copied,
          ownerOnlyPermissions: true,
          chmodExecutable: '/usr/bin/false',
        );
        expect(await store.restrictPermissions(), isFalse);
        expect(store.permissionProblem, contains('退出碼 1'));
        expect(copied.statSync().modeString(), 'rwxr-xr-x');

        // 權限是額外一層，失敗不擋解鎖。
        await store.unlock(fixturePassword);
        expect(store.items, hasLength(3));
      },
      skip: Platform.isWindows ? '沒有 POSIX 權限' : false,
    );

    test('chmod 回報成功但權限沒變時，事後檢查會抓到', () async {
      await Process.run('/bin/chmod', ['755', copied.path]);
      // /usr/bin/true 什麼都不做就以 0 結束，像掛載在不支援權限的檔案系統上。
      final store = VaultStore(
        copied,
        ownerOnlyPermissions: true,
        chmodExecutable: '/usr/bin/true',
      );
      expect(await store.restrictPermissions(), isFalse);
      expect(store.permissionProblem, contains('仍是 755'));
    }, skip: Platform.isWindows ? '沒有 POSIX 權限' : false);

    test('找不到 chmod 時回報失敗', () async {
      final store = VaultStore(
        copied,
        ownerOnlyPermissions: true,
        chmodExecutable: '/nonexistent/chmod',
      );
      expect(await store.restrictPermissions(), isFalse);
      expect(store.permissionProblem, contains('無法執行 chmod'));
    }, skip: Platform.isWindows ? '沒有 POSIX 權限' : false);

    test('不指定時只在 Linux 收權限，其他平台不動目錄', () async {
      final before = copied.statSync().modeString();
      await VaultStore(copied).restrictPermissions();
      expect(
        copied.statSync().modeString(),
        Platform.isLinux ? 'rwx------' : before,
      );
    });
  });
}
