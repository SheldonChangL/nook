import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 複製到剪貼簿，並在倒數結束後清掉。
///
/// 清除前會先比對剪貼簿目前的內容還是不是我們放進去的那段；如果使用者後來
/// 複製了別的東西，就不動它。不然會莫名其妙吃掉別人的剪貼簿。
class ClipboardGuard extends ChangeNotifier {
  ClipboardGuard({this.clearAfter = const Duration(seconds: 30)});

  Duration clearAfter;

  Timer? _ticker;
  String? _written;

  /// 正在倒數的那筆機密叫什麼（例如「sudo 密碼」）。沒有倒數時是 null。
  String? label;

  /// 剩餘秒數。
  int remaining = 0;

  /// 已經清掉了，提示還在畫面上停一下。
  bool cleared = false;

  bool get isActive => label != null;

  /// 倒數進度 0.0 → 1.0，給環形進度條用。
  double get progress {
    final total = clearAfter.inSeconds;
    if (total <= 0) return 1;
    return (total - remaining) / total;
  }

  Future<void> copy(String value, {required String label}) async {
    await Clipboard.setData(ClipboardData(text: value));
    _written = value;
    this.label = label;
    remaining = clearAfter.inSeconds;
    cleared = false;
    notifyListeners();

    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) async {
      remaining--;
      if (remaining <= 0) {
        await _clearIfStillOurs();
      }
      notifyListeners();
    });
  }

  Future<void> _clearIfStillOurs() async {
    _ticker?.cancel();
    _ticker = null;
    remaining = 0;

    final current = await Clipboard.getData('text/plain');
    if (current?.text == _written) {
      await Clipboard.setData(const ClipboardData(text: ''));
      cleared = true;
    } else {
      // 使用者已經複製了別的東西，不要去動它。
      cleared = false;
      label = null;
    }
    _written = null;
    notifyListeners();

    Timer(const Duration(seconds: 3), () {
      label = null;
      cleared = false;
      notifyListeners();
    });
  }

  /// 上鎖時呼叫：立刻清掉，不等倒數。
  Future<void> clearNow() async {
    if (_written == null) {
      _ticker?.cancel();
      _ticker = null;
      label = null;
      remaining = 0;
      notifyListeners();
      return;
    }
    await _clearIfStillOurs();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}
