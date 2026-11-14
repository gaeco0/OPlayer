import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oplayer/features/web/browser_download_transport.dart';

class _Browser extends BrowserDownloadTransport {
  _Browser(this.handle) : super('https://page.example/watch');
  final Future<BrowserFetchResponse> Function(Uri, Map<String, String>, String) handle;
  int calls = 0, closes = 0;
  @override
  Future<BrowserFetchResponse> open(Uri uri, Map<String, String> headers, {String method = 'GET'}) {
    calls++;
    return handle(uri, headers, method);
  }

  @override
  Future<void> close() async => closes++;
}

void main() {
  final uri = Uri.parse('https://cdn.example/segment.ts');
  test('native TLS failure falls back to browser Range streaming and keeps the origin on the browser', () async {
    final release = Completer<void>();
    final browser = _Browser((url, headers, method) async {
      expect(headers['Cookie'], 'session=test');
      if (method == 'HEAD') return BrowserFetchResponse(200, {}, url, const Stream.empty());
      expect(headers['Range'], 'bytes=100-103');
      Stream<List<int>> bytes() async* {
        yield [1, 2];
        await release.future;
        yield [3, 4];
      }

      return BrowserFetchResponse(206, {'content-length': '4'}, url, bytes());
    });
    var nativeCalls = 0;
    final client = BrowserDownloadClient(
      browser,
      native: MockClient((_) async {
        nativeCalls++;
        throw const HandshakeException('CERTIFICATE_VERIFY_FAILED');
      }),
    );
    addTearDown(() {
      release.complete();
      client.close();
    });
    final response = await client.send(
      http.Request('GET', uri)..headers.addAll({'Cookie': 'session=test', 'Range': 'bytes=100-103'}),
    );
    expect(response.statusCode, 206);
    final stream = StreamIterator(response.stream);
    expect(await stream.moveNext(), true);
    expect(stream.current, [1, 2]);
    final head = await client.send(http.Request('HEAD', uri)..headers['Cookie'] = 'session=test');
    expect(await head.stream.toBytes(), isEmpty);
    expect(browser.calls, 2);
    expect(nativeCalls, 1);
    await stream.cancel();
    await client.closeBrowser();
    client.close();
    await client.closeBrowser();
    expect(browser.closes, 1);
  });

  test('decompressed browser bytes do not retain encoded length', () async {
    final client = BrowserDownloadClient(
      _Browser(
        (url, headers, method) async =>
            BrowserFetchResponse(200, {'content-encoding': 'gzip', 'content-length': '999'}, url, Stream.value([1, 2])),
      ),
      native: MockClient((_) async => http.Response('', 403)),
    );
    addTearDown(client.close);
    final response = await client.send(http.Request('GET', uri));
    expect(response.contentLength, isNull);
    expect(response.headers, isNot(contains('content-encoding')));
    expect(await response.stream.toBytes(), [1, 2]);
  });

  test('browser TLS verification errors propagate without native retry or certificate bypass', () async {
    final browser = _Browser((_, __, ___) async => throw const HandshakeException('CERTIFICATE_VERIFY_FAILED'));
    final client = BrowserDownloadClient(browser, native: MockClient((_) async => http.Response('', 403)));
    addTearDown(client.close);
    await expectLater(client.send(http.Request('GET', uri)), throwsA(isA<HandshakeException>()));
    expect(browser.calls, 1);
    await expectLater(client.send(http.Request('POST', uri)), throwsA(isA<http.ClientException>()));
    expect(browser.calls, 1);
    client.close();
    await expectLater(client.send(http.Request('GET', uri)), throwsA(isA<http.ClientException>()));
  });
  test('successful native requests never fetch from WebView and fallback is isolated per origin', () async {
    var nativeCalls = 0;
    final browser = _Browser((url, headers, method) async => BrowserFetchResponse(200, {}, url, Stream.value([7])));
    final client = BrowserDownloadClient(
      browser,
      native: MockClient((request) async {
        nativeCalls++;
        return http.Response('native', request.url.host == 'blocked.example' ? 403 : 200);
      }),
    );
    addTearDown(client.close);
    expect(await client.read(uri), 'native');
    expect(browser.calls, 0);
    expect(await client.readBytes(Uri.parse('https://blocked.example/a')), [7]);
    expect(await client.readBytes(Uri.parse('https://blocked.example/b')), [7]);
    expect(await client.read(uri), 'native');
    expect(nativeCalls, 3);
    expect(browser.calls, 2);
  });

  test('only authentication/access blocks and explicit WAF challenge responses trigger browser fallback', () async {
    for (final status in [200, 202, 401, 403, 404, 500]) {
      for (final challenge in [false, true]) {
        final browser = _Browser((url, _, __) async => BrowserFetchResponse(200, {}, url, const Stream.empty()));
        final client = BrowserDownloadClient(
          browser,
          native: MockClient(
            (_) async => http.Response('', status, headers: challenge ? {'x-amzn-waf-action': 'challenge'} : {}),
          ),
        );
        await client.get(uri);
        expect(browser.calls, status == 401 || status == 403 || (status == 202 && challenge) ? 1 : 0);
        client.close();
      }
    }
  });

  test('ordinary socket failures propagate instead of silently switching transports', () async {
    final browser = _Browser((_, __, ___) async => throw StateError('Unexpected browser request'));
    final client = BrowserDownloadClient(
      browser,
      native: MockClient((_) async => throw const SocketException('offline')),
    );
    addTearDown(client.close);
    await expectLater(client.get(uri), throwsA(isA<SocketException>()));
    expect(browser.calls, 0);
  });
}
