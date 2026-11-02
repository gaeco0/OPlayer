import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/ffmpeg.dart';
import 'package:oplayer/core/settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('real FFmpeg generates MP4 profiles and MKV with original audio/video/subtitles', () async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.init();
    debugDefaultTargetPlatformOverride = Platform.isWindows
        ? TargetPlatform.windows
        : Platform.isMacOS
        ? TargetPlatform.macOS
        : TargetPlatform.linux;
    Ffmpeg.reset();
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      Ffmpeg.reset();
    });
    final bin = await Ffmpeg.locate();
    if (bin == null) {
      markTestSkipped('Desktop FFmpeg is not installed');
      return;
    }
    final dir = await Directory.systemTemp.createTemp('oplayer_profiles_real_');
    addTearDown(() => dir.delete(recursive: true));
    final input = p.join(dir.path, 'input.mp4');
    final generated = await Process.run(bin, [
      '-y',
      '-hide_banner',
      '-loglevel',
      'error',
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=1280x720:rate=5',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:sample_rate=44100',
      '-t',
      '0.6',
      '-c:v',
      'mpeg4',
      '-c:a',
      'aac',
      input,
    ]);
    expect(generated.exitCode, 0, reason: '${generated.stderr}');
    final subtitle = File(p.join(dir.path, 'sample.srt'));
    await subtitle.writeAsString('1\n00:00:00,000 --> 00:00:00,500\nSubtitle test\n');
    final mkvInput = p.join(dir.path, 'source.mkv');
    final subtitled = await Process.run(bin, [
      '-y',
      '-hide_banner',
      '-loglevel',
      'error',
      '-i',
      input,
      '-i',
      subtitle.path,
      '-map',
      '0',
      '-map',
      '1:s',
      '-c',
      'copy',
      mkvInput,
    ]);
    expect(subtitled.exitCode, 0, reason: '${subtitled.stderr}');
    Future<String> splitInput(String path, String prefix) async {
      final bytes = await File(path).readAsBytes();
      final parts = <String>[];
      final step = (bytes.length / 3).ceil();
      for (var offset = 0; offset < bytes.length; offset += step) {
        final file = File(p.join(dir.path, "$prefix part '${parts.length}.seg"));
        await file.writeAsBytes(bytes.sublist(offset, (offset + step).clamp(0, bytes.length)));
        parts.add(file.path);
      }
      return Ffmpeg.concatInput(files: parts, listPath: p.join(dir.path, '$prefix list.txt'));
    }

    final videoInput = await splitInput(input, 'mp4');
    final subtitleInput = await splitInput(mkvInput, 'mkv');
    final ffprobe = p.join(
      p.dirname(File(bin).resolveSymbolicLinksSync()),
      Platform.isWindows ? 'ffprobe.exe' : 'ffprobe',
    );
    for (final quality in OutputQuality.values) {
      final output = p.join(dir.path, '${quality.name}${quality.extension}');
      final result = await Ffmpeg.createOutput(
        video: quality == OutputQuality.mkv ? subtitleInput : videoInput,
        output: output,
        quality: quality,
      );
      expect(result.$1, true, reason: result.$2);
      final probe = await Process.run(ffprobe, ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', output]);
      expect(probe.exitCode, 0);
      final streams = (jsonDecode('${probe.stdout}')['streams'] as List).cast<Map>();
      if (quality == OutputQuality.audio) {
        expect(streams.every((s) => s['codec_type'] == 'audio'), true);
      } else {
        final video = streams.firstWhere((s) => s['codec_type'] == 'video');
        expect(video['height'], quality == OutputQuality.low ? 480 : 720);
        expect(streams.any((s) => s['codec_type'] == 'audio'), true);
        if (quality == OutputQuality.mkv) {
          expect(jsonDecode('${probe.stdout}')['format']['format_name'], contains('matroska'));
          expect(video['codec_name'], 'mpeg4');
          expect(streams.firstWhere((s) => s['codec_type'] == 'audio')['codec_name'], 'aac');
          expect(streams.any((s) => s['codec_type'] == 'subtitle' && s['codec_name'] == 'subrip'), isTrue);
          expect(await File(mkvInput).exists(), isTrue);
        }
      }
    }
  });
}
