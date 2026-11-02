import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/plugins/plugin.dart';
import 'package:oplayer/core/plugins/plugin_store.dart';
import 'package:oplayer/core/plugins/upscale_models.dart';
import 'package:oplayer/core/secure_store.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/sources/server_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('disable retains data, uninstall deletes owned data and accounts without touching other providers', () async {
    final source = File('plugins/cloud.dropbox.js').readAsStringSync();
    SharedPreferences.setMockInitialValues({
      'plugins': [source],
      'pluginOAuthClientId:cloud.dropbox': 'client',
      'pluginSettings:cloud.dropbox': '{"name":"mine"}',
      'pluginConfigured:cloud.dropbox': true,
      'pluginOAuthClientId:cloud.dropbox2': 'keep',
    });
    FlutterSecureStorage.setMockInitialValues({
      'pluginCredentials:cloud.dropbox': '{"clientId":"mine"}',
      'pluginOAuthSecret:cloud.dropbox:old': 'old',
      'pluginOAuthSecret:cloud.dropbox:new': 'new',
      'pluginCredentials:cloud.dropbox2': 'keep',
      'tok:unrelated': 'keep',
      'tok_owned': 'token',
      'tok_legacy': 'token',
    });
    await AppSettings.instance.init();
    AppSettings.instance.update((s) => s.dropboxAppKey = 'legacy-client');
    final servers = ServerStore.instance;
    servers.accounts.clear();
    servers.servers.clear();
    await servers.init();
    for (final account in [
      CloudAccount(id: 'owned', provider: CloudProvider.plugin, name: 'owned', pluginId: 'cloud.dropbox'),
      CloudAccount(id: 'legacy', provider: CloudProvider.dropbox, name: 'legacy'),
      CloudAccount(id: 'keep', provider: CloudProvider.gdrive, name: 'keep'),
    ]) {
      await servers.saveAccount(account);
    }
    final store = PluginStore.forTesting();
    addTearDown(store.dispose);
    await store.init();
    await store.setEnabled('cloud.dropbox', false);
    expect(await SecureStore.instance.readRequired('tok_owned'), 'token');
    expect(store.hasCredentials('cloud.dropbox'), true);
    await store.remove('cloud.dropbox');
    expect(store.installed, isEmpty);
    expect(AppSettings.instance.dropboxAppKey, isEmpty);
    expect(servers.accounts.map((a) => a.id), ['keep']);
    for (final key in [
      'pluginCredentials:cloud.dropbox',
      'pluginOAuthSecret:cloud.dropbox:old',
      'pluginOAuthSecret:cloud.dropbox:new',
      'tok_owned',
      'tok_legacy',
    ]) {
      expect(await SecureStore.instance.readRequired(key), isNull);
    }
    expect(await SecureStore.instance.readRequired('pluginCredentials:cloud.dropbox2'), 'keep');
    expect(await SecureStore.instance.readRequired('tok:unrelated'), 'keep');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('pluginSettings:cloud.dropbox'), isNull);
    expect(prefs.getString('pluginOAuthClientId:cloud.dropbox'), isNull);
    expect(prefs.getBool('pluginConfigured:cloud.dropbox'), isNull);
    expect(prefs.getString('pluginOAuthClientId:cloud.dropbox2'), 'keep');
    store.installed['cloud.dropbox'] = OPlugin.parse(source);
    expect(await store.credentials('cloud.dropbox'), isEmpty);
  });

  test('shader cleanup removes private and old cache while preserving URL and shared hashes', () async {
    final dir = await Directory.systemTemp.createTemp('oplayer-uninstall-');
    addTearDown(() => dir.delete(recursive: true));
    final own = 'a' * 64, shared = 'b' * 64, url = 'c' * 64, old = 'd' * 64;
    SharedPreferences.setMockInitialValues({
      'pluginModelCache:player.test': [own, shared],
      'pluginModelCache:player.other': [shared],
      'upscaleUrlModels': [
        jsonEncode({'sha256': url}),
      ],
    });
    for (final digest in [own, shared, url, old]) {
      await File('${dir.path}/$digest.glsl').writeAsString('shader');
      await File('${dir.path}/$digest.glsl.ous').writeAsString('network');
    }
    await File('${dir.path}/unrelated.txt').writeAsString('keep');
    final store = PluginStore.forTesting();
    addTearDown(store.dispose);
    await store.init();
    await UpscaleModels(store: store, directory: dir).removeProviderCache('player.test');
    for (final digest in [own, old]) {
      expect(await File('${dir.path}/$digest.glsl').exists(), false);
    }
    for (final digest in [shared, url]) {
      expect(await File('${dir.path}/$digest.glsl.ous').exists(), true);
    }
    expect(await File('${dir.path}/unrelated.txt').exists(), true);
  });
}
