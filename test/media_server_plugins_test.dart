import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/plugins/plugin.dart';
import 'package:oplayer/core/plugins/plugin_runtime.dart';
import 'package:oplayer/core/plugins/plugin_store.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/core/secure_store.dart';
import 'package:oplayer/sources/cloud/cloud_sources.dart';
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
    for (final id in ['jellyfin', 'peertube']) {
      await store.load(await File('plugins/resource.$id.js').readAsString());
    }
  });

  http.Response reply(Object value, [int status = 200]) =>
      http.Response(jsonEncode(value), status, headers: {'content-type': 'application/json; charset=utf-8'});

  Future<void> noPublicSecrets(String token) async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys()) {
      expect(jsonEncode(prefs.get(key)), isNot(contains(token)), reason: key);
    }
  }

  test('Jellyfin connects, paginates folders, searches and creates authenticated video and audio URLs', () async {
    await store.setCredentials('resource.jellyfin', {
      'endpoint': 'https://media.example/jellyfin/',
      'username': 'viewer',
      'password': 'jf-password',
      'deviceId': 'phone',
    });
    var logins = 0, pages = 0;
    await http.runWithClient(
      () async {
        final account = await connectCloudAccount(CloudProvider.plugin, pluginId: 'resource.jellyfin');
        final source = cloudSourceFor(account);
        addTearDown(source.close);
        expect(account.name, 'Jellyfin · Viewer');
        expect((await source.list('root')).single.path, 'folder:abc');
        final files = await source.list('folder:abc');
        expect(files.map((f) => f.path), ['video:def', 'audio:fed']);
        expect(files.map((f) => f.name), ['Film.mkv', 'Song.flac']);
        expect(pages, 2);
        final found = await source.search('  한글 & +  ', path: 'folder:abc');
        expect(found.single.name, 'Found.mp4');
        for (final path in ['video:def', 'audio:fed']) {
          final stream = await source.streamFor(path);
          final uri = Uri.parse(stream.url);
          expect(uri.path, '/jellyfin/${path.startsWith('video') ? 'Videos/def' : 'Audio/fed'}/stream');
          expect(uri.queryParameters['api_key'], 'jf-token-$logins');
          expect(uri.queryParameters['MediaSourceId'], 'source-id');
          expect(uri.queryParameters['Static'], 'true');
          expect(stream.headers, isNull);
        }
        expect(logins, 3);
        expect(await source.accountName(), 'Jellyfin · Viewer');
        expect(logins, 4); // A stream login may invalidate the earlier listing session.
        final state = jsonDecode((await SecureStore.instance.readRequired(account.tokenKey))!) as Map;
        expect(state['sessionToken'], 'jf-token-4');
        expect(store.publicSettings(store.installed['resource.jellyfin']!).containsKey('password'), false);
        await noPublicSecrets('jf-password');
        await noPublicSecrets('jf-token-1');
      },
      () => MockClient((request) async {
        expect(request.url.origin, 'https://media.example');
        expect(request.url.path, startsWith('/jellyfin/'));
        expect(request.followRedirects, false);
        if (request.url.path.endsWith('/AuthenticateByName')) {
          logins++;
          expect(jsonDecode(request.body), {'Username': 'viewer', 'Pw': 'jf-password'});
          expect(request.headers['Authorization'], startsWith('MediaBrowser Client="OPlayer"'));
          return reply({
            'AccessToken': 'jf-token-$logins',
            'User': {'Id': 'aaa'},
          });
        }
        expect(request.headers['X-Emby-Token'], startsWith('jf-token-'));
        if (request.url.path.endsWith('/Users/Me')) {
          if (logins == 3 && request.headers['X-Emby-Token'] == 'jf-token-1') return reply({'error': 'expired'}, 401);
          return reply({'Id': 'aaa', 'Name': 'Viewer'});
        }
        if (request.url.path.endsWith('/Views')) {
          return reply({
            'Items': [
              {'Id': 'abc', 'Name': 'Movies', 'IsFolder': true},
            ],
          });
        }
        if (request.url.path == '/jellyfin/Items') {
          expect(request.url.queryParameters['UserId'], 'aaa');
          expect(request.url.queryParameters['ParentId'], 'abc');
          if (request.url.queryParameters.containsKey('SearchTerm')) {
            expect(request.url.queryParameters['SearchTerm'], '한글 & +');
            expect(request.url.queryParameters['Recursive'], 'true');
            return reply({
              'Items': [
                {'Id': 'def', 'Name': 'Found', 'MediaType': 'Video', 'Container': 'mp4'},
              ],
              'TotalRecordCount': 1,
            });
          }
          pages++;
          expect(request.url.queryParameters['StartIndex'], '${pages - 1}');
          return reply({
            'Items': [
              pages == 1
                  ? {'Id': 'def', 'Name': 'Film', 'MediaType': 'Video', 'Container': 'mkv'}
                  : {'Id': 'fed', 'Name': 'Song', 'MediaType': 'Audio', 'Container': 'flac'},
            ],
            'TotalRecordCount': 2,
          });
        }
        return reply({
          'Name': 'Media',
          'MediaSources': [
            {'Id': 'source-id', 'Size': 123},
          ],
        });
      }),
    );
  });

  for (final login in [false, true]) {
    test(
      'PeerTube ${login ? 'login refresh and private HLS' : 'anonymous public video'} uses only plugin APIs',
      () async {
        await store.setCredentials('resource.peertube', {
          'endpoint': 'https://tube.example',
          'username': login ? 'viewer' : '',
          'password': login ? 'pt-password' : '',
        });
        var tokenCalls = 0, listings = 0;
        await http.runWithClient(
          () async {
            final account = await connectCloudAccount(CloudProvider.plugin, pluginId: 'resource.peertube');
            final source = cloudSourceFor(account);
            addTearDown(source.close);
            final files = await source.list('root');
            expect(files.last.path, 'video-id');
            if (login) expect(files.first.path, 'mine');
            final search = await source.search('한글 & +', path: 'root');
            expect(search.single.name, 'Result.mp4');
            if (login) expect((await source.search('example', path: 'mine')).single.path, 'video-id');
            final stream = await source.streamFor('video-id');
            expect(stream.headers, isNull);
            if (login) {
              expect(Uri.parse(stream.url).queryParameters, {
                'videoFileToken': 'short-lived',
                'reinjectVideoFileToken': 'true',
              });
              expect(tokenCalls, 2);
              final state = jsonDecode((await SecureStore.instance.readRequired(account.tokenKey))!) as Map;
              expect(state['sessionToken'], 'pt-token-2');
              await noPublicSecrets('pt-token-2');
              await noPublicSecrets('pt-password');
            } else {
              expect(stream.url, 'https://cdn.example/video-high.mp4');
              expect(tokenCalls, 0);
            }
          },
          () => MockClient((request) async {
            expect(request.url.origin, 'https://tube.example');
            final path = request.url.path;
            if (path.endsWith('/oauth-clients/local')) {
              return reply({'client_id': 'local-client', 'client_secret': 'local-secret'});
            }
            if (path.endsWith('/users/token')) {
              tokenCalls++;
              if (tokenCalls == 1) {
                expect(request.bodyFields['password'], 'pt-password');
              } else {
                expect(request.bodyFields['refresh_token'], 'refresh-1');
              }
              return reply({'access_token': 'pt-token-$tokenCalls', 'refresh_token': 'refresh-$tokenCalls'});
            }
            if (login) {
              expect(request.headers['Authorization'], 'Bearer pt-token-$tokenCalls');
            } else {
              expect(request.headers.containsKey('Authorization'), false);
            }
            if (path.endsWith('/users/me')) return reply({'username': 'viewer'});
            if (path.endsWith('/config')) {
              return reply({
                'instance': {'name': 'Public tube'},
              });
            }
            if (path.endsWith('/search/videos')) {
              expect(request.url.queryParameters['search'], '한글 & +');
              return reply({
                'total': 1,
                'data': [
                  {'uuid': 'search-id', 'name': 'Result'},
                ],
              });
            }
            if (path.endsWith('/videos')) {
              listings++;
              if (login && listings == 1) return reply({'error': 'expired'}, 401);
              return reply({
                'total': 1,
                'data': [
                  {'uuid': 'video-id', 'name': 'Example'},
                ],
              });
            }
            if (path.endsWith('/token')) {
              return reply({
                'files': {'token': 'short-lived'},
              });
            }
            return reply({
              'privacy': {'id': login ? 3 : 1},
              'files': login
                  ? []
                  : [
                      {
                        'fileUrl': 'https://cdn.example/video-low.mp4',
                        'resolution': {'id': 360},
                      },
                      {
                        'fileUrl': 'https://cdn.example/video-high.mp4',
                        'resolution': {'id': 1080},
                      },
                    ],
              'streamingPlaylists': [
                {'playlistUrl': 'https://tube.example/static/private/master.m3u8'},
              ],
            });
          }),
        );
      },
    );
  }

  test('both plugins reject invalid settings and keep credentials inside the configured server', () async {
    for (final id in ['jellyfin', 'peertube']) {
      final plugin = OPlugin.parse(await File('plugins/resource.$id.js').readAsString());
      await callPlugin(plugin, 'validate', {}, validateOnly: true);
      final config = {'endpoint': 'https://server.example/base', 'username': 'user'};
      expect(plugin.allowsConfigured('https://server.example/base/api', config, auth: true), true);
      expect(plugin.allowsConfigured('https://server.example/base-other', config, auth: true), false);
      expect(plugin.allowsConfigured('https://evil.example/base/api', config, auth: true), false);
      expect(
        await callPlugin(plugin, 'validateSettings', {}, config: {'endpoint': 'http://server.example'}),
        isNotNull,
      );
      await expectLater(callPlugin(plugin, 'stream', {'path': '../../escape'}, config: config), throwsStateError);
    }
  });
}
