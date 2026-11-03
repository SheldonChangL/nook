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

  static const all =
      _Category(null, '全部', '這台裝置上所有已加密的項目', Icons.grid_view_outlined);
  static const keys = _Category(
      ItemKind.secureKey, '金鑰', '集中管理 SSH 金鑰與存取憑證', Icons.key_outlined);
  static const accounts =
      _Category(ItemKind.account, '帳號', '服務帳號、網址與密碼', Icons.person_outline);
  static const hosts = _Category(
      ItemKind.host, '主機 / VM', '連線資訊、環境變數與對應金鑰', Icons.dns_outlined);

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
            _PaletteIntent:
                CallbackAction<_PaletteIntent>(onInvoke: (_) => _openPalette()),
            _LockIntent:
                CallbackAction<_LockIntent>(onInvoke: (_) => state.lock()),
            _NewIntent: CallbackAction<_NewIntent>(
                onInvoke: (_) => _newItem(_category.kind ?? ItemKind.host)),
          },
          child: Focus(
            autofocus: true,
            // 活動偵測統一在 main.dart：鍵盤走 HardwareKeyboard，滑鼠走包在
            // Navigator 外面的 Listener，對話框裡的操作才算得到。
            child: Scaffold(
              backgroundColor: brandSurface,
              body: Stack(
                key: _stackKey,
                children: [
                  Row(children: [
                    _sidebar(),
                    Expanded(child: _content()),
                  ]),
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

  ThemeData _assetTheme() {
    final base = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: brandBlue,
        brightness: Brightness.light,
      ).copyWith(
        primary: brandBlue,
        onPrimary: Colors.white,
        surface: brandSurface,
        onSurface: brandTextPrimary,
        onSurfaceVariant: brandTextSecondary,
        outlineVariant: brandBorder,
      ),
      useMaterial3: true,
      visualDensity: VisualDensity.compact,
    );
    return base.copyWith(
      dividerTheme: const DividerThemeData(
          thickness: 0.5, space: 0.5, color: brandBorder),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: brandBlue,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
          textStyle:
              const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: brandTextPrimary,
          backgroundColor: brandSurface,
          side: const BorderSide(color: brandBorder),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ 側欄

  Widget _sidebar() {
    final counts = <ItemKind, int>{
      for (final kind in ItemKind.values)
        kind: state.items.where((i) => i.kind == kind).length,
    };

    return SizedBox(
      width: 232,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFEAF5FE), panelBlueLight],
              ),
            ),
            child: SizedBox.expand(),
          ),
          Opacity(
            opacity: 0.5,
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
                child: Row(children: [
                  SvgPicture.asset(
                    '$brandAssets/icons/shield.svg',
                    width: 21,
                    height: 21,
                    colorFilter:
                        const ColorFilter.mode(brandBlueDark, BlendMode.srcIn),
                  ),
                  const SizedBox(width: 9),
                  const Text('Nook',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w600,
                        color: brandBlueDark,
                      )),
                ]),
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
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 12, 20, 10),
                  child: Divider(height: 1, color: Color(0x33176FA8)),
                ),
                for (final tag in _allTags)
                  _navTile(
                    icon: Icons.label_outline,
                    label: tag,
                    count: state.items.where((i) => i.tags.contains(tag)).length,
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        color: selected ? Colors.white : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(9),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
            child: Row(children: [
              Icon(icon, size: 17, color: selected ? brandBlue : brandBlueDark),
              const SizedBox(width: 10),
              Expanded(
                child: Text(label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: selected ? brandBlue : brandBlueDark,
                    )),
              ),
              if (count != null)
                Text('$count',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: selected
                          ? brandBlue
                          : brandBlueDark.withValues(alpha: 0.6),
                    )),
            ]),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ 右側內容

  Widget _content() {
    return Stack(
      fit: StackFit.expand,
      children: [
        Opacity(
          opacity: 0.7,
          child: SvgPicture.asset(
            '$brandAssets/backgrounds/right_panel.svg',
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
          ),
        ),
        Column(children: [
          const SizedBox(height: 30),
          _topBar(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(26, 10, 26, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  RiseIn(child: _categoryHeader()),
                  const SizedBox(height: 20),
                  RiseIn(delay: Motion.stagger, child: _statCards()),
                  if (_category.kind == ItemKind.secureKey) ...[
                    const SizedBox(height: 18),
                    RiseIn(delay: Motion.stagger * 2, child: _keyKindChips()),
                  ],
                  const SizedBox(height: 18),
                  _listOrEmpty(),
                ],
              ),
            ),
          ),
        ]),
      ],
    );
  }

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 0, 26, 14),
      child: Row(children: [
        Expanded(
          child: SizedBox(
            height: 38,
            child: TextField(
              controller: _search,
              onChanged: (_) {
                state.touch();
                setState(() {});
              },
              style: const TextStyle(fontSize: 13.5),
              decoration: InputDecoration(
                hintText: '搜尋名稱、主機、標籤',
                hintStyle:
                    const TextStyle(fontSize: 13.5, color: brandTextSecondary),
                prefixIcon: const Icon(Icons.search,
                    size: 17, color: brandTextSecondary),
                prefixIconConstraints: const BoxConstraints(minWidth: 40),
                filled: true,
                fillColor: brandSurface,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 11),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: brandBorder),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: brandBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: brandBlue, width: 1.5),
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
        const SizedBox(width: 14),
        _LockCountdown(state: state),
      ]),
    );
  }

  Widget _categoryHeader() {
    return Row(children: [
      Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: panelBlueLight,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(_category.icon, size: 25, color: brandBlue),
      ),
      const SizedBox(width: 14),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_category.label,
              style: const TextStyle(
                fontSize: 25,
                fontWeight: FontWeight.w600,
                color: brandTextPrimary,
              )),
          const SizedBox(height: 2),
          Text(
            _tagFilter == null ? _category.subtitle : '標籤「$_tagFilter」底下的項目',
            style: const TextStyle(fontSize: 13, color: brandTextSecondary),
          ),
        ],
      ),
    ]);
  }

  // ------------------------------------------------------------ 統計卡

  Widget _statCards() {
    final items = _inCategory;
    final accessed =
        items.map((i) => i.lastAccessedAt).whereType<DateTime>().toList()
          ..sort();
    final last = accessed.isEmpty ? null : accessed.last;

    return Row(children: [
      Expanded(
        child: _StatCard(
          icon: Icons.verified_user_outlined,
          label: '已保護項目',
          value: '${items.length}',
          suffix: '/ ${_category.label}',
        ),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: _StatCard(
          icon: Icons.schedule,
          label: '最近存取',
          value: last == null ? '—' : _ago(last),
          hint: last == null ? '尚無存取紀錄' : '上次複製機密的時間',
        ),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: _StatCard(
          icon: Icons.lock_outline,
          label: '本機加密',
          pill: '已啟用',
          hint: '資料僅儲存在此裝置',
          accent: brandGreen,
          accentBg: brandGreenBg,
        ),
      ),
    ]);
  }

  Widget _keyKindChips() {
    final items = _inCategory.whereType<SecureKeyItem>().toList();

    Widget chip(String label, int count, bool selected, VoidCallback onTap,
        IconData? icon) {
      return Padding(
        padding: const EdgeInsets.only(right: 10),
        child: Material(
          color: selected ? brandBlue : brandSurface,
          borderRadius: BorderRadius.circular(20),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border:
                    Border.all(color: selected ? brandBlue : brandBorder),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (icon != null) ...[
                  Icon(icon,
                      size: 15,
                      color: selected ? Colors.white : brandTextSecondary),
                  const SizedBox(width: 7),
                ],
                Text('$label ($count)',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                      color: selected ? Colors.white : brandTextPrimary,
                    )),
              ]),
            ),
          ),
        ),
      );
    }

    return Wrap(runSpacing: 10, children: [
      chip('全部', items.length, _keyKind == null,
          () => setState(() => _keyKind = null), null),
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
    ]);
  }

  // ------------------------------------------------------------ 清單

  Widget _listOrEmpty() {
    final items = _visible;
    if (items.isEmpty) {
      return RiseIn(delay: Motion.stagger * 3, child: _empty());
    }

    return Container(
      decoration: BoxDecoration(
        color: brandSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: brandBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        for (final (index, item) in items.indexed) ...[
          if (index > 0) const Divider(height: 0.5),
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
      ]),
    );
  }

  Widget _row(VaultItem item) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      child: Row(children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: panelBlueLight.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(
            switch (item.kind) {
              ItemKind.host => Icons.dns_outlined,
              ItemKind.secureKey => Icons.key_outlined,
              ItemKind.account => Icons.person_outline,
            },
            size: 17,
            color: brandBlue,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.name,
                  style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                      color: brandTextPrimary)),
              // 只放中繼資料。密碼與金鑰本體不出現在列表層。
              Text(item.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 11.5, color: brandTextSecondary)),
            ],
          ),
        ),
        for (final tag in item.tags.take(2))
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                color: panelBlueLight.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(tag,
                  style:
                      const TextStyle(fontSize: 11, color: brandBlueDark)),
            ),
          ),
        const SizedBox(width: 12),
        Text(_ago(item.updatedAt),
            style:
                const TextStyle(fontSize: 11.5, color: brandTextSecondary)),
        const SizedBox(width: 8),
        const Icon(Icons.arrow_forward_ios,
            size: 12, color: brandTextSecondary),
      ]),
    );
  }

  Widget _empty() {
    final filtered =
        _search.text.isNotEmpty || _tagFilter != null || _keyKind != null;
    final label = _category.label;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(32, 34, 32, 26),
      decoration: BoxDecoration(
        color: brandSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: brandBorder),
      ),
      child: Column(children: [
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
          style: const TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.w600,
            color: brandTextPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          filtered ? '換個關鍵字，或把左邊與上方的篩選清掉。' : _emptyBody(),
          textAlign: TextAlign.center,
          style: const TextStyle(
              fontSize: 13, height: 1.6, color: brandTextSecondary),
        ),
        const SizedBox(height: 20),
        if (!filtered)
          FilledButton.icon(
            onPressed: () => _newItem(_category.kind ?? ItemKind.host),
            icon: const Icon(Icons.add, size: 17),
            label: Text(
                _category.kind == null ? '新增第一個項目' : '新增第一個$label'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
            ),
          ),
        const SizedBox(height: 22),
        const Divider(height: 0.5),
        const SizedBox(height: 14),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          SvgPicture.asset(
            '$brandAssets/icons/lock.svg',
            width: 14,
            height: 14,
            colorFilter:
                const ColorFilter.mode(brandTextSecondary, BlendMode.srcIn),
          ),
          const SizedBox(width: 8),
          const Text('所有項目皆儲存在本機，並以強加密保護。',
              style: TextStyle(fontSize: 12, color: brandTextSecondary)),
        ]),
      ]),
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
    final target = Rect.fromLTWH(
      252,
      42,
      (size.width - 252 - 22).clamp(320, 1400),
      (size.height - 62).clamp(240, 2000),
    );
    final rect = _expanded ? target : (_originRect ?? target);

    return Positioned.fill(
      child: Stack(children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: _closeDetail,
            behavior: HitTestBehavior.opaque,
            child: AnimatedOpacity(
              duration: Motion.base,
              opacity: _expanded ? 1 : 0,
              child: Container(color: brandBlueDark.withValues(alpha: 0.10)),
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
      ]),
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

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.label,
    this.value,
    this.suffix,
    this.pill,
    this.hint,
    this.accent = brandBlue,
    this.accentBg = panelBlueLight,
  });

  final IconData icon;
  final String label;
  final String? value;
  final String? suffix;
  final String? pill;
  final String? hint;
  final Color accent;
  final Color accentBg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
      decoration: BoxDecoration(
        color: brandSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: brandBorder),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: accentBg,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(icon, size: 19, color: accent),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style:
                      const TextStyle(fontSize: 12, color: brandTextSecondary)),
              const SizedBox(height: 4),
              if (pill != null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: accentBg,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(pill!,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: accent,
                      )),
                )
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Flexible(
                      child: Text(value ?? '—',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                            color: brandTextPrimary,
                          )),
                    ),
                    if (suffix != null) ...[
                      const SizedBox(width: 6),
                      Text(suffix!,
                          style: const TextStyle(
                              fontSize: 12, color: brandTextSecondary)),
                    ],
                  ],
                ),
              if (hint != null) ...[
                const SizedBox(height: 3),
                Text(hint!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11, color: brandTextSecondary)),
              ],
            ],
          ),
        ),
      ]),
    );
  }
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
            leadingIcon: Icon(
                switch (kind) {
                  ItemKind.host => Icons.dns_outlined,
                  ItemKind.secureKey => Icons.key_outlined,
                  ItemKind.account => Icons.person_outline,
                },
                size: 16),
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
    return MenuAnchor(
      builder: (context, controller, child) => OutlinedButton.icon(
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.tune, size: 16),
        label: Text(active ?? '篩選', style: const TextStyle(fontSize: 13.5)),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          foregroundColor: active == null ? brandTextPrimary : brandBlue,
          side: BorderSide(color: active == null ? brandBorder : brandBlue),
        ),
      ),
      menuChildren: [
        if (tags.isEmpty)
          const MenuItemButton(onPressed: null, child: Text('還沒有任何標籤'))
        else ...[
          MenuItemButton(
              onPressed: () => onPick(null), child: const Text('全部')),
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
    final seconds = state.secondsUntilLock.clamp(0, 86400);
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    final soon = seconds <= 30;
    const danger = Color(0xFFE24B4A);
    return Tooltip(
      message: '閒置滿 ${state.settings.autoLockSeconds ~/ 60} 分鐘自動上鎖．⌘L 立刻上鎖',
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.lock_open_outlined,
            size: 15, color: soon ? danger : brandTextSecondary),
        const SizedBox(width: 6),
        Text(
          '$minutes:${rest.toString().padLeft(2, '0')}',
          style: monoStyle(
              fontSize: 12.5, color: soon ? danger : brandTextSecondary),
        ),
      ]),
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
        content:
            const Text('這筆資料會從加密檔裡移除，救不回來。', style: TextStyle(fontSize: 13)),
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
