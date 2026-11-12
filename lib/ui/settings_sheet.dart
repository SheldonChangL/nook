import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_state.dart';
import '../app/platform_profile.dart';
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
                      title: Text(PlatformProfile.current.appSwitchTitle,
                          style: const TextStyle(fontSize: 13)),
                      subtitle: Text(
                        PlatformProfile.current.appSwitchHint,
                        style: TextStyle(
                            fontSize: 11,
                            height: 1.5,
                            color: scheme.onSurfaceVariant),
                      ),
                    ),
                    // 快速解鎖只在 macOS 有受保護的金鑰設計（Touch ID＋Keychain）。
                    // Windows／Linux 不顯示這個開關，免得讓人以為 DEK 有被系統驗證綁住。
                    if (PlatformProfile.current.supportsQuickUnlock)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: state.biometricSwitchOn,
                      onChanged: state.biometricAvailable
                          ? (v) async {
                              if (!v && !await _confirmDisableTouchId()) {
                                return;
                              }
                              final error =
                                  await state.setBiometricEnabled(v);
                              if (mounted) setState(() => _message = error);
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
                    if (state.permissionWarning != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(state.permissionWarning!,
                            key: const ValueKey('permission-warning'),
                            style: TextStyle(
                                fontSize: 12,
                                height: 1.5,
                                color: scheme.error)),
                      ),
                    const SizedBox(height: 10),
                    Text(
                      '備份就是把整個資料夾複製走。裡面全是密文，放哪都不會外洩內容，'
                      '但沒有主密碼誰也打不開，包括你自己。',
                      style: TextStyle(
                          fontSize: 11,
                          height: 1.6,
                          color: scheme.onSurfaceVariant),
                    ),

                    const SizedBox(height: 20),
                    _group('跨機同步'),
                    // 同步在背景跑，狀態會自己變；這一段要跟著 AppState 重畫。
                    ListenableBuilder(
                      listenable: state,
                      builder: (context, _) => _syncSection(scheme),
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

  String? _syncMessage;

  Widget _syncSection(ColorScheme scheme) {
    final hint = TextStyle(
        fontSize: 11, height: 1.6, color: scheme.onSurfaceVariant);
    final warn = TextStyle(fontSize: 12, height: 1.5, color: scheme.error);
    final report = state.lastSync;
    final children = <Widget>[];

    if (!state.syncEnabled) {
      children.addAll([
        Text(
          '選一個雲端硬碟（Dropbox、Google Drive、iCloud Drive⋯）裡的資料夾，'
          '其他電腦上的 Nook 接上同一個資料夾，就會自動合併。'
          '上傳下載由雲端硬碟的程式負責，Nook 本身不連網；放進去的全是密文，'
          // Touch ID 只有 macOS 有；其他平台的設定頁不提它，免得讓人以為那裡也有。
          '${PlatformProfile.current.supportsQuickUnlock ? '主密碼與 Touch ID 的金鑰' : '主密碼'}'
          '不會進同步資料夾。設定不同步，各台各自保管。',
          style: hint,
        ),
        if (state.syncSetupProblem != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(state.syncSetupProblem!, style: warn),
          ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const ValueKey('sync-choose'),
            onPressed: () async {
              final error = await state.chooseSyncFolder();
              if (mounted) setState(() => _syncMessage = error);
            },
            icon: const Icon(Icons.folder_open_outlined, size: 15),
            label: const Text('選擇同步資料夾⋯', style: TextStyle(fontSize: 13)),
          ),
        ),
      ]);
    } else {
      final status = state.syncing
          ? '同步中⋯'
          : report?.finishedAt != null
              ? '上次同步 ${_clock(report!.finishedAt!)}'
              : '尚未同步';
      children.addAll([
        Text(state.syncFolderPath ?? '',
            key: const ValueKey('sync-folder'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12.5)),
        const SizedBox(height: 4),
        Text(status, key: const ValueKey('sync-status'), style: hint),
        if (state.syncError != null)
          Text(state.syncError!, key: const ValueKey('sync-error'), style: warn),
        if (report != null && report.unreadable.isNotEmpty)
          Text(
            '有 ${report.unreadable.length} 個檔案讀不到，多半是雲端硬碟還沒下載完；'
            '不會被當成刪除，之後會再試。',
            style: hint,
          ),
        if (report != null && report.pendingDownload > 0)
          Text(
            'iCloud 還有 ${report.pendingDownload} 個檔案沒下載到這台。'
            '建議在 Finder 對同步資料夾選「保留下載項目」。',
            style: hint,
          ),
        if (state.syncNotice != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(state.syncNotice!,
                key: const ValueKey('sync-notice'),
                style: TextStyle(
                    fontSize: 12, height: 1.5, color: scheme.primary)),
          ),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
            key: const ValueKey('sync-now'),
            onPressed: state.syncing ? null : state.syncNow,
            icon: const Icon(Icons.sync, size: 15),
            label: const Text('立即同步', style: TextStyle(fontSize: 13)),
          ),
          OutlinedButton(
            key: const ValueKey('sync-stop'),
            onPressed: () async {
              await state.stopSync();
              if (mounted) setState(() => _syncMessage = null);
            },
            child: const Text('停止同步', style: TextStyle(fontSize: 13)),
          ),
        ]),
        const SizedBox(height: 6),
        Text('停止同步不會刪任何東西：這台的資料和同步資料夾都原封不動。', style: hint),
      ]);
    }
    if (_syncMessage != null) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(_syncMessage!,
            key: const ValueKey('sync-message'), style: warn),
      ));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  static String _clock(DateTime t) {
    final l = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
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
          // DropdownButton 的 style 會取代而不是合併預設字型樣式，Linux 的中文備援要自己帶。
          style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurface,
              fontFamilyFallback: PlatformProfile.current.cjkFontFallback),
          items: [
            for (final entry in options.entries)
              DropdownMenuItem(value: entry.key, child: Text(entry.value)),
          ],
          onChanged: (v) => v == null ? null : onChanged(v),
        ),
      ]),
    );
  }

  /// 關掉 Touch ID 會刪掉 Keychain 那份金鑰。忘了主密碼、靠 Touch ID 進來的人，
  /// 那份是唯一的鑰匙，關掉之前一定要問。
  Future<bool> _confirmDisableTouchId() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('關掉 Touch ID？', style: TextStyle(fontSize: 16)),
        content: const SizedBox(
          width: 320,
          child: Text(
            '關掉會刪掉存在鑰匙圈裡的那份金鑰，之後只能用主密碼打開 Nook。\n\n'
            '如果你不記得主密碼，先到「更改主密碼」用 Touch ID 換一組新的，再關。',
            key: ValueKey('disable-touch-id-warning'),
            style: TextStyle(fontSize: 13, height: 1.6),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              key: const ValueKey('disable-touch-id-confirm'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('仍要關掉')),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _changePassword(BuildContext context) async {
    final result = await showDialog<_PasswordChange>(
      context: context,
      builder: (context) => _ChangePasswordDialog(
        allowTouchId: state.canChangePasswordWithBiometrics,
      ),
    );
    if (result == null) return;
    final error = result.oldPassword == null
        ? await state.changeMasterPasswordWithBiometrics(result.newPassword)
        : await state.changeMasterPassword(
            result.oldPassword!, result.newPassword);
    if (mounted) setState(() => _message = error ?? '主密碼已更換');
  }
}

/// 改密碼對話框的結果。[oldPassword] 是 null 代表改用 Touch ID 確認身分。
class _PasswordChange {
  const _PasswordChange(this.oldPassword, this.newPassword);
  final String? oldPassword;
  final String newPassword;
}

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog({required this.allowTouchId});

  /// 這台開過 Touch ID：可以不輸入目前的主密碼，改用 Touch ID 確認身分。
  final bool allowTouchId;

  @override
  State<_ChangePasswordDialog> createState() =>
      _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _old = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;

  /// 不記得目前的主密碼，改用 Touch ID 確認。
  bool _useTouchId = false;

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
    Navigator.pop(
      context,
      _PasswordChange(_useTouchId ? null : _old.text, _new.text),
    );
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
            if (!_useTouchId)
              PasswordField(
                controller: _old,
                autofocus: true,
                label: '目前的主密碼',
              ),
            if (widget.allowTouchId && !_useTouchId)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const ValueKey('change-password-use-touch-id'),
                  onPressed: () => setState(() {
                    _useTouchId = true;
                    _error = null;
                  }),
                  child: const Text('不記得目前的主密碼？改用 Touch ID 確認',
                      style: TextStyle(fontSize: 12)),
                ),
              ),
            if (_useTouchId)
              Text(
                '按「更改」之後會跳出 Touch ID（也可以輸入這台 Mac 的登入密碼）確認是本人。'
                '資料一筆都不會動，Touch ID 之後照樣能用。'
                '有用跨機同步的話，其他電腦同步之後也會換成新的主密碼，舊的在那些電腦上同樣會失效。',
                key: const ValueKey('change-password-touch-id-note'),
                style: TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
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
