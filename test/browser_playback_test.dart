import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:oplayer/features/web/browser_download_transport.dart';
import 'package:oplayer/features/web/browser_playback_proxy.dart';
import 'package:oplayer/features/web/hls.dart';

void main() {
  late HttpServer origin;
  late String base;
  late http.Client client;
  HttpOverrides? previous;
  setUp(() async {
    previous = HttpOverrides.current;
    HttpOverrides.global = null;
    origin = await HttpServer.bind('127.0.0.1', 0);
    base = 'http://127.0.0.1:${origin.port}';
    client = http.Client();
  });
  tearDown(() async {
    client.close();
    await origin.close(force: true);
    HttpOverrides.global = previous;
  });

  test('playback rewrites master, audio, maps and rotating identity keys without requesting JSON keys', () async {
    final keyA = Uint8List.fromList(List.generate(16, (i) => i));
    final keyB = Uint8List.fromList(List.generate(16, (i) => 16 + i));
    final master =
        '#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",URI="audio/list.m3u8"\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="a"\nvideo/list.m3u8\n';
    final video =
        '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:7\n'
        '#EXT-X-MAP:URI="init.mp4"\n#EXT-X-KEY:METHOD=AES-128,URI="../key-a?v=1"\n'
        '#EXTINF:4,\nfirst.m4s\n#EXT-X-KEY:METHOD=AES-128,URI="../key-b?v=2"\n'
        '#EXTINF:4,\nsecond.m4s\n#EXT-X-ENDLIST\n';
    var keyRequests = 0;
    origin.listen((request) async {
      if (request.uri.path.startsWith('/key')) {
        keyRequests++;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"encrypted_key":"site-specific"}');
      } else {
        expect(request.headers.value('authorization'), 'Bearer segment');
        expect(request.headers.value('origin'), 'https://player.example');
        expect(request.headers.value('referer'), 'https://player.example/watch');
        request.response.add([1, 2, 3, 4]);
      }
      await request.response.close();
    });
    final proxy = BrowserPlaybackProxy(
      url: '$base/master.m3u8',
      pageUrl: 'https://player.example/watch',
      headers: const {'Authorization': 'Bearer playlist'},
      hls: true,
      headersFor: (_) async => const {
        'Authorization': 'Bearer segment',
        'Origin': 'https://player.example',
        'Referer': 'https://player.example/watch',
      },
      keys: {'$base/key-a?v=1': keyA, '$base/key-b?v=2': keyB},
      playlists: {
        '$base/master.m3u8': master,
        '$base/video/list.m3u8': video,
        '$base/audio/list.m3u8': '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\naudio.aac\n#EXT-X-ENDLIST\n',
      },
    );
    addTearDown(proxy.close);
    final url = await proxy.start();
    final rewritten = await client.read(Uri.parse(url));
    final parsedMaster = Hls.parseMasterFull(rewritten, Uri.parse(url));
    expect(parsedMaster.variants.single.uri.host, '127.0.0.1');
    final media = await client.read(parsedMaster.variants.single.uri);
    final parsed = Hls.parseMedia(media, parsedMaster.variants.single.uri);
    expect(parsed.segments.map((s) => s.sequence), [7, 8]);
    expect(await client.readBytes(parsed.segments[0].key!.uri!), keyA);
    expect(await client.readBytes(parsed.segments[1].key!.uri!), keyB);
    expect(await client.readBytes(parsed.initSegment!), [1, 2, 3, 4]);
    expect(await client.readBytes(parsed.segments[1].uri), [1, 2, 3, 4]);
    final audio = Hls.parseMedia(await client.read(parsedMaster.audios.single.uri!), parsedMaster.audios.single.uri!);
    expect(await client.readBytes(audio.segments.single.uri), [1, 2, 3, 4]);
    expect(keyRequests, 0);
    expect((await client.get(Uri.parse(url).replace(path: '/wrong/0/media.ts'))).statusCode, 404);
  });

  test('403 fallback streams browser bytes before EOF and forwards seek range and session headers', () async {
    origin.listen((request) async {
      request.response.statusCode = 403;
      await request.response.close();
    });
    final release = Completer<void>();
    var browserCalls = 0;
    final proxy = BrowserPlaybackProxy(
      url: '$base/video.mp4',
      pageUrl: '$base/watch',
      headers: const {'Cookie': 'session=abc', 'Origin': 'https://player.example'},
      length: 1000000,
      browserOpen: (uri, headers, method) async {
        browserCalls++;
        expect(headers['Cookie'], 'session=abc');
        expect(headers['Origin'], 'https://player.example');
        expect(headers['Range'], 'bytes=100-103');
        Stream<List<int>> body() async* {
          yield [1, 2];
          await release.future;
          yield [3, 4];
        }

        return BrowserFetchResponse(206, {'content-type': 'video/mp4', 'content-length': '4'}, uri, body());
      },
    );
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await proxy.close();
    });
    final url = await proxy.start();
    final result = await client.send(http.Request('GET', Uri.parse(url))..headers['Range'] = 'bytes=100-103');
    expect(result.statusCode, 206);
    expect(result.headers['content-range'], 'bytes 100-103/1000000');
    final chunks = StreamIterator(result.stream);
    expect(await chunks.moveNext().timeout(const Duration(seconds: 3)), true);
    expect(chunks.current, [1, 2]);
    release.complete();
    final received = <int>[...chunks.current];
    while (await chunks.moveNext()) {
      received.addAll(chunks.current);
    }
    expect(received, [1, 2, 3, 4]);
    expect(browserCalls, 1);
    await chunks.cancel();
  });

  test('redirected playlists resolve segments against final URL and live playlists refresh', () async {
    var calls = 0;
    origin.listen((request) async {
      if (request.uri.path == '/start') {
        request.response.statusCode = 302;
        request.response.headers.set('Location', '/final/live.m3u8');
      } else if (request.uri.path == '/final/live.m3u8') {
        request.response.write(
          '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:${++calls}\n#EXTINF:4,\nsegment.ts\n',
        );
      } else {
        expect(request.uri.path, '/final/segment.ts');
        request.response.add([5, 6]);
      }
      await request.response.close();
    });
    final proxy = BrowserPlaybackProxy(url: '$base/start', pageUrl: '$base/watch', headers: const {}, hls: true);
    addTearDown(proxy.close);
    final url = Uri.parse(await proxy.start());
    final first = Hls.parseMedia(await client.read(url), url);
    expect(await client.readBytes(first.segments.single.uri), [5, 6]);
    final second = Hls.parseMedia(await client.read(url), url);
    expect(first.segments.single.sequence, 1);
    expect(second.segments.single.sequence, 2);
  });

  test('unsupported encryption reports an error instead of serving invalid media', () async {
    final proxy = BrowserPlaybackProxy(
      url: '$base/list.m3u8',
      pageUrl: '$base/watch',
      headers: const {},
      hls: true,
      playlists: {
        '$base/list.m3u8':
            '#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="secret"\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n',
      },
    );
    addTearDown(proxy.close);
    Object? error;
    proxy.onError = (value) => error = value;
    final response = await client.get(Uri.parse(await proxy.start()));
    expect(response.statusCode, 502);
    expect(error, isFormatException);
    expect(utf8.decode(response.bodyBytes), isNot(contains('secret')));
  });
}
