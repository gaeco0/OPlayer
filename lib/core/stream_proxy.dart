import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

/// 원본에서 [start, end) 바이트를 읽어오는 함수
typedef RangeOpener = Future<Stream<List<int>>> Function(int start, int end);

class _Entry {
  _Entry(this.length, this.opener, this.mime);
  final int length;
  final RangeOpener opener;
  final String mime;
}

/// media_kit(ffmpeg)이 직접 열 수 없는 소스(SMB 등)를 http://127.0.0.1 로 노출하는 로컬 프록시.
/// HTTP Range 요청을 지원하므로 탐색(seek)이 가능하다.
class StreamProxy {
  StreamProxy._();
  static final instance = StreamProxy._();

  HttpServer? _server;
  final _entries = <String, _Entry>{};
  final _rand = Random.secure();

  Future<int> _ensure() async {
    if (_server != null) return _server!.port;
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    s.listen(_handle, onError: (_) {});
    _server = s;
    return s.port;
  }

  /// 소스를 등록하고 재생용 URL을 돌려준다.
  Future<String> register({required String name, required int length, required RangeOpener opener}) async {
    final port = await _ensure();
    final token = List.generate(16, (_) => _rand.nextInt(16).toRadixString(16)).join();
    _entries[token] = _Entry(length, opener, mimeOf(name));
    return 'http://127.0.0.1:$port/$token/${Uri.encodeComponent(p.basename(name))}';
  }

  void unregisterAll() => _entries.clear();
  void unregister(String url) {
    final segments = Uri.parse(url).pathSegments;
    if (segments.isNotEmpty) _entries.remove(segments.first);
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final seg = req.uri.pathSegments;
      final e = seg.isEmpty ? null : _entries[seg.first];
      if (e == null) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      res.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..contentType = ContentType.parse(e.mime);

      var start = 0;
      var end = e.length; // exclusive
      final range = req.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        final m = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range);
        if (m != null) {
          final a = m.group(1)!, b = m.group(2)!;
          if (a.isEmpty && b.isNotEmpty) {
            start = max(0, e.length - int.parse(b));
          } else {
            start = int.parse(a.isEmpty ? '0' : a);
            if (b.isNotEmpty) end = min(e.length, int.parse(b) + 1);
          }
        }
        if (start >= e.length) {
          res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */${e.length}');
          await res.close();
          return;
        }
        res.statusCode = HttpStatus.partialContent;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-${end - 1}/${e.length}');
      }
      res.contentLength = end - start;
      if (req.method == 'HEAD') {
        await res.close();
        return;
      }
      final stream = await e.opener(start, end);
      await res.addStream(stream);
      await res.close();
    } catch (_) {
      // 플레이어가 탐색하면서 연결을 끊는 건 정상 동작
      try {
        await res.close();
      } catch (_) {}
    }
  }

  static String mimeOf(String name) => switch (p.extension(name).toLowerCase()) {
    '.mp4' || '.m4v' => 'video/mp4',
    '.mkv' => 'video/x-matroska',
    '.webm' => 'video/webm',
    '.avi' => 'video/x-msvideo',
    '.mov' => 'video/quicktime',
    '.ts' || '.m2ts' || '.mts' => 'video/mp2t',
    '.m3u8' => 'application/vnd.apple.mpegurl',
    '.mp3' => 'audio/mpeg',
    '.m4a' => 'audio/mp4',
    '.aac' => 'audio/aac',
    '.jpg' || '.jpeg' => 'image/jpeg',
    '.png' => 'image/png',
    '.webp' => 'image/webp',
    '.gif' => 'image/gif',
    '.bmp' => 'image/bmp',
    '.avif' => 'image/avif',
    '.flac' => 'audio/flac',
    '.wav' => 'audio/wav',
    '.srt' => 'application/x-subrip',
    '.vtt' => 'text/vtt',
    '.ass' || '.ssa' || '.smi' => 'text/plain',
    _ => 'application/octet-stream',
  };
}
