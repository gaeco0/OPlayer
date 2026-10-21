import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/resource_locks.dart';
import 'package:oplayer/core/resume_store.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/browser/recent_page.dart';

void main() {
  testWidgets('recent list lock hides history, persists, and grants no access to a separately locked file', (
    tester,
  ) async {
    final locks = ResourceLocks.instance;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(privacyChannel, (_) async => null);
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('oplayer-recent-lock-')))!;
    final file = File('${dir.path}/private.mp3')..writeAsStringSync('audio');
    addTearDown(() async {
      locks.onAuthenticate = null;
      locks.background(false);
      FlutterSecureStorage.setMockInitialValues({});
      await locks.init();
      messenger.setMockMethodCallHandler(privacyChannel, null);
      expect(dir.absolute.path.startsWith('${Directory.systemTemp.absolute.path}${Platform.pathSeparator}'), true);
      dir.deleteSync(recursive: true);
    });
    await tester.runAsync(() async {
      await AppSettings.instance.init();
      await ResumeStore.instance.init();
      await ResumeStore.instance.save(
        file.path,
        const Duration(seconds: 1),
        const Duration(minutes: 1),
        title: 'Private track',
      );
      await locks.init();
      await locks.setPin('123456');
      locks.onAuthenticate = (_) => locks.verifyPin('123456');
      await locks.toggle(file.path, 'Private file');
    });
    await tester.pumpWidget(MaterialApp(home: RecentPage(onOpenDrawer: () {})));
    await tester.pumpAndSettle();
    expect(find.text('Private track'), findsOneWidget);
    await tester.tap(find.byTooltip('최근 재생 목록 잠금 설정'));
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!locks.hasExact(recentResourceKey) && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
    expect(locks.hasExact(recentResourceKey), true);
    expect(find.text('Private track'), findsNothing);
    expect(find.text('이 리소스 잠금 해제'), findsOneWidget);
    await tester.runAsync(() => locks.init());
    expect(locks.isLocked(recentResourceKey), true);
    await tester.runAsync(() => locks.requireAccess(recentResourceKey));
    await tester.pumpAndSettle();
    expect(find.text('Private track'), findsOneWidget);
    expect(locks.isLocked(file.path), true);
    locks.background(true);
    locks.background(false);
    await tester.pumpAndSettle();
    expect(find.text('Private track'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
