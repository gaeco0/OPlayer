import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/plugins/plugin.dart';
import 'package:oplayer/core/plugins/plugin_compatibility.dart';
import 'package:oplayer/core/plugins/plugin_runtime.dart';
import 'package:oplayer/core/plugins/plugin_store.dart';

OPlugin fixture(Map<String, dynamic> extra) => OPlugin.parse(
  '// @oplayer ${jsonEncode({
    'api': 5,
    'id': 'test.compat',
    'name': 'Compat',
    'version': '1',
    'kind': 'player',
    'capabilities': ['videoFilter'],
    'hosts': <String>[],
    ...extra,
  })}\nglobalThis.plugin={videoFilter(){return {contrast:1}}}',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('every official catalog entry agrees with its script for all five platform decisions', () {
    final catalog = jsonDecode(File('plugins/repository.json').readAsStringSync()) as Map;
    for (final entry in (catalog['plugins'] as List).cast<Map>()) {
      final plugin = OPlugin.parse(
        File('plugins/${Uri.parse(entry['downloadUrl'] as String).pathSegments.last}').readAsStringSync(),
      );
      expect(entry['platforms'], plugin.manifest['platforms'], reason: plugin.id);
      expect(entry['requiresHost'], plugin.manifest['requiresHost'], reason: plugin.id);
      expect(entry['pluginApi'], plugin.manifest['api']);
      if ((plugin.oauth['scopes'] as List? ?? []).contains('https://www.googleapis.com/auth/drive.readonly') &&
          plugin.id == 'cloud.gdrive') {
        expect(entry['requiresHost'], contains('oauthScopes'));
        expect(entry['requiresHost'], contains('fixedUploadRoot'));
        expect(plugin.manifest['uploadRoot'], isNotNull);
      }

      if ((plugin.oauth['extraAuthParams'] as Map?)?['trigger_onepick'] == 'true') {
        expect(entry['pluginApi'], 5, reason: 'Picker must be rejected by old API-4-only apps');
        expect(entry['requiresHost'], contains('googlePicker'), reason: plugin.id);
      }

      for (final platform in pluginPlatforms) {
        expect(
          pluginCompatibilityIssue(entry.cast<String, dynamic>(), platform: platform),
          plugin.compatibilityIssue(platform: platform),
          reason: '${plugin.id}/$platform',
        );
        expect(
          plugin.compatibilityIssue(platform: platform) == null,
          (entry['platforms'] as List).contains(platform),
          reason: '${plugin.id}/$platform',
        );
      }
    }
  });
  test('unknown host requirements stop execution and cannot silently use the old API', () async {
    final plugin = fixture({
      'requiresHost': ['futureEngine'],
    });
    for (final platform in pluginPlatforms) {
      expect(plugin.compatibilityIssue(platform: platform), contains('futureEngine'));
    }
    expect(
      () => fixture({
        'api': 4,
        'requiresHost': ['googlePicker'],
      }),
      throwsFormatException,
    );
    expect(() => fixture({'platforms': <String>[]}), throwsFormatException);
    await expectLater(callPlugin(plugin, 'videoFilter', {}), throwsStateError);
    SharedPreferences.setMockInitialValues({});
    final store = PluginStore.forTesting();
    addTearDown(store.dispose);
    await store.init();
    await expectLater(store.load(plugin.source), throwsStateError);
    store.installed[plugin.id] = plugin;
    expect(store.enabled, isEmpty);
    expect(() => store.require(plugin.id), throwsStateError);
    await expectLater(store.setEnabled(plugin.id, true), throwsStateError);
  });
  test('native Google options must use known parameters and the official Google endpoints', () {
    final source = File('plugins/cloud.gdrive.js').readAsStringSync();
    expect(
      () => OPlugin.parse(source.replaceFirst('"include_granted_scopes"', '"unknown_native_option"')),
      throwsFormatException,
    );
    expect(
      () => OPlugin.parse(source.replaceFirst('https://oauth2.googleapis.com/token', 'https://example.com/token')),
      throwsFormatException,
    );
  });
}
