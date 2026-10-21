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
  test('real FFmpeg generates capped video and audio-only MP4 containers', () async {
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
    final ffprobe = p.join(
      p.dirname(File(bin).resolveSymbolicLinksSync()),
      Platform.isWindows ? 'ffprobe.exe' : 'ffprobe',
    );
    for (final quality in OutputQuality.values) {
      final output = p.join(dir.path, '${quality.name}${quality == OutputQuality.audio ? '.m4a' : '.mp4'}');
      final result = await Ffmpeg.createMp4(video: input, output: output, quality: quality);
      expect(result.$1, true, reason: result.$2);
      final probe = await Process.run(ffprobe, ['-v', 'error', '-show_streams', '-of', 'json', output]);
      expect(probe.exitCode, 0);
      final streams = (jsonDecode('${probe.stdout}')['streams'] as List).cast<Map>();
      if (quality == OutputQuality.audio) {
        expect(streams.every((s) => s['codec_type'] == 'audio'), true);
      } else {
        final video = streams.firstWhere((s) => s['codec_type'] == 'video');
        expect(video['height'], quality == OutputQuality.low ? 480 : 720);
        expect(streams.any((s) => s['codec_type'] == 'audio'), true);
      }
    }
  });
}
