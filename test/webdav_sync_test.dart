import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/plugins/plugin.dart';
import 'package:oplayer/core/plugins/plugin_compatibility.dart';
import 'package:oplayer/core/plugins/plugin_http.dart';
import 'package:oplayer/core/plugins/plugin_store.dart';
import 'package:oplayer/core/plugins/plugin_runtime.dart';
import 'package:oplayer/core/plugins/sync_storage.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/sources/cloud/cloud_sources.dart';
import 'package:oplayer/sources/server_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('WebDAV connects without Google, lists only sync files and shares JSON across connections', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await AppSettings.instance.init();
    final store = PluginStore.instance;
    await store.init();
    await store.load(await File('plugins/sync.webdav.js').readAsString());
    await store.setCredentials('sync.webdav', {
      'endpoint': 'https://nas.example/dav/sync',
      'username': 'user',
      'password': '비밀번호',
    });
    final docs = <String, Map<String, dynamic>>{};
    var denied = false;
    http.Client client() => MockClient((request) async {
      expect(request.url.origin, 'https://nas.example');
      expect(request.url.path, startsWith('/dav/sync/'));
      expect(request.followRedirects, false);
      expect(request.headers['Authorization'], 'Basic ${base64Encode(utf8.encode('user:비밀번호'))}');
      if (denied) return http.Response('Unauthorized', 401);
      if (request.method == 'PROPFIND') {
        expect(request.headers['Depth'], '1');
        String entry(String href, {bool folder = false, int status = 200}) =>
            '<d:response><d:href>$href</d:href><d:propstat><d:prop><d:resourcetype>'
            '${folder ? '<d:collection/>' : ''}</d:resourcetype></d:prop>'
            '<d:status>HTTP/1.1 $status OK</d:status></d:propstat></d:response>';
        return http.Response(
          '<d:multistatus xmlns:d="DAV:">'
          '${entry('/dav/sync/', folder: true)}'
          '${entry('/dav/sync/other.json')}'
          '${entry('/dav/sync/child/oplayer-sync-v1-hidden.json')}'
          '${entry('/dav/sync/oplayer-sync-v1-folder.json', folder: true)}'
          '${entry('/dav/sync/oplayer-sync-v1-denied.json', status: 403)}'
          '${entry('https://other.example/dav/sync/oplayer-sync-v1-external.json')}'
          '${docs.keys.map((name) => entry('/dav/sync/$name')).join()}'
          '</d:multistatus>',
          207,
        );
      }
      final name = request.url.pathSegments.last;
      if (request.method == 'PUT') {
        docs[name] = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('', 201);
      }
      expect(request.method, 'GET');
      return http.Response.bytes(utf8.encode(jsonEncode(docs[name])), 200);
    });
    final first = await http.runWithClient(
      () => connectCloudAccount(CloudProvider.plugin, pluginId: 'sync.webdav', saveAccount: false),
      client,
    );
    final api = PluginSyncStorage(first, clientFactory: client);
    addTearDown(api.close);
    final doc = {
      'version': 1,
      'records': {
        'playlist:one': {'name': '한글'},
      },
    };
    await api.write('deviceA', doc);
    final second = await http.runWithClient(
      () => connectCloudAccount(CloudProvider.plugin, pluginId: 'sync.webdav', saveAccount: false),
      client,
    );
    final peer = PluginSyncStorage(second, clientFactory: client);
    addTearDown(peer.close);
    expect((await api.account()).id, (await peer.account()).id);
    final files = await peer.files();
    expect(files.single.name, 'oplayer-sync-v1-deviceA.json');
    expect(await peer.read(files.single.id), doc);
    await peer.write('deviceB', {'version': 1, 'records': {}});
    expect((await api.files()).length, 2);
    await expectLater(peer.read('../private.json'), throwsStateError);
    denied = true;
    await expectLater(peer.files(), throwsStateError);
  });
  test('WebDAV permissions stay inside the user endpoint and old hosts reject it', () async {
    final plugin = OPlugin.parse(await File('plugins/sync.webdav.js').readAsString());
    const config = {'endpoint': 'https://nas.example/dav/sync'};
    expect(plugin.allowsConfigured('https://nas.example/dav/sync/a.json', config, auth: true), true);
    for (final url in ['https://nas.example/dav/private', 'https://evil.example/dav/sync/a.json']) {
      expect(plugin.allowsConfigured(url, config, auth: true), false);
    }
    await callPlugin(plugin, 'validate', {}, validateOnly: true);
    final oldHost = pluginHostFeatures('windows')..remove('webdavSync');
    expect((plugin.manifest['requiresHost'] as List).every(oldHost.contains), false);
    for (final method in ['syncRead', 'syncWrite']) {
      await expectLater(
        callPlugin(plugin, method, {'id': '../private.json', 'name': '../private.json'}, config: config),
        throwsStateError,
      );
    }
  });
  test('Basic credentials are resolved natively and cannot inject a username separator', () {
    final request = pluginHttpRequest(
      'PROPFIND',
      'https://nas.example/dav/',
      {
        'basicAuth': {
          'username': {r'$secret': 'user'},
          'password': {r'$secret': 'password'},
        },
      },
      {'user': '사용자', 'password': 'pass:word'},
    );
    expect(request.headers['Authorization'], 'Basic ${base64Encode(utf8.encode('사용자:pass:word'))}');
    expect(request.followRedirects, false);
    expect(
      () => pluginHttpRequest('PROPFIND', 'https://nas.example/dav/', {
        'basicAuth': {'username': 'wrong:name', 'password': 'password'},
      }, {}),
      throwsStateError,
    );
  });
}
