import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../core/media_item.dart';
import '../../core/stream_proxy.dart';
import '../web/request_headers.dart';

/// Exposes only the selected media and its HLS children, behind unguessable URLs.
class CastRelay {
  HttpServer? _server;
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  final _routes = <String, Uri>{};
  Map<String, String> _headers = {};
  String? _localProxy;
  String mime = 'video/mp4';

  Future<String> start(
    MediaItem media,
    Uri receiver, {
    InternetAddress? bindAddress,
  }) async {
    final address = bindAddress ?? await _localAddress(receiver);
    final server = await HttpServer.bind(address, 0);
    _server = server;
    server.listen(_handle, onError: (_) {});
    _headers = BrowserRequestHeaders.replay(media.headers ?? const {});
    Uri upstream;
    final uri = Uri.tryParse(media.uri);
    if (media.localPath != null ||
        uri == null ||
        !uri.hasScheme ||
        uri.scheme == 'file') {
      final file = File(
        media.localPath ??
            (uri?.scheme == 'file' ? uri!.toFilePath() : media.uri),
      );
      _localProxy = await StreamProxy.instance.register(
        name: file.path,
        length: await file.length(),
        opener: (start, end) async => file.openRead(start, end),
      );
      upstream = Uri.parse(_localProxy!);
      mime = StreamProxy.mimeOf(file.path);
    } else {
      if (!['http', 'https'].contains(uri.scheme)) {
        throw const FormatException('이 소스는 먼저 로컬에 받은 뒤 외부 기기로 재생해 주세요');
      }
      upstream = uri;
      mime = StreamProxy.mimeOf(uri.path);
      if (mime == 'application/octet-stream') mime = 'video/mp4';
      try {
        final request = await _client.headUrl(upstream);
        _headers.forEach((k, v) => request.headers.set(k, v));
        final response = await request.close();
        if (response.statusCode < 300 && response.headers.contentType != null) {
          mime = response.headers.contentType!.mimeType;
        }
        await response.drain<void>();
      } catch (_) {}
    }
    return _register(upstream);
  }

  static Future<InternetAddress> _localAddress(Uri receiver) async {
    try {
      final socket = await Socket.connect(
        receiver.host,
        receiver.hasPort ? receiver.port : 80,
        timeout: const Duration(seconds: 2),
      );
      final address = socket.address;
      socket.destroy();
      if (!address.isLoopback) return address;
    } catch (_) {}
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    final addresses = interfaces
        .expand((i) => i.addresses)
        .where((a) => !a.isLoopback)
        .toList();
    if (addresses.isEmpty) {
      throw const FormatException('TV와 같은 로컬 네트워크에 연결해 주세요');
    }
    final prefix = receiver.host.split('.').take(3).join('.');
    return addresses
            .where((a) => a.address.startsWith('$prefix.'))
            .firstOrNull ??
        addresses.first;
  }

  String _register(Uri uri) {
    if (!['http', 'https'].contains(uri.scheme)) return uri.toString();
    final previous = _routes.entries.where((e) => e.value == uri).firstOrNull;
    final random = Random.secure();
    final token =
        previous?.key ??
        List.generate(
          24,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
    _routes[token] = uri;
    return Uri(
      scheme: 'http',
      host: _server!.address.address,
      port: _server!.port,
      path: '/$token/${uri.pathSegments.lastOrNull ?? 'media'}',
    ).toString();
  }

  Future<void> _handle(HttpRequest incoming) async {
    final out = incoming.response;
    try {
      final token = incoming.uri.pathSegments.firstOrNull;
      final uri = _routes[token];
      if (uri == null) {
        out.statusCode = 404;
        await out.close();
        return;
      }
      out.headers.set('Access-Control-Allow-Origin', '*');
      out.headers.set('Access-Control-Allow-Headers', 'Range, Content-Type');
      out.headers.set(
        'Access-Control-Expose-Headers',
        'Content-Length, Content-Range, Accept-Ranges',
      );
      if (incoming.method == 'OPTIONS') {
        out.headers.set('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS');
        await out.close();
        return;
      }
      if (!['GET', 'HEAD'].contains(incoming.method)) {
        out.statusCode = 405;
        await out.close();
        return;
      }
      final request = await _client.openUrl(incoming.method, uri);
      _headers.forEach((k, v) => request.headers.set(k, v));
      request.headers.set('Accept-Encoding', 'identity');
      final range = incoming.headers.value('range');
      if (range != null) request.headers.set('Range', range);
      final response = await request.close();
      out.statusCode = response.statusCode;
      for (final name in ['content-type', 'content-range', 'accept-ranges']) {
        final value = response.headers.value(name);
        if (value != null) out.headers.set(name, value);
      }
      out.headers.set('transferMode.dlna.org', 'Streaming');
      out.headers.set(
        'contentFeatures.dlna.org',
        'DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000',
      );
      final isPlaylist =
          (response.headers.contentType?.mimeType ?? '').contains('mpegurl') ||
          uri.path.endsWith('.m3u8');
      if (isPlaylist && incoming.method == 'GET' && response.statusCode < 300) {
        var base = uri;
        for (final redirect in response.redirects) {
          base = base.resolveUri(redirect.location);
        }
        final text = await utf8.decoder.bind(response).join();
        final rewritten = text
            .split('\n')
            .map((line) {
              if (line.trim().isEmpty) return line;
              if (!line.startsWith('#')) {
                return _register(base.resolve(line.trim()));
              }
              return line.replaceAllMapped(
                RegExp(r'URI="([^"]+)"'),
                (m) => 'URI="${_register(base.resolve(m[1]!))}"',
              );
            })
            .join('\n');
        final bytes = utf8.encode(rewritten);
        out.headers.contentType = ContentType.parse(
          'application/vnd.apple.mpegurl',
        );
        out.contentLength = bytes.length;
        out.add(bytes);
      } else {
        if (response.contentLength >= 0 &&
            response.compressionState !=
                HttpClientResponseCompressionState.decompressed) {
          out.contentLength = response.contentLength;
        }
        if (incoming.method == 'HEAD') {
          await response.drain<void>();
        } else {
          await out.addStream(response);
        }
      }
      await out.close();
    } catch (_) {
      try {
        out.statusCode = 502;
        await out.close();
      } catch (_) {}
    }
  }

  Future<void> close() async {
    _client.close(force: true);
    await _server?.close(force: true);
    if (_localProxy != null) StreamProxy.instance.unregister(_localProxy!);
    _routes.clear();
  }
}
