import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../app/app_state.dart';
import 'theme.dart';
import 'widgets/fields.dart';
import 'widgets/motion.dart';

/// 鎖定畫面。版面與文案照 SecureManage_UI_Assets 這包素材與指定的 mockup。
///
/// 素材是固定的淺色設計，所以這個畫面在系統深色模式下也維持淺色 ——
/// 底下用 [_assetTheme] 把整棵子樹固定成淺色，免得深色模式的文字顏色
/// 落在淺色底上看不見。
class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.state});

  final AppState state;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

// palette.json 的色票。
const _brandBlueDark = Color(0xFF0D5C96);
const _brandBlue = Color(0xFF1878BE);
const _brandBlueBright = Color(0xFF2F8EDB);
const _surface = Color(0xFFFCFCFB);
const _surfaceAlt = Color(0xFFF3F6FA);
const _textPrimary = Color(0xFF17212B);
const _textSecondary = Color(0xFF66707A);
const _border = Color(0xFFD7DEE7);

const _assets = 'SecureManage_UI_Assets';

class _LockScreenState extends State<LockScreen> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  int _shake = 0;
  bool _tried = false;
  bool _revealed = false;

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

  /// 素材是固定淺色的，所以這個畫面不跟著系統深色模式走。
  ThemeData _assetTheme() {
    final base = ThemeData(
      colorScheme:
          ColorScheme.fromSeed(
            seedColor: _brandBlue,
            brightness: Brightness.light,
          ).copyWith(
            primary: _brandBlue,
            onPrimary: Colors.white,
            surface: _surface,
            onSurface: _textPrimary,
            onSurfaceVariant: _textSecondary,
            outlineVariant: _border,
          ),
      useMaterial3: true,
    );
    return base.copyWith(
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: _brandBlue,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 17),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: _brandBlueDark,
          side: const BorderSide(color: _border),
          padding: const EdgeInsets.symmetric(vertical: 13),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: _assetTheme(),
      child: Scaffold(
        backgroundColor: _surfaceAlt,
        body: LayoutBuilder(
          builder: (context, constraints) {
            // 視窗太窄時左欄的插圖會擠掉表單，乾脆只留表單。
            final showBrandPanel = constraints.maxWidth >= 860;
            return Row(
              children: [
                if (showBrandPanel) Expanded(flex: 50, child: _brandPanel()),
                Expanded(flex: 50, child: _formPanel(showBrandPanel)),
              ],
            );
          },
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 左欄

  Widget _brandPanel() {
    return ClipPath(
      clipper: _CurvedEdgeClipper(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          SvgPicture.asset(
            '$_assets/backgrounds/left_panel.svg',
            fit: BoxFit.cover,
            alignment: Alignment.bottomCenter,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(44, 30, 72, 34),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RiseIn(child: _brandLockup()),
                Expanded(
                  child: Center(
                    child: RiseIn(
                      delay: Motion.stagger,
                      // 用去背的向量版。素材包原本的 PNG 底色是不透明的淺藍
                      // （四角 alpha 約 250），疊在面板上會露出一個方框。
                      child: SvgPicture.asset(
                        '$_assets/hero/securemanage_hero_transparent.svg',
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                ),
                RiseIn(
                  delay: Motion.stagger * 2,
                  child: const Text(
                    '歡迎回來',
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                      color: _brandBlueDark,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                // 標題底下的短強調線。
                RiseIn(
                  delay: Motion.stagger * 2,
                  child: Container(
                    width: 46,
                    height: 3,
                    decoration: BoxDecoration(
                      color: _brandBlue,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                RiseIn(
                  delay: Motion.stagger * 3,
                  child: const Text(
                    '你的敏感資料，只留在這台 Mac。',
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.6,
                      color: _brandBlueDark,
                    ),
                  ),
                ),
                const SizedBox(height: 26),
                RiseIn(delay: Motion.stagger * 4, child: _sellingPointRow()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _brandLockup() {
    return Row(
      children: [
        SvgPicture.asset(
          '$_assets/icons/shield.svg',
          width: 24,
          height: 24,
          colorFilter: const ColorFilter.mode(_brandBlueDark, BlendMode.srcIn),
        ),
        const SizedBox(width: 10),
        const Text(
          'SecureManage',
          style: TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w600,
            color: _brandBlueDark,
          ),
        ),
      ],
    );
  }

  /// mockup 的三個賣點是橫排、中間用細直線隔開。
  ///
  /// 素材的 COPY.md 與 mockup 都把第二點寫成「AES-256 加密」，但這個 app 實際
  /// 用的是 ChaCha20-Poly1305。演算法名稱寫錯會變成不實宣稱，所以這裡照實寫。
  static const _sellingPoints = <({String icon, String title, String body})>[
    (icon: 'laptop', title: '本機儲存', body: '資料不離開這台裝置'),
    (icon: 'lock', title: '強加密保護', body: 'ChaCha20-Poly1305'),
    (icon: 'cloud-off', title: '無雲端同步', body: '完全掌握你的資料'),
  ];

  Widget _sellingPointRow() {
    final children = <Widget>[];
    for (final (index, point) in _sellingPoints.indexed) {
      if (index > 0) {
        children.add(
          Container(
            width: 1,
            height: 46,
            color: _brandBlueDark.withValues(alpha: 0.18),
          ),
        );
      }
      children.add(
        Expanded(
          child: Column(
            children: [
              SvgPicture.asset(
                '$_assets/icons/${point.icon}.svg',
                width: 22,
                height: 22,
                colorFilter: const ColorFilter.mode(
                  _brandBlueDark,
                  BlendMode.srcIn,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                point.title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _brandBlueDark,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                point.body,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.4,
                  color: _brandBlueDark.withValues(alpha: 0.78),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  // ---------------------------------------------------------------- 右欄

  Widget _formPanel(bool showBrandPanel) {
    final state = widget.state;

    return Stack(
      fit: StackFit.expand,
      children: [
        SvgPicture.asset(
          '$_assets/backgrounds/right_panel.svg',
          fit: BoxFit.cover,
          alignment: Alignment.bottomCenter,
        ),
        Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(showBrandPanel ? 48 : 36, 32, 48, 32),
            child: ShakeOnError(
              trigger: _shake,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(40, 36, 40, 30),
                  decoration: BoxDecoration(
                    color: _surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: _border.withValues(alpha: 0.7)),
                    boxShadow: [
                      BoxShadow(
                        color: _brandBlueDark.withValues(alpha: 0.07),
                        blurRadius: 24,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(
                        child: SizedBox(
                          width: 58,
                          height: 58,
                          child: CustomPaint(painter: _ShieldBadgePainter()),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        _isSetup ? '建立你的 SecureManage' : '解除鎖定並進入 SecureManage',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                          color: _textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _isSetup ? '設定一組主密碼來保護你的資料' : '請輸入主密碼以存取你的資料',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 13.5,
                          height: 1.6,
                          color: _textSecondary,
                        ),
                      ),
                      const SizedBox(height: 24),
                      _passwordField(
                        controller: _password,
                        hint: '主密碼',
                        autofocus: true,
                      ),
                      if (_isSetup) ...[
                        const SizedBox(height: 14),
                        AnimatedBuilder(
                          animation: _password,
                          builder: (context, _) =>
                              StrengthMeter(password: _password.text),
                        ),
                        const SizedBox(height: 14),
                        _passwordField(controller: _confirm, hint: '再打一次'),
                        if (_tried &&
                            _confirm.text.isNotEmpty &&
                            _confirm.text != _password.text)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text(
                              '兩次輸入不一樣',
                              style: TextStyle(fontSize: 12, color: Colors.red),
                            ),
                          ),
                      ],
                      SizedBox(
                        height: 26,
                        child: state.unlockError == null
                            ? null
                            : Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  // 不細分錯在哪，免得幫人縮小破解範圍。
                                  state.unlockError!,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.red,
                                  ),
                                ),
                              ),
                      ),
                      FilledButton(
                        onPressed: state.busy ? null : _submit,
                        child: state.busy
                            ? const SizedBox(
                                width: 17,
                                height: 17,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(_isSetup ? '建立保險庫' : '解除鎖定'),
                                  const SizedBox(width: 10),
                                  const Icon(Icons.arrow_forward, size: 17),
                                ],
                              ),
                      ),
                      if (!_isSetup && state.biometricArmed) ...[
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: state.busy
                              ? null
                              : () => state.unlockWithBiometrics(),
                          icon: const Icon(Icons.fingerprint, size: 18),
                          label: const Text('用 Touch ID 解除鎖定'),
                        ),
                      ],
                      const SizedBox(height: 22),
                      Divider(color: _border.withValues(alpha: 0.8), height: 1),
                      const SizedBox(height: 16),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SvgPicture.asset(
                            '$_assets/icons/info.svg',
                            width: 16,
                            height: 16,
                            colorFilter: const ColorFilter.mode(
                              _textSecondary,
                              BlendMode.srcIn,
                            ),
                          ),
                          const SizedBox(width: 9),
                          const Expanded(
                            child: Text(
                              '提醒：若忘記主密碼，將無法復原你的資料。',
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.55,
                                color: _textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// mockup 的欄位是有外框的方塊，左邊帶鎖頭、右邊帶眼睛。
  Widget _passwordField({
    required TextEditingController controller,
    required String hint,
    bool autofocus = false,
  }) {
    return TextField(
      controller: controller,
      obscureText: !_revealed,
      autofocus: autofocus,
      onSubmitted: (_) => _submit(),
      style: const TextStyle(fontSize: 14, color: _textPrimary),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(fontSize: 14, color: _textSecondary),
        filled: true,
        fillColor: _surfaceAlt.withValues(alpha: 0.6),
        contentPadding: const EdgeInsets.symmetric(vertical: 16),
        prefixIcon: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 10, 0),
          child: SvgPicture.asset(
            '$_assets/icons/lock.svg',
            width: 18,
            height: 18,
            colorFilter: const ColorFilter.mode(
              _textSecondary,
              BlendMode.srcIn,
            ),
          ),
        ),
        prefixIconConstraints: const BoxConstraints(minWidth: 44),
        suffixIcon: Padding(
          padding: const EdgeInsets.only(right: 8),
          child: RevealToggle(
            revealed: _revealed,
            onToggle: () => setState(() => _revealed = !_revealed),
          ),
        ),
        suffixIconConstraints: const BoxConstraints(minWidth: 46),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: _border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: _border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: _brandBlue, width: 1.6),
        ),
      ),
    );
  }
}

/// 左欄右緣的弧線，照 mockup 往右鼓出來一點。
class _CurvedEdgeClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    const bulge = 46.0;
    final straight = size.width - bulge;
    return Path()
      ..moveTo(0, 0)
      ..lineTo(straight, 0)
      ..cubicTo(
        straight + bulge * 1.1,
        size.height * 0.28,
        straight + bulge * 1.1,
        size.height * 0.72,
        straight,
        size.height,
      )
      ..lineTo(0, size.height)
      ..close();
  }

  @override
  bool shouldReclip(_CurvedEdgeClipper oldClipper) => false;
}

/// 卡片頂端那枚實心盾牌，中間挖一個鑰匙孔。
///
/// 素材的 shield.svg 是線稿，mockup 要的是實心加白色鎖頭，所以直接畫。
/// 造型跟 app icon 同一套語言（design/render_icon.swift）。
class _ShieldBadgePainter extends CustomPainter {
  const _ShieldBadgePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final shield = Path()
      ..moveTo(w * 0.5, h * 0.03)
      ..lineTo(w * 0.94, h * 0.19)
      ..lineTo(w * 0.94, h * 0.52)
      ..cubicTo(w * 0.94, h * 0.78, w * 0.76, h * 0.93, w * 0.5, h * 0.99)
      ..cubicTo(w * 0.24, h * 0.93, w * 0.06, h * 0.78, w * 0.06, h * 0.52)
      ..lineTo(w * 0.06, h * 0.19)
      ..close();

    canvas.drawPath(
      shield,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_brandBlueBright, _brandBlueDark],
        ).createShader(Rect.fromLTWH(0, 0, w, h)),
    );

    // 中間的鑰匙孔：圓加一道上窄下寬的槽，兩次分開填，免得繞行方向相反
    // 把重疊處挖掉。
    final white = Paint()..color = Colors.white;
    final cx = w * 0.5;
    final cy = h * 0.46;
    final r = w * 0.105;
    canvas.drawCircle(Offset(cx, cy), r, white);

    final slot = Path()
      ..moveTo(cx - r * 0.42, cy)
      ..lineTo(cx + r * 0.42, cy)
      ..lineTo(cx + r * 0.78, cy + r * 1.75)
      ..lineTo(cx - r * 0.78, cy + r * 1.75)
      ..close();
    canvas.drawPath(slot, white);
  }

  @override
  bool shouldRepaint(_ShieldBadgePainter oldDelegate) => false;
}
