import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ai_frame_engine/engine.dart' as rife;
import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/settings.dart';

void main() {
  test('RIFE preference survives restart without enabling interpolation by default', () async {
    SharedPreferences.setMockInitialValues({'settings_v1': '{}'});
    final settings = AppSettings.instance;
    await settings.init();
    expect(settings.frameInterpolation, false);
    expect(settings.interpolationMode, 'blend');
    settings.update((s) {
      s.interpolationMode = 'rife';
      s.frameInterpolation = true;
    });
    await settings.init();
    expect(settings.interpolationMode, 'rife');
    expect(settings.frameInterpolation, true);
    for (final value in [null, true, 'unknown', <String, Object>{}]) {
      SharedPreferences.setMockInitialValues({
        'settings_v1': jsonEncode({'interpolationMode': value}),
      });
      await settings.init();
      expect(settings.interpolationMode, 'blend');
    }
  });

  test('bundled RIFE files match pinned upstream model', () async {
    const hashes = {
      'flownet.param': '724569596bcd1e7b9fa50455c604777ebed99746d2ef40aa86e31b5725f1053c',
      'flownet.bin': 'f334ed2260149ce0188a6dcf049844e8b0cdd912e01cbcfb63553157d2508958',
    };
    for (final entry in hashes.entries) {
      expect(sha256.convert(await File('assets/models/rife-v4.6/${entry.key}').readAsBytes()).toString(), entry.value);
    }
  });

  test('native CPU generates a moving midpoint instead of blending and rejects missing model', () {
    const w = 128, h = 72, length = w * h * 4;
    final path = Directory('assets/models/rife-v4.6').absolute.path.toNativeUtf8();
    final missing = Directory('.dart_tool/no-rife-model').absolute.path.toNativeUtf8();
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
      expect(rife.probe(missing.cast(), a, b, out, w, h, 0), -2);
      expect(rife.probe(path.cast(), a, b, out, w, h, 0), 0);
      int pixel(int x, int y) => out[(y * w + x) * 4];
      expect(pixel(36, 36), greaterThan(190)); // Midpoint rectangle shifted by 8px.
      expect(pixel(28, 36), lessThan(60)); // Blending leaves a grey ghost here.
      expect(pixel(68, 36), lessThan(60));
      expect(rife.probe(path.cast(), a, b, out, 10000, h, 0), -1);
    } finally {
      calloc.free(path);
      calloc.free(missing);
      calloc.free(a);
      calloc.free(b);
      calloc.free(out);
    }
  });
}
