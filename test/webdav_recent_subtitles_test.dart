import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/resource_locks.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/sources/server_store.dart';
import 'package:oplayer/sources/source_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('recent WebDAV playback re-lists its folder and fetches matching subtitles with authentication', () async {
    final previous = HttpOverrides.current;
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await AppSettings.instance.init();
    await ResourceLocks.instance.init();
    await ServerStore.instance.init();
    final server = await HttpServer.bind('127.0.0.1', 0);
    final cfg = ServerConfig(
      id: 'recent-subtitles',
      type: ServerType.webdav,
      name: 'NAS',
      host: '127.0.0.1',
      port: server.port,
      username: 'user',
    );
    final downloaded = <File>[];
    addTearDown(() async {
      await SourceRegistry.instance.invalidate(cfg.id);
      await server.close(force: true);
      for (final file in downloaded) {
        if (await file.exists()) await file.delete();
      }
      HttpOverrides.global = previous;
    });
    await ServerStore.instance.saveServer(cfg, password: 'password');
    var denyListing = false;
    final paths = <String>[];
    server.listen((request) async {
      expect(request.headers.value('authorization'), 'Basic ${base64Encode(utf8.encode('user:password'))}');
      await request.drain<void>();
      final path = Uri.decodeFull(request.uri.path);
      paths.add('${request.method} $path');
      if (request.method == 'PROPFIND') {
        expect(path, '/한글 폴더/');
        expect(request.headers.value('depth'), '1');
        request.response.statusCode = denyListing ? 403 : 207;
        if (!denyListing) {
          request.response.write('<d:multistatus xmlns:d="DAV:">');
          for (final name in ['영상.mp4', '영상.ko.srt', '영상.smi', '다른 영상.srt']) {
            final href = '/한글 폴더/$name'.split('/').map(Uri.encodeComponent).join('/');
            request.response.write(
              '<d:response><d:href>$href</d:href><d:propstat><d:prop>'
              '<d:resourcetype/></d:prop></d:propstat></d:response>',
            );
          }
          request.response.write('</d:multistatus>');
        }
      } else {
        expect(request.method, 'GET');
        expect(path, isIn(['/한글 폴더/영상.ko.srt', '/한글 폴더/영상.smi']));
        request.response.add(utf8.encode('자막 원본'));
      }
      await request.response.close();
    });
    final key = 'webdav://${cfg.id}/한글 폴더/영상.mp4';
    final item = (await SourceRegistry.instance.itemFromKey(key, title: '표시 제목'))!;
    final resolved = await item.resolve();
    expect(resolved.key, key);
    expect(resolved.subtitles.map((s) => s.title), ['영상.ko.srt', '영상.smi']);
    for (final subtitle in resolved.subtitles) {
      final file = File.fromUri(Uri.parse(subtitle.uri));
      downloaded.add(file);
      expect(await file.readAsString(), '자막 원본');
    }
    expect(paths, ['PROPFIND /한글 폴더/', 'GET /한글 폴더/영상.ko.srt', 'GET /한글 폴더/영상.smi']);
    denyListing = true;
    final readable = (await SourceRegistry.instance.itemFromKey(key))!;
    expect((await readable.resolve()).subtitles, isEmpty);
    expect(readable.uri, resolved.uri);
  });
}
