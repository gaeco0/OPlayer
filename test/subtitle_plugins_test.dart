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
import 'package:oplayer/core/plugins/subtitle_plugins.dart';
import 'package:oplayer/features/web/site_plugins.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final store = PluginStore.instance;
  late OPlugin provider;
  late Directory temp;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await store.init();
    await store.load(await File('plugins/subtitle.opensubtitles.js').readAsString());
    provider = store.installed['subtitle.opensubtitles']!;
    await store.setCredentials(provider.id, {
      'apiKey': 'test-key',
      'username': 'test-user',
      'password': 'test-password',
      'language': 'ko',
    });
  });
  setUp(() => temp = Directory.systemTemp.createTempSync('oplayer-subtitles-test-'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('subtitle hooks require API 4 and do not inject into websites', () async {
    expect(provider.subtitle, true);
    expect(provider.site, false);
    expect(provider.cloud, false);
    expect(() => OPlugin.parse(provider.source.replaceFirst('"api":4', '"api":3')), throwsFormatException);
    await callPlugin(provider, 'validate', {}, validateOnly: true);
    final invalid = provider.source.replaceFirst('async searchSubtitles(', 'async wrongSearch(');
    await expectLater(callPlugin(OPlugin.parse(invalid), 'validate', {}, validateOnly: true), throwsStateError);
    expect(pluginContentBlockers(), isEmpty);
    expect(blockedBySitePlugin('https://api.opensubtitles.com', 'https://api.opensubtitles.com'), false);
  });

  test('OpenSubtitles uses file IDs, VIP login host and no API credentials on subtitle CDN', () async {
    final requests = <http.Request>[];
    final service = SubtitlePlugins(
      store,
      clientFactory: () => MockClient((r) async {
        requests.add(r);
        if (r.url.host == 'dl.opensubtitles.com') {
          expect(r.headers.containsKey('api-key'), false);
          expect(r.headers.containsKey('authorization'), false);
          return http.Response(
            '1\n00:00:01,000 --> 00:00:02,000\n테스트\n',
            200,
            headers: {'content-type': 'application/x-subrip; charset=utf-8'},
          );
        }
        expect(r.headers['api-key'], 'test-key');
        if (r.url.path.endsWith('/subtitles')) {
          expect(r.url.queryParameters['query'], 'example s01e02');
          expect(r.url.queryParameters['languages'], 'ko');
          expect(r.url.queryParameters['page'], '2');
          return http.Response(
            jsonEncode({
              'page': 2,
              'total_pages': 3,
              'data': [
                {
                  'id': 'not-the-file-id',
                  'attributes': {
                    'language': 'ko',
                    'release': 'Example',
                    'files': [
                      {'file_id': 123, 'file_name': 'Example.ko.srt'},
                      {'file_id': 124, 'file_name': 'Example.part2.srt'},
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }
        if (r.url.path.endsWith('/login')) {
          expect(jsonDecode(r.body), {'username': 'test-user', 'password': 'test-password'});
          return http.Response(jsonEncode({'token': 'mock-jwt', 'base_url': 'vip-api.opensubtitles.com'}), 200);
        }
        expect(r.url.host, 'vip-api.opensubtitles.com');
        expect(r.headers['authorization'], 'Bearer mock-jwt');
        expect(jsonDecode(r.body)['file_id'], 123);
        return http.Response(
          jsonEncode({'link': 'https://dl.opensubtitles.com/download/test', 'file_name': 'Example.srt'}),
          200,
        );
      }),
    );
    final results = await service.search(provider, 'Example S01E02', 'ko', page: 2);
    expect(results.items.map((v) => v['id']), ['123', '124']);
    expect(results.totalPages, 3);
    final file = await service.download(provider, results.items.first, temp);
    expect(await file.readAsString(), contains('테스트'));
    expect(file.path, endsWith('.srt'));
    expect(requests.length, 4);
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys()) {
      expect(jsonEncode(prefs.get(key)), isNot(contains('test-key')));
      expect(jsonEncode(prefs.get(key)), isNot(contains('test-password')));
    }
  });

  test('OpenSubtitles allows its subdomains, upgrades HTTP links and follows declared CDN redirects', () async {
    expect(provider.hosts, containsAll(['*.opensubtitles.org', '*.opensubtitles.com']));
    expect(provider.allows('https://dl.opensubtitles.org/sub'), true);
    expect(provider.allows('https://dl.opensubtitles.org/sub', auth: true), false);
    expect(provider.allows('https://cdn.opensubtitles.com/sub', auth: true), false);
    expect(provider.allows('https://dl.opensubtitles.org.evil.example/sub'), false);
    expect(provider.allows('https://dl.opensubtitles.com.evil.example/sub'), false);
    expect(provider.allows('https://user@dl.opensubtitles.org/sub'), false);
    for (final link in [
      'https://dl.opensubtitles.org/sub?token=signed%2Fvalue&name=a+b',
      'http://dl.opensubtitles.org/sub?token=signed%2Fvalue&name=a+b',
      'http://dl.opensubtitles.com:80/sub?token=signed%2Fvalue&name=a+b',
      'https://dl.opensubtitles.com/redirect',
      'https://vip-dl.opensubtitles.com/sub?token=signed%2Fvalue&name=a+b',
      'http://cdn.eu.opensubtitles.org:80/sub?token=signed%2Fvalue&name=a+b',
    ]) {
      var cdnRequests = 0;
      final service = SubtitlePlugins(
        store,
        clientFactory: () => MockClient((r) async {
          if (r.url.path.endsWith('/login')) return http.Response('{"token":"test-token"}', 200);
          if (r.url.path == '/api/v1/download') return http.Response(jsonEncode({'link': link}), 200);
          cdnRequests++;
          expect(r.url.scheme, 'https');
          expect(r.url.port, 443);
          expect(provider.allows(r.url.toString()), true);
          expect(r.headers.containsKey('api-key'), false);
          expect(r.headers.containsKey('authorization'), false);
          if (r.url.path == '/redirect') {
            return http.Response('', 302, headers: {'location': 'https://dl.opensubtitles.org/sub'});
          }
          if (r.url.hasQuery) expect(r.url.query, 'token=signed%2Fvalue&name=a+b');
          return http.Response('1\n00:00:00,000 --> 00:00:01,000\nSubtitle\n', 200);
        }),
      );
      final file = await service.download(provider, {
        'id': '42',
        'data': {'fileId': 42},
      }, temp);
      expect(await file.readAsString(), contains('Subtitle'));
      expect(cdnRequests, link.endsWith('/redirect') ? 2 : 1);
    }
  });

  test('API-key-only settings search and download without login; canonical GET redirects are followed', () async {
    await store.setCredentials(provider.id, {'apiKey': 'test-key'});
    addTearDown(
      () => store.setCredentials(provider.id, {
        'apiKey': 'test-key',
        'username': 'test-user',
        'password': 'test-password',
        'language': 'ko',
      }),
    );
    final requests = <http.Request>[];
    final service = SubtitlePlugins(
      store,
      clientFactory: () => MockClient((r) async {
        requests.add(r);
        expect(r.headers.containsKey('authorization'), false);
        expect(r.url.path.endsWith('/login'), false);
        if (r.url.host == 'dl.opensubtitles.com') {
          return http.Response('1\n00:00:00,000 --> 00:00:01,000\nAnonymous\n', 200);
        }
        expect(r.headers['api-key'], 'test-key');
        if (r.url.path.endsWith('/subtitles')) {
          expect(r.url.queryParameters['query'], 'example movie');
          expect(r.url.query, contains('query=example+movie'));
          if (!r.url.queryParameters.containsKey('canonical')) {
            return http.Response('', 301, headers: {'location': '/api/v1/subtitles?canonical=1&query=example+movie'});
          }
          return http.Response(
            jsonEncode({
              'data': [
                {
                  'attributes': {
                    'files': [
                      {'file_id': 42, 'file_name': 'Example.srt'},
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }
        expect(r.url.path, '/api/v1/download');
        expect(r.method, 'POST');
        expect(jsonDecode(r.body)['file_id'], 42);
        return http.Response(jsonEncode({'link': 'https://dl.opensubtitles.com/download/anonymous'}), 200);
      }),
    );
    final results = await service.search(provider, 'Example Movie', 'ko');
    final file = await service.download(provider, results.items.first, temp);
    expect(await file.readAsString(), contains('Anonymous'));
    expect(requests.length, 4);
    expect(
      provider.settings.where((f) => ['username', 'password'].contains(f['key'])).every((f) => f['required'] != true),
      true,
    );
  });

  test('failed account login never falls back to anonymous quota or repeats a download POST', () async {
    var calls = 0;
    final failedLogin = SubtitlePlugins(
      store,
      clientFactory: () => MockClient((r) async {
        calls++;
        expect(r.url.path, '/api/v1/login');
        return http.Response('{}', 401);
      }),
    );
    await expectLater(
      failedLogin.download(provider, {
        'data': {'fileId': 42},
      }, temp),
      throwsA(predicate((e) => '$e'.contains('계정 인증'))),
    );
    expect(calls, 1);
    await store.setCredentials(provider.id, {'apiKey': 'test-key'});
    addTearDown(
      () => store.setCredentials(provider.id, {
        'apiKey': 'test-key',
        'username': 'test-user',
        'password': 'test-password',
        'language': 'ko',
      }),
    );
    final redirectedPost = SubtitlePlugins(
      store,
      clientFactory: () => MockClient((r) async {
        calls++;
        expect(r.url.path, '/api/v1/download');
        return http.Response('', 307, headers: {'location': '/api/v1/download'});
      }),
    );
    await expectLater(
      redirectedPost.download(provider, {
        'data': {'fileId': 42},
      }, temp),
      throwsStateError,
    );
    expect(calls, 2);
  });

  test('canonical search redirects cannot forward API credentials to another origin', () async {
    var calls = 0;
    final service = SubtitlePlugins(
      store,
      clientFactory: () => MockClient((r) async {
        calls++;
        return http.Response('', 301, headers: {'location': 'https://dl.opensubtitles.com/leak'});
      }),
    );
    await expectLater(service.search(provider, 'Movie', 'ko'), throwsStateError);
    expect(calls, 1);
  });

  Future<OPlugin> custom(String download, {String search = "return {items:[],totalPages:1};"}) async {
    final source =
        '// @oplayer ${jsonEncode({
          'api': 4,
          'id': 'subtitle.custom',
          'name': 'Custom',
          'version': '1',
          'kind': 'subtitle',
          'hosts': ['provider.example', 'cdn.example'],
          'authHosts': ['provider.example'],
        })}\nglobalThis.plugin={searchSubtitles(){ $search },downloadSubtitle(){ $download }};';
    await store.load(source);
    await store.setCredentials('subtitle.custom', {'apiKey': 'test-key'});
    return store.installed['subtitle.custom']!;
  }

  test('unknown providers use the common SDK; redirects strip all headers across origins', () async {
    final p = await custom(
      "return {url:'https://provider.example/sub',headers:{Authorization:OPlayer.secret('apiKey')},format:'srt'};",
    );
    var calls = 0;
    final service = SubtitlePlugins(
      store,
      clientFactory: () => MockClient((r) async {
        calls++;
        if (r.url.host == 'provider.example') {
          expect(r.headers['authorization'], 'test-key');
          return http.Response('', 302, headers: {'location': 'https://cdn.example/sub'});
        }
        expect(r.headers.containsKey('authorization'), false);
        return http.Response('1\n00:00:00,000 --> 00:00:01,000\nSubtitle\n', 200);
      }),
    );
    final file = await service.download(p, {'id': 'a', 'title': 'Test'}, temp);
    expect(file.existsSync(), true);
    expect(calls, 2);
  });

  test('undeclared downloads, redirects to undeclared hosts and disabled providers are rejected', () async {
    var p = await custom("return {url:'https://outside.example/sub'};");
    var calls = 0;
    final service = SubtitlePlugins(
      store,
      clientFactory: () => MockClient((r) async {
        calls++;
        return http.Response('', 302, headers: {'location': 'https://outside.example/sub'});
      }),
    );
    await expectLater(service.download(p, {'id': 'a'}, temp), throwsStateError);
    expect(calls, 0);
    p = await custom("return {url:'https://provider.example/sub'};");
    await expectLater(service.download(p, {'id': 'a'}, temp), throwsStateError);
    expect(calls, 1);
    await store.setEnabled(p.id, false);
    await expectLater(service.search(p, 'Title', 'ko'), throwsStateError);
    expect(calls, 1);
  });

  test('quota errors, invalid search results, HTML and oversized subtitle bodies do not create files', () async {
    final quota = SubtitlePlugins(store, clientFactory: () => MockClient((r) async => http.Response('{}', 429)));
    await expectLater(quota.search(provider, 'Title', 'ko'), throwsA(predicate((e) => '$e'.contains('요청이 너무 많'))));
    var p = await custom("return {content:'<!DOCTYPE html>login',format:'srt'};", search: 'return {items:[{}]};');
    final service = SubtitlePlugins(store);
    await expectLater(service.search(p, 'Title', 'ko'), throwsStateError);
    await expectLater(service.download(p, {'id': 'a'}, temp), throwsStateError);
    p = await custom("return {url:'https://provider.example/sub'};");
    final huge = SubtitlePlugins(
      store,
      clientFactory: () => MockClient((r) async => http.Response('x' * (8 * 1024 * 1024 + 1), 200)),
    );
    await expectLater(huge.download(p, {'id': 'a'}, temp), throwsStateError);
    expect(temp.listSync(), isEmpty);
  });

  test('search title contains no local directory or URL query and subtitle removal persists', () async {
    expect(subtitleSearchTitle(r'C:\private\movies\Example.S01E02.mkv'), 'Example S01E02');
    expect(subtitleSearchTitle('https://example.com/private/Movie.mp4?token=secret'), 'Movie');
    await store.remove(provider.id);
    expect(store.installed.containsKey(provider.id), false);
    expect(
      (await SharedPreferences.getInstance())
          .getStringList('plugins')!
          .any((s) => s.contains('subtitle.opensubtitles')),
      false,
    );
    expect((await SharedPreferences.getInstance()).getBool('defaultSubtitlePluginAdded'), isNull);
  });
}
