import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_state.dart';
import '../vault/models.dart';
import 'theme.dart';
import 'widgets/motion.dart';

/// 素材庫 #321「鍵盤喚出搜尋清單」。
///
/// 按 ⌘K、打幾個字、Enter，密碼就進剪貼簿，整個過程不必看視窗。預期這會是
/// 這個工具最常用的入口，所以 Enter 給的是「複製」而不是「開啟」。
Future<VaultItem?> showCommandPalette(
  BuildContext context, {
  required AppState state,
}) {
  return showDialog<VaultItem>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.2),
    builder: (context) => _CommandPalette(state: state),
  );
}

/// 一個項目最常被複製的那一份機密。沒有就回 null。
({String label, String value})? primarySecret(VaultItem item) {
  switch (item) {
    case final AccountItem a:
      if (a.password.isEmpty) return null;
      return (label: '${a.name} 密碼', value: a.password);
    case final SecureKeyItem k:
      if (k.secret.isEmpty) return null;
      return (label: k.name, value: k.secret);
    case final HostItem h:
      if (h.sudoPassword.isNotEmpty) {
        return (label: '${h.name} sudo 密碼', value: h.sudoPassword);
      }
      final secretEnv = h.env.where((e) => e.secret && e.value.isNotEmpty);
      if (secretEnv.isNotEmpty) {
        return (
          label: '${h.name} ${secretEnv.first.name}',
          value: secretEnv.first.value
        );
      }
      if (h.hostname.isEmpty) return null;
      return (label: '${h.name} ssh 指令', value: h.sshCommand);
  }
  return null;
}

class _CommandPalette extends StatefulWidget {
  const _CommandPalette({required this.state});

  final AppState state;

  @override
  State<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<_CommandPalette> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  int _cursor = 0;

  List<VaultItem> get _results {
    final query = _controller.text.trim().toLowerCase();
    final items = widget.state.items;
    if (query.isEmpty) return items.take(8).toList();
    return items
        .where((i) => i.searchText.toLowerCase().contains(query))
        .take(8)
        .toList();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _move(int delta) {
    final max = _results.length;
    if (max == 0) return;
    setState(() => _cursor = (_cursor + delta) % max);
  }

  void _copySelected() {
    final results = _results;
    if (results.isEmpty) return;
    final item = results[_cursor.clamp(0, results.length - 1)];
    final secret = primarySecret(item);
    if (secret == null) {
      // 沒有可複製的機密就改成開啟詳情，不要讓 Enter 變成無反應。
      Navigator.pop(context, item);
      return;
    }
    widget.state.copySecret(secret.value, label: secret.label);
    Navigator.pop(context);
  }

  void _openSelected() {
    final results = _results;
    if (results.isEmpty) return;
    Navigator.pop(context, results[_cursor.clamp(0, results.length - 1)]);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final results = _results;

    return Align(
      alignment: const Alignment(0, -0.55),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
          const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
          const SingleActivator(LogicalKeyboardKey.enter): _copySelected,
          const SingleActivator(LogicalKeyboardKey.enter, meta: true):
              _openSelected,
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.pop(context),
        },
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: 440,
            decoration: panelDecoration(context, strong: true),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _controller,
                  focusNode: _focus,
                  autofocus: true,
                  onChanged: (_) => setState(() => _cursor = 0),
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: '打名稱、主機或標籤',
                    hintStyle: TextStyle(
                        fontSize: 14, color: scheme.onSurfaceVariant),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 14),
                  ),
                ),
                const Divider(height: 0.5),
                if (results.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text('沒有符合的項目',
                          style: TextStyle(
                              fontSize: 13,
                              color: scheme.onSurfaceVariant)),
                    ),
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 300),
                    child: ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: results.length,
                      itemBuilder: (context, index) {
                        final item = results[index];
                        final secret = primarySecret(item);
                        return RiseIn(
                          delay: Motion.stagger * index ~/ 1,
                          offset: 6,
                          child: SweepRow(
                            selected: index == _cursor,
                            onTap: () {
                              setState(() => _cursor = index);
                              _copySelected();
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 8),
                              child: Row(children: [
                                Icon(
                                  switch (item.kind) {
                                    ItemKind.host => Icons.dns_outlined,
                                    ItemKind.secureKey => Icons.key_outlined,
                                    ItemKind.account => Icons.person_outline,
                                  },
                                  size: 15,
                                  color: scheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(item.name,
                                      style: const TextStyle(fontSize: 13)),
                                ),
                                Text(
                                  secret == null
                                      ? '⏎ 開啟'
                                      : '⏎ 複製${_shortLabel(secret.label, item.name)}',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: scheme.onSurfaceVariant),
                                ),
                              ]),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                const Divider(height: 0.5),
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  child: Row(children: [
                    Text('↑↓ 選擇　⏎ 複製　⌘⏎ 開啟　esc 關閉',
                        style: TextStyle(
                            fontSize: 11, color: scheme.onSurfaceVariant)),
                  ]),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 標籤前面通常已經有項目名稱，列表裡就不要再重複一次。
String _shortLabel(String label, String name) {
  final trimmed = label.replaceFirst(name, '').trim();
  return trimmed.isEmpty ? '' : trimmed;
}
