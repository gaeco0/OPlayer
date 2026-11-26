import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/core/plugins/plugin.dart';
import 'package:oplayer/core/plugins/plugin_runtime.dart';
import 'package:oplayer/core/plugins/plugin_store.dart';
import 'package:oplayer/sources/cloud/cloud_config.dart';
import 'package:oplayer/sources/cloud/cloud_sources.dart';
import 'package:oplayer/sources/server_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Google has no bundled registration; user IDs remain usable and secrets never reach JS', () async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.init();
    const expected = '';
    expect(CloudConfig.googleClientId, expected);
    final store = PluginStore.instance;
    await store.init();
    await store.load(await File('plugins/cloud.gdrive.js').readAsString());
    expect(oauthClientFor(CloudProvider.gdrive).clientId, expected);
    expect(oauthClientFor(CloudProvider.gdrive).clientSecret, isNull);
    await store.load(
      (await File('plugins/cloud.gdrive.js').readAsString()).replaceFirst('cloud.gdrive', 'cloud.google.generic'),
    );
    final generic = store.installed['cloud.google.generic']!;
    expect(() => OPlugin.parse(generic.source.replaceFirst('app.google', 'app.unknown')), throwsFormatException);
    expect(store.oauthClientId(generic), expected);
    expect((await store.credentials(generic.id))['clientId'], expected);
    expect(oauthClientFor(CloudProvider.plugin, pluginId: generic.id).clientId, expected);
    await store.setOAuthClientId(generic.id, 'custom.apps.googleusercontent.com');
    expect(oauthClientFor(CloudProvider.plugin, pluginId: generic.id).clientId, 'custom.apps.googleusercontent.com');
    expect(oauthClientFor(CloudProvider.plugin, pluginId: generic.id).clientSecret, isNull);
    final example = OPlugin.parse(await File('plugins/examples/cloud.custom.example.js').readAsString());
    final plugin = OPlugin.parse(
      '// @oplayer ${jsonEncode(example.manifest)}\n'
      'globalThis.plugin = {accountName(){return {registration:OPlayer.app.googleOAuth,'
      'frozen:Object.isFrozen(OPlayer.app)&&Object.isFrozen(OPlayer.app.googleOAuth)}},'
      'list(){return []},stream(){return null}};',
    );
    final result = await callPlugin(plugin, 'accountName', {}) as Map;
    expect(result['registration'], {'clientId': expected, 'platform': Platform.operatingSystem});
    expect(result['frozen'], true);
    // Per-account user registration is preserved.
    expect(
      oauthClientFor(CloudProvider.gdrive, clientId: 'custom.apps.googleusercontent.com').clientId,
      'custom.apps.googleusercontent.com',
    );
    expect(oauthClientFor(CloudProvider.gdrive, clientId: 'custom.apps.googleusercontent.com').clientSecret, isNull);
  });
  test('older Google extensions gain user registration controls without replacing their code', () async {
    final source = await File('plugins/sync.gdrive.js').readAsString();
    final manifest = Map<String, dynamic>.from(OPlugin.parse(source).manifest)..['settings'] = [];
    final old = '// @oplayer ${jsonEncode(manifest)}\n${source.substring(source.indexOf('\n') + 1)}';
    await PluginStore.instance.load(old);
    final migrated = PluginStore.instance.require('sync.gdrive');
    expect(migrated.settings.map((f) => f['key']), containsAll(['clientId', 'clientSecret']));
    expect(migrated.source, old);
    expect(migrated.manifest['setup']['help'], contains('기본 인증정보는 포함하지 않습니다'));
  });
}
