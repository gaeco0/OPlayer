import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ai_frame_engine/engine.dart' as engine;
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oplayer/core/plugins/upscale_network.dart';

void main() {
  test('installed trained shaders convert to executable networks; unknown GLSL stays on GPU', () {
    expect(upscaleNetwork('//!HOOK MAIN\nvec4 hook(){return vec4(1);}'), isNull);
    final dir = Directory.systemTemp.createTempSync('oplayer-upscale-test-');
    const w = 8, h = 6;
    final input = calloc<Uint8>(w * h * 4);
    final output = calloc<Uint8>(w * h * 16);
    try {
      for (var i = 0; i < w * h; i++) {
        input[i * 4] = i * 13 % 256;
        input[i * 4 + 1] = i * 7 % 256;
        input[i * 4 + 2] = i * 19 % 256;
        input[i * 4 + 3] = 255;
      }
      final fingerprints = <String>{};
      for (final name in ['anime4k-s', 'anime4k-denoise-s', 'fsrcnnx-8']) {
        final shader = File('third_party/ai-upscale/$name.glsl').readAsStringSync();
        final bytes = upscaleNetwork(shader)!;
        expect(upscaleNetwork('$shader\n// changed'), isNull);
        final header = ByteData.sublistView(bytes);
        expect(header.getUint32(0, Endian.little), 0x3153554f);
        expect(header.getUint32(8, Endian.little), name == 'fsrcnnx-8' ? 13 : 4);
        final file = File('${dir.path}/$name.ous')..writeAsBytesSync(bytes);
        final path = file.path.toNativeUtf8();
        try {
          expect(engine.upscaleReference(path.cast(), input, output, w, h), 0);
          final pixels = output.asTypedList(w * h * 16).toList();
          expect(pixels.indexed.where((e) => e.$1 % 4 == 3).map((e) => e.$2), everyElement(255));
          expect(pixels.toSet().length, greaterThan(30));
          fingerprints.add(pixels.join(','));
          expect(engine.upscaleReference(path.cast(), input, output, w, h), 0);
          expect(output.asTypedList(pixels.length), pixels);
          file.writeAsBytesSync(bytes.sublist(0, bytes.length - 1));
          expect(engine.upscaleReference(path.cast(), input, output, w, h), -2);
          expect(engine.upscaleReference(path.cast(), input, output, 65, h), -1);
        } finally {
          calloc.free(path);
        }
      }
      expect(fingerprints.length, 3);
    } finally {
      calloc.free(input);
      calloc.free(output);
      for (final file in dir.listSync()) {
        file.deleteSync();
      }
      dir.deleteSync();
    }
  });
}
