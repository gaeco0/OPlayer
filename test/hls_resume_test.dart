import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/ffmpeg.dart';
import 'package:oplayer/core/resource_locks.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/web/download_manager.dart';
import 'package:oplayer/sources/server_store.dart';

Future<void> settled(DownloadTask task) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while ([DownloadStatus.queued, DownloadStatus.running].contains(task.status)) {
    if (DateTime.now().isAfter(deadline)) fail('Download timed out: ${task.error}');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  await Future<void>.delayed(const Duration(milliseconds: 30));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manager = DownloadManager.instance;
  late Directory directory;
  late HttpServer server;
  late String url;
  final requests = <String>[];
  HttpOverrides? overrides;
  const ffmpeg = MethodChannel('oplayer/ffmpeg');

  String playlist({String first = 'first', int sequence = 0}) =>
      '#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:$sequence\n#EXTINF:5,\n$first.ts\n#EXTINF:5,\nsecond.ts\n#EXT-X-ENDLIST\n';

  DownloadTask add({String cookie = 'expired', String? text, String name = 'movie.mp4'}) => manager.add(
    url: url,
    title: 'Movie',
    fileName: name,
    hls: true,
    headers: {'Cookie': cookie},
    hlsPlaylists: {url: text ?? playlist()},
  );

  setUp(() async {
    overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await AppSettings.instance.init();
    await ResourceLocks.instance.init();
    await ServerStore.instance.init();
    await manager.init();
    directory = await Directory.systemTemp.createTemp('oplayer_hls_resume_');
    AppSettings.instance
      ..downloadDir = directory.path
      ..downloadServerId = null
      ..outputQuality = OutputQuality.original
      ..maxConcurrentDownloads = 1
      ..hlsParallelSegments = 1;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    Ffmpeg.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ffmpeg, (call) async {
      if (call.method == 'version') return 'test';
      final args = List<String>.from((call.arguments as Map)['arguments'] as List);
      await File(args[args.indexOf('-i') + 1]).copy(args.last);
      return {'code': 0, 'error': ''};
    });
    requests.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = 'http://127.0.0.1:${server.port}/video.m3u8';
    server.listen((request) async {
      final cookie = request.headers.value('cookie');
      requests.add('${request.uri.path}:$cookie');
      if (request.uri.path == '/second.ts' && cookie != 'fresh') {
        request.response.statusCode = 401;
      } else {
        request.response.add([
          request.uri.path == '/first.ts'
              ? 1
              : request.uri.path == '/changed.ts'
              ? 3
              : 2,
        ]);
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    for (final task in manager.tasks.toList()) {
      await manager.remove(task);
    }
    await server.close(force: true);
    await directory.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ffmpeg, null);
    debugDefaultTargetPlatformOverride = null;
    Ffmpeg.reset();
    HttpOverrides.global = overrides;
  });

  test('fresh cookies resume the same segments after task persistence without fetching completed ones', () async {
    final first = add();
    await settled(first);
    expect(first.status, DownloadStatus.failed);
    expect(first.done, 1);
    final id = first.id;
    manager.tasks.clear(); // Simulate a fresh process loading the persisted queue.
    await manager.init();
    final renewed = add(cookie: 'fresh');
    expect(renewed.id, id);
    expect(manager.tasks, hasLength(1));
    await settled(renewed);
    expect(renewed.status, DownloadStatus.done, reason: renewed.error);
    expect(requests.where((r) => r.startsWith('/first.ts:')), hasLength(1));
    expect(requests, contains('/second.ts:fresh'));
    expect(await File(renewed.savePath!).readAsBytes(), [1, 2]);
  });

  test('a changed segment URL at the same index invalidates the old cached pieces', () async {
    final first = add();
    await settled(first);
    final renewed = add(
      cookie: 'fresh',
      text: playlist(first: 'changed'),
    );
    expect(identical(first, renewed), isTrue);
    await settled(renewed);
    expect(renewed.status, DownloadStatus.done, reason: renewed.error);
    expect(requests, contains('/changed.ts:fresh'));
    expect(await File(renewed.savePath!).readAsBytes(), [3, 2]);
  });

  test('different sequence numbers also invalidate identically named segment URLs', () async {
    final first = add();
    await settled(first);
    final renewed = add(cookie: 'fresh', text: playlist(sequence: 10));
    expect(identical(first, renewed), isTrue);
    await settled(renewed);
    expect(renewed.status, DownloadStatus.done, reason: renewed.error);
    expect(requests.where((r) => r.startsWith('/first.ts:')), hasLength(2));
  });

  test('different filenames and completed tasks are kept separate', () async {
    AppSettings.instance.maxConcurrentDownloads = 0;
    final first = add()..status = DownloadStatus.failed;
    final other = add(name: 'other.mp4');
    expect(other.id, isNot(first.id));
    first.status = DownloadStatus.done;
    final again = add(cookie: 'fresh');
    expect(again.id, isNot(first.id));
    expect(manager.tasks, hasLength(3));
    for (var i = 0; i < 50; i++) {
      add(name: 'batch-$i.mp4');
    }
    expect(manager.tasks.map((task) => task.id).toSet(), hasLength(manager.tasks.length));
  });
}
