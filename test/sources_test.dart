import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:oplayer/core/stream_proxy.dart';
import 'package:oplayer/features/web/hls.dart';
import 'package:oplayer/sources/webdav_source.dart';
import 'package:pointycastle/export.dart';

void main() {
  test('HLS master/media parse', () {
    const master =
        '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\nlow/index.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080\nhigh/index.m3u8\n';
    final base = Uri.parse('https://cdn.example.com/v/master.m3u8');
    expect(Hls.isMaster(master), true);
    final v = Hls.parseMaster(master, base);
    expect(v.first.uri.toString(), 'https://cdn.example.com/v/high/index.m3u8');

    const media =
        '#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:5\n'
        '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
        '#EXTINF:4.0,\nseg5.ts\n#EXTINF:4.0,\nseg6.ts\n#EXT-X-ENDLIST\n';
    final pl = Hls.parseMedia(media, Uri.parse('https://cdn.example.com/v/high/index.m3u8'));
    expect(pl.segments.length, 2);
    expect(pl.segments[1].sequence, 6);
    expect(pl.segments[0].key!.uri.toString(), 'https://cdn.example.com/v/high/key.bin');
    expect(pl.totalDuration, 8.0);
    expect(Hls.ivForSequence(6).last, 6);
  });

  test('AES-128 decrypt roundtrip', () {
    final key = Uint8List.fromList(List.generate(16, (i) => i));
    final iv = Hls.ivForSequence(3);
    final plain = Uint8List.fromList(List.generate(1000, (i) => i % 251));
    final enc = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
      ..init(true, PaddedBlockCipherParameters(ParametersWithIV(KeyParameter(key), iv), null));
    final cipher = enc.process(plain);
    expect(Hls.decryptAes128(cipher, key, iv), plain);
  });

  test('HLS keys accept raw bytes and encoded JSON values', () {
    final key = Uint8List.fromList(List.generate(16, (i) => i * 13));
    final hex = key.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    expect(Hls.parseAes128Key(key), key);
    for (final value in [
      {'key': base64.encode(key)},
      {
        'data': {'key': base64Url.encode(key).replaceAll('=', '')},
      },
      {
        'result': {'aes_key': '0X$hex'},
      },
      {'aesKey': key.toList()},
      key.toList(),
      base64.encode(key),
    ]) {
      expect(Hls.parseAes128Key(Uint8List.fromList(utf8.encode(jsonEncode(value)))), key);
    }
    expect(Hls.parseAes128Key(Uint8List.fromList(utf8.encode('$hex\n'))), key);
  });

  test('HLS rejects invalid key responses without exposing their contents', () {
    for (final body in [
      '<html>Sign in required</html>',
      '{"error":"PRIVATE_TOKEN login expired"}',
      '{"key":"not base64"}',
      jsonEncode({'key': List.filled(16, 256)}),
      jsonEncode({'key': base64.encode(List.generate(24, (i) => i))}),
      jsonEncode({'key': base64.encode(List.filled(32, 0))}),
    ]) {
      expect(
        () => Hls.parseAes128Key(Uint8List.fromList(utf8.encode(body))),
        throwsA(isA<FormatException>().having((e) => e.toString(), 'message', isNot(contains('PRIVATE_TOKEN')))),
      );
    }
    expect(() => Hls.decryptAes128(Uint8List(16), Uint8List(24), Uint8List(16)), throwsFormatException);
    expect(() => Hls.decryptAes128(Uint8List(16), Uint8List(16), Uint8List(15)), throwsFormatException);
    expect(
      () => Hls.parseAes128Key(
        Uint8List.fromList(utf8.encode('{"version":11,"encrypted_key":"ciphertext","key_length":16}')),
      ),
      throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('사이트 전용'))),
    );
  });

  test('StreamProxy serves byte ranges', () async {
    final data = List.generate(10000, (i) => i % 256);
    final url = await StreamProxy.instance.register(
      name: 'a.mp4',
      length: data.length,
      opener: (s, e) async => Stream.value(data.sublist(s, e)),
    );
    final full = await http.get(Uri.parse(url));
    expect(full.bodyBytes.length, 10000);
    final part = await http.get(Uri.parse(url), headers: {'Range': 'bytes=100-199'});
    expect(part.statusCode, HttpStatus.partialContent);
    expect(part.bodyBytes, data.sublist(100, 200));
    expect(part.headers['content-range'], 'bytes 100-199/10000');
    final tail = await http.get(Uri.parse(url), headers: {'Range': 'bytes=9990-'});
    expect(tail.bodyBytes.length, 10);
  });

  test('HTTP date parse', () {
    expect(HttpDateParser.parse('Mon, 19 Oct 2026 06:44:00 GMT'), DateTime.utc(2026, 10, 19, 6, 44));
  });
}
