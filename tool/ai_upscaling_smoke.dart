// flutter run -d windows --debug -t tool/ai_upscaling_smoke.dart
// Requires .dart_tool/interpolation.mp4 (small, generated test fixture).
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:oplayer/core/plugins/upscale_models.dart';
import 'package:oplayer/core/plugins/plugin.dart';
import 'package:oplayer/core/plugins/plugin_store.dart';
import 'package:oplayer/features/player/video_upscaling.dart';
import 'package:oplayer/features/player/frame_interpolation.dart';

Future<void> main(List<String> args) async {
  final baselineOnly = args.contains('--no-ai');
  final closeActive = args.contains('--close-active');
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final player = Player(configuration: const PlayerConfiguration(logLevel: MPVLogLevel.debug));
  final boundary = GlobalKey();
  // Match OPlayer's Windows copy-back decoding policy.
  final video = VideoController(player, configuration: const VideoControllerConfiguration(hwdec: 'auto-copy'));
  final errors = <String>[];
  final messages = <String>[];
  final logs = player.stream.log.listen((event) {
    messages.add('${event.prefix}: ${event.text}');
    if (const {'error', 'fatal'}.contains(event.level)) errors.add('${event.prefix}: ${event.text}');
  });
  runApp(
    MaterialApp(
      home: Scaffold(
        body: RepaintBoundary(
          key: boundary,
          child: Video(controller: video, controls: NoVideoControls),
        ),
      ),
    ),
  );
  var success = false;
  Future<void> step(String text) =>
      File('.dart_tool/ai-upscaling-trace.txt').writeAsString('$text\n', mode: FileMode.append, flush: true);
  await File('.dart_tool/ai-upscaling-trace.txt').writeAsString('start\n');
  try {
    await Future<void>.delayed(const Duration(seconds: 2));
    await player.setVolume(0);
    await player.setPlaylistMode(PlaylistMode.single);
    await player.open(Media(File('.dart_tool/interpolation.mp4').absolute.uri.toString()));
    await Future<void>.delayed(const Duration(seconds: 2));
    await player.pause();
    await player.seek(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final native = player.platform as NativePlayer;
    final mixing = FrameInterpolation(read: native.getProperty, write: native.setProperty);
    Future<void> visibleFrame() async {
      await WidgetsBinding.instance.endOfFrame;
      final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: .25);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      if (bytes == null) throw StateError('No composed frame');
      var lit = 0;
      for (var i = 0; i < bytes.lengthInBytes; i += 4) {
        if (bytes.getUint8(i) + bytes.getUint8(i + 1) + bytes.getUint8(i + 2) > 30) lit++;
      }
      if (lit < bytes.lengthInBytes ~/ 200) throw StateError('Black composed video frame');
    }

    final originalSize = video.rect.value!.size;
    final scaler = VideoUpscaler(
      read: native.getProperty,
      write: native.setProperty,
      resize: (size) => video.setSize(width: size?.width.toInt(), height: size?.height.toInt()),
    );
    final shaders = UpscaleShader(native.command);
    // This manual renderer test must not install extensions into the user profile.
    // ignore: invalid_use_of_visible_for_testing_member
    final store = PluginStore.forTesting();
    final provider = OPlugin.parse(await File('plugins/player.ai-upscale.js').readAsString());
    store.installed[provider.id] = provider;
    final modelService = UpscaleModels(store: store);
    final models = await modelService.catalog();
    final passes = <String, dynamic>{};
    await step('resize');
    await scaler.apply(true, const Size(640, 360));
    await Future<void>.delayed(const Duration(seconds: 2));
    await step('resized ${video.rect.value}');
    await step('vo ${await native.getProperty('vo')} out ${await native.getProperty('video-out-params')}');

    for (final model in models.take(baselineOnly ? 0 : 3)) {
      await step('model ${model.name}');
      messages.clear();
      errors.clear();
      final file = await modelService.materialize(model);
      await step('shader prepared ${file.path}');
      await shaders.apply(file.absolute.path);
      await step('shader attached');
      await Future<void>.delayed(const Duration(seconds: 2));
      if (errors.isNotEmpty) throw StateError('${model.name}: $errors');
      await step('shader option ${await native.getProperty('glsl-shaders')}');
      await File('.dart_tool/ai-${model.id}-gpu.log').writeAsString(messages.join('\n'));
      final source = await file.readAsString();
      final coefficient = RegExp(r'(?:mat4|vec4)\(\s*(-?\d+\.\d+)').firstMatch(source)!.group(1)!;
      if (!messages.any((line) => line.startsWith('libmpv_render:') && line.contains(coefficient))) {
        throw StateError('${model.name} trained weights were not compiled by the active GPU renderer');
      }
      await step('verified GPU coefficient $coefficient');
      passes[model.name] = <String, Object>{
        'shader': await native.getProperty('glsl-shaders'),
        'compiledCoefficient': coefficient,
      };
      if (video.rect.value?.size != const Size(640, 360)) throw StateError('Wrong output texture size');
      await mixing.apply(true, 60);
      await player.play();
      for (var frame = 0; frame < 12; frame++) {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        await visibleFrame();
      }
      await player.pause();
      await mixing.apply(false, 60);
      passes[model.name]['composedFramesWithMixing'] = 12;
    }
    if (closeActive) {
      await mixing.apply(true, 60);
      await player.play();
    } else {
      await shaders.apply(null);
      await scaler.apply(false, null);
      await Future<void>.delayed(const Duration(seconds: 1));
      final restored = await native.getProperty('glsl-shaders');
      if (video.rect.value?.size != originalSize) throw StateError('Texture size was not restored');
      if (restored.contains('.glsl')) throw StateError('Shader was not removed');
    }
    await File('.dart_tool/ai-upscaling-smoke.json').writeAsString(jsonEncode(passes));
    debugPrint('AI_UPSCALING_SMOKE_OK: three trained CNNs executed on GPU; shaders and texture restored');
    success = true;
  } catch (e, st) {
    await step('ERROR $e\n$st');
    debugPrint('$e\n$st');
  } finally {
    await File('.dart_tool/ai-gpu-all.log').writeAsString(messages.join('\n'));
    if (!closeActive) runApp(const SizedBox());
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await logs.cancel();
    if (!closeActive) await player.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  await File(
    '.dart_tool/ai-upscaling-smoke-result${baselineOnly ? '-baseline' : ''}.json',
  ).writeAsString(jsonEncode({'success': success, 'models': baselineOnly ? 0 : 3}));
  // Let the Windows UI/COM thread close normally; dart:io exit() tears down
  // CoreMessaging from the Dart thread and can itself cause an access violation.
  await const MethodChannel('oplayer/window').invokeMethod<void>('closeForUpdate');
}
