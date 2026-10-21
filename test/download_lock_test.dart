import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/resource_locks.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/web/downloads_page.dart';
import 'package:oplayer/features/web/download_manager.dart';

void main() {
  testWidgets('download lock hides list and filenames, independent of recent resource grants', (t) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(privacyChannel, (_) async => null);
    final locks = ResourceLocks.instance;
    final manager = DownloadManager.instance;
    await t.runAsync(() async {
      await AppSettings.instance.init();
      await locks.init();
      await locks.setPin('123456');
      locks.onAuthenticate = (_) => locks.verifyPin('123456');
      await locks.toggle(downloadsResourceKey, '다운로드');
      await locks.toggle(recentResourceKey, '최근 재생');
      await locks.requireAccess(recentResourceKey);
    });
    final task =
        DownloadTask(
            id: 'private',
            url: 'https://example.com/private',
            fileName: 'private.mp4',
            kind: DownloadKind.direct,
          )
          ..status = DownloadStatus.running
          ..total = 100
          ..received = 25;
    manager.tasks.add(task);
    addTearDown(() {
      manager.tasks.remove(task);
      locks.onAuthenticate = null;
      messenger.setMockMethodCallHandler(privacyChannel, null);
    });
    await t.pumpWidget(const MaterialApp(home: DownloadsPage()));
    await t.pumpAndSettle();
    expect(find.text('private.mp4'), findsNothing);
    expect(find.byType(PopupMenuButton<String>), findsNothing);
    expect(downloadNotificationState([task])['active'], true);
    expect(downloadNotificationState([task])['name'], '');
    await t.runAsync(() => locks.requireAccess(downloadsResourceKey));
    await t.pumpAndSettle();
    expect(find.text('private.mp4'), findsOneWidget);
    locks.background(true);
    locks.background(false);
    await t.pumpAndSettle();
    expect(find.text('private.mp4'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });
}
