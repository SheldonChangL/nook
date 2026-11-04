import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../app/app_state.dart';
import 'theme.dart';
import 'widgets/fields.dart';
import 'widgets/motion.dart';

/// 鎖定畫面：窄版獨立視窗（540×700）。
///
/// 構圖照 mockup 分成兩段：上半部整面是「門縫透光」的主視覺，左上角壓品牌；
/// 下半部是靠底對齊的緊湊表單（標題、主密碼欄、一顆按鈕）。深淺色共用
/// 同一套幾何，只換 [NookPalette] 的色票。
class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.state});

  final AppState state;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

const _assets = brandAssets;

/// mockup 的左右留白與頂部品牌位置；ui_flow_test 也鎖著這幾個數字。
const _gutter = 48.0;
const _brandTop = 56.0;
const _formBottom = 52.0;

class _LockScreenState extends State<LockScreen> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  int _shake = 0;
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
    final palette = NookPalette(widget.state.darkAppearance);
    return Theme(
      data: AppTheme.nook(palette.dark),
      child: Scaffold(
        backgroundColor: palette.background,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // 整面都是門縫場景；表單疊在它的下半部，光束從表單上方打下來。
            CustomPaint(
              key: const ValueKey('lock-door-scene'),
              painter: _DoorwayPainter(palette),
            ),
            Positioned(
              key: const ValueKey('lock-brand'),
              top: _brandTop,
              left: _gutter,
              child: RiseIn(child: _brandLockup(palette)),
            ),
            Positioned(
              top: 12,
              right: 12,
              child: AppearanceToggle(state: widget.state),
            ),
            Positioned(
              key: const ValueKey('lock-form'),
              left: _gutter,
              right: _gutter,
              bottom: _formBottom,
              child: RiseIn(delay: Motion.stagger, child: _form(palette)),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 品牌

  Widget _brandLockup(NookPalette palette) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _VaultMark(palette: palette, size: 46),
      const SizedBox(width: 14),
      Text(
        'Nook',
        style: TextStyle(
          fontSize: 30,
          height: 1,
          fontWeight: FontWeight.w600,
          letterSpacing: -.3,
          color: palette.text,
        ),
      ),
    ],
  );

  // ---------------------------------------------------------------- 表單

  Widget _form(NookPalette palette) {
    final state = widget.state;
    final error = state.unlockError;
    return ShakeOnError(
      trigger: _shake,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 文案沿用原本的版本，只有版面照新 mockup。
          Text(
            _isSetup ? '建立你的 Nook' : '解除鎖定並進入 Nook',
            style: TextStyle(
              fontSize: 30,
              height: 1.2,
              fontWeight: FontWeight.w700,
              letterSpacing: .3,
              color: palette.text,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _isSetup ? '設定一組主密碼來保護你的資料' : '請輸入主密碼以存取你的資料',
            style: TextStyle(fontSize: 13.5, height: 1.5, color: palette.muted),
          ),
          SizedBox(height: _isSetup ? 18 : 24),
          _label('主密碼', palette),
          const SizedBox(height: 10),
          _passwordField(controller: _password, hint: '主密碼', autofocus: true),
          if (_isSetup) ...[
            const SizedBox(height: 10),
            AnimatedBuilder(
              animation: _password,
              builder: (context, _) => StrengthMeter(password: _password.text),
            ),
            const SizedBox(height: 14),
            _label('再打一次', palette),
            const SizedBox(height: 10),
            _passwordField(controller: _confirm, hint: '再打一次'),
          ],
          // 錯誤訊息放在按鈕上方那段固定間距裡，出現時整體不跳動。
          SizedBox(
            height: 26,
            child: error == null
                ? null
                : Padding(
                    padding: const EdgeInsets.only(top: 7),
                    child: Text(
                      error,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFFFF6B6B),
                      ),
                    ),
                  ),
          ),
          FilledButton(
            onPressed: state.busy ? null : _submit,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              visualDensity: VisualDensity.standard,
              // 淺色 mockup 的按鈕是沉一點的鋼藍配白字。
              backgroundColor: palette.dark ? null : const Color(0xFF3F86B6),
              foregroundColor: palette.dark ? null : Colors.white,
              textStyle: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                letterSpacing: 1,
              ),
            ),
            child: state.busy
                ? const SizedBox(
                    width: 17,
                    height: 17,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(_isSetup ? '建立保險庫' : '解除鎖定'),
          ),
          if (!_isSetup && state.biometricArmed) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: state.busy ? null : state.unlockWithBiometrics,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(44),
                visualDensity: VisualDensity.standard,
              ),
              icon: const Icon(Icons.fingerprint, size: 18),
              label: const Text('用 Touch ID 解除鎖定'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _label(String text, NookPalette palette) => Text(
    text,
    style: TextStyle(
      fontSize: 14,
      height: 1.3,
      fontWeight: FontWeight.w500,
      // 淺色 mockup 的欄位標籤是深灰，不是正文的深藍黑。
      color: palette.dark ? palette.text : const Color(0xFF515259),
    ),
  );

  /// mockup 的欄位：有外框的圓角方塊，左邊鎖頭、右邊眼睛。
  Widget _passwordField({
    required TextEditingController controller,
    required String hint,
    bool autofocus = false,
  }) {
    final palette = NookPalette(widget.state.darkAppearance);
    final fieldBorder = palette.dark
        ? palette.border
        : const Color(0xFFD7D7D7);
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: color, width: width),
        );
    return TextField(
      controller: controller,
      obscureText: !_revealed,
      autofocus: autofocus,
      onSubmitted: (_) => _submit(),
      style: TextStyle(fontSize: 15, letterSpacing: 2, color: palette.text),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(
          fontSize: 14,
          letterSpacing: 0,
          color: palette.muted,
        ),
        filled: true,
        // 淺色 mockup 的欄位近乎白底、中性灰框。
        fillColor: palette.dark
            ? palette.surfaceRaised
            : const Color(0xFFF7F9F8),
        isDense: false,
        // 主題的 isDense 會把欄位壓成 23pt；mockup 是 50pt 高的方塊。
        constraints: const BoxConstraints.tightFor(height: 50),
        contentPadding: EdgeInsets.zero,
        prefixIcon: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
          child: SvgPicture.asset(
            '$_assets/icons/lock.svg',
            width: 18,
            height: 18,
            colorFilter: ColorFilter.mode(palette.muted, BlendMode.srcIn),
          ),
        ),
        prefixIconConstraints: const BoxConstraints(minWidth: 46),
        suffixIcon: Padding(
          padding: const EdgeInsets.only(right: 10),
          child: RevealToggle(
            revealed: _revealed,
            onToggle: () => setState(() => _revealed = !_revealed),
          ),
        ),
        suffixIconConstraints: const BoxConstraints(minWidth: 46),
        border: border(fieldBorder),
        enabledBorder: border(fieldBorder),
        focusedBorder: border(palette.accent, 1.4),
      ),
    );
  }
}

// ------------------------------------------------------------------ 品牌圖

/// 品牌標誌：一塊屋形（五角）的淺色門體，中央一個深色鑰匙孔，右側帶一片厚度。
class _VaultMark extends StatelessWidget {
  const _VaultMark({required this.palette, required this.size});

  final NookPalette palette;
  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _VaultMarkPainter(palette));
}

class _VaultMarkPainter extends CustomPainter {
  const _VaultMarkPainter(this.palette);

  final NookPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final dark = palette.dark;

    // 正面：尖頂的五角形，左下往右上微微傾斜。
    final front = Path()
      ..moveTo(w * .44, h * .02)
      ..lineTo(w * .80, h * .24)
      ..lineTo(w * .80, h * .96)
      ..lineTo(w * .08, h * .96)
      ..lineTo(w * .08, h * .24)
      ..close();
    // 右側厚度：跟正面右邊平行，往右上方偏移一點。
    final side = Path()
      ..moveTo(w * .44, h * .02)
      ..lineTo(w * .58, h * .00)
      ..lineTo(w * .94, h * .20)
      ..lineTo(w * .94, h * .90)
      ..lineTo(w * .80, h * .96)
      ..lineTo(w * .80, h * .24)
      ..close();

    canvas.drawPath(
      side,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: dark
              ? const [Color(0xFF8FDDF2), Color(0xFF3FB4D6)]
              : const [Color(0xFF8ACDEA), Color(0xFF3F9BC6)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      front,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? const [Color(0xFFF4FDFF), Color(0xFFBDEFFB), Color(0xFF86DCF2)]
              : const [Color(0xFFFFFFFF), Color(0xFFCDEEFA), Color(0xFF93D3EE)],
          stops: const [0, .55, 1],
        ).createShader(Offset.zero & size),
    );

    // 鑰匙孔：深色圓頭加往下收的匙身，放在正面偏下的中央。
    final hole = dark ? const Color(0xFF061722) : const Color(0xFF17364A);
    canvas.drawCircle(Offset(w * .44, h * .52), w * .11, Paint()..color = hole);
    canvas.drawPath(
      Path()
        ..moveTo(w * .37, h * .58)
        ..lineTo(w * .51, h * .58)
        ..lineTo(w * .55, h * .82)
        ..lineTo(w * .33, h * .82)
        ..close(),
      Paint()..color = hole,
    );
  }

  @override
  bool shouldRepaint(_VaultMarkPainter oldDelegate) =>
      oldDelegate.palette.dark != palette.dark;
}

// ------------------------------------------------------------------ 門縫場景

/// 上半部的主視覺，結構照 mockup 是個「反 Z」：
/// 右側一扇往外推開的門，門縫是一條等寬的直立光帶；門縫頂端有一道亮邊
/// 沿著門頂往右上延伸到門的遠角，底端的光則往左下灑在地板上漫開。
/// 門板本身是暗的，只比牆面亮一階。
///
/// 幾何全部用比例寫，窗寬 540 / 高 700 時對得上 mockup；視窗略大也不會跑掉。
class _DoorwayPainter extends CustomPainter {
  const _DoorwayPainter(this.palette);

  final NookPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final bounds = Offset.zero & size;
    final dark = palette.dark;
    final accent = palette.accent;
    final glow = dark ? const Color(0xFF8FE4FA) : const Color(0xFF8CD2F0);
    final bright = dark ? const Color(0xFFDCF8FF) : const Color(0xFFDDF5FD);

    // 1. 底：左上略亮、往右下沉下去。
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? const [Color(0xFF0C1D2B), Color(0xFF071520), Color(0xFF05101A)]
              : const [Color(0xFFF7F7F5), Color(0xFFF3F4F1), Color(0xFFEDEFEE)],
          stops: const [0, .55, 1],
        ).createShader(bounds),
    );

    // 門縫：等寬直立光帶，頂邊跟著門頂的透視微微上揚。
    final crackTL = Offset(w * .687, h * .178);
    final crackTR = Offset(w * .727, h * .170);
    final crackBR = Offset(w * .727, h * .465);
    final crackBL = Offset(w * .687, h * .465);
    // 門的遠角（門板右上、右下）。
    final doorTopFar = Offset(w * .89, h * .113);
    final doorBotFar = Offset(w * .89, h * .54);
    final floorY = crackBL.dy;

    // 3. 環境光：門縫左邊的牆被染上一層淡藍。
    final mid = Offset(w * .69, h * .33);
    final ambient = Rect.fromCircle(center: mid, radius: w * .5);
    canvas.drawCircle(
      mid,
      w * .5,
      Paint()
        ..shader = RadialGradient(
          colors: [
            accent.withValues(alpha: dark ? .20 : .16),
            accent.withValues(alpha: 0),
          ],
        ).createShader(ambient),
    );

    // 4. 門板：暗的，只比牆亮一階，靠縫那側稍微受光。
    final door = Path()
      ..moveTo(crackTR.dx, crackTR.dy)
      ..lineTo(doorTopFar.dx, doorTopFar.dy)
      ..lineTo(doorBotFar.dx, doorBotFar.dy)
      ..lineTo(crackBR.dx, crackBR.dy)
      ..close();
    canvas.drawPath(
      door,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: dark
              ? const [Color(0xFF10344A), Color(0xFF0A2234), Color(0xFF061421)]
              : const [Color(0xFFD3DEE5), Color(0xFFDCE5EA), Color(0xFFE9EDF0)],
          stops: const [0, .4, 1],
        ).createShader(Rect.fromLTRB(crackTR.dx, 0, doorTopFar.dx, h)),
    );
    // 門板底邊的一道淡邊，交代門板與地板的交線。
    canvas.drawLine(
      crackBR,
      doorBotFar,
      Paint()
        ..shader = LinearGradient(
          colors: [
            bright.withValues(alpha: dark ? .8 : .9),
            glow.withValues(alpha: dark ? .25 : .3),
            glow.withValues(alpha: 0),
          ],
          stops: const [0, .5, 1],
        ).createShader(Rect.fromPoints(crackBR, doorBotFar))
        ..strokeWidth = 1.2,
    );

    // 5. 反 Z 的上一撇：門頂那道被光打亮的薄邊，從門縫頂往右上到遠角，越遠越淡。
    final lintel = Path()
      ..moveTo(crackTL.dx, crackTL.dy)
      ..lineTo(doorTopFar.dx, doorTopFar.dy)
      ..lineTo(doorTopFar.dx, doorTopFar.dy + 1.5)
      ..lineTo(crackTR.dx, crackTR.dy + 7)
      ..close();
    final lintelRect = Rect.fromPoints(crackTL, doorTopFar);
    canvas.drawPath(
      lintel,
      Paint()
        ..color = glow.withValues(alpha: dark ? .5 : .45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawPath(
      lintel,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [bright, glow, glow.withValues(alpha: .15)],
          stops: const [0, .35, 1],
        ).createShader(lintelRect),
    );

    // 6. 反 Z 的下一撇：門縫底的光打在地板上。上緣是一條清楚的斜線從門縫底
    //    往左下走，光從門縫底往外衰減：往左、往下都散掉，右邊沿門板底線帶一小段。
    final spill = Path()
      ..moveTo(0, floorY + h * .085)
      ..lineTo(crackBL.dx, crackBL.dy)
      ..lineTo(crackBR.dx, crackBR.dy)
      ..lineTo(crackBR.dx + w * .14, crackBR.dy + h * .065)
      ..lineTo(w, floorY + h * .36)
      ..lineTo(0, floorY + h * .36)
      ..close();
    canvas.drawPath(
      spill,
      Paint()
        ..shader = RadialGradient(
          colors: [
            bright.withValues(alpha: dark ? .9 : .9),
            glow.withValues(alpha: dark ? .55 : .5),
            accent.withValues(alpha: dark ? .18 : .14),
            accent.withValues(alpha: 0),
          ],
          stops: const [0, .15, .42, 1],
          transform: _SquashY(crackBL, .38),
        ).createShader(Rect.fromCircle(center: crackBL, radius: w * .62)),
    );
    // 地板整片再罩一層很淡的藍，讓光不是只有那一片楔形。
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(w * .55, floorY + h * .17),
        width: w * .95,
        height: h * .18,
      ),
      Paint()
        ..color = accent.withValues(alpha: dark ? .07 : .05)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 30),
    );

    // 7. 門縫本體：等寬光帶，上下兩端最亮、中段稍沉；外罩一層柔光。
    final crack = Path()
      ..moveTo(crackTL.dx, crackTL.dy)
      ..lineTo(crackTR.dx, crackTR.dy)
      ..lineTo(crackBR.dx, crackBR.dy)
      ..lineTo(crackBL.dx, crackBL.dy)
      ..close();
    final crackRect = Rect.fromLTRB(
      crackBL.dx,
      crackTR.dy,
      crackBR.dx,
      crackBR.dy,
    );
    canvas.drawPath(
      crack,
      Paint()
        ..color = glow.withValues(alpha: dark ? .45 : .4)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
    );
    canvas.drawPath(
      crack,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: dark
              ? const [
                  Color(0xFF86E4FA),
                  Color(0xFF55B8D8),
                  Color(0xFF48AACB),
                  Color(0xFF6CCCE6),
                  Color(0xFFDDF9FF),
                ]
              : const [
                  Color(0xFF5FA8D7),
                  Color(0xFF70B9E3),
                  Color(0xFF81C7EC),
                  Color(0xFFA8DEF5),
                  Color(0xFFDCF8FD),
                ],
          stops: const [0, .25, .6, .9, 1],
        ).createShader(crackRect),
    );
    // 光帶左緣有一條更亮的細線，是門框被直接照到的邊。
    canvas.drawLine(
      crackTL,
      crackBL,
      Paint()
        ..color = bright.withValues(alpha: dark ? .9 : .95)
        ..strokeWidth = 1.5,
    );
    // 底端最亮的那一小段。
    final hot = Rect.fromLTRB(
      crackBL.dx - 6,
      floorY - 14,
      crackBR.dx + 6,
      floorY + 6,
    );
    canvas.drawRect(
      hot,
      Paint()
        ..color = Colors.white.withValues(alpha: dark ? .55 : .6)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    // 8. 淺色模式牆面太平，門板下緣補一道淡影讓門看起來是立體的。
    if (!dark) {
      final shade = Path()
        ..moveTo(crackBR.dx, crackBR.dy)
        ..lineTo(doorBotFar.dx, doorBotFar.dy)
        ..lineTo(doorBotFar.dx, doorBotFar.dy + h * .08)
        ..lineTo(crackBR.dx + w * .04, crackBR.dy + h * .05)
        ..close();
      canvas.drawPath(
        shade,
        Paint()
          ..color = const Color(0xFF9FB3BD).withValues(alpha: .22)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );
    }
  }

  @override
  bool shouldRepaint(_DoorwayPainter oldDelegate) =>
      oldDelegate.palette.dark != palette.dark;
}

/// 把徑向漸層以 [center] 為中心在垂直方向壓扁，地板上的光才會是扁的橢圓而不是圓。
class _SquashY extends GradientTransform {
  const _SquashY(this.center, this.factor);

  final Offset center;
  final double factor;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.identity()
        ..translate(center.dx, center.dy)
        ..scale(1.0, factor)
        ..translate(-center.dx, -center.dy);
}
