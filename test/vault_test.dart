import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:securemanage/vault/models.dart';
import 'package:securemanage/vault/vault_crypto.dart';
import 'package:securemanage/vault/vault_store.dart';

/// 測試一律用這裡捏造的假資料，不碰任何真實憑證。
const testPassword = 'correct-horse-battery-staple-9471';
const wrongPassword = 'correct-horse-battery-staple-9472';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('securemanage_test_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('建立 → 寫入 → 關閉 → 重開解鎖 → 讀得回來', () async {
    final first = VaultStore(tmp);
    expect(first.exists, isFalse);

    await first.create(testPassword);
    expect(first.exists, isTrue);
    expect(first.isUnlocked, isTrue);

    final key = SecureKeyItem(
      name: '假的部署金鑰',
      keyKind: KeyKind.sshPrivateKey,
      algorithm: 'ed25519',
      secret: 'FAKE-KEY-BODY-NOT-A-REAL-KEY',
      passphrase: 'fake-passphrase',
      tags: ['lab'],
    );
    final host = HostItem(
      name: 'testbox',
      hostname: '198.51.100.7',
      port: 2222,
      username: 'tester',
      keyRef: key.id,
      sudoPassword: 'fake-sudo-pw',
      env: [
        EnvVar(name: 'FAKE_TOKEN', value: 'fake-token-value', secret: true),
        EnvVar(name: 'PG_DSN', value: 'postgres://fake@localhost/fake'),
      ],
      tags: ['lab'],
    );
    final account = AccountItem(
      name: '假的 wiki',
      url: 'wiki.example.test',
      username: 'tester',
      password: 'fake-account-pw',
    );

    await first.put(key);
    await first.put(host);
    await first.put(account);
    expect(first.items.length, 3);

    // 關掉這個 instance，模擬 app 結束。
    first.lock();
    expect(first.isUnlocked, isFalse);
    expect(first.items, isEmpty);

    // 完全新的 instance，模擬重開 app。
    final second = VaultStore(tmp);
    expect(second.isUnlocked, isFalse);
    expect(second.items, isEmpty, reason: '還沒解鎖就不該有任何項目');

    await second.unlock(testPassword);
    expect(second.items.length, 3);

    final readKey = second.byId(key.id) as SecureKeyItem;
    expect(readKey.name, '假的部署金鑰');
    expect(readKey.secret, 'FAKE-KEY-BODY-NOT-A-REAL-KEY');
    expect(readKey.passphrase, 'fake-passphrase');
    expect(readKey.algorithm, 'ed25519');

    final readHost = second.byId(host.id) as HostItem;
    expect(readHost.hostname, '198.51.100.7');
    expect(readHost.port, 2222);
    expect(readHost.keyRef, key.id);
    expect(readHost.sudoPassword, 'fake-sudo-pw');
    expect(readHost.env.length, 2);
    expect(readHost.env.first.secret, isTrue);
    expect(readHost.env.last.secret, isFalse);
    expect(readHost.sshCommand, 'ssh -p 2222 tester@198.51.100.7');

    final readAccount = second.byId(account.id) as AccountItem;
    expect(readAccount.password, 'fake-account-pw');
  });

  test('密碼錯就打不開', () async {
    final store = VaultStore(tmp);
    await store.create(testPassword);
    await store.put(AccountItem(name: '假帳號', password: 'fake-pw'));

    final reopened = VaultStore(tmp);
    await expectLater(
      reopened.unlock(wrongPassword),
      throwsA(isA<VaultOpenException>()),
    );
    expect(reopened.isUnlocked, isFalse);
    expect(reopened.items, isEmpty);
  });

  test('落地的檔案裡找不到任何明文，連項目名稱都看不到', () async {
    final store = VaultStore(tmp);
    await store.create(testPassword);
    await store.put(
      HostItem(
        name: 'secret-host-name',
        hostname: '198.51.100.9',
        sudoPassword: 'fake-sudo-pw',
        env: [
          EnvVar(name: 'FAKE_TOKEN', value: 'fake-token-value', secret: true),
        ],
      ),
    );

    final needles = [
      'secret-host-name',
      '198.51.100.9',
      'fake-sudo-pw',
      'fake-token-value',
      'FAKE_TOKEN',
      testPassword,
    ];

    final files = tmp.listSync(recursive: true).whereType<File>().toList();
    expect(files.length, greaterThanOrEqualTo(2));

    for (final file in files) {
      final bytes = file.readAsBytesSync();
      final asText = String.fromCharCodes(bytes);
      for (final needle in needles) {
        expect(
          asText.contains(needle),
          isFalse,
          reason: '${file.path} 裡出現了明文「$needle」',
        );
      }
    }
  });

  test('檔案被竄改就解不開，不會悄悄解出垃圾', () async {
    final store = VaultStore(tmp);
    await store.create(testPassword);
    final item = AccountItem(name: '假帳號', password: 'fake-pw');
    await store.put(item);

    final itemFile = File('${tmp.path}/items/${item.id}.item');
    final bytes = itemFile.readAsBytesSync();
    // 改掉密文中間一個位元組。
    bytes[bytes.length - 5] = bytes[bytes.length - 5] ^ 0xff;
    itemFile.writeAsBytesSync(bytes);

    final reopened = VaultStore(tmp);
    await expectLater(
      reopened.unlock(testPassword),
      throwsA(isA<VaultOpenException>()),
    );
  });

  test('換主密碼後舊密碼失效、資料還在', () async {
    final store = VaultStore(tmp);
    await store.create(testPassword);
    final item = AccountItem(name: '假帳號', password: 'fake-pw');
    await store.put(item);

    const newPassword = 'another-fake-master-password-55';
    await store.changePassword(testPassword, newPassword);

    final reopened = VaultStore(tmp);
    await expectLater(
      reopened.unlock(testPassword),
      throwsA(isA<VaultOpenException>()),
    );

    final again = VaultStore(tmp);
    await again.unlock(newPassword);
    expect((again.byId(item.id) as AccountItem).password, 'fake-pw');
  });

  test('Touch ID 用的 DEK 可以直接解鎖', () async {
    final store = VaultStore(tmp);
    await store.create(testPassword);
    final item = AccountItem(name: '假帳號', password: 'fake-pw');
    await store.put(item);
    final dek = await store.exportDek();
    expect(dek.length, 32);

    final reopened = VaultStore(tmp);
    await reopened.unlockWithDek(dek);
    expect((reopened.byId(item.id) as AccountItem).password, 'fake-pw');
  });

  test('外觀模式會寫進公開設定，尚未解鎖也讀得到', () async {
    final store = VaultStore(tmp);
    await store.create(testPassword);
    store.settings.darkAppearance = false;
    await store.saveSettings();
    store.lock();

    final reopened = VaultStore(tmp);
    await reopened.loadSettings();

    expect(reopened.isUnlocked, isFalse);
    expect(reopened.settings.darkAppearance, isFalse);
  });

  test('Argon2id 解鎖耗時落在可接受範圍', () async {
    final params = KdfParams.fresh();
    final watch = Stopwatch()..start();
    await VaultCrypto.deriveKek(testPassword, params);
    watch.stop();
    // ignore: avoid_print
    print(
      'Argon2id(memory=${params.memory}KiB, iterations=${params.iterations})'
      ' 耗時 ${watch.elapsedMilliseconds} ms',
    );
    expect(
      watch.elapsedMilliseconds,
      greaterThan(50),
      reason: '太快代表參數被調弱了，擋不住暴力破解',
    );
  });

  test('magic 不對的檔案會被擋下來', () async {
    final store = VaultStore(tmp);
    await store.create(testPassword);
    final dek = await store.exportDek();
    final junk = Uint8List.fromList(List.filled(64, 7));
    await expectLater(
      VaultCrypto.open(SecretKey(dek), junk),
      throwsA(isA<VaultOpenException>()),
    );
  });
}
