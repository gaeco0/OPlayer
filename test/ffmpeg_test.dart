import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oplayer/core/ffmpeg.dart';
import 'package:oplayer/core/settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('oplayer/ffmpeg');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    Ffmpeg.reset();
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
    Ffmpeg.reset();
  });

  test('Android uses embedded FFmpeg, preserves paths and retries without AAC filter', () async {
    final dir = Directory.systemTemp.createTempSync('oplayer ffmpeg ');
    addTearDown(() => dir.deleteSync(recursive: true));
    final video = File('${dir.path}/video clip.ts')..writeAsBytesSync([1, 2]);
    final audio = File('${dir.path}/audio clip.aac')..writeAsBytesSync([3, 4]);
    final output = File('${dir.path}/merged clip.mp4');
    final executions = <List<String>>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'version') return '6.0';
      final args = List<String>.from((call.arguments as Map)['arguments'] as List);
      executions.add(args);
      if (executions.length == 1) return {'code': 1, 'error': 'AAC filter does not apply'};
      await output.writeAsBytes([0, 0, 0, 24]);
      return {'code': 0, 'error': ''};
    });

    expect(await Ffmpeg.locate(), '내장 FFmpeg 6.0');
    expect(await Ffmpeg.remuxToMp4(video: video.path, audio: audio.path, output: output.path), (true, ''));
    expect(executions.length, 2);
    expect(executions.first, containsAllInOrder(['-i', video.path, '-i', audio.path]));
    expect(executions.first, containsAllInOrder(['-map', '0:v:0', '-map', '1:a:0', '-c', 'copy']));
    expect(executions.last, isNot(contains('-bsf:a')));
    expect(executions.last.last, output.path);
    expect(video.existsSync(), true);
    expect(audio.existsSync(), true);
  });

  test('Android reports native failure and does not accept empty MP4 output', () async {
    final dir = Directory.systemTemp.createTempSync('oplayer_ffmpeg_error_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final output = File('${dir.path}/empty.mp4')..writeAsBytesSync([]);
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'version') return '6.0';
      return {'code': 0, 'error': ''};
    });
    expect((await Ffmpeg.remuxToMp4(video: 'input.ts', output: output.path)).$1, false);
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'version') return '6.0';
      throw PlatformException(code: 'FFMPEG', message: 'native execution failed');
    });
    final result = await Ffmpeg.remuxToMp4(video: 'input.ts', output: output.path);
    expect(result.$1, false);
    expect(result.$2, contains('native execution failed'));
  });

  test('output presets retain original input and map audio-only to a real audio track', () async {
    final dir = Directory.systemTemp.createTempSync('oplayer_profiles_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final input = File('${dir.path}/input.ts')..writeAsBytesSync([1, 2, 3]);
    final executions = <List<String>>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'version') return '6.0';
      final args = List<String>.from((call.arguments as Map)['arguments'] as List);
      executions.add(args);
      await File(args.last).writeAsBytes([1, 2]);
      return {'code': 0, 'error': ''};
    });
    for (final q in OutputQuality.values) {
      final path = '${dir.path}/${q.name}${q == OutputQuality.audio ? '.m4a' : '.mp4'}';
      expect(
        (await Ffmpeg.createMp4(
          video: input.path,
          audio: q == OutputQuality.audio ? 'audio.aac' : null,
          output: path,
          quality: q,
        )).$1,
        true,
      );
    }
    expect(executions.first, containsAllInOrder(['-c', 'copy']));
    expect(executions.first, isNot(contains('-threads')));
    for (final args in executions.skip(1)) {
      expect(args, containsAllInOrder(['-filter_threads', '1', '-threads']));
      final threads = int.parse(args[args.indexOf('-threads') + 1]);
      expect(threads, inInclusiveRange(1, 4));
      expect(args.lastIndexOf('-threads'), greaterThan(args.indexOf('-i')));
    }
    expect(executions[1], contains("scale=-2:'trunc(min(1080,ih)/2)*2'"));
    expect(executions[2], contains("scale=-2:'trunc(min(720,ih)/2)*2'"));
    expect(executions[3], contains("scale=-2:'trunc(min(480,ih)/2)*2'"));
    expect(executions.last, containsAllInOrder(['-map', '1:a:0', '-vn', '-c:a', 'aac']));
    expect(input.readAsBytesSync(), [1, 2, 3]);
  });
}
