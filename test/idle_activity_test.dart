import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:securemanage/app/app_state.dart';
import 'package:securemanage/main.dart';
import 'package:securemanage/services/biometric_gate.dart';
import 'package:securemanage/vault/models.dart';
import 'package:securemanage/vault/vault_crypto.dart';
import 'package:securemanage/vault/vault_store.dart';

/// 這幾個測試守的是一個實際踩到的狀況：新增項目打到一半被自動上鎖。
///
/// 當時有三個問題疊在一起：
///   1. 只監聽滑鼠的 onPointerDown，打字完全不算活動
///   2. Listener 掛在 HomeScreen 裡，而對話框是 Navigator 上另一個 route，
///      連在對話框裡點擊都不會經過它
///   3. 上鎖之後對話框還留在畫面上，繼續顯示已經展開的機密
///
/// 所以這裡一定要掛真正的 NookApp，不能自己兜一個簡化的 harness，
/// 不然測到的是假的接線。
const masterPassword = 'fake-master-pw-for-tests-2026!';

class _NoBiometrics extends BiometricGate {
  @override
  Future<bool> get isAvailable async => false;
  @override
  Future<bool> get hasStoredKey async => false;
}

Future<void> grind(
  WidgetTester tester, {
  int rounds = 16,
  Duration step = const Duration(milliseconds: 80),
}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(step);
  }
}

void main() {
  late Directory tmp;
  AppState? active;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('securemanage_idle_');
  });

  tearDown(() {
    active?.lock();
    active = null;
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 掛上真正的 app，解鎖，回傳狀態。
  Future<AppState> bootUnlocked(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 860);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      final seed = VaultStore(tmp, kdfFactory: KdfParams.weakForTests);
      await seed.create(masterPassword);
      await seed.put(SecureKeyItem(
        name: '示範金鑰',
        algorithm: 'ed25519',
        secret: 'FAKE-KEY-BODY',
      ));
      seed.lock();
    });

    final state =
        AppState(store: VaultStore(tmp, kdfFactory: KdfParams.weakForTests), biometrics: _NoBiometrics());
    active = state;
    await tester.pumpWidget(NookApp(state: state));
    await grind(tester);

    await tester.enterText(find.byType(TextField).first, masterPassword);
    await grind(tester);
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '解除鎖定'));
      for (var i = 0; i < 600 && state.phase != VaultPhase.unlocked; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await grind(tester);
    expect(state.phase, VaultPhase.unlocked);
    return state;
  }

  Future<void> openEditor(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, '新增'));
    await grind(tester);
    await tester.tap(find.widgetWithText(MenuItemButton, '主機 / VM'));
    await grind(tester);
    expect(find.text('新增主機 / VM'), findsOneWidget);
  }

  testWidgets('在分類頁按新增，直接開該類型的表單，不再問要哪一種', (tester) async {
    await bootUnlocked(tester);

    // 預設在「全部」，這時按新增應該要跳出選單讓你挑類型。
    await tester.tap(find.widgetWithText(FilledButton, '新增'));
    await grind(tester);
    expect(find.byType(MenuItemButton), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await grind(tester);

    // 切到「金鑰」之後，按新增就該直接開金鑰的表單。
    await tester.tap(find.text('金鑰').first);
    await grind(tester);
    await tester.tap(find.widgetWithText(FilledButton, '新增'));
    await grind(tester);

    expect(find.text('新增金鑰'), findsOneWidget);
    expect(find.byType(MenuItemButton), findsNothing,
        reason: '已經在金鑰分類了，不該再問一次要新增哪一種');
  });

  testWidgets('打字算活動，會把自動上鎖的倒數推回去', (tester) async {
    final state = await bootUnlocked(tester);

    final before = state.touchCount;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await grind(tester, rounds: 2);

    expect(state.touchCount, greaterThan(before),
        reason: '鍵盤輸入沒有被算成活動，打字打到一半就會被上鎖');
  });

  testWidgets('在新增對話框裡打字也算活動', (tester) async {
    final state = await bootUnlocked(tester);
    await openEditor(tester);

    final before = state.touchCount;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await grind(tester, rounds: 2);

    expect(state.touchCount, greaterThan(before),
        reason: '對話框開著的時候鍵盤事件必須照樣算數');
  });

  testWidgets('在新增對話框裡點滑鼠也算活動', (tester) async {
    final state = await bootUnlocked(tester);
    await openEditor(tester);

    final before = state.touchCount;
    // 點對話框裡的欄位。這個事件走的是 Navigator 上另一個 route，
    // 掛在 HomeScreen 裡的 Listener 收不到。
    await tester.tap(find.descendant(
        of: find.byType(Dialog), matching: find.byType(TextField)).first);
    await grind(tester, rounds: 2);

    expect(state.touchCount, greaterThan(before),
        reason: '對話框裡的點擊沒算到，填表途中就會被上鎖');
  });

  testWidgets('上鎖時會把還開著的對話框收掉', (tester) async {
    final state = await bootUnlocked(tester);
    await openEditor(tester);

    // 在 sudo 密碼欄位打字，模擬填到一半。
    final fields = find.descendant(
        of: find.byType(Dialog), matching: find.byType(TextField));
    await tester.enterText(fields.at(0), 'halfway-typed');
    await grind(tester);
    expect(find.byType(Dialog), findsOneWidget);

    state.lock();
    await grind(tester);

    expect(state.phase, VaultPhase.locked);
    expect(find.byType(Dialog), findsNothing,
        reason: '編輯器留在上鎖畫面上的話，已經展開的機密會繼續顯示在那裡');
    expect(find.text('halfway-typed'), findsNothing);
    expect(find.text('請輸入主密碼以存取你的資料'), findsOneWidget);
  });

  testWidgets('預設切換到其他 app 不會上鎖', (tester) async {
    final state = await bootUnlocked(tester);
    expect(state.settings.lockOnAppSwitch, isFalse, reason: '這個行為預設要關著');

    // macOS 只要焦點切到別的 app 就會送 hidden（實測過），視窗不用被遮住。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await grind(tester, rounds: 4);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await grind(tester, rounds: 4);

    expect(state.phase, VaultPhase.unlocked,
        reason: '⌘Tab 切個視窗就被鎖掉的話根本沒辦法用');

    // 回來的路徑也得照順序走，Flutter 不允許狀態亂跳。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await grind(tester, rounds: 4);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await grind(tester, rounds: 4);
    expect(state.phase, VaultPhase.unlocked);
  });

  testWidgets('開了設定之後切換到其他 app 就會上鎖', (tester) async {
    final state = await bootUnlocked(tester);
    await tester.runAsync(() => state.setLockOnAppSwitch(true));
    await grind(tester, rounds: 4);
    expect(state.settings.lockOnAppSwitch, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await grind(tester, rounds: 4);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await grind(tester, rounds: 4);
    expect(state.phase, VaultPhase.locked);

    // 停在 hidden 的時候 Flutter 不會產生畫面，所以要切回來才看得到上鎖畫面。
    // 真實使用也是這樣：你切回 app 才會看到它鎖上了。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await grind(tester, rounds: 4);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await grind(tester, rounds: 4);
    expect(find.text('請輸入主密碼以存取你的資料'), findsOneWidget);
  });

  testWidgets('上鎖時也會把詳情面板收掉', (tester) async {
    final state = await bootUnlocked(tester);
    await tester.tap(find.text('示範金鑰').first);
    await grind(tester);

    state.lock();
    await grind(tester);

    expect(state.phase, VaultPhase.locked);
    expect(find.text('示範金鑰'), findsNothing);
    expect(find.text('請輸入主密碼以存取你的資料'), findsOneWidget);
  });
}
