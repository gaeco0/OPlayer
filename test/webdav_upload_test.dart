import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/core/network/local_proxy.dart';
import 'package:oplayer/core/network/tunnel_socket.dart';
import 'package:oplayer/features/web/download_manager.dart';
import 'package:oplayer/sources/server_store.dart';
import 'package:oplayer/sources/webdav_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late File file;
  late HttpServer server;
  late WebDavSource source;
  late HttpOverrides? previous;
  setUp(() async {
    previous = HttpOverrides.current;
    HttpOverrides.global = null;
    dir = await Directory.systemTemp.createTemp('oplayer_webdav_');
    file = await File('${dir.path}/video.mp4').writeAsBytes(List.generate(500000, (i) => i % 251));
    server = await HttpServer.bind('127.0.0.1', 0);
    source = WebDavSource(
      ServerConfig(
        id: 'dav',
        type: ServerType.webdav,
        name: 'NAS',
        host: '127.0.0.1',
        port: server.port,
        username: 'user',
      ),
      'password',
      uploadTimeout: const Duration(seconds: 2),
    );
  });
  tearDown(() async {
    await server.close(force: true);
    await dir.delete(recursive: true);
    HttpOverrides.global = previous;
  });

  test('PUT preserves bytes, path, authentication and waits for server acknowledgement', () async {
    final received = Completer<void>();
    final acknowledge = Completer<void>();
    final progress = <int>[];
    server.listen((request) async {
      expect(request.method, 'PUT');
      expect(Uri.decodeFull(request.uri.path), '/videos/한 글.mp4');
      expect(request.headers.value('authorization'), 'Basic ${base64Encode(utf8.encode('user:password'))}');
      expect(request.contentLength, await file.length());
      final bytes = await request.fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
      expect(bytes, await file.readAsBytes());
      received.complete();
      await acknowledge.future;
      request.response.statusCode = 201;
      // Deliberately leave the optional response body open after headers.
      request.response.write('saved');
      await request.response.flush();
    });
    var finished = false;
    final upload = source.upload(file, '/videos', '한 글.mp4', onProgress: progress.add)..then((_) => finished = true);
    await received.future.timeout(const Duration(seconds: 5));
    expect(finished, false);
    acknowledge.complete();
    expect(await upload, '/videos/한 글.mp4');
    expect(progress.last, await file.length());
    expect(progress, orderedEquals([...progress]..sort()));
  });

  test('stalled server times out and preserves the local file', () async {
    source = WebDavSource(source.cfg, source.password, uploadTimeout: const Duration(milliseconds: 200));
    server.listen((request) async {
      await request.drain<void>();
    });
    await expectLater(source.upload(file, '/', 'video.mp4'), throwsA(isA<TimeoutException>()));
    expect(await file.length(), 500000);
  });

  test('pause cancels while waiting for acknowledgement', () async {
    final received = Completer<void>();
    server.listen((request) async {
      await request.drain<void>();
      received.complete();
    });
    final cancel = Completer<void>();
    final upload = source.upload(file, '/', 'video.mp4', cancelled: cancel.future);
    final check = expectLater(upload, throwsA(isA<HttpException>()));
    await received.future.timeout(const Duration(seconds: 5));
    cancel.complete();
    await check.timeout(const Duration(seconds: 1));
    expect(await file.exists(), true);
  });

  test('pause interrupts a blocked file transfer', () async {
    final handle = await file.open(mode: FileMode.append);
    await handle.truncate(32 * 1024 * 1024);
    await handle.close();
    final connected = Completer<void>();
    server.listen((request) {
      connected.complete();
    }); // Server does not consume the body.
    final cancel = Completer<void>();
    final check = expectLater(
      source.upload(file, '/', 'large.mp4', cancelled: cancel.future),
      throwsA(isA<HttpException>()),
    );
    await connected.future.timeout(const Duration(seconds: 5));
    cancel.complete();
    await check.timeout(const Duration(seconds: 1));
    expect(await file.length(), 32 * 1024 * 1024);
  });

  test('permission rejection produces an actionable error', () async {
    server.listen((request) async {
      await request.drain<void>();
      request.response.statusCode = 403;
      await request.response.close();
    });
    await expectLater(
      source.upload(file, '/', 'video.mp4'),
      throwsA(isA<HttpException>().having((e) => e.message, 'message', contains('쓰기 권한'))),
    );
  });

  test('PUT also works through the app network proxy', () async {
    final proxy = LocalProxy((host, port) async => TunnelSocket(await Socket.connect(host, port)));
    await proxy.start();
    server.listen((request) async {
      final body = await request.fold<List<int>>([], (body, chunk) => body..addAll(chunk));
      expect(body, await file.readAsBytes());
      request.response.statusCode = 204;
      await request.response.close();
    });
    try {
      final path = await HttpOverrides.runWithHttpOverrides(
        () => source.upload(file, '/', 'proxy.mp4'),
        _ProxyOverrides(proxy.port),
      );
      expect(path, '/proxy.mp4');
    } finally {
      await proxy.close();
    }
  });

  test('failed upload retries the completed local file without downloading again', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await AppSettings.instance.init();
    await ServerStore.instance.init();
    await ServerStore.instance.saveServer(source.cfg);
    AppSettings.instance.downloadServerId = source.cfg.id;
    AppSettings.instance.downloadServerDir = '/videos';
    final manager = DownloadManager.instance;
    await manager.init();
    var gets = 0;
    var puts = 0;
    final bytes = await file.readAsBytes();
    server.listen((request) async {
      if (request.method == 'GET') {
        gets++;
        request.response.add(bytes);
      } else {
        puts++;
        final body = await request.fold<List<int>>([], (body, chunk) => body..addAll(chunk));
        expect(body, bytes);
        request.response.statusCode = puts == 1 ? 403 : 201;
      }
      await request.response.close();
    });
    final failed = Completer<void>();
    final done = Completer<void>();
    DownloadTask? task;
    void changed() {
      if (task?.status == DownloadStatus.failed && !failed.isCompleted) failed.complete();
      if (task?.status == DownloadStatus.done && !done.isCompleted) done.complete();
    }

    manager.addListener(changed);
    try {
      task = manager.add(url: 'http://127.0.0.1:${server.port}/video.mp4', title: 'dav-retry', hls: false);
      await failed.future.timeout(const Duration(seconds: 5));
      expect(task.localDone, true);
      final pending = File(task.savePath!);
      expect(await pending.readAsBytes(), bytes);
      manager.resume(task);
      await done.future.timeout(const Duration(seconds: 5));
      expect(gets, 1);
      expect(puts, 2);
      expect(task.remoteKey, startsWith('webdav://dav/videos/'));
      expect(await pending.exists(), false);
    } finally {
      manager.removeListener(changed);
      if (task != null) await manager.remove(task);
      AppSettings.instance.downloadServerId = null;
    }
  });

  test('HLS upload progress uses bytes and survives persistence', () {
    final task = DownloadTask(id: 'a', url: 'https://example.com/a.m3u8', fileName: 'a.mp4', kind: DownloadKind.hls)
      ..remoteServerId = 'dav'
      ..localDone = true
      ..uploading = true
      ..total = 1000
      ..received = 250
      ..done = 0;
    expect(task.progress, .25);
    expect(DownloadTask.fromJson(task.toJson()).progress, .25);
    expect(downloadNotificationState([task])['progress'], 25);
  });
}

class _ProxyOverrides extends HttpOverrides {
  _ProxyOverrides(this.port);
  final int port;
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..findProxy = (_) => 'PROXY 127.0.0.1:$port';
}
