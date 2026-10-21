import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oplayer/core/ffmpeg.dart';

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
}
