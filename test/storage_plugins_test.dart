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
import 'package:oplayer/core/secure_store.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/sources/cloud/cloud_sources.dart';
import 'package:oplayer/sources/cloud/oauth.dart';
import 'package:oplayer/sources/cloud/s3_credentials.dart';
import 'package:oplayer/sources/server_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final store = PluginStore.instance;
  setUpAll(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await AppSettings.instance.init();
    await store.init();
    await ServerStore.instance.init();
    for (final id in ['s3', 'box', 'mybox']) {
      await store.load(await File('plugins/cloud.$id.js').readAsString());
    }
  });

  test(
    'Google Drive plugin receives the account registration and uses native authenticated listing and refresh',
    () async {
      const boundId = 'bound-drive.apps.googleusercontent.com';
      var script = await File('plugins/cloud.gdrive.js').readAsString();
      script +=
          '''
      const originalList = plugin.list;
      plugin.list = function(input) {
        if (OPlayer.config.clientId !== '$boundId') throw Error('Wrong account registration');
        if (OPlayer.config.accessToken || OPlayer.config.refreshToken || OPlayer.config.clientSecret ||
            OPlayer.app.googleOAuth.clientSecret) throw Error('Exposed credentials');
        return originalList(input);
      };
    ''';
      await store.load(script);
      await store.setOAuthClientId('cloud.gdrive', 'new-default.apps.googleusercontent.com');
      await SecureStore.instance.writeRequired(
        PluginStore.oauthSecretKey('cloud.gdrive', boundId),
        'drive-test-secret',
      );
      final account = CloudAccount(
        id: 'google-drive-test',
        provider: CloudProvider.gdrive,
        name: 'Drive',
        oauthClientId: boundId,
      );
      final source = cloudSourceFor(account);
      addTearDown(source.close);
      expect(source.tokens.client.scopes, ['https://www.googleapis.com/auth/drive.readonly']);
      await source.tokens.save(
        OAuthTokens(
          accessToken: 'old-drive-token',
          refreshToken: 'drive-refresh',
          expiry: DateTime.now().add(const Duration(hours: 1)),
        ),
      );
      var lists = 0, refreshes = 0;
      await http.runWithClient(
        () async {
          expect(await source.accountName(), 'drive@example.com');
          final rows = await source.list('root');
          expect(rows.map((r) => r.name), ['movie.mp4', 'subfolder']);
          expect(rows.first.path, 'video-id');
          expect(rows.last.isDir, true);
          final stream = await source.streamFor('video-id');
          expect(stream.url, 'https://www.googleapis.com/drive/v3/files/video-id?alt=media&supportsAllDrives=true');
          expect(stream.headers, {'Authorization': 'Bearer new-drive-token'});
          expect(lists, 3);
          expect(refreshes, 1);
        },
        () => MockClient((request) async {
          expect(request.followRedirects, false);
          if (request.url.host == 'oauth2.googleapis.com') {
            refreshes++;
            expect(request.bodyFields, {
              'client_id': boundId,
              'client_secret': 'drive-test-secret',
              'grant_type': 'refresh_token',
              'refresh_token': 'drive-refresh',
            });
            return http.Response('{"access_token":"new-drive-token","expires_in":3600}', 200);
          }
          expect(request.url.host, 'www.googleapis.com');
          if (request.url.path.endsWith('/about')) {
            expect(request.headers['Authorization'], 'Bearer old-drive-token');
            return http.Response('{"user":{"emailAddress":"drive@example.com"}}', 200);
          }
          lists++;
          expect(request.url.queryParameters['q'], "'root' in parents and trashed=false");
          if (lists == 1) {
            expect(request.headers['Authorization'], 'Bearer old-drive-token');
            return http.Response('{"error":"expired"}', 401);
          }
          expect(request.headers['Authorization'], 'Bearer new-drive-token');
          if (request.url.queryParameters['pageToken'] == null) {
            return http.Response(
              '{"nextPageToken":"next-page","files":[{"id":"video-id","name":"movie.mp4","mimeType":"video/mp4","size":"123"}]}',
              200,
            );
          }
          expect(request.url.queryParameters['pageToken'], 'next-page');
          return http.Response(
            '{"files":[{"id":"folder-id","name":"subfolder","mimeType":"application/vnd.google-apps.folder"}]}',
            200,
          );
        }),
      );
    },
  );

  test('official Google Drive search filters the current folder, escapes input and paginates', () async {
    final plugin = OPlugin.parse(await File('plugins/cloud.gdrive.js').readAsString());
    expect(plugin.manifest['canSearch'], true);
    var requests = 0;
    final results =
        await callPlugin(
              plugin,
              'search',
              {'query': "  한글 'test\\name  ", 'path': "folder'id"},
              request: (url, options) async {
                requests++;
                final uri = Uri.parse(url);
                expect(uri.host, 'www.googleapis.com');
                expect(
                  uri.queryParameters['q'],
                  "'folder\\'id' in parents and trashed=false and name contains '한글 \\'test\\\\name'",
                );
                if (requests == 1) {
                  return {
                    'nextPageToken': 'next/+page',
                    'files': [
                      {'id': 'one', 'name': 'one.mp4', 'mimeType': 'video/mp4'},
                    ],
                  };
                }
                expect(uri.queryParameters['pageToken'], 'next/+page');
                return {
                  'files': [
                    {'id': 'two', 'name': 'two.mp4', 'mimeType': 'video/mp4'},
                    {'id': 'doc', 'name': 'document', 'mimeType': 'application/vnd.google-apps.document'},
                  ],
                };
              },
            )
            as List;
    expect(results.map((r) => (r as Map)['path']), ['one', 'two']);
    expect(requests, 2);
    expect(
      await callPlugin(
        plugin,
        'search',
        {'query': '   ', 'path': 'root'},
        request: (_, __) async {
          fail('An empty query must not send a request');
        },
      ),
      isEmpty,
    );
  });

  test('SigV4 matches the published AWS example and encodes paths, queries and session tokens', () {
    // Public example credentials, NOT an account credential:
    // https://docs.aws.amazon.com/AmazonS3/latest/developerguide/sigv4-query-string-auth.html
    final values = <String, dynamic>{
      'endpoint': 'https://s3.amazonaws.com',
      'virtualHosted': true,
      'bucket': 'examplebucket',
      'region': 'us-east-1',
      'accessKeyId': 'AKIAIOSFODNN7EXAMPLE',
      'secretAccessKey': 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
    };
    final s3 = S3Credentials(values);
    final signed = s3.presign(
      Uri.parse('https://examplebucket.s3.amazonaws.com/test.txt'),
      now: DateTime.utc(2013, 5, 24),
      expires: 86400,
    );
    expect(
      signed.queryParameters['X-Amz-Signature'],
      'aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404',
    );
    final temporary = S3Credentials({...values, 'sessionToken': 'test /+token='});
    final url = temporary.presign(Uri.parse('${temporary.bucketUri}한글%20%2B%25.mp4?prefix=a%2Bb%20c&x=2&x=1'));
    expect(url.pathSegments.last, '한글 +%.mp4');
    expect(url.queryParameters['prefix'], 'a+b c');
    expect(url.queryParametersAll['x'], ['1', '2']);
    expect(url.queryParameters['X-Amz-Security-Token'], 'test /+token=');
    expect(url.toString(), isNot(contains('+')));
    expect(temporary.publicConfig.keys, unorderedEquals(['bucketUrl', 'bucket', 'listV1']));
    for (final bad in [
      'https://evil.example/test',
      'https://examplebucket.s3.amazonaws.com.evil/test',
      'https://user@examplebucket.s3.amazonaws.com/test',
      'file:///test',
    ]) {
      expect(s3.allows(bad), false);
      expect(() => s3.presign(Uri.parse(bad)), throwsFormatException);
    }
    final path = S3Credentials({...values, 'virtualHosted': false});
    expect(path.allows('https://s3.amazonaws.com/examplebucket-other/file'), false);
    expect(path.allows('https://s3.amazonaws.com/other/file'), false);
    expect(() => path.presign(path.bucketUri, method: 'DELETE'), throwsFormatException);
  });

  test(
    'S3 connects with secure account credentials, lists both API versions and renews ranged media requests',
    () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() => server.close(force: true));
      final media = List.generate(30, (i) => i);
      var heads = 0, gets = 0, listings = 0;
      server.listen((request) async {
        final q = request.uri.queryParameters;
        expect(q['X-Amz-Algorithm'], 'AWS4-HMAC-SHA256');
        expect(q['X-Amz-Signature'], matches(RegExp(r'^[a-f0-9]{64}$')));
        expect(request.headers.value('authorization'), null);
        if (request.uri.path == '/videos/') {
          listings++;
          final next = q['continuation-token'] != null || q['marker'] != null;
          request.response.headers.contentType = ContentType('application', 'xml');
          request.response.write('''<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <EncodingType>url</EncodingType><IsTruncated>${q['max-keys'] != '1' && !next}</IsTruncated>
          <CommonPrefixes><Prefix>folder/sub%20folder/</Prefix></CommonPrefixes>
          <Contents><Key>folder/${next ? 'next.mp3' : '%ED%95%9C%EA%B8%80%20%2B%25.mp4'}</Key><Size>30</Size><LastModified>2026-10-01T00:00:00Z</LastModified></Contents>
          <NextContinuationToken>next+token</NextContinuationToken><NextMarker>folder/marker%20key</NextMarker>
          </ListBucketResult>''');
        } else {
          expect(request.uri.pathSegments.last, '한글 +%.mp4');
          if (request.method == 'HEAD') {
            heads++;
            request.response.contentLength = media.length;
          } else {
            gets++;
            expect(request.headers.value('accept-encoding'), 'identity');
            final range = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(request.headers.value('range')!)!;
            final start = int.parse(range[1]!), end = int.parse(range[2]!);
            request.response.statusCode = 206;
            request.response.headers.set('Content-Range', 'bytes $start-$end/${media.length}');
            request.response.add(media.sublist(start, end + 1));
          }
        }
        await request.response.close();
      });
      final credentials = <String, dynamic>{
        'endpoint': 'http://127.0.0.1:${server.port}',
        'bucket': 'videos',
        'region': 'us-east-1',
        'accessKeyId': 'test-access',
        'secretAccessKey': 'test-secret',
        'sessionToken': 'test-session',
      };
      await store.setCredentials('cloud.s3', credentials);
      final account = await connectCloudAccount(CloudProvider.plugin, pluginId: 'cloud.s3');
      expect(account.name, 'videos');
      expect(jsonEncode(account.toJson()), isNot(contains('test-secret')));
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        expect(jsonEncode(prefs.get(key)), isNot(contains('test-secret')));
        expect(jsonEncode(prefs.get(key)), isNot(contains('test-session')));
      }
      final stored = jsonDecode((await SecureStore.instance.readRequired(account.tokenKey))!) as Map;
      expect(stored['secretAccessKey'], 'test-secret');
      await store.setCredentials('cloud.s3', {
        ...credentials,
        'bucket': 'another-bucket',
        'secretAccessKey': 'changed-secret',
      });
      final source = cloudSourceFor(account);
      addTearDown(source.close);
      final rows = await source.list('folder/');
      expect(rows.map((r) => r.name), ['sub folder', '한글 +%.mp4', 'next.mp3']);
      final local = await source.streamFor('folder/한글 +%.mp4');
      expect(local.headers, null);
      expect(local.url, startsWith('http://127.0.0.1:'));
      expect(local.url, isNot(contains('X-Amz')));
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      for (final pair in [(0, 9), (20, 29)]) {
        final req = await client.getUrl(Uri.parse(local.url));
        req.headers.set('Range', 'bytes=${pair.$1}-${pair.$2}');
        final res = await req.close();
        expect(res.statusCode, 206);
        expect(await res.expand((v) => v).toList(), media.sublist(pair.$1, pair.$2 + 1));
      }
      expect(gets, 2);
      expect(heads, 1);
      expect(listings, 3);
      await source.close();
      final removed = await client.getUrl(Uri.parse(local.url));
      expect((await removed.close()).statusCode, 404);
      final v1Account = CloudAccount(
        id: 's3-v1-test',
        provider: CloudProvider.plugin,
        name: 'S3 V1',
        pluginId: 'cloud.s3',
      );
      await SecureStore.instance.writeRequired(
        v1Account.tokenKey,
        jsonEncode({...credentials, 'listV1': true, 'authType': 's3', 'pluginId': 'cloud.s3'}),
      );
      final v1 = cloudSourceFor(v1Account);
      addTearDown(v1.close);
      expect((await v1.list('folder/')).length, 3);
      await store.setEnabled('cloud.s3', false);
      await expectLater(v1.list('folder/'), throwsStateError);
      await store.setEnabled('cloud.s3', true);
      await ServerStore.instance.removeAccount(account);
      expect(await SecureStore.instance.readRequired(account.tokenKey), null);
    },
  );

  test('MYBOX PAT stays native, supports cursor pagination and returns refreshable private media', () async {
    await store.setCredentials('cloud.mybox', {'accessToken': 'test-personal-token'});
    await http.runWithClient(
      () async {
        final account = await connectCloudAccount(CloudProvider.plugin, pluginId: 'cloud.mybox');
        final source = cloudSourceFor(account);
        addTearDown(source.close);
        expect(account.name, '네이버 MYBOX');
        final entries = await source.list('folder id');
        expect(entries.map((e) => e.name), ['subfolder', 'movie.mp4']);
        expect(entries.first.isDir, true);
        final stream = await source.streamFor('file id');
        expect(stream.url, startsWith('http://127.0.0.1:'));
        expect(stream.url, isNot(contains('test-personal-token')));
        await expectLater(source.getJson('https://open-api.mybox.naver.com.evil/'), throwsStateError);
        await ServerStore.instance.removeAccount(account);
        await expectLater(source.list('root'), throwsStateError);
      },
      () => MockClient((request) async {
        expect(request.url.host, 'open-api.mybox.naver.com');
        expect(request.headers['Authorization'], 'Bearer test-personal-token');
        expect(request.followRedirects, false);
        final path = request.url.path;
        if (path.endsWith('/storage')) return http.Response('{}', 200);
        if (path.contains('/folders/')) {
          final next = request.url.queryParameters['cursor'] != null;
          return http.Response(
            jsonEncode({
              'resources': [
                {
                  'name': next ? 'movie.mp4' : 'subfolder',
                  'resourceId': next ? 'file id' : 'child',
                  'type': next ? 'file' : 'folder',
                  'size': 30,
                },
              ],
              'responseMetaData': {if (!next) 'nextCursor': 'cursor +/'},
            }),
            200,
          );
        }
        if (path.endsWith('/download')) {
          return http.Response('{"downloadUrl":"https://storage.example/one-use","expiresIn":600}', 200);
        }
        return http.Response('{"size":30,"name":"movie.mp4"}', 200);
      }),
    );
  });

  test('Box uses a bound secure OAuth secret, refreshes tokens and handles markers/download redirects', () async {
    const clientId = 'box-test-client';
    await store.setOAuthClientId('cloud.box', clientId);
    await SecureStore.instance.writeRequired(PluginStore.oauthSecretKey('cloud.box', clientId), 'test-box-secret');
    final account = CloudAccount(
      id: 'box-test-account',
      provider: CloudProvider.plugin,
      name: 'Box',
      pluginId: 'cloud.box',
      oauthClientId: clientId,
    );
    final source = cloudSourceFor(account);
    addTearDown(source.close);
    await source.tokens.save(
      OAuthTokens(
        accessToken: 'old-token',
        refreshToken: 'test-refresh',
        expiry: DateTime.now().add(const Duration(hours: 1)),
      ),
    );
    final client = oauthClientFor(CloudProvider.plugin, pluginId: 'cloud.box', clientId: clientId);
    expect(client.usePkce, false);
    expect(client.loopbackOnMobile, true);
    expect(client.redirectUri, 'http://localhost:53682/callback');
    var first = true, apiCalls = 0, refreshes = 0, redirects = 0;
    await http.runWithClient(
      () async {
        final rows = await source.list('0');
        expect(rows.map((r) => r.name), ['movie.mp4', 'subfolder']);
        final stream = await source.streamFor('file-id');
        expect(stream.headers, null);
        expect(stream.url, startsWith('http://127.0.0.1:'));
        expect(refreshes, 1);
        expect(redirects, 1);
        expect(apiCalls, 3);
      },
      () => MockClient((request) async {
        expect(request.url.host, 'api.box.com');
        expect(request.followRedirects, false);
        if (request.url.path == '/oauth2/token') {
          refreshes++;
          final body = Uri.splitQueryString(request.body);
          expect(body['client_secret'], 'test-box-secret');
          expect(body['client_id'], clientId);
          expect(body['refresh_token'], 'test-refresh');
          return http.Response('{"access_token":"fresh-token","refresh_token":"rotated-token","expires_in":3600}', 200);
        }
        if (first) {
          first = false;
          return http.Response('{"error":"expired"}', 401);
        }
        expect(request.headers['Authorization'], 'Bearer fresh-token');
        if (request.url.path.endsWith('/items')) {
          apiCalls++;
          final next = request.url.queryParameters['marker'] != null;
          return http.Response(
            jsonEncode({
              'entries': [
                {
                  'name': next ? 'subfolder' : 'movie.mp4',
                  'id': next ? 'folder-id' : 'file-id',
                  'type': next ? 'folder' : 'file',
                },
              ],
              if (!next) 'next_marker': 'marker +/',
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/content')) {
          redirects++;
          return http.Response('', 302, headers: {'location': 'https://dl.boxcloud.com/private-download'});
        }
        apiCalls++;
        return http.Response('{"size":30,"name":"movie.mp4"}', 200);
      }),
    );
  });

  test('API 2 rejects unsupported auth and a script cannot leave its configured S3 bucket', () async {
    final p = store.installed['cloud.s3']!;
    var sent = false;
    final invalid = p.source.replaceFirst(
      'async accountName() {',
      'async accountName() { return OPlayer.request("https://other.example/private");',
    );
    final s3 = S3Credentials({
      'endpoint': 'https://s3.example',
      'bucket': 'private',
      'region': 'auto',
      'accessKeyId': 'test-id',
      'secretAccessKey': 'test-secret',
    });
    await expectLater(
      callPlugin(
        OPlugin.parse(invalid),
        'accountName',
        {},
        config: s3.publicConfig,
        allowsRequest: s3.allows,
        request: (_, __) async {
          sent = true;
          return {};
        },
      ),
      throwsStateError,
    );
    expect(sent, false);
    expect(() => OPlugin.parse(p.source.replaceFirst('"type":"s3"', '"type":"unknown"')), throwsFormatException);
    expect(() => OPlugin.parse(p.source.replaceFirst('"api":4', '"api":1')), throwsFormatException);
  });
}
