import 'dart:convert';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/player/video_upscaling.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('viewport scaling preserves source aspect, cover/stretch, original size and allocation limits', () {
    const source = Size(640, 360);
    expect(upscaleTarget(source, const Size(1920, 1080), BoxFit.contain), const Size(1920, 1080));
    expect(upscaleTarget(source, const Size(1000, 1000), BoxFit.contain), const Size(1000, 562));
    expect(upscaleTarget(source, const Size(1000, 1000), BoxFit.cover), const Size(1777, 1000));
    expect(upscaleTarget(source, const Size(1000, 1000), BoxFit.fill), const Size(1777, 1000));
    expect(upscaleTarget(source, const Size(3840, 2160), BoxFit.none), null);
    expect(upscaleTarget(source, const Size(3840, 2160), BoxFit.scaleDown), null);
    expect(upscaleTarget(source, const Size(112, 72), BoxFit.contain), null);
    expect(upscaleTarget(const Size(360, 640), const Size(1080, 1920), BoxFit.contain), const Size(1080, 1920));
    expect(upscaleTarget(const Size(7680, 4320), const Size(12000, 8000), BoxFit.cover), null);
    for (final view in [const Size(16000, 9000), const Size(9000, 16000), Size.infinite, Size.zero]) {
      final result = upscaleTarget(source, view, BoxFit.cover);
      if (result != null) {
        expect(result.longestSide, lessThanOrEqualTo(4096));
        expect(result.width * result.height, lessThanOrEqualTo(8294400));
      }
    }
  });
  test(
    'GPU filters and texture size change together; rapid toggles restore both without touching interpolation',
    () async {
      final values = {'scale': 'bilinear', 'cscale': 'bilinear'};
      final original = Map.of(values);
      Size? texture;
      var resized = 0;
      final scaler = VideoUpscaler(
        read: (key) async => values[key.replaceFirst('options/', '')] ?? '',
        write: (key, value) async {
          expect(['scale', 'cscale'], contains(key));
          values[key] = value;
        },
        resize: (size) async {
          texture = size;
          resized++;
        },
      );
      await scaler.apply(false, null);
      expect(resized, 0);
      await scaler.apply(true, const Size(1920, 1080));
      expect(values, {'scale': 'lanczos', 'cscale': 'lanczos'});
      expect(texture, const Size(1920, 1080));
      await scaler.apply(true, const Size(1920, 1080));
      expect(resized, 1);
      await Future.wait([scaler.apply(true, const Size(2560, 1440)), scaler.apply(false, null)]);
      expect(texture, null);
      expect(values, original);
    },
  );
  test('a rejected scaler or output allocation restores the original renderer', () async {
    for (final failResize in [false, true]) {
      final values = {'scale': 'bilinear', 'cscale': 'bilinear'};
      Size? texture;
      final sizes = <Size?>[];
      final scaler = VideoUpscaler(
        read: (key) async => values[key.replaceFirst('options/', '')] ?? '',
        write: (key, value) async {
          if (failResize || key != 'cscale' || value != 'lanczos') values[key] = value;
        },
        resize: (size) async {
          sizes.add(size);
          if (failResize && size != null) throw StateError('allocation failed');
          texture = size;
        },
      );
      await expectLater(
        scaler.apply(true, const Size(640, 360)),
        throwsA(anyOf(isA<UnsupportedError>(), isA<StateError>())),
      );
      expect(values, {'scale': 'bilinear', 'cscale': 'bilinear'});
      expect(texture, null);
      if (failResize) expect(sizes, contains(null));
    }
  });
  test('unset chroma scaler is supported and restored as inherited', () async {
    final values = {'scale': 'lanczos', 'cscale': ''};
    final scaler = VideoUpscaler(
      read: (key) async => key == 'option-info/cscale/type' ? 'String' : values[key.replaceFirst('options/', '')] ?? '',
      write: (key, value) async {
        values[key] = value;
      },
      resize: (_) async {},
    );
    await scaler.apply(true, const Size(640, 360));
    expect(values['cscale'], 'lanczos');
    await scaler.apply(false, null);
    expect(values['cscale'], '');
  });
  test('retry after partial rollback reapplies both scalers', () async {
    final values = {'scale': 'bilinear', 'cscale': 'bilinear'};
    var rejectRestore = true, failOutput = true;
    final scaler = VideoUpscaler(
      read: (key) async => values[key.replaceFirst('options/', '')] ?? '',
      write: (key, value) async {
        if (rejectRestore && key == 'cscale' && value == 'bilinear') throw StateError('restore failed');
        values[key] = value;
      },
      resize: (size) async {
        if (size != null && failOutput) {
          failOutput = false;
          throw StateError('allocation failed');
        }
      },
    );
    await expectLater(scaler.apply(true, const Size(640, 360)), throwsStateError);
    rejectRestore = false;
    await scaler.apply(true, const Size(640, 360));
    expect(values, {'scale': 'lanczos', 'cscale': 'lanczos'});
    await scaler.apply(false, null);
    expect(values, {'scale': 'bilinear', 'cscale': 'bilinear'});
  });
  test('invalid target and unsupported GPU do not change output', () async {
    var mutations = 0;
    final scaler = VideoUpscaler(
      read: (_) async => '',
      write: (_, __) async {
        mutations++;
      },
      resize: (_) async {
        mutations++;
      },
    );
    await expectLater(scaler.apply(true, const Size(9000, 9000)), throwsArgumentError);
    await expectLater(scaler.apply(true, const Size(640, 360)), throwsUnsupportedError);
    expect(mutations, 0);
  });
  test('upscaling preference defaults off and survives a restart', () async {
    SharedPreferences.setMockInitialValues({'settings_v1': jsonEncode({})});
    final settings = AppSettings.instance;
    await settings.init();
    expect(settings.videoUpscaling, false);
    settings.update((s) => s.videoUpscaling = true);
    await Future<void>.delayed(Duration.zero);
    settings.videoUpscaling = false;
    await settings.init();
    expect(settings.videoUpscaling, true);
  });
}
