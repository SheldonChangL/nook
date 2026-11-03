import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_state.dart';
import 'widgets/fields.dart';

Future<void> showSettingsSheet(BuildContext context,
    {required AppState state}) {
  return showDialog(
    context: context,
    builder: (context) => _SettingsSheet(state: state),
  );
}

/// 版面取自素材庫的 Togglet 設定頁：分組清單加開關。
class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({required this.state});

  final AppState state;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  String? _message;
  bool _pathCopied = false;
  Timer? _copiedReset;

  /// 路徑不是機密，所以不走 ClipboardGuard —— 不需要 30 秒後被清掉。
  Future<void> _copyVaultPath() async {
    await Clipboard.setData(ClipboardData(text: state.vaultPath));
    setState(() => _pathCopied = true);
    _copiedReset?.cancel();
    _copiedReset = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _pathCopied = false);
    });
  }

  @override
  void dispose() {
    _copiedReset?.cancel();
    super.dispose();
  }

  AppState get state => widget.state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 16, 12),
              child: Row(children: [
                const Expanded(
                  child: Text('設定',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w500)),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => Navigator.pop(context),
                ),
              ]),
            ),
            const Divider(height: 0.5),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _group('安全'),
                    _dropdownRow(
                      label: '閒置自動上鎖',
                      value: state.settings.autoLockSeconds,
                      options: const {
                        60: '1 分鐘',
                        300: '5 分鐘',
                        600: '10 分鐘',
                        1800: '30 分鐘',
                      },
                      onChanged: (v) async {
                        await state.setAutoLockSeconds(v);
                        setState(() {});
                      },
                    ),
                    _dropdownRow(
                      label: '剪貼簿自動清除',
                      value: state.settings.clipboardClearSeconds,
                      options: const {
                        15: '15 秒',
                        30: '30 秒',
                        60: '60 秒',
                        120: '2 分鐘',
                      },
                      onChanged: (v) async {
                        await state.setClipboardSeconds(v);
                        setState(() {});
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: state.settings.lockOnAppSwitch,
                      onChanged: (v) async {
                        await state.setLockOnAppSwitch(v);
                        setState(() {});
                      },
                      title: const Text('切換到其他 app 就立刻上鎖',
                          style: TextStyle(fontSize: 13)),
                      subtitle: Text(
                        'macOS 只要焦點離開就算切換，所以開了之後每次 ⌘Tab 都會被鎖，'
                        '要重打主密碼。閒置自動上鎖本來就擋得住離開座位的情況，'
                        '除非你的螢幕常被旁人看到，否則不建議開。',
                        style: TextStyle(
                            fontSize: 11,
                            height: 1.5,
                            color: scheme.onSurfaceVariant),
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: state.biometricArmed,
                      onChanged: state.biometricAvailable
                          ? (v) async {
                              final error =
                                  await state.setBiometricEnabled(v);
                              setState(() => _message = error);
                            }
                          : null,
                      title: const Text('用 Touch ID 解鎖',
                          style: TextStyle(fontSize: 13)),
                      subtitle: Text(
                        state.biometricAvailable
                            ? '主密碼仍是唯一的金鑰，Touch ID 只是把它另外存一份在 Keychain。'
                                '你的 Mac 已登入時，這份的保護力比主密碼弱。'
                            : '這台機器沒有可用的 Touch ID。',
                        style: TextStyle(
                            fontSize: 11,
                            height: 1.5,
                            color: scheme.onSurfaceVariant),
                      ),
                    ),
                    if (_message != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(_message!,
                            style: TextStyle(
                                fontSize: 12, color: scheme.error)),
                      ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: () => _changePassword(context),
                      icon: const Icon(Icons.password_outlined, size: 15),
                      label: const Text('更改主密碼',
                          style: TextStyle(fontSize: 13)),
                    ),

                    const SizedBox(height: 20),
                    _group('資料'),
                    // 路徑又長又深（沙盒容器底下），攤在設定頁上只是噪音。
                    // 需要的時候複製走就好。
                    Row(children: [
                      Expanded(
                        child: Text('加密檔位置',
                            style: TextStyle(
                                fontSize: 13,
                                color: scheme.onSurface)),
                      ),
                      OutlinedButton.icon(
                        onPressed: _copyVaultPath,
                        icon: Icon(
                            _pathCopied
                                ? Icons.check
                                : Icons.copy_outlined,
                            size: 14),
                        label: Text(_pathCopied ? '已複製' : '複製路徑',
                            style: const TextStyle(fontSize: 12)),
                      ),
                    ]),
                    const SizedBox(height: 10),
                    Text(
                      '備份就是把整個資料夾複製走。裡面全是密文，放哪都不會外洩內容，'
                      '但沒有主密碼誰也打不開，包括你自己。',
                      style: TextStyle(
                          fontSize: 11,
                          height: 1.6,
                          color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _group(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(title,
            style: const TextStyle(
                fontSize: 12, fontWeight: FontWeight.w500)),
      );

  Widget _dropdownRow({
    required String label,
    required int value,
    required Map<int, String> options,
    required ValueChanged<int> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
        DropdownButton<int>(
          value: options.containsKey(value) ? value : options.keys.first,
          isDense: true,
          underline: const SizedBox.shrink(),
          style: TextStyle(
              fontSize: 13, color: Theme.of(context).colorScheme.onSurface),
          items: [
            for (final entry in options.entries)
              DropdownMenuItem(value: entry.key, child: Text(entry.value)),
          ],
          onChanged: (v) => v == null ? null : onChanged(v),
        ),
      ]),
    );
  }

  Future<void> _changePassword(BuildContext context) async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) => const _ChangePasswordDialog(),
    );
    if (result == null) return;
    final parts = result.split('\u0000');
    final error = await state.changeMasterPassword(parts[0], parts[1]);
    setState(() => _message = error ?? '主密碼已更換');
  }
}

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog();

  @override
  State<_ChangePasswordDialog> createState() =>
      _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _old = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _old.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() {
    if (StrengthMeter.score(_new.text) < 2) {
      setState(() => _error = '新主密碼太弱');
      return;
    }
    if (_new.text != _confirm.text) {
      setState(() => _error = '兩次輸入不一樣');
      return;
    }
    Navigator.pop(context, '${_old.text}\u0000${_new.text}');
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: const Text('更改主密碼', style: TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PasswordField(
              controller: _old,
              autofocus: true,
              label: '目前的主密碼',
            ),
            const SizedBox(height: 12),
            PasswordField(
              controller: _new,
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
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.error)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消')),
        FilledButton(onPressed: _submit, child: const Text('更改')),
      ],
    );
  }
}
