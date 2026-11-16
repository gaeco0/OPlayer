import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:media_kit/media_kit.dart';
import 'package:oplayer/core/media_item.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/core/resource_locks.dart';
import 'package:oplayer/core/resume_store.dart';
import 'package:oplayer/features/player/player_controller.dart';
import 'package:oplayer/core/plugins/pixel_program.dart';
import 'package:oplayer/core/plugins/plugin.dart';
import 'package:oplayer/core/plugins/plugin_store.dart';

// Opt-in native integration. Run separately from the default test suite.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final plugin = OPlugin.parse(File('plugins/player.video-presets.js').readAsStringSync());
  final invert = OPlugin.parse(
    '''// @oplayer {"api":5,"id":"thirdparty.invert","name":"External invert","version":"1","kind":"player","capabilities":["videoFilter"],"requiresHost":["pixelPrograms"],"hosts":[]}
 globalThis.plugin={videoFilter(){return {contrast:0}},frameProcessor(){return {engine:'pixel-program-v1',inputFrames:1,outputFrames:1,passes:[[[8,0,0,1],[1,1,1,1],[32,1,0,0]]]}}};
 ''',
  );
  final library = Platform.environment['OPLAYER_TEST_LIBMPV'];
  if (library != null) MediaKit.ensureInitialized(libmpv: library);
  test('actual native player composes providers without clearing upscaler shaders or screen flips', () async {
    SharedPreferences.setMockInitialValues({
      'plugins': [plugin.source, invert.source],
      'pluginSettings:${plugin.id}': '{"smoothing":"보통","temperature":"따뜻하게"}',
    });
    FlutterSecureStorage.setMockInitialValues({});
    await AppSettings.instance.init();
    await ResourceLocks.instance.init();
    await ResumeStore.instance.init();
    final store = PluginStore.instance;
    await store.init();
    final player = Player();
    final backend = player.platform as NativePlayer;
    final c = PlayerController(
      playlist: const [MediaItem(key: 'pixel-native', uri: 'test', title: 'Test')],
      startIndex: 0,
      playbackEngine: player,
    );
    final dir = await Directory.systemTemp.createTemp('oplayer_pixel_native_');
    try {
      await backend.setProperty('vo', 'null');
      await backend.setProperty('ao', 'null');
      final other = File('${dir.path}/other.glsl');
      await other.writeAsString((await pixelPrograms(invert, {}))!.single.shader);
      await backend.command(['change-list', 'glsl-shaders', 'append', other.path]);
      await c.applyVideoFilter(store.require(plugin.id));
      await c.applyVideoFilter(store.require(invert.id));
      expect(c.frameEffects.ids, [plugin.id, invert.id]);
      expect(
        await backend.getProperty('glsl-shaders'),
        allOf(contains(other.path), contains('oplayer_frame_pipeline_')),
      );
      await c.setVideoTransform(horizontal: true);
      expect(await backend.getProperty('vf'), contains('hflip'));
      await c.clearVideoFilters();
      expect(
        await backend.getProperty('glsl-shaders'),
        allOf(contains(other.path), isNot(contains('oplayer_frame_pipeline_'))),
      );
      expect(await backend.getProperty('vf'), contains('hflip'));
    } finally {
      c.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await dir.delete(recursive: true);
    }
  }, skip: library == null ? 'Set OPLAYER_TEST_LIBMPV to the native player library' : false);
}
