import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:oplayer/core/plugins/plugin_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final savedEmpty in [false, true]) {
    test('startup never installs defaults (saved empty list: $savedEmpty)', () async {
      SharedPreferences.setMockInitialValues({
        if (savedEmpty) 'plugins': <String>[],
        'defaultSubtitlePluginAdded': false,
      });
      final store = PluginStore.forTesting();
      addTearDown(store.dispose);
      await store.init();
      expect(store.installed, isEmpty);
      expect(store.enabled, isEmpty);
      expect(store.errors, isEmpty);
      expect(store.repositories, [defaultPluginRepository]);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('plugins'), savedEmpty ? isEmpty : isNull);
      expect(prefs.getBool('defaultSubtitlePluginAdded'), false);
    });
  }

  test('startup restores only saved extensions and retains settings and disabled state', () async {
    final source = await File('plugins/cloud.dropbox.js').readAsString();
    SharedPreferences.setMockInitialValues({
      'plugins': [source],
      'disabledPlugins': ['cloud.dropbox'],
      'pluginOAuthClientId:cloud.dropbox': 'saved-client',
      'pluginConfigured:cloud.dropbox': true,
    });
    final store = PluginStore.forTesting();
    addTearDown(store.dispose);
    await store.init();
    await store.init();
    expect(store.installed.keys, ['cloud.dropbox']);
    expect(store.installed.values.single.source, source);
    expect(store.enabled, isEmpty);
    expect(store.oauthClientId(store.installed.values.single), 'saved-client');
    expect(store.hasCredentials('cloud.dropbox'), true);
    expect(store.errors, isEmpty);
  });
}
