import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:securemanage/app/instance_lock.dart';

/// 單一執行個體保護要防的是「另一個程序」，所以主要的測試真的另開程序：
/// 這裡用 Flutter SDK 附的 dart 另開程序跑 test/support/hold_instance_lock.dart，
/// 它用的是跟 App 一模一樣的 InstanceLock。
String _dartExecutable() {
  final exe = Platform.isWindows ? 'dart.exe' : 'dart';
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    final bundled = File('$root/bin/cache/dart-sdk/bin/$exe');
    if (bundled.existsSync()) return bundled.path;
  }
  // 找不到 FLUTTER_ROOT 時退回 PATH 上的 dart。
  return exe;
}

class _Holder {
  _Holder(this.process, this.lines);
  final Process process;
  final StreamIterator<String> lines;

  static Future<_Holder> start(File lockFile) async {
    final p = await Process.start(_dartExecutable(), [
      'test/support/hold_instance_lock.dart',
      lockFile.path,
    ]);
    unawaited(p.stderr.transform(utf8.decoder).forEach(stderr.write));
    final lines = StreamIterator(
      p.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    return _Holder(p, lines);
  }

  Future<String> firstLine() async {
    final ok = await lines.moveNext().timeout(const Duration(seconds: 90));
    if (!ok) throw StateError('子程序沒有輸出就結束了');
    return lines.current;
  }
}

void main() {
  late Directory tmp;
  late File lockFile;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('nook_lock_');
    // 模擬「應用程式支援目錄」，保險庫與鎖檔都在這底下。
    lockFile = File('${tmp.path}${Platform.pathSeparator}nook.lock');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('另一個程序握著鎖時，這邊拿不到；那邊結束後就拿得到', () async {
    final holder = await _Holder.start(lockFile);
    expect(await holder.firstLine(), 'LOCKED');

    expect(
      InstanceLock.tryAcquire(lockFile),
      isNull,
      reason: '第二個執行個體必須被擋下，不然兩邊會交錯改寫 vault.json',
    );

    // 第三個程序也一樣被擋。
    final third = await _Holder.start(lockFile);
    expect(await third.firstLine(), 'BUSY');
    expect(await third.process.exitCode, 3);

    await holder.process.stdin.close();
    expect(await holder.process.exitCode, 0);

    final mine = InstanceLock.tryAcquire(lockFile);
    expect(mine, isNotNull);
    expect(mine!.isHeld, isTrue);

    // 換我們握著時，別的程序拿不到。
    final other = await _Holder.start(lockFile);
    expect(await other.firstLine(), 'BUSY');
    expect(await other.process.exitCode, 3);
    mine.release();
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('握鎖的程序被強制終止，鎖自動釋放、不會留下殘鎖', () async {
    final holder = await _Holder.start(lockFile);
    expect(await holder.firstLine(), 'LOCKED');
    expect(InstanceLock.tryAcquire(lockFile), isNull);

    holder.process.kill(ProcessSignal.sigkill);
    await holder.process.exitCode;

    expect(lockFile.existsSync(), isTrue, reason: '鎖檔留著沒關係，有沒有被鎖才算數');
    final mine = InstanceLock.tryAcquire(lockFile);
    expect(mine, isNotNull, reason: '當機後重開不該被自己擋在門外');
    mine!.release();
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('同一個程序裡第二次取得也會失敗，釋放後才拿得到', () {
    // 改用 flock／不共用的 CreateFileW 之後，鎖綁在「開啟的檔案」上而不是程序上。
    final first = InstanceLock.tryAcquire(lockFile);
    expect(first, isNotNull);
    expect(InstanceLock.tryAcquire(lockFile), isNull);
    first!.release();
    expect(first.isHeld, isFalse);
    final again = InstanceLock.tryAcquire(lockFile);
    expect(again, isNotNull);
    again!.release();
  });

  test('鎖檔開不了時丟例外，不會被當成「拿到鎖」', () {
    // 父路徑是一個普通檔案，目錄建不起來，鎖檔也就開不了。
    final blocker = File('${tmp.path}${Platform.pathSeparator}not-a-dir')
      ..writeAsStringSync('x');
    final bad = File('${blocker.path}${Platform.pathSeparator}nook.lock');
    expect(
      () => InstanceLock.tryAcquire(bad),
      throwsA(isA<FileSystemException>()),
    );
  });
}
