import 'dart:io';
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
}
