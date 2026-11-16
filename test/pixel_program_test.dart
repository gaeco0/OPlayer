import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/plugins/pixel_program.dart';
import 'package:oplayer/core/plugins/plugin.dart';
import 'package:oplayer/core/plugins/plugin_store.dart';
import 'package:oplayer/core/plugins/plugin_runtime.dart';
import 'package:oplayer/core/plugins/upscale_models.dart';
import 'package:oplayer/features/player/frame_pipeline.dart';
import 'package:oplayer/features/player/frame_effects.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final source = File('plugins/player.video-presets.js').readAsStringSync();
  final plugin = OPlugin.parse(source);
  final invert = OPlugin.parse(
    '''// @oplayer {"api":5,"id":"thirdparty.invert","name":"External invert","version":"1","kind":"player","capabilities":["videoFilter"],"requiresHost":["pixelPrograms"],"hosts":[]}
 globalThis.plugin={videoFilter(){return {contrast:0}},frameProcessor(){return {engine:'pixel-program-v1',inputFrames:1,outputFrames:1,passes:[[[8,0,0,1],[1,1,1,1],[32,1,0,0]]]}}};
 ''',
  );
  test(
    'unknown third-party programs compile without effect names or host registration; unsafe code is rejected',
    () async {
      final programs = (await pixelPrograms(invert, {}))!;
      validateUpscaleShader(programs.single.shader);
      expect(programs.single.shader, contains('r0 = r1 - r0'));
      for (final code in [
        [
          [999, 0, 0, 0],
        ],
        [
          [8, 0, 0, double.nan],
        ],
        [
          [24, 1, 0, 0],
        ],
        [
          [8, 65, 0, 1],
        ],
        [
          [0, 0, 0, 0],
          [128, 0, 0, 9],
        ],
        List.filled(65, [0, 0, 0, 0]),
      ]) {
        expect(
          () => parsePixelPrograms({
            'engine': 'pixel-program-v1',
            'inputFrames': 1,
            'outputFrames': 1,
            'passes': [code],
          }),
          throwsFormatException,
        );
      }
      await expectLater(
        callPlugin(plugin, 'validateSettings', {}, config: {'sharpening': 'invalid'}),
        throwsStateError,
      );
    },
  );
  test(
    'common GPU executor renders smoothing, sharpening, color temperature, grayscale and external effects in order',
    () async {
      final bytes = Uint8List(32 * 32 * 4);
      for (var y = 0; y < 32; y++) {
        for (var x = 0; x < 32; x++) {
          final i = (y * 32 + x) * 4, v = (x + y).isEven ? 100 : 140;
          bytes.setRange(i, i + 4, [v - 20, v, v + 20, 255]);
        }
      }
      final ready = Completer<ui.Image>();
      ui.decodeImageFromPixels(bytes, 32, 32, ui.PixelFormat.rgba8888, ready.complete);
      final image = await ready.future;
      Future<Uint8List> render(List<PixelProgram> p) async {
        final output = await renderFramePrograms(image, p);
        try {
          return (await output.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
        } finally {
          output.dispose();
        }
      }

      Future<List<PixelProgram>> filter(Map<String, dynamic> c) async => (await pixelPrograms(plugin, c))!;
      double difference(Uint8List b) => (b[(16 * 32 + 16) * 4] - b[(16 * 32 + 17) * 4]).abs().toDouble();
      double balance(Uint8List b) => b[(16 * 32 + 16) * 4] - b[(16 * 32 + 16) * 4 + 2].toDouble();
      try {
        expect(await render(await filter({})), bytes);
        final soft = await render(await filter({'smoothing': '보통'}));
        final sharp = await render(await filter({'sharpening': '보통'}));
        expect(difference(soft), lessThan(difference(bytes)));
        expect(difference(sharp), greaterThan(difference(bytes)));
        final warm = await filter({'temperature': '따뜻하게'});
        expect(balance(await render(warm)), greaterThan(balance(bytes) + 15));
        expect(balance(await render(await filter({'temperature': '차갑게'}))), lessThan(balance(bytes) - 15));
        final gray = await render(await filter({'grayscale': true}));
        final i = (16 * 32 + 16) * 4;
        expect(gray[i], closeTo(gray[i + 1], 1));
        expect(gray[i + 1], closeTo(gray[i + 2], 1));
        final combined = await render(await filter({'smoothing': '보통', 'sharpening': '보통', 'temperature': '따뜻하게'}));
        expect(combined, isNot(equals(soft)));
        expect(combined, isNot(equals(sharp)));
        final external = (await pixelPrograms(invert, {}))!;
        final inverted = await render(external);
        expect(inverted[i], closeTo(255 - bytes[i], 1));
        expect(await render([...external, ...warm]), isNot(equals(await render([...warm, ...external]))));
      } finally {
        image.dispose();
      }
    },
  );
  test('multiple providers update, reorder and disappear on disable without touching another shader', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final store = PluginStore.forTesting();
    await store.init();
    store.installed[plugin.id] = plugin;
    store.installed[invert.id] = invert;
    await store.setCredentials(plugin.id, {'smoothing': '보통', 'sharpening': '보통'});
    final shaders = <String>['other.glsl'];
    final effects = FrameEffects(
      store: store,
      changed: () {},
      command: (args) async {
        expect(args.take(2), ['change-list', 'glsl-shaders']);
        if (args[2] == 'remove') {
          shaders.remove(args[3]);
        } else {
          shaders.add(args[3]);
        }
      },
    );
    try {
      await effects.activate(plugin);
      await effects.activate(invert);
      expect(effects.ids, [plugin.id, invert.id]);
      expect(effects.programs.length, 3);
      await effects.move(invert.id, -1);
      expect(effects.ids.first, invert.id);
      await store.setEnabled(plugin.id, false);
      for (var i = 0; i < 100 && effects.contains(plugin.id); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(effects.ids, [invert.id]);
      expect(shaders, contains('other.glsl'));
      await effects.clear();
      expect(shaders, ['other.glsl']);
    } finally {
      await effects.dispose();
      store.dispose();
    }
  });
}
