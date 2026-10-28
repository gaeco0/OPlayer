import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/player/frame_interpolation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final rateKey in ['override-display-fps', 'display-fps-override']) {
    test('frame mixing follows actual display and restores original $rateKey', () async {
      final values = {'interpolation': 'no', 'video-sync': 'audio', 'tscale': 'linear', rateKey: '0.000000'};
      final initial = Map.of(values);
      final writes = <String>[];
      final mixer = FrameInterpolation(
        read: (key) async => values[key.replaceFirst('options/', '')] ?? '',
        write: (key, value) async {
          values[key] = value;
          writes.add(key);
        },
      );
      await mixer.apply(false, 0);
      expect(writes, isEmpty);
      await mixer.apply(true, 59.94);
      expect(values['interpolation'], 'yes');
      expect(values['video-sync'], 'display-resample');
      expect(values['tscale'], 'oversample');
      expect(double.parse(values[rateKey]!), 59.94);
      final writesAfterEnable = writes.length;
      await Future.wait(List.generate(20, (_) => mixer.apply(true, 59.94)));
      expect(writes.length, writesAfterEnable, reason: 'Output callbacks must not repeatedly clear temporal frames');
      await Future.wait([mixer.apply(true, 90), mixer.apply(false, 90), mixer.apply(true, 120)]);
      expect(values['interpolation'], 'yes');
      expect(double.parse(values[rateKey]!), 120);
      await mixer.apply(false, 120);
      expect(values, initial);
      expect(writes, isNot(contains('vf')));
      expect(writes, isNot(contains('hwdec')));
    });
  }
  test('silently rejected native property is detected and rolled back; later requests still work', () async {
    final values = {'interpolation': 'no', 'video-sync': 'audio', 'tscale': 'linear', 'override-display-fps': '0'};
    final original = Map.of(values);
    var reject = true;
    final mixer = FrameInterpolation(
      read: (key) async => values[key.replaceFirst('options/', '')] ?? '',
      write: (key, value) async {
        if (!(reject && key == 'interpolation' && value == 'yes')) values[key] = value;
      },
    );
    await expectLater(mixer.apply(true, 60), throwsUnsupportedError);
    expect(values, original);
    reject = false;
    await mixer.apply(true, 60);
    expect(values['interpolation'], 'yes');
    await mixer.apply(false, 60);
    expect(values, original);
  });
  test('unsupported engines and invalid display rates never leave partial settings', () async {
    var writes = 0;
    final mixer = FrameInterpolation(
      read: (_) async => '',
      write: (_, __) async {
        writes++;
      },
    );
    for (final rate in [0.0, double.nan, double.infinity, 2000.0, 60.0]) {
      await expectLater(mixer.apply(true, rate), throwsUnsupportedError);
    }
    expect(writes, 0);
  });
  test('frame mixing preference defaults off, survives restart and rejects malformed saved values', () async {
    final settings = AppSettings.instance;
    for (final value in [null, 'true', false, true]) {
      SharedPreferences.setMockInitialValues({
        'settings_v1': jsonEncode({'frameInterpolation': value}),
      });
      await settings.init();
      expect(settings.frameInterpolation, value == true);
    }
    settings.update((s) => s.frameInterpolation = true);
    await Future<void>.delayed(Duration.zero);
    settings.frameInterpolation = false;
    await settings.init();
    expect(settings.frameInterpolation, true);
  });
}
