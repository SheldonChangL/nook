import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../vault/models.dart';
import '../vault/vault_crypto.dart';
import '../vault/vault_store.dart';

/// 跨機同步：把本機保險庫跟一個「同步資料夾」逐筆合併。
///
/// 同步資料夾通常放在 Dropbox、Google Drive、iCloud Drive 之類的雲端硬碟裡，
/// 檔案怎麼在機器之間搬由那些服務的程式負責 —— Nook 自己不連網，只讀寫本機
/// 的一個資料夾。所以這裡要面對的是「別人的同步程式」的各種行為：檔案還沒
/// 下載完、衝突時另存一份改了名的副本、刪掉的檔案又冒出來。
///
/// 資料夾長這樣：
///   nook-sync.json      金鑰包裝（KDF 參數、被包住的 DEK、換密碼時間）＋用 DEK 封的認證
///   items/「id」.item     跟本機同格式的密文，但不含 lastAccessedAt（那是各台自己的使用紀錄）
///   deleted/「id」.tomb   刪除標記，也是密文：{id, deletedVersion}
///
/// 合併規則（逐筆，三方）：
/// - 「上次同步時兩邊同意的版本」記在本機的 sync-state（用 DEK 加密，不放在同步資料夾）。
/// - 只有一邊比上次同意的版本新 → 那邊的版本贏。
/// - 兩邊都改過 → updatedAt 較新的贏；另一份內容不同的話另存成「（衝突副本）」，
///   任何一次修改都不會被默默吃掉。
/// - 刪除 vs 修改 → 修改贏（刪掉的那筆會回來，可以再刪一次；改掉的內容卻救不回來）。
/// - 本機的資料只有在同步資料夾裡有「用同一把 DEK 封的刪除標記」時才會被刪；
///   檔案不見了、讀不出來、還沒下載完，一律不當成刪除。
/// - 同步資料夾裡比上次同意的版本還舊的檔案（例如雲端回復到舊版）不會被拉回來，
///   反而會用本機版本蓋回去。
///
/// 安全上：拿到同步資料夾寫入權的人（雲端服務、或盜用你帳號的人）能做的只有
/// 不給你新資料、或刪檔讓同步停滯；沒有 DEK 就偽造不出項目、刪除標記或金鑰包裝，
/// 也沒辦法把舊的金鑰包裝（舊主密碼）塞回來 —— 換密碼時間在認證範圍裡。
class SyncEngine {
  SyncEngine({
    required this.store,
    required this.folder,
    required this.stateFile,
  });

  /// 必須是解鎖狀態才能同步：比對內容要先解密。
  final VaultStore store;

  /// 同步資料夾（已經解析到真正放 nook-sync.json 的那一層）。
  final Directory folder;

  /// 這台機器的同步基準。放在保險庫資料夾外面：整個 vault/ 複製到別台當備份時，
  /// 不該把「這台上次同步到哪」也帶過去。
  final File stateFile;

  static const manifestName = 'nook-sync.json';
  static const defaultSubfolder = 'Nook Sync';
  static const conflictSuffix = '（衝突副本）';

  /// 讀不出來的檔在這段時間內被改過，就當成「還在下載」，先不蓋它。
  static const inFlightWindow = Duration(minutes: 10);

  /// 每筆記住最近幾個同意過的版本（內容雜湊，各 32 字元），刪除時放進刪除標記。
  /// 記得越多，越難用雲端的舊版本讓刪掉的項目復活；256 個一筆最多約 8 KB。
  static const historyLimit = 256;

  Future<SyncReport>? _running;

  File get _manifestFile => File('${folder.path}/$manifestName');
  Directory get _itemsDir => Directory('${folder.path}/items');
  Directory get _deletedDir => Directory('${folder.path}/deleted');

  // ------------------------------------------------------------ 資料夾

  /// 使用者選的資料夾可能是同步區本身，也可能是放同步區的上一層（例如直接選了
  /// Dropbox 根目錄）。已經有同步區就用它；都沒有就在選的資料夾底下開一個
  /// [defaultSubfolder]，免得在別人的資料夾裡撒一地檔案。
  static Directory resolveExchange(Directory picked) {
    if (_hasManifest(picked)) return picked;
    final nested = Directory('${picked.path}/$defaultSubfolder');
    return nested;
  }

  static bool _hasManifest(Directory dir) =>
      _manifestCandidates(dir).isNotEmpty;

  /// 這個資料夾是不是已經設定好的同步區（有 nook-sync.json）。
  static bool isExchange(Directory dir) => _hasManifest(dir);

  /// 另存衝突副本用的新物件：id 由原 id、版本與內容推出來（兩台各自處理同一個
  /// 衝突時會得到同一個 id），名稱加上 [conflictSuffix]。
  static Future<VaultItem> conflictCopyOf(VaultItem item) async {
    final json = item.toJson();
    json['id'] = await _conflictId(item);
    json['name'] = '${item.name}$conflictSuffix';
    json['lastAccessedAt'] = null;
    return VaultItem.fromJson(json);
  }

  /// nook-sync.json 以及雲端服務衝突時另存的版本：
  ///   Dropbox  nook-sync (某人's conflicted copy 2026-11-11).json
  ///   iCloud   nook-sync 2.json
  ///   Google   nook-sync(1).json
  static List<File> _manifestCandidates(Directory dir) {
    if (!dir.existsSync()) return const [];
    final out = <File>[];
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is! File) continue;
      final name = _basename(entity.path);
      if (name.startsWith('nook-sync') && name.endsWith('.json')) {
        out.add(entity);
      }
    }
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  // ------------------------------------------------------------ 接上

  /// 把這台接上同步資料夾（必須已解鎖）。資料夾是空的就初始化；已經是同一個
  /// 保險庫的同步區就沿用；是別的保險庫的、或裡面已經有不認得的東西，就拒絕。
  Future<void> attach() async {
    final remote = await _readAuthenticManifests();
    if (remote.authentic.isEmpty) {
      if (remote.foreign > 0) {
        throw const SyncException(
          '這個資料夾是另一個保險庫的同步區（主密碼不同的 Nook），不能混在一起。'
          '請另外選一個資料夾。',
        );
      }
      if (_itemsDir.existsSync() &&
          _itemsDir.listSync().whereType<File>().isNotEmpty) {
        throw const SyncException('這個資料夾裡已經有東西，但不是 Nook 的同步區。');
      }
      await folder.create(recursive: true);
      await _writeManifest(await store.readKeyMaterial());
    }
  }

  // ------------------------------------------------------------ 新機器加入

  /// 這台還沒有保險庫時，用主密碼從同步資料夾加入。成功後 [store] 是解鎖狀態，
  /// 但項目還沒拉下來 —— 接著跑一次 [sync]。
  static Future<void> join({
    required VaultStore store,
    required Directory folder,
    required String password,
  }) async {
    final unlocked = await _unlockCandidates(folder, password);
    if (unlocked == null) {
      // 跟一般解鎖一樣，不細分是密碼錯還是資料夾不對。
      throw const VaultOpenException('解不開：主密碼不對，或這不是 Nook 的同步資料夾');
    }
    await store.createFromKeyMaterial(
      kdf: unlocked.material.kdf,
      wrappedDek: unlocked.material.wrappedDek,
      keyChangedAt: unlocked.material.keyChangedAt,
      dek: unlocked.dek,
    );
  }

  /// 本機解鎖失敗時的備案：主密碼可能在另一台換過了，這台還沒同步到。
  /// 用輸入的密碼去解同步資料夾裡「比本機新」的金鑰包裝；解得開、認證對、
  /// 而且解出來的 DEK 真的能打開本機的項目，就採用它並解鎖。回傳有沒有成功。
  static Future<bool> unlockWithNewerKey({
    required VaultStore store,
    required Directory folder,
    required String password,
  }) async {
    final local = await store.readKeyMaterial();
    final unlocked = await _unlockCandidates(
      folder,
      password,
      newerThan: local.keyChangedAt,
    );
    if (unlocked == null) return false;
    if (!await store.dekMatchesLocalItems(unlocked.dek)) return false;
    await store.adoptKeyMaterial(unlocked.material);
    await store.unlockWithDek(unlocked.dek);
    return true;
  }

  static Future<_Unlocked?> _unlockCandidates(
    Directory folder,
    String password, {
    DateTime? newerThan,
  }) async {
    _Unlocked? best;
    // 每個候選都要跑一次 Argon2id（約半秒），只看前幾個；正名的 nook-sync.json
    // 一定排第一個 —— 不然有人在資料夾裡種幾個假候選，真的那份就永遠輪不到。
    final candidates = _manifestCandidates(folder)
      ..sort((a, b) {
        final ac = _basename(a.path) == manifestName ? 0 : 1;
        final bc = _basename(b.path) == manifestName ? 0 : 1;
        return ac != bc ? ac - bc : a.path.compareTo(b.path);
      });
    for (final file in candidates.take(4)) {
      final parsed = _parseManifest(file);
      if (parsed == null) continue;
      if (newerThan != null && !parsed.material.keyChangedAt.isAfter(newerThan)) {
        continue;
      }
      try {
        final kek = await VaultCrypto.deriveKek(password, parsed.material.kdf);
        final dek = await VaultCrypto.open(
          kek,
          Uint8List.fromList(parsed.material.wrappedDek),
        );
        if (!await _verifyAuth(SecretKey(dek), parsed)) continue;
        if (best == null ||
            parsed.material.keyChangedAt.isAfter(best.material.keyChangedAt)) {
          best = _Unlocked(parsed.material, dek);
        }
      } catch (_) {
        // 解不開、參數不合法（例如 iterations 是 0）：都只是這個候選不算數。
        continue;
      }
    }
    return best;
  }

  // ------------------------------------------------------------ 同步

  /// 跑一輪同步。同時被叫好幾次時共用同一輪。
  Future<SyncReport> sync() {
    return _running ??= _sync().whenComplete(() => _running = null);
  }

  Future<SyncReport> _sync() async {
    if (!store.isUnlocked) {
      throw const SyncException('保險庫是鎖著的');
    }
    if (!folder.existsSync()) {
      throw SyncException(
        '找不到同步資料夾 ${folder.path}。雲端硬碟的程式有在執行嗎？資料夾被移走了嗎？',
      );
    }
    final report = SyncReport();

    // 1. 金鑰包裝：一台換了主密碼，另一台跟著換。
    final remote = await _readAuthenticManifests();
    final local = await store.readKeyMaterial();
    final newest = remote.newest;
    if (remote.authentic.isEmpty && remote.foreign > 0) {
      throw const SyncException('同步資料夾裡的設定檔不是這個保險庫的，已停止同步以免混在一起。');
    }
    if (newest != null &&
        newest.material.keyChangedAt.isAfter(local.keyChangedAt)) {
      await store.adoptKeyMaterial(newest.material);
      report.keyAdopted = true;
    } else if (newest == null ||
        local.keyChangedAt.isAfter(newest.material.keyChangedAt)) {
      await _writeManifest(local);
    }
    // 雲端服務另存的衝突版本：認證過、內容已經併進來了，可以清掉。
    for (final extra in remote.authentic) {
      if (_basename(extra.file.path) != manifestName) {
        await _tryDelete(extra.file);
      }
    }

    // 2. 項目。
    final state = await _readState();
    final base = state.items;
    final remoteItems = await _readRemoteItems(report);
    final tombstones = await _readTombstones(report);

    final localSnapshot = <String, _LocalVersion>{
      for (final item in store.items)
        item.id: _LocalVersion(item, item.updatedAt, _canonicalJson(item)),
    };
    final ids = <String>{
      ...localSnapshot.keys,
      ...remoteItems.keys,
      ...tombstones.keys,
      ...base.keys,
      ...state.deleted.keys,
    };

    final next = _SyncState();
    for (final id in ids) {
      if (!store.isUnlocked) throw const SyncException('同步途中被上鎖了');
      final history = state.history[id] ?? const <String>[];
      final outcome = await _mergeOne(
        id: id,
        local: localSnapshot[id],
        variants: remoteItems[id] ?? const [],
        tombstone: _Tombstone.combine(
          tombstones[id],
          state.deleted[id],
          // 這台自己刪的（或跟著刪的）才算「刪除者看過的版本」；
          // 活著的項目的歷史是這台自己的，不能拿來替別台的刪除背書。
          state.deleted.containsKey(id) ? history : const [],
        ),
        base: base[id],
        history: history,
        canonicalInFlight: report._inFlight.contains('$id.item'),
        report: report,
      );
      if (outcome.agreed != null) next.items[id] = outcome.agreed!;
      if (outcome.deleted != null) next.deleted[id] = outcome.deleted!;
      final kept = outcome.agreedHash == null
          ? history
          : _remember(history, outcome.agreedHash!);
      if (kept.isNotEmpty) next.history[id] = kept;
    }
    // 衝突副本是這一輪才產生的新項目，已經兩邊都寫好了。
    for (final copy in report._newCopies) {
      next.items[copy.id] = copy.updatedAt;
      next.history[copy.id] = [_hash(_canonicalJson(copy))];
    }

    await _writeState(next);
    report.finishedAt = DateTime.now();
    return report;
  }

  /// 合併一筆。回傳兩邊同意的版本，或（這筆已刪除時）刪除的版本。
  ///
  /// 任何一步「套用到本機」被擋下（使用者剛好在這時存了檔），這一筆整輪作廢、
  /// 基準不前進：下一輪會看到兩邊都改過，照衝突處理。基準若前進了，下一輪會以為
  /// 雲端沒變，直接用本機版本蓋掉別台的修改。
  Future<_Outcome> _mergeOne({
    required String id,
    required _LocalVersion? local,
    required List<_RemoteVersion> variants,
    required _Tombstone? tombstone,
    required DateTime? base,
    required List<String> history,
    required bool canonicalInFlight,
    required SyncReport report,
  }) async {
    final skip = _Outcome(base, base == null ? tombstone?.knownVersion : null);
    // 雲端的正名檔讀不出來、而且剛被改過（多半是別台的新版還沒下載完）：這一輪
    // 不碰這筆，免得用本機版本把它蓋掉。放了很久還是讀不出來的就當壞檔，照常蓋過去，
    // 不然這筆會永遠卡住。
    if (canonicalInFlight) return skip;

    // 同一筆在雲端有好幾份（雲端服務的衝突副本、或兩台同時寫）：挑最新的當代表，
    // 其他內容不同、而且比上次同意的還新的另存衝突副本。比上次同意的還舊的是
    // 回放或回復的舊檔，丟掉就好。
    _RemoteVersion? remote;
    if (variants.isNotEmpty) {
      final sorted = [...variants]..sort(_RemoteVersion.newestFirst);
      remote = sorted.first;
      for (final other in sorted.skip(1)) {
        final duplicate = other.canonical == remote.canonical ||
            other.canonical == local?.canonical;
        final stale = base != null && !other.updatedAt.isAfter(base);
        if (!duplicate && !stale) await _preserveConflict(other.item, report);
      }
    }

    final localMissingAtStart = local == null;
    var localChanged = local != null &&
        (base == null || !local.updatedAt.isAtSameMomentAs(base));

    if (tombstone != null) {
      // 刪除標記帶著刪除那台看過的每個版本的內容雜湊。比刪除還早的版本：
      //   - 內容在名單裡 → 刪除者看過它才刪的（或是被放回來的舊檔）→ 照刪；
      //   - 不在名單裡   → 刪除者沒看過的同時修改 → 改過的贏。
      // 時間分不出這兩種：雲端服務送檔不保證順序，別台的修改可能先推上去、
      // 刪除標記才到。舊版的刪除標記沒有名單，退回只看時間的規則。
      final known = tombstone.known;
      bool deleterSaw(_Version v) => known.contains(v.hash);

      if (remote != null && !remote.updatedAt.isAfter(tombstone.version)) {
        if (known.isEmpty || deleterSaw(remote)) {
          remote = null;
        } else {
          // 別台在刪除之前、刪除者不知道的修改：留下，時間蓋到刪除之後。
          final json = jsonDecode(remote.canonical) as Map<String, dynamic>;
          json['updatedAt'] = VaultStore.nextUpdatedAt(tombstone.version)
              .toIso8601String();
          json['lastAccessedAt'] = null;
          final item = VaultItem.fromJson(json);
          remote = _RemoteVersion(
              remote.file, item, item.updatedAt, remote.canonical);
        }
      }
      if (local != null && !local.updatedAt.isAfter(tombstone.version)) {
        // 這台自上次同步後沒改過 → 沒有新東西要保護，跟著刪（不管刪除者的名單
        // 是不是剛好沒記到這一版：它可能停止過同步、或比較晚才加入）。
        // 改過的、或沒有基準可比的，才看刪除者有沒有看過這份內容。
        final deleteLocal = base != null && !localChanged
            ? true
            : known.isEmpty
                ? local.updatedAt.isAtSameMomentAs(tombstone.version)
                : deleterSaw(local);
        if (deleteLocal) {
          if (!await _applyLocal(local, null)) return skip;
          report.deletedLocally++;
          local = null;
        } else {
          // 留下本機版本，但時間戳要蓋到刪除之後：別台記得「這筆在某版被刪了」，
          // 不比那個新的版本一律擋掉。重新蓋時間需要 DEK，有雲端寫入權的人做不到。
          final restamped = local.snapshotItem()
            ..updatedAt = VaultStore.nextUpdatedAt(tombstone.version);
          if (!await _applyLocal(local, restamped)) return skip;
          local = _LocalVersion(restamped, restamped.updatedAt, local.canonical);
          localChanged = true;
        }
      }
    }
    final remoteStillChanged =
        remote != null && (base == null || remote.updatedAt.isAfter(base));

    // 在這台刪掉的：上次同步時還在、這輪開始前就沒了。殘留的舊刪除標記
    // （刪的是比上次同意還舊的版本）不算數，不然這次的刪除會被它吃掉。
    final deletedHere = localMissingAtStart &&
        base != null &&
        (tombstone == null || tombstone.version.isBefore(base));

    _Version? winner;
    DateTime? deletedVersion;
    if (deletedHere && !remoteStillChanged) {
      await _writeTombstone(id, base, history);
      report.deletedRemotely++;
      deletedVersion = base;
    } else if (local == null && remote == null) {
      // 兩邊都沒有了。記住刪除的版本；雲端的刪除標記不見了就補回去。
      deletedVersion = tombstone?.version;
      if (tombstone != null && tombstone.files.isEmpty) {
        await _writeTombstone(id, tombstone.version, tombstone.known.toList());
      }
    } else if (local == null) {
      // 新的，或在別台被改過（改過的贏過這台的刪除）→ 拉下來。
      if (!await _applyLocal(null, remote!.item)) return skip;
      report.pulled++;
      winner = remote;
    } else if (remote == null) {
      winner = local;
    } else if (localChanged && remoteStillChanged) {
      if (local.canonical == remote.canonical) {
        // 內容一樣、只有時間不同：統一成較新的那個，不然下一輪又會判成有改。
        if (remote.updatedAt.isAfter(local.updatedAt)) {
          if (!await _applyLocal(local, remote.item)) return skip;
          winner = remote;
        } else {
          winner = local;
        }
      } else if (local.updatedAt.isAfter(remote.updatedAt)) {
        await _preserveConflict(remote.item, report);
        winner = local;
      } else {
        await _preserveConflict(local.snapshotItem(), report);
        if (!await _applyLocal(local, remote.item)) return skip;
        report.pulled++;
        winner = remote;
      }
    } else if (remoteStillChanged) {
      if (!await _applyLocal(local, remote.item)) return skip;
      report.pulled++;
      winner = remote;
    } else {
      // 雲端沒有比上次同意的新：本機改過、或雲端是被回復的舊版 → 以本機為準。
      winner = local;
    }

    // 雲端只留一份正名的檔案，內容就是贏的那份。
    final canonicalPath = File('${_itemsDir.path}/$id.item').path;
    if (winner != null) {
      _RemoteVersion? atCanonical;
      for (final v in variants) {
        if (v.file.path == canonicalPath) atCanonical = v;
      }
      final upToDate = atCanonical != null &&
          atCanonical.updatedAt.isAtSameMomentAs(winner.updatedAt) &&
          atCanonical.canonical == winner.canonical;
      if (!upToDate) {
        await _pushVersion(id, winner);
        if (identical(winner, local)) report.pushed++;
      }
      // 這筆最後留下來了，刪除標記作廢。
      for (final f in tombstone?.files ?? const <File>[]) {
        await _tryDelete(f);
      }
    } else {
      // 這筆沒了：雲端剩下的是刪除前的舊版，清掉，免得之後被當成新項目拉回來。
      await _tryDelete(File(canonicalPath));
    }
    // 其餘變體（雲端服務另存的衝突檔）內容已經合併或另存了。
    for (final v in variants) {
      if (v.file.path != canonicalPath) await _tryDelete(v.file);
    }
    return _Outcome(
      winner?.updatedAt,
      winner == null ? deletedVersion : null,
      agreedHash: winner?.hash,
    );
  }

  // ------------------------------------------------------------ 本機

  /// 本機那筆仍是同步開始時看到的版本才套用；使用者剛好在這中間存了檔就放棄，
  /// 下一輪再比。
  Future<bool> _applyLocal(_LocalVersion? expected, VaultItem? replacement) {
    final id = expected?.item.id ?? replacement!.id;
    return store.applySynced(
      id,
      expected: expected?.item,
      expectedUpdatedAt: expected?.updatedAt,
      replacement: replacement,
    );
  }

  /// 另存衝突副本：新的 id 由原 id、版本與內容推出來，兩台各自解同一個衝突時
  /// 會得到同一個 id，不會變出兩份副本。
  Future<void> _preserveConflict(VaultItem loser, SyncReport report) async {
    final copy = await conflictCopyOf(loser);
    final copyId = copy.id;
    if (store.byId(copyId) != null) return; // 已經存過了
    final added = await store.applySynced(
      copyId,
      expected: null,
      expectedUpdatedAt: null,
      replacement: copy,
    );
    if (!added) return;
    await _pushVersion(copyId, _LocalVersion(copy, copy.updatedAt, _canonicalJson(copy)));
    report.conflictCopies.add(copy.name);
    report._newCopies.add(copy);
  }

  static Future<String> _conflictId(VaultItem item) async {
    final digest = await Sha256().hash(utf8.encode(
      'nook-conflict-v1|${item.id}|${item.updatedAt.toUtc().toIso8601String()}|'
      '${_canonicalJson(item)}',
    ));
    final b = digest.bytes;
    String hex(int from, int to) => b
        .sublist(from, to)
        .map((x) => x.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }

  // ------------------------------------------------------------ 雲端：項目

  Future<Map<String, List<_RemoteVersion>>> _readRemoteItems(
    SyncReport report,
  ) async {
    final out = <String, List<_RemoteVersion>>{};
    for (final file in _listData(_itemsDir, report)) {
      try {
        final clear = await store.openWithDek(await file.readAsBytes());
        final json = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
        final item = VaultItem.fromJson(json);
        item.lastAccessedAt = null;
        out.putIfAbsent(item.id, () => []).add(
          _RemoteVersion(file, item, item.updatedAt, _canonicalJson(item)),
        );
      } catch (_) {
        // 還沒下載完、被截斷、或根本不是這個保險庫的檔：不刪、不當成刪除，只回報。
        final name = _basename(file.path);
        report.unreadable.add(name);
        try {
          final age = DateTime.now().difference(file.lastModifiedSync());
          if (age < inFlightWindow) report._inFlight.add(name);
        } on FileSystemException {
          report._inFlight.add(name);
        }
      }
    }
    return out;
  }

  /// 把一個版本寫成雲端的正名檔。內容取快照當下的，不含 lastAccessedAt。
  Future<void> _pushVersion(String id, _Version version) async {
    final json = jsonDecode(version.canonical) as Map<String, dynamic>;
    json['updatedAt'] = version.updatedAt.toUtc().toIso8601String();
    json['lastAccessedAt'] = null;
    final sealed = await store.sealWithDek(utf8.encode(jsonEncode(json)));
    await _itemsDir.create(recursive: true);
    await _writeAtomic(File('${_itemsDir.path}/$id.item'), sealed);
  }

  // ------------------------------------------------------------ 雲端：刪除標記

  Future<Map<String, _Tombstone>> _readTombstones(SyncReport report) async {
    final out = <String, _Tombstone>{};
    for (final file in _listData(_deletedDir, report)) {
      try {
        final clear = await store.openWithDek(await file.readAsBytes());
        final json = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
        if (json['tombstone'] != true) continue;
        final id = json['id'] as String;
        final version = DateTime.parse(json['deletedVersion'] as String).toUtc();
        final known = ((json['known'] as List?) ?? const []).cast<String>();
        final existing = out[id];
        if (existing == null) {
          out[id] = _Tombstone(version, [file])..known.addAll(known);
        } else {
          existing.files.add(file);
          existing.known.addAll(known);
          if (version.isAfter(existing.version)) existing.version = version;
        }
      } catch (_) {
        report.unreadable.add(_basename(file.path));
      }
    }
    return out;
  }

  /// [known]：刪除這台看過的每個版本的內容雜湊（見 [_mergeOne]）。
  Future<void> _writeTombstone(
    String id,
    DateTime deletedVersion,
    List<String> known,
  ) async {
    final sealed = await store.sealWithDek(utf8.encode(jsonEncode({
      'tombstone': true,
      'id': id,
      'deletedVersion': deletedVersion.toUtc().toIso8601String(),
      'known': known,
    })));
    await _deletedDir.create(recursive: true);
    await _writeAtomic(File('${_deletedDir.path}/$id.tomb'), sealed);
    await _tryDelete(File('${_itemsDir.path}/$id.item'));
  }

  // ------------------------------------------------------------ 雲端：金鑰包裝

  Future<_ManifestScan> _readAuthenticManifests() async {
    final scan = _ManifestScan();
    for (final file in _manifestCandidates(folder)) {
      final parsed = _parseManifest(file);
      if (parsed == null) {
        scan.foreign++;
        continue;
      }
      if (await _verifyAuthWith(store.openWithDek, parsed)) {
        scan.authentic.add(parsed);
      } else {
        scan.foreign++;
      }
    }
    return scan;
  }

  Future<void> _writeManifest(KeyMaterial material) async {
    final body = _manifestBody(material);
    final auth = await store.sealWithDek(utf8.encode(jsonEncode(body)));
    final json = {...body, 'auth': base64Encode(auth)};
    await folder.create(recursive: true);
    await _writeAtomic(
      _manifestFile,
      utf8.encode(const JsonEncoder.withIndent('  ').convert(json)),
    );
  }

  /// 被認證的範圍。欄位順序固定，序列化結果才會一致。
  static Map<String, dynamic> _manifestBody(KeyMaterial m) => {
    'format': 'nook-sync',
    'version': 1,
    'kdf': m.kdf.toJson(),
    'wrappedDek': base64Encode(m.wrappedDek),
    'keyChangedAt': m.keyChangedAt.toUtc().toIso8601String(),
  };

  /// 解析但不信任：KDF 參數設上限，免得被塞一個要吃掉幾十 GB 記憶體的檔案。
  static _ParsedManifest? _parseManifest(File file) {
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      if (json['format'] != 'nook-sync' || json['version'] != 1) return null;
      final kdf = KdfParams.fromJson(json['kdf'] as Map<String, dynamic>);
      // 正式參數是 128 MiB／3 次／4 線；上限只放寬到兩倍左右，免得被塞一個
      // 每次解鎖要吃好幾 GB、跑好幾十秒的檔案。
      if (kdf.memory > 256 * 1024 ||
          kdf.iterations < 1 ||
          kdf.iterations > 8 ||
          kdf.parallelism < 1 ||
          kdf.parallelism > 8 ||
          kdf.memory < 8 * kdf.parallelism) {
        return null;
      }
      final material = KeyMaterial(
        kdf: kdf,
        wrappedDek: base64Decode(json['wrappedDek'] as String),
        keyChangedAt: DateTime.parse(json['keyChangedAt'] as String).toUtc(),
      );
      return _ParsedManifest(
        file,
        material,
        base64Decode(json['auth'] as String),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _verifyAuth(SecretKey dek, _ParsedManifest parsed) =>
      _verifyAuthWith((sealed) => VaultCrypto.open(dek, sealed), parsed);

  static Future<bool> _verifyAuthWith(
    Future<Uint8List> Function(Uint8List sealed) open,
    _ParsedManifest parsed,
  ) async {
    try {
      final clear = await open(Uint8List.fromList(parsed.auth));
      return utf8.decode(clear) == jsonEncode(_manifestBody(parsed.material));
    } catch (_) {
      return false;
    }
  }

  // ------------------------------------------------------------ 本機同步基準

  Future<_SyncState> _readState() async {
    final state = _SyncState();
    if (!stateFile.existsSync()) return state;
    try {
      final clear = await store.openWithDek(await stateFile.readAsBytes());
      final json = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
      Map<String, DateTime> times(Object? raw) => {
        for (final e in ((raw as Map<String, dynamic>?) ?? const {}).entries)
          e.key: DateTime.parse(e.value as String).toUtc(),
      };
      state.items.addAll(times(json['items']));
      state.deleted.addAll(times(json['deleted']));
      final history = (json['history'] as Map<String, dynamic>?) ?? const {};
      for (final e in history.entries) {
        state.history[e.key] = (e.value as List).cast<String>();
      }
    } catch (_) {
      // 讀不出來（例如別的保險庫留下的）就當成第一次同步：最壞是刪掉的項目回來，
      // 不會有資料被刪。
    }
    return state;
  }

  Future<void> _writeState(_SyncState state) async {
    String iso(DateTime t) => t.toUtc().toIso8601String();
    final sealed = await store.sealWithDek(utf8.encode(jsonEncode({
      'version': 1,
      'items': {for (final e in state.items.entries) e.key: iso(e.value)},
      // 刪掉的也記著：雲端的刪除標記被拿掉、舊檔被放回來時，靠這份擋住復活。
      'deleted': {for (final e in state.deleted.entries) e.key: iso(e.value)},
      // 每筆同意過的版本的內容雜湊（最近 historyLimit 個）。
      'history': state.history,
    })));
    await stateFile.parent.create(recursive: true);
    await _writeAtomic(stateFile, sealed);
  }

  /// 忘掉這台的同步基準（停止同步時）。「上次同步時兩邊同意的版本」丟掉，
  /// 但看過的版本歷史與記得的刪除留著：之後再接上時，刪掉的項目才不會被
  /// 雲端的舊檔帶回來，這台刪除時寫出的名單也才完整。鎖著讀不了就整個刪掉。
  Future<void> forgetState() async {
    if (!store.isUnlocked || !stateFile.existsSync()) {
      await _tryDelete(stateFile);
      return;
    }
    final state = await _readState();
    state.items.clear();
    await _writeState(state);
  }

  // ------------------------------------------------------------ 檔案工具

  /// 資料夾裡要讀的檔：跳過隱藏檔與暫存檔。iCloud 還沒下載的檔案是
  /// `.名稱.icloud` 這種隱藏的佔位檔，記下來讓畫面提示「還在下載」。
  Iterable<File> _listData(Directory dir, SyncReport report) sync* {
    if (!dir.existsSync()) return;
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is! File) continue;
      final name = _basename(entity.path);
      if (name.startsWith('.')) {
        if (name.endsWith('.icloud')) report.pendingDownload++;
        continue;
      }
      if (name.endsWith('.tmp')) continue;
      yield entity;
    }
  }

  static final _rng = Random.secure();

  /// 先寫隱藏的暫存檔再 rename。暫存檔以點開頭，讀的時候會被跳過；
  /// 雲端服務就算先把半成品傳出去，別台也不會去讀它。
  static Future<void> _writeAtomic(File target, List<int> bytes) async {
    final nonce = _rng.nextInt(1 << 32).toRadixString(16);
    final tmp = File(
      '${target.parent.path}/.${_basename(target.path)}.$pid.$nonce.tmp',
    );
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(target.path);
    } catch (_) {
      await _tryDelete(tmp);
      rethrow;
    }
  }

  static Future<void> _tryDelete(File file) async {
    try {
      if (file.existsSync()) await file.delete();
    } on FileSystemException {
      // 雲端服務可能正鎖著它；下一輪再清。
    }
  }

  static String _basename(String path) {
    final i = path.lastIndexOf(RegExp(r'[/\\]'));
    return i < 0 ? path : path.substring(i + 1);
  }

}

/// 內容雜湊（SHA-256 前 16 bytes 的十六進位）。只存在加密的同步基準與刪除標記裡。
String _hash(String canonical) {
  final digest = Sha256().toSync().hashSync(utf8.encode(canonical)).bytes;
  return digest
      .sublist(0, 16)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}

List<String> _remember(List<String> history, String hash) {
  final out = [...history.where((h) => h != hash), hash];
  return out.length > SyncEngine.historyLimit
      ? out.sublist(out.length - SyncEngine.historyLimit)
      : out;
}

/// 比較「內容是否一樣」用的正規形式：不含 lastAccessedAt 與 updatedAt。
String _canonicalJson(VaultItem item) {
  final json = item.toJson()
    ..remove('lastAccessedAt')
    ..remove('updatedAt');
  return jsonEncode(json);
}

class SyncException implements Exception {
  const SyncException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 一輪同步做了什麼，給設定頁顯示。
class SyncReport {
  int pulled = 0;
  int pushed = 0;
  int deletedLocally = 0;
  int deletedRemotely = 0;
  bool keyAdopted = false;

  /// 這一輪新增的衝突副本名稱。
  final List<String> conflictCopies = [];

  /// 讀不出來的檔案（多半是還沒下載完）。不刪、不當成刪除。
  final List<String> unreadable = [];

  /// iCloud 還沒下載到本機的佔位檔數。
  int pendingDownload = 0;

  DateTime? finishedAt;

  final List<VaultItem> _newCopies = [];

  /// 讀不出來、而且剛被改過的檔名（當成還在下載）。
  final Set<String> _inFlight = {};

  bool get changedLocally =>
      pulled > 0 || deletedLocally > 0 || conflictCopies.isNotEmpty || keyAdopted;
}

/// 某一筆在某一邊的某個版本：時間與內容都是讀到當下的快照。
abstract class _Version {
  DateTime get updatedAt;

  /// 不含 lastAccessedAt 與 updatedAt 的 JSON，用來比「內容是否一樣」。
  String get canonical;

  String get hash => _hash(canonical);
}

class _LocalVersion extends _Version {
  _LocalVersion(this.item, this.updatedAt, this.canonical);

  /// 本機的物件本身。編輯器會直接改這個物件，所以內容與時間另外存快照。
  final VaultItem item;
  @override
  final DateTime updatedAt;
  @override
  final String canonical;

  /// 用快照重建一份獨立的物件（存衝突副本用），不受之後的編輯影響。
  VaultItem snapshotItem() {
    final json = jsonDecode(canonical) as Map<String, dynamic>;
    json['updatedAt'] = updatedAt.toUtc().toIso8601String();
    json['lastAccessedAt'] = null;
    return VaultItem.fromJson(json);
  }
}

class _RemoteVersion extends _Version {
  _RemoteVersion(this.file, this.item, this.updatedAt, this.canonical);
  final File file;
  final VaultItem item;
  @override
  final DateTime updatedAt;
  @override
  final String canonical;

  /// 新的排前面；時間一樣時用內容排，兩台機器挑出來的才會是同一份。
  static int newestFirst(_RemoteVersion a, _RemoteVersion b) {
    final byTime = b.updatedAt.compareTo(a.updatedAt);
    return byTime != 0 ? byTime : a.canonical.compareTo(b.canonical);
  }
}

/// 刪除標記：雲端的檔案，加上這台記得的「這筆在某版被刪了」。
class _Tombstone {
  _Tombstone(this.version, this.files);
  DateTime version;

  /// 雲端的刪除標記檔；空的代表只有本機記得（雲端那份不見了）。
  final List<File> files;

  /// 這台原本就記得的刪除版本（沒有就是 null）。
  DateTime? knownVersion;

  /// 刪除者看過的版本的內容雜湊。空的代表沒有這份資訊（舊格式）。
  final Set<String> known = {};

  static _Tombstone? combine(
    _Tombstone? remote,
    DateTime? knownVersion,
    List<String> knownHistory,
  ) {
    if (remote == null && knownVersion == null) return null;
    final t = remote ?? _Tombstone(knownVersion!, []);
    if (knownVersion != null && knownVersion.isAfter(t.version)) {
      t.version = knownVersion;
    }
    t.knownVersion = knownVersion;
    t.known.addAll(knownHistory);
    return t;
  }
}

class _Outcome {
  const _Outcome(this.agreed, this.deleted, {this.agreedHash});

  /// 同意的那個版本的內容雜湊（記進歷史）。
  final String? agreedHash;

  /// 兩邊同意的版本；這筆不存在時是 null。
  final DateTime? agreed;

  /// 這筆被刪了的話，刪除的版本。
  final DateTime? deleted;
}

/// 這台的同步基準。
class _SyncState {
  final Map<String, DateTime> items = {};
  final Map<String, DateTime> deleted = {};
  final Map<String, List<String>> history = {};
}

class _ParsedManifest {
  _ParsedManifest(this.file, this.material, this.auth);
  final File file;
  final KeyMaterial material;
  final List<int> auth;
}

class _ManifestScan {
  final List<_ParsedManifest> authentic = [];
  int foreign = 0;

  _ParsedManifest? get newest {
    _ParsedManifest? best;
    for (final m in authentic) {
      if (best == null ||
          m.material.keyChangedAt.isAfter(best.material.keyChangedAt)) {
        best = m;
      }
    }
    return best;
  }
}

class _Unlocked {
  _Unlocked(this.material, this.dek);
  final KeyMaterial material;
  final List<int> dek;
}
