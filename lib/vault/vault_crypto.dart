import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// 加密原語集中在這裡。演算法都來自 package:cryptography，沒有自製的密碼學。
///
/// 兩層金鑰：
///   主密碼 --Argon2id--> KEK（金鑰加密金鑰，不落地）
///   隨機 DEK（資料加密金鑰）被 KEK 包起來存在 vault.json
///   每筆項目用 DEK 加密成獨立檔案
///
/// 這樣改主密碼只要重包 DEK，不必把所有項目重新加密。
class VaultCrypto {
  VaultCrypto._();

  static final _cipher = Chacha20.poly1305Aead();
  static final _rng = Random.secure();

  /// 檔頭魔術字，用來擋掉「拿錯檔案來解」的情況。
  static const magic = [0x53, 0x4d, 0x30, 0x31]; // 'SM01'
  static const nonceLength = 12;
  static const macLength = 16;
  static const dekLength = 32;

  static Uint8List randomBytes(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _rng.nextInt(256);
    }
    return out;
  }

  static Argon2id _argon2(KdfParams params) => Argon2id(
        parallelism: params.parallelism,
        memory: params.memory,
        iterations: params.iterations,
        hashLength: 32,
      );

  /// 主密碼 → KEK。慢是刻意的，這是擋暴力破解的那一道。
  static Future<SecretKey> deriveKek(String password, KdfParams params) async {
    return _argon2(params).deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: params.salt,
    );
  }

  /// 加密成 magic + nonce + mac + ciphertext 的單一位元組串。
  static Future<Uint8List> seal(SecretKey key, List<int> plaintext) async {
    final box = await _cipher.encrypt(
      plaintext,
      secretKey: key,
      nonce: randomBytes(nonceLength),
    );
    final out = BytesBuilder()
      ..add(magic)
      ..add(box.nonce)
      ..add(box.mac.bytes)
      ..add(box.cipherText);
    return out.toBytes();
  }

  /// 解密。密碼錯、檔案被改、檔案不是我們的，都會丟 [VaultOpenException]。
  static Future<Uint8List> open(SecretKey key, Uint8List sealed) async {
    const headerLength = 4 + nonceLength + macLength;
    if (sealed.length < headerLength) {
      throw const VaultOpenException('加密內容不完整');
    }
    for (var i = 0; i < magic.length; i++) {
      if (sealed[i] != magic[i]) {
        throw const VaultOpenException('不是 Nook 的加密內容');
      }
    }
    final box = SecretBox(
      sealed.sublist(headerLength),
      nonce: sealed.sublist(4, 4 + nonceLength),
      mac: Mac(sealed.sublist(4 + nonceLength, headerLength)),
    );
    try {
      final clear = await _cipher.decrypt(box, secretKey: key);
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw const VaultOpenException('解不開：主密碼不對，或檔案已被竄改');
    }
  }

  static Future<Uint8List> newDek() async => randomBytes(dekLength);
}

/// Argon2id 的參數。存在 vault.json 的明文區，讓未來調參後舊檔還解得開。
class KdfParams {
  const KdfParams({
    required this.memory,
    required this.iterations,
    required this.parallelism,
    required this.salt,
  });

  /// 1 KiB 區塊數。65536 = 64 MiB。
  final int memory;
  final int iterations;
  final int parallelism;
  final Uint8List salt;

  /// 測試用的輕量參數。只給 UI 測試用，正式路徑一律走 [fresh]。
  static KdfParams weakForTests() => KdfParams(
        memory: 256,
        iterations: 1,
        parallelism: 1,
        salt: VaultCrypto.randomBytes(16),
      );

  /// 新保險庫的預設強度。參數跟著每個保險庫走，以後調高不會讓舊檔打不開。
  static KdfParams fresh() => KdfParams(
        memory: 131072,
        iterations: 3,
        parallelism: 4,
        salt: VaultCrypto.randomBytes(16),
      );

  Map<String, dynamic> toJson() => {
        'algorithm': 'argon2id',
        'memory': memory,
        'iterations': iterations,
        'parallelism': parallelism,
        'salt': base64Encode(salt),
      };

  factory KdfParams.fromJson(Map<String, dynamic> json) {
    final algorithm = json['algorithm'] as String?;
    if (algorithm != 'argon2id') {
      throw VaultOpenException('不認得的金鑰衍生演算法：$algorithm');
    }
    return KdfParams(
      memory: json['memory'] as int,
      iterations: json['iterations'] as int,
      parallelism: json['parallelism'] as int,
      salt: base64Decode(json['salt'] as String),
    );
  }
}

class VaultOpenException implements Exception {
  const VaultOpenException(this.message);
  final String message;
  @override
  String toString() => message;
}
