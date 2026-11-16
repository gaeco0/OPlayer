import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_frame_engine/engine.dart' as rife;
import 'package:oplayer/core/plugins/plugin.dart';
import 'package:oplayer/core/plugins/frame_processor.dart';
import 'package:oplayer/core/plugins/plugin_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final plugin = OPlugin.parse(File('plugins/player.ai-interpolation.js').readAsStringSync());
  test(
    'extension supplies two-frame processing graph and its verified weights; output is an inferred midpoint',
    () async {
      final program = (await frameProcessor(plugin, {'id': 'rife-v4-6'}))!;
      expect(program['inputFrames'], 2);
      final dir = await Directory.systemTemp.createTemp('oplayer_frame_program_');
      addTearDown(() => dir.delete(recursive: true));
      var downloads = 0;
      http.Client client() => MockClient((request) async {
        downloads++;
        return http.Response.bytes(
          await File('assets/models/rife-v4.6/${request.url.pathSegments.last}').readAsBytes(),
          200,
        );
      });
      final prepared = await prepareFrameModel(plugin, program, directory: dir, clientFactory: client);
      expect(downloads, 3);
      expect(await prepareFrameModel(plugin, program, directory: dir, clientFactory: client), prepared);
      expect(downloads, 3); // Valid cache needs no network request.
      const w = 128, h = 72, length = w * h * 4;
      final path = prepared.toNativeUtf8();
      final a = calloc<Uint8>(length), b = calloc<Uint8>(length), out = calloc<Uint8>(length);
      try {
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            final i = (y * w + x) * 4;
            for (var c = 0; c < 3; c++) {
              a[i + c] = x >= 24 && x < 56 && y >= 20 && y < 52 ? 230 : 20;
              b[i + c] = x >= 40 && x < 72 && y >= 20 && y < 52 ? 230 : 20;
            }
            a[i + 3] = b[i + 3] = 255;
          }
        }
        expect(rife.probe(path.cast(), a, b, out, w, h, 0), 0);
        expect(out[(36 * w + 36) * 4], greaterThan(190));
        expect(out[(36 * w + 28) * 4], lessThan(60)); // Motion compensation, not blending.
      } finally {
        calloc.free(path);
        calloc.free(a);
        calloc.free(b);
        calloc.free(out);
      }
      await removeFrameModelCache(plugin.id, directory: dir);
      expect(await Directory(prepared).exists(), false);
      await expectLater(
        prepareFrameModel(
          plugin,
          program,
          directory: dir,
          clientFactory: () => MockClient((_) async => http.Response.bytes([0], 200)),
        ),
        throwsFormatException,
      );
      final unsafe = Map<String, dynamic>.of(program)
        ..['artifacts'] = [
          {'name': '../escape.bin', 'url': 'https://raw.githubusercontent.com/test', 'sha256': '0' * 64},
        ];
      await expectLater(
        prepareFrameModel(plugin, unsafe, directory: dir, clientFactory: client),
        throwsFormatException,
      );
    },
  );

  test('upscale extension provides the actual frame shader, not only a model label', () async {
    final upscale = OPlugin.parse(File('plugins/player.ai-upscale.js').readAsStringSync());
    final program = (await frameProcessor(upscale, {'id': 'anime4k-s'}))!;
    expect(program['inputFrames'], 1);
    expect(program['engine'], 'mpv-glsl');
    expect(program['shader'], contains('vec4 hook()'));
    expect(program['shader'], contains('//!HOOK MAIN'));
  });

  test('interpolation options and frame compatibility are decided by the provider', () async {
    final context = {
      'platform': 'android',
      'visible': true,
      'bitmapSubtitles': false,
      'rate': 1,
      'fastForwarding': false,
      'casting': false,
      'gamma': 'srgb',
    };
    Future<Map> plan(Map<String, dynamic> overrides, [Map<String, dynamic> config = const {}]) async =>
        (await callPlugin(plugin, 'playbackOptions', {...context, ...overrides}, config: plugin.publicConfig(config)))
            as Map;
    expect((await plan({}))['npu'], true);
    expect((await plan({}, {'accelerator': 'GPU'}))['npu'], false);
    expect((await plan({'bitmapSubtitles': true}))['ai'], false);
    expect((await plan({'gamma': 'pq'}))['ai'], false);
    expect((await plan({'rate': 2}))['ai'], false);
  });
}
