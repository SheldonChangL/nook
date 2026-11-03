import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:securemanage/app/app_state.dart';
import 'package:securemanage/services/biometric_gate.dart';
import 'package:securemanage/ui/home_screen.dart';
import 'package:securemanage/ui/lock_screen.dart';
import 'package:securemanage/ui/theme.dart';
import 'package:securemanage/vault/models.dart';
import 'package:securemanage/vault/vault_store.dart';

/// 把各個畫面算成 PNG，用來人眼檢查版面。輸出在 design/screens/。
///
/// 跑法：flutter test tool/render_screens.dart --update-goldens
///
/// 刻意放在 test/ 外面：詳情面板會印出建立與更新時間，每跑一次都不一樣，
/// 當成回歸基準比對一定會壞。這些圖是給人看的，不是斷言。
///
/// 測試用的預設字型是方框字，中文會變成豆腐，所以借系統的 Arial Unicode 來算。
/// 全部都是假資料。
const masterPassword = 'fake-master-pw-for-render-2026!';
const _cjkFont = '/System/Library/Fonts/Supplemental/Arial Unicode.ttf';

class _NoBiometrics extends BiometricGate {
  @override
  Future<bool> get isAvailable async => false;
  @override
  Future<bool> get hasStoredKey async => false;
}

Future<void> grind(WidgetTester tester,
    {int rounds = 16, Duration step = const Duration(milliseconds: 80)}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(step);
  }
}

void main() {
  late Directory tmp;
  AppState? active;

  setUpAll(() async {
    final bytes = File(_cjkFont).readAsBytesSync();
    final loader = FontLoader('RenderCJK')
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('securemanage_render_');
  });

  tearDown(() {
    active?.lock();
    active = null;
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Widget harness(AppState state) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light().copyWith(
          textTheme: AppTheme.light().textTheme.apply(fontFamily: 'RenderCJK'),
        ),
        home: ListenableBuilder(
          listenable: state,
          builder: (context, _) => DefaultTextStyle.merge(
            style: const TextStyle(fontFamily: 'RenderCJK'),
            child: switch (state.phase) {
              VaultPhase.loading => const SizedBox.shrink(),
              VaultPhase.needsSetup || VaultPhase.locked =>
                LockScreen(state: state),
              VaultPhase.unlocked => HomeScreen(state: state),
            },
          ),
        ),
      );

  Future<AppState> bootUnlocked(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1120, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late List<VaultItem> seeded;
    await tester.runAsync(() async {
      final seed = VaultStore(tmp);
      await seed.create(masterPassword);
      seeded = _fakeData();
      for (final item in seeded) {
        await seed.put(item);
      }
      seed.lock();
    });

    final state =
        AppState(store: VaultStore(tmp), biometrics: _NoBiometrics());
    active = state;
    await state.boot();
    await tester.pumpWidget(harness(state));
    await grind(tester);

    await tester.runAsync(() => state.unlock(masterPassword));
    await grind(tester);
    return state;
  }

  testWidgets('算出上鎖畫面', (tester) async {
    tester.view.physicalSize = const Size(1120, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      final seed = VaultStore(tmp);
      await seed.create(masterPassword);
      seed.lock();
    });

    final state =
        AppState(store: VaultStore(tmp), biometrics: _NoBiometrics());
    active = state;
    await state.boot();
    await tester.pumpWidget(harness(state));
    await grind(tester);

    await expectLater(
        find.byType(LockScreen), matchesGoldenFile('../design/screens/01_lock.png'));
  });

  testWidgets('算出主畫面清單', (tester) async {
    await bootUnlocked(tester);
    await expectLater(
        find.byType(HomeScreen), matchesGoldenFile('../design/screens/02_list.png'));
  });

  testWidgets('算出詳情面板', (tester) async {
    await bootUnlocked(tester);
    await tester.tap(find.text('demo-box').first);
    await grind(tester);
    await expectLater(
        find.byType(HomeScreen), matchesGoldenFile('../design/screens/03_detail.png'));
  });

  testWidgets('算出 ⌘K 面板', (tester) async {
    await bootUnlocked(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await grind(tester);
    await tester.enterText(find.byType(TextField).last, 'box');
    await grind(tester);
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('../design/screens/04_palette.png'));
  });

  testWidgets('算出新增主機表單', (tester) async {
    await bootUnlocked(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, '新增'));
    await grind(tester);
    await tester.tap(find.widgetWithText(MenuItemButton, '主機 / VM'));
    await grind(tester);
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('../design/screens/05_editor.png'));
  });
}

/// 全部捏造，跟使用者真實的主機或憑證無關。
List<VaultItem> _fakeData() {
  final key = SecureKeyItem(
    name: '示範部署金鑰',
    keyKind: KeyKind.sshPrivateKey,
    algorithm: 'ed25519',
    secret: 'FAKE-KEY-BODY-FOR-RENDERING-ONLY',
    passphrase: 'fake-passphrase',
    tags: ['lab'],
  );
  return [
    key,
    HostItem(
      name: 'demo-box',
      hostname: '198.51.100.7',
      port: 22,
      username: 'ubuntu',
      keyRef: key.id,
      sudoPassword: 'fake-sudo-password',
      env: [
        EnvVar(name: 'DEMO_TOKEN', value: 'fake-token-value', secret: true),
        EnvVar(name: 'PG_DSN', value: 'postgres://demo@localhost/demo'),
      ],
      tags: ['lab'],
      notes: '這是示範資料，不是真的主機。',
    ),
    HostItem(
      name: 'build-farm',
      hostname: '198.51.100.42',
      port: 2222,
      username: 'builder',
      jumpHost: 'gateway.example.test',
      tags: ['work'],
    ),
    AccountItem(
      name: '示範 wiki',
      url: 'wiki.example.test',
      username: 'demo.user',
      password: 'fake-account-password',
      tags: ['work'],
    ),
  ];
}
