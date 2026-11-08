import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/plugins/plugin_store.dart';
import 'package:oplayer/core/plugins/plugin_runtime.dart';
import 'package:oplayer/core/plugins/plugin.dart';
import 'package:oplayer/sources/server_store.dart';
import 'package:oplayer/core/playback_sync.dart';
import 'package:oplayer/core/playlist_store.dart';
import 'package:oplayer/core/resume_store.dart';
import 'package:oplayer/core/resource_locks.dart';
import 'package:oplayer/core/secure_store.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/core/sync_document.dart';
import 'package:oplayer/core/sync_references.dart';
import 'package:oplayer/sources/cloud/oauth.dart';

const googleSyncScope = 'https://www.googleapis.com/auth/drive.appdata';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('documents converge, keep independent playlists and retain deletion tombstones', () {
    final a = SyncDocument('a'), b = SyncDocument('b');
    a.change('playlist:one', {'name': 'one'});
    b.change('playlist:two', {'name': 'two'});
    a.merge(b.toJson());
    b.merge(a.toJson());
    expect(SyncDocument.same(a.toJson(), b.toJson()), true);
    final offline = jsonDecode(jsonEncode(a.toJson())) as Map<String, dynamic>;
    a.change('playlist:one', null);
    a.merge(offline);
    b.merge(a.toJson());
    expect(b.values.containsKey('playlist:one'), false);
    expect(b.records['playlist:one']!['value'], null);
    expect(b.values['playlist:two']!['name'], 'two');
    expect(
      SyncDocument.same(
        {
          'a': [1, 2],
          'b': true,
        },
        {
          'b': true,
          'a': [1, 2],
        },
      ),
      true,
    );
    final invalid = {
      'version': 1,
      'records': {
        'playlist:x': {'time': -1, 'device': 'x', 'value': null},
      },
    };
    final before = jsonEncode(a.toJson());
    expect(() => a.merge(invalid), throwsFormatException);
    expect(jsonEncode(a.toJson()), before);
  });

  test('explicit aliases map different roots without exposing URLs or permitting folder traversal', () async {
    SharedPreferences.setMockInitialValues({});
    final refs = SyncReferences();
    await refs.init();
    final root = '${Directory.systemTemp.path}${Platform.pathSeparator}oplayer_movies';
    await refs.bind(root, '영화');
    final key = refs.portable('$root${Platform.pathSeparator}시즌${Platform.pathSeparator}1.mp4')!;
    expect(key, isNot(contains(root)));
    expect(refs.resolve(key), '$root${Platform.pathSeparator}시즌${Platform.pathSeparator}1.mp4');
    expect(refs.portable('https://example.com/stream?token=secret'), null);
    expect(refs.portable('${Directory.systemTemp.path}${Platform.pathSeparator}other.mp4'), null);
    final bad = '${SyncReferences.prefix}${base64Url.encode(utf8.encode(jsonEncode(['영화', '../outside.mp4'])))}';
    expect(refs.resolve(bad), null);
    await refs.bind(root, '');
    final other = '$root-other';
    await refs.bind(other, '영화');
    expect(refs.resolve(key), '$other${Platform.pathSeparator}시즌${Platform.pathSeparator}1.mp4');
    await refs.bind('gdrive://device-account', '클라우드');
    final cloudKey = refs.portable('gdrive://device-account/file-id')!;
    await refs.bind('gdrive://device-account', '');
    await refs.bind('gdrive://another-account', '클라우드');
    expect(refs.resolve(cloudKey), 'gdrive://another-account/file-id');
  });

  test('Android appdata authorization is separate from the per-file cloud scope', () async {
    const channel = MethodChannel('oplayer/google-drive');
    final calls = <Map>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.arguments as Map);
      return {'accessToken': 'native-token', 'grantedScopes': (call.arguments as Map)['scopes']};
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );
    final sync = GoogleAndroidOAuthClient(
      clientId: 'android',
      accountEmail: 'a@example.com',
      requestedScopes: [googleSyncScope],
    );
    await sync.authorize();
    expect(calls.last['scopes'], [googleSyncScope]);
    expect(calls.last['email'], 'a@example.com');
    await GoogleAndroidOAuthClient(clientId: 'cloud', requestedScopes: const [googleDriveFileScope]).authorize();
    expect(calls.last['scopes'], ['https://www.googleapis.com/auth/drive.file']);
  });

  test('Google sync transport lives in the extension and preserves appdata format', () async {
    final plugin = OPlugin.parse(await File('plugins/sync.gdrive.js').readAsString());
    var creates = 0, updates = 0;
    Future<Object?> request(String url, Map<String, dynamic> options) async {
      final uri = Uri.parse(url);
      expect(uri.host, 'www.googleapis.com');
      if (options['method'] == 'POST') {
        creates++;
        expect(options['body'], contains('"parents":["appDataFolder"]'));
        expect(options['body'], contains('한글'));
        expect(options['body'], contains('\r\nContent-Type:'));
        return {};
      }
      if (options['method'] == 'PATCH') {
        updates++;
        expect(options['body'], containsPair('version', 1));
        return {};
      }
      expect(uri.queryParameters['spaces'], 'appDataFolder');
      return uri.queryParameters['pageToken'] == null
          ? {
              'files': [
                {'id': 'one', 'name': 'first'},
              ],
              'nextPageToken': 'next',
            }
          : {
              'files': [
                {'id': 'two', 'name': 'second'},
              ],
            };
    }

    final files = await callPlugin(plugin, 'syncList', {}, request: request) as List;
    expect(files.map((f) => f['id']), ['one', 'two']);
    final doc = SyncDocument('한글')..change('playlist:x', {'name': '한글'});
    await callPlugin(plugin, 'syncWrite', {
      'name': 'test.json',
      'device': 'device',
      'document': doc.toJson(),
    }, request: request);
    await callPlugin(plugin, 'syncWrite', {
      'name': 'test.json',
      'device': 'device',
      'document': doc.toJson(),
      'id': 'own',
    }, request: request);
    expect(creates, 1);
    expect(updates, 1);
  });

  test('a synchronized reference cannot bypass the original resource lock when changing watched status', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(privacyChannel, (_) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(privacyChannel, null);
      ResourceLocks.instance.onAuthenticate = null;
    });
    await AppSettings.instance.init();
    await ResumeStore.instance.init();
    final refs = SyncReferences.instance;
    await refs.init();
    final root = '${Directory.systemTemp.path}${Platform.pathSeparator}sync_private';
    await refs.bind(root, '비공개');
    final key = refs.portable('$root${Platform.pathSeparator}video.mp4')!;
    final locks = ResourceLocks.instance;
    await locks.init();
    await locks.setPin('123456');
    locks.onAuthenticate = (_) async => true;
    await locks.toggle(root, 'private');
    locks.relock();
    locks.onAuthenticate = (_) async => false;
    await expectLater(ResumeStore.instance.toggleWatched(key), throwsA(isA<ResourceLockedException>()));
    expect(ResumeStore.instance.get(key), null);
  });

  test(
    'sync merges metadata, resumes a newer rewind, preserves edits and rejects mismatched accounts or corrupt data',
    () async {
      final root = '${Directory.systemTemp.path}${Platform.pathSeparator}oplayer_sync_test';
      final file = '$root${Platform.pathSeparator}episode.mp4';
      SharedPreferences.setMockInitialValues({
        'sync_provider': 'sync.gdrive',
        'pluginSyncConnection:sync.gdrive': jsonEncode({
          'id': 'account',
          'email': 'a@example.com',
          'account': CloudAccount(
            id: 'sync-account',
            provider: CloudProvider.plugin,
            name: 'a@example.com',
            pluginId: 'sync.gdrive',
            oauthClientId: 'desktop.apps.googleusercontent.com',
          ).toJson(),
        }),
        'pluginSyncAuto:sync.gdrive:account': false,
        'sync_sources_v1': jsonEncode({root: '영화'}),
      });
      FlutterSecureStorage.setMockInitialValues({});
      await SecureStore.instance.writeRequired(
        'tok_sync-account',
        jsonEncode(
          OAuthTokens(accessToken: 'private-token', expiry: DateTime.now().add(const Duration(hours: 1))).toJson(),
        ),
      );
      await AppSettings.instance.init();
      await ResourceLocks.instance.init();
      await PlaylistStore.instance.init();
      await ResumeStore.instance.init();
      final local = await PlaylistStore.instance.create('Local', [PlaylistTrack(file, 'episode.mp4')]);
      await ResumeStore.instance.save(file, const Duration(seconds: 300), const Duration(seconds: 900));
      var account = 'account';
      Map<String, dynamic>? uploaded;
      var writes = 0;
      Completer<void>? gate, reached;
      var remote = SyncDocument('other');
      late PlaybackSync sync;
      final client = MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer private-token');
        expect(request.url.host, 'www.googleapis.com');
        if (request.url.path.endsWith('/about')) {
          return http.Response(
            jsonEncode({
              'user': {'permissionId': account, 'emailAddress': 'a@example.com'},
            }),
            200,
          );
        }
        if (request.url.path == '/drive/v3/files') {
          reached?.complete();
          if (gate != null) await gate.future;
          return http.Response(
            jsonEncode({
              'files': [
                {'id': 'remote', 'name': 'other-device'},
                if (uploaded != null) {'id': 'own', 'name': 'not-own-name'},
              ],
            }),
            200,
          );
        }
        if (request.url.path == '/drive/v3/files/remote') return http.Response(jsonEncode(remote.toJson()), 200);
        if (request.url.path == '/drive/v3/files/own') return http.Response(jsonEncode(uploaded), 200);
        if (request.method == 'POST') {
          final content = request.body
              .split('Content-Type: application/json; charset=UTF-8\r\n\r\n')
              .last
              .split('\r\n--')
              .first;
          uploaded = jsonDecode(content) as Map<String, dynamic>;
          expect(content, isNot(contains(root)));
          expect(content, isNot(contains('private-token')));
          writes++;
          return http.Response('{}', 200);
        }
        fail('Unexpected Google sync request: ${request.method} ${request.url.path}');
      });
      await PluginStore.instance.init();
      await PluginStore.instance.load(await File('plugins/sync.gdrive.js').readAsString());
      sync = PlaybackSync(clientFactory: () => client);
      await sync.init();
      addTearDown(sync.dispose);
      final key = SyncReferences.instance.portable(file)!;
      remote.change('playlist:remote', {
        'id': 'remote',
        'name': 'Remote',
        'tracks': [
          {'key': key, 'title': 'episode.mp4'},
        ],
      });
      remote.change('playlist:folder', {
        'id': 'folder',
        'name': 'Folder',
        'tracks': [
          {'key': key, 'title': 'Shared folder', 'isFolder': true},
        ],
      });
      remote.change('resume:$key', {
        'p': 100000,
        'd': 900000,
        'u': DateTime.now().millisecondsSinceEpoch + 1000,
        't': 'episode.mp4',
      });
      // Remote has a later logical edit, even though playback moved backwards.
      for (final record in remote.records.values) {
        record['time'] = DateTime.now().microsecondsSinceEpoch + 1000000;
      }
      await sync.syncNow();
      expect(PlaylistStore.instance.find(local), isNotNull);
      expect(PlaylistStore.instance.find('remote')!.tracks.single.key, file);
      expect(PlaylistStore.instance.find('folder')!.tracks.single.isFolder, true);
      expect(PlaylistStore.instance.find('folder')!.tracks.single.key, file);
      expect(ResumeStore.instance.get(file)!.position, const Duration(seconds: 100));
      expect(sync.lastSync, isNotNull);
      // Linking a local-only track after connecting must not drop it.
      final secondRoot = '$root-other';
      final secondFile = '$secondRoot${Platform.pathSeparator}new.mp4';
      final added = await PlaylistStore.instance.create('Newly linked', [
        PlaylistTrack(secondFile, 'New folder', isFolder: true),
      ]);
      await sync.bindReference(secondRoot, '다른 폴더');
      expect(PlaylistStore.instance.find(added)!.tracks.single.key, secondFile);
      expect(PlaylistStore.instance.find(added)!.tracks.single.isFolder, true);
      await PlaylistStore.instance.delete('remote');
      await ResumeStore.instance.remove(file);
      await sync.syncNow();
      expect(PlaylistStore.instance.find('remote'), null);
      expect(ResumeStore.instance.get(file), null);
      expect((uploaded!['records'] as Map)['playlist:remote']['value'], null);
      // Edits while Google is responding must survive merging the previous copy.
      gate = Completer<void>();
      reached = Completer<void>();
      final running = sync.syncNow();
      await reached.future;
      await PlaylistStore.instance.rename(local, 'Changed during sync');
      await ResumeStore.instance.save(file, const Duration(seconds: 40), const Duration(seconds: 900));
      gate.complete();
      await running;
      gate = null;
      reached = null;
      expect(PlaylistStore.instance.find(local)!.name, 'Changed during sync');
      expect(ResumeStore.instance.get(file)!.position, const Duration(seconds: 40));
      final before = writes;
      account = 'other-account';
      await expectLater(sync.syncNow(), throwsStateError);
      expect(writes, before);
      account = 'account';
      remote = SyncDocument('bad')..change('resume:https://example.com/token=secret', {'p': 0, 'd': 1, 'u': 1});
      await expectLater(sync.syncNow(), throwsFormatException);
      expect(writes, before);
      expect(PlaylistStore.instance.find(local)!.name, 'Changed during sync');
      await sync.disconnect();
      expect(await SecureStore.instance.readRequired('tok_sync-account'), null);
      expect(PlaylistStore.instance.find(local), isNotNull);
    },
  );
}
