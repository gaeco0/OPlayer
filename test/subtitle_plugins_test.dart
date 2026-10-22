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
          expect(r.url.queryParameters['query'], 'Example S01E02');
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
    expect((await SharedPreferences.getInstance()).getBool('defaultSubtitlePluginAdded'), true);
  });
}
