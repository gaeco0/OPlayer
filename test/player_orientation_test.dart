import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/player/player_orientation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('mobile orientation preference restores across reloads and tolerates older settings', () async {
    final settings = AppSettings.instance;
    for (final value in [null, 'unknown', ...PlaybackOrientation.values.map((mode) => mode.name)]) {
      SharedPreferences.setMockInitialValues({
        'settings_v1': jsonEncode({'playbackOrientation': value}),
      });
      await settings.init();
      final expected = PlaybackOrientation.values.firstWhere(
        (mode) => mode.name == value,
        orElse: () => PlaybackOrientation.landscape,
      );
      expect(settings.playbackOrientation, expected);
    }
    settings.update((s) => s.playbackOrientation = PlaybackOrientation.portrait);
    await Future<void>.delayed(Duration.zero);
    await settings.init();
    expect(settings.playbackOrientation, PlaybackOrientation.portrait);
  });

  test('Android uses the sensor bridge for every mode and releases it on player exit', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('oplayer/orientation');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'set');
      calls.add(call.arguments as String);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    expect(PlayerOrientation.supported, true);
    for (final mode in PlaybackOrientation.values) {
      await PlayerOrientation.apply(mode);
    }
    await PlayerOrientation.apply(null);
    expect(calls, ['landscape', 'portrait', 'auto', 'system']);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(PlayerOrientation.supported, false);
    await PlayerOrientation.apply(PlaybackOrientation.auto);
    expect(calls.length, 4);
  });

  test('iOS applies explicit supported directions and restores system defaults', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <List>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') calls.add(call.arguments as List);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await PlayerOrientation.apply(PlaybackOrientation.portrait);
    await PlayerOrientation.apply(PlaybackOrientation.auto);
    await PlayerOrientation.apply(null);
    expect(calls.first, ['DeviceOrientation.portraitUp']);
    expect(calls[1], containsAll(DeviceOrientation.values.map((mode) => mode.toString())));
    expect(calls.last, isEmpty);
  });
}
