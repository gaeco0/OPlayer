import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/plugins/plugin.dart';
import 'package:oplayer/core/plugins/plugin_store.dart';
import 'package:oplayer/sources/cloud/cloud_sources.dart';
import 'package:oplayer/sources/server_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('provider enum never overrides a third-party extension OAuth declaration', () async {
    SharedPreferences.setMockInitialValues({});
    await PluginStore.instance.init();
    final source = File('plugins/cloud.dropbox.js').readAsStringSync();
    final manifest = Map<String, dynamic>.of(OPlugin.parse(source).manifest)..['id'] = 'resource.custom-oauth';
    manifest['oauth'] = Map<String, dynamic>.of(manifest['oauth'])
      ..['mobileRedirectUri'] = 'com.oplayer.oplayer://custom-provider';
    final plugin = OPlugin.parse('// @oplayer ${jsonEncode(manifest)}\n${source.substring(source.indexOf('\n') + 1)}');
    PluginStore.instance.installed[plugin.id] = plugin;
    for (final provider in [
      CloudProvider.plugin,
      CloudProvider.dropbox,
      CloudProvider.onedrive,
      CloudProvider.gdrive,
    ]) {
      final client = oauthClientFor(provider, pluginId: plugin.id, clientId: 'account-bound-registration');
      expect(client.mobileRedirectUri, 'com.oplayer.oplayer://custom-provider');
      expect(client.clientId, 'account-bound-registration');
      expect(client.clientSecretFallbackKey, isNull);
      expect(client.authEndpoint, plugin.oauth['authEndpoint']);
    }
  });
}
