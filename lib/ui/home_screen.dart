import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../app/app_state.dart';
import '../vault/models.dart';
import 'command_palette.dart';
import 'detail_panel.dart';
import 'item_editor.dart';
import 'settings_sheet.dart';
import 'theme.dart';
import 'widgets/clipboard_toast.dart';
import 'widgets/motion.dart';

/// 主畫面。版面照指定的 mockup：左側淺藍側欄，右側分類頁（標題區、統計卡、
/// 子篩選、清單或空狀態）。
///
/// 跟鎖定畫面一樣，素材是固定淺色設計，所以這個畫面也不跟系統深色模式走。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.state});

  final AppState state;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// 側欄的分類。kind 為 null 代表「全部」。
class _Category {
  const _Category(this.kind, this.label, this.subtitle, this.icon);

  final ItemKind? kind;
  final String label;
  final String subtitle;
  final IconData icon;

  static const all = _Category(
    null,
    '全部',
    '這台裝置上所有已加密的項目',
    Icons.grid_view_outlined,
  );
  static const keys = _Category(
    ItemKind.secureKey,
    '金鑰',
    '集中管理 SSH 金鑰與存取憑證',
    Icons.key_outlined,
  );
  static const accounts = _Category(
    ItemKind.account,
    '帳號',
    '服務帳號、網址與密碼',
    Icons.person_outline,
  );
  static const hosts = _Category(
    ItemKind.host,
    '主機 / VM',
    '連線資訊、環境變數與對應金鑰',
    Icons.dns_outlined,
  );

  static const values = [all, keys, accounts, hosts];
}

class _HomeScreenState extends State<HomeScreen> {
  final _stackKey = GlobalKey();
  final _rowKeys = <String, GlobalKey>{};
  final _search = TextEditingController();

  _Category _category = _Category.all;
  String? _tagFilter;

  /// 金鑰分類底下的子篩選。null 代表全部。
  KeyKind? _keyKind;

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

  /// 只套分類與標籤，不套搜尋字串。統計卡算的是這個範圍。
  List<VaultItem> get _inCategory => state.items.where((item) {
    if (_category.kind != null && item.kind != _category.kind) return false;
    if (_tagFilter != null && !item.tags.contains(_tagFilter)) return false;
    return true;
  }).toList();

  List<VaultItem> get _visible {
    final query = _search.text.trim().toLowerCase();
    return _inCategory.where((item) {
      if (_keyKind != null) {
        if (item is! SecureKeyItem || item.keyKind != _keyKind) return false;
      }
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
    final palette = NookPalette(state.darkAppearance);
    return Theme(
      data: _assetTheme(),
      child: Shortcuts(
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
              onInvoke: (_) => _newItem(_category.kind ?? ItemKind.host),
            ),
          },
          child: Focus(
            autofocus: true,
            // 活動偵測統一在 main.dart：鍵盤走 HardwareKeyboard，滑鼠走包在
            // Navigator 外面的 Listener，對話框裡的操作才算得到。
            child: Scaffold(
              backgroundColor: palette.background,
              body: Stack(
                key: _stackKey,
                children: [
                  Row(
                    children: [
                      _sidebar(),
                      Expanded(child: _content()),
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
      ),
    );
  }

  ThemeData _assetTheme() => AppTheme.nook(state.darkAppearance);

  // ------------------------------------------------------------ 側欄

  Widget _sidebar() {
    final palette = NookPalette(state.darkAppearance);
    final counts = <ItemKind, int>{
      for (final kind in ItemKind.values)
        kind: state.items.where((i) => i.kind == kind).length,
    };

    return SizedBox(
      width: 232,
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(color: palette.sidebar),
            child: SizedBox.expand(),
          ),
          Opacity(
            opacity: state.darkAppearance ? 0 : 0.12,
            child: SvgPicture.asset(
              '$brandAssets/backgrounds/left_panel.svg',
              fit: BoxFit.cover,
              alignment: Alignment.bottomCenter,
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 34),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 6, 18, 18),
                child: Row(
                  children: [
                    SvgPicture.asset(
                      '$brandAssets/icons/shield.svg',
                      width: 21,
                      height: 21,
                      colorFilter: ColorFilter.mode(
                        palette.accent,
                        BlendMode.srcIn,
                      ),
                    ),
                    const SizedBox(width: 9),
                    Text(
                      'Nook',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w600,
                        color: palette.text,
                      ),
                    ),
                  ],
                ),
              ),
              for (final category in _Category.values)
                _navTile(
                  icon: category.icon,
                  label: category.label,
                  count: category.kind == null
                      ? state.items.length
                      : counts[category.kind] ?? 0,
                  selected: _category == category && _tagFilter == null,
                  onTap: () => setState(() {
                    _category = category;
                    _tagFilter = null;
                    _keyKind = null;
                  }),
                ),
              if (_allTags.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
                  child: Divider(height: 1, color: palette.border),
                ),
                for (final tag in _allTags)
                  _navTile(
                    icon: Icons.label_outline,
                    label: tag,
                    count: state.items
                        .where((i) => i.tags.contains(tag))
                        .length,
                    selected: _tagFilter == tag,
                    onTap: () => setState(() {
                      _tagFilter = tag;
                      _category = _Category.all;
                      _keyKind = null;
                    }),
                  ),
              ],
              const Spacer(),
              _navTile(
                icon: Icons.settings_outlined,
                label: '設定',
                onTap: () => showSettingsSheet(context, state: state),
              ),
              _navTile(
                icon: Icons.lock_outline,
                label: '立刻上鎖',
                onTap: state.lock,
              ),
              const SizedBox(height: 14),
            ],
          ),
        ],
      ),
    );
  }

  Widget _navTile({
    required IconData icon,
    required String label,
    int? count,
    bool selected = false,
    required VoidCallback onTap,
  }) {
    final palette = NookPalette(state.darkAppearance);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        color: selected ? palette.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(9),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 17,
                  color: selected ? palette.accent : palette.muted,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: selected ? palette.text : palette.muted,
                    ),
                  ),
                ),
                if (count != null)
                  Text(
                    '$count',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: selected ? palette.accent : palette.muted,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ 右側內容

  Widget _content() {
    final palette = NookPalette(state.darkAppearance);
    return ColoredBox(
      color: palette.surface,
      child: Column(
        children: [
          const SizedBox(height: 30),
          _topBar(),
          Divider(height: 0.5, color: palette.border),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_category.kind == ItemKind.secureKey) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
                      child: _keyKindChips(),
                    ),
                  ],
                  _listOrEmpty(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _topBar() {
    final palette = NookPalette(state.darkAppearance);
    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 0, 26, 14),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 38,
              child: TextField(
                controller: _search,
                onChanged: (_) {
                  state.touch();
                  setState(() {});
                },
                style: TextStyle(fontSize: 13.5, color: palette.text),
                decoration: InputDecoration(
                  hintText: '搜尋名稱、主機、標籤',
                  hintStyle: TextStyle(fontSize: 13.5, color: palette.muted),
                  prefixIcon: Icon(
                    Icons.search,
                    size: 17,
                    color: palette.muted,
                  ),
                  prefixIconConstraints: const BoxConstraints(minWidth: 40),
                  filled: true,
                  fillColor: palette.surfaceRaised,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 11),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: palette.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: palette.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: palette.accent, width: 1.5),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          _TagFilterButton(
            tags: _allTags,
            active: _tagFilter,
            onPick: (tag) => setState(() {
              _tagFilter = tag;
              if (tag != null) _category = _Category.all;
            }),
          ),
          const SizedBox(width: 10),
          _AddButton(onPick: _newItem, fixedKind: _category.kind),
          const SizedBox(width: 8),
          AppearanceToggle(state: state),
          const SizedBox(width: 14),
          _LockCountdown(state: state),
        ],
      ),
    );
  }

  Widget _keyKindChips() {
    final palette = NookPalette(state.darkAppearance);
    final items = _inCategory.whereType<SecureKeyItem>().toList();

    Widget chip(
      String label,
      int count,
      bool selected,
      VoidCallback onTap,
      IconData? icon,
    ) {
      return Padding(
        padding: const EdgeInsets.only(right: 10),
        child: Material(
          color: selected ? palette.accent : palette.surface,
          borderRadius: BorderRadius.circular(20),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: selected ? palette.accent : palette.border,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(
                      icon,
                      size: 15,
                      color: selected ? palette.onAccent : palette.muted,
                    ),
                    const SizedBox(width: 7),
                  ],
                  Text(
                    '$label ($count)',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                      color: selected ? palette.onAccent : palette.text,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Wrap(
      runSpacing: 10,
      children: [
        chip(
          '全部',
          items.length,
          _keyKind == null,
          () => setState(() => _keyKind = null),
          null,
        ),
        for (final kind in KeyKind.values)
          chip(
            kind.label,
            items.where((i) => i.keyKind == kind).length,
            _keyKind == kind,
            () => setState(() => _keyKind = kind),
            switch (kind) {
              KeyKind.sshPrivateKey => Icons.vpn_key_outlined,
              KeyKind.apiToken => Icons.code,
              KeyKind.certificate => Icons.workspace_premium_outlined,
            },
          ),
      ],
    );
  }

  // ------------------------------------------------------------ 清單

  Widget _listOrEmpty() {
    final palette = NookPalette(state.darkAppearance);
    final items = _visible;
    if (items.isEmpty) {
      return RiseIn(delay: Motion.stagger * 3, child: _empty());
    }

    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (final (index, item) in items.indexed) ...[
            if (index > 0) Divider(height: 0.5, color: palette.border),
            RiseIn(
              key: ValueKey('rise-${item.id}'),
              delay: Motion.stagger * (index.clamp(0, 8)),
              child: Container(
                key: _rowKeys.putIfAbsent(item.id, () => GlobalKey()),
                child: SweepRow(
                  selected: _detailItem?.id == item.id,
                  onTap: () => _openDetail(item),
                  child: _row(item),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(VaultItem item) {
    final palette = NookPalette(state.darkAppearance);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: palette.accentSoft,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(
              switch (item.kind) {
                ItemKind.host => Icons.dns_outlined,
                ItemKind.secureKey => Icons.key_outlined,
                ItemKind.account => Icons.person_outline,
              },
              size: 17,
              color: palette.accent,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    color: palette.text,
                  ),
                ),
                // 只放中繼資料。密碼與金鑰本體不出現在列表層。
                Text(
                  item.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: palette.muted),
                ),
              ],
            ),
          ),
          for (final tag in item.tags.take(2))
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  color: palette.surfaceRaised,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  tag,
                  style: TextStyle(fontSize: 11, color: palette.muted),
                ),
              ),
            ),
          const SizedBox(width: 12),
          Text(
            _ago(item.updatedAt),
            style: TextStyle(fontSize: 11.5, color: palette.muted),
          ),
          const SizedBox(width: 8),
          Icon(Icons.arrow_forward_ios, size: 12, color: palette.muted),
        ],
      ),
    );
  }

  Widget _empty() {
    final palette = NookPalette(state.darkAppearance);
    final filtered =
        _search.text.isNotEmpty || _tagFilter != null || _keyKind != null;
    final label = _category.label;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(32, 34, 32, 26),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 170,
            child: SvgPicture.asset(
              '$brandAssets/hero/empty_state.svg',
              fit: BoxFit.contain,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            filtered
                ? '沒有符合的項目'
                : (_category.kind == null ? '保險庫還是空的' : '目前沒有$label'),
            style: TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w600,
              color: palette.text,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            filtered ? '換個關鍵字，或把左邊與上方的篩選清掉。' : _emptyBody(),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, height: 1.6, color: palette.muted),
          ),
          const SizedBox(height: 20),
          if (!filtered)
            FilledButton.icon(
              onPressed: () => _newItem(_category.kind ?? ItemKind.host),
              icon: const Icon(Icons.add, size: 17),
              label: Text(_category.kind == null ? '新增第一個項目' : '新增第一個$label'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 15,
                ),
              ),
            ),
          const SizedBox(height: 22),
          const Divider(height: 0.5),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SvgPicture.asset(
                '$brandAssets/icons/lock.svg',
                width: 14,
                height: 14,
                colorFilter: ColorFilter.mode(palette.muted, BlendMode.srcIn),
              ),
              const SizedBox(width: 8),
              Text(
                '所有項目皆儲存在本機，並以強加密保護。',
                style: TextStyle(fontSize: 12, color: palette.muted),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _emptyBody() => switch (_category.kind) {
    ItemKind.secureKey => '你可以新增 SSH 金鑰、API 憑證或存取用金鑰，並以本機加密方式保存。',
    ItemKind.account => '記下服務的網址、使用者名稱與密碼，密碼只有你按下顯示才會出現。',
    ItemKind.host => '記下主機位址、登入帳號、環境變數，並指定要用哪一把金鑰。',
    null => '主機、金鑰、帳號都可以放進來，全部在這台機器上加密保存。',
  };

  // ------------------------------------------------------------ 詳情層

  Widget _detailLayer() {
    final item = _detailItem!;
    final size = MediaQuery.of(context).size;
    final palette = NookPalette(state.darkAppearance);
    final width = (size.width * 0.32).clamp(340.0, 430.0);
    final target = Rect.fromLTWH(size.width - width, 0, width, size.height);
    final rect = _expanded ? target : (_originRect ?? target);

    return Positioned.fill(
      child: Stack(
        children: [
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
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(left: BorderSide(color: palette.border)),
                ),
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
  const _AddButton({required this.onPick, this.fixedKind});

  final void Function(ItemKind) onPick;

  /// 已經切到某個分類時就不用再問要新增哪一種，直接開那一種的表單。
  /// 只有在「全部」才需要選單。
  final ItemKind? fixedKind;

  @override
  Widget build(BuildContext context) {
    final kind = fixedKind;
    if (kind != null) {
      return FilledButton.icon(
        onPressed: () => onPick(kind),
        icon: const Icon(Icons.add, size: 17),
        label: const Text('新增'),
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      );
    }
    return MenuAnchor(
      builder: (context, controller, child) => FilledButton.icon(
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.add, size: 17),
        label: const Text('新增'),
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
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

/// mockup 上的「篩選」。接成依標籤篩選 —— 標籤是目前唯一真的能拿來篩的維度。
class _TagFilterButton extends StatelessWidget {
  const _TagFilterButton({
    required this.tags,
    required this.active,
    required this.onPick,
  });

  final Set<String> tags;
  final String? active;
  final ValueChanged<String?> onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MenuAnchor(
      builder: (context, controller, child) => OutlinedButton.icon(
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.tune, size: 16),
        label: Text(active ?? '篩選', style: const TextStyle(fontSize: 13.5)),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          foregroundColor: active == null
              ? scheme.onSurfaceVariant
              : scheme.primary,
          side: BorderSide(
            color: active == null ? scheme.outlineVariant : scheme.primary,
          ),
        ),
      ),
      menuChildren: [
        if (tags.isEmpty)
          const MenuItemButton(onPressed: null, child: Text('還沒有任何標籤'))
        else ...[
          MenuItemButton(
            onPressed: () => onPick(null),
            child: const Text('全部'),
          ),
          for (final tag in tags)
            MenuItemButton(onPressed: () => onPick(tag), child: Text(tag)),
        ],
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
    const danger = Color(0xFFE24B4A);
    return Tooltip(
      message: '閒置滿 ${state.settings.autoLockSeconds ~/ 60} 分鐘自動上鎖．⌘L 立刻上鎖',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.lock_open_outlined,
            size: 15,
            color: soon ? danger : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(
            '$minutes:${rest.toString().padLeft(2, '0')}',
            style: monoStyle(
              fontSize: 12.5,
              color: soon ? danger : scheme.onSurfaceVariant,
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
