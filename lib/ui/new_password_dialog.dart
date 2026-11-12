import 'package:flutter/material.dart';

import 'widgets/fields.dart';

/// 輸入新主密碼兩次的對話框。回傳新密碼；取消回 null。
///
/// 強度門檻與建立保險庫時相同（[StrengthMeter.score] 至少 2，也就是至少 8 個字元）。
class NewPasswordDialog extends StatefulWidget {
  const NewPasswordDialog({
    super.key,
    required this.title,
    required this.explanation,
    required this.confirmLabel,
  });

  final String title;
  final String explanation;
  final String confirmLabel;

  @override
  State<NewPasswordDialog> createState() => _NewPasswordDialogState();
}

class _NewPasswordDialogState extends State<NewPasswordDialog> {
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() {
    if (StrengthMeter.score(_new.text) < 2) {
      setState(() => _error = '新主密碼太短，至少要 8 個字元');
      return;
    }
    if (_new.text != _confirm.text) {
      setState(() => _error = '兩次輸入不一樣');
      return;
    }
    Navigator.pop(context, _new.text);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: Text(widget.title, style: const TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.explanation,
              key: const ValueKey('new-password-explanation'),
              style: TextStyle(
                  fontSize: 12, height: 1.6, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            PasswordField(
              controller: _new,
              autofocus: true,
              label: '新主密碼',
              onChanged: () => setState(() => _error = null),
            ),
            const SizedBox(height: 10),
            AnimatedBuilder(
              animation: _new,
              builder: (context, _) => StrengthMeter(password: _new.text),
            ),
            const SizedBox(height: 12),
            PasswordField(
              controller: _confirm,
              label: '再打一次',
              onSubmitted: (_) => _submit(),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!,
                    key: const ValueKey('new-password-error'),
                    style: TextStyle(fontSize: 12, color: scheme.error)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消')),
        FilledButton(
            key: const ValueKey('new-password-confirm'),
            onPressed: _submit,
            child: Text(widget.confirmLabel)),
      ],
    );
  }
}
