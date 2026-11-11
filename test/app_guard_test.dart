import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:securemanage/app/app_state.dart';
import 'package:securemanage/app/instance_lock.dart';
import 'package:securemanage/main.dart';
import 'package:securemanage/services/biometric_gate.dart';
import 'package:securemanage/vault/vault_crypto.dart';
import 'package:securemanage/vault/vault_store.dart';

/// 開機時的兩道防線接到畫面上：
///   - 拿不到單一執行個體鎖就停在「已經在執行」畫面，完全不碰保險庫。
///   - 資料夾權限收不緊時，設定頁要看得到警告，而不是默默當作沒事。
const masterPassword = 'fake-master-pw-for-guard-tests';

class _NoBiometrics extends BiometricGate {
  _NoBiometrics() : super(platformSupported: false);
}

Future<void> grind(WidgetTester tester, {int rounds = 16}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

void main() {
  late Directory support;
  late Directory vault;

  setUp(() {
    support = Directory.systemTemp.createTempSync('nook_guard_');
    vault = Directory('${support.path}${Platform.pathSeparator}vault');
  });

  tearDown(() {
    if (support.existsSync()) support.deleteSync(recursive: true);
  });

  Future<void> seedVault(WidgetTester tester) async {
    await tester.runAsync(() async {
      final seed = VaultStore(
        vault,
        kdfFactory: KdfParams.weakForTests,
        ownerOnlyPermissions: false,
      );
      await seed.create(masterPassword);
      seed.lock();
    });
  }

  testWidgets('別的程序握著鎖：停在「已經在執行」，不讀也不寫保險庫', (tester) async {
    await seedVault(tester);
    final manifest = File('${vault.path}/vault.json');
    final before = manifest.readAsBytesSync();
    final beforeModified = manifest.lastModifiedSync();

    final state = AppState(
      store: VaultStore(
        vault,
        kdfFactory: KdfParams.weakForTests,
        ownerOnlyPermissions: false,
      ),
      biometrics: _NoBiometrics(),
      acquireInstanceLock: (_) => null,
    );
    await tester.pumpWidget(NookApp(state: state));
    await grind(tester);

    expect(state.phase, VaultPhase.blocked);
    expect(find.textContaining('Nook 已經在執行中'), findsOneWidget);
    expect(find.byType(TextField), findsNothing, reason: '不能讓人在這裡輸入主密碼');
    // 任何地方誤呼叫上鎖，都不能把畫面切到可輸入主密碼的上鎖畫面。
    state.lock();
    await grind(tester);
    expect(state.phase, VaultPhase.blocked);
    expect(manifest.readAsBytesSync(), before);
    expect(manifest.lastModifiedSync(), beforeModified);
  });

  testWidgets('鎖檔開不了也一樣不開啟，並說出原因', (tester) async {
    await seedVault(tester);
    final state = AppState(
      store: VaultStore(vault, ownerOnlyPermissions: false),
      biometrics: _NoBiometrics(),
      acquireInstanceLock: (dir) => throw FileSystemException(
        'Cannot open file',
        '${dir.path}/nook.lock',
        const OSError('Permission denied', 13),
      ),
    );
    await tester.pumpWidget(NookApp(state: state));
    await grind(tester);

    expect(state.phase, VaultPhase.blocked);
    expect(find.textContaining('無法建立單一執行個體鎖'), findsOneWidget);
    expect(find.textContaining('Permission denied'), findsOneWidget);
  });

  testWidgets('拿到鎖就正常進上鎖畫面，鎖放在保險庫資料夾外面', (tester) async {
    await seedVault(tester);
    final lockFile = File('${support.path}${Platform.pathSeparator}nook.lock');
    InstanceLock? held;
    final state = AppState(
      store: VaultStore(vault, ownerOnlyPermissions: false),
      biometrics: _NoBiometrics(),
      acquireInstanceLock: (dir) {
        expect(dir.path, support.path, reason: '鎖檔要在 vault/ 外面，不然備份複製會撞到');
        return held = InstanceLock.tryAcquire(lockFile);
      },
    );
    await tester.pumpWidget(NookApp(state: state));
    await grind(tester);

    expect(state.phase, VaultPhase.locked);
    expect(state.instanceLock, same(held));
    expect(held!.isHeld, isTrue);
    expect(
      vault.listSync().map((e) => e.path),
      isNot(contains(endsWith('nook.lock'))),
    );
    held!.release();
  });

  testWidgets('權限收不緊時，設定頁看得到警告', (tester) async {
    tester.view.physicalSize = const Size(1280, 860);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await seedVault(tester);

    final state = AppState(
      store: VaultStore(
        vault,
        kdfFactory: KdfParams.weakForTests,
        ownerOnlyPermissions: true,
        chmodExecutable: '/usr/bin/false',
      ),
      biometrics: _NoBiometrics(),
    );
    await tester.pumpWidget(NookApp(state: state));
    await grind(tester);
    expect(state.permissionWarning, contains('0700'));

    await tester.enterText(find.byType(TextField).first, masterPassword);
    await grind(tester);
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '解除鎖定'));
      for (var i = 0; i < 600 && state.phase != VaultPhase.unlocked; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await grind(tester);
    expect(state.phase, VaultPhase.unlocked, reason: '權限是額外一層，失敗不擋解鎖');

    await tester.tap(find.text('設定').first);
    await grind(tester);
    expect(find.byKey(const ValueKey('permission-warning')), findsOneWidget);
    expect(find.textContaining('沒能收成只限本人存取'), findsOneWidget);

    state.lock();
    await grind(tester);
  }, skip: Platform.isWindows);
}
