import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/plugins/plugin.dart';
import 'package:oplayer/core/plugins/plugin_runtime.dart';
import 'package:oplayer/core/plugins/plugin_store.dart';
import 'package:oplayer/core/plugins/upscale_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final plugin = OPlugin.parse(File('plugins/player.ai-upscale.js').readAsStringSync());
  final base = <String, dynamic>{
    'model': 'player.ai-upscale/anime4k-s',
    'id': 'anime4k-s',
    'enabled': true,
    'platform': 'android',
    'sourceWidth': 1280,
    'sourceHeight': 720,
    'targetWidth': 1920,
    'targetHeight': 1080,
    'visible': true,
    'bitmapSubtitles': false,
    'rate': 1,
    'fastForwarding': false,
    'casting': false,
  };
  Future<Map> plan({Map<String, dynamic> context = const {}, Map<String, dynamic> config = const {}}) async =>
      (await callPlugin(plugin, 'playbackOptions', {...base, ...context}, config: plugin.publicConfig(config))) as Map;

  test('extension owns device selection, resolution and runtime conflict decisions', () async {
    await callPlugin(plugin, 'validate', {}, validateOnly: true);
    expect((await plan())['npu'], true);
    for (final platform in ['windows', 'linux', 'macos', 'ios']) {
      final result = await plan(context: {'platform': platform});
      expect(result['ai'], true);
      expect(result['npu'], false);
    }
    expect((await plan(config: {'accelerator': 'GPU'}))['npu'], false);
    expect((await plan(context: {'acceleratorIssue': 'NPU unavailable'}))['npu'], false);
    expect(
      (await plan(context: {'acceleratorIssue': 'NPU unavailable'}, config: {'conflictPolicy': 'AI 사용 중지'}))['ai'],
      false,
    );
    expect((await plan(config: {'targetResolution': '2160p'}))['resolution'], 2160);
    expect((await plan(context: {'bitmapSubtitles': true}))['ai'], true);
    expect((await plan(context: {'bitmapSubtitles': true}))['npu'], false);
    expect((await plan(context: {'bitmapSubtitles': true}, config: {'conflictPolicy': 'AI 사용 중지'}))['ai'], false);
    expect((await plan(context: {'targetWidth': 1280, 'targetHeight': 720}))['ai'], false);
    expect((await plan(context: {'sourceWidth': 3840, 'sourceHeight': 2160}))['ai'], false);
    expect((await plan(context: {'enabled': false, 'aiInterpolation': true}))['ai'], false);
  });

  test('extension validation rejects conflicting options, not the settings renderer', () async {
    for (final context in [
      {'platform': 'windows'},
      {'platform': 'android', 'model': 'lanczos'},
    ]) {
      final result = await callPlugin(
        plugin,
        'validateSettings',
        context,
        config: plugin.publicConfig({'accelerator': 'NPU 전용', 'conflictPolicy': 'AI 사용 중지'}),
      );
      expect(result, isA<String>());
    }
    expect(
      await callPlugin(plugin, 'validateSettings', {}, config: plugin.publicConfig({'accelerator': 'NPU 전용'})),
      isA<String>(),
    );
    expect(await callPlugin(plugin, 'validateSettings', base, config: plugin.publicConfig({})), isNull);
  });

  test('a plugin update can add an option and change policy without host registration', () async {
    SharedPreferences.setMockInitialValues({});
    final source = plugin.source;
    final newline = source.indexOf('\n');
    final manifest = jsonDecode(source.substring(12, newline)) as Map<String, dynamic>;
    (manifest['settings'] as List).add({
      'key': 'newGpuOnlyOption',
      'label': '새 GPU 옵션',
      'type': 'boolean',
      'default': true,
    });
    final updated = OPlugin.parse(
      '// @oplayer ${jsonEncode(manifest)}\n${source.substring(newline + 1).replaceFirst('  playbackOptions(context) {', '  playbackOptions(context) { if (OPlayer.config.newGpuOnlyOption) return {ai:true,npu:false,resolution:1440,issue:null};')}',
    );
    final store = PluginStore.forTesting()..installed[updated.id] = updated;
    final models = UpscaleModels(store: store);
    expect(updated.settings.last['label'], '새 GPU 옵션');
    final result = await models.playbackOptions('player.ai-upscale/anime4k-s', base);
    expect(result?['npu'], false);
    expect(result?['resolution'], 1440);
    store.installed[updated.id] = OPlugin.parse(
      updated.source.replaceFirst('ai:true,npu:false,resolution:1440', 'ai:"invalid",npu:false,resolution:1440'),
    );
    await expectLater(models.playbackOptions('player.ai-upscale/anime4k-s', base), throwsFormatException);
  });

  test('shared host reads provider playback settings; older providers remain compatible', () async {
    SharedPreferences.setMockInitialValues({});
    final store = PluginStore.forTesting()..installed[plugin.id] = plugin;
    final models = UpscaleModels(store: store);
    final result = await models.playbackOptions('player.ai-upscale/anime4k-s', base);
    expect(result?['npu'], true);
    final oldSource = File('plugins/player.ai-upscale.js').readAsStringSync();
    final old = OPlugin.parse(oldSource.replaceFirst('  playbackOptions(context) {', '  _legacyOptions(context) {'));
    store.installed[plugin.id] = old;
    expect(await models.playbackOptions('player.ai-upscale/anime4k-s', base), isNull);
    store.disabled.add(plugin.id);
    await expectLater(models.playbackOptions('player.ai-upscale/anime4k-s', base), throwsStateError);
  });
}
