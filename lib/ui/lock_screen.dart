import 'package:flutter/material.dart';

import '../app/app_state.dart';
import 'theme.dart';
import 'widgets/fields.dart';
import 'widgets/motion.dart';

/// 版面取自素材庫的 Keyhollow 登入模板：左邊品牌區，右邊表單。
class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.state});

  final AppState state;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  int _shake = 0;
  bool _tried = false;

  bool get _isSetup => widget.state.phase == VaultPhase.needsSetup;

  @override
  void initState() {
    super.initState();
    // 有開 Touch ID 就先問一次，省得每次都要打字。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!_isSetup && widget.state.biometricArmed) {
        await widget.state.unlockWithBiometrics();
      }
    });
  }

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final state = widget.state;
    setState(() => _tried = true);

    if (_isSetup) {
      if (StrengthMeter.score(_password.text) < 2) {
        setState(() => _shake++);
        return;
      }
      if (_password.text != _confirm.text) {
        setState(() => _shake++);
        return;
      }
      final ok = await state.createVault(_password.text);
      if (!ok) setState(() => _shake++);
      return;
    }

    if (_password.text.isEmpty) {
      setState(() => _shake++);
      return;
    }
    final ok = await state.unlock(_password.text);
    if (!ok) {
      setState(() => _shake++);
      _password.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = widget.state;

    return Scaffold(
      body: Row(children: [
        // 左側品牌區。
        Expanded(
          flex: 42,
          child: Container(
            color: scheme.primaryContainer,
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RiseIn(
                  child: Icon(Icons.shield_outlined,
                      size: 30, color: scheme.onPrimaryContainer),
                ),
                const SizedBox(height: 14),
                RiseIn(
                  delay: Motion.stagger,
                  child: Text(
                    _isSetup ? '先設一道門。' : '歡迎回來。',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w500,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                RiseIn(
                  delay: Motion.stagger * 2,
                  child: Text(
                    _isSetup
                        ? '主密碼是唯一能打開保險庫的東西，沒有找回機制。\n挑一個你記得住、別人猜不到的。'
                        : '所有資料都鎖在這台機器裡，沒有任何東西送到雲端。',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.7,
                      color: scheme.onPrimaryContainer
                          .withValues(alpha: 0.75),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // 右側表單。
        Expanded(
          flex: 58,
          child: Center(
            child: ShakeOnError(
              trigger: _shake,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        _isSetup ? '建立保險庫' : '解鎖保險庫',
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 20),
                      RisingLabelField(
                        label: '主密碼',
                        controller: _password,
                        obscure: true,
                        autofocus: true,
                        onSubmitted: (_) => _submit(),
                      ),
                      if (_isSetup) ...[
                        const SizedBox(height: 14),
                        AnimatedBuilder(
                          animation: _password,
                          builder: (context, _) =>
                              StrengthMeter(password: _password.text),
                        ),
                        const SizedBox(height: 14),
                        RisingLabelField(
                          label: '再打一次',
                          controller: _confirm,
                          obscure: true,
                          onSubmitted: (_) => _submit(),
                        ),
                        if (_tried &&
                            _confirm.text.isNotEmpty &&
                            _confirm.text != _password.text)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text('兩次輸入不一樣',
                                style: TextStyle(
                                    fontSize: 12, color: scheme.error)),
                          ),
                      ],
                      SizedBox(
                        height: 22,
                        child: state.unlockError == null
                            ? null
                            : Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  // 不細分錯在哪，免得幫人縮小破解範圍。
                                  state.unlockError!,
                                  style: TextStyle(
                                      fontSize: 12, color: scheme.error),
                                ),
                              ),
                      ),
                      const SizedBox(height: 4),
                      FilledButton(
                        onPressed: state.busy ? null : _submit,
                        child: state.busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2))
                            : Text(_isSetup ? '建立' : '解鎖'),
                      ),
                      if (!_isSetup && state.biometricArmed) ...[
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: state.busy
                              ? null
                              : () => state.unlockWithBiometrics(),
                          icon: const Icon(Icons.fingerprint, size: 18),
                          label: const Text('用 Touch ID 解鎖'),
                        ),
                      ],
                      const SizedBox(height: 18),
                      Text(
                        _isSetup
                            ? '忘記主密碼＝資料救不回來，沒有後門。'
                            : '忘記主密碼無法復原。',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant
                                .withValues(alpha: 0.8)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
