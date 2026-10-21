import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/web/download_manager.dart';
import 'package:oplayer/features/web/hls.dart';
import 'package:oplayer/features/web/request_headers.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // These integration fixtures use real loopback HTTP servers.
  HttpOverrides.global = null;
  test('ExtraInfo may arrive before or after its request', () {
    for (final early in [true, false]) {
      final h = BrowserRequestHeaders();
      void extra() => h.extra('1', {'cookie': 'session=ok', 'authorization': 'new'});
      if (early) extra();
      h.request('1', 'https://cdn.test/master.m3u8', {'Authorization': 'old', 'X-Token': 'token'});
      if (!early) extra();
      expect(h.forUrl('https://cdn.test/master.m3u8'), {
        'authorization': 'new',
        'x-token': 'token',
        'cookie': 'session=ok',
      });
    }
  });

  test('redirects pair headers in order; repeated URLs discard old credentials', () {
    final h = BrowserRequestHeaders();
    h.request('1', 'https://a.test/hls', {'Authorization': 'first'});
    h.request('1', 'https://b.test/hls', {'X-Token': 'second'});
    h.extra('1', {'Cookie': 'a=1'});
    h.extra('1', {'Cookie': 'b=2'});
    expect(h.forUrl('https://a.test/hls')!['cookie'], 'a=1');
    expect(h.forUrl('https://b.test/hls'), {'x-token': 'second', 'cookie': 'b=2'});
    h.request('2', 'https://a.test/hls', {'Accept': '*/*'});
    expect(h.forUrl('https://a.test/hls'), {'accept': '*/*'});
    h.clear();
    expect(h.forUrl('https://a.test/hls'), isNull);
    expect(h.hasNative('https://a.test/hls'), isFalse);
  });

  test('script fallback cannot overwrite native headers or disconnect late ExtraInfo', () {
    final h = BrowserRequestHeaders();
    const url = 'https://cdn.test/hls';
    h.capture(url, {'X-Token': 'old'}, fallback: true);
    h.capture(url, {'X-Token': 'new'}, fallback: true);
    expect(h.forUrl(url)!['x-token'], 'new');
    expect(h.hasNative(url), isFalse);
    h.request('1', url, {'X-Token': 'native'});
    h.capture(url, {'X-Token': 'script'}, fallback: true);
    h.extra('1', {'Cookie': 'session=ok'});
    expect(h.forUrl(url), {'x-token': 'native', 'cookie': 'session=ok'});
    expect(h.hasNative(url), isTrue);
  });

  test('replay preserves arbitrary request headers without adding Origin or Referer', () {
    final h = BrowserRequestHeaders.replay({
      'authorization': 'Bearer token',
      'cookie': 'session=ok',
      'x-site-signature': 'signed',
      'sec-ch-ua': 'browser',
      ':authority': 'cdn.test',
      'Host': 'cdn.test',
      'Range': 'bytes=0-1',
      'Accept-Encoding': 'br',
      'If-None-Match': 'cached',
    });
    expect(h, {
      'Authorization': 'Bearer token',
      'Cookie': 'session=ok',
      'X-Site-Signature': 'signed',
      'Sec-Ch-Ua': 'browser',
    });
  });

  for (final useBrowserKey in [false, true]) {
    test('HLS headers and ${useBrowserKey ? 'browser-resolved' : 'JSON'} keys reach all tracks', () async {
      SharedPreferences.setMockInitialValues({});
      await AppSettings.instance.init();
      await DownloadManager.instance.init();
      final dir = await Directory.systemTemp.createTemp('oplayer_headers_');
      AppSettings.instance.downloadDir = dir.path;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final seen = <String>{};
      final failures = <String>[];
      final headers = BrowserRequestHeaders.replay({
        'Authorization': 'Bearer test',
        'Cookie': 'session=test',
        'Referer': 'https://player.test/embed',
        'Origin': 'https://player.test',
        'User-Agent': 'Browser/Test',
        'X-Site-Token': 'custom',
        'Sec-Fetch-Mode': 'cors',
      });
      final key = Uint8List(16);
      final rotatedKey = Uint8List(16)..fillRange(0, 16, 1);
      String mediaPlaylist(String track, String suffix) =>
          '#EXTM3U\n#EXT-X-MAP:URI="init.mp4"\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin$suffix"\n'
          '#EXTINF:4,\n$track.m4s\n#EXT-X-KEY:METHOD=AES-128,URI="key2.bin$suffix"\n'
          '#EXTINF:4,\n${track}2.m4s\n#EXT-X-ENDLIST\n';
      final enc = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
        ..init(true, PaddedBlockCipherParameters(ParametersWithIV(KeyParameter(key), Hls.ivForSequence(0)), null));
      final encrypted = enc.process(Uint8List.fromList([1, 2, 3, 4]));
      final rotatedEnc = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
        ..init(
          true,
          PaddedBlockCipherParameters(ParametersWithIV(KeyParameter(rotatedKey), Hls.ivForSequence(1)), null),
        );
      final rotatedEncrypted = rotatedEnc.process(Uint8List.fromList([5, 6, 7, 8]));
      final sub = server.listen((r) async {
        seen.add(r.uri.path);
        for (final e in headers.entries) {
          if (r.headers.value(e.key) != e.value) {
            failures.add('${r.uri.path}: ${e.key}');
          }
        }
        switch (r.uri.path) {
          case '/master.m3u8':
            r.response.write(
              '#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="main",DEFAULT=YES,URI="audio.m3u8"\n'
              '#EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="a"\nvideo.m3u8\n',
            );
          case '/video.m3u8':
          case '/audio.m3u8':
            r.response.write(
              mediaPlaylist(r.uri.path == '/video.m3u8' ? 'video' : 'audio', useBrowserKey ? '?session=refetched' : ''),
            );
          case '/key.bin':
          case '/key2.bin':
            r.response.headers.contentType = ContentType.json;
            r.response.write(
              jsonEncode(
                useBrowserKey
                    ? {'encrypted_key': 'site-cipher', 'version': 11}
                    : {
                        'data': {'key': base64.encode(r.uri.path == '/key.bin' ? key : rotatedKey)},
                      },
              ),
            );
          case '/init.mp4':
            r.response.add([0, 0, 0, 0]);
          default:
            r.response.add(r.uri.path.endsWith('2.m4s') ? rotatedEncrypted : encrypted);
        }
        await r.response.close();
      });
      final manager = DownloadManager.instance;
      final finished = Completer<void>();
      DownloadTask? task;
      void changed() {
        if (task != null &&
            [DownloadStatus.done, DownloadStatus.failed].contains(task.status) &&
            !finished.isCompleted) {
          finished.complete();
        }
      }

      manager.addListener(changed);
      try {
        task = manager.add(
          url: 'http://127.0.0.1:${server.port}/master.m3u8',
          title: 'headers',
          headers: headers,
          hlsKeys: useBrowserKey
              ? {
                  'http://127.0.0.1:${server.port}/key.bin?session=browser': key,
                  'http://127.0.0.1:${server.port}/key2.bin?session=browser': rotatedKey,
                }
              : {},
          hlsPlaylists: useBrowserKey
              ? {
                  'http://127.0.0.1:${server.port}/video.m3u8': mediaPlaylist('video', '?session=browser'),
                  'http://127.0.0.1:${server.port}/audio.m3u8': mediaPlaylist('audio', '?session=browser'),
                }
              : {},
          hls: true,
        );
        await finished.future.timeout(const Duration(seconds: 30));
        expect(task.status, DownloadStatus.done, reason: task.error);
        expect(failures, isEmpty);
        expect(
          seen,
          containsAll([
            '/master.m3u8',
            if (!useBrowserKey) '/video.m3u8',
            if (!useBrowserKey) '/audio.m3u8',
            if (!useBrowserKey) '/key.bin',
            if (!useBrowserKey) '/key2.bin',
            '/init.mp4',
            '/video.m4s',
            '/audio.m4s',
            '/video2.m4s',
            '/audio2.m4s',
          ]),
        );
        expect(DownloadTask.fromJson(task.toJson()).headers, headers);
        if (useBrowserKey) {
          expect(seen, isNot(contains('/key.bin')));
          expect(seen, isNot(contains('/key2.bin')));
          expect(seen, isNot(contains('/video.m3u8')));
          expect(seen, isNot(contains('/audio.m3u8')));
        }
        expect(DownloadTask.fromJson(task.toJson()).hlsKeys, isEmpty);
      } finally {
        manager.removeListener(changed);
        if (task != null) await manager.remove(task, deleteFile: true);
        await sub.cancel();
        await server.close(force: true);
        AppSettings.instance.downloadDir = null;
        await dir.delete(recursive: true);
      }
    });
  }
}
