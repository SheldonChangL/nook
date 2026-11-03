import 'package:flutter/material.dart';

import '../theme.dart';

/// 素材庫 #125「區塊依序輕輕浮現」。解鎖後列表一項一項浮上來。
class RiseIn extends StatefulWidget {
  const RiseIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.offset = 10,
  });

  final Widget child;
  final Duration delay;
  final double offset;

  @override
  State<RiseIn> createState() => _RiseInState();
}

class _RiseInState extends State<RiseIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.base,
  );

  @override
  void initState() {
    super.initState();
    if (widget.delay == Duration.zero) {
      _c.forward();
    } else {
      Future.delayed(widget.delay, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: _c, curve: Motion.curve);
    return AnimatedBuilder(
      animation: curved,
      builder: (context, child) => Opacity(
        opacity: curved.value,
        child: Transform.translate(
          offset: Offset(0, widget.offset * (1 - curved.value)),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}

/// 素材庫 #151「欄位搖頭報錯」。主密碼錯的時候搖一下，不多說什麼。
class ShakeOnError extends StatefulWidget {
  const ShakeOnError({super.key, required this.child, required this.trigger});

  final Widget child;

  /// 每次這個值變了就搖一次。
  final int trigger;

  @override
  State<ShakeOnError> createState() => _ShakeOnErrorState();
}

class _ShakeOnErrorState extends State<ShakeOnError>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
  );

  @override
  void didUpdateWidget(ShakeOnError old) {
    super.didUpdateWidget(old);
    if (old.trigger != widget.trigger) {
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  static const _path = [0.0, -7.0, 6.0, -4.0, 3.0, -2.0, 0.0];

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = _c.value * (_path.length - 1);
        final i = t.floor().clamp(0, _path.length - 2);
        final dx = _path[i] + (_path[i + 1] - _path[i]) * (t - i);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: widget.child,
    );
  }
}

/// 素材庫 #284「列表底色由左刷入」。滑過清單列時底色從左邊刷過來。
class SweepRow extends StatefulWidget {
  const SweepRow({
    super.key,
    required this.child,
    required this.onTap,
    this.selected = false,
  });

  final Widget child;
  final VoidCallback onTap;
  final bool selected;

  @override
  State<SweepRow> createState() => _SweepRowState();
}

class _SweepRowState extends State<SweepRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: ClipRect(
          child: Stack(
            children: [
              Positioned.fill(
                child: AnimatedScale(
                  duration: Motion.base,
                  curve: Motion.curve,
                  alignment: Alignment.centerLeft,
                  scale: 1,
                  child: TweenAnimationBuilder<double>(
                    duration: Motion.base,
                    curve: Motion.curve,
                    tween: Tween(
                        begin: 0,
                        end: widget.selected || _hover ? 1.0 : 0.0),
                    builder: (context, v, child) => Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: v.clamp(0.0001, 1),
                        child: Container(
                          color: widget.selected
                              ? scheme.primaryContainer
                                  .withValues(alpha: 0.55)
                              : scheme.surfaceContainerHighest
                                  .withValues(alpha: 0.75),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              widget.child,
            ],
          ),
        ),
      ),
    );
  }
}

/// 素材庫 #148「提示字上浮欄位」。聚焦時標籤縮小浮上去，底線從中央展開。
class RisingLabelField extends StatefulWidget {
  const RisingLabelField({
    super.key,
    required this.label,
    required this.controller,
    this.obscure = false,
    this.autofocus = false,
    this.onSubmitted,
  });

  final String label;
  final TextEditingController controller;
  final bool obscure;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;

  @override
  State<RisingLabelField> createState() => _RisingLabelFieldState();
}

class _RisingLabelFieldState extends State<RisingLabelField> {
  final _focus = FocusNode();
  bool _raised = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_sync);
    widget.controller.addListener(_sync);
    _raised = widget.controller.text.isNotEmpty;
  }

  void _sync() {
    final next = _focus.hasFocus || widget.controller.text.isNotEmpty;
    if (next != _raised) setState(() => _raised = next);
  }

  @override
  void dispose() {
    _focus.removeListener(_sync);
    widget.controller.removeListener(_sync);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 44,
          child: Stack(
            children: [
              AnimatedPositioned(
                duration: Motion.base,
                curve: Motion.curve,
                left: 0,
                top: _raised ? 0 : 20,
                child: AnimatedDefaultTextStyle(
                  duration: Motion.base,
                  curve: Motion.curve,
                  style: TextStyle(
                    fontSize: _raised ? 11 : 14,
                    color: _raised
                        ? scheme.primary
                        : scheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                  child: Text(widget.label),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 26,
                child: TextField(
                  controller: widget.controller,
                  focusNode: _focus,
                  autofocus: widget.autofocus,
                  obscureText: widget.obscure,
                  onSubmitted: widget.onSubmitted,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
            ],
          ),
        ),
        Stack(
          children: [
            Container(height: 1, color: scheme.outlineVariant),
            TweenAnimationBuilder<double>(
              duration: Motion.base,
              curve: Motion.curve,
              tween: Tween(begin: 0, end: _focus.hasFocus ? 1 : 0),
              builder: (context, v, _) => Transform.scale(
                scaleX: v,
                child: Container(height: 1.5, color: scheme.primary),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
