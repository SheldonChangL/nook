import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:securemanage/app/app_state.dart';
import 'package:securemanage/app/platform_profile.dart';
import 'package:securemanage/main.dart';
import 'package:securemanage/services/biometric_gate.dart';
import 'package:securemanage/ui/theme.dart';
import 'package:securemanage/vault/vault_crypto.dart';
import 'package:securemanage/vault/vault_store.dart';

/// Windows／Linux 版的分流：快捷鍵改用 Ctrl、快速解鎖整個不出現也不碰原生通道、
/// 設定頁不講 macOS 專屬的事。
///
/// 這裡用 debugDefaultTargetPlatformOverride 模擬平台，驗的是 Dart 端的分流邏輯；
/// 它不能取代在 Windows／Linux 實機上的驗收（原生 runner、視窗、檔案路徑）。
const masterPassword = 'fake-master-pw-for-tests-2026!';

/// 任何呼叫都記下來。快速解鎖在不支援的平台上不該碰到 local_auth 或安全儲存。
class _SpyAuth implements LocalAuthentication {
  int calls = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    // 同步丟出：回傳型別不對的 Future 會變成沒人接的錯誤。
    throw StateError('不該呼叫 local_auth');
  }
}

class _SpyStorage implements FlutterSecureStorage {
  int calls = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    throw StateError('不該呼叫安全儲存');
  }
}

class _NoBiometrics extends BiometricGate {
  _NoBiometrics() : super(platformSupported: false);
}

/// 假裝這台 Mac 有 Touch ID，好讓設定頁把開關畫出來（不會真的去註冊）。
class _FakeTouchId extends BiometricGate {
  _FakeTouchId() : super(platformSupported: true);
  @override
  Future<bool> get isAvailable async => true;
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

final _otherDesktops = TargetPlatformVariant(<TargetPlatform>{
  TargetPlatform.windows,
  TargetPlatform.linux,
});

void main() {
  group('PlatformProfile', () {
    test('macOS 用 ⌘，Windows／Linux 用 Ctrl', () {
      final mac = PlatformProfile.of(TargetPlatform.macOS);
      expect(mac.shortcut(LogicalKeyboardKey.keyK).meta, isTrue);
      expect(mac.shortcut(LogicalKeyboardKey.keyK).control, isFalse);
      expect(mac.shortcutLabel('K'), '⌘K');

      for (final p in [TargetPlatform.windows, TargetPlatform.linux]) {
        final profile = PlatformProfile.of(p);
        expect(profile.shortcut(LogicalKeyboardKey.keyK).control, isTrue);
        expect(profile.shortcut(LogicalKeyboardKey.keyK).meta, isFalse);
        expect(profile.shortcutLabel('K'), 'Ctrl+K');
      }
    });

    test('快速解鎖與原生視窗通道只在 macOS 開啟', () {
      for (final p in TargetPlatform.values) {
        final profile = PlatformProfile.of(p);
        final isMac = p == TargetPlatform.macOS;
        expect(profile.supportsQuickUnlock, isMac, reason: '$p');
        expect(profile.hasWindowChannel, isMac, reason: '$p');
      }
    });

    test('Windows／Linux 的說明文字不提 macOS 專屬的操作', () {
      for (final p in [TargetPlatform.windows, TargetPlatform.linux]) {
        final hint = PlatformProfile.of(p).appSwitchHint;
        expect(
          PlatformProfile.of(p).appSwitchTitle,
          isNot(contains('切換到其他 app')),
        );
        expect(hint, isNot(contains('⌘')));
        expect(hint, isNot(contains('macOS')));
      }
    });
  });

  group('Linux 中文字型備援', () {
    // Linux 上不指名的話，Flutter 找不到 CJK 字型，介面中文全是方塊（.deb 實測）。
    const noto = 'Noto Sans CJK TC';

    test('只有 Linux 指名 Noto Sans CJK，macOS／Windows 交給系統備援', () {
      for (final p in TargetPlatform.values) {
        final fallback = PlatformProfile.of(p).cjkFontFallback;
        expect(
          fallback.contains(noto),
          p == TargetPlatform.linux,
          reason: '$p',
        );
      }
    });

    for (final p in [
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    ]) {
      test('$p：主題與等寬字都套用同一份中文備援', () {
        debugDefaultTargetPlatformOverride = p;
        try {
          final expected = PlatformProfile.of(p).cjkFontFallback;
          for (final theme in [
            AppTheme.light(),
            AppTheme.dark(),
            AppTheme.nook(true),
            AppTheme.nook(false),
          ]) {
            expect(
              theme.textTheme.bodyMedium!.fontFamilyFallback ?? const [],
              expected,
            );
            expect(
              theme.textTheme.titleLarge!.fontFamilyFallback ?? const [],
              expected,
            );
          }
          // 等寬欄位自帶 fallback，中文要接在拉丁等寬字後面。
          final mono = monoStyle().fontFamilyFallback!;
          expect(mono.first, 'SF Mono');
          expect(mono.sublist(mono.length - expected.length), expected);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  });

  group('BiometricGate 在不支援的平台', () {
    test('一律回「沒有」，而且完全不碰 local_auth 與安全儲存', () async {
      final auth = _SpyAuth();
      final storage = _SpyStorage();
      final gate = BiometricGate(
        auth: auth,
        storage: storage,
        platformSupported: false,
      );

      expect(await gate.isAvailable, isFalse);
      expect(await gate.hasStoredKey, isFalse);
      expect(await gate.unlock(), isNull);
      expect(await gate.enroll(List<int>.filled(32, 7)), isNotNull);
      await gate.forget();

      expect(auth.calls, 0);
      expect(storage.calls, 0);
    });

    test('沒指定時跟著目前平台走：Windows／Linux 關閉、macOS 開啟', () async {
      for (final p in TargetPlatform.values) {
        debugDefaultTargetPlatformOverride = p;
        try {
          final auth = _SpyAuth();
          final gate = BiometricGate(auth: auth, storage: _SpyStorage());
          await gate.isAvailable;
          // macOS 會真的去問 local_auth（這裡的假物件會丟錯，當成沒有）；
          // 其他平台連問都不問。
          expect(auth.calls > 0, p == TargetPlatform.macOS, reason: '$p');
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
    });
  });

  group('掛真正的 NookApp', () {
    late Directory tmp;
    AppState? active;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('securemanage_platform_');
    });

    tearDown(() {
      active?.lock();
      active = null;
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    Future<AppState> bootUnlocked(
      WidgetTester tester, {
      BiometricGate? biometrics,
    }) async {
      tester.view.physicalSize = const Size(1280, 860);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.runAsync(() async {
        final seed = VaultStore(tmp, kdfFactory: KdfParams.weakForTests);
        await seed.create(masterPassword);
        seed.lock();
      });

      final state = AppState(
        store: VaultStore(tmp, kdfFactory: KdfParams.weakForTests),
        biometrics: biometrics ?? _NoBiometrics(),
      );
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

    Future<void> press(
      WidgetTester tester,
      LogicalKeyboardKey modifier,
      LogicalKeyboardKey key,
    ) async {
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(modifier);
      await grind(tester);
    }

    testWidgets('Windows／Linux：Ctrl+L 上鎖，⌘L 不做事', (tester) async {
      final state = await bootUnlocked(tester);

      await press(tester, LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.keyL);
      expect(state.phase, VaultPhase.unlocked);

      await press(
        tester,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.keyL,
      );
      expect(state.phase, VaultPhase.locked);
    }, variant: _otherDesktops);

    testWidgets('macOS：⌘L 照舊上鎖', (tester) async {
      final state = await bootUnlocked(tester);
      await press(tester, LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.keyL);
      expect(state.phase, VaultPhase.locked);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('Windows／Linux：Ctrl+K 叫出搜尋，提示寫的是 Ctrl', (tester) async {
      await bootUnlocked(tester);
      await press(
        tester,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.keyK,
      );
      expect(find.textContaining('Ctrl+⏎ 開啟'), findsOneWidget);
      expect(find.textContaining('⌘'), findsNothing);
    }, variant: _otherDesktops);

    testWidgets('Windows／Linux：設定頁沒有 Touch ID，也不提 macOS', (tester) async {
      await bootUnlocked(tester);
      await tester.tap(find.text('設定').first);
      await grind(tester);

      // 程式只在 hidden／paused 上鎖，Windows／Linux 焦點離開只會是 inactive，
      // 所以標題不能寫「切換到其他 app」。
      expect(find.text('視窗最小化或隱藏時立刻上鎖'), findsOneWidget);
      expect(find.textContaining('切換到其他 app'), findsNothing);
      expect(find.textContaining('Touch ID'), findsNothing);
      expect(find.textContaining('Keychain'), findsNothing);
      expect(find.textContaining('macOS'), findsNothing);
    }, variant: _otherDesktops);

    testWidgets('Windows／Linux：開了這個設定，只失去焦點不鎖、最小化／隱藏才鎖', (tester) async {
      final state = await bootUnlocked(tester);
      await tester.runAsync(() => state.setLockOnAppSwitch(true));
      await grind(tester, rounds: 4);

      // 焦點移到別的視窗：Flutter 回報 inactive。設定標題沒說這會鎖，程式也不能鎖。
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await grind(tester, rounds: 4);
      expect(state.phase, VaultPhase.unlocked);

      // 最小化／隱藏：hidden，照標題所說立刻上鎖。
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await grind(tester, rounds: 4);
      expect(state.phase, VaultPhase.locked);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await grind(tester, rounds: 4);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await grind(tester, rounds: 4);
    }, variant: _otherDesktops);

    testWidgets(
      'Linux：主畫面、設定、指令面板、新增選單、編輯器與鎖定畫面的每段中文都帶到 Noto 備援',
      (tester) async {
        // 防止有人在某個元件用自己的 TextStyle 蓋掉主題（例如 ButtonStyle.textStyle），
        // 那段中文在 Linux 上就會變方塊。
        final cjk = RegExp(r'[\u4e00-\u9fff]');
        List<String> missing() => [
          for (final rt in tester.widgetList<RichText>(find.byType(RichText)))
            if (cjk.hasMatch(rt.text.toPlainText()) &&
                !(rt.text.style?.fontFamilyFallback ?? const []).contains(
                  'Noto Sans CJK TC',
                ))
              rt.text.toPlainText(),
        ];

        final state = await bootUnlocked(tester);
        expect(missing(), isEmpty, reason: '主畫面');

        await tester.tap(find.text('設定').first);
        await grind(tester);
        expect(find.text('視窗最小化或隱藏時立刻上鎖'), findsOneWidget);
        expect(missing(), isEmpty, reason: '設定對話框');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await grind(tester);

        await press(
          tester,
          LogicalKeyboardKey.controlLeft,
          LogicalKeyboardKey.keyK,
        );
        expect(find.textContaining('Ctrl+⏎'), findsWidgets);
        expect(missing(), isEmpty, reason: '指令面板');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await grind(tester);

        await tester.tap(find.widgetWithText(FilledButton, '新增'));
        await grind(tester);
        expect(missing(), isEmpty, reason: '新增選單');
        await tester.tap(find.widgetWithText(MenuItemButton, '主機 / VM'));
        await grind(tester);
        expect(find.byType(Dialog), findsOneWidget);
        expect(missing(), isEmpty, reason: '項目編輯器');

        state.lock();
        await grind(tester);
        expect(find.widgetWithText(FilledButton, '解除鎖定'), findsOneWidget);
        expect(missing(), isEmpty, reason: '鎖定畫面（含主按鈕）');
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );

    testWidgets(
      'macOS：設定頁仍有 Touch ID 開關',
      (tester) async {
        await bootUnlocked(tester, biometrics: _FakeTouchId());
        await tester.tap(find.text('設定').first);
        await grind(tester);

        expect(find.text('用 Touch ID 解鎖'), findsOneWidget);
        expect(find.text('切換到其他 app 就立刻上鎖'), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  });
}
