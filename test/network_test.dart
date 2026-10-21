import 'package:oplayer/core/network/network_service.dart';
import 'package:oplayer/core/resume_store.dart';
import 'package:oplayer/sources/source_registry.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oplayer/core/network/doh_resolver.dart';
import 'package:oplayer/core/network/local_proxy.dart';
import 'package:oplayer/core/network/tunnel_socket.dart';
import 'package:oplayer/core/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('network scope bypasses resources only and browser origin survives recent playback', () async {
    final url = Uri.parse('https://example.com/movie.mp4');
    expect(useNetworkProxy(url, enabled: true, browser: false, resources: false), false);
    expect(useNetworkProxy(url, enabled: true, browser: true, resources: false), true);
    expect(useNetworkProxy(url, enabled: true, browser: false, resources: true), true);
    expect(useNetworkProxy(url, enabled: false, browser: true, resources: true), false);
    expect(
      useNetworkProxy(Uri.parse('https://192.168.1.10/movie.mp4'), enabled: true, browser: true, resources: true),
      false,
    );
    SharedPreferences.setMockInitialValues({
      'settings_v1': jsonEncode({'networkForResources': false}),
    });
    await AppSettings.instance.init();
    expect(AppSettings.instance.networkForResources, false);
    AppSettings.instance.update((s) {
      s.dohEnabled = true;
      s.networkForResources = true;
    });
    await Future<void>.delayed(Duration.zero);
    await AppSettings.instance.init();
    expect(AppSettings.instance.networkForResources, true);
    await ResumeStore.instance.init();
    await ResumeStore.instance.save(
      url.toString(),
      const Duration(seconds: 1),
      const Duration(seconds: 60),
      browserMedia: true,
    );
    await ResumeStore.instance.init();
    expect((await SourceRegistry.instance.itemFromKey(url.toString()))!.browserMedia, true);
  });

  test('resource proxy is opt-in, requires either feature and resets when both turn off', () async {
    final s = AppSettings.instance;
    for (final saved in [
      <String, dynamic>{},
      {'networkForResources': true},
      {'dohEnabled': true},
      {'byeDpiEnabled': true},
    ]) {
      SharedPreferences.setMockInitialValues({'settings_v1': jsonEncode(saved)});
      await s.init();
      expect(s.networkForResources, false);
    }
    s.update((s) => s.networkForResources = true);
    expect(s.networkForResources, true); // ByeDPI remains enabled from the last saved case.
    s.update((s) {
      s.dohEnabled = true;
      s.byeDpiEnabled = false;
    });
    expect(s.networkForResources, true);
    s.update((s) => s.dohEnabled = false);
    expect(s.networkEnabled, false);
    expect(s.networkForResources, false);
    s.update((s) => s.networkForResources = true);
    expect(s.networkForResources, false);
    s.update((s) => s.dohEnabled = true);
    expect(s.networkForResources, false);
    s.update((s) => s.networkForResources = true);
    await Future<void>.delayed(Duration.zero);
    await s.init();
    expect(s.networkForResources, true);
    s.update((s) => s.dohEnabled = false);
    await Future<void>.delayed(Duration.zero);
    await s.init();
    expect(s.networkForResources, false);
  });

  test('network defaults migrate once and preserve subsequently chosen DoH URLs', () async {
    SharedPreferences.setMockInitialValues({
      'settings_v1': jsonEncode({'dohUrl': 'https://cloudflare-dns.com/dns-query'}),
    });
    final settings = AppSettings.instance;
    await settings.init();
    expect(settings.dohUrl, 'https://dns.google/dns-query');
    settings.update((s) => s.dohUrl = 'https://cloudflare-dns.com/dns-query');
    await Future<void>.delayed(Duration.zero);
    await settings.init();
    expect(settings.dohUrl, 'https://cloudflare-dns.com/dns-query');
  });
  test('bundled Windows ByeDPI engine starts with shipped strategy and transfers HTTP', () async {
    final origin = await HttpServer.bind('127.0.0.1', 0);
    final reservation = await ServerSocket.bind('127.0.0.1', 0);
    final port = reservation.port;
    await reservation.close();
    final process = await Process.start(File('assets/native/windows/ciadpi.exe').absolute.path, [
      '--ip',
      '127.0.0.1',
      '--port',
      '$port',
      '--no-udp',
      '--disorder',
      '1',
      '--auto=torst',
      '--tlsrec',
      '1+s',
    ]);
    process.stdout.drain<void>();
    final errors = process.stderr.transform(utf8.decoder).join();
    addTearDown(() async {
      process.kill();
      await process.exitCode;
      await errors;
      await origin.close(force: true);
    });
    origin.listen((request) async {
      request.response.write('ByeDPI native engine OK');
      await request.response.close();
    });
    TunnelSocket? tunnel;
    for (var attempt = 0; attempt < 30 && tunnel == null; attempt++) {
      try {
        tunnel = await TunnelSocket.socks5('127.0.0.1', port, '127.0.0.1', origin.port);
      } on SocketException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    expect(tunnel, isNotNull, reason: 'Bundled ByeDPI did not listen');
    final connected = tunnel!;
    addTearDown(connected.close);
    connected.socket.add(ascii.encode('GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n'));
    final reply = await connected.stream.transform(utf8.decoder).join().timeout(const Duration(seconds: 10));
    expect(reply, contains('200 OK'));
    expect(reply, contains('ByeDPI native engine OK'));
  }, skip: !Platform.isWindows);

  test('DoH wire queries coalesce and cache validated DNS responses', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    addTearDown(() async {
      client.close(force: true);
      await server.close(force: true);
    });
    var queries = 0;
    server.listen((request) async {
      queries++;
      expect(request.method, 'POST');
      expect(request.headers.value('content-type'), 'application/dns-message');
      final question = await request.fold<List<int>>([], (out, bytes) => out..addAll(bytes));
      final response = <int>[
        ...question.take(2),
        0x81,
        0x80,
        0,
        1,
        0,
        1,
        0,
        0,
        0,
        0,
        ...question.skip(12),
        0xc0,
        12,
        0,
        1,
        0,
        1,
        0,
        0,
        0,
        60,
        0,
        4,
        203,
        0,
        113,
        12,
      ];
      request.response.headers.contentType = ContentType('application', 'dns-message');
      request.response.add(response);
      await request.response.close();
    });
    final resolver = DohResolver(Uri.parse('http://127.0.0.1:${server.port}/dns-query'), client);
    final results = await Future.wait(List.generate(8, (_) => resolver.lookup('example.test')));
    expect(results.every((list) => list.single.address == '203.0.113.12'), true);
    expect((await resolver.lookup('example.test')).single.address, '203.0.113.12');
    expect(queries, 1);
    resolver.clear();
    await resolver.lookup('example.test');
    expect(queries, 2);
  });

  test('DNS parser rejects wrong IDs, truncation and failure codes; accepts IPv6', () {
    final packet = Uint8List.fromList([
      0,
      9,
      0x81,
      0x80,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      0,
      0,
      28,
      0,
      1,
      0,
      0,
      0,
      30,
      0,
      16,
      0x20,
      1,
      0x0d,
      0xb8,
      ...List.filled(11, 0),
      1,
    ]);
    final (addresses, ttl) = DohResolver.parseResponse(packet, 9);
    expect(addresses.single.address, '2001:db8::1');
    expect(ttl, 30);
    expect(() => DohResolver.parseResponse(packet, 8), throwsFormatException);
    expect(() => DohResolver.parseResponse(Uint8List.sublistView(packet, 0, 20), 9), throwsFormatException);
    final failure = Uint8List.fromList(packet)..[3] = 0x83;
    expect(() => DohResolver.parseResponse(failure, 9), throwsFormatException);
    final truncated = Uint8List.fromList(packet)..[2] = 0x83;
    expect(() => DohResolver.parseResponse(truncated, 9), throwsFormatException);
    expect(validDohUrl('https://cloudflare-dns.com/dns-query'), true);
    expect(validDohUrl('http://dns.example/query'), false);
    expect(validDohUrl('https://user:password@dns.example/query'), false);
    expect(localNetworkHost('192.168.1.5'), true);
    expect(localNetworkHost('172.31.2.3'), true);
    expect(localNetworkHost('172.32.2.3'), false);
    expect(localNetworkHost('nas.local'), true);
    expect(localNetworkHost('::1'), true);
    expect(localNetworkHost('example.com'), false);
  });

  test('HTTP proxy preserves headers and chunked binary request/response data', () async {
    final origin = await HttpServer.bind('127.0.0.1', 0);
    final proxy = LocalProxy((host, port) async {
      expect(host, 'media.example');
      expect(port, origin.port);
      return TunnelSocket(await Socket.connect('127.0.0.1', port));
    });
    await proxy.start();
    final client = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:${proxy.port}';
    addTearDown(() async {
      client.close(force: true);
      await proxy.close();
      await origin.close(force: true);
    });
    final body = List.generate(150000, (i) => i % 256);
    origin.listen((request) async {
      expect(request.uri.toString(), '/upload?token=a%2Bb');
      expect(request.headers.value('origin'), 'https://player.example');
      expect(request.headers.value('referer'), 'https://player.example/watch');
      expect(request.headers.value('x-test-header'), 'retained');
      final received = await request.fold<List<int>>([], (out, bytes) => out..addAll(bytes));
      expect(received, body);
      request.response.headers.set('X-Reply', 'yes');
      request.response.add(received);
      await request.response.close();
    });
    final request = await client.postUrl(Uri.parse('http://media.example:${origin.port}/upload?token=a%2Bb'));
    request.headers.set('Origin', 'https://player.example');
    request.headers.set('Referer', 'https://player.example/watch');
    request.headers.set('X-Test-Header', 'retained');
    request.add(body.sublist(0, 75000));
    await request.flush();
    request.add(body.sublist(75000));
    final response = await request.close();
    expect(response.statusCode, 200);
    expect(response.headers.value('x-reply'), 'yes');
    expect(await response.fold<List<int>>([], (out, bytes) => out..addAll(bytes)), body);
  });

  test('CONNECT preserves buffered bytes and opaque binary traffic through SOCKS5', () async {
    final socks = await ServerSocket.bind('127.0.0.1', 0);
    socks.listen((socket) async {
      final peer = TunnelSocket(socket);
      try {
        expect(await peer.read(3), [5, 1, 0]);
        socket.add([5]);
        await socket.flush();
        socket.add([0]);
        expect(await peer.read(5), [5, 1, 0, 3, 13]);
        expect(ascii.decode(await peer.read(13)), 'media.example');
        expect(await peer.read(2), [1, 187]);
        socket.add([5, 0, 0, 1, 127, 0, 0, 1, 0, 0]);
        await socket.addStream(peer.stream);
      } finally {
        peer.close();
      }
    });
    final proxy = LocalProxy((host, port) => TunnelSocket.socks5('127.0.0.1', socks.port, host, port));
    await proxy.start();
    final raw = await Socket.connect('127.0.0.1', proxy.port);
    final client = TunnelSocket(raw);
    addTearDown(() async {
      client.close();
      await proxy.close();
      await socks.close();
    });
    final payload = List.generate(120000, (i) => (i * 37) % 256);
    raw.add([...ascii.encode('CONNECT media.example:443 HTTP/1.1\r\nHost: media.example:443\r\n\r\n'), ...payload]);
    expect(await client.readHeader(), startsWith('HTTP/1.1 200'));
    expect(await client.read(payload.length), payload);
  });
}
