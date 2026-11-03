import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:securemanage/app/app_state.dart';
import 'package:securemanage/services/biometric_gate.dart';
import 'package:securemanage/ui/home_screen.dart';
import 'package:securemanage/ui/lock_screen.dart';
import 'package:securemanage/ui/theme.dart';
import 'package:securemanage/vault/models.dart';
import 'package:securemanage/vault/vault_crypto.dart';
import 'package:securemanage/vault/vault_store.dart';

/// 驅動真實 UI 跑一輪：建立保險庫 → 新增項目 → 上鎖 → 用錯密碼 → 用對密碼 → 讀回。
/// 全程用這裡捏造的假資料。
const masterPassword = 'fake-master-pw-for-tests-2026!';

/// 測試環境沒有 Touch ID 的 platform channel，呼叫下去不會回來。
class _NoBiometrics extends BiometricGate {
  @override
  Future<bool> get isAvailable async => false;
  @override
  Future<bool> get hasStoredKey async => false;
}

/// 推進假時鐘，順便把進場動畫與它們的 delay 跑完。
Future<void> grind(
  WidgetTester tester, {
  int rounds = 16,
  Duration step = const Duration(milliseconds: 80),
}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(step);
  }
}

/// Argon2id 會開 isolate，isolate 的訊息在 widget test 的假時鐘下送不進來，
/// 所以把點擊連同等待一起放進 runAsync，整段跑在真正的事件迴圈上。
///
/// runAsync 不允許有待處理的 timer，所以進去之前先 grind 把動畫的 delay 沖掉。
Future<void> tapAndWait(
  WidgetTester tester,
  Finder target,
  bool Function() done, {
  int maxRounds = 600,
}) async {
  await grind(tester);
  await tester.runAsync(() async {
    await tester.tap(target);
    for (var i = 0; i < maxRounds && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });
  await grind(tester);
}

void main() {
  late Directory tmp;
  AppState? active;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('securemanage_ui_');
  });

  tearDown(() {
    active?.lock();
    active = null;
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Widget harness(AppState state) => MaterialApp(
        theme: AppTheme.light(),
        home: ListenableBuilder(
          listenable: state,
          builder: (context, _) => switch (state.phase) {
            VaultPhase.loading => const SizedBox.shrink(),
            VaultPhase.needsSetup || VaultPhase.locked =>
              LockScreen(key: const ValueKey('lock'), state: state),
            VaultPhase.unlocked =>
              HomeScreen(key: const ValueKey('home'), state: state),
          },
        ),
      );

  Future<AppState> boot(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 860);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state =
        AppState(store: VaultStore(tmp, kdfFactory: KdfParams.weakForTests), biometrics: _NoBiometrics());
    active = state;
    await state.boot();
    await tester.pumpWidget(harness(state));
    await grind(tester);
    return state;
  }

  /// 在 widget 還沒掛上去之前做前置資料，這時沒有任何 timer，可以安心用 runAsync。
  Future<void> seedVault(
      WidgetTester tester, Future<void> Function(VaultStore) build) async {
    await tester.runAsync(() async {
      final seed = VaultStore(tmp, kdfFactory: KdfParams.weakForTests);
      await seed.create(masterPassword);
      await build(seed);
      seed.lock();
    });
  }

  testWidgets('整輪流程：建立 → 新增 → 上鎖 → 用錯密碼 → 用對密碼 → 讀回',
      (tester) async {
    final state = await boot(tester);

    // --- 建立保險庫 -------------------------------------------------
    expect(state.phase, VaultPhase.needsSetup);
    expect(find.text('建立保險庫'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), masterPassword);
    await tester.enterText(find.byType(TextField).at(1), masterPassword);
    await tapAndWait(
      tester,
      find.widgetWithText(FilledButton, '建立'),
      () => state.phase == VaultPhase.unlocked,
    );

    expect(state.phase, VaultPhase.unlocked);
    expect(find.text('保險庫還是空的'), findsOneWidget);

    // --- 新增一台主機 -----------------------------------------------
    await tester.tap(find.widgetWithText(OutlinedButton, '新增'));
    await grind(tester);
    await tester.tap(find.widgetWithText(MenuItemButton, '主機 / VM'));
    await grind(tester);

    expect(find.text('新增主機 / VM'), findsOneWidget);

    // 主畫面的搜尋框還在樹上，欄位要限定在對話框裡找。
    final fields = find.descendant(
        of: find.byType(Dialog), matching: find.byType(TextField));
    await tester.enterText(fields.at(0), 'testbox'); // 名稱
    await tester.enterText(fields.at(1), '198.51.100.7'); // hostname
    await tester.enterText(fields.at(2), '2222'); // port
    await tester.enterText(fields.at(3), 'tester'); // 登入帳號
    await tapAndWait(
      tester,
      find.widgetWithText(FilledButton, '儲存'),
      () => state.items.isNotEmpty,
    );

    expect(state.items.length, 1);
    final host = state.items.first as HostItem;
    final hostId = host.id;
    expect(host.name, 'testbox');
    expect(host.hostname, '198.51.100.7');
    expect(host.port, 2222);
    expect(host.username, 'tester');
    expect(find.text('testbox'), findsWidgets);

    // --- 上鎖 --------------------------------------------------------
    state.lock();
    await grind(tester);
    expect(state.phase, VaultPhase.locked);
    expect(find.text('解鎖保險庫'), findsOneWidget);
    expect(find.text('testbox'), findsNothing,
        reason: '上鎖之後畫面上不該還看得到任何項目');

    // --- 用錯的主密碼 -------------------------------------------------
    await tester.enterText(find.byType(TextField).first, 'definitely-wrong');
    await tapAndWait(
      tester,
      find.widgetWithText(FilledButton, '解鎖'),
      () => state.unlockError != null,
    );
    expect(state.phase, VaultPhase.locked);
    expect(state.unlockError, isNotNull);

    // --- 用對的主密碼 -------------------------------------------------
    await tester.enterText(find.byType(TextField).first, masterPassword);
    await tapAndWait(
      tester,
      find.widgetWithText(FilledButton, '解鎖'),
      () => state.phase == VaultPhase.unlocked,
    );

    expect(state.phase, VaultPhase.unlocked);
    expect(state.items.length, 1);
    final reread = state.store.byId(hostId) as HostItem;
    expect(reread.name, 'testbox');
    expect(reread.hostname, '198.51.100.7');
    expect(reread.port, 2222);
    expect(find.text('testbox'), findsWidgets);
  });

  testWidgets('全新的 AppState 接手既有保險庫，解得開也讀得回', (tester) async {
    final account = AccountItem(
      name: '假的 wiki',
      url: 'wiki.example.test',
      username: 'tester',
      password: 'fake-account-pw',
    );
    await seedVault(tester, (seed) => seed.put(account));

    final state = await boot(tester);

    expect(state.phase, VaultPhase.locked,
        reason: '已經有保險庫就該停在上鎖畫面，不是設定畫面');
    expect(find.text('假的 wiki'), findsNothing);

    await tester.enterText(find.byType(TextField).first, masterPassword);
    await tapAndWait(
      tester,
      find.widgetWithText(FilledButton, '解鎖'),
      () => state.phase == VaultPhase.unlocked,
    );

    expect(state.phase, VaultPhase.unlocked);
    expect(find.text('假的 wiki'), findsOneWidget);
    expect((state.store.byId(account.id) as AccountItem).password,
        'fake-account-pw');

    // 密碼本身不該出現在列表層的任何文字上。
    expect(find.text('fake-account-pw'), findsNothing);
  });

  testWidgets('主密碼欄位可以按眼睛切換顯示', (tester) async {
    final state = await boot(tester);
    expect(state.phase, VaultPhase.needsSetup);

    TextField firstField() =>
        tester.widget<TextField>(find.byType(TextField).first);

    expect(firstField().obscureText, isTrue, reason: '預設要遮起來');

    await tester.enterText(find.byType(TextField).first, 'something');
    await grind(tester);

    await tester.tap(find.byTooltip('顯示').first);
    await grind(tester);
    expect(firstField().obscureText, isFalse);

    await tester.tap(find.byTooltip('隱藏').first);
    await grind(tester);
    expect(firstField().obscureText, isTrue);

    // 切換顯示不該把輸入的內容弄掉。
    expect(firstField().controller?.text, 'something');
  });

  testWidgets('閒置到時間會自動上鎖', (tester) async {
    await seedVault(tester, (seed) async {
      await seed.put(AccountItem(name: '假帳號', password: 'fake-pw'));
      // 把自動上鎖調成 1 秒，測試才跑得動。
      seed.settings.autoLockSeconds = 1;
      await seed.saveSettings();
    });

    final state = await boot(tester);
    await tester.enterText(find.byType(TextField).first, masterPassword);
    await tapAndWait(
      tester,
      find.widgetWithText(FilledButton, '解鎖'),
      () => state.phase == VaultPhase.unlocked,
    );
    expect(state.phase, VaultPhase.unlocked);
    expect(find.text('假帳號'), findsOneWidget);

    // 自動上鎖判斷的是真實經過時間（機器睡著也要算），所以要真的等過去，
    // 再推進假時鐘讓週期 timer 開火。等待時間刻意拉得比門檻寬很多：那個週期
    // timer 落在真實還是假的時鐘，取決於解鎖是在 runAsync 窗口內還是外完成，
    // 兩種情形都要能過。
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 3000)));
    await grind(tester, rounds: 16, step: const Duration(milliseconds: 500));

    expect(state.phase, VaultPhase.locked);
    expect(find.text('假帳號'), findsNothing);
  });
}
