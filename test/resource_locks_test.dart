import 'package:oplayer/features/settings/resource_access_view.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oplayer/core/media_item.dart';
import 'package:oplayer/core/mouse_nav.dart';
import 'package:oplayer/core/resource_locks.dart';
import 'package:oplayer/core/secure_store.dart';
import 'package:oplayer/features/settings/privacy_settings.dart';
import 'package:oplayer/sources/server_store.dart';
import 'package:oplayer/core/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      privacyChannel,
      (call) async => ['biometricAvailable', 'authenticate'].contains(call.method) ? true : null,
    );
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.init();
    AppSettings.instance.preventCapture = false;
    FlutterSecureStorage.setMockInitialValues({});
    ServerStore.instance.servers.clear();
    await ResourceLocks.instance.init();
    dir = await Directory.systemTemp.createTemp('oplayer_lock_');
  });
  tearDown(() async {
    ResourceLocks.instance.onAuthenticate = null;
    ResourceLocks.instance.background(false);
    FlutterSecureStorage.setMockInitialValues({});
    await ResourceLocks.instance.init();
    ServerStore.instance.servers.clear();
    await dir.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(privacyChannel, null);
  });

  test('background relock retains current playback but denies new access and manual relock revokes it', () async {
    final locks = ResourceLocks();
    await locks.init();
    await locks.setPin('123456');
    locks.onAuthenticate = (_) => locks.verifyPin('123456');
    await locks.setAppLockEnabled(true);
    await locks.toggle(dir.path, 'private');
    final current = '${dir.path}/current.mp3';
    await locks.requireAccess(current);
    final permit = locks.authorizePlayback([current]);
    expect(permit, isNotNull);
    locks.background(true);
    expect(locks.shielded, true);
    expect(locks.isLocked(current), true);
    expect(locks.canContinuePlayback(permit), true);
    expect(locks.authorizePlayback([current]), isNull);
    expect(locks.canContinuePlayback(null), false);
    await expectLater(locks.requireAccess('${dir.path}/other.mp3'), throwsA(isA<ResourceLockedException>()));
    locks.background(false);
    expect(locks.isLocked(current), true);
    expect(locks.canContinuePlayback(permit), true);
    locks.relock();
    expect(locks.canContinuePlayback(permit), false);
    await locks.requireAccess(current);
    final renewed = locks.authorizePlayback([current]);
    expect(locks.canContinuePlayback(renewed), true);
    await locks.toggle(current, 'nested lock');
    expect(locks.canContinuePlayback(renewed), false);
    expect(locks.authorizePlayback([current]), isNull);
  });

  test('PIN protects descendants, persists without plaintext, and canceled auth denies access', () async {
    final locks = ResourceLocks();
    await locks.init();
    await locks.setPin('123456');
    locks.onAuthenticate = (_) => locks.verifyPin('123456');
    final folder = await Directory('${dir.path}/private').create();
    final file = await File('${folder.path}/a.mp4').writeAsBytes([1]);
    await locks.toggle(folder.path, 'private');
    locks.relock();
    expect(locks.isLocked(file.path), true);
    expect(locks.protects('${dir.path}/private-other/a.mp4'), false);
    expect(locks.protects('${folder.path}/../public/a.mp4'), false);
    locks.onAuthenticate = (_) async => false;
    await expectLater(locks.requireAccess(file.path), throwsA(isA<ResourceLockedException>()));
    final record = await SecureStore.instance.readRequired(ResourceLocks.storageKey);
    expect(record, isNot(contains('123456')));
    final restarted = ResourceLocks();
    await restarted.init();
    expect(restarted.isLocked(file.path), true);
    expect(await restarted.verifyPin('000000'), false);
    expect(await restarted.verifyPin('123456'), true);
    expect(restarted.isLocked(file.path), true);
    restarted.onAuthenticate = (_) => restarted.verifyPin('123456');
    await restarted.requireAccess(file.path);
    expect(restarted.isLocked(file.path), false);
    restarted.background(true);
    expect(restarted.isLocked(file.path), true);
    expect(restarted.shielded, false);
    expect(await restarted.verifyPin('123456'), false);
  });

  test('repeated incorrect PIN attempts are rate limited across app restarts', () async {
    final locks = ResourceLocks();
    await locks.init();
    await locks.setPin('123456');
    for (var i = 0; i < 5; i++) {
      expect(await locks.verifyPin('999999'), false);
    }
    expect(locks.retrySeconds, greaterThan(0));
    final restarted = ResourceLocks();
    await restarted.init();
    expect(await restarted.verifyPin('123456'), false);
  });

  test('app lock persists independently of resources and forces capture protection after unlock', () async {
    final locks = ResourceLocks();
    await locks.init();
    await locks.setPin('123456');
    locks.onAuthenticate = (_) => locks.verifyPin('123456');
    await locks.setAppLockEnabled(true);
    expect(locks.resources, isEmpty);
    expect(locks.appLockEnabled, true);
    expect(locks.forcesCaptureProtection, true);
    final restarted = ResourceLocks();
    await restarted.init();
    expect(restarted.shielded, true);
    expect(restarted.isLocked('${dir.path}/any-file.mp4'), true);
    expect(await restarted.verifyPin('123456'), true);
    expect(restarted.shielded, false);
    expect(restarted.forcesCaptureProtection, true);
    restarted.onAuthenticate = (_) async => false;
    await expectLater(restarted.setAppLockEnabled(false), throwsA(isA<ResourceLockedException>()));
    expect(restarted.appLockEnabled, true);
    restarted.onAuthenticate = (_) => restarted.verifyPin('123456');
    await restarted.setAppLockEnabled(false);
    expect(restarted.forcesCaptureProtection, false);
    final disabled = ResourceLocks();
    await disabled.init();
    expect(disabled.appLockEnabled, false);
    expect(disabled.shielded, false);
  });

  test('same server aliases and direct WebDAV URLs share storage protection', () async {
    final locks = ResourceLocks();
    await locks.init();
    await locks.setPin('123456');
    locks.onAuthenticate = (_) => locks.verifyPin('123456');
    ServerStore.instance.servers.addAll([
      ServerConfig(
        id: 'old-with-a-very-long-id',
        type: ServerType.webdav,
        name: 'NAS',
        host: 'nas.example',
        port: 5006,
        secure: true,
      ),
      ServerConfig(id: 'new', type: ServerType.webdav, name: 'NAS2', host: 'nas.example', port: 5006, secure: true),
    ]);
    await locks.toggle('webdav://old-with-a-very-long-id', 'NAS');
    await locks.toggle('webdav://new/private', 'private');
    locks.relock();
    expect(locks.isLocked('webdav://new/video/a.mp4'), true);
    expect(locks.isLocked('https://nas.example:5006/video/a.mp4?token=x'), true);
    expect(locks.protects('https://unrelated.example/video/a.mp4'), false);
    await locks.requireAccess('webdav://old-with-a-very-long-id/video/a.mp4');
    expect(locks.isLocked('https://nas.example:5006/video/a.mp4'), false);
    expect(locks.isLocked('webdav://old-with-a-very-long-id/private/a.mp4'), true);
    await locks.requireAccess('https://nas.example:5006/private/a.mp4');
    expect(locks.isLocked('webdav://new/private/a.mp4'), false);
  });

  test('backgrounding during PIN confirmation cannot enable or disable app lock', () async {
    final locks = ResourceLocks();
    await locks.init();
    await locks.setPin('123456');
    locks.onAuthenticate = (_) async {
      await locks.verifyPin('123456');
      locks.background(true);
      return true;
    };
    await expectLater(locks.setAppLockEnabled(true), throwsA(isA<ResourceLockedException>()));
    expect(locks.appLockEnabled, false);
  });

  test('unreadable security data fails closed instead of removing locks', () async {
    FlutterSecureStorage.setMockInitialValues({
      ResourceLocks.storageKey: jsonEncode({'salt': 'broken'}),
    });
    final locks = ResourceLocks();
    await locks.init();
    expect(locks.unavailable, true);
    await expectLater(locks.requireAccess('${dir.path}/a.mp4'), throwsA(isA<ResourceLockedException>()));
    await expectLater(locks.setPin('123456'), throwsA(isA<ResourceLockedException>()));
  });

  test('media resolution cannot bypass a locked file using a resolver or file URI', () async {
    final locks = ResourceLocks.instance;
    await locks.setPin('123456');
    locks.onAuthenticate = (_) => locks.verifyPin('123456');
    final file = await File('${dir.path}/a.mp4').writeAsBytes([1]);
    await locks.toggle(file.path, 'a');
    locks.relock();
    locks.onAuthenticate = (_) async => false;
    var resolved = false;
    final item = MediaItem(
      key: 'unrelated',
      uri: Uri.file(file.path).toString(),
      title: 'a',
      resolver: () async {
        resolved = true;
        return MediaItem.local(file.path);
      },
    );
    await expectLater(item.resolve(), throwsA(isA<ResourceLockedException>()));
    expect(resolved, false);
    locks.background(false);
    locks.onAuthenticate = (_) => locks.verifyPin('123456');
    await item.resolve();
    expect(resolved, true);
  });

  test('home stays public and app, sibling and nested resource grants stay independent', () async {
    final locks = ResourceLocks();
    await locks.init();
    await locks.setPin('123456');
    var prompts = 0;
    locks.onAuthenticate = (_) {
      prompts++;
      return locks.verifyPin('123456');
    };
    await locks.toggle('${dir.path}/a', 'a');
    await locks.toggle('${dir.path}/b', 'b');
    await locks.toggle('${dir.path}/a/nested', 'nested');
    await locks.init();
    expect(locks.shielded, false);
    expect(locks.isLocked(dir.path), false);
    prompts = 0;
    await locks.requireAccess('${dir.path}/a/movie.mp4');
    expect(prompts, 1);
    expect(locks.isLocked('${dir.path}/b/movie.mp4'), true);
    expect(locks.isLocked('${dir.path}/a/nested/movie.mp4'), true);
    await locks.requireAccess('${dir.path}/a/other.mp4');
    expect(prompts, 1);
    await locks.requireAccess('${dir.path}/b/movie.mp4');
    expect(prompts, 2);
    await locks.requireAccess('${dir.path}/a/nested/movie.mp4');
    expect(prompts, 3);
    locks.background(true);
    locks.background(false);
    expect(locks.isLocked(dir.path), false);
    expect(locks.isLocked('${dir.path}/a/movie.mp4'), true);
    expect(locks.isLocked('${dir.path}/b/movie.mp4'), true);
    await locks.setAppLockEnabled(true);
    locks.relock();
    expect(await locks.verifyPin('123456'), true);
    expect(locks.isLocked(dir.path), false);
    expect(locks.isLocked('${dir.path}/a/movie.mp4'), true);
  });

  test('concurrent resources need separate verification and a backgrounded prompt grants nothing', () async {
    final locks = ResourceLocks();
    await locks.init();
    await locks.setPin('123456');
    locks.onAuthenticate = (_) => locks.verifyPin('123456');
    await locks.toggle('${dir.path}/a', 'a');
    await locks.toggle('${dir.path}/b', 'b');
    final first = Completer<void>();
    var prompts = 0;
    locks.onAuthenticate = (_) async {
      prompts++;
      if (prompts == 1) await first.future;
      return locks.verifyPin('123456');
    };
    final a = locks.requireAccess('${dir.path}/a/file');
    final b = locks.requireAccess('${dir.path}/b/file');
    await Future<void>.delayed(Duration.zero);
    expect(prompts, 1);
    first.complete();
    await Future.wait([a, b]);
    expect(prompts, 2);
    locks.relock();
    final pending = Completer<void>();
    locks.onAuthenticate = (_) async {
      await pending.future;
      return locks.verifyPin('123456');
    };
    final rejected = expectLater(locks.requireAccess('${dir.path}/a/file'), throwsA(isA<ResourceLockedException>()));
    locks.background(true);
    locks.background(false);
    pending.complete();
    await rejected;
    expect(locks.isLocked('${dir.path}/a/file'), true);
    expect(locks.isLocked('${dir.path}/b/file'), true);
  });

  testWidgets('background relock obscures already opened content until authentication', (tester) async {
    final locks = ResourceLocks.instance;
    await tester.runAsync(() async {
      await locks.setPin('123456');
      locks.onAuthenticate = (_) => locks.verifyPin('123456');
      await locks.toggle(dir.path, 'private');
      await locks.requireAccess(dir.path);
    });
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: MouseNav.navigatorKey,
        builder: (_, child) => PrivacyShell(child: child!),
        home: Scaffold(
          body: ResourceAccessView(resources: [dir.path], child: const Text('private content')),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(ResourceUnlockPanel), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(locks.shielded, false);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('이 리소스는 잠겨 있습니다'), findsOneWidget);
    expect(find.text('private content').hitTestable(), findsNothing);
    locks.onAuthenticate = (_) => locks.verifyPin('123456');
    await tester.runAsync(() => locks.requireAccess(dir.path));
    await tester.pump();
    expect(find.byType(ResourceUnlockPanel), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('app lock covers the whole app on resume without any resource locks', (tester) async {
    final locks = ResourceLocks.instance;
    await tester.runAsync(() async {
      await locks.setPin('123456');
      locks.onAuthenticate = (_) => locks.verifyPin('123456');
      await locks.setAppLockEnabled(true);
    });
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: MouseNav.navigatorKey,
        builder: (_, child) => PrivacyShell(child: child!),
        home: const Scaffold(body: Text('app content')),
      ),
    );
    await tester.pump();
    expect(locks.resources, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('앱 잠금 해제'), findsOneWidget);
    expect(find.text('app content').hitTestable(), findsNothing);
    await tester.runAsync(() => locks.verifyPin('123456'));
    await tester.pump();
    expect(find.byType(ResourceUnlockPanel), findsNothing);
    expect(locks.forcesCaptureProtection, true);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
