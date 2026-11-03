import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/clipboard_guard.dart';
import '../theme.dart';

/// 素材庫 #139「弧線繞圈累加百分比」+ #140「畫圈勾選成功提示」。
///
/// 複製之後左下角的環形倒數，繞完就代表剪貼簿已經被清掉了。這個提示的重點
/// 是讓你隨時看得到「機密還躺在剪貼簿裡多久」。
class ClipboardToast extends StatelessWidget {
  const ClipboardToast({super.key, required this.guard});

  final ClipboardGuard guard;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedSlide(
      duration: Motion.base,
      curve: Motion.curve,
      offset: guard.isActive ? Offset.zero : const Offset(0, 0.4),
      child: AnimatedOpacity(
        duration: Motion.base,
        opacity: guard.isActive ? 1 : 0,
        child: IgnorePointer(
          ignoring: !guard.isActive,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: panelDecoration(context, strong: true),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                width: 26,
                height: 26,
                child: CustomPaint(
                  painter: _RingPainter(
                    progress: guard.progress,
                    done: guard.cleared,
                    track: scheme.outlineVariant,
                    accent: const Color(0xFF1D9E75),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('已複製 ${guard.label ?? ''}',
                      style: const TextStyle(fontSize: 13)),
                  Text(
                    guard.cleared
                        ? '剪貼簿已清除'
                        : '${guard.remaining} 秒後自動清除剪貼簿',
                    style: TextStyle(
                        fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.progress,
    required this.done,
    required this.track,
    required this.accent,
  });

  final double progress;
  final bool done;
  final Color track;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 3;

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = track;
    canvas.drawCircle(center, radius, trackPaint);

    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..color = accent;
    // 從十二點鐘方向開始，剩餘比例畫成弧，時間走完就消失。
    final remaining = (1 - progress).clamp(0.0, 1.0);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * remaining,
      false,
      arcPaint,
    );

    // 勾勾用畫的，不是貼一個 icon 上去。
    final tick = Path()
      ..moveTo(size.width * 0.32, size.height * 0.51)
      ..lineTo(size.width * 0.44, size.height * 0.63)
      ..lineTo(size.width * 0.69, size.height * 0.38);
    canvas.drawPath(
      tick,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = accent.withValues(alpha: done ? 1 : 0.35),
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.done != done;
}
