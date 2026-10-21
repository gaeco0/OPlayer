import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'settings.dart';

/// 시스템에 설치된 ffmpeg 찾기 + 스트림 복사(재인코딩 없음)로 MP4 만들기.
/// HLS(MPEG-TS) 조각을 이어붙인 결과를 .mp4로 바꾸거나, 분리된 영상/음성을 합칠 때 사용.
class Ffmpeg {
  Ffmpeg._();

  static const _channel = MethodChannel('oplayer/ffmpeg');
  static bool get embedded => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static String? _cached;
  static bool _searched = false;

  static void reset() {
    _cached = null;
    _searched = false;
  }

  static Future<String?> locate() async {
    if (embedded) {
      if (_searched) return _cached;
      try {
        final version = await _channel.invokeMethod<String>('version');
        if (version != null && version.isNotEmpty) {
          _searched = true;
          return _cached = '내장 FFmpeg $version';
        }
      } on PlatformException {
        return null;
      } on MissingPluginException {
        return null;
      }
      return null;
    }
    final custom = AppSettings.instance.ffmpegPath;
    if (custom != null && custom.isNotEmpty && await File(custom).exists()) return custom;
    if (_searched) return _cached;
    _searched = true;
    if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) return null;

    final candidates = <String>[];
    if (Platform.isWindows) {
      final local = Platform.environment['LOCALAPPDATA'];
      if (local != null) {
        // winget 설치 위치 (앱 실행 후 설치하면 PATH가 반영되지 않으므로 직접 확인)
        candidates.add(p.join(local, 'Microsoft', 'WinGet', 'Links', 'ffmpeg.exe'));
      }
      candidates.addAll([r'C:\ffmpeg\bin\ffmpeg.exe', r'C:\Program Files\ffmpeg\bin\ffmpeg.exe']);
    } else {
      candidates.addAll(['/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg', '/usr/bin/ffmpeg']);
    }
    // PATH 검색
    try {
      final r = await Process.run(Platform.isWindows ? 'where' : 'which', ['ffmpeg']);
      if (r.exitCode == 0) {
        final first = '${r.stdout}'.split(RegExp(r'[\r\n]+')).firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
        if (first.isNotEmpty) candidates.insert(0, first.trim());
      }
    } catch (_) {}
    for (final c in candidates) {
      if (await File(c).exists()) return _cached = c;
    }
    return null;
  }

  /// 영상(+선택적 음성)을 MP4로 스트림 복사. 성공하면 true.
  static Future<(bool, String)> remuxToMp4({required String video, String? audio, required String output}) async {
    final bin = await locate();
    if (bin == null) return (false, 'ffmpeg 없음');
    final args = <String>['-y', '-hide_banner', '-loglevel', 'error', '-i', video];
    if (audio != null) {
      args.addAll(['-i', audio, '-map', '0:v:0', '-map', '1:a:0']);
    } else {
      args.addAll(['-map', '0:v?', '-map', '0:a?']);
    }
    args.addAll(['-c', 'copy', '-bsf:a', 'aac_adtstoasc', '-movflags', '+faststart', output]);
    try {
      var (code, error) = await _execute(bin, args);
      if (code != 0) {
        // 오디오가 AAC가 아니면 bsf가 실패할 수 있음 → bsf 없이 재시도
        final retry = List.of(args);
        final i = retry.indexOf('-bsf:a');
        retry.removeRange(i, i + 2);
        (code, error) = await _execute(bin, retry);
      }
      final file = File(output);
      return (code == 0 && await file.exists() && await file.length() > 0, error.trim());
    } catch (e) {
      return (false, '$e');
    }
  }

  static Future<(int, String)> _execute(String bin, List<String> args) async {
    if (embedded) {
      final response = await _channel.invokeMapMethod<String, dynamic>('execute', {'arguments': args});
      return (response?['code'] as int? ?? -1, response?['error'] as String? ?? 'FFmpeg 응답 없음');
    }
    final result = await Process.run(bin, args);
    return (result.exitCode, '${result.stderr}');
  }

  /// MPEG-4/AAC encoders are included in the LGPL Android FFmpeg build.
  /// Presets cap resolution without upscaling; original uses stream copy.
  static Future<(bool, String)> createMp4({
    required String video,
    String? audio,
    required String output,
    required OutputQuality quality,
  }) async {
    if (quality == OutputQuality.original) return remuxToMp4(video: video, audio: audio, output: output);
    final bin = await locate();
    if (bin == null) return (false, 'ffmpeg 없음');
    final args = <String>['-y', '-hide_banner', '-loglevel', 'error', '-i', video];
    if (audio != null) args.addAll(['-i', audio]);
    if (quality == OutputQuality.audio) {
      args.addAll(['-map', audio == null ? '0:a:0' : '1:a:0', '-vn', '-c:a', 'aac', '-b:a', '192k']);
    } else {
      final height = switch (quality) {
        OutputQuality.high => 1080,
        OutputQuality.medium => 720,
        _ => 480,
      };
      final q = switch (quality) {
        OutputQuality.high => '2',
        OutputQuality.medium => '5',
        _ => '8',
      };
      args.addAll([
        '-map',
        '0:v?',
        '-map',
        audio == null ? '0:a?' : '1:a:0',
        '-vf',
        "scale=-2:'trunc(min($height,ih)/2)*2'",
        '-c:v',
        'mpeg4',
        '-q:v',
        q,
        '-pix_fmt',
        'yuv420p',
        '-c:a',
        'aac',
        '-b:a',
        quality == OutputQuality.low ? '96k' : '192k',
      ]);
    }
    args.addAll(['-movflags', '+faststart', output]);
    try {
      final (code, error) = await _execute(bin, args);
      final f = File(output);
      return (code == 0 && await f.exists() && await f.length() > 0, error.trim());
    } catch (e) {
      return (false, '$e');
    }
  }
}
