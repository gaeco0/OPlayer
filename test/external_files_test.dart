import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oplayer/app/media_shell.dart';
import 'package:oplayer/core/external_files.dart';
import 'package:oplayer/core/linux_file_associations.dart';
import 'package:oplayer/core/mouse_nav.dart';
import 'package:oplayer/core/open_media.dart';
import 'package:oplayer/core/resource_locks.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/photos/photo_viewer.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('desktop Exec quotes paths without turning them into shell commands', () {
    final desktop = linuxDesktopEntry('/opt/My Player/50% "quoted" \$name/oplayer');
    expect(desktop, contains(r'Exec="/opt/My Player/50%% \\"quoted\\" \\$name/oplayer" %F'));
    expect(desktop, contains('image/jpeg;'));
    expect(desktop, contains('audio/mp4;'));
    expect(desktop, contains('video/x-matroska;'));
    expect(desktop, isNot(contains('x-scheme-handler/http')));
  });

  testWidgets('native startup and running-app file events wait for unlock and open once', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final photo = File('assets/branding/oplayer.png').absolute;
    final locks = ResourceLocks.instance;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    messenger.setMockMethodCallHandler(privacyChannel, (_) async => null);
    messenger.setMockMethodCallHandler(externalFilesChannel, (call) async {
      if (call.method == 'ready') {
        return [
          {'uri': photo.uri.toString(), 'name': 'oplayer.png'},
        ];
      }
      return null;
    });
    await tester.runAsync(() async {
      await AppSettings.instance.init();
      await locks.init();
      await locks.setPin('123456');
      locks.onAuthenticate = (_) => locks.verifyPin('123456');
      await locks.setAppLockEnabled(true);
    });
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: MouseNav.navigatorKey,
        builder: (_, child) => MediaShell(child: child!),
        home: const Scaffold(body: Text('Home')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewer), findsNothing);
    await tester.runAsync(() => locks.verifyPin('123456'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewer), findsOneWidget);
    MouseNav.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    locks.background(true);
    await messenger.handlePlatformMessage(
      'oplayer/open_files',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('open', [
          {'uri': photo.uri.toString()},
        ]),
      ),
      (_) {},
    );
    await tester.pump();
    expect(find.byType(PhotoViewer), findsNothing);
    locks.background(false);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.byType(PhotoViewer), findsNothing);
    await tester.runAsync(() => locks.verifyPin('123456'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewer), findsOneWidget);
    MouseNav.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewer), findsNothing);
    await tester.pumpWidget(const SizedBox());
    locks.background(false);
    locks.onAuthenticate = null;
    FlutterSecureStorage.setMockInitialValues({});
    await tester.runAsync(locks.init);
    messenger.setMockMethodCallHandler(privacyChannel, null);
    messenger.setMockMethodCallHandler(externalFilesChannel, null);
  });

  testWidgets('opaque content photo uses provider metadata and resolves to a readable image', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const uri = 'content://files/document/123';
    var prepared = 0;
    messenger.setMockMethodCallHandler(externalFilesChannel, (call) async {
      expect(call.method, 'prepareImage');
      expect(call.arguments, uri);
      prepared++;
      return File('assets/branding/oplayer.png').absolute.path;
    });
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const Scaffold();
          },
        ),
      ),
    );
    await openExternalMedia(context, const [ExternalFile(uri, name: '사진.png', mime: 'image/png')]);
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewer), findsOneWidget);
    expect(prepared, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    messenger.setMockMethodCallHandler(externalFilesChannel, null);
  });
}
