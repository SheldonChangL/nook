import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_state.dart';
import '../vault/models.dart';
import 'command_palette.dart';
import 'detail_panel.dart';
import 'item_editor.dart';
import 'settings_sheet.dart';
import 'theme.dart';
import 'widgets/clipboard_toast.dart';
import 'widgets/motion.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.state});

  final AppState state;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _stackKey = GlobalKey();
  final _rowKeys = <String, GlobalKey>{};
  final _search = TextEditingController();

  ItemKind? _filter;
  String? _tagFilter;

  /// 素材庫 #320：側邊欄收成只剩圖示。
  bool _railCollapsed = false;

  // 素材庫 #216「點選放大成面板」用的狀態。
  VaultItem? _detailItem;
  Rect? _originRect;
  bool _expanded = false;

  AppState get state => widget.state;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<VaultItem> get _visible {
    final query = _search.text.trim().toLowerCase();
    return state.items.where((item) {
      if (_filter != null && item.kind != _filter) return false;
      if (_tagFilter != null && !item.tags.contains(_tagFilter)) return false;
      if (query.isEmpty) return true;
      return item.searchText.toLowerCase().contains(query);
    }).toList();
  }

  Set<String> get _allTags {
    final tags = <String>{};
    for (final item in state.items) {
      tags.addAll(item.tags);
    }
    return tags;
  }

  // ------------------------------------------------------------ 詳情面板

  void _openDetail(VaultItem item) {
    state.touch();
    final stackBox = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    final rowBox =
        _rowKeys[item.id]?.currentContext?.findRenderObject() as RenderBox?;
    if (stackBox != null && rowBox != null) {
      final offset = rowBox.localToGlobal(Offset.zero, ancestor: stackBox);
      _originRect = offset & rowBox.size;
    } else {
      _originRect = null;
    }
    setState(() {
      _detailItem = item;
      _expanded = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _expanded = true);
    });
  }

  void _closeDetail() {
    setState(() {
      _expanded = false;
      _detailItem = null;
    });
  }

  // ------------------------------------------------------------ 動作

  Future<void> _newItem(ItemKind kind) async {
    state.touch();
    final created = await showItemEditor(context, state: state, kind: kind);
    if (created != null && mounted) setState(() {});
  }

  Future<void> _edit(VaultItem item) async {
    state.touch();
    final saved = await showItemEditor(context, state: state, existing: item);
    if (saved != null && mounted) {
      setState(() => _detailItem = state.store.byId(item.id));
    }
  }

  Future<void> _delete(VaultItem item) async {
    state.touch();
    // 素材庫 #205：背景模糊變暗，對話框帶彈性浮出。
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (context) => _ConfirmDeleteDialog(name: item.name),
    );
    if (ok == true) {
      await state.remove(item.id);
      if (mounted) _closeDetail();
    }
  }

  Future<void> _openPalette() async {
    state.touch();
    final picked = await showCommandPalette(context, state: state);
    if (picked != null && mounted) _openDetail(picked);
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Shortcuts(
      shortcuts: {
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
            const _PaletteIntent(),
        const SingleActivator(LogicalKeyboardKey.keyL, meta: true):
            const _LockIntent(),
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true):
            const _NewIntent(),
      },
      child: Actions(
        actions: {
          _PaletteIntent: CallbackAction<_PaletteIntent>(
            onInvoke: (_) => _openPalette(),
          ),
          _LockIntent: CallbackAction<_LockIntent>(
            onInvoke: (_) => state.lock(),
          ),
          _NewIntent: CallbackAction<_NewIntent>(
            onInvoke: (_) => _newItem(_filter ?? ItemKind.host),
          ),
        },
        child: Focus(
          autofocus: true,
          // 活動偵測統一在 main.dart 做：鍵盤走 HardwareKeyboard，滑鼠走包在
          // Navigator 外面的 Listener，對話框裡的操作才算得到。
          child: Scaffold(
            body: Stack(
              key: _stackKey,
              children: [
                Row(
                  children: [
                    _sidebar(scheme),
                    const VerticalDivider(width: 0.5),
                    Expanded(child: _mainColumn(scheme)),
                  ],
                ),
                if (_detailItem != null) _detailLayer(),
                Positioned(
                  left: 16,
                  bottom: 16,
                  child: ListenableBuilder(
                    listenable: state.clipboard,
                    builder: (context, _) =>
                        ClipboardToast(guard: state.clipboard),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ 側邊欄

  Widget _sidebar(ColorScheme scheme) {
    final counts = <ItemKind, int>{
      for (final kind in ItemKind.values)
        kind: state.items.where((i) => i.kind == kind).length,
    };

    return AnimatedContainer(
      duration: Motion.base,
      curve: Motion.curve,
      width: _railCollapsed ? 56 : 172,
      color: scheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 36),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
            child: Row(
              children: [
                if (!_railCollapsed) ...[
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'SecureManage',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
                IconButton(
                  icon: Icon(
                    _railCollapsed ? Icons.chevron_right : Icons.chevron_left,
                    size: 16,
                  ),
                  tooltip: _railCollapsed ? '展開側邊欄' : '收起側邊欄',
                  onPressed: () =>
                      setState(() => _railCollapsed = !_railCollapsed),
                ),
              ],
            ),
          ),
          _railTile(
            icon: Icons.inbox_outlined,
            label: '全部',
            count: state.items.length,
            selected: _filter == null && _tagFilter == null,
            onTap: () => setState(() {
              _filter = null;
              _tagFilter = null;
            }),
          ),
          for (final kind in ItemKind.values)
            _railTile(
              icon: switch (kind) {
                ItemKind.host => Icons.dns_outlined,
                ItemKind.secureKey => Icons.key_outlined,
                ItemKind.account => Icons.person_outline,
              },
              label: kind.label,
              count: counts[kind] ?? 0,
              selected: _filter == kind,
              onTap: () => setState(() {
                _filter = kind;
                _tagFilter = null;
              }),
            ),
          if (!_railCollapsed && _allTags.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 12, 14, 6),
              child: Divider(height: 1),
            ),
            for (final tag in _allTags)
              _railTile(
                icon: Icons.label_outline,
                label: tag,
                count: state.items.where((i) => i.tags.contains(tag)).length,
                selected: _tagFilter == tag,
                onTap: () => setState(() {
                  _tagFilter = tag;
                  _filter = null;
                }),
              ),
          ],
          const Spacer(),
          _railTile(
            icon: Icons.settings_outlined,
            label: '設定',
            onTap: () => showSettingsSheet(context, state: state),
          ),
          _railTile(icon: Icons.lock_outline, label: '立刻上鎖', onTap: state.lock),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _railTile({
    required IconData icon,
    required String label,
    int? count,
    bool selected = false,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Material(
        color: selected
            ? scheme.primaryContainer.withValues(alpha: 0.6)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(7),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 16,
                  color: selected
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant,
                ),
                if (!_railCollapsed) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: selected
                            ? scheme.onPrimaryContainer
                            : scheme.onSurface,
                      ),
                    ),
                  ),
                  if (count != null)
                    Text(
                      '$count',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ 主欄

  Widget _mainColumn(ColorScheme scheme) {
    final items = _visible;
    return Column(
      children: [
        const SizedBox(height: 32),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 30,
                  child: TextField(
                    controller: _search,
                    onChanged: (_) {
                      state.touch();
                      setState(() {});
                    },
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      hintText: '搜尋名稱、主機、標籤',
                      hintStyle: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurfaceVariant,
                      ),
                      prefixIcon: const Icon(Icons.search, size: 15),
                      prefixIconConstraints: const BoxConstraints(minWidth: 32),
                      suffixIcon: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Text(
                          '⌘K',
                          style: monoStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      suffixIconConstraints: const BoxConstraints(minWidth: 36),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _AddButton(onPick: _newItem),
              const SizedBox(width: 8),
              _LockCountdown(state: state),
            ],
          ),
        ),
        const Divider(height: 0.5),
        Expanded(
          child: items.isEmpty
              ? _emptyState(scheme)
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final key = _rowKeys.putIfAbsent(
                      item.id,
                      () => GlobalKey(),
                    );
                    return RiseIn(
                      key: ValueKey('rise-${item.id}'),
                      delay: Motion.stagger * (index.clamp(0, 8)),
                      child: Container(
                        key: key,
                        child: SweepRow(
                          selected: _detailItem?.id == item.id,
                          onTap: () => _openDetail(item),
                          child: _row(item, scheme),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _row(VaultItem item, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Row(
        children: [
          Icon(
            switch (item.kind) {
              ItemKind.host => Icons.dns_outlined,
              ItemKind.secureKey => Icons.key_outlined,
              ItemKind.account => Icons.person_outline,
            },
            size: 17,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  // 只放中繼資料。密碼與金鑰本體不出現在列表層。
                  item.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Text(
            _ago(item.updatedAt),
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            Icons.arrow_forward,
            size: 14,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(ColorScheme scheme) {
    final filtered =
        _search.text.isNotEmpty || _filter != null || _tagFilter != null;
    return Center(
      child: RiseIn(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.inbox_outlined,
              size: 26,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 10),
            Text(
              filtered ? '沒有符合的項目' : '保險庫還是空的',
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 4),
            Text(
              filtered ? '換個關鍵字，或清掉左邊的篩選' : '按右上角的「新增」記第一筆，主機、金鑰或帳號都行',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------ 詳情層

  Widget _detailLayer() {
    final item = _detailItem!;
    final size = MediaQuery.of(context).size;
    final target = Rect.fromLTWH(
      _railCollapsed ? 72 : 188,
      48,
      (size.width - (_railCollapsed ? 72 : 188) - 16).clamp(320, 1200),
      (size.height - 64).clamp(240, 2000),
    );
    final rect = _expanded ? target : (_originRect ?? target);

    return Positioned.fill(
      child: Stack(
        children: [
          // 點面板外面就收起來。
          Positioned.fill(
            child: GestureDetector(
              onTap: _closeDetail,
              behavior: HitTestBehavior.opaque,
              child: AnimatedOpacity(
                duration: Motion.base,
                opacity: _expanded ? 1 : 0,
                child: Container(color: Colors.black.withValues(alpha: 0.06)),
              ),
            ),
          ),
          AnimatedPositioned(
            duration: Motion.panel,
            curve: Motion.curve,
            left: rect.left,
            top: rect.top,
            width: rect.width,
            height: rect.height,
            child: AnimatedOpacity(
              duration: Motion.fast,
              opacity: _expanded ? 1 : 0,
              child: DetailPanel(
                key: ValueKey(item.id),
                state: state,
                item: item,
                visible: _expanded,
                onClose: _closeDetail,
                onEdit: () => _edit(item),
                onDelete: () => _delete(item),
                onOpenRef: _openDetail,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _ago(DateTime time) {
  final diff = DateTime.now().difference(time);
  if (diff.inMinutes < 1) return '剛剛';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分鐘前';
  if (diff.inHours < 24) return '${diff.inHours} 小時前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  return '${(diff.inDays / 30).floor()} 個月前';
}

class _AddButton extends StatelessWidget {
  const _AddButton({required this.onPick});

  final void Function(ItemKind) onPick;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      builder: (context, controller, child) => OutlinedButton.icon(
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.add, size: 15),
        label: const Text('新增', style: TextStyle(fontSize: 13)),
      ),
      menuChildren: [
        for (final kind in ItemKind.values)
          MenuItemButton(
            onPressed: () => onPick(kind),
            leadingIcon: Icon(switch (kind) {
              ItemKind.host => Icons.dns_outlined,
              ItemKind.secureKey => Icons.key_outlined,
              ItemKind.account => Icons.person_outline,
            }, size: 16),
            child: Text(kind.label),
          ),
      ],
    );
  }
}

/// 右上角的自動上鎖倒數。隨時看得到還剩多久。
class _LockCountdown extends StatelessWidget {
  const _LockCountdown({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final seconds = state.secondsUntilLock.clamp(0, 86400);
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    final soon = seconds <= 30;
    return Tooltip(
      message: '閒置滿 ${state.settings.autoLockSeconds ~/ 60} 分鐘自動上鎖．⌘L 立刻上鎖',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.lock_open_outlined,
            size: 14,
            color: soon ? scheme.error : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 5),
          Text(
            '$minutes:${rest.toString().padLeft(2, '0')}',
            style: monoStyle(
              fontSize: 12,
              color: soon ? scheme.error : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ConfirmDeleteDialog extends StatelessWidget {
  const _ConfirmDeleteDialog({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
      child: AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        icon: Icon(Icons.delete_outline, color: scheme.error),
        title: Text('刪除「$name」？', style: const TextStyle(fontSize: 16)),
        content: const Text(
          '這筆資料會從加密檔裡移除，救不回來。',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: scheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('刪除'),
          ),
        ],
      ),
    );
  }
}

class _PaletteIntent extends Intent {
  const _PaletteIntent();
}

class _LockIntent extends Intent {
  const _LockIntent();
}

class _NewIntent extends Intent {
  const _NewIntent();
}
