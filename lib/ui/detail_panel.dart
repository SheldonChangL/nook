import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../vault/models.dart';
import 'theme.dart';
import 'widgets/fields.dart';
import 'widgets/motion.dart';

/// 詳情面板。從被點的那一列長出來（素材庫 #216），內容再逐列浮現（#125）。
class DetailPanel extends StatelessWidget {
  const DetailPanel({
    super.key,
    required this.state,
    required this.item,
    required this.visible,
    required this.onClose,
    required this.onEdit,
    required this.onDelete,
    required this.onOpenRef,
  });

  final AppState state;
  final VaultItem item;

  /// 面板已經展開到位，才開始放內容，免得縮放中途文字擠在一起。
  final bool visible;
  final VoidCallback onClose;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final void Function(VaultItem) onOpenRef;

  void _copy(BuildContext context, String value, String label) {
    state.copySecret(value, label: label);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: panelDecoration(context, strong: true),
      clipBehavior: Clip.antiAlias,
      child: !visible
          ? const SizedBox.shrink()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                RiseIn(child: _header(context, scheme)),
                const Divider(height: 0.5),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: _body(context),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _header(BuildContext context, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
      child: Row(children: [
        Icon(
          switch (item.kind) {
            ItemKind.host => Icons.dns_outlined,
            ItemKind.secureKey => Icons.key_outlined,
            ItemKind.account => Icons.person_outline,
          },
          size: 19,
          color: scheme.onSurfaceVariant,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.name,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w500)),
              Text(item.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11.5, color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.edit_outlined, size: 17),
          tooltip: '編輯',
          onPressed: onEdit,
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline, size: 17),
          tooltip: '刪除',
          color: scheme.error,
          onPressed: onDelete,
        ),
        IconButton(
          icon: const Icon(Icons.close, size: 17),
          tooltip: '關閉',
          onPressed: onClose,
        ),
      ]),
    );
  }

  List<Widget> _body(BuildContext context) {
    final rows = <Widget>[];
    var index = 0;
    void add(Widget child) {
      rows.add(RiseIn(
          delay: Motion.stagger * (index++).clamp(0, 8), child: child));
    }

    switch (item) {
      case final HostItem host:
        add(PlainRow(
            label: 'Hostname',
            value: host.hostname,
            monospace: true,
            onCopy: () => _copy(context, host.hostname, '主機位址')));
        add(PlainRow(
            label: '使用者 · Port',
            value: '${host.username.isEmpty ? '—' : host.username} · ${host.port}'));
        if (host.jumpHost.isNotEmpty) {
          add(PlainRow(
              label: '跳板機', value: host.jumpHost, monospace: true));
        }
        add(PlainRow(
          label: 'ssh 指令',
          value: host.sshCommand,
          monospace: true,
          onCopy: () => _copy(context, host.sshCommand, 'ssh 指令'),
        ));

        final key = state.resolveKey(host.keyRef);
        if (host.keyRef != null) {
          add(_KeyRefRow(
            key: ValueKey(host.keyRef),
            resolved: key,
            onOpen: key == null ? null : () => onOpenRef(key),
          ));
        }

        if (host.sudoPassword.isNotEmpty) {
          add(_divider(context));
          add(SecretRow(
            label: 'sudo 密碼',
            value: host.sudoPassword,
            onCopy: () => _copy(context, host.sudoPassword, 'sudo 密碼'),
          ));
        }

        if (host.env.isNotEmpty) {
          add(_divider(context));
          add(_sectionLabel(context, '環境變數'));
          for (final env in host.env) {
            if (env.secret) {
              add(SecretRow(
                label: env.name,
                value: env.value,
                onCopy: () => _copy(context, env.value, env.name),
              ));
            } else {
              add(PlainRow(
                label: env.name,
                value: env.value,
                monospace: true,
                onCopy: () => _copy(context, env.value, env.name),
              ));
            }
          }
          add(_EnvExportRow(
            host: host,
            onCopy: (text) => _copy(context, text, '所有環境變數'),
          ));
        }

      case final SecureKeyItem key:
        add(PlainRow(label: '種類', value: key.keyKind.label));
        if (key.algorithm.isNotEmpty) {
          add(PlainRow(label: '演算法', value: key.algorithm));
        }
        add(_divider(context));
        add(SecretRow(
          label: key.keyKind == KeyKind.apiToken ? 'Token' : '金鑰內容',
          value: key.secret,
          onCopy: () => _copy(context, key.secret, key.name),
        ));
        if (key.passphrase.isNotEmpty) {
          add(SecretRow(
            label: 'Passphrase',
            value: key.passphrase,
            onCopy: () => _copy(context, key.passphrase, 'passphrase'),
          ));
        }
        final users = state.items
            .whereType<HostItem>()
            .where((h) => h.keyRef == key.id)
            .toList();
        if (users.isNotEmpty) {
          add(_divider(context));
          add(_sectionLabel(context, '這把金鑰被誰用'));
          for (final host in users) {
            add(_UsedByRow(host: host, onOpen: () => onOpenRef(host)));
          }
        }

      case final AccountItem account:
        add(PlainRow(
            label: '網址',
            value: account.url,
            onCopy: () => _copy(context, account.url, '網址')));
        add(PlainRow(
          label: '使用者名稱',
          value: account.username,
          onCopy: () => _copy(context, account.username, '使用者名稱'),
        ));
        add(_divider(context));
        add(SecretRow(
          label: '密碼',
          value: account.password,
          onCopy: () => _copy(context, account.password, '${account.name} 密碼'),
        ));
    }

    if (item.tags.isNotEmpty) {
      add(_divider(context));
      add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Wrap(
          spacing: 6,
          children: [
            for (final tag in item.tags)
              Chip(
                label: Text(tag, style: const TextStyle(fontSize: 11)),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
          ],
        ),
      ));
    }

    if (item.notes.isNotEmpty) {
      add(_divider(context));
      add(_sectionLabel(context, '備註'));
      add(Padding(
        padding: const EdgeInsets.only(top: 2),
        child: SelectableText(item.notes,
            style: const TextStyle(fontSize: 13, height: 1.6)),
      ));
    }

    add(_divider(context));
    add(Text(
      '建立於 ${_stamp(item.createdAt)}．上次更新 ${_stamp(item.updatedAt)}',
      style: TextStyle(
          fontSize: 11,
          color: Theme.of(context).colorScheme.onSurfaceVariant),
    ));

    return rows;
  }

  Widget _divider(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Divider(height: 0.5),
      );

  Widget _sectionLabel(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(text,
            style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}

/// 主機引用的那把金鑰。金鑰被刪掉時要講清楚，不要留一個空白。
class _KeyRefRow extends StatelessWidget {
  const _KeyRefRow({super.key, required this.resolved, required this.onOpen});

  final SecureKeyItem? resolved;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        SizedBox(
          width: 110,
          child: Text('認證金鑰',
              style:
                  TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ),
        if (resolved == null)
          Text('引用的金鑰已被刪除',
              style: TextStyle(fontSize: 13, color: scheme.error))
        else
          TextButton.icon(
            onPressed: onOpen,
            icon: const Icon(Icons.key_outlined, size: 14),
            label: Text(resolved!.name,
                style: const TextStyle(fontSize: 13)),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
      ]),
    );
  }
}

class _UsedByRow extends StatelessWidget {
  const _UsedByRow({required this.host, required this.onOpen});

  final HostItem host;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: onOpen,
        icon: const Icon(Icons.dns_outlined, size: 14),
        label: Text('${host.name}　${host.subtitle}',
            style: const TextStyle(fontSize: 12)),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }
}

/// 把整組環境變數倒成一串 export，貼進終端機就能用。
class _EnvExportRow extends StatelessWidget {
  const _EnvExportRow({required this.host, required this.onCopy});

  final HostItem host;
  final void Function(String) onCopy;

  @override
  Widget build(BuildContext context) {
    final text = host.env
        .map((e) => "export ${e.name}='${e.value.replaceAll("'", r"'\''")}'")
        .join('\n');
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: () => onCopy(text),
          icon: const Icon(Icons.terminal_outlined, size: 14),
          label: const Text('複製成 export 指令',
              style: TextStyle(fontSize: 12)),
        ),
      ),
    );
  }
}

String _stamp(DateTime t) =>
    '${t.year}/${t.month.toString().padLeft(2, '0')}/${t.day.toString().padLeft(2, '0')} '
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
