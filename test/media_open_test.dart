import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:media_kit/media_kit.dart';
import 'package:oplayer/core/media_utils.dart';
import 'package:oplayer/core/open_media.dart';
import 'package:oplayer/app/media_shell.dart';
import 'package:oplayer/core/mouse_nav.dart';
import 'package:oplayer/core/resource_locks.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/photos/photo_viewer.dart';
import 'package:oplayer/features/player/player_controller.dart';

void main() {
  test('Android audio continues in background independently of the video preference', () {
    expect(backgroundPlaybackAllowed(android: true, audioOnly: true, enabled: false), true);
    expect(backgroundPlaybackAllowed(android: true, audioOnly: false, enabled: false), false);
    expect(backgroundPlaybackAllowed(android: true, audioOnly: false, enabled: true), true);
    expect(backgroundPlaybackAllowed(android: false, audioOnly: true, enabled: false), false);
  });
  test('audio-only detection uses actual tracks, including audio in an MP4 container', () {
    expect(audioOnlyTracks(const Tracks()), false);
    expect(audioOnlyTracks(const Tracks(audio: [AudioTrack('1', null, null)])), true);
    expect(
      audioOnlyTracks(
        const Tracks(audio: [AudioTrack('1', null, null)], video: [VideoTrack('2', null, null, albumart: true)]),
      ),
      true,
    );
    expect(
      audioOnlyTracks(
        const Tracks(
          audio: [AudioTrack('1', null, null)],
          video: [VideoTrack('2', null, null, image: true), VideoTrack('3', null, null)],
        ),
      ),
      false,
    );
    expect(audioOnlyTracks(const Tracks(audio: [AudioTrack('auto', null, null), AudioTrack('no', null, null)])), false);
    expect(
      audioOnlyTracks(const Tracks(audio: [AudioTrack('1', null, null)], video: [VideoTrack('2', null, null)])),
      false,
    );
    expect(isPlayable('music.M4A'), true);
    expect(isPlayable('audio_only.mp4'), true);
    expect(isImage('photo.JPEG'), true);
    expect(isBrowsableMedia('notes.txt'), false);
  });

  testWidgets('file opening filters unsupported files and opens a navigable photo gallery', (tester) async {
    final dir = Directory.systemTemp.createTempSync('oplayer-photos-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final first = File('assets/branding/oplayer.png').copySync('${dir.path}/first.png');
    final second = first.copySync('${dir.path}/second.png');
    final text = File('${dir.path}/ignore.txt')..writeAsStringSync('not media');
    late BuildContext openerContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            openerContext = context;
            return const Scaffold(body: Text('Files'));
          },
        ),
      ),
    );
    await tester.runAsync(
      () => openLocalMedia(openerContext, [text.path, first.path, second.path], waitForClose: false),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewer), findsOneWidget);
    expect(find.textContaining('first'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.textContaining('second'), findsOneWidget);
    await tester.tap(find.byTooltip('회전'));
    await tester.pump();
    expect(tester.widgetList<RotatedBox>(find.byType(RotatedBox)).any((box) => box.quarterTurns == 1), true);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewer), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('startup file waits for app unlock and opens only once', (tester) async {
    final locks = ResourceLocks.instance;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(privacyChannel, (_) async => null);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await tester.runAsync(() async {
      await AppSettings.instance.init();
      await locks.init();
      await locks.setPin('123456');
      locks.onAuthenticate = (_) => locks.verifyPin('123456');
      await locks.setAppLockEnabled(true);
      locks.relock();
    });
    final file = File('assets/branding/oplayer.png').absolute.path;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: MouseNav.navigatorKey,
        builder: (_, child) => MediaShell(initialFiles: [file], child: child!),
        home: const Scaffold(body: Text('Files')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewer), findsNothing);
    await tester.runAsync(() => locks.verifyPin('123456'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewer), findsOneWidget);
    MouseNav.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    locks.relock();
    await tester.runAsync(() => locks.verifyPin('123456'));
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewer), findsNothing);
    await tester.pumpWidget(const SizedBox());
    locks.onAuthenticate = null;
    FlutterSecureStorage.setMockInitialValues({});
    await locks.init();
    messenger.setMockMethodCallHandler(privacyChannel, null);
  });
}
