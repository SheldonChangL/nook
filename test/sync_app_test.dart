import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:securemanage/app/app_state.dart';
import 'package:securemanage/services/biometric_gate.dart';
import 'package:securemanage/sync/sync_engine.dart';
import 'package:securemanage/sync/sync_setup.dart';
import 'package:securemanage/vault/models.dart';
import 'package:securemanage/vault/vault_crypto.dart';
import 'package:securemanage/vault/vault_store.dart';

/// 同步接到 AppState 之後的流程：在 A 接上同步資料夾、B 從資料夾加入、
/// 重開後恢復、主密碼在別台換過、編輯途中被同步換掉。全部用假資料。
const pw = 'fake-master-pw-for-sync-app-tests';
const newPw = 'fake-new-master-pw-for-sync-app-tests';

class _NoBiometrics extends BiometricGate {
  _NoBiometrics() : super(platformSupported: false);
}

/// 不開任何視窗：pick 回傳事先指定的資料夾，restore 照設定檔回傳。
class FakeFolders implements FolderAccess {
  String? next;
  @override
  Future<PickedFolder?> pick({required String prompt}) async =>
      next == null ? null : PickedFolder(next!);
  @override
  Future<PickedFolder> restore(SyncConfig config) async =>
      PickedFolder(config.folder);
}

class Box {
  Box(Directory tmp, String name)
      : support = Directory('${tmp.path}/$name'),
        folders = FakeFolders();
  final Directory support;
  final FakeFolders folders;
  Directory get vault => Directory('${support.path}/vault');

  AppState newState() => AppState(
        store: VaultStore(vault,
            kdfFactory: KdfParams.weakForTests, ownerOnlyPermissions: false),
        biometrics: _NoBiometrics(),
        folderAccess: folders,
      );
}

Future<void> settle(AppState s) async {
  // 解鎖時背景會跑一輪同步；等它跑完再比對。
  for (var i = 0; i < 200 && s.syncing; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  await s.syncNow();
}

void main() {
  late Directory tmp;
  late Directory cloudRoot;
  late Box mac;
  late Box linux;
  final opened = <AppState>[];

  Future<AppState> boot(Box box) async {
    final s = box.newState();
    opened.add(s);
    await s.boot();
    return s;
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('nook_sync_app_');
    cloudRoot = Directory('${tmp.path}/Dropbox')..createSync();
    mac = Box(tmp, 'mac');
    linux = Box(tmp, 'linux');
  });

  tearDown(() {
    for (final s in opened) {
      s.lock();
      s.dispose();
    }
    opened.clear();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<AppState> macWithSync() async {
    final a = await boot(mac);
    expect(a.phase, VaultPhase.needsSetup);
    expect(await a.createVault(pw), isTrue);
    await a.save(AccountItem(name: '假的 wiki', password: 'fake-pw-1'));
    mac.folders.next = cloudRoot.path;
    expect(await a.chooseSyncFolder(), isNull);
    await settle(a);
    return a;
  }

  Future<AppState> linuxJoined() async {
    final b = await boot(linux);
    expect(b.phase, VaultPhase.needsSetup);
    linux.folders.next = cloudRoot.path;
    expect(await b.pickJoinFolder(), isNull);
    expect(b.pendingJoinFolder?.path,
        '${cloudRoot.path}/${SyncEngine.defaultSubfolder}');
    expect(await b.joinVault(pw), isTrue);
    await settle(b);
    return b;
  }

  test('A 接上同步資料夾，B 從資料夾加入後拿到同樣的項目', () async {
    final a = await macWithSync();
    expect(a.syncEnabled, isTrue);
    expect(a.syncError, isNull);
    expect(
        File('${cloudRoot.path}/${SyncEngine.defaultSubfolder}/nook-sync.json')
            .existsSync(),
        isTrue);

    final b = await linuxJoined();
    expect(b.phase, VaultPhase.unlocked);
    expect(b.items.map((i) => i.name), ['假的 wiki']);
    expect(File('${linux.support.path}/sync.json').existsSync(), isTrue);
  });

  test('加入時密碼錯：不建立保險庫', () async {
    await macWithSync();
    final b = await boot(linux);
    linux.folders.next = cloudRoot.path;
    await b.pickJoinFolder();
    expect(await b.joinVault('wrong-fake-password'), isFalse);
    expect(b.unlockError, isNotNull);
    expect(b.phase, VaultPhase.needsSetup);
    expect(File('${linux.vault.path}/vault.json').existsSync(), isFalse);
  });

  test('選到沒有同步資料的資料夾：加入流程直接說明，不進下一步', () async {
    final b = await boot(linux);
    linux.folders.next = cloudRoot.path; // 空的 Dropbox
    final error = await b.pickJoinFolder();
    expect(error, contains('沒有 Nook 的同步資料'));
    expect(b.pendingJoinFolder, isNull);
  });

  test('重開 app：同步設定還在，解鎖後繼續同步', () async {
    final a = await macWithSync();
    final b = await linuxJoined();
    await a.save(AccountItem(name: '第二筆'));
    await settle(a);

    b.lock();
    final b2 = await boot(linux);
    expect(b2.syncEnabled, isTrue);
    expect(await b2.unlock(pw), isTrue);
    await settle(b2);
    expect(b2.items.map((i) => i.name).toSet(), {'假的 wiki', '第二筆'});
  });

  test('主密碼在 A 換過、B 還沒同步：B 用新密碼也解得開，並收到提示', () async {
    final a = await macWithSync();
    final b = await linuxJoined();
    b.lock();

    expect(await a.changeMasterPassword(pw, newPw), isNull);
    await settle(a);

    expect(await b.unlock(newPw), isTrue);
    expect(b.syncNotice, contains('另一台機器更換'));
    b.lock();
    expect(await b.unlock(pw), isFalse, reason: '舊密碼要失效');
    expect(await b.unlock(newPw), isTrue);
  });

  test('編輯途中同步拉進了別台的版本：存檔時別台那份另存成衝突副本', () async {
    final a = await macWithSync();
    final b = await linuxJoined();

    // B 的編輯器拿著這個物件。
    final editing = b.items.single as AccountItem;

    // 這時 A 改了同一筆，B 的背景同步把新版拉進來（換成新物件）。
    final onA = a.items.single as AccountItem;
    onA.password = 'changed-on-a';
    await a.save(onA);
    await settle(a);
    await settle(b);
    expect(identical(b.items.single, editing), isFalse);

    // B 的使用者按下存檔。
    editing.password = 'typed-on-b';
    await b.save(editing);
    final names = b.items.map((i) => i.name).toList()..sort();
    expect(names, ['假的 wiki', '假的 wiki${SyncEngine.conflictSuffix}']);
    final copy = b.items.firstWhere((i) => i.name.endsWith(SyncEngine.conflictSuffix))
        as AccountItem;
    expect(copy.password, 'changed-on-a');
    expect((b.items.firstWhere((i) => i.name == '假的 wiki') as AccountItem).password,
        'typed-on-b');
    expect(b.syncNotice, contains('另存為'));
  });

  test('編輯途中被拉進的版本來自時鐘較快的機器：這次修改仍然算數', () async {
    final a = await macWithSync();
    final b = await linuxJoined();
    final editing = b.items.single as AccountItem;

    // A 的時鐘快一小時。
    final onA = a.items.single as AccountItem;
    onA.password = 'v2-on-a';
    onA.updatedAt = DateTime.now().toUtc().add(const Duration(hours: 1));
    await a.store.put(onA, bumpUpdated: false);
    await settle(a);
    await settle(b);

    editing.password = 'typed-on-b';
    await b.save(editing);
    await settle(b);
    await settle(a);
    await settle(b);
    for (final s in [a, b]) {
      final main = s.items.firstWhere((i) => i.name == '假的 wiki') as AccountItem;
      expect(main.password, 'typed-on-b');
      final copy = s.items.firstWhere(
          (i) => i.name.endsWith(SyncEngine.conflictSuffix)) as AccountItem;
      expect(copy.password, 'v2-on-a');
    }
  });

  test('停止同步：設定清掉，本機資料與同步資料夾都不動', () async {
    final a = await macWithSync();
    final exchange =
        Directory('${cloudRoot.path}/${SyncEngine.defaultSubfolder}');
    final before = exchange.listSync(recursive: true).length;

    await a.stopSync();
    expect(a.syncEnabled, isFalse);
    expect(File('${mac.support.path}/sync.json').existsSync(), isFalse);
    // 同步基準清掉了，但看過的版本與刪除紀錄留著（加密的），之後再接上才不會讓刪掉的復活。
    expect(File('${mac.support.path}/sync-state.bin').existsSync(), isTrue);
    expect(exchange.listSync(recursive: true).length, before);
    expect(a.items.map((i) => i.name), ['假的 wiki']);
  });

  test('接上別的保險庫的同步資料夾：拒絕並說明', () async {
    await macWithSync();
    final other = await boot(linux);
    expect(await other.createVault('a-different-fake-master-pw'), isTrue);
    linux.folders.next = cloudRoot.path;
    final error = await other.chooseSyncFolder();
    expect(error, contains('另一個保險庫'));
    expect(other.syncEnabled, isFalse);
  });
}
