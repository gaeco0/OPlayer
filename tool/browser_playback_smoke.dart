// flutter run -d windows --debug --no-pub --no-dds --no-hot -t tool/browser_playback_smoke.dart
// Generates local test media; never loads a third-party site or saved credentials.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pointycastle/export.dart';
import 'package:oplayer/features/web/browser_playback_proxy.dart';
import 'package:oplayer/features/web/hls.dart';
import 'package:oplayer/features/player/player_controller.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/core/resume_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // Keep this executable test completely separate from the user's preferences/history.
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues({});
  await AppSettings.instance.init();
  await ResumeStore.instance.init();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('Preparing local playback test'))),
    ),
  );
  PlayerController? controller;
  final origin = await HttpServer.bind('127.0.0.1', 0);
  final base = 'http://127.0.0.1:${origin.port}';
  var rejectedNative = 0, browserSegments = 0, keyRequests = 0;
  final errors = <String>[];
  var maxPosition = 0;
  final subscriptions = <StreamSubscription>[];
  try {
    final dir = await Directory('D:/Data/Projects/OPlayer/.dart_tool/browser_playback_smoke').create(recursive: true);
    final ffmpeg = '${Platform.environment['LOCALAPPDATA']}/Microsoft/WinGet/Links/ffmpeg.exe';
    final generated = await Process.run(ffmpeg, [
      '-y',
      '-hide_banner',
      '-loglevel',
      'error',
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=160x90:rate=10',
      '-t',
      '4',
      '-c:v',
      'libx264',
      '-pix_fmt',
      'yuv420p',
      '-g',
      '10',
      '-f',
      'hls',
      '-hls_time',
      '1',
      '-hls_list_size',
      '0',
      '-hls_segment_filename',
      '${dir.path}/segment%d.ts',
      '${dir.path}/plain.m3u8',
    ]);
    if (generated.exitCode != 0) throw StateError('Fixture generation failed: ${generated.stderr}');
    final original = await File('${dir.path}/plain.m3u8').readAsString();
    final segments = <String, Uint8List>{};
    final keys = <String, Uint8List>{};
    var sequence = 0;
    final encryptedPlaylist = <String>[];
    for (final line in original.split('\n')) {
      if (line.trim().isNotEmpty && !line.startsWith('#')) {
        final key = Uint8List.fromList(List.generate(16, (i) => (i + sequence * 17) % 256));
        final uri = '$base/v/session?n=$sequence';
        keys[uri] = key;
        final cipher = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
          ..init(
            true,
            PaddedBlockCipherParameters(ParametersWithIV(KeyParameter(key), Hls.ivForSequence(sequence)), null),
          );
        segments['/$line'] = cipher.process(await File('${dir.path}/$line').readAsBytes());
        encryptedPlaylist.add('#EXT-X-KEY:METHOD=AES-128,URI="$uri"');
        sequence++;
      }
      encryptedPlaylist.add(line);
    }
    origin.listen((request) async {
      final response = request.response;
      if (request.uri.path == '/watch') {
        response.headers.contentType = ContentType.html;
        response.write('<!doctype html><title>OPlayer local browser playback test</title>');
      } else if (request.uri.path == '/v/session') {
        keyRequests++;
        response.headers.contentType = ContentType.json;
        response.write('{"encrypted_key":"not-a-raw-key"}');
      } else if (request.headers.value('user-agent') == 'native-rejected') {
        rejectedNative++;
        response.statusCode = 403;
      } else if (request.headers.value('x-session') != 'test-session') {
        response.statusCode = 401;
      } else {
        final bytes = segments[request.uri.path];
        if (bytes == null) {
          response.statusCode = 404;
        } else {
          browserSegments++;
          response.headers.contentType = ContentType('video', 'mp2t');
          response.contentLength = bytes.length;
          response.add(bytes);
        }
      }
      await response.close();
    });
    final item = BrowserPlaybackRegistry.remember(
      url: '$base/list.m3u8',
      title: 'Local playback test',
      pageUrl: '$base/watch',
      hls: true,
      headers: const {'User-Agent': 'native-rejected', 'X-Session': 'test-session'},
      keys: keys,
      playlists: {'$base/list.m3u8': encryptedPlaylist.join('\n')},
    );
    final c = PlayerController(playlist: [item], startIndex: 0);
    controller = c;
    final player = c.player;
    subscriptions.addAll([
      player.stream.error.listen(errors.add),
      player.stream.position.listen((position) {
        if (position.inMilliseconds > maxPosition) maxPosition = position.inMilliseconds;
      }),
    ]);
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Video(controller: c.video, controls: NoVideoControls),
        ),
      ),
    );
    final completed = player.stream.completed.firstWhere((value) => value).timeout(const Duration(seconds: 40));
    await player.setVolume(0);
    await c.open();
    await completed;
    if (rejectedNative < 1 || browserSegments < segments.length || keyRequests != 0 || maxPosition < 2000) {
      throw StateError('Playback did not reach all rotating-key segments');
    }
    final report = {
      'native403': rejectedNative,
      'browserSegments': browserSegments,
      'jsonKeyRequests': keyRequests,
      'maxPositionMs': maxPosition,
      'errors': errors,
    };
    await File('D:/Data/Projects/OPlayer/.dart_tool/browser_playback_result.json').writeAsString(jsonEncode(report));
    debugPrint('BROWSER_PLAYBACK_OK ${jsonEncode(report)}');
  } catch (error, stack) {
    debugPrint('BROWSER_PLAYBACK_FAILED $error\n$stack');
    exitCode = 1;
  } finally {
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    controller?.dispose();
    await origin.close(force: true);
  }
  await Future<void>.delayed(const Duration(seconds: 5));
  exit(exitCode);
}
