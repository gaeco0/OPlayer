// Generate .dart_tool/interpolation.mp4 with a 24fps clip before running:
// flutter run -d windows -t tool/frame_interpolation_smoke.dart
// Only this test process is exited. No application preferences are touched.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:oplayer/features/player/frame_interpolation.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final file = File('.dart_tool/interpolation.mp4').absolute;
  if (!file.existsSync()) throw StateError('Generate a small 24fps .dart_tool/interpolation.mp4 first');
  final player = Player();
  final video = VideoController(player);
  runApp(
    MaterialApp(
      home: Scaffold(
        body: Video(controller: video, controls: NoVideoControls),
      ),
    ),
  );
  try {
    await Future<void>.delayed(const Duration(seconds: 2));
    await player.setVolume(0);
    await player.setPlaylistMode(PlaylistMode.single);
    await player.open(Media(file.uri.toString()));
    await Future<void>.delayed(const Duration(seconds: 2));
    final native = player.platform as NativePlayer;
    final mixer = FrameInterpolation(read: native.getProperty, write: native.setProperty);
    final before = <String, String>{};
    for (final key in ['interpolation', 'video-sync', 'tscale', 'override-display-fps']) {
      before[key] = await native.getProperty('options/$key');
    }
    final rate = WidgetsBinding.instance.platformDispatcher.views.first.display.refreshRate;
    await mixer.apply(true, rate);
    await Future<void>.delayed(const Duration(seconds: 2));
    final active = await native.getProperty('display-sync-active');
    if (active != 'yes') throw StateError('Display sync is inactive: $active');
    final properties = {
      'interpolation': await native.getProperty('interpolation'),
      'video-sync': await native.getProperty('video-sync'),
      'display-sync-active': active,
      'display-fps': await native.getProperty('display-fps'),
      'container-fps': await native.getProperty('container-fps'),
    };
    await mixer.apply(false, rate);
    for (final entry in before.entries) {
      if (await native.getProperty('options/${entry.key}') != entry.value) {
        throw StateError('Not restored: ${entry.key}');
      }
    }
    await File(
      '.dart_tool/frame-interpolation-smoke.json',
    ).writeAsString(jsonEncode({'enabled': properties, 'restored': before}));
    debugPrint('FRAME_INTERPOLATION_SMOKE_OK: display sync, frame mixing and restoration');
  } finally {
    await player.dispose();
  }
  exit(0);
}
