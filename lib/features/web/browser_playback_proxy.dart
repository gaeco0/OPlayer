import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../core/network/network_service.dart';
import '../../core/media_item.dart';
import 'browser_download_transport.dart';
import 'hls.dart';
import 'request_headers.dart';

typedef BrowserMediaOpener = Future<BrowserFetchResponse> Function(Uri uri, Map<String, String> headers, String method);

class BrowserPlaybackRegistry {
  static final _items = <String, MediaItem>{};
  static MediaItem? find(String url) => _items[url];

  static MediaItem remember({
    required String url,
    required String title,
    required String pageUrl,
    required Map<String, String> headers,
    required bool hls,
    int length = 0,
    Map<String, Uint8List> keys = const {},
    Map<String, String> playlists = const {},
    Map<String, Map<String, String>> requestHeaders = const {},
  }) {
    final savedKeys = {for (final e in keys.entries) e.key: Uint8List.fromList(e.value)};
    final savedPlaylists = Map<String, String>.of(playlists);
    final savedHeaders = Map<String, String>.of(headers);
    final requests = {for (final e in requestHeaders.entries) e.key: Map<String, String>.of(e.value)};
    final item = MediaItem(
      key: url,
      uri: url,
      title: title,
      browserMedia: true,
      resolver: () async {
        final errors = StreamController<String>.broadcast();
        final proxy = BrowserPlaybackProxy(
          url: url,
          pageUrl: pageUrl,
          headers: savedHeaders,
          hls: hls,
          length: length,
          keys: savedKeys,
          playlists: savedPlaylists,
          headersFor: (uri) async => requests[uri.toString()] ?? savedHeaders,
        );
        proxy.onError = (error) {
          if (!errors.isClosed) errors.add('브라우저 재생 요청 실패: $error');
        };
        Future<void> release() async {
          await proxy.close();
          await errors.close();
        }

        try {
          final local = await proxy.start();
          return MediaItem(
            key: url,
            uri: local,
            title: title,
            browserMedia: true,
            onRelease: release,
            playbackErrors: errors.stream,
          );
        } catch (_) {
          await release();
          rethrow;
        }
      },
    );
    _items.remove(url);
    _items[url] = item;
    while (_items.length > 12) {
      _items.remove(_items.keys.first);
    }
    return item;
  }
}

class _Resource {
  _Resource(this.uri, this.playlist, this.key);
  final Uri uri;
  final bool playlist;
  final bool key;
}

/// Gives mpv the same browser session, playlists and identity AES keys as downloads.
/// Only registered URLs are exposed, behind a random loopback-only capability.
class BrowserPlaybackProxy {
  BrowserPlaybackProxy({
    required this.url,
    required String pageUrl,
    required Map<String, String> headers,
    this.hls = false,
    this.length = 0,
    Map<String, Uint8List> keys = const {},
    Map<String, String> playlists = const {},
    this.headersFor,
    BrowserMediaOpener? browserOpen,
  }) : _headers = BrowserRequestHeaders.replay(headers),
       _keys = {for (final e in keys.entries) e.key: Uint8List.fromList(e.value)},
       _playlists = Map.of(playlists),
       _browser = BrowserDownloadTransport(pageUrl),
       _browserOpen = browserOpen;

  final String url;
  final bool hls;
  final int length;
  final Map<String, String> _headers;
  final Map<String, Uint8List> _keys;
  final Map<String, String> _playlists;
  final Future<Map<String, String>> Function(Uri)? headersFor;
  final BrowserDownloadTransport _browser;
  final BrowserMediaOpener? _browserOpen;
  final _client = NetworkService.instance.createHttpClient(browser: true);
  final _resources = <_Resource>[];
  final _ids = <String, int>{};
  final _served = <String>{};
  final _browserHosts = <String>{};
  final _token = base64UrlEncode(List.generate(24, (_) => Random.secure().nextInt(256))).replaceAll('=', '');
  HttpServer? _server;
  bool _closed = false;
  void Function(Object)? onError;

  Future<String> start() async {
    if (_closed) throw StateError('재생 연결이 종료됐습니다');
    _server ??= await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_serve, onError: (_) {});
    return _register(Uri.parse(url), playlist: hls);
  }

  String _register(Uri uri, {bool playlist = false, bool key = false}) {
    if (!['http', 'https'].contains(uri.scheme) || uri.userInfo.isNotEmpty) {
      throw const FormatException('지원하지 않는 미디어 주소입니다');
    }
    final kind = key
        ? 'key'
        : playlist
        ? 'playlist'
        : 'media';
    final id = _ids.putIfAbsent('$kind:$uri', () {
      if (_resources.length >= 30000) throw const FormatException('재생목록이 너무 큽니다');
      _resources.add(_Resource(uri, playlist, key));
      return _resources.length - 1;
    });
    final name = key
        ? 'key.bin'
        : playlist
        ? 'playlist.m3u8'
        : uri.pathSegments.lastOrNull?.contains('.') == true
        ? uri.pathSegments.last
        : 'media.ts';
    return 'http://127.0.0.1:${_server!.port}/$_token/$id/${Uri.encodeComponent(name)}';
  }

  String _rewrite(String text, Uri base) {
    if (!Hls.isPlaylist(text)) throw const FormatException('HLS 재생목록이 아닙니다');
    var variant = false;
    return text
        .split(RegExp(r'\r?\n'))
        .map((line) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) return line;
          if (!trimmed.startsWith('#')) {
            final result = _register(
              base.resolve(trimmed),
              playlist: variant || trimmed.split('?').first.endsWith('.m3u8'),
            );
            variant = false;
            return result;
          }
          if (trimmed.startsWith('#EXT-X-STREAM-INF:')) variant = true;
          final key = trimmed.startsWith('#EXT-X-KEY:') || trimmed.startsWith('#EXT-X-SESSION-KEY:');
          if (key &&
              !trimmed.contains('METHOD=NONE') &&
              (!RegExp(r'METHOD=AES-128(?:,|$)').hasMatch(trimmed) ||
                  (trimmed.contains('KEYFORMAT=') && !trimmed.contains('KEYFORMAT="identity"')))) {
            throw const FormatException('DRM 또는 지원하지 않는 암호화 스트림입니다');
          }
          final playlist =
              trimmed.startsWith('#EXT-X-MEDIA:') ||
              trimmed.startsWith('#EXT-X-I-FRAME-STREAM-INF:') ||
              trimmed.startsWith('#EXT-X-RENDITION-REPORT:');
          return line.replaceAllMapped(
            RegExp(r'URI="([^"]+)"'),
            (match) => 'URI="${_register(base.resolve(match[1]!), playlist: playlist, key: key)}"',
          );
        })
        .join('\n');
  }

  Future<BrowserFetchResponse> _open(Uri uri, Map<String, String> headers, String method) async {
    if (!_browserHosts.contains(uri.origin)) {
      final request = await _client.openUrl(method, uri).timeout(const Duration(seconds: 30));
      headers.forEach((name, value) => request.headers.set(name, value));
      final response = await request.close().timeout(const Duration(seconds: 30));
      var finalUri = uri;
      for (final redirect in response.redirects) {
        finalUri = finalUri.resolveUri(redirect.location);
      }
      final fields = <String, String>{};
      response.headers.forEach((name, values) => fields[name.toLowerCase()] = values.join(', '));
      if (response.compressionState == HttpClientResponseCompressionState.decompressed) {
        fields.remove('content-length');
        fields.remove('content-encoding');
      }
      if (response.statusCode != 403 && response.statusCode != 401) {
        return BrowserFetchResponse(
          response.statusCode,
          fields,
          finalUri,
          response.timeout(const Duration(seconds: 40)),
        );
      }
      await response.listen((_) {}).cancel();
      _browserHosts.add(uri.origin);
    }
    return _browserOpen == null ? _browser.open(uri, headers, method: method) : _browserOpen(uri, headers, method);
  }

  Future<Uint8List> _collect(Stream<List<int>> body, int limit) async {
    final result = BytesBuilder(copy: false);
    await for (final chunk in body) {
      if (_closed) throw StateError('재생 연결이 종료됐습니다');
      if (result.length + chunk.length > limit) throw const FormatException('재생 응답 크기가 너무 큽니다');
      result.add(chunk);
    }
    return result.takeBytes();
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    var forwarding = false;
    try {
      final path = request.uri.pathSegments;
      final id = path.length == 3 && path.first == _token ? int.tryParse(path[1]) : null;
      if (_closed || id == null || id < 0 || id >= _resources.length) {
        response.statusCode = 404;
        await response.close();
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = 405;
        await response.close();
        return;
      }
      response.headers.set('Cache-Control', 'no-store');
      final resource = _resources[id];
      final savedKey = resource.key ? _keys[resource.uri.toString()] : null;
      final savedPlaylist = _playlists[resource.uri.toString()];
      if (savedKey != null) {
        if (savedKey.length != 16) throw const FormatException('AES-128 키 길이가 올바르지 않습니다');
        _bytes(response, savedKey, 'application/octet-stream', request.method == 'HEAD');
      } else if (savedPlaylist != null &&
          (Hls.isMaster(savedPlaylist) ||
              savedPlaylist.contains('#EXT-X-ENDLIST') ||
              !_served.contains(resource.uri.toString()))) {
        _served.add(resource.uri.toString());
        _bytes(
          response,
          utf8.encode(_rewrite(savedPlaylist, resource.uri)),
          'application/vnd.apple.mpegurl',
          request.method == 'HEAD',
        );
      } else {
        final headers = BrowserRequestHeaders.replay(await headersFor?.call(resource.uri) ?? _headers);
        final range = request.headers.value('range');
        if (range != null && !resource.key && !resource.playlist) headers['Range'] = range;
        final upstream = await _open(resource.uri, headers, request.method);
        if (upstream.status >= 300) {
          await upstream.body.listen((_) {}).cancel();
          if (upstream.status != 416) onError?.call(HttpException('미디어 요청 HTTP ${upstream.status}'));
          response.statusCode = upstream.status;
          await response.close();
          return;
        }
        if (request.method == 'HEAD') {
          await upstream.body.listen((_) {}).cancel();
          response.statusCode = upstream.status;
          _copyHeaders(upstream.headers, response);
        } else if (resource.key) {
          final bytes = Hls.parseAes128Key(await _collect(upstream.body, 64 * 1024));
          _keys[resource.uri.toString()] = bytes;
          _bytes(response, bytes, 'application/octet-stream', false);
        } else {
          final iterator = StreamIterator(upstream.body);
          try {
            final first = await iterator.moveNext() ? iterator.current : <int>[];
            Stream<List<int>> chunks() async* {
              yield first;
              while (await iterator.moveNext()) {
                yield iterator.current;
              }
            }

            final playlist =
                resource.playlist ||
                (upstream.headers['content-type'] ?? '').contains('mpegurl') ||
                Hls.isPlaylist(utf8.decode(first.take(64).toList(), allowMalformed: true));
            if (playlist) {
              final text = utf8.decode(await _collect(chunks(), 4 * 1024 * 1024));
              _bytes(response, utf8.encode(_rewrite(text, upstream.uri)), 'application/vnd.apple.mpegurl', false);
            } else {
              response.statusCode = upstream.status;
              _copyHeaders(upstream.headers, response);
              if (upstream.status == 206 && !upstream.headers.containsKey('content-range')) {
                final start = RegExp(r'^bytes=(\d+)-').firstMatch(range ?? '');
                final size = int.tryParse(upstream.headers['content-length'] ?? '');
                if (start != null && size != null) {
                  final offset = int.parse(start[1]!);
                  response.headers.set(
                    'Content-Range',
                    'bytes $offset-${offset + size - 1}/${id == 0 && length > 0 ? length : '*'}',
                  );
                }
              }
              forwarding = true;
              response.bufferOutput = false;
              await response.addStream(chunks());
            }
          } finally {
            await iterator.cancel();
          }
        }
      }
      await response.close();
    } catch (error) {
      // Seeking normally cancels the previous response while it is streaming.
      if (!_closed && !forwarding) onError?.call(error);
      try {
        response.statusCode = 502;
        await response.close();
      } catch (_) {}
    }
  }

  void _copyHeaders(Map<String, String> source, HttpResponse response) {
    for (final name in ['content-type', 'content-range', 'accept-ranges']) {
      if (source[name] != null) response.headers.set(name, source[name]!);
    }
    final size = int.tryParse(source['content-length'] ?? '');
    if (size != null && !source.containsKey('content-encoding')) response.contentLength = size;
  }

  void _bytes(HttpResponse response, List<int> bytes, String type, bool head) {
    response.headers.contentType = ContentType.parse(type);
    response.contentLength = bytes.length;
    if (!head) response.add(bytes);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _client.close(force: true);
    await _server?.close(force: true);
    await _browser.close();
    _keys.clear();
    _playlists.clear();
    _resources.clear();
    _ids.clear();
  }
}
