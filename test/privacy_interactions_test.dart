import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/resource_locks.dart';
import 'package:oplayer/core/secure_store.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/settings/pattern_pad.dart';
import 'package:oplayer/features/settings/privacy_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final locks = ResourceLocks.instance;
  bool manual = false, forced = false, authenticated = false;
  setUp(() async {
    manual = forced = authenticated = false;
    messenger.setMockMethodCallHandler(privacyChannel, (call) async {
      switch (call.method) {
        case 'setCaptureProtection':
          manual = call.arguments as bool;
        case 'setLockPolicy':
          final policy = call.arguments as Map;
          forced = policy['appLock'] == true || policy['shielded'] == true;
          manual = policy['preventCapture'] == true;
        case 'biometricAvailable':
          return true;
        case 'authenticate':
          return authenticated;
      }
      return null;
    });
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await AppSettings.instance.init();
    AppSettings.instance.preventCapture = false;
    locks.background(false);
    await locks.init();
    locks.onAuthenticate = (_) => locks.verifyPin('123456');
  });
  tearDown(() async {
    locks.onAuthenticate = null;
    locks.background(false);
    FlutterSecureStorage.setMockInitialValues({});
    await locks.init();
    messenger.setMockMethodCallHandler(privacyChannel, null);
  });

  test('pattern fills skipped intermediate dots and rejects repeats', () {
    expect(extendPattern([0], 2), [0, 1, 2]);
    expect(extendPattern([0], 8), [0, 4, 8]);
    expect(extendPattern([1, 0], 2), [1, 0, 2]);
    expect(extendPattern([0, 1], 0), [0, 1]);
    expect(ResourceLocks.validPattern([0, 1, 1, 2]), false);
    expect(ResourceLocks.validPattern([0, 1, 2]), false);
  });

  testWidgets('biometrics precede PIN and pattern, including fresh settings authentication', (tester) async {
    await tester.runAsync(() async {
      await locks.setPin('123456');
      await locks.setPattern([0, 1, 2, 5]);
      await locks.setBiometric(true);
    });
    for (final forceCredential in [false, true]) {
      final pending = Completer<bool>();
      var prompts = 0;
      messenger.setMockMethodCallHandler(privacyChannel, (call) async {
        if (call.method == 'authenticate') {
          prompts++;
          return pending.future;
        }
        return null;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ResourceUnlockPanel(
              key: ValueKey(forceCredential),
              forceCredential: forceCredential,
              onUnlocked: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(prompts, 1);
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(PatternPad), findsNothing);
      pending.complete(false);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      await tester.tap(find.text('패턴으로 해제'));
      await tester.pumpAndSettle();
      expect(find.byType(PatternPad), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('background lock defers biometrics until resume and keeps credentials hidden', (tester) async {
    await tester.runAsync(() async {
      await locks.setPin('123456');
      await locks.setBiometric(true);
      await locks.setAppLockEnabled(true);
    });
    final pending = Completer<bool>();
    var prompts = 0;
    messenger.setMockMethodCallHandler(privacyChannel, (call) async {
      if (call.method == 'authenticate') {
        prompts++;
        return pending.future;
      }
      return null;
    });
    await tester.pumpWidget(
      const MaterialApp(
        home: PrivacyShell(child: Scaffold(body: Text('private app'))),
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump();
    expect(prompts, 0);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(PatternPad), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(prompts, 1);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('private app').hitTestable(), findsNothing);
    pending.complete(true);
    await tester.pumpAndSettle();
    expect(locks.shielded, false);
    expect(find.text('private app').hitTestable(), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('drawing a pattern submits its actual ordered dots', (tester) async {
    List<int>? submitted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox.square(dimension: 270, child: PatternPad(onCompleted: (value) => submitted = value)),
          ),
        ),
      ),
    );
    final origin = tester.getTopLeft(find.byType(PatternPad));
    Offset dot(int index) => origin + Offset((index % 3 + .5) * 90, (index ~/ 3 + .5) * 90);
    final gesture = await tester.startGesture(dot(0));
    await gesture.moveTo(dot(2));
    await tester.pump();
    await gesture.moveTo(dot(8));
    await tester.pump();
    await gesture.moveTo(dot(6));
    await gesture.up();
    await tester.pump();
    expect(submitted, [0, 1, 2, 5, 8, 7, 6]);
  });

  test('one pattern credential protects app and resources, persists and supports biometric unlock', () async {
    final pattern = [0, 1, 2, 5, 8];
    await locks.setPattern(pattern);
    expect(locks.configured, true);
    expect(locks.hasPin, false);
    locks.onAuthenticate = (_) => locks.verifyPattern(pattern);
    await locks.setAppLockEnabled(true);
    await locks.toggle('webdav://shared/private', 'private');
    await locks.setBiometric(true);
    final raw = await SecureStore.instance.readRequired(ResourceLocks.storageKey);
    expect(raw, isNot(contains('pattern:0,1,2,5,8')));
    expect((jsonDecode(raw!) as Map)['hash'], isNull);
    final restarted = ResourceLocks();
    await restarted.init();
    expect(restarted.hasPattern, true);
    expect(restarted.hasPin, false);
    expect(restarted.appLockEnabled, true);
    expect(restarted.isLocked('webdav://shared/private/movie.mp4'), true);
    expect(await restarted.verifyPattern(pattern), true);
    expect(restarted.shielded, false);
    expect(restarted.isLocked('webdav://shared/private/movie.mp4'), true);
    restarted.onAuthenticate = (_) => restarted.verifyPattern(pattern);
    await restarted.requireAccess('webdav://shared/private/movie.mp4');
    expect(restarted.isLocked('webdav://shared/private/movie.mp4'), false);
    restarted.relock();
    authenticated = true;
    restarted.onAuthenticate = (_) => restarted.biometric();
    await restarted.requireAccess('webdav://shared/private/movie.mp4');
    expect(restarted.isLocked('webdav://shared/private/movie.mp4'), false);
    restarted.onAuthenticate = (_) => restarted.verifyPattern(pattern);
    await restarted.setAppLockEnabled(false);
    restarted.relock();
    expect(restarted.isLocked('webdav://shared/private/movie.mp4'), true);
    expect(restarted.isLocked('webdav://shared/public/movie.mp4'), false);
    restarted.onAuthenticate = (_) => restarted.biometric();
    await restarted.requireAccess('webdav://shared/private/movie.mp4');
    expect(restarted.isLocked('webdav://shared/private/movie.mp4'), false);
    await restarted.setPin('654321');
    expect(restarted.hasPattern, true);
    expect(restarted.hasPin, true);
    expect(restarted.hasExact('webdav://shared/private'), true);
    expect(restarted.biometricEnabled, true);
    final pinRestart = ResourceLocks();
    await pinRestart.init();
    expect(await pinRestart.verifyPin('654321'), true);
    expect(pinRestart.hasPattern, true);
    pinRestart.onAuthenticate = (_) => pinRestart.verifyPin('654321');
    await pinRestart.setPattern(pattern);
    expect(pinRestart.hasPin, true);
    expect(pinRestart.hasPattern, true);
    expect(pinRestart.hasExact('webdav://shared/private'), true);
    expect(pinRestart.biometricEnabled, true);
  });

  test('removing PIN preserves shared pattern, biometrics and locked resources across restart', () async {
    final pattern = [0, 1, 2, 5];
    await locks.setPin('123456');
    await locks.setPattern(pattern);
    await locks.setAppLockEnabled(true);
    await locks.toggle('webdav://private', 'private');
    await locks.setBiometric(true);
    await locks.removePin();
    final restarted = ResourceLocks();
    await restarted.init();
    expect(restarted.hasPin, false);
    expect(restarted.hasPattern, true);
    expect(restarted.appLockEnabled, true);
    expect(restarted.hasExact('webdav://private'), true);
    expect(restarted.biometricEnabled, true);
    expect(await restarted.verifyPin('123456'), false);
    expect(await restarted.verifyPattern(pattern), true);
    restarted.onAuthenticate = (_) => restarted.verifyPattern(pattern);
    await expectLater(restarted.setPattern(null), throwsFormatException);
    await restarted.setAppLockEnabled(false);
    await restarted.toggle('webdav://private', 'private');
    await restarted.setPattern(null);
    expect(restarted.configured, false);
    final empty = ResourceLocks();
    await empty.init();
    expect(empty.configured, false);
    expect(empty.unavailable, false);
    expect(empty.biometricEnabled, false);
  });

  test('pattern-only credential cannot be removed and incorrect attempts remain limited after restart', () async {
    await locks.setPattern([0, 1, 2, 5]);
    locks.onAuthenticate = (_) => locks.verifyPattern([0, 1, 2, 5]);
    await locks.toggle('webdav://protected', 'protected');
    await expectLater(locks.setPattern(null), throwsFormatException);
    for (var i = 0; i < 5; i++) {
      expect(await locks.verifyPattern([0, 1, 2, 4]), false);
    }
    final restarted = ResourceLocks();
    await restarted.init();
    expect(restarted.retrySeconds, greaterThan(0));
    expect(await restarted.verifyPattern([0, 1, 2, 5]), false);
  });

  testWidgets('pattern-only unlock panel uses pattern for app, resources and credential confirmation', (tester) async {
    await tester.runAsync(() => locks.setPattern([0, 1, 2, 5]));
    for (final forceCredential in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ResourceUnlockPanel(
              key: ValueKey(forceCredential),
              forceCredential: forceCredential,
              onUnlocked: () {},
            ),
          ),
        ),
      );
      expect(find.byType(PatternPad), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('PIN and pattern verification show progress while native hashing is pending', (tester) async {
    for (final pattern in [false, true]) {
      messenger.setMockMethodCallHandler(privacyChannel, (_) async => null);
      await tester.runAsync(() async {
        FlutterSecureStorage.setMockInitialValues({});
        await locks.init();
        if (pattern) {
          await locks.setPattern([0, 1, 2, 5]);
        } else {
          await locks.setPin('123456');
        }
      });
      final pending = Completer<List<int>>();
      messenger.setMockMethodCallHandler(privacyChannel, (_) async => pending.future);
      var opened = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ResourceUnlockPanel(
                key: ValueKey(pattern),
                forceCredential: true,
                onUnlocked: () => opened = true,
              ),
            ),
          ),
        ),
      );
      if (pattern) {
        final pad = find.descendant(of: find.byType(PatternPad), matching: find.byType(GestureDetector));
        final origin = tester.getTopLeft(pad);
        final side = tester.getSize(pad).width;
        Offset dot(int i) => origin + Offset((i % 3 + .5) * side / 3, (i ~/ 3 + .5) * side / 3);
        final gesture = await tester.startGesture(dot(0));
        await gesture.moveTo(dot(2));
        await tester.pump();
        await gesture.moveTo(dot(5));
        await gesture.up();
      } else {
        await tester.enterText(find.byType(TextField), '123456');
        await tester.tap(find.widgetWithText(FilledButton, '잠금 해제'));
      }
      await tester.pump();
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget, reason: 'pattern=$pattern');
      expect(find.text('잠금 정보 확인 중…'), findsOneWidget);
      expect(opened, false);
      pending.complete(List<int>.filled(32, 0));
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(opened, false);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('capture settings refresh when the settings notifier changes', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: PrivacySettings())),
      ),
    );
    final toggle = find.widgetWithText(SwitchListTile, '캡처·화면 녹화 방지 (수동 설정)');
    for (final enabled in [true, false, true, false]) {
      AppSettings.instance.update((settings) => settings.preventCapture = enabled);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).value, enabled);
      expect(find.text(enabled ? '현재 캡처 차단 중' : '현재 캡처 허용'), findsOneWidget);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('manual capture switch changes both ways while app lock keeps protection forced', (tester) async {
    await tester.runAsync(() async {
      await locks.setPin('123456');
      await locks.setAppLockEnabled(true);
    });
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: PrivacySettings())),
      ),
    );
    final toggle = find.widgetWithText(SwitchListTile, '캡처·화면 녹화 방지 (수동 설정)');
    expect(tester.widget<SwitchListTile>(toggle).value, false);
    expect(tester.widget<SwitchListTile>(toggle).onChanged, isNotNull);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, true);
    expect(manual, true);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, false);
    expect(manual, false);
    expect(forced, true);
    await tester.runAsync(() => locks.setAppLockEnabled(false));
    await tester.pumpAndSettle();
    expect(manual || forced, false);
    expect(find.text('현재 캡처 허용'), findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(manual || forced, true);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(manual || forced, false);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('system authentication cancellation preserves lock and a verified retry unlocks', (tester) async {
    await tester.runAsync(() async {
      await locks.setPin('123456');
      await locks.setAppLockEnabled(true);
      await locks.setBiometric(true);
      locks.relock();
    });
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: ResourceUnlockPanel(onUnlocked: () => opened = true)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(opened, false);
    expect(locks.shielded, true);
    authenticated = true;
    final systemButton = find.widgetWithText(TextButton, 'Windows Hello로 인증');
    await tester.tap(systemButton);
    await tester.pumpAndSettle();
    expect(opened, true);
    expect(locks.shielded, false);
    expect(locks.forcesCaptureProtection, true);
    await tester.pumpWidget(const SizedBox());
  });
}
