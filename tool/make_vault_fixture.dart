// 產生 test/fixtures/vault_v1/ 這份「跨平台相容」測試保險庫。
//
//   dart run tool/make_vault_fixture.dart test/fixtures/vault_v1
//
// 這份樣本是刻意凍結的：test/vault_fixture_test.dart 拿它驗證現行程式碼還打得開
// 舊格式（vault.json 版本 1、SM01 檔頭、Argon2id 包住的 DEK），而且在 macOS、
// Windows、Linux 上跑同一個測試，就等於驗證「把 vault/ 整個複製過去就能解鎖」。
// 所以只有在格式真的要升版時才重新產生，平常不要動它。
//
// 全部是捏造的假資料（198.51.100.x 是 RFC 5737 的文件用位址、example.test 是
// 保留網域），KDF 用測試用的輕量參數，主密碼寫在測試裡 —— 這份檔案本來就是公開的。
import 'dart:io';

import 'package:securemanage/vault/models.dart';
import 'package:securemanage/vault/vault_crypto.dart';
import 'package:securemanage/vault/vault_store.dart';

const fixturePassword = 'fixture-master-pw-not-a-secret';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('用法：dart run tool/make_vault_fixture.dart <輸出目錄>');
    exitCode = 2;
    return;
  }
  final root = Directory(args.single);
  if (root.existsSync()) {
    stderr.writeln('${root.path} 已經存在。這份樣本是凍結的，要重產請先自己刪掉。');
    exitCode = 1;
    return;
  }

  final store = VaultStore(
    root,
    kdfFactory: KdfParams.weakForTests,
    ownerOnlyPermissions: false,
  );
  await store.create(fixturePassword);

  final key = SecureKeyItem(
    id: 'fixture-key-0001',
    name: '樣本金鑰',
    algorithm: 'ed25519',
    secret: 'FAKE-FIXTURE-KEY-BODY',
    passphrase: 'fake-fixture-passphrase',
    createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
  );
  await store.put(key);
  await store.put(
    AccountItem(
      id: 'fixture-account-0001',
      name: '樣本帳號',
      url: 'https://example.test/login',
      username: 'fixture-user',
      password: 'fake-fixture-password',
      createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
    ),
  );
  await store.put(
    HostItem(
      id: 'fixture-host-0001',
      name: '樣本主機',
      hostname: '198.51.100.7',
      port: 2222,
      username: 'deploy',
      keyRef: key.id,
      sudoPassword: 'fake-fixture-sudo',
      env: [
        EnvVar(name: 'APP_ENV', value: 'fixture'),
        EnvVar(name: 'API_TOKEN', value: 'fake-fixture-token', secret: true),
      ],
      createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
    ),
  );
  store.lock();
  stdout.writeln('寫好了：${root.path}');
}
