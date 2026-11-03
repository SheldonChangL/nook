import 'package:uuid/uuid.dart';

const _uuid = Uuid();

enum ItemKind {
  secureKey('金鑰', 'secure_key'),
  account('帳號', 'account'),
  host('主機 / VM', 'host');

  const ItemKind(this.label, this.wire);
  final String label;
  final String wire;

  static ItemKind fromWire(String wire) =>
      ItemKind.values.firstWhere((k) => k.wire == wire);
}

enum KeyKind {
  sshPrivateKey('SSH 私鑰', 'ssh_private_key'),
  apiToken('API token', 'api_token'),
  certificate('憑證', 'certificate');

  const KeyKind(this.label, this.wire);
  final String label;
  final String wire;

  static KeyKind fromWire(String wire) =>
      KeyKind.values.firstWhere((k) => k.wire == wire, orElse: () => apiToken);
}

/// 主機上的一條環境變數。[secret] 決定它在畫面上是否要遮起來。
class EnvVar {
  EnvVar({required this.name, required this.value, this.secret = false});

  String name;
  String value;
  bool secret;

  Map<String, dynamic> toJson() =>
      {'name': name, 'value': value, 'secret': secret};

  factory EnvVar.fromJson(Map<String, dynamic> json) => EnvVar(
        name: json['name'] as String? ?? '',
        value: json['value'] as String? ?? '',
        secret: json['secret'] as bool? ?? false,
      );
}

/// 所有項目共用的欄位。子類別各自帶自己的內容。
abstract class VaultItem {
  VaultItem({
    String? id,
    required this.name,
    List<String>? tags,
    this.notes = '',
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : id = id ?? _uuid.v4(),
        tags = tags ?? <String>[],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  final String id;
  String name;
  List<String> tags;
  String notes;
  final DateTime createdAt;
  DateTime updatedAt;

  ItemKind get kind;

  /// 列表那一行的副標。只放辨識用的中繼資料，不放任何機密。
  String get subtitle;

  /// 可供搜尋的文字。同樣不含機密，免得搜尋索引變成洩漏管道。
  String get searchText => '$name ${tags.join(' ')} $subtitle';

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.wire,
        'name': name,
        'tags': tags,
        'notes': notes,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        ...payload(),
      };

  Map<String, dynamic> payload();

  static VaultItem fromJson(Map<String, dynamic> json) {
    final kind = ItemKind.fromWire(json['kind'] as String);
    return switch (kind) {
      ItemKind.secureKey => SecureKeyItem.fromJson(json),
      ItemKind.account => AccountItem.fromJson(json),
      ItemKind.host => HostItem.fromJson(json),
    };
  }
}

class SecureKeyItem extends VaultItem {
  SecureKeyItem({
    super.id,
    required super.name,
    super.tags,
    super.notes,
    super.createdAt,
    super.updatedAt,
    this.keyKind = KeyKind.sshPrivateKey,
    this.algorithm = '',
    this.secret = '',
    this.passphrase = '',
  });

  KeyKind keyKind;

  /// 像 ed25519、RSA-4096。純中繼資料，不是機密。
  String algorithm;

  /// 私鑰本文或 token。機密。
  String secret;

  /// 私鑰的 passphrase。機密。
  String passphrase;

  @override
  ItemKind get kind => ItemKind.secureKey;

  @override
  String get subtitle {
    final parts = <String>[keyKind.label];
    if (algorithm.isNotEmpty) parts.add(algorithm);
    parts.add(passphrase.isEmpty ? '無 passphrase' : '有 passphrase');
    return parts.join(' · ');
  }

  @override
  Map<String, dynamic> payload() => {
        'keyKind': keyKind.wire,
        'algorithm': algorithm,
        'secret': secret,
        'passphrase': passphrase,
      };

  factory SecureKeyItem.fromJson(Map<String, dynamic> json) => SecureKeyItem(
        id: json['id'] as String,
        name: json['name'] as String,
        tags: (json['tags'] as List?)?.cast<String>(),
        notes: json['notes'] as String? ?? '',
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
        keyKind: KeyKind.fromWire(json['keyKind'] as String? ?? ''),
        algorithm: json['algorithm'] as String? ?? '',
        secret: json['secret'] as String? ?? '',
        passphrase: json['passphrase'] as String? ?? '',
      );
}

class AccountItem extends VaultItem {
  AccountItem({
    super.id,
    required super.name,
    super.tags,
    super.notes,
    super.createdAt,
    super.updatedAt,
    this.url = '',
    this.username = '',
    this.password = '',
  });

  String url;
  String username;

  /// 機密。
  String password;

  @override
  ItemKind get kind => ItemKind.account;

  @override
  String get subtitle {
    final parts = <String>[];
    if (url.isNotEmpty) parts.add(url);
    if (username.isNotEmpty) parts.add(username);
    return parts.isEmpty ? '未填網址與帳號' : parts.join(' · ');
  }

  @override
  Map<String, dynamic> payload() =>
      {'url': url, 'username': username, 'password': password};

  factory AccountItem.fromJson(Map<String, dynamic> json) => AccountItem(
        id: json['id'] as String,
        name: json['name'] as String,
        tags: (json['tags'] as List?)?.cast<String>(),
        notes: json['notes'] as String? ?? '',
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
        url: json['url'] as String? ?? '',
        username: json['username'] as String? ?? '',
        password: json['password'] as String? ?? '',
      );
}

class HostItem extends VaultItem {
  HostItem({
    super.id,
    required super.name,
    super.tags,
    super.notes,
    super.createdAt,
    super.updatedAt,
    this.hostname = '',
    this.port = 22,
    this.username = '',
    this.keyRef,
    this.jumpHost = '',
    this.sudoPassword = '',
    List<EnvVar>? env,
  }) : env = env ?? <EnvVar>[];

  String hostname;
  int port;
  String username;

  /// 指向某個 [SecureKeyItem] 的 id。一把金鑰給多台機器用時只存一份。
  String? keyRef;
  String jumpHost;

  /// 機密。
  String sudoPassword;
  List<EnvVar> env;

  @override
  ItemKind get kind => ItemKind.host;

  @override
  String get subtitle {
    final target = [
      if (username.isNotEmpty) '$username@',
      hostname.isEmpty ? '未填位址' : hostname,
      ':$port',
    ].join();
    final parts = <String>[target];
    if (env.isNotEmpty) parts.add('${env.length} 個環境變數');
    if (jumpHost.isNotEmpty) parts.add('經由跳板機');
    return parts.join(' · ');
  }

  /// 給使用者直接複製去終端機用。不含任何機密。
  String get sshCommand {
    final buffer = StringBuffer('ssh ');
    if (jumpHost.isNotEmpty) buffer.write('-J $jumpHost ');
    if (port != 22) buffer.write('-p $port ');
    if (username.isNotEmpty) buffer.write('$username@');
    buffer.write(hostname);
    return buffer.toString();
  }

  @override
  Map<String, dynamic> payload() => {
        'hostname': hostname,
        'port': port,
        'username': username,
        'keyRef': keyRef,
        'jumpHost': jumpHost,
        'sudoPassword': sudoPassword,
        'env': env.map((e) => e.toJson()).toList(),
      };

  factory HostItem.fromJson(Map<String, dynamic> json) => HostItem(
        id: json['id'] as String,
        name: json['name'] as String,
        tags: (json['tags'] as List?)?.cast<String>(),
        notes: json['notes'] as String? ?? '',
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
        hostname: json['hostname'] as String? ?? '',
        port: json['port'] as int? ?? 22,
        username: json['username'] as String? ?? '',
        keyRef: json['keyRef'] as String?,
        jumpHost: json['jumpHost'] as String? ?? '',
        sudoPassword: json['sudoPassword'] as String? ?? '',
        env: (json['env'] as List?)
            ?.map((e) => EnvVar.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// 畫面上一個可揭露 / 可複製的機密欄位。
class SecretField {
  const SecretField({required this.label, required this.value});
  final String label;
  final String value;
}

/// 畫面上直接顯示的一般欄位。
class PlainField {
  const PlainField({required this.label, required this.value, this.copyable = true});
  final String label;
  final String value;
  final bool copyable;
}
