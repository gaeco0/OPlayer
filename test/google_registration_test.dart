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
  test('build registration reaches native OAuth and JS receives only a read-only public client ID', () async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.init();
    final expected = Platform.isAndroid
        ? const String.fromEnvironment('OPLAYER_GOOGLE_ANDROID_CLIENT_ID')
        : const String.fromEnvironment('OPLAYER_GOOGLE_DESKTOP_CLIENT_ID');
    expect(CloudConfig.googleClientId, expected);
    expect(CloudConfig.googleBundledSecret('unrelated.apps.googleusercontent.com'), isNull);
    if (CloudConfig.bundledGoogleDesktopClientId.isNotEmpty) {
      expect(
        CloudConfig.googleBundledSecret(CloudConfig.bundledGoogleDesktopClientId),
        const String.fromEnvironment('OPLAYER_GOOGLE_DESKTOP_CLIENT_SECRET'),
      );
    }
    final store = PluginStore.instance;
    await store.init();
    await store.load(await File('plugins/cloud.gdrive.js').readAsString());
    expect(oauthClientFor(CloudProvider.gdrive).clientId, expected);
    expect(oauthClientFor(CloudProvider.gdrive).clientSecret, CloudConfig.googleBundledSecret(expected));
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
    // Per-account registration continues to win over newly bundled defaults.
    expect(
      oauthClientFor(CloudProvider.gdrive, clientId: 'custom.apps.googleusercontent.com').clientId,
      'custom.apps.googleusercontent.com',
    );
    expect(oauthClientFor(CloudProvider.gdrive, clientId: 'custom.apps.googleusercontent.com').clientSecret, isNull);
  });
}
