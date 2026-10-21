import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:oplayer/core/media_item.dart';
import 'package:oplayer/features/cast/cast_relay.dart';
import 'package:oplayer/features/cast/dlna_renderer.dart';
import 'package:oplayer/sources/dlna_source.dart';
import 'package:xml/xml.dart';

void main() {
  test('casting a local file supports seeking and only exposes its registered token', () async {
    final directory = await Directory.systemTemp.createTemp('oplayer_cast_');
    final file = File('${directory.path}/movie.mp4');
    final bytes = List.generate(1024, (i) => i % 256);
    await file.writeAsBytes(bytes);
    final relay = CastRelay();
    try {
      final url = Uri.parse(
        await relay.start(
          MediaItem.local(file.path),
          Uri.parse('http://127.0.0.1'),
          bindAddress: InternetAddress.loopbackIPv4,
        ),
      );
      final response = await http.get(url, headers: {'Range': 'bytes=100-199'});
      expect(response.statusCode, 206);
      expect(response.bodyBytes, bytes.sublist(100, 200));
      expect(response.headers['content-range'], 'bytes 100-199/1024');
      final head = await http.head(url);
      expect(head.headers['content-length'], '1024');
      expect((await http.get(url.replace(path: '/unknown/movie.mp4'))).statusCode, 404);
    } finally {
      await relay.close();
      await directory.delete(recursive: true);
    }
  });

  test('casting HLS preserves authentication and rewrites relative URLs after redirects', () async {
    final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final key = List.generate(16, (i) => i);
    final paths = <String>[];
    final subscription = source.listen((request) async {
      paths.add(request.uri.path);
      if (request.headers.value('authorization') != 'Bearer test' || request.headers.value('cookie') != 'sid=test') {
        request.response.statusCode = 403;
      } else if (request.uri.path == '/start') {
        request.response.statusCode = 302;
        request.response.headers.set('location', '/stream/list.m3u8');
      } else if (request.uri.path.endsWith('.m3u8')) {
        request.response.headers.contentType = ContentType.parse('application/vnd.apple.mpegurl');
        request.response.write('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n#EXTINF:4,\nsegment.ts\n');
      } else if (request.uri.path == '/stream/key.bin') {
        request.response.add(key);
      } else {
        request.response.add([1, 2, 3]);
      }
      await request.response.close();
    });
    final relay = CastRelay();
    try {
      final url = Uri.parse(
        await relay.start(
          MediaItem.url(
            'http://127.0.0.1:${source.port}/start',
            headers: {'Authorization': 'Bearer test', 'Cookie': 'sid=test'},
          ),
          Uri.parse('http://127.0.0.1'),
          bindAddress: InternetAddress.loopbackIPv4,
        ),
      );
      final playlist = (await http.get(url)).body;
      final keyUrl = Uri.parse(RegExp(r'URI="([^"]+)"').firstMatch(playlist)![1]!);
      final segmentUrl = Uri.parse(playlist.split('\n').firstWhere((line) => line.startsWith('http')));
      expect(keyUrl.port, url.port);
      expect((await http.get(keyUrl)).bodyBytes, key);
      expect((await http.get(segmentUrl)).bodyBytes, [1, 2, 3]);
      expect(paths, containsAll(['/stream/key.bin', '/stream/segment.ts']));
    } finally {
      await relay.close();
      await subscription.cancel();
      await source.close(force: true);
    }
  });

  test('DLNA loads escaped metadata, seeks, controls volume and reads remote state', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final calls = <String, XmlDocument>{};
    final subscription = server.listen((request) async {
      final document = XmlDocument.parse(await utf8.decoder.bind(request).join());
      final action = request.headers.value('soapaction')!.split('#').last.replaceAll('"', '');
      calls[action] = document;
      request.response.headers.contentType = ContentType.parse('text/xml');
      final value = switch (action) {
        'GetTransportInfo' => '<CurrentTransportState>PLAYING</CurrentTransportState>',
        'GetPositionInfo' => '<RelTime>01:02:03.500</RelTime><TrackDuration>02:00:00</TrackDuration>',
        _ => '',
      };
      request.response.write(
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><Response>$value</Response></s:Body></s:Envelope>',
      );
      await request.response.close();
    });
    final renderer = DlnaRenderer(
      DlnaDevice(
        udn: 'test',
        name: 'TV',
        controlUrl: 'http://127.0.0.1:${server.port}/av',
        serviceType: 'urn:schemas-upnp-org:service:AVTransport:1',
        renderingControlUrl: 'http://127.0.0.1:${server.port}/volume',
      ),
    );
    try {
      await renderer.load('http://media.test/movie?a=1&b=2', 'A & <B>', 'video/mp4');
      final metadata = calls['SetAVTransportURI']!.findAllElements('CurrentURIMetaData').single.innerText;
      expect(XmlDocument.parse(metadata).findAllElements('title', namespace: '*').single.innerText, 'A & <B>');
      await renderer.pause();
      await renderer.seek(const Duration(hours: 1, minutes: 2, seconds: 3));
      expect(calls['Seek']!.findAllElements('Target').single.innerText, '01:02:03');
      await renderer.volume(0.75);
      expect(calls['SetVolume']!.findAllElements('DesiredVolume').single.innerText, '75');
      final status = await renderer.status();
      expect(status.playing, true);
      expect(status.position, const Duration(hours: 1, minutes: 2, seconds: 3, milliseconds: 500));
      expect(status.duration, const Duration(hours: 2));
      await renderer.stop();
      expect(calls.keys, containsAll(['Play', 'Pause', 'Stop']));
    } finally {
      await subscription.cancel();
      await server.close(force: true);
    }
  });
}
