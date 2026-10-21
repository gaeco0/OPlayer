import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/core/resource_locks.dart';
import 'package:oplayer/features/web/download_foreground.dart';
import 'package:oplayer/features/web/download_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('oplayer/downloads');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() => messenger.setMockMethodCallHandler(privacyChannel, (_) async => null));
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(privacyChannel, null);
  });

  test('active and queued downloads continue behind the app lock in background', () async {
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await AppSettings.instance.init();
    AppSettings.instance.maxConcurrentDownloads = 1;
    final locks = ResourceLocks.instance;
    await locks.init();
    await locks.setPin('123456');
    locks.onAuthenticate = (_) => locks.verifyPin('123456');
    await locks.setAppLockEnabled(true);
    final manager = DownloadManager.instance;
    await manager.init();
    final dir = await Directory.systemTemp.createTemp('oplayer_background_');
    AppSettings.instance.downloadDir = dir.path;
    final server = await HttpServer.bind('127.0.0.1', 0);
    final firstChunk = Completer<void>();
    final release = Completer<void>();
    final done = Completer<void>();
    DownloadTask? task;
    DownloadTask? queued;
    void changed() {
      if (task != null &&
          queued != null &&
          [DownloadStatus.done, DownloadStatus.failed].contains(queued.status) &&
          [DownloadStatus.done, DownloadStatus.failed].contains(task.status) &&
          !done.isCompleted) {
        done.complete();
      }
    }

    manager.addListener(changed);
    server.listen((request) async {
      request.response.contentLength = 6;
      request.response.add([1, 2, 3]);
      await request.response.flush();
      if (!firstChunk.isCompleted) firstChunk.complete();
      await release.future;
      request.response.add([4, 5, 6]);
      await request.response.close();
    });
    try {
      task = manager.add(url: 'http://127.0.0.1:${server.port}/video.mp4', title: 'background', hls: false);
      await firstChunk.future.timeout(const Duration(seconds: 10));
      queued = manager.add(url: 'http://127.0.0.1:${server.port}/second.mp4', title: 'queued', hls: false);
      expect(queued.status, DownloadStatus.queued);
      locks.background(true);
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      release.complete();
      await done.future.timeout(const Duration(seconds: 10));
      expect(task.status, DownloadStatus.done, reason: task.error);
      expect(queued.status, DownloadStatus.done, reason: queued.error);
      expect(await File(task.savePath!).readAsBytes(), [1, 2, 3, 4, 5, 6]);
      expect(await File(queued.savePath!).readAsBytes(), [1, 2, 3, 4, 5, 6]);
    } finally {
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      if (!release.isCompleted) release.complete();
      manager.removeListener(changed);
      if (task != null) await manager.remove(task, deleteFile: true);
      if (queued != null) await manager.remove(queued, deleteFile: true);
      locks.background(false);
      locks.onAuthenticate = null;
      FlutterSecureStorage.setMockInitialValues({});
      await locks.init();
      await server.close(force: true);
      await dir.delete();
      HttpOverrides.global = previousOverrides;
    }
  });

  test('notification describes direct/HLS progress and excludes credentials', () {
    final task =
        DownloadTask(
            id: 'a',
            url: 'https://private.example/secret',
            fileName: 'video.mp4',
            kind: DownloadKind.direct,
            headers: {'Authorization': 'secret'},
          )
          ..status = DownloadStatus.running
          ..received = 25
          ..total = 100;
    final state = downloadNotificationState([task]);
    expect(state['progress'], 25);
    expect(state['active'], true);
    expect(state.toString(), isNot(contains('secret')));
    task.kind = DownloadKind.hls;
    task.done = 60;
    expect(downloadNotificationState([task])['progress'], 60);
    task.total = 0;
    expect(downloadNotificationState([task])['progress'], -1);
    task.status = DownloadStatus.paused;
    expect(downloadNotificationState([task])['active'], false);
    task.status = DownloadStatus.queued;
    expect(downloadNotificationState([task])['active'], true);
  });

  test('service acknowledgement precedes later updates, and errors do not block cleanup', () async {
    final ready = Completer<void>();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (calls.length == 1) await ready.future;
      if (call.method == 'finished') throw PlatformException(code: 'NOTIFICATIONS_DENIED');
      return null;
    });
    final bridge = DownloadForeground(onPause: (_) {}, onOpen: () {}, onError: (_) {});
    var acknowledged = false;
    final start = bridge.update({'active': true}).then((_) => acknowledged = true);
    final completion = bridge.finished(id: 'a', name: 'video.mp4', success: true);
    final stop = bridge.update({'active': false});
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['update']);
    expect(acknowledged, false);
    final failed = expectLater(completion, throwsA(isA<PlatformException>()));
    ready.complete();
    await start;
    await failed;
    await stop;
    expect(acknowledged, true);
    expect(calls, ['update', 'finished', 'update']);
  });

  testWidgets('pending progress cannot restart service after pause; native actions are delivered', (tester) async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final pauses = <String?>[];
    var opens = 0;
    final bridge = DownloadForeground(onPause: pauses.add, onOpen: () => opens++, onError: (_) {});
    bridge.schedule({'active': true});
    await bridge.update({'active': false});
    await tester.pump(const Duration(seconds: 2));
    expect(calls.length, 1);
    expect((calls.single.arguments as Map)['active'], false);
    for (final method in ['pause', 'timeout', 'open']) {
      final response = Completer<void>();
      tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'oplayer/downloads',
        const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
        (_) => response.complete(),
      );
      await response.future;
    }
    expect(pauses.length, 2);
    expect(pauses.first, null);
    expect(pauses.last, contains('시간 제한'));
    expect(opens, 1);
  });
}
