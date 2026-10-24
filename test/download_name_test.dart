import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/ffmpeg.dart';
import 'package:oplayer/core/resource_locks.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/web/download_manager.dart';
import 'package:oplayer/features/web/download_name_dialog.dart';
import 'package:oplayer/sources/server_store.dart';
import 'package:oplayer/sources/source_registry.dart';

Future<void> settled(DownloadTask task) async {
  final until = DateTime.now().add(const Duration(seconds: 10));
  while ([DownloadStatus.queued, DownloadStatus.running].contains(task.status)) {
    if (DateTime.now().isAfter(until)) fail('Download timed out: ${task.error}');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  await Future<void>.delayed(const Duration(milliseconds: 10));
}

Future<void> waitFor(WidgetTester t, bool Function() ready) async {
  for (var i = 0; i < 150 && !ready(); i++) {
    await t.pump(const Duration(milliseconds: 20));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  }
  expect(ready(), true);
  await t.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manager = DownloadManager.instance;
  late Directory dir;
  HttpOverrides? previous;
  setUp(() async {
    previous = HttpOverrides.current;
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await AppSettings.instance.init();
    await ResourceLocks.instance.init();
    await ServerStore.instance.init();
    await manager.init();
    dir = await Directory.systemTemp.createTemp('oplayer_download_name_');
    AppSettings.instance.downloadDir = dir.path;
    AppSettings.instance.downloadServerId = null;
    AppSettings.instance.outputQuality = OutputQuality.original;
    AppSettings.instance.maxConcurrentDownloads = 2;
  });
  tearDown(() async {
    for (final task in manager.tasks.toList()) {
      await manager.remove(task);
    }
    for (final server in ServerStore.instance.servers.toList()) {
      await SourceRegistry.instance.invalidate(server.id);
      await ServerStore.instance.removeServer(server);
    }
    await dir.delete(recursive: true);
    HttpOverrides.global = previous;
    debugDefaultTargetPlatformOverride = null;
    Ffmpeg.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('oplayer/ffmpeg'),
      null,
    );
  });

  testWidgets('prefilled name is editable; collision asks overwrite, rename or cancel without touching the file', (
    t,
  ) async {
    final file = File('${dir.path}/recognized.mp4')..writeAsStringSync('existing');
    DownloadNameChoice? result;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await askDownloadName(context, initialName: 'recognized.mp4');
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    Future<void> open() async {
      await t.tap(find.text('Open'));
      await t.pumpAndSettle();
    }

    Future<void> submit() async {
      await t.runAsync(() => t.tap(find.text('다운로드')));
      await waitFor(t, () => find.text('같은 이름의 파일이 있습니다').evaluate().isNotEmpty);
    }

    await open();
    expect(t.widget<TextField>(find.byType(TextField)).controller!.text, 'recognized.mp4');
    await submit();
    await t.tap(find.text('다른 이름으로 저장'));
    await waitFor(t, () => t.widget<TextField>(find.byType(TextField)).enabled == true);
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'edited.mp4');
    await t.runAsync(() => t.tap(find.text('다운로드')));
    await waitFor(t, () => find.byType(AlertDialog).evaluate().isEmpty);
    expect(result!.name, 'edited.mp4');
    expect(result!.overwriteTarget, null);
    expect(file.readAsStringSync(), 'existing');
    await t.pumpAndSettle();
    await open();
    await submit();
    await t.tap(find.text('덮어쓰기'));
    await waitFor(t, () => find.byType(AlertDialog).evaluate().isEmpty);
    await t.pumpAndSettle();
    expect(result!.overwriteTarget, resourceKey(file.path));
    expect(file.readAsStringSync(), 'existing');
    await open();
    await submit();
    await t.tap(find.text('취소').last);
    await waitFor(t, () => find.byType(AlertDialog).evaluate().isEmpty);
    await t.pumpAndSettle();
    expect(result, null);
    expect(manager.tasks, isEmpty);
    expect(file.readAsStringSync(), 'existing');
  });

  test('approved local replacement keeps old bytes until the complete download is published', () async {
    final old = await File('${dir.path}/chosen.mp4').writeAsString('old bytes');
    final received = Completer<void>(), release = Completer<void>();
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((request) async {
      request.response.contentLength = 3;
      request.response.add([1]);
      await request.response.flush();
      received.complete();
      await release.future;
      request.response.add([2, 3]);
      await request.response.close();
    });
    try {
      final inspected = await manager.inspectFileName('chosen.mp4', resource: false);
      expect(inspected.exists, true);
      final task = manager.add(
        url: 'http://127.0.0.1:${server.port}/source.mp4',
        title: 'page title',
        fileName: 'chosen.mp4',
        overwriteTarget: inspected.key,
      );
      final restored = DownloadTask.fromJson(task.toJson());
      expect(restored.preferredFileName, 'chosen.mp4');
      expect(restored.overwriteTarget, inspected.key);
      await received.future;
      expect(await old.readAsString(), 'old bytes');
      expect((await manager.inspectFileName('chosen.mp4', resource: false)).busy, true);
      release.complete();
      await settled(task);
      expect(task.status, DownloadStatus.done, reason: task.error);
      expect(resourceKey(task.savePath!), resourceKey(old.path));
      expect(task.fileName, 'chosen.mp4');
      expect(await old.readAsBytes(), [1, 2, 3]);
    } finally {
      if (!release.isCompleted) release.complete();
      await server.close(force: true);
    }
  });

  test('download failure and an unapproved collision both preserve the existing file', () async {
    final old = await File('${dir.path}/chosen.mp4').writeAsString('keep');
    final server = await HttpServer.bind('127.0.0.1', 0);
    var fail = true;
    server.listen((request) async {
      request.response.statusCode = fail ? 500 : 200;
      request.response.add([7, 8]);
      await request.response.close();
    });
    try {
      final url = 'http://127.0.0.1:${server.port}/file.mp4';
      final failed = manager.add(
        url: url,
        title: 'ignored',
        fileName: 'chosen.mp4',
        overwriteTarget: resourceKey(old.path),
      );
      await settled(failed);
      expect(failed.status, DownloadStatus.failed);
      expect(await old.readAsString(), 'keep');
      fail = false;
      final numbered = manager.add(url: url, title: 'ignored', fileName: 'chosen.mp4');
      await settled(numbered);
      expect(numbered.status, DownloadStatus.done, reason: numbered.error);
      expect(numbered.fileName, 'chosen (1).mp4');
      expect(await old.readAsString(), 'keep');
      expect(await File(numbered.savePath!).readAsBytes(), [7, 8]);
    } finally {
      await server.close(force: true);
    }
  });

  test('audio conversion keeps the entered filename without a quality suffix or duplicate extension', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    Ffmpeg.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('oplayer/ffmpeg'),
      (call) async {
        if (call.method == 'version') return '6.0';
        final args = List<String>.from((call.arguments as Map)['arguments'] as List);
        await File(args.last).writeAsBytes([3, 4]);
        return {'code': 0, 'error': ''};
      },
    );
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((request) async {
      request.response.add([1, 2]);
      await request.response.close();
    });
    try {
      final task = manager.add(
        url: 'http://127.0.0.1:${server.port}/video.mp4',
        title: 'page title',
        fileName: 'my music.m4a',
        outputQuality: OutputQuality.audio,
      );
      await settled(task);
      expect(task.status, DownloadStatus.done, reason: task.error);
      expect(task.fileName, 'my music.m4a');
      expect(await File(task.savePath!).readAsBytes(), [3, 4]);
    } finally {
      await server.close(force: true);
    }
  });

  test('remote destination only overwrites an explicitly confirmed name and uploads the chosen filename', () async {
    final remote = <String, List<int>>{
      'chosen.mp4': [9],
    };
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((request) async {
      if (request.method == 'GET') {
        request.response.add([1, 2]);
      } else if (request.method == 'PROPFIND') {
        await request.drain<void>();
        request.response.statusCode = 207;
        request.response.write(
          '<d:multistatus xmlns:d="DAV:">${remote.keys.map((name) => '<d:response><d:href>/target/${Uri.encodeComponent(name)}</d:href><d:propstat><d:prop><d:getcontentlength>1</d:getcontentlength><d:resourcetype/></d:prop></d:propstat></d:response>').join()}</d:multistatus>',
        );
      } else if (request.method == 'PUT') {
        final name = Uri.decodeComponent(request.uri.pathSegments.last);
        remote[name] = await request.fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
        request.response.statusCode = 201;
      } else {
        request.response.statusCode = 405;
      }
      await request.response.close();
    });
    final config = ServerConfig(
      id: 'names',
      type: ServerType.webdav,
      name: 'NAS',
      host: '127.0.0.1',
      port: server.port,
      path: '/target',
    );
    await ServerStore.instance.saveServer(config);
    AppSettings.instance.downloadServerId = config.id;
    AppSettings.instance.downloadServerDir = '/target/';
    try {
      final destination = await manager.inspectFileName('chosen.mp4', resource: false);
      expect(destination.exists, true);
      final url = 'http://127.0.0.1:${server.port}/source.mp4';
      final numbered = manager.add(url: url, title: 'ignored', fileName: 'chosen.mp4');
      await settled(numbered);
      expect(numbered.status, DownloadStatus.done, reason: numbered.error);
      expect(remote['chosen.mp4'], [9]);
      expect(remote['chosen (1).mp4'], [1, 2]);
      final overwritten = manager.add(
        url: url,
        title: 'ignored',
        fileName: 'chosen.mp4',
        overwriteTarget: destination.key,
      );
      await settled(overwritten);
      expect(overwritten.status, DownloadStatus.done, reason: overwritten.error);
      expect(overwritten.fileName, 'chosen.mp4');
      expect(remote['chosen.mp4'], [1, 2]);
    } finally {
      await server.close(force: true);
    }
  });
}
