import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/media_item.dart';
import 'package:oplayer/core/resource_locks.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/web/download_manager.dart';
import 'package:oplayer/sources/ftp_source.dart';
import 'package:oplayer/sources/media_source.dart';
import 'package:oplayer/sources/server_store.dart';
import 'package:oplayer/sources/source_registry.dart';
import 'package:oplayer/sources/webdav_source.dart';

class _Source extends MediaSource {
  _Source(this.url);
  final String url;
  int resolutions = 0;
  int releases = 0;
  @override
  String get scheme => 'test';
  @override
  String get id => 'test';
  @override
  String get displayName => 'Test';
  @override
  String get rootPath => '/';
  @override
  Future<List<RemoteEntry>> list(String path) async => [];
  @override
  MediaItem itemFor(RemoteEntry e, List<RemoteEntry> siblings) => MediaItem(
    key: keyFor(e.path),
    uri: '',
    title: e.name,
    resolver: () async => MediaItem(
      key: keyFor(e.path),
      uri: url,
      title: e.name,
      headers: {'Authorization': 'Bearer fresh-${++resolutions}'},
      onRelease: () async {
        releases++;
      },
    ),
  );
}

Future<void> _settled(DownloadTask task) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while ([DownloadStatus.running, DownloadStatus.queued].contains(task.status)) {
    if (DateTime.now().isAfter(end)) fail('Download did not finish: ${task.error}');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  HttpOverrides? overrides;
  const entry = RemoteEntry(name: 'movie.srt', path: '/movie.srt', isDir: false, size: 6);
  setUp(() async {
    overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    dir = await Directory.systemTemp.createTemp('oplayer_remote_download_');
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await AppSettings.instance.init();
    await ResourceLocks.instance.init();
  });
  tearDown(() async {
    HttpOverrides.global = overrides;
    await dir.delete(recursive: true);
  });

  test('fresh source credentials, correct range append and cleanup', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    final source = _Source('http://127.0.0.1:${server.port}/file');
    final target = File('${dir.path}/file.part');
    await target.writeAsBytes([1, 2, 3]);
    final requests = <String?>[];
    server.listen((request) async {
      requests.add(request.headers.value('authorization'));
      expect(request.headers.value('range'), 'bytes=3-');
      request.response.statusCode = 206;
      request.response.headers.set('Content-Range', 'bytes 3-5/6');
      request.response.contentLength = 3;
      request.response.add([4, 5, 6]);
      await request.response.close();
    });
    try {
      final progress = <(int, int)>[];
      await source.download(entry, target, onProgress: (n, total) => progress.add((n, total)));
      expect(await target.readAsBytes(), [1, 2, 3, 4, 5, 6]);
      expect(progress.last, (6, 6));
      expect(source.releases, 1);
      await target.writeAsBytes([1, 2, 3]);
      await source.download(entry, target);
      expect(requests, ['Bearer fresh-1', 'Bearer fresh-2']);
      expect(source.releases, 2);
    } finally {
      await server.close(force: true);
    }
  });

  test('range ignored restarts; invalid partial range is never appended', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    var invalid = false;
    server.listen((request) async {
      if (invalid) {
        request.response.statusCode = 206;
        request.response.headers.set('Content-Range', 'bytes 0-5/6');
      }
      request.response.contentLength = 6;
      request.response.add([1, 2, 3, 4, 5, 6]);
      await request.response.close();
    });
    final source = _Source('http://127.0.0.1:${server.port}/file');
    final target = File('${dir.path}/file.part');
    try {
      await target.writeAsBytes([99, 98, 97]);
      await source.download(entry, target);
      expect(await target.readAsBytes(), [1, 2, 3, 4, 5, 6]);
      invalid = true;
      await target.writeAsBytes([1, 2, 3]);
      await expectLater(source.download(entry, target), throwsA(isA<HttpException>()));
      expect(await target.readAsBytes(), [1, 2, 3]);
      expect(source.releases, 2);
    } finally {
      await server.close(force: true);
    }
  });

  test('cancel closes an idle transfer and releases resolved source', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    final received = Completer<void>();
    server.listen((request) async {
      request.response.bufferOutput = false;
      request.response.contentLength = 65536;
      request.response.add(List.filled(32768, 1));
      try {
        await request.response.flush();
      } catch (_) {}
    });
    final source = _Source('http://127.0.0.1:${server.port}/file');
    final cancellation = Completer<void>();
    final target = File('${dir.path}/file.part');
    try {
      final download = source.download(
        entry,
        target,
        cancelled: cancellation.future,
        onProgress: (n, _) {
          if (n >= 32768 && !received.isCompleted) received.complete();
        },
      );
      final failed = expectLater(download, throwsA(anything));
      await received.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError('First chunk never arrived'),
      );
      cancellation.complete();
      await failed.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError('Cancellation did not finish'),
      );
      expect(source.releases, 1);
      expect(await target.length(), 32768);
    } finally {
      await server.close(force: true);
    }
  });

  test('resource jobs persist references, save original bytes locally and preserve collisions', () async {
    await ServerStore.instance.init();
    final manager = DownloadManager.instance;
    await manager.init();
    AppSettings.instance.downloadDir = dir.path;
    AppSettings.instance.outputQuality = OutputQuality.audio;
    AppSettings.instance.downloadServerId = 'not-a-destination';
    AppSettings.instance.maxConcurrentDownloads = 2;
    final server = await HttpServer.bind('127.0.0.1', 0);
    final cfg = ServerConfig(
      id: 'resource-download',
      type: ServerType.webdav,
      name: 'NAS',
      host: '127.0.0.1',
      port: server.port,
      username: 'test-user',
    );
    await ServerStore.instance.saveServer(cfg, password: 'private-password');
    server.listen((request) async {
      expect(
        request.headers.value('authorization'),
        'Basic ${base64Encode(utf8.encode('test-user:private-password'))}',
      );
      request.response.contentLength = 6;
      request.response.add([1, 2, 3, 4, 5, 6]);
      await request.response.close();
    });
    await File('${dir.path}/movie.srt').writeAsString('keep-existing');
    try {
      final source = WebDavSource(cfg, 'private-password');
      final first = await manager.addResource(source, entry);
      final second = await manager.addResource(source, entry);
      await Future.wait([_settled(first), _settled(second)]);
      expect(first.status, DownloadStatus.done, reason: first.error);
      expect(second.status, DownloadStatus.done, reason: second.error);
      expect(first.savePath, isNot(second.savePath));
      expect(first.fileName, endsWith('.srt'));
      expect(first.isRemote, false);
      expect(await File(first.savePath!).readAsBytes(), [1, 2, 3, 4, 5, 6]);
      expect(await File(second.savePath!).readAsBytes(), [1, 2, 3, 4, 5, 6]);
      expect(await File('${dir.path}/movie.srt').readAsString(), 'keep-existing');
      final renamed = await manager.addResource(source, entry, fileName: 'my subtitles.srt');
      await _settled(renamed);
      expect(renamed.status, DownloadStatus.done, reason: renamed.error);
      expect(renamed.fileName, 'my subtitles.srt');
      expect(renamed.resourceEntry!.path, entry.path);
      expect(await File(renamed.savePath!).readAsBytes(), [1, 2, 3, 4, 5, 6]);
      final restored = DownloadTask.fromJson(jsonDecode(jsonEncode(first.toJson())));
      expect(restored.kind, DownloadKind.resource);
      expect(restored.resourceEntry!.path, entry.path);
      expect(restored.resourceSourceId, cfg.id);
      expect(jsonEncode(first.toJson()), isNot(contains('private-password')));
      expect(jsonEncode(first.toJson()), isNot(contains('Authorization')));
      await expectLater(
        manager.addResource(source, const RemoteEntry(name: 'folder', path: '/folder/', isDir: true)),
        throwsUnsupportedError,
      );
    } finally {
      for (final task in manager.tasks.toList()) {
        await manager.remove(task);
      }
      await SourceRegistry.instance.invalidate(cfg.id);
      await ServerStore.instance.removeServer(cfg);
      await server.close(force: true);
    }
  });

  test('file names cannot escape the destination and keep extensions', () {
    expect(resourceDownloadName('../image.jpg'), '.._image.jpg');
    expect(resourceDownloadName('..'), 'download');
    expect(resourceDownloadName('CON.srt'), '_CON.srt');
    expect(resourceDownloadName('${'가' * 200}.zip'), '${'가' * 66}.zip');
  });

  test('FTP downloads binary bytes with REST and verifies transfer completion', () async {
    final server = await ServerSocket.bind('127.0.0.1', 0);
    final sockets = <Socket>[];
    final passiveServers = <ServerSocket>[];
    final commands = <String>[];
    server.listen((control) async {
      sockets.add(control);
      control.write('220-Test\r\n220 Ready\r\n');
      ServerSocket? passive;
      Future<Socket>? accepted;
      var offset = 0;
      await for (final line in control.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter())) {
        commands.add(line);
        if (line.startsWith('USER')) {
          control.write('331 Password\r\n');
        } else if (line.startsWith('PASS')) {
          control.write('230 Logged in\r\n');
        } else if (line == 'TYPE I') {
          control.write('200 Binary\r\n');
        } else if (line.startsWith('SIZE')) {
          control.write('213 6\r\n');
        } else if (line == 'EPSV') {
          passive = await ServerSocket.bind('127.0.0.1', 0);
          passiveServers.add(passive);
          accepted = passive.first;
          control.write('229 Passive (|||${passive.port}|)\r\n');
        } else if (line.startsWith('REST')) {
          offset = int.parse(line.substring(5));
          control.write('350 Restart\r\n');
        } else if (line.startsWith('RETR')) {
          control.write('150 Sending\r\n');
          await control.flush();
          final data = await accepted!;
          sockets.add(data);
          data.add(line.contains('/cancel') ? [1, 2, 3] : [1, 2, 3, 4, 5, 6].skip(offset).toList());
          await data.flush();
          if (line.contains('/cancel')) continue;
          await data.close();
          control.write('226 Complete\r\n');
        }
      }
    });
    final cfg = ServerConfig(
      id: 'ftp',
      type: ServerType.ftp,
      name: 'FTP',
      host: '127.0.0.1',
      port: server.port,
      username: 'user',
    );
    final target = File('${dir.path}/ftp.part');
    await target.writeAsBytes([1, 2, 3]);
    try {
      await FtpSource(cfg, 'pass').download(entry, target).timeout(const Duration(seconds: 8));
      expect(await target.readAsBytes(), [1, 2, 3, 4, 5, 6]);
      expect(commands, contains('REST 3'));
      final cancelled = Completer<void>();
      final firstChunk = Completer<void>();
      final partial = File('${dir.path}/cancel.part');
      final job = FtpSource(cfg, 'pass').download(
        const RemoteEntry(name: 'cancel', path: '/cancel', isDir: false, size: 6),
        partial,
        cancelled: cancelled.future,
        onProgress: (n, _) {
          if (n == 3 && !firstChunk.isCompleted) firstChunk.complete();
        },
      );
      final failed = expectLater(job, throwsStateError);
      await firstChunk.future.timeout(const Duration(seconds: 5));
      cancelled.complete();
      await failed.timeout(const Duration(seconds: 5));
      expect(await partial.readAsBytes(), [1, 2, 3]);
    } finally {
      for (final s in sockets) {
        s.destroy();
      }
      for (final s in passiveServers) {
        await s.close();
      }
      await server.close();
    }
  });
}
