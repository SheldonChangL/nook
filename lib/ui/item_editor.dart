import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../vault/models.dart';
import 'theme.dart';
import 'widgets/fields.dart';

Future<VaultItem?> showItemEditor(
  BuildContext context, {
  required AppState state,
  ItemKind? kind,
  VaultItem? existing,
}) {
  return showDialog<VaultItem>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _ItemEditor(
      state: state,
      kind: existing?.kind ?? kind ?? ItemKind.host,
      existing: existing,
    ),
  );
}

class _ItemEditor extends StatefulWidget {
  const _ItemEditor(
      {required this.state, required this.kind, this.existing});

  final AppState state;
  final ItemKind kind;
  final VaultItem? existing;

  @override
  State<_ItemEditor> createState() => _ItemEditorState();
}

class _ItemEditorState extends State<_ItemEditor> {
  final _name = TextEditingController();
  final _notes = TextEditingController();
  var _tags = <String>[];

  // 主機
  final _hostname = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _hostUser = TextEditingController();
  final _jump = TextEditingController();
  final _sudo = TextEditingController();
  String? _keyRef;
  final _env = <EnvVar>[];

  // 金鑰
  KeyKind _keyKind = KeyKind.sshPrivateKey;
  final _algorithm = TextEditingController();
  final _secret = TextEditingController();
  final _passphrase = TextEditingController();

  // 帳號
  final _url = TextEditingController();
  final _accountUser = TextEditingController();
  final _password = TextEditingController();

  bool _nameMissing = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    if (existing == null) return;
    _name.text = existing.name;
    _notes.text = existing.notes;
    _tags = [...existing.tags];
    switch (existing) {
      case final HostItem h:
        _hostname.text = h.hostname;
        _port.text = '${h.port}';
        _hostUser.text = h.username;
        _jump.text = h.jumpHost;
        _sudo.text = h.sudoPassword;
        _keyRef = h.keyRef;
        _env.addAll(h.env.map((e) =>
            EnvVar(name: e.name, value: e.value, secret: e.secret)));
      case final SecureKeyItem k:
        _keyKind = k.keyKind;
        _algorithm.text = k.algorithm;
        _secret.text = k.secret;
        _passphrase.text = k.passphrase;
      case final AccountItem a:
        _url.text = a.url;
        _accountUser.text = a.username;
        _password.text = a.password;
    }
  }

  @override
  void dispose() {
    for (final c in [
      _name, _notes, _hostname, _port, _hostUser, _jump, _sudo,
      _algorithm, _secret, _passphrase, _url, _accountUser, _password,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _nameMissing = true);
      return;
    }
    final existing = widget.existing;
    final VaultItem item;

    switch (widget.kind) {
      case ItemKind.host:
        final host = existing is HostItem
            ? existing
            : HostItem(name: _name.text.trim());
        host
          ..name = _name.text.trim()
          ..notes = _notes.text
          ..tags = _tags
          ..hostname = _hostname.text.trim()
          ..port = int.tryParse(_port.text.trim()) ?? 22
          ..username = _hostUser.text.trim()
          ..jumpHost = _jump.text.trim()
          ..sudoPassword = _sudo.text
          ..keyRef = _keyRef
          ..env = _env
              .where((e) => e.name.trim().isNotEmpty)
              .map((e) => EnvVar(
                  name: e.name.trim(), value: e.value, secret: e.secret))
              .toList();
        item = host;
      case ItemKind.secureKey:
        final key = existing is SecureKeyItem
            ? existing
            : SecureKeyItem(name: _name.text.trim());
        key
          ..name = _name.text.trim()
          ..notes = _notes.text
          ..tags = _tags
          ..keyKind = _keyKind
          ..algorithm = _algorithm.text.trim()
          ..secret = _secret.text
          ..passphrase = _passphrase.text;
        item = key;
      case ItemKind.account:
        final account = existing is AccountItem
            ? existing
            : AccountItem(name: _name.text.trim());
        account
          ..name = _name.text.trim()
          ..notes = _notes.text
          ..tags = _tags
          ..url = _url.text.trim()
          ..username = _accountUser.text.trim()
          ..password = _password.text;
        item = account;
    }

    await widget.state.save(item);
    if (mounted) Navigator.pop(context, item);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 620),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 16, 12),
              child: Row(children: [
                Expanded(
                  child: Text(
                    '${widget.existing == null ? '新增' : '編輯'}${widget.kind.label}',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w500),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => Navigator.pop(context),
                ),
              ]),
            ),
            const Divider(height: 0.5),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _field('名稱', _name,
                        error: _nameMissing ? '名稱不能空白' : null,
                        onChanged: () => setState(() => _nameMissing = false)),
                    const SizedBox(height: 14),
                    ..._kindFields(scheme),
                    const SizedBox(height: 14),
                    _label('標籤'),
                    const SizedBox(height: 6),
                    TagField(
                        tags: _tags,
                        onChanged: (t) => setState(() => _tags = t)),
                    const SizedBox(height: 14),
                    _field('備註', _notes, maxLines: 3),
                  ],
                ),
              ),
            ),
            const Divider(height: 0.5),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
              child: Row(children: [
                Icon(Icons.lock_outline,
                    size: 13, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('存檔時整筆加密',
                      style: TextStyle(
                          fontSize: 11, color: scheme.onSurfaceVariant)),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _save, child: const Text('儲存')),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _kindFields(ColorScheme scheme) {
    switch (widget.kind) {
      case ItemKind.host:
        final keys = widget.state.items.whereType<SecureKeyItem>().toList();
        return [
          Row(children: [
            Expanded(flex: 3, child: _field('Hostname', _hostname)),
            const SizedBox(width: 10),
            Expanded(child: _field('Port', _port)),
          ]),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: _field('登入帳號', _hostUser)),
            const SizedBox(width: 10),
            Expanded(child: _field('跳板機（選填）', _jump)),
          ]),
          const SizedBox(height: 14),
          _label('認證金鑰'),
          const SizedBox(height: 6),
          DropdownButtonFormField<String?>(
            initialValue: _keyRef,
            isDense: true,
            items: [
              const DropdownMenuItem(value: null, child: Text('不指定')),
              for (final key in keys)
                DropdownMenuItem(
                    value: key.id,
                    child: Text('${key.name}（${key.keyKind.label}）')),
            ],
            onChanged: (v) => setState(() => _keyRef = v),
          ),
          const SizedBox(height: 14),
          _field('sudo 密碼（選填）', _sudo, obscure: true),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: _label('環境變數')),
            TextButton.icon(
              onPressed: () => setState(
                  () => _env.add(EnvVar(name: '', value: ''))),
              icon: const Icon(Icons.add, size: 14),
              label: const Text('加一條', style: TextStyle(fontSize: 12)),
            ),
          ]),
          for (var i = 0; i < _env.length; i++) _envRow(i, scheme),
          if (_env.isEmpty)
            Text('還沒有環境變數',
                style:
                    TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ];

      case ItemKind.secureKey:
        return [
          _label('種類'),
          const SizedBox(height: 6),
          SegmentedButton<KeyKind>(
            segments: [
              for (final k in KeyKind.values)
                ButtonSegment(
                    value: k,
                    label: Text(k.label,
                        style: const TextStyle(fontSize: 12))),
            ],
            selected: {_keyKind},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _keyKind = s.first),
          ),
          const SizedBox(height: 14),
          _field('演算法 / 備註標記（選填，例如 ed25519）', _algorithm),
          const SizedBox(height: 14),
          _field(
            _keyKind == KeyKind.apiToken ? 'Token' : '金鑰內容',
            _secret,
            maxLines: 6,
            monospace: true,
          ),
          const SizedBox(height: 14),
          _field('Passphrase（選填）', _passphrase, obscure: true),
        ];

      case ItemKind.account:
        return [
          _field('網址', _url),
          const SizedBox(height: 14),
          _field('使用者名稱', _accountUser),
          const SizedBox(height: 14),
          _field('密碼', _password, obscure: true),
        ];
    }
  }

  Widget _envRow(int index, ColorScheme scheme) {
    final env = _env[index];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(children: [
        Expanded(
          flex: 2,
          child: TextFormField(
            initialValue: env.name,
            onChanged: (v) => env.name = v,
            style: monoStyle(),
            decoration: const InputDecoration(hintText: 'NAME'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 3,
          child: TextFormField(
            initialValue: env.value,
            onChanged: (v) => env.value = v,
            obscureText: env.secret,
            style: monoStyle(),
            decoration: const InputDecoration(hintText: 'value'),
          ),
        ),
        const SizedBox(width: 4),
        Tooltip(
          // 連線字串這種你會想一眼看到的就不勾，token 才勾。
          message: env.secret ? '機密，列表與詳情都會遮起來' : '一般資料，直接顯示',
          child: IconButton(
            icon: Icon(
                env.secret ? Icons.lock_outline : Icons.lock_open_outlined,
                size: 16),
            color: env.secret ? scheme.primary : scheme.onSurfaceVariant,
            onPressed: () => setState(() => env.secret = !env.secret),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close, size: 15),
          onPressed: () => setState(() => _env.removeAt(index)),
        ),
      ]),
    );
  }

  Widget _label(String text) => Text(text,
      style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant));

  Widget _field(
    String label,
    TextEditingController controller, {
    bool obscure = false,
    int maxLines = 1,
    bool monospace = false,
    String? error,
    VoidCallback? onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(label),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          obscureText: obscure,
          maxLines: obscure ? 1 : maxLines,
          onChanged: (_) => onChanged?.call(),
          style: TextStyle(
              fontSize: 13,
              fontFamily: monospace ? monoFamily : null,
              fontFamilyFallback: monospace ? monoFallback : null),
          decoration: InputDecoration(errorText: error),
        ),
      ],
    );
  }
}
