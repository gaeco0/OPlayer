// Generate a small .dart_tool/interpolation.mp4, then:
// flutter run -d windows --debug -t tool/video_upscaling_smoke.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:oplayer/features/player/video_upscaling.dart';
import 'package:oplayer/features/player/frame_interpolation.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final player = Player();
  final video = VideoController(player);
  runApp(
    MaterialApp(
      home: Scaffold(
        body: Video(controller: video, controls: NoVideoControls),
      ),
    ),
  );
  var succeeded = false;
  try {
    await Future<void>.delayed(const Duration(seconds: 2));
    await player.setVolume(0);
    await player.setPlaylistMode(PlaylistMode.single);
    await player.open(Media(File('.dart_tool/interpolation.mp4').absolute.uri.toString()));
    await Future<void>.delayed(const Duration(seconds: 2));
    final native = player.platform as NativePlayer;
    final original = {
      for (final key in ['scale', 'cscale']) key: await native.getProperty('options/$key'),
    };
    final source = video.rect.value!.size;
    final scaler = VideoUpscaler(
      read: native.getProperty,
      write: native.setProperty,
      resize: (size) => video.setSize(width: size?.width.toInt(), height: size?.height.toInt()),
    );
    final mixer = FrameInterpolation(read: native.getProperty, write: native.setProperty);
    final rate = WidgetsBinding.instance.platformDispatcher.views.first.display.refreshRate;
    await mixer.apply(true, rate);
    await scaler.apply(true, const Size(640, 360));
    await Future<void>.delayed(const Duration(seconds: 2));
    if (video.rect.value?.size != const Size(640, 360)) throw StateError('Output texture was not upscaled');
    if (await native.getProperty('display-sync-active') != 'yes') throw StateError('Frame mixing was disrupted');
    final result = {
      'source': source.toString(),
      'render': video.rect.value!.size.toString(),
      'scale': await native.getProperty('scale'),
      'cscale': await native.getProperty('cscale'),
      'display-sync-active': await native.getProperty('display-sync-active'),
    };
    await scaler.apply(false, null);
    await mixer.apply(false, rate);
    await Future<void>.delayed(const Duration(seconds: 1));
    for (final entry in original.entries) {
      if (await native.getProperty('options/${entry.key}') != entry.value) {
        throw StateError('Not restored: ${entry.key}');
      }
    }
    if (video.rect.value?.size != source) throw StateError('Source texture size was not restored');
    await File('.dart_tool/video-upscaling-smoke.json').writeAsString(jsonEncode(result));
    debugPrint('VIDEO_UPSCALING_SMOKE_OK: Lanczos, larger GPU texture, frame mixing and restoration');
    succeeded = true;
  } catch (error, stack) {
    debugPrint('$error\n$stack');
  } finally {
    await player.dispose();
  }
  exit(succeeded ? 0 : 1);
}
