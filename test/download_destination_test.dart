import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/resource_locks.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/web/download_manager.dart';
import 'package:oplayer/features/web/downloads_page.dart';
import 'package:oplayer/sources/server_store.dart';
import 'package:oplayer/sources/source_registry.dart';

Future<void> _wait(bool Function() ready) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (!ready()) {
    if (DateTime.now().isAfter(end)) fail('Move did not settle');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  await Future<void>.delayed(const Duration(milliseconds: 10));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manager = DownloadManager.instance;
  late Directory dir;
  late File original;
  final bytes = List.generate(4096, (i) => i % 251);
  HttpOverrides? previous;
  var sequence = 0;
  DownloadTask retained({DownloadKind kind = DownloadKind.hls}) {
    final task =
        DownloadTask(
            id: 'move-${sequence++}',
            url: 'https://example.invalid/expired.m3u8',
            fileName: 'video.mp4',
            kind: kind,
          )
          ..status = DownloadStatus.failed
          ..localDone = true
          ..outputDone = true
          ..savePath = original.path
          ..remoteServerId = 'unavailable-server'
          ..remoteDir = '/old'
          ..uploading = true
          ..received = bytes.length ~/ 2
          ..total = bytes.length;
    manager.tasks.add(task);
    return task;
  }

  setUp(() async {
    previous = HttpOverrides.current;
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await AppSettings.instance.init();
    await ResourceLocks.instance.init();
    await ServerStore.instance.init();
    await manager.init();
    dir = await Directory.systemTemp.createTemp('oplayer_move_');
    final cache = await Directory('${dir.path}/cache').create();
    original = await File('${cache.path}/video.mp4').writeAsBytes(bytes);
    AppSettings.instance.downloadDir = '${dir.path}/default';
    AppSettings.instance.downloadServerId = 'global-server';
    AppSettings.instance.downloadServerDir = '/global';
    AppSettings.instance.maxConcurrentDownloads = 2;
  });
  tearDown(() async {
    for (final task in manager.tasks.toList()) {
      await manager.remove(task);
    }
    for (final config in ServerStore.instance.servers.toList()) {
      await SourceRegistry.instance.invalidate(config.id);
      await ServerStore.instance.removeServer(config);
    }
    ResourceLocks.instance.onAuthenticate = null;
    await dir.delete(recursive: true);
    HttpOverrides.global = previous;
  });

  test('failed upload saves retained HLS file locally without re-fetching or replacing existing files', () async {
    final task = retained();
    final destination = await Directory('${dir.path}/saved').create();
    final existing = await File('${destination.path}/video.mp4').writeAsString('keep');
    await manager.changeDestination(task, directory: destination.path);
    await _wait(() => task.status == DownloadStatus.done || task.status == DownloadStatus.failed);
    expect(task.status, DownloadStatus.done, reason: task.error);
    expect(await File(task.savePath!).readAsBytes(), bytes);
    expect(task.savePath, isNot(existing.path));
    expect(await existing.readAsString(), 'keep');
    expect(await original.exists(), false);
    expect(task.isRemote, false);
    expect(task.progress, 1);
    expect(DownloadTask.fromJson(task.toJson()).localDirectory, destination.path);
    expect(AppSettings.instance.downloadServerId, 'global-server');
    expect(AppSettings.instance.downloadServerDir, '/global');
  });

  test('another WebDAV server receives the retained original and must acknowledge before deletion', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    final config = ServerConfig(
      id: 'move-server',
      type: ServerType.webdav,
      name: 'Other NAS',
      host: '127.0.0.1',
      port: server.port,
    );
    await ServerStore.instance.saveServer(config);
    final task = retained();
    var gets = 0;
    var puts = 0;
    final received = Completer<void>();
    final acknowledge = Completer<void>();
    server.listen((request) async {
      if (request.method == 'GET') gets++;
      if (request.method == 'PUT') puts++;
      expect(request.uri.path, '/backup/video.mp4');
      expect(await request.fold<List<int>>([], (result, chunk) => result..addAll(chunk)), bytes);
      received.complete();
      await acknowledge.future;
      request.response.statusCode = 201;
      await request.response.close();
    });
    try {
      await manager.changeDestination(task, serverId: config.id, directory: '/backup');
      await received.future.timeout(const Duration(seconds: 5));
      expect(await original.exists(), true);
      expect(task.status, DownloadStatus.running);
      acknowledge.complete();
      await _wait(() => task.status == DownloadStatus.done || task.status == DownloadStatus.failed);
      expect(task.status, DownloadStatus.done, reason: task.error);
      expect(gets, 0);
      expect(puts, 1);
      expect(await original.exists(), false);
      expect(task.remoteKey, 'webdav://move-server/backup/video.mp4');
      expect(AppSettings.instance.downloadServerId, 'global-server');
    } finally {
      if (!acknowledge.isCompleted) acknowledge.complete();
      await server.close(force: true);
    }
  });

  test('a second destination failure retains original for another local fallback', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    final config = ServerConfig(
      id: 'denied',
      type: ServerType.webdav,
      name: 'Denied NAS',
      host: '127.0.0.1',
      port: server.port,
    );
    await ServerStore.instance.saveServer(config);
    server.listen((request) async {
      await request.drain<void>();
      request.response.statusCode = 403;
      await request.response.close();
    });
    final task = retained();
    try {
      await manager.changeDestination(task, serverId: config.id, directory: '/denied');
      await _wait(() => task.status == DownloadStatus.failed && manager.canChangeDestination(task));
      expect(await original.readAsBytes(), bytes);
      expect(task.savePath, original.path);
      expect(task.error, contains('HTTP 403'));
      await manager.changeDestination(task, directory: '${dir.path}/fallback');
      await _wait(() => task.status == DownloadStatus.done || task.status == DownloadStatus.failed);
      expect(task.status, DownloadStatus.done, reason: task.error);
      expect(await File(task.savePath!).readAsBytes(), bytes);
    } finally {
      await server.close(force: true);
    }
  });

  test('local disk error preserves the cached original and retry destination', () async {
    final task = retained();
    final blocker = await File('${dir.path}/blocker').writeAsString('file');
    await manager.changeDestination(task, directory: '${blocker.path}/folder');
    await _wait(() => task.status == DownloadStatus.failed && manager.canChangeDestination(task));
    expect(await original.readAsBytes(), bytes);
    expect(task.savePath, original.path);
    expect(DownloadTask.fromJson(task.toJson()).localDirectory, Directory('${blocker.path}/folder').absolute.path);
  });

  test('locked target refuses changes without discarding the old destination or file', () async {
    final task = retained();
    final locks = ResourceLocks.instance;
    final destination = '${dir.path}/locked';
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(privacyChannel, (_) async => null);
    try {
      await locks.setPin('123456');
      locks.onAuthenticate = (_) async => true;
      await locks.toggle(destination, 'locked');
      locks.onAuthenticate = (_) async => false;
      await expectLater(
        manager.changeDestination(task, directory: destination),
        throwsA(isA<ResourceLockedException>()),
      );
      expect(task.remoteServerId, 'unavailable-server');
      expect(task.localDirectory, null);
      expect(task.status, DownloadStatus.failed);
      expect(await original.readAsBytes(), bytes);
    } finally {
      messenger.setMockMethodCallHandler(privacyChannel, null);
    }
  });

  test('pause before local publication preserves the source and cleans staging data', () async {
    final task = retained();
    var paused = false;
    void changed() {
      if (task.moving && task.status == DownloadStatus.running && !paused) {
        paused = true;
        manager.pause(task);
      }
    }

    manager.addListener(changed);
    final destination = '${dir.path}/paused';
    try {
      await manager.changeDestination(task, directory: destination);
      await _wait(() => paused && manager.canChangeDestination(task));
      expect(task.status, DownloadStatus.paused);
      expect(await original.readAsBytes(), bytes);
      expect(await Directory(destination).list().toList(), isEmpty);
      final restored = DownloadTask.fromJson(task.toJson());
      expect(restored.progress, task.progress);
      manager.resume(task);
      await _wait(() => task.status == DownloadStatus.done || task.status == DownloadStatus.failed);
      expect(task.status, DownloadStatus.done, reason: task.error);
      expect(await File(task.savePath!).readAsBytes(), bytes);
    } finally {
      manager.removeListener(changed);
    }
  });

  test('incomplete and active jobs cannot be moved', () async {
    final task = retained()..localDone = false;
    expect(manager.canChangeDestination(task), false);
    await expectLater(manager.changeDestination(task, directory: dir.path), throwsStateError);
    task
      ..localDone = true
      ..status = DownloadStatus.running;
    expect(manager.canChangeDestination(task), false);
    task.status = DownloadStatus.failed;
    await original.delete();
    expect(manager.canChangeDestination(task), false);
    task.status = DownloadStatus.failed;
  });

  testWidgets('failed item offers destinations and cancelling the picker preserves the file', (t) async {
    final task = retained();
    await t.pumpWidget(const MaterialApp(home: DownloadsPage()));
    await t.pumpAndSettle();
    await t.tap(find.byIcon(Icons.more_vert));
    await t.pumpAndSettle();
    await t.tap(find.text('다른 저장소로 이동'));
    await t.pumpAndSettle();
    expect(find.text('이 기기 · 다운로드 폴더'), findsOneWidget);
    Navigator.of(t.element(find.text('이 기기 · 다운로드 폴더'))).pop();
    await t.pumpAndSettle();
    expect(task.status, DownloadStatus.failed);
    expect(task.localDirectory, null);
    expect(await t.runAsync(original.readAsBytes), bytes);
    expect(AppSettings.instance.downloadServerId, 'global-server');
    await t.pumpWidget(const SizedBox());
    await t.pumpAndSettle();
  });
}
