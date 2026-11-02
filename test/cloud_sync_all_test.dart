import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:oplayer/core/plugins/plugin.dart';
import 'package:oplayer/core/plugins/plugin_runtime.dart';
import 'package:oplayer/sources/cloud/s3_credentials.dart';
import 'package:oplayer/sources/cloud/cloud_sources.dart';
import 'package:oplayer/sources/server_store.dart';
import 'package:oplayer/core/plugins/plugin_store.dart';
import 'package:oplayer/core/secure_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

OPlugin official(String id) => OPlugin.parse(File('plugins/sync.$id.js').readAsStringSync());
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Dropbox sync creates its folder, filters files and uploads UTF-8 JSON', () async {
    var uploads = 0;
    Future<Object?> request(String url, Map<String, dynamic> options) async {
      if (url.endsWith('create_folder_v2')) return {'status': 200, 'body': '{}'};
      if (url.endsWith('list_folder')) {
        return {
          'entries': [
            {
              '.tag': 'file',
              'name': 'oplayer-sync-v1-device.json',
              'path_lower': '/oplayer sync/oplayer-sync-v1-device.json',
            },
            {'.tag': 'file', 'name': 'other.json', 'path_lower': '/other.json'},
          ],
          'has_more': false,
        };
      }
      if (url.endsWith('/download')) {
        expect((options['headers'] as Map)['Dropbox-API-Arg'], contains('/oplayer sync/'));
        return {'version': 1, 'records': {}};
      }
      expect(url, 'https://content.dropboxapi.com/2/files/upload');
      expect(jsonDecode((options['headers'] as Map)['Dropbox-API-Arg'] as String)['mode'], 'overwrite');
      expect(jsonDecode(options['body'] as String), {'한글': true});
      uploads++;
      return {'id': 'id:one'};
    }

    final plugin = official('dropbox');
    final rows = await callPlugin(plugin, 'syncList', {}, request: request) as List;
    expect(rows, hasLength(1));
    await callPlugin(plugin, 'syncRead', {'id': rows.single['id']}, request: request);
    expect(
      await callPlugin(plugin, 'syncWrite', {
        'name': 'oplayer-sync-v1-device.json',
        'document': {'한글': true},
      }, request: request),
      true,
    );
    expect(uploads, 1);
  });
  test('S3 sync stays in its prefix and native PUT signing keeps keys private', () async {
    final plugin = official('s3');
    const config = {'bucketUrl': 'https://s3.example/bucket/', 'bucket': 'bucket', 'prefix': 'oplayer-sync/'};
    var writes = 0;
    Future<Object?> request(String url, Map<String, dynamic> options) async {
      if (options['method'] == 'PUT') {
        expect(url, 'https://s3.example/bucket/oplayer-sync/oplayer-sync-v1-device.json');
        expect(options['response'], 'headers');
        writes++;
        return {};
      }
      return {
        'name': 'ListBucketResult',
        'children': [
          {'name': 'EncodingType', 'text': 'url'},
          {'name': 'IsTruncated', 'text': 'false'},
          {
            'name': 'Contents',
            'children': [
              {'name': 'Key', 'text': 'oplayer-sync%2Foplayer-sync-v1-device.json'},
            ],
          },
          {
            'name': 'Contents',
            'children': [
              {'name': 'Key', 'text': 'outside%2Fother.json'},
            ],
          },
        ],
      };
    }

    expect(
      await callPlugin(
        plugin,
        'syncList',
        {},
        config: config,
        allowsRequest: (url) => url.startsWith(config['bucketUrl']!),
        request: request,
      ),
      [
        {'id': 'oplayer-sync/oplayer-sync-v1-device.json', 'name': 'oplayer-sync-v1-device.json'},
      ],
    );
    expect(
      await callPlugin(
        plugin,
        'syncWrite',
        {'name': 'oplayer-sync-v1-device.json', 'document': {}},
        config: config,
        allowsRequest: (url) => url.startsWith(config['bucketUrl']!),
        request: request,
      ),
      true,
    );
    await expectLater(
      callPlugin(
        plugin,
        'syncRead',
        {'id': 'outside/secret'},
        config: config,
        allowsRequest: (url) => url.startsWith(config['bucketUrl']!),
        request: request,
      ),
      throwsStateError,
    );
    expect(writes, 1);
    final c = S3Credentials({
      'endpoint': 'https://s3.example',
      'bucket': 'bucket',
      'region': 'us-east-1',
      'accessKeyId': 'access',
      'secretAccessKey': 'private',
    });
    final uri = Uri.parse('${config['bucketUrl']}oplayer-sync/test.json');
    final put = c.presign(uri, method: 'PUT', now: DateTime.utc(2026)), get = c.presign(uri, now: DateTime.utc(2026));
    expect(put.queryParameters['X-Amz-Signature'], isNot(get.queryParameters['X-Amz-Signature']));
    expect(put.toString(), isNot(contains('private')));
  });
  test('S3 sync passes through native authenticated HTTP PUT end to end', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final store = PluginStore.instance;
    await store.init();
    await store.load(await File('plugins/sync.s3.js').readAsString());
    final account = CloudAccount(id: 's3-sync', provider: CloudProvider.plugin, name: 'S3', pluginId: 'sync.s3');
    await SecureStore.instance.writeRequired(
      account.tokenKey,
      jsonEncode({
        'pluginId': 'sync.s3',
        'authType': 's3',
        'endpoint': 'https://s3.example',
        'bucket': 'bucket',
        'region': 'us-east-1',
        'accessKeyId': 'access',
        'secretAccessKey': 'private',
        'prefix': 'records/',
      }),
    );
    final source = CloudSource(account);
    addTearDown(source.close);
    var writes = 0;
    expect(
      await http.runWithClient(
        () => source.syncCall('syncWrite', {
          'name': 'oplayer-sync-v1-device.json',
          'document': {'한글': true},
        }),
        () => MockClient((request) async {
          expect(request.method, 'PUT');
          expect(request.url.path, '/bucket/records/oplayer-sync-v1-device.json');
          expect(request.url.queryParameters['X-Amz-Signature'], isNotEmpty);
          expect(request.headers.containsKey('Authorization'), false);
          expect(jsonDecode(utf8.decode(request.bodyBytes)), {'한글': true});
          writes++;
          return http.Response('', 200);
        }),
      ),
      true,
    );
    expect(writes, 1);
  });
  test('MYBOX counts UTF-8 upload bytes and does not forward PAT to signed storage URLs', () async {
    final plugin = official('mybox');
    var uploads = 0;
    Future<Object?> request(String url, Map<String, dynamic> options) async {
      if (url.contains('/folders/folder/resources')) {
        return {
          'resources': [
            {'type': 'file', 'name': 'oplayer-sync-v1-device.json', 'resourceId': 'file'},
          ],
        };
      }
      if (url.contains('/resources?')) {
        return {
          'resources': [
            {'type': 'folder', 'name': 'OPlayer Sync', 'resourceId': 'folder'},
          ],
        };
      }
      if (url.endsWith('/files/file/download')) return {'downloadUrl': 'https://storage.naver.com/download'};
      if (url.endsWith('/download')) {
        expect(options['authenticated'], false);
        return {'version': 1, 'records': {}};
      }
      if (url == 'https://open-api.mybox.naver.com/v1/drive/files') {
        final body = options['body'] as Map;
        expect(body['fileSize'], utf8.encode(jsonEncode({'한글': '✓'})).length);
        expect(body['isOverwrite'], true);
        expect(body['parentId'], 'folder');
        return {'uploadUrl': 'https://storage.naver.com/upload'};
      }
      expect(url, 'https://storage.naver.com/upload');
      expect(options['authenticated'], false);
      expect(options['body'], contains('name="Filedata"'));
      expect(options['body'], contains('한글'));
      uploads++;
      return {'resourceId': 'file'};
    }

    expect(await callPlugin(plugin, 'syncAccount', {}, request: request), {'id': 'folder', 'name': '네이버 MYBOX'});
    expect(await callPlugin(plugin, 'syncList', {}, request: request), [
      {'id': 'file', 'name': 'oplayer-sync-v1-device.json'},
    ]);
    await callPlugin(plugin, 'syncRead', {'id': 'file'}, request: request);
    expect(
      await callPlugin(plugin, 'syncWrite', {
        'name': 'oplayer-sync-v1-device.json',
        'document': {'한글': '✓'},
      }, request: request),
      true,
    );
    expect(uploads, 1);
  });
}
