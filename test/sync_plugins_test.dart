import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/playback_sync.dart';
import 'package:oplayer/core/plugins/plugin.dart';
import 'package:oplayer/core/plugins/plugin_runtime.dart';
import 'package:oplayer/core/plugins/plugin_store.dart';
import 'package:oplayer/core/playlist_store.dart';
import 'package:oplayer/core/resume_store.dart';
import 'package:oplayer/core/resource_locks.dart';
import 'package:oplayer/core/secure_store.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/sources/server_store.dart';

OPlugin official(String id) => OPlugin.parse(File('plugins/sync.$id.js').readAsStringSync());
String fixture(String id) =>
    '// @oplayer ${jsonEncode({
      'api': 5,
      'id': id,
      'name': id,
      'version': '1',
      'kind': 'resource',
      'capabilities': ['sync'],
      'requiresHost': ['syncStorage'],
      'legacySyncKey': 'legacy',
      'hosts': <String>[],
      'auth': {'type': 'bearer'},
      'settings': [
        {'key': 'accessToken', 'label': 'Token', 'type': 'password', 'required': true},
      ],
    })}\nglobalThis.plugin={accountName(){return "account"},syncAccount(){return {id:"remote-account",name:"account"}},'
    'syncList(){return []},syncRead(){return {}},syncWrite(){return true}};';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('OneDrive app-folder sync paginates, reads signed URLs without auth and writes JSON', () async {
    final plugin = official('onedrive');
    var pages = 0, writes = 0;
    Future<Object?> request(String url, Map<String, dynamic> options) async {
      if (options['method'] == 'PUT') {
        writes++;
        expect(url, contains('/special/approot:/oplayer-sync-v1-device.json:/content'));
        expect(options['body'], {'version': 1, 'records': {}});
        return {'id': 'own'};
      }
      if (url.contains('download.1drv.com')) {
        expect(options['authenticated'], false);
        return {'version': 1, 'records': {}};
      }
      if (url.contains('/items/one?')) return {'@microsoft.graph.downloadUrl': 'https://download.1drv.com/doc'};
      pages++;
      return pages == 1
          ? {
              'value': [
                {'id': 'one', 'name': 'oplayer-sync-v1-a.json', 'file': {}},
                {'id': 'other', 'name': 'other.json', 'file': {}},
                {'id': 'folder', 'name': 'oplayer-sync-v1-folder.json', 'folder': {}},
              ],
              '@odata.nextLink': 'https://graph.microsoft.com/v1.0/next',
            }
          : {
              'value': [
                {'id': 'two', 'name': 'oplayer-sync-v1-b.json', 'file': {}},
              ],
            };
    }

    expect(await callPlugin(plugin, 'syncList', {}, request: request), [
      {'id': 'one', 'name': 'oplayer-sync-v1-a.json'},
      {'id': 'two', 'name': 'oplayer-sync-v1-b.json'},
    ]);
    expect(await callPlugin(plugin, 'syncRead', {'id': 'one'}, request: request), {'version': 1, 'records': {}});
    expect(
      await callPlugin(plugin, 'syncWrite', {
        'name': 'oplayer-sync-v1-device.json',
        'document': {'version': 1, 'records': {}},
      }, request: request),
      true,
    );
    expect(writes, 1);
  });
  test('Box reuses its folder, limits listing to sync files and uploads multipart versions', () async {
    final plugin = official('box');
    var uploads = 0;
    Future<Object?> request(String url, Map<String, dynamic> options) async {
      if (url == 'https://api.box.com/2.0/folders') {
        return {
          'status': 409,
          'body': jsonEncode({
            'context_info': {
              'conflicts': [
                {'id': 'folder', 'name': 'OPlayer Sync', 'type': 'folder'},
              ],
            },
          }),
        };
      }
      if (url.contains('/folders/folder/items')) {
        return {
          'entries': [
            {'id': 'one', 'type': 'file', 'name': 'oplayer-sync-v1-device.json'},
            {'id': 'other', 'type': 'file', 'name': 'other.json'},
          ],
        };
      }
      if (url.contains('/files/one/content') && options['response'] == 'redirect') {
        return {'url': 'https://dl.boxcloud.com/content'};
      }
      if (url.startsWith('https://dl.boxcloud.com/')) {
        expect(options['authenticated'], false);
        return {'version': 1, 'records': {}};
      }
      expect(
        url,
        uploads == 0
            ? 'https://upload.box.com/api/2.0/files/content'
            : 'https://upload.box.com/api/2.0/files/one/content',
      );
      final body = options['body'] as String;
      expect(body.indexOf('name="attributes"'), lessThan(body.indexOf('name="file"')));
      expect(body, contains('\r\nContent-Disposition:'));
      expect(body, contains('한글'));
      if (uploads == 0) expect(body, contains('"parent":{"id":"folder"}'));
      uploads++;
      return {
        'entries': [
          {'id': 'one'},
        ],
      };
    }

    expect(await callPlugin(plugin, 'syncList', {}, request: request), [
      {'id': 'one', 'name': 'oplayer-sync-v1-device.json'},
    ]);
    await callPlugin(plugin, 'syncRead', {'id': 'one'}, request: request);
    for (final id in [null, 'one']) {
      expect(
        await callPlugin(plugin, 'syncWrite', {
          'name': 'oplayer-sync-v1-device.json',
          'document': {'한글': true},
          if (id != null) 'id': id,
        }, request: request),
        true,
      );
    }
    expect(uploads, 2);
  });
  test(
    'arbitrary sync extensions can be selected; disable stops sync and uninstall cleans only provider data',
    () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(privacyChannel, (_) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(privacyChannel, null));
      await AppSettings.instance.init();
      await ResourceLocks.instance.init();
      await PlaylistStore.instance.init();
      await ResumeStore.instance.init();
      await ServerStore.instance.init();
      final store = PluginStore.instance;
      await store.init();
      for (final id in ['sync.custom', 'sync.another']) {
        await store.load(fixture(id));
        await store.setCredentials(id, {'accessToken': 'private'});
      }
      final migrationPrefs = await SharedPreferences.getInstance();
      await migrationPrefs.setString('legacy_sync_connection', jsonEncode({'id': 'remote-account'}));
      await migrationPrefs.setString(
        'legacy_sync_state_remote-account',
        jsonEncode({
          'document': {
            'version': 1,
            'records': {
              'playlist:previously-deleted': {'time': 1, 'device': 'old-device', 'value': null},
            },
          },
          'baseline': {},
        }),
      );
      await migrationPrefs.setBool('legacy_sync_auto_remote-account', false);
      await SecureStore.instance.writeRequired('legacy_sync_token_remote-account', 'old-token-never-forwarded');
      var sync = PlaybackSync();
      await sync.init();
      addTearDown(() => sync.dispose());
      final list = await PlaylistStore.instance.create('Keep local', []);
      await sync.selectProvider('sync.custom');
      await sync.connect();
      expect(sync.connected, true);
      expect(sync.automatic, false);
      expect(migrationPrefs.getString('legacy_sync_connection'), null);
      expect(await SecureStore.instance.readRequired('legacy_sync_token_remote-account'), null);
      final migrated = jsonDecode(migrationPrefs.getString('pluginSyncState:sync.custom:remote-account')!) as Map;
      expect((migrated['document'] as Map)['records'], contains('playlist:previously-deleted'));
      expect(ServerStore.instance.accounts, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      final saved = jsonDecode(prefs.getString('pluginSyncConnection:sync.custom')!) as Map;
      final token = CloudAccount.fromJson((saved['account'] as Map).cast<String, dynamic>()).tokenKey;
      expect(await SecureStore.instance.readRequired(token), isNotNull);
      sync.dispose();
      sync = PlaybackSync();
      await sync.init();
      expect(sync.providerId, 'sync.custom');
      expect(sync.connected, true);
      expect(sync.automatic, false);
      await store.setEnabled('sync.custom', false);
      expect(sync.available, false);
      await expectLater(sync.syncNow(), throwsStateError);
      await store.setEnabled('sync.custom', true);
      await sync.syncNow();
      await sync.selectProvider('sync.another');
      expect(sync.connected, false);
      expect(await SecureStore.instance.readRequired(token), null);
      await sync.connect();
      final second = jsonDecode(prefs.getString('pluginSyncConnection:sync.another')!) as Map;
      final secondToken = CloudAccount.fromJson((second['account'] as Map).cast<String, dynamic>()).tokenKey;
      await store.remove('sync.another');
      expect(sync.connected, false);
      expect(await SecureStore.instance.readRequired(secondToken), null);
      expect(prefs.getKeys().any((k) => k.startsWith('pluginSyncState:sync.another:')), false);
      expect(PlaylistStore.instance.find(list), isNotNull);
    },
  );
}
