import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/plugins/plugin_store.dart';
import 'package:oplayer/core/plugins/plugin.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'repository fetch validates hashes/identity and install state persists without automatic installation',
    () async {
      HttpOverrides.global = null;
      SharedPreferences.setMockInitialValues({});
      final store = PluginStore.instance;
      await store.init();
      expect(store.installed, isEmpty);
      final source = await File('plugins/examples/site.example.js').readAsString();
      final bytes = utf8.encode(source);
      final server = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() => server.close(force: true));
      var tampered = false;
      var advertisedKind = 'browser';
      server.listen((request) async {
        if (request.uri.path == '/plugin.js') {
          request.response.add(tampered ? utf8.encode('$source\n// tampered') : bytes);
        } else {
          request.response.write(
            jsonEncode({
              'api': 1,
              'plugins': [
                {
                  'id': 'site.example',
                  'name': 'Example',
                  'version': OPlugin.parse(source).version,
                  'kind': advertisedKind,
                  'capabilities': ['page', 'resolveDownload', 'blockRequests'],
                  'url': 'plugin.js',
                  'sha256': sha256.convert(bytes).toString(),
                },
              ],
            }),
          );
        }
        await request.response.close();
      });
      final url = 'http://127.0.0.1:${server.port}/repository.json';
      await store.addRepository(url);
      expect(store.installed.containsKey('site.example'), false);
      final listings = await store.listings(url);
      expect(listings.single.url.path, '/plugin.js');
      final plugin = await store.download(listings.single);
      advertisedKind = 'resource';
      // Hash and identity alone must not permit a misleading type declaration.
      final wrongType = PluginListing(listings.single.repository, {...listings.single.data, 'kind': advertisedKind});
      await expectLater(store.download(wrongType), throwsFormatException);
      advertisedKind = 'browser';
      final wrongFeatures = PluginListing(listings.single.repository, {
        ...listings.single.data,
        'capabilities': ['page'],
      });
      await expectLater(store.download(wrongFeatures), throwsFormatException);
      await store.load(plugin.source);
      await store.setEnabled(plugin.id, false);
      expect(store.enabled.any((p) => p.id == plugin.id), false);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('disabledPlugins'), contains(plugin.id));
      expect(prefs.getStringList('plugins')!.any((p) => p.contains('site.example')), true);
      tampered = true;
      await expectLater(store.download(listings.single), throwsFormatException);
      expect(store.installed[plugin.id]!.source, source);
      await store.remove(plugin.id);
      expect(store.installed.containsKey(plugin.id), false);
    },
  );
  test('public catalog hashes match checked-in scripts', () async {
    final catalog = jsonDecode(await File('plugins/repository.json').readAsString()) as Map;
    expect(
      (catalog['plugins'] as List).map((p) => p['id']),
      containsAll([
        'cloud.gdrive',
        'cloud.dropbox',
        'cloud.onedrive',
        'cloud.s3',
        'cloud.box',
        'cloud.mybox',
        'resource.peertube',
        'resource.jellyfin',
        'subtitle.opensubtitles',
      ]),
    );
    for (final item in (catalog['plugins'] as List).cast<Map>()) {
      final fileName = Uri.parse(item['downloadUrl'] as String).pathSegments.last;
      expect(sha256.convert(await File('plugins/$fileName').readAsBytes()).toString(), item['sha256']);
      expect(['player', 'browser', 'resource'], contains(item['kind']));
      expect(item['pluginApi'], 4);
      expect(item['capabilities'], isNotEmpty);
      expect(item['features'], isNotEmpty);
    }
  });
}
