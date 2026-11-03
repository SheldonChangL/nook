import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';

/// 一列機密。預設遮起來，要按「顯示」才揭露，按「複製」才進剪貼簿。
///
/// 刻意不做「滑過就顯示」或逐字解碼動畫：揭露必須是明確的動作，而且解碼過程
/// 反而會把每個字演給旁邊的人看。
class SecretRow extends StatefulWidget {
  const SecretRow({
    super.key,
    required this.label,
    required this.value,
    required this.onCopy,
    this.monospace = true,
  });

  final String label;
  final String value;
  final VoidCallback onCopy;
  final bool monospace;

  @override
  State<SecretRow> createState() => _SecretRowState();
}

class _SecretRowState extends State<SecretRow> {
  bool _revealed = false;
  Timer? _autoHide;

  /// 揭露後 20 秒自動遮回去，免得走開時留在畫面上。
  void _toggle() {
    setState(() => _revealed = !_revealed);
    _autoHide?.cancel();
    if (_revealed) {
      _autoHide = Timer(const Duration(seconds: 20), () {
        if (mounted) setState(() => _revealed = false);
      });
    }
  }

  @override
  void dispose() {
    _autoHide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final empty = widget.value.isEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(widget.label,
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant)),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: empty
                  ? Text('（未填）',
                      style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurfaceVariant
                              .withValues(alpha: 0.6)))
                  : AnimatedSwitcher(
                      duration: Motion.fast,
                      child: Text(
                        _revealed
                            ? widget.value
                            : '•' * widget.value.length.clamp(6, 18),
                        key: ValueKey(_revealed),
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.45,
                          letterSpacing: _revealed ? 0 : 2,
                          fontFamily: widget.monospace ? monoFamily : null,
                          fontFamilyFallback:
                              widget.monospace ? monoFallback : null,
                        ),
                      ),
                    ),
            ),
          ),
          if (!empty) ...[
            _MiniButton(
              icon: _revealed
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              label: _revealed ? '隱藏' : '顯示',
              onTap: _toggle,
            ),
            const SizedBox(width: 6),
            _MiniButton(
              icon: Icons.copy_outlined,
              label: '複製',
              onTap: widget.onCopy,
            ),
          ],
        ],
      ),
    );
  }
}

/// 一列非機密資料。直接顯示，可複製。
class PlainRow extends StatelessWidget {
  const PlainRow({
    super.key,
    required this.label,
    required this.value,
    this.onCopy,
    this.monospace = false,
    this.trailing,
  });

  final String label;
  final String value;
  final VoidCallback? onCopy;
  final bool monospace;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(label,
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant)),
            ),
          ),
          Expanded(
            child: value.isEmpty
                ? Text('（未填）',
                    style: TextStyle(
                        fontSize: 13,
                        color:
                            scheme.onSurfaceVariant.withValues(alpha: 0.6)))
                : SelectableText(
                    value,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.45,
                      fontFamily: monospace ? monoFamily : null,
                      fontFamilyFallback: monospace ? monoFallback : null,
                    ),
                  ),
          ),
          ?trailing,
          if (onCopy != null && value.isNotEmpty)
            _MiniButton(
                icon: Icons.copy_outlined, label: '複製', onTap: onCopy!),
        ],
      ),
    );
  }
}

class _MiniButton extends StatelessWidget {
  const _MiniButton(
      {required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(label,
                style:
                    TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          ]),
        ),
      ),
    );
  }
}

/// 素材庫 #244「格狀強弱量尺」。設定主密碼時逐格長出。
class StrengthMeter extends StatelessWidget {
  const StrengthMeter({super.key, required this.password});

  final String password;

  /// 粗略估計，只為了給使用者方向感，不是正式的熵計算。
  static int score(String p) {
    if (p.isEmpty) return 0;
    var s = 1;
    if (p.length >= 8) s = 2;
    if (p.length >= 12) s = 3;
    if (p.length >= 12 && RegExp(r'[^a-zA-Z0-9]').hasMatch(p)) s = 4;
    if (p.length >= 16 &&
        RegExp(r'[^a-zA-Z0-9]').hasMatch(p) &&
        RegExp(r'[0-9]').hasMatch(p)) {
      s = 5;
    }
    return s;
  }

  static const _labels = [
    '還沒輸入',
    '太短，很快就被跑完',
    '普通，再長一點',
    '還行',
    '不錯',
    '夠強，記得寫下來放安全的地方',
  ];

  static const _colors = [
    Color(0xFFB4B2A9),
    Color(0xFFE24B4A),
    Color(0xFFEF9F27),
    Color(0xFFEF9F27),
    Color(0xFF639922),
    Color(0xFF1D9E75),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = score(password);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: List.generate(5, (i) {
            return Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: i == 4 ? 0 : 4),
                child: AnimatedContainer(
                  duration: Motion.base,
                  curve: Motion.curve,
                  height: 5,
                  decoration: BoxDecoration(
                    color: i < s
                        ? _colors[s]
                        : scheme.outlineVariant.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 6),
        Text(_labels[s],
            style: TextStyle(
                fontSize: 11,
                color: s == 0
                    ? scheme.onSurfaceVariant.withValues(alpha: 0.7)
                    : _colors[s])),
      ],
    );
  }
}

/// 素材庫 #249「回車化膠囊」。打完按 Enter 就變成一顆標籤。
class TagField extends StatefulWidget {
  const TagField({super.key, required this.tags, required this.onChanged});

  final List<String> tags;
  final ValueChanged<List<String>> onChanged;

  @override
  State<TagField> createState() => _TagFieldState();
}

class _TagFieldState extends State<TagField> {
  final _controller = TextEditingController();

  void _add(String raw) {
    final value = raw.trim();
    if (value.isEmpty || widget.tags.contains(value)) {
      _controller.clear();
      return;
    }
    widget.onChanged([...widget.tags, value]);
    _controller.clear();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final tag in widget.tags)
          _PoppingChip(
            key: ValueKey(tag),
            label: tag,
            onRemove: () => widget.onChanged(
                widget.tags.where((t) => t != tag).toList()),
          ),
        SizedBox(
          width: 130,
          child: TextField(
            controller: _controller,
            onSubmitted: _add,
            style: const TextStyle(fontSize: 12),
            decoration: InputDecoration(
              hintText: '加標籤後按 Enter',
              hintStyle: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.6)),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            ),
          ),
        ),
      ],
    );
  }
}

class _PoppingChip extends StatefulWidget {
  const _PoppingChip({super.key, required this.label, required this.onRemove});

  final String label;
  final VoidCallback onRemove;

  @override
  State<_PoppingChip> createState() => _PoppingChipState();
}

class _PoppingChipState extends State<_PoppingChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ScaleTransition(
      scale: CurvedAnimation(parent: _c, curve: Curves.easeOutBack),
      child: Container(
        padding: const EdgeInsets.only(left: 10, right: 4, top: 3, bottom: 3),
        decoration: BoxDecoration(
          color: scheme.primaryContainer.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(widget.label,
              style: TextStyle(
                  fontSize: 12, color: scheme.onPrimaryContainer)),
          IconButton(
            icon: const Icon(Icons.close, size: 12),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
            onPressed: widget.onRemove,
            color: scheme.onPrimaryContainer,
          ),
        ]),
      ),
    );
  }
}

/// 密碼欄位旁邊的眼睛。刻意不讓它搶走輸入焦點，按完還能接著打。
class RevealToggle extends StatelessWidget {
  const RevealToggle({
    super.key,
    required this.revealed,
    required this.onToggle,
  });

  final bool revealed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ExcludeFocus(
      child: IconButton(
        icon: Icon(
            revealed ? Icons.visibility_off_outlined : Icons.visibility_outlined,
            size: 17),
        color: scheme.onSurfaceVariant,
        tooltip: revealed ? '隱藏' : '顯示',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
        visualDensity: VisualDensity.compact,
        onPressed: onToggle,
      ),
    );
  }
}

/// 一般的密碼輸入欄位，附顯示切換。
///
/// 輸入時看得到自己打了什麼跟「列表上不該出現明文」是兩回事：前者是你主動
/// 按下去的，後者是沒人要求就攤開。所以這裡給切換，列表那邊不給。
class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.controller,
    this.label,
    this.hint,
    this.autofocus = false,
    this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String? label;
  final String? hint;
  final bool autofocus;
  final VoidCallback? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      obscureText: !_revealed,
      autofocus: widget.autofocus,
      onChanged: (_) => widget.onChanged?.call(),
      onSubmitted: widget.onSubmitted,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        suffixIcon: RevealToggle(
          revealed: _revealed,
          onToggle: () => setState(() => _revealed = !_revealed),
        ),
        suffixIconConstraints:
            const BoxConstraints(minWidth: 38, minHeight: 30),
      ),
    );
  }
}
