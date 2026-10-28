// flutter run -d windows --debug -t tool/ai_interpolation_smoke.dart
// Requires a moving 24fps, >=30s .dart_tool/rife-playback.mp4 fixture.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
// ignore: implementation_imports
import 'package:media_kit/src/player/native/core/native_library.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:oplayer/features/player/ai_interpolation.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final player = Player();
  final video = VideoController(player, configuration: const VideoControllerConfiguration(hwdec: 'auto-copy'));
  final engine = AiInterpolation(changed: () {});
  final results = <String, Object?>{};
  Future<void> step(String value) =>
      File('.dart_tool/rife-playback-trace.txt').writeAsString('$value\n', mode: FileMode.append, flush: true);
  var frames = 0;
  engine.frame.addListener(() {
    if (engine.frame.value != null) frames++;
  });
  runApp(
    MaterialApp(
      home: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            Video(controller: video, controls: NoVideoControls),
            ValueListenableBuilder(
              valueListenable: engine.frame,
              builder: (_, image, _) => image == null
                  ? const SizedBox.shrink()
                  : ColoredBox(
                      color: Colors.black,
                      child: RawImage(image: image, fit: BoxFit.contain),
                    ),
            ),
          ],
        ),
      ),
    ),
  );
  try {
    await Future<void>.delayed(const Duration(seconds: 1));
    await step('open');
    await player.setVolume(0);
    await player.open(Media(File('.dart_tool/rife-playback.mp4').absolute.path));
    await Future<void>.delayed(const Duration(seconds: 2));
    final native = player.platform as NativePlayer;
    await native.setProperty('audio-delay', '.250');
    await step('start');
    await engine
        .start(handle: await player.handle, mpvLibrary: NativeLibrary.path)
        .timeout(const Duration(seconds: 30));
    await step('started');
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!engine.applied && engine.issue == null && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (!engine.applied) throw StateError('No AI output: ${engine.issue}');
    await step('applied');
    final before = frames;
    await Future<void>.delayed(const Duration(seconds: 3));
    results['framesIn3s'] = frames - before;
    results['inferenceMs'] = engine.inferenceMs;
    results['audioDelay'] = await native.getProperty('audio-delay');
    if (frames - before < 85 || !engine.applied) throw StateError('Not real-time: $results / ${engine.issue}');
    await player.pause();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final pausedFrames = frames;
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (frames != pausedFrames || !engine.applied) throw StateError('Pause was not stable');
    await player.seek(const Duration(seconds: 15));
    await player.play();
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!engine.applied || engine.issue != null) throw StateError('Seek failed: ${engine.issue}');
    results['seek'] = true;
    await engine.stop();
    await native.setProperty('audio-delay', '0');
    if (engine.applied || engine.running || await native.getProperty('audio-delay') != '0.000000') {
      throw StateError('Original output/timing not restored');
    }
    results['stop'] = true;
    await engine.start(handle: await player.handle, mpvLibrary: NativeLibrary.path);
    await player.setRate(2);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (engine.running || engine.issue == null) throw StateError('Unsupported speed did not fall back');
    results['speedFallback'] = true;
    results['success'] = true;
  } catch (e, st) {
    results['success'] = false;
    results['error'] = '$e\n$st';
  } finally {
    await File('.dart_tool/rife-playback-result.json').writeAsString(jsonEncode(results));
    await step('teardown $results');
    await engine.stop();
    runApp(const SizedBox());
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await engine.dispose();
    await player.dispose();
    await File('.dart_tool/rife-playback-result.json').writeAsString(jsonEncode(results));
    debugPrint('RIFE_SMOKE: $results');
    await const MethodChannel('oplayer/window').invokeMethod<void>('closeForUpdate');
  }
}
