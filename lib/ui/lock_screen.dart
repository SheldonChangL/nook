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
      _VaultMark(palette: palette, size: 44),
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
      color: palette.text,
    ),
  );

  /// mockup 的欄位：有外框的圓角方塊，左邊鎖頭、右邊眼睛。
  Widget _passwordField({
    required TextEditingController controller,
    required String hint,
    bool autofocus = false,
  }) {
    final palette = NookPalette(widget.state.darkAppearance);
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
        fillColor: palette.surfaceRaised,
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
        border: border(palette.border),
        enabledBorder: border(palette.border),
        focusedBorder: border(palette.accent, 1.4),
      ),
    );
  }
}

// ------------------------------------------------------------------ 品牌圖

/// 品牌標誌：一顆等角立方體，左面開一道有鑰匙孔的門。
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
    // 等角投影的頂點：頂、左、右、中、左下、右下、底。
    final top = Offset(w * .50, h * .04);
    final left = Offset(w * .06, h * .27);
    final right = Offset(w * .94, h * .27);
    final center = Offset(w * .50, h * .50);
    final bottomLeft = Offset(w * .06, h * .73);
    final bottomRight = Offset(w * .94, h * .73);
    final bottom = Offset(w * .50, h * .96);

    final dark = palette.dark;
    final topFace = Path()
      ..moveTo(top.dx, top.dy)
      ..lineTo(right.dx, right.dy)
      ..lineTo(center.dx, center.dy)
      ..lineTo(left.dx, left.dy)
      ..close();
    final leftFace = Path()
      ..moveTo(left.dx, left.dy)
      ..lineTo(center.dx, center.dy)
      ..lineTo(bottom.dx, bottom.dy)
      ..lineTo(bottomLeft.dx, bottomLeft.dy)
      ..close();
    final rightFace = Path()
      ..moveTo(center.dx, center.dy)
      ..lineTo(right.dx, right.dy)
      ..lineTo(bottomRight.dx, bottomRight.dy)
      ..lineTo(bottom.dx, bottom.dy)
      ..close();

    canvas.drawPath(
      topFace,
      Paint()..color = dark ? const Color(0xFFEAFBFF) : const Color(0xFFF2FBFF),
    );
    canvas.drawPath(
      leftFace,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: dark
              ? const [Color(0xFFBDEFFB), Color(0xFF7FD9F2)]
              : const [Color(0xFFC9ECFA), Color(0xFF8ED3EE)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      rightFace,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: dark
              ? const [Color(0xFF7CD6F0), Color(0xFF3FB8DB)]
              : const [Color(0xFF8ACDEA), Color(0xFF4FA9D1)],
        ).createShader(Offset.zero & size),
    );

    // 左面上的門：跟著面的斜度；門面深色、鑰匙孔亮色。
    final door = Path()
      ..moveTo(w * .20, h * .40)
      ..lineTo(w * .42, h * .51)
      ..lineTo(w * .42, h * .86)
      ..lineTo(w * .20, h * .75)
      ..close();
    canvas.drawPath(
      door,
      Paint()..color = dark ? const Color(0xFF061722) : const Color(0xFF17364A),
    );
    final keyhole = dark ? Colors.white : const Color(0xFFE6F8FF);
    canvas.drawCircle(
      Offset(w * .31, h * .575),
      w * .05,
      Paint()..color = keyhole,
    );
    canvas.drawPath(
      Path()
        ..moveTo(w * .29, h * .60)
        ..lineTo(w * .33, h * .62)
        ..lineTo(w * .33, h * .72)
        ..lineTo(w * .29, h * .70)
        ..close(),
      Paint()..color = keyhole,
    );
  }

  @override
  bool shouldRepaint(_VaultMarkPainter oldDelegate) =>
      oldDelegate.palette.dark != palette.dark;
}

// ------------------------------------------------------------------ 門縫場景

/// 上半部的主視覺：一道微開的門在畫面右側，門縫透出一道冷光，
/// 光束沿著地板往左下掃過來，剛好停在表單上緣。
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
    final glow = dark ? const Color(0xFF9FEBFF) : const Color(0xFF7FD4F7);

    // 1. 底：左上略亮、往右下沉下去，營造房間深度。
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? const [Color(0xFF0E2131), Color(0xFF071520), Color(0xFF05101A)]
              : const [Color(0xFFFBFBFA), Color(0xFFF2F3F1), Color(0xFFE9ECEB)],
          stops: const [0, .55, 1],
        ).createShader(bounds),
    );

    // 門縫的位置與長度。
    final slitX = w * .825;
    final slitTop = h * .18;
    final slitBottom = h * .50;
    final slitMid = Offset(slitX, (slitTop + slitBottom) / 2);

    // 2. 環境光：門縫周圍一團柔光，把牆面染成微藍。
    final ambient = Rect.fromCircle(center: slitMid, radius: w * .55);
    canvas.drawCircle(
      slitMid,
      w * .55,
      Paint()
        ..shader = RadialGradient(
          colors: [
            accent.withValues(alpha: dark ? .22 : .18),
            accent.withValues(alpha: 0),
          ],
        ).createShader(ambient),
    );

    // 3. 地板：門縫底部高度往下是地面，色階比牆面稍亮一點點。
    final floor = Rect.fromLTRB(0, slitBottom, w, h);
    canvas.drawRect(
      floor,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: dark
              ? [
                  const Color(0xFF0E2434).withValues(alpha: .55),
                  const Color(0xFF071520).withValues(alpha: 0),
                ]
              : [
                  const Color(0xFFDDE4E6).withValues(alpha: .6),
                  const Color(0xFFF2F3F1).withValues(alpha: 0),
                ],
          stops: const [0, .6],
        ).createShader(floor),
    );

    // 4. 門板：右側一片在透視裡往外推開的平面，比牆面亮一階。
    final door = Path()
      ..moveTo(slitX, slitTop)
      ..lineTo(w, h * .13)
      ..lineTo(w, h * .57)
      ..lineTo(slitX, slitBottom)
      ..close();
    canvas.drawPath(
      door,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: dark
              ? const [Color(0xFF17364A), Color(0xFF0D2334)]
              : const [Color(0xFFFFFFFF), Color(0xFFE4EBEE)],
        ).createShader(Rect.fromLTRB(slitX, 0, w, h)),
    );
    // 門板靠門縫那側被光打亮，往右漸暗。
    canvas.drawPath(
      door,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            glow.withValues(alpha: dark ? .22 : .35),
            glow.withValues(alpha: 0),
          ],
          stops: const [0, .6],
        ).createShader(Rect.fromLTRB(slitX, 0, w, h)),
    );

    // 5. 地板上的光束：從門縫底往左下掃出去的扇形，越遠越淡。
    final beamEnd = Offset(w * .40, h * .64);
    final beam = Path()
      ..moveTo(slitX - 2, slitBottom - 4)
      ..lineTo(slitX + 8, slitBottom + 3)
      ..lineTo(w * .72, h * .65)
      ..lineTo(beamEnd.dx, beamEnd.dy)
      ..close();
    canvas.drawPath(
      beam,
      Paint()
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5)
        ..shader = LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [
            glow.withValues(alpha: dark ? .5 : .45),
            accent.withValues(alpha: dark ? .14 : .12),
            accent.withValues(alpha: 0),
          ],
          stops: const [0, .4, 1],
        ).createShader(Rect.fromPoints(Offset(slitX, slitBottom), beamEnd)),
    );

    // 6. 門縫本體：上窄下寬的一線光，外面再罩兩層模糊光暈。
    final slit = Path()
      ..moveTo(slitX - 1, slitTop)
      ..lineTo(slitX + 1.5, slitTop)
      ..lineTo(slitX + 4.5, slitBottom)
      ..lineTo(slitX - 3.5, slitBottom)
      ..close();
    canvas.drawPath(
      slit,
      Paint()
        ..color = glow.withValues(alpha: dark ? .9 : .85)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );
    canvas.drawPath(
      slit,
      Paint()
        ..color = accent.withValues(alpha: .9)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawPath(
      slit,
      Paint()
        ..shader =
            LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [glow, Colors.white],
            ).createShader(
              Rect.fromLTRB(slitX - 4, slitTop, slitX + 5, slitBottom),
            ),
    );

    // 7. 門縫底部最亮的一點，光束從這裡出發。
    final hot = Offset(slitX, slitBottom);
    final hotRect = Rect.fromCircle(center: hot, radius: w * .09);
    canvas.drawCircle(
      hot,
      w * .09,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.white.withValues(alpha: dark ? .55 : .7),
            glow.withValues(alpha: 0),
          ],
        ).createShader(hotRect),
    );

    // 8. 淺色模式牆面太平，門板下緣補一道很淡的陰影讓門看起來是立體的。
    if (!dark) {
      final shade = Path()
        ..moveTo(slitX, slitBottom)
        ..lineTo(w, h * .57)
        ..lineTo(w, h * .66)
        ..lineTo(slitX + w * .04, slitBottom + h * .05)
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
