import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:securemanage/sync/sync_engine.dart';
import 'package:securemanage/vault/models.dart';
import 'package:securemanage/vault/vault_crypto.dart';
import 'package:securemanage/vault/vault_store.dart';

/// 測試一律用捏造的假資料。
const pw = 'correct-horse-battery-staple-9471';
const newPw = 'another-fake-master-password-5521';

/// 一台機器：自己的保險庫、自己的同步基準，共用同一個「雲端」資料夾。
class Machine {
  Machine(this.name, Directory tmp, this.cloud)
      : _store = VaultStore(
          Directory('${tmp.path}/$name/vault'),
          kdfFactory: KdfParams.weakForTests,
        ),
        stateFile = File('${tmp.path}/$name/sync-state.bin');

  final String name;
  final VaultStore _store;
  VaultStore get store => _store;
  final File stateFile;
  final Directory cloud;

  SyncEngine get engine =>
      SyncEngine(store: store, folder: cloud, stateFile: stateFile);

  Future<SyncReport> sync() => engine.sync();

  VaultItem byName(String n) => store.items.firstWhere((i) => i.name == n);
  List<String> get names => store.items.map((i) => i.name).toList()..sort();
}

Future<void> reopen(Machine m, String password) async {
  m.store.lock();
  await m.store.unlock(password);
}

void main() {
  late Directory tmp;
  late Directory cloud;
  late Machine a;
  late Machine b;

  /// A 建保險庫、接上同步；B 從同步資料夾加入。
  Future<void> pair() async {
    await a.store.create(pw);
    await a.engine.attach();
    await a.sync();
    await SyncEngine.join(store: b.store, folder: cloud, password: pw);
    await b.sync();
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('nook_sync_test_');
    cloud = Directory('${tmp.path}/cloud/${SyncEngine.defaultSubfolder}');
    a = Machine('a', tmp, cloud);
    b = Machine('b', tmp, cloud);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('A 的項目同步到新加入的 B，內容一致；設定不跟著走', () async {
    await a.store.create(pw);
    await a.store.put(AccountItem(
        name: '假的 wiki', username: 'tester', password: 'fake-pw-1'));
    await a.store.put(SecureKeyItem(
        name: '假金鑰', keyKind: KeyKind.sshPrivateKey, secret: 'FAKE-KEY'));
    a.store.settings.autoLockSeconds = 1800;
    await a.store.saveSettings();
    await a.engine.attach();
    final first = await a.sync();
    expect(first.pushed, 2);

    await SyncEngine.join(store: b.store, folder: cloud, password: pw);
    final pulled = await b.sync();
    expect(pulled.pulled, 2);
    expect(b.names, ['假的 wiki', '假金鑰']);
    expect((b.byName('假的 wiki') as AccountItem).password, 'fake-pw-1');
    expect(b.store.settings.autoLockSeconds, 300, reason: '設定各台各自保管');

    // 第二輪什麼都不用做。
    final again = await b.sync();
    expect(again.pulled + again.pushed, 0);
  });

  test('同步資料夾裡找不到任何明文', () async {
    await a.store.create(pw);
    await a.store.put(AccountItem(
        name: 'PLAINTEXT-NAME-MARKER',
        username: 'PLAINTEXT-USER-MARKER',
        password: 'PLAINTEXT-SECRET-MARKER'));
    await a.engine.attach();
    await a.sync();
    final item = a.byName('PLAINTEXT-NAME-MARKER');
    await a.store.delete(item.id);
    await a.sync(); // 留下刪除標記
    for (final f in cloud.listSync(recursive: true).whereType<File>()) {
      final raw = latin1.decode(f.readAsBytesSync());
      expect(raw.contains('PLAINTEXT'), isFalse, reason: f.path);
      expect(raw.contains(item.id) && !f.path.contains(item.id), isFalse,
          reason: '檔名以外不該出現 id：${f.path}');
    }
  });

  test('一邊改，另一邊同步後看到新版；本機的 lastAccessedAt 不被蓋掉', () async {
    await a.store.create(pw);
    await a.store.put(AccountItem(name: '帳號', password: 'v1'));
    await a.engine.attach();
    await a.sync();
    await SyncEngine.join(store: b.store, folder: cloud, password: pw);
    await b.sync();

    final onB = b.byName('帳號');
    onB.lastAccessedAt = DateTime.utc(2026, 1, 2);
    await b.store.put(onB, bumpUpdated: false);

    final onA = a.byName('帳號') as AccountItem;
    onA.password = 'v2';
    await a.store.put(onA);
    await a.sync();
    final r = await b.sync();
    expect(r.pulled, 1);
    expect((b.byName('帳號') as AccountItem).password, 'v2');
    expect(b.byName('帳號').lastAccessedAt, DateTime.utc(2026, 1, 2));
  });

  test('只記錄「用過」不會推上雲端，也不會造成衝突', () async {
    await pair();
    await a.store.put(AccountItem(name: '帳號', password: 'v1'));
    await a.sync();
    await b.sync();
    for (final m in [a, b]) {
      final item = m.byName('帳號');
      item.lastAccessedAt = DateTime.now().toUtc();
      await m.store.put(item, bumpUpdated: false);
    }
    final ra = await a.sync();
    final rb = await b.sync();
    expect(ra.pushed + rb.pushed, 0);
    expect(ra.conflictCopies, isEmpty);
    expect(rb.conflictCopies, isEmpty);
  });

  test('刪除會傳過去；刪除標記是密文', () async {
    await pair();
    await a.store.put(AccountItem(name: '要刪的'));
    await a.sync();
    await b.sync();
    expect(b.names, ['要刪的']);

    await a.store.delete(a.byName('要刪的').id);
    final ra = await a.sync();
    expect(ra.deletedRemotely, 1);
    final rb = await b.sync();
    expect(rb.deletedLocally, 1);
    expect(b.names, isEmpty);
    // 再同步幾輪也不會復活。
    await a.sync();
    await b.sync();
    expect(a.names, isEmpty);
    expect(b.names, isEmpty);
  });

  test('兩邊同時改同一筆：較新的贏，另一份存成衝突副本，兩邊各只有一份副本', () async {
    await pair();
    await a.store.put(AccountItem(name: '帳號', password: 'base'));
    await a.sync();
    await b.sync();

    final onA = a.byName('帳號') as AccountItem;
    onA.password = 'from-a';
    await a.store.put(onA);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final onB = b.byName('帳號') as AccountItem;
    onB.password = 'from-b';
    await b.store.put(onB); // B 比較晚改

    await a.sync();
    final rb = await b.sync();
    expect(rb.conflictCopies, ['帳號${SyncEngine.conflictSuffix}']);
    await a.sync();
    await b.sync();

    for (final m in [a, b]) {
      expect(m.names, ['帳號', '帳號${SyncEngine.conflictSuffix}'], reason: m.name);
      expect((m.byName('帳號') as AccountItem).password, 'from-b');
      expect(
          (m.byName('帳號${SyncEngine.conflictSuffix}') as AccountItem).password,
          'from-a');
    }
  });

  test('一邊刪、另一邊改：改過的贏，刪掉的那筆回來', () async {
    await pair();
    await a.store.put(AccountItem(name: '帳號', password: 'base'));
    await a.sync();
    await b.sync();

    await a.store.delete(a.byName('帳號').id);
    final onB = b.byName('帳號') as AccountItem;
    onB.password = 'edited-on-b';
    await b.store.put(onB);

    await a.sync(); // 留下刪除標記
    final rb = await b.sync();
    expect(rb.deletedLocally, 0);
    expect(b.names, ['帳號']);
    await a.sync();
    expect((a.byName('帳號') as AccountItem).password, 'edited-on-b');
  });

  test('雲端服務的衝突檔（Dropbox／iCloud／Google 的命名）都會被合併、清掉', () async {
    await pair();
    await a.store.put(AccountItem(name: '帳號', password: 'base'));
    await a.sync();
    await b.sync();

    // 模擬：兩台各自改完、各自寫進雲端，雲端服務把其中一份另存成衝突檔。
    final onA = a.byName('帳號') as AccountItem;
    onA.password = 'from-a';
    await a.store.put(onA);
    await a.sync();
    final id = onA.id;
    final canonical = File('${cloud.path}/items/$id.item');
    final aBytes = canonical.readAsBytesSync();

    final onB = b.byName('帳號') as AccountItem;
    onB.password = 'from-b';
    await b.store.put(onB);
    // B 推上去之前，先把 A 的版本放回去，B 的版本放到衝突檔名 —— 等同雲端服務的行為。
    await b.sync();
    final bBytes = canonical.readAsBytesSync();
    canonical.writeAsBytesSync(aBytes);
    for (final name in [
      "$id (B's conflicted copy 2026-11-11).item",
      '$id 2.item',
      '$id(1).item',
    ]) {
      File('${cloud.path}/items/$name').writeAsBytesSync(bBytes);
    }

    await a.sync();
    final left = Directory('${cloud.path}/items')
        .listSync()
        .map((e) => e.path.split(RegExp(r'[/\\]')).last)
        .where((n) => n.startsWith(id))
        .toList();
    expect(left, ['$id.item'], reason: '只留正名的檔');
    expect((a.byName('帳號') as AccountItem).password, 'from-b');
    expect(a.names, ['帳號', '帳號${SyncEngine.conflictSuffix}']);
  });

  test('讀不出來的檔（還沒下載完）不刪、不當成刪除，只回報', () async {
    await pair();
    await a.store.put(AccountItem(name: '帳號', password: 'v1'));
    await a.sync();
    await b.sync();
    final id = a.byName('帳號').id;
    final file = File('${cloud.path}/items/$id.item');
    final bytes = file.readAsBytesSync();
    file.writeAsBytesSync(bytes.sublist(0, bytes.length ~/ 2)); // 截斷

    final rb = await b.sync();
    expect(rb.unreadable, ['$id.item']);
    expect(rb.deletedLocally, 0);
    expect(b.names, ['帳號']);
    expect(file.existsSync(), isTrue);
  });

  test('雲端的檔案被刪掉（沒有刪除標記）不算刪除，會被補回去', () async {
    await pair();
    await a.store.put(AccountItem(name: '帳號'));
    await a.sync();
    await b.sync();
    final id = a.byName('帳號').id;
    File('${cloud.path}/items/$id.item').deleteSync();

    await b.sync();
    expect(b.names, ['帳號']);
    expect(File('${cloud.path}/items/$id.item').existsSync(), isTrue);
  });

  test('雲端被回復成舊版：不會拉回舊版，會用本機版本蓋回去', () async {
    await pair();
    await a.store.put(AccountItem(name: '帳號', password: 'old'));
    await a.sync();
    await b.sync();
    final id = a.byName('帳號').id;
    final file = File('${cloud.path}/items/$id.item');
    final oldBytes = file.readAsBytesSync();

    final onA = a.byName('帳號') as AccountItem;
    onA.password = 'new';
    await a.store.put(onA);
    await a.sync();
    await b.sync();

    file.writeAsBytesSync(oldBytes); // 回復成舊版
    final rb = await b.sync();
    expect(rb.pulled, 0);
    expect((b.byName('帳號') as AccountItem).password, 'new');
    await a.sync();
    expect((a.byName('帳號') as AccountItem).password, 'new');
  });

  test('別的保險庫的同步資料夾：拒絕接上', () async {
    final other = Machine('c', tmp, cloud);
    await other.store.create('some-other-fake-password-77');
    await other.engine.attach();
    await other.sync();

    await a.store.create(pw);
    expect(() => a.engine.attach(), throwsA(isA<SyncException>()));
  });

  test('一台換主密碼，另一台同步後跟著換', () async {
    await pair();
    await a.store.put(AccountItem(name: '帳號'));
    await a.sync();
    await b.sync();

    await a.store.changePassword(pw, newPw);
    await a.sync();
    final rb = await b.sync();
    expect(rb.keyAdopted, isTrue);

    b.store.lock();
    await expectLater(b.store.unlock(pw), throwsA(isA<VaultOpenException>()));
    await b.store.unlock(newPw);
    expect(b.names, ['帳號']);
  });

  test('主密碼在別台換過、這台還沒同步：用新密碼也能解鎖', () async {
    await pair();
    await a.store.put(AccountItem(name: '帳號'));
    await a.sync();
    await b.sync();
    b.store.lock();

    await a.store.changePassword(pw, newPw);
    await a.sync();

    await expectLater(b.store.unlock(newPw), throwsA(isA<VaultOpenException>()));
    final ok = await SyncEngine.unlockWithNewerKey(
        store: b.store, folder: cloud, password: newPw);
    expect(ok, isTrue);
    expect(b.store.isUnlocked, isTrue);
    expect(b.names, ['帳號']);
    b.store.lock();
    await b.store.unlock(newPw); // 本機已經換成新的金鑰包裝
  });

  test('解鎖備案不接受舊密碼，也不接受別的保險庫', () async {
    await pair();
    b.store.lock();
    expect(
        await SyncEngine.unlockWithNewerKey(
            store: b.store, folder: cloud, password: pw),
        isFalse,
        reason: '雲端沒有比本機新的金鑰包裝');
    expect(b.store.isUnlocked, isFalse);
  });

  test('竄改同步資料夾的換密碼時間：認證不過，同步停下、本機不變', () async {
    await pair();
    final manifest = File('${cloud.path}/${SyncEngine.manifestName}');
    final json = jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
    json['keyChangedAt'] = '2099-01-01T00:00:00.000Z';
    manifest.writeAsStringSync(jsonEncode(json));

    final before = await b.store.readKeyMaterial();
    await expectLater(b.sync(), throwsA(isA<SyncException>()));
    final after = await b.store.readKeyMaterial();
    expect(after.keyChangedAt, before.keyChangedAt);
  });

  test('同步途中使用者剛好存檔：不會被別台的版本蓋掉', () async {
    await pair();
    await a.store.put(AccountItem(name: '帳號', password: 'base'));
    await a.sync();
    await b.sync();
    final onB = b.byName('帳號') as AccountItem;
    final seenAt = onB.updatedAt;

    // 同步決定要套用別台版本之前，使用者改了這筆。
    onB.password = 'typed-by-user';
    await b.store.put(onB);
    final applied = await b.store.applySynced(onB.id,
        expected: onB,
        expectedUpdatedAt: seenAt,
        replacement: AccountItem(id: onB.id, name: '帳號', password: 'remote'));
    expect(applied, isFalse);
    expect((b.byName('帳號') as AccountItem).password, 'typed-by-user');
  });

  // ---------------------------------------------------------------- 審查抓到的資料遺失案例

  test('同步套用別台版本時被使用者存檔擋下：下一輪仍會比對，兩份都留著', () async {
    final rb = _RacyMachine('rb', tmp, cloud);
    await a.store.create(pw);
    await a.engine.attach();
    await a.store.put(AccountItem(name: 'X', password: 'base'));
    await a.sync();
    await SyncEngine.join(store: rb.store, folder: cloud, password: pw);
    await rb.sync();

    final onA = a.byName('X') as AccountItem;
    onA.password = 'edit-from-A';
    await a.store.put(onA);
    await a.sync();

    final onB = rb.byName('X') as AccountItem;
    rb.racy.beforeApply = () async {
      onB.password = 'edit-from-B';
      await rb.store.put(onB);
    };
    await rb.sync();
    await rb.sync();
    await a.sync();
    await rb.sync();
    for (final m in [a, rb]) {
      final pws =
          m.store.items.map((i) => (i as AccountItem).password).toSet();
      expect(pws, containsAll(['edit-from-A', 'edit-from-B']), reason: m.name);
    }
  });

  test('停止再接上同步（沒有基準）：別台的刪除標記不會刪掉這台離線改過的內容', () async {
    await pair();
    await a.store.put(AccountItem(name: 'X', password: 'v1'));
    await a.sync();
    await b.sync();

    await b.engine.forgetState();
    final onB = b.byName('X') as AccountItem;
    onB.password = 'offline-edit-on-B';
    await b.store.put(onB);

    await Future<void>.delayed(const Duration(milliseconds: 5));
    final onA = a.byName('X') as AccountItem;
    onA.password = 'v2-on-A';
    await a.store.put(onA);
    await a.sync();
    await a.store.delete(onA.id);
    await a.sync();

    await b.engine.attach();
    await b.sync();
    await a.sync();
    for (final m in [a, b]) {
      expect((m.byName('X') as AccountItem).password, 'offline-edit-on-B',
          reason: m.name);
    }
  });

  test('被刪掉的項目：雲端被換回舊檔、刪除標記也被拿掉，仍不會復活', () async {
    await pair();
    await a.store.put(AccountItem(name: 'X', password: 'secret'));
    await a.sync();
    await b.sync();
    final id = a.byName('X').id;
    final old = File('${cloud.path}/items/$id.item').readAsBytesSync();

    await a.store.delete(id);
    await a.sync();
    await b.sync();
    expect(b.names, isEmpty);

    // 雲端「還原已刪除的檔案」：舊項目檔回來、刪除標記不見。
    for (final f in Directory('${cloud.path}/deleted').listSync()) {
      f.deleteSync();
    }
    File('${cloud.path}/items/$id.item').writeAsBytesSync(old);
    await a.sync();
    await b.sync();
    expect(a.names, isEmpty);
    expect(b.names, isEmpty);
    expect(File('${cloud.path}/items/$id.item').existsSync(), isFalse);
    expect(File('${cloud.path}/deleted/$id.tomb').existsSync(), isTrue,
        reason: '刪除標記要被補回去');
  });

  test('殘留的舊刪除標記不會讓之後的刪除失效', () async {
    await pair();
    await a.store.put(AccountItem(name: 'X', password: 'v1'));
    await a.sync();
    await b.sync();
    final id = a.byName('X').id;

    // 先刪一次再在 B 改回來（改過的贏），留下一個舊的刪除標記副本。
    await a.store.delete(id);
    await a.sync();
    final staleTomb = File('${cloud.path}/deleted/$id.tomb').readAsBytesSync();
    final onB = b.byName('X') as AccountItem;
    onB.password = 'v2';
    await b.store.put(onB);
    await b.sync();
    await a.sync();
    expect(a.names, ['X']);
    File('${cloud.path}/deleted/$id.tomb').writeAsBytesSync(staleTomb);

    // 這次真的刪。
    await a.store.delete(id);
    await a.sync();
    await b.sync();
    await a.sync();
    expect(a.names, isEmpty);
    expect(b.names, isEmpty);
  });

  test('雲端讀不出來的正名檔不會被這台蓋掉', () async {
    await pair();
    await a.store.put(AccountItem(name: 'X', password: 'v1'));
    await a.sync();
    await b.sync();
    final id = a.byName('X').id;
    final file = File('${cloud.path}/items/$id.item');
    file.writeAsBytesSync(file.readAsBytesSync().sublist(0, 10));
    final partial = file.readAsBytesSync();

    final onB = b.byName('X') as AccountItem;
    onB.password = 'v2';
    await b.store.put(onB);
    await b.sync();
    expect(file.readAsBytesSync(), partial, reason: '可能是別台的新版還沒下載完');
  });

  test('解鎖備案：先試正名的 nook-sync.json，種了一堆假候選也擋不住', () async {
    await pair();
    await a.store.put(AccountItem(name: 'X'));
    await a.sync();
    await b.sync();
    b.store.lock();
    await a.store.changePassword(pw, newPw);
    await a.sync();

    final real = File('${cloud.path}/${SyncEngine.manifestName}');
    for (final n in ['nook-sync 0.json', 'nook-sync 1.json', 'nook-sync 2.json', 'nook-sync 3.json']) {
      final json = jsonDecode(real.readAsStringSync()) as Map<String, dynamic>;
      json['wrappedDek'] = base64Encode(List.filled(60, 7));
      json['keyChangedAt'] = '2099-01-01T00:00:00.000Z';
      File('${cloud.path}/$n').writeAsStringSync(jsonEncode(json));
    }
    expect(
        await SyncEngine.unlockWithNewerKey(
            store: b.store, folder: cloud, password: newPw),
        isTrue);
  });

  // 雲端服務送檔不保證順序：刪除標記可能比別台的修改還晚到。
  Future<void> hideDeleted(Future<void> Function() body) async {
    final dir = Directory('${cloud.path}/deleted');
    final aside = Directory('${tmp.path}/deleted-in-flight');
    if (dir.existsSync()) dir.renameSync(aside.path);
    try {
      await body();
    } finally {
      if (aside.existsSync()) {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
        aside.renameSync(dir.path);
      }
    }
  }

  Future<String> concurrentEditAndDelete() async {
    await pair();
    await a.store.put(AccountItem(name: 'X', password: 'v0'));
    await a.sync();
    await b.sync();
    final id = a.byName('X').id;

    final onB = b.byName('X') as AccountItem; // B 先改（還沒同步）
    onB.password = 'edit-on-B';
    await b.store.put(onB);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final onA = a.byName('X') as AccountItem; // A 之後改了又刪，沒看過 B 的修改
    onA.password = 'v1-on-A';
    await a.store.put(onA);
    await a.sync();
    await a.store.delete(id);
    await a.sync();
    return id;
  }

  test('同時一邊改一邊刪，刪除標記晚到：B 先推了修改，A 再同步 → 修改贏', () async {
    await concurrentEditAndDelete();
    await hideDeleted(() => b.sync()); // B 還沒收到刪除標記，把修改當一般修改推上去
    await a.sync();
    await b.sync();
    await a.sync();
    for (final m in [a, b]) {
      expect(m.names, ['X'], reason: m.name);
      expect((m.byName('X') as AccountItem).password, 'edit-on-B', reason: m.name);
    }
  });

  test('同時一邊改一邊刪，刪除標記晚到：B 推了修改後才收到刪除標記 → 修改贏', () async {
    await concurrentEditAndDelete();
    await hideDeleted(() => b.sync());
    await b.sync(); // 刪除標記到了，A 還沒處理 B 的修改
    await a.sync();
    await b.sync();
    for (final m in [a, b]) {
      expect(m.names, ['X'], reason: m.name);
      expect((m.byName('X') as AccountItem).password, 'edit-on-B', reason: m.name);
    }
  });

  test('A 改了又刪、B 手上是沒改過的舊版：B 要跟著刪，舊版不能復活', () async {
    await pair();
    await a.store.put(AccountItem(name: 'X', password: 'v0'));
    await a.sync();
    await b.sync();
    final onA = a.byName('X') as AccountItem;
    onA.password = 'v1-on-A';
    await a.store.put(onA);
    await a.sync();
    await a.store.delete(onA.id);
    await a.sync();

    await b.sync();
    await a.sync();
    await b.sync();
    expect(a.names, isEmpty);
    expect(b.names, isEmpty);
  });

  test('刪除那台停止過同步（歷史較短）：另一台沒改過的舊版仍要跟著刪', () async {
    await pair();
    await a.store.put(AccountItem(name: 'X', password: 'v0'));
    await a.sync();
    await b.sync();

    // A 停止再接上同步，之後改了又刪。
    await a.engine.forgetState();
    await a.engine.attach();
    await a.sync();
    final onA = a.byName('X') as AccountItem;
    onA.password = 'v1-on-A';
    await a.store.put(onA);
    await a.sync();
    await a.store.delete(onA.id);
    await a.sync();

    await b.sync(); // B 一直是 v0、沒改過
    await a.sync();
    await b.sync();
    expect(a.names, isEmpty);
    expect(b.names, isEmpty);
  });

  test('停止同步只丟基準：刪過的項目再接上後，雲端的舊檔帶不回來', () async {
    await pair();
    await a.store.put(AccountItem(name: 'X', password: 'secret'));
    await a.sync();
    await b.sync();
    final id = a.byName('X').id;
    final old = File('${cloud.path}/items/$id.item').readAsBytesSync();
    await a.store.delete(id);
    await a.sync();
    await b.sync();

    await a.engine.forgetState();
    for (final f in Directory('${cloud.path}/deleted').listSync()) {
      f.deleteSync();
    }
    File('${cloud.path}/items/$id.item').writeAsBytesSync(old);
    await a.engine.attach();
    await a.sync();
    await b.sync();
    expect(a.names, isEmpty);
    expect(b.names, isEmpty);
  });

  test('雲端正名檔壞掉很久了（不是還在下載）：用新版蓋過去，不會永遠卡住', () async {
    await pair();
    await a.store.put(AccountItem(name: 'X', password: 'v0'));
    await a.sync();
    await b.sync();
    final id = a.byName('X').id;
    final file = File('${cloud.path}/items/$id.item');
    file.writeAsBytesSync(List.filled(40, 1));
    file.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 1)));

    final onA = a.byName('X') as AccountItem;
    onA.password = 'v1-on-A';
    await a.store.put(onA);
    await a.sync();
    await b.sync();
    expect((b.byName('X') as AccountItem).password, 'v1-on-A');
  });

  test('衝突檔名解析：選上一層資料夾時找得到底下的同步區', () async {
    await pair();
    final parent = cloud.parent;
    expect(SyncEngine.resolveExchange(parent).path, cloud.path);
    expect(SyncEngine.resolveExchange(cloud).path, cloud.path);
  });

  test('updatedAt 每次修改都嚴格遞增，即使時鐘倒退', () {
    final future = DateTime.now().toUtc().add(const Duration(hours: 3));
    final next = VaultStore.nextUpdatedAt(future);
    expect(next.isAfter(future), isTrue);
    expect(next.isUtc, isTrue);
  });
}

/// applySynced 之前先讓「使用者」存一次檔，模擬同步途中剛好存檔。
class _RacyStore extends VaultStore {
  _RacyStore(super.root) : super(kdfFactory: KdfParams.weakForTests);
  Future<void> Function()? beforeApply;

  @override
  Future<bool> applySynced(
    String id, {
    required VaultItem? expected,
    required DateTime? expectedUpdatedAt,
    required VaultItem? replacement,
  }) async {
    final hook = beforeApply;
    if (hook != null && expected != null) {
      beforeApply = null;
      await hook();
    }
    return super.applySynced(id,
        expected: expected,
        expectedUpdatedAt: expectedUpdatedAt,
        replacement: replacement);
  }
}

class _RacyMachine extends Machine {
  _RacyMachine(super.name, super.tmp, super.cloud)
      : racy = _RacyStore(Directory('${tmp.path}/$name/vault'));
  final _RacyStore racy;
  @override
  VaultStore get store => racy;
}
