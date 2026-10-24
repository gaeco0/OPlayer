import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/plugins/plugin.dart';
import 'package:oplayer/core/plugins/plugin_runtime.dart';
import 'package:oplayer/core/plugins/plugin_store.dart';
import 'package:oplayer/core/plugins/plugin_upload.dart';
import 'package:oplayer/core/resource_locks.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/web/download_manager.dart';
import 'package:oplayer/sources/cloud/cloud_sources.dart';
import 'package:oplayer/sources/cloud/oauth.dart';
import 'package:oplayer/sources/server_store.dart';
import 'package:oplayer/sources/source_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late File file;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('oplayer-upload-');
    file = File('${temp.path}/movie.mp4')..writeAsStringSync('1234567');
  });
  tearDown(() => temp.delete(recursive: true));

  test('resumable upload sends bounded chunks and reports acknowledged progress', () async {
    const chunk = 8 * 1024 * 1024;
    final handle = file.openSync(mode: FileMode.write);
    handle.truncateSync(chunk + 17);
    handle.closeSync();
    final progress = <int>[];
    var requests = 0;
    final result = await uploadPluginFile(
      file,
      Uri.parse('https://upload.example/session'),
      client: MockClient((r) async {
        requests++;
        expect(r.followRedirects, false);
        expect(r.headers['Authorization'], 'Bearer test');
        if (requests == 1) {
          expect(r.headers['Content-Range'], 'bytes 0-${chunk - 1}/${chunk + 17}');
          expect(r.bodyBytes.length, chunk);
          return http.Response('', 308, headers: {'range': 'bytes=0-${chunk - 1}'});
        }
        expect(r.headers['Content-Range'], 'bytes $chunk-${chunk + 16}/${chunk + 17}');
        expect(r.bodyBytes.length, 17);
        return http.Response('{"id":"uploaded"}', 200);
      }),
      authHeaders: (_) async => {'Authorization': 'Bearer test'},
      check: () {},
      onProgress: progress.add,
    );
    expect(result, {'id': 'uploaded'});
    expect(progress, [0, chunk, chunk + 17]);
    expect(requests, 2);
  });

  test('lost responses query the server offset before resending; 401 refreshes once', () async {
    var calls = 0, refreshes = 0;
    final progress = <int>[];
    final result = await uploadPluginFile(
      file,
      Uri.parse('https://upload.example/session'),
      client: MockClient((r) async {
        calls++;
        if (calls == 1) throw http.ClientException('connection lost');
        if (calls == 2) {
          expect(r.headers['Content-Range'], 'bytes */7');
          expect(r.bodyBytes, isEmpty);
          return http.Response('', 308, headers: {'range': 'bytes=0-2'});
        }
        expect(r.headers['Content-Range'], 'bytes 3-6/7');
        expect(utf8.decode(r.bodyBytes), '4567');
        if (calls == 3) return http.Response('', 401);
        expect(r.headers['Authorization'], 'Bearer fresh');
        return http.Response('{"id":"done"}', 200);
      }),
      authHeaders: (refresh) async {
        if (refresh) refreshes++;
        return {'Authorization': refresh ? 'Bearer fresh' : 'Bearer old'};
      },
      check: () {},
      onProgress: progress.add,
    );
    expect(result, {'id': 'done'});
    expect(calls, 4);
    expect(refreshes, 1);
    expect(progress, [0, 3, 7]);
  });

  test('invalid offsets, missing write permission, and cancellation never report completion', () async {
    for (final status in [308, 403]) {
      var completed = false;
      await expectLater(
        uploadPluginFile(
          file,
          Uri.parse('https://upload.example/session'),
          client: MockClient((_) async => http.Response('', status, headers: {'range': 'bytes=0-999'})),
          authHeaders: (_) async => {},
          check: () {},
          onProgress: (v) {
            if (v == 7) completed = true;
          },
        ),
        throwsStateError,
      );
      expect(completed, false);
      expect(await file.readAsString(), '1234567');
    }
    var stopped = false;
    await expectLater(
      uploadPluginFile(
        file,
        Uri.parse('https://upload.example/session'),
        client: MockClient((_) async {
          stopped = true;
          return http.Response('{"id":"done"}', 200);
        }),
        authHeaders: (_) async => {},
        check: () {
          if (stopped) throw StateError('cancelled');
        },
      ),
      throwsStateError,
    );
  });

  test('Drive extension upload is opt-in, validates sessions and only overwrites the confirmed file ID', () async {
    final source = await File('plugins/cloud.gdrive.js').readAsString();
    final plugin = OPlugin.parse(source);
    expect(plugin.manifest['canUpload'], true);
    await expectLater(
      callPlugin(
        OPlugin.parse(source.replaceFirst('uploadComplete({response})', '_complete({response})')),
        'validate',
        {},
        validateOnly: true,
      ),
      throwsStateError,
    );
    var starts = 0;
    final plan =
        await callPlugin(
              plugin,
              'upload',
              {'path': 'folder', 'name': 'movie.mp4', 'size': 7},
              request: (url, opts) async {
                if (opts['response'] == 'headers') {
                  starts++;
                  expect(opts['method'], 'POST');
                  expect(opts['body'], {
                    'name': 'movie.mp4',
                    'parents': ['folder'],
                  });
                  expect((opts['headers'] as Map)['X-Upload-Content-Length'], '7');
                  return {'location': 'https://www.googleapis.com/upload/session'};
                }
                return {'files': []};
              },
            )
            as Map;
    expect(plan['protocol'], 'http-content-range');
    expect(starts, 1);
    Future<Object?> existing(String? grant) => callPlugin(
      plugin,
      'upload',
      {'path': 'folder', 'name': 'movie.mp4', 'size': 7, 'overwritePath': grant},
      request: (url, opts) async {
        if (opts['response'] == 'headers') {
          expect(opts['method'], 'PATCH');
          expect(Uri.parse(url).path, endsWith('/existing'));
          expect(opts['body'], {'name': 'movie.mp4'});
          return {'location': 'https://www.googleapis.com/upload/session'};
        }
        return {
          'files': [
            {'id': 'existing', 'name': 'movie.mp4', 'mimeType': 'video/mp4'},
          ],
        };
      },
    );
    await expectLater(existing(null), throwsStateError);
    await expectLater(existing('another-file'), throwsStateError);
    expect(await existing('existing'), isA<Map>());
    expect(
      await callPlugin(plugin, 'uploadComplete', {
        'response': {'id': 'new-file'},
      }),
      'new-file',
    );
  });

  test('a retained download can move to Drive, is saved with its name, and keeps local data on failure', () async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await AppSettings.instance.init();
    await ResourceLocks.instance.init();
    final store = PluginStore.instance;
    await store.init();
    await store.load(await File('plugins/cloud.gdrive.js').readAsString());
    await ServerStore.instance.init();
    final account = CloudAccount(
      id: 'upload-test',
      provider: CloudProvider.gdrive,
      name: 'Test Drive',
      oauthClientId: 'test.apps.googleusercontent.com',
    );
    await ServerStore.instance.saveAccount(account);
    final cloud = SourceRegistry.instance.forAccount(account) as CloudSource;
    await cloud.tokens.save(
      OAuthTokens(accessToken: 'test-token', expiry: DateTime.now().add(const Duration(hours: 1))),
    );
    expect(SourceRegistry.instance.uploadAccounts.map((a) => a.id), contains(account.id));
    final manager = DownloadManager.instance;
    await manager.init();
    final task =
        DownloadTask(
            id: 'upload-retained',
            url: 'https://unused.example/movie',
            fileName: 'movie.mp4',
            kind: DownloadKind.direct,
          )
          ..savePath = file.path
          ..localDone = true
          ..outputDone = true
          ..status = DownloadStatus.failed;
    manager.tasks.add(task);
    var puts = 0;
    try {
      await http.runWithClient(
        () async {
          await manager.changeDestination(task, serverId: account.id, directory: 'folder');
          final until = DateTime.now().add(const Duration(seconds: 10));
          while ([DownloadStatus.running, DownloadStatus.queued].contains(task.status)) {
            if (DateTime.now().isAfter(until)) fail('Upload timed out: ${task.error}');
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(task.status, DownloadStatus.done, reason: task.error);
          expect(task.remoteKey, 'gdrive://${account.id}/new-file');
          expect(await file.exists(), false);
        },
        () => MockClient((r) async {
          expect(r.headers['Authorization'], 'Bearer test-token');
          if (r.url.path == '/upload/session') {
            puts++;
            expect(r.method, 'PUT');
            expect(r.body, '1234567');
            return http.Response('{"id":"new-file"}', 200);
          }
          if (r.url.path.startsWith('/upload/drive/')) {
            expect(r.method, 'POST');
            expect(jsonDecode(r.body), {
              'name': 'movie.mp4',
              'parents': ['folder'],
            });
            return http.Response('', 200, headers: {'location': 'https://www.googleapis.com/upload/session'});
          }
          return http.Response('{"files":[]}', 200);
        }),
      );
      expect(puts, 1);
      await file.writeAsString('keep-local');
      await http.runWithClient(
        () async {
          await expectLater(cloud.upload(file, 'folder', 'movie.mp4'), throwsStateError);
          expect(await file.readAsString(), 'keep-local');
        },
        () => MockClient((r) async {
          if (r.url.path.startsWith('/upload/drive/')) {
            return http.Response('', 200, headers: {'location': 'https://evil.example/upload'});
          }
          return http.Response('{"files":[]}', 200);
        }),
      );
    } finally {
      await manager.remove(task);
      await SourceRegistry.instance.invalidate(account.id);
      await ServerStore.instance.removeAccount(account);
    }
  });
}
