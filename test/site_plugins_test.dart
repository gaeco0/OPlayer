import 'dart:io';
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/plugins/plugin_store.dart';
import 'package:oplayer/features/web/site_plugins.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('site extensions filter their pages, preserve headers and stop affecting requests when disabled', () async {
    SharedPreferences.setMockInitialValues({});
    final store = PluginStore.instance;
    await store.init();
    await store.load(await File('plugins/examples/site.example.js').readAsString());
    expect(blockedBySitePlugin('https://example.com/watch', 'https://ads.example.com/banner.js'), true);
    expect(blockedBySitePlugin('https://example.com.evil/watch', 'https://ads.example.com/banner.js'), false);
    final media = {
      'url': 'https://example.com/movie.m3u8',
      'pageUrl': 'https://example.com/watch',
      'kind': 'hls',
      'headers': {'Cookie': 'session=value', 'X-Custom': 'keep'},
    };
    final resolved = await resolveSiteMedia(media);
    expect(resolved['url'], media['url']);
    expect(resolved['headers'], media['headers']);
    await store.setEnabled('site.example', false);
    expect(blockedBySitePlugin('https://example.com/watch', 'https://ads.example.com/banner.js'), false);
    expect(await resolveSiteMedia(media), media);
  });
  test('site extension settings reach native requests and page hooks without exposing private values', () async {
    HttpOverrides.global = null;
    FlutterSecureStorage.setMockInitialValues({});
    final store = PluginStore.instance;
    await store.init();
    final server = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() => server.close(force: true));
    var hits = 0;
    server.listen((r) async {
      hits++;
      expect(r.headers.value('x-token'), 'test-site-secret');
      r.response.write('{"url":"https://cdn.example/movie.m3u8"}');
      await r.response.close();
    });
    final meta = {
      'api': 2,
      'id': 'site.settings.test',
      'name': 'Settings test',
      'version': '1',
      'kind': 'site',
      'sites': ['example.com'],
      'hosts': [],
      'authHosts': [],
      'networkSettings': ['endpoint'],
      'authSettings': ['endpoint'],
      'settings': [
        {'key': 'endpoint', 'label': 'Endpoint', 'type': 'url'},
        {'key': 'label', 'label': 'Label', 'type': 'text'},
        {'key': 'token', 'label': 'Token', 'type': 'password'},
      ],
    };
    await store.load(
      '// @oplayer ${jsonEncode(meta)}\nglobalThis.plugin={async resolveDownload(){'
      "const j=await OPlayer.request(OPlayer.config.endpoint,{headers:{'X-Token':OPlayer.secret('token')}});"
      "return {url:j.url,headers:{'X-Label':OPlayer.config.label}};}};",
    );
    await store.setCredentials('site.settings.test', {
      'endpoint': 'http://127.0.0.1:${server.port}/api',
      'label': 'configured-label',
      'token': 'test-site-secret',
    });
    final result = await resolveSiteMedia({'url': 'https://example.com/video', 'pageUrl': 'https://example.com/watch'});
    expect(result['url'], 'https://cdn.example/movie.m3u8');
    expect((result['headers'] as Map)['X-Label'], 'configured-label');
    expect(hits, 1);
    final script = sitePluginScript(store.installed['site.settings.test']!);
    expect(script, contains('configured-label'));
    expect(script, isNot(contains('test-site-secret')));
    await store.remove('site.settings.test');
  });
}
