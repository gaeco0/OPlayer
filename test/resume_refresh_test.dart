import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oplayer/core/media_item.dart';
import 'package:oplayer/core/mouse_nav.dart';
import 'package:oplayer/core/resource_locks.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/network/remote_browser_page.dart';
import 'package:oplayer/features/settings/privacy_settings.dart';
import 'package:oplayer/sources/media_source.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Source extends MediaSource {
  int calls = 0;
  bool fail = false;
  @override
  String get scheme => 'test';
  @override
  String get id => 'resume';
  @override
  String get displayName => 'Server';
  @override
  String get rootPath => '/';
  @override
  Future<List<RemoteEntry>> list(String path) async {
    calls++;
    if (fail) throw Exception('expired connection');
    return [RemoteEntry(name: 'Fresh $calls', path: '/folder', isDir: true)];
  }

  @override
  MediaItem itemFor(RemoteEntry e, List<RemoteEntry> siblings) => throw UnimplementedError();
}

void main() {
  final locks = ResourceLocks.instance;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.init();
    FlutterSecureStorage.setMockInitialValues({});
    locks.background(false);
    await locks.init();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      privacyChannel,
      (_) async => null,
    );
  });
  tearDown(() async {
    locks.onAuthenticate = null;
    locks.background(false);
    FlutterSecureStorage.setMockInitialValues({});
    await locks.init();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(privacyChannel, null);
  });

  Future<void> mount(WidgetTester t, _Source source) async {
    await t.pumpWidget(
      MaterialApp(
        navigatorKey: MouseNav.navigatorKey,
        builder: (_, child) => PrivacyShell(child: child!),
        home: RemoteBrowserPage(source: source),
      ),
    );
    await t.pumpAndSettle();
  }

  void resume(WidgetTester t) {
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }

  testWidgets('app unlock retries an errored public folder without a retry button', (t) async {
    await t.runAsync(() async {
      await locks.setPin('123456');
      locks.onAuthenticate = (_) => locks.verifyPin('123456');
      await locks.setAppLockEnabled(true);
    });
    final source = _Source()..fail = true;
    await mount(t, source);
    expect(source.calls, 1);
    expect(find.textContaining('expired connection'), findsOneWidget);
    source.fail = false;
    resume(t);
    await t.pumpAndSettle();
    expect(source.calls, 1);
    expect(locks.shielded, isTrue);
    await t.runAsync(() => locks.verifyPin('123456'));
    await t.pumpAndSettle();
    expect(source.calls, 2);
    expect(find.text('Fresh 2'), findsOneWidget);
    expect(find.textContaining('expired connection'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('initial app unlock also retries the folder blocked by the app shield', (t) async {
    await t.runAsync(() async {
      await locks.setPin('123456');
      locks.onAuthenticate = (_) => locks.verifyPin('123456');
      await locks.setAppLockEnabled(true);
      locks.relock();
    });
    final source = _Source();
    await mount(t, source);
    expect(source.calls, 0);
    await t.runAsync(() => locks.verifyPin('123456'));
    await t.pumpAndSettle();
    expect(source.calls, 1);
    expect(find.text('Fresh 1'), findsOneWidget);
    expect(find.text('다시 시도'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('resource authentication precedes the forced refresh and canceled auth can be retried', (t) async {
    final source = _Source();
    await t.runAsync(() async {
      await locks.setPin('123456');
      locks.onAuthenticate = (_) => locks.verifyPin('123456');
      await locks.toggle(source.keyFor('/'), 'Server');
      await locks.requireAccess(source.keyFor('/'));
    });
    await mount(t, source);
    final authentication = Completer<bool>();
    var prompts = 0;
    locks.onAuthenticate = (_) {
      prompts++;
      return authentication.future;
    };
    resume(t);
    await t.pump();
    await t.pump();
    expect(prompts, 1);
    expect(source.calls, 1);
    expect(find.text('Fresh 1').hitTestable(), findsNothing);
    authentication.complete(false);
    await t.pumpAndSettle();
    expect(source.calls, 1);
    locks.onAuthenticate = (_) => locks.verifyPin('123456');
    await t.tap(find.text('이 리소스 잠금 해제'));
    // Credential hashing uses a worker isolate; let it finish outside fake time.
    for (var i = 0; i < 80 && source.calls < 2; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump(const Duration(milliseconds: 20));
    }
    await t.pumpAndSettle();
    expect(source.calls, 2);
    expect(find.text('Fresh 2'), findsOneWidget);
    expect(prompts, 1);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('unlocked public folders bypass cache once per background return', (t) async {
    final source = _Source();
    await mount(t, source);
    expect(source.calls, 1);
    resume(t);
    await t.pumpAndSettle();
    expect(source.calls, 2);
    expect(find.text('Fresh 2'), findsOneWidget);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpAndSettle();
    expect(source.calls, 2);
    resume(t);
    await t.pumpAndSettle();
    expect(source.calls, 3);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('covered folders defer their refresh until their route is shown', (t) async {
    final source = _Source();
    await mount(t, source);
    unawaited(
      MouseNav.navigatorKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Player'))),
      ),
    );
    await t.pumpAndSettle();
    resume(t);
    await t.pumpAndSettle();
    expect(source.calls, 1);
    MouseNav.navigatorKey.currentState!.pop();
    await t.pumpAndSettle();
    expect(source.calls, 2);
    expect(find.text('Fresh 2'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
}
