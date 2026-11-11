// 給 instance_lock_test 用的「另一個程序」：單一執行個體保護防的是另一個程序，
// 所以要在獨立的 Dart 程序裡跑。
//
// 用法：dart test/support/hold_instance_lock.dart <鎖檔路徑>
// 拿到鎖印 LOCKED 並一直握著，直到 stdin 關閉；拿不到印 BUSY 後以 3 結束。
import 'dart:convert';
import 'dart:io';

import 'package:securemanage/app/instance_lock.dart';

Future<void> main(List<String> args) async {
  final lock = InstanceLock.tryAcquire(File(args.single));
  if (lock == null) {
    stdout.writeln('BUSY');
    await stdout.flush();
    exit(3);
  }
  stdout.writeln('LOCKED');
  await stdout.flush();
  await stdin.transform(utf8.decoder).drain<void>();
  lock.release();
  exit(0);
}
