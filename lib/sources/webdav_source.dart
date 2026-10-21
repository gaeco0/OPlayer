import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../core/media_item.dart';
import 'media_source.dart';
import 'server_store.dart';

/// WebDAV (Nextcloud, Synology, NAS 등). 재생은 http(s) 직접 + Basic 인증 헤더.
class WebDavSource extends MediaSource {
  WebDavSource(this.cfg, this.password, {this.uploadTimeout = const Duration(minutes: 2)});
  final Duration uploadTimeout;
  final ServerConfig cfg;
  final String password;

  @override
  String get scheme => 'webdav';
  @override
  String get id => cfg.id;
  @override
  String get displayName => cfg.name;
  @override
  String get rootPath => _normDir(cfg.path);

  String get _origin => '${cfg.secure ? 'https' : 'http'}://${cfg.host}:${cfg.effectivePort}';

  Map<String, String> get _auth =>
      cfg.username.isEmpty ? {} : {'Authorization': 'Basic ${base64Encode(utf8.encode('${cfg.username}:$password'))}'};

  static String _normDir(String path) {
    var s = path.isEmpty ? '/' : path;
    if (!s.startsWith('/')) s = '/$s';
    if (!s.endsWith('/')) s = '$s/';
    return s;
  }

  Uri _uri(String path) => Uri.parse(_origin + path.split('/').map(Uri.encodeComponent).join('/'));

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final dir = _normDir(path);
    final req = http.Request('PROPFIND', _uri(dir))
      ..headers.addAll({..._auth, 'Depth': '1', 'Content-Type': 'application/xml; charset=utf-8'})
      ..body =
          '<?xml version="1.0" encoding="utf-8"?>'
          '<d:propfind xmlns:d="DAV:"><d:prop>'
          '<d:displayname/><d:getcontentlength/><d:getlastmodified/><d:resourcetype/>'
          '</d:prop></d:propfind>';
    final res = await http.Response.fromStream(await req.send());
    if (res.statusCode == 401) throw '인증 실패 (아이디/비밀번호 확인)';
    if (res.statusCode >= 300) throw 'HTTP ${res.statusCode}';

    final doc = XmlDocument.parse(utf8.decode(res.bodyBytes));
    final out = <RemoteEntry>[];
    for (final r in doc.findAllElements('response', namespace: 'DAV:')) {
      final href = r.findElements('href', namespace: 'DAV:').firstOrNull?.innerText;
      if (href == null) continue;
      var hrefPath = Uri.decodeFull(Uri.parse(href).path);
      if (_normDir(hrefPath) == dir) continue; // 자기 자신
      final prop = r.findAllElements('prop', namespace: 'DAV:').firstOrNull;
      final isDir = prop?.findAllElements('collection', namespace: 'DAV:').isNotEmpty ?? false;
      final size =
          int.tryParse(prop?.findAllElements('getcontentlength', namespace: 'DAV:').firstOrNull?.innerText ?? '') ?? 0;
      final mod = prop?.findAllElements('getlastmodified', namespace: 'DAV:').firstOrNull?.innerText;
      if (isDir) hrefPath = _normDir(hrefPath);
      final name = p.url.basename(hrefPath.endsWith('/') ? hrefPath.substring(0, hrefPath.length - 1) : hrefPath);
      out.add(
        RemoteEntry(
          name: name,
          path: hrefPath,
          isDir: isDir,
          size: size,
          modified: mod == null ? null : _parseHttpDate(mod),
        ),
      );
    }
    return out;
  }

  static DateTime? _parseHttpDate(String s) {
    try {
      return HttpDateParser.parse(s);
    } catch (_) {
      return null;
    }
  }

  @override
  MediaItem itemFor(RemoteEntry e, List<RemoteEntry> siblings) {
    final subs = MediaSource.matchSubtitles(e, siblings);
    return MediaItem(
      key: keyFor(e.path),
      uri: _uri(e.path).toString(),
      title: p.basenameWithoutExtension(e.name),
      headers: _auth,
      resolver: subs.isEmpty
          ? null
          : () async {
              final refs = <SubtitleRef>[];
              for (final s in subs) {
                final r = await MediaSource.downloadSubtitle(_uri(s.path).toString(), s.name, headers: _auth);
                if (r != null) refs.add(r);
              }
              return MediaItem(
                key: keyFor(e.path),
                uri: _uri(e.path).toString(),
                title: p.basenameWithoutExtension(e.name),
                headers: _auth,
                subtitles: refs,
              );
            },
    );
  }

  @override
  Future<MediaItem?> itemForPath(String path, String title) async =>
      itemFor(RemoteEntry(name: p.url.basename(path), path: path, isDir: false), const []);

  @override
  bool get canUpload => true;

  @override
  Future<String> upload(
    File local,
    String remoteDir,
    String name, {
    void Function(int sent)? onProgress,
    Future<void>? cancelled,
  }) async {
    final path = MediaSource.joinRemote(_normDir(remoteDir), name);
    final client = HttpClient()..connectionTimeout = uploadTimeout;
    HttpClientRequest? request;
    Timer? watchdog;
    var finished = false;
    Object? interrupted;
    void abort(Object error) {
      if (finished) return;
      interrupted ??= error;
      request?.abort(error);
      client.close(force: true);
    }

    void touch() {
      watchdog?.cancel();
      watchdog = Timer(
        uploadTimeout,
        () => abort(TimeoutException('WebDAV 전송 또는 서버 응답이 멈췄습니다. 다시 시도해 주세요.', uploadTimeout)),
      );
    }

    cancelled?.then((_) => abort(const HttpException('업로드 일시정지')));
    try {
      touch();
      final len = await local.length();
      if (interrupted != null) throw interrupted!;
      final req = await client.putUrl(_uri(path));
      request = req;
      if (interrupted != null) {
        req.abort(interrupted);
        throw interrupted!;
      }
      req.followRedirects = false;
      req.contentLength = len;
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/octet-stream');
      _auth.forEach(req.headers.set);
      var sent = 0;
      // Respect socket backpressure instead of buffering the entire file.
      await req.addStream(
        local.openRead().map((chunk) {
          touch();
          sent += chunk.length;
          onProgress?.call(sent);
          return chunk;
        }),
      );
      touch();
      final res = await req.close();
      if (res.statusCode < 200 || res.statusCode >= 300) {
        final hint = switch (res.statusCode) {
          401 => '아이디/비밀번호를 확인해 주세요',
          403 => '저장 폴더의 쓰기 권한을 확인해 주세요',
          404 || 409 => '저장 폴더가 존재하는지 확인해 주세요',
          413 => '서버의 업로드 용량 제한을 확인해 주세요',
          507 => '서버의 남은 저장 공간을 확인해 주세요',
          >= 300 && < 400 => '리디렉션됩니다. 실제 WebDAV 주소로 설정해 주세요',
          _ => '서버 설정을 확인해 주세요',
        };
        throw HttpException('WebDAV 업로드 실패 (HTTP ${res.statusCode}): $hint');
      }
      // The successful PUT status acknowledges storage. An optional response
      // body must not keep a completed upload waiting indefinitely.
    } catch (error) {
      throw interrupted ?? error;
    } finally {
      finished = true;
      watchdog?.cancel();
      client.close(force: true);
    }
    return path;
  }
}

/// RFC 1123 날짜 파서 (dart:io HttpDate는 웹 지원이 없어서 간단히 구현)
class HttpDateParser {
  static const _months = {
    'Jan': 1,
    'Feb': 2,
    'Mar': 3,
    'Apr': 4,
    'May': 5,
    'Jun': 6,
    'Jul': 7,
    'Aug': 8,
    'Sep': 9,
    'Oct': 10,
    'Nov': 11,
    'Dec': 12,
  };
  static DateTime parse(String s) {
    final m = RegExp(r'(\d{1,2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2})').firstMatch(s)!;
    return DateTime.utc(
      int.parse(m[3]!),
      _months[m[2]!]!,
      int.parse(m[1]!),
      int.parse(m[4]!),
      int.parse(m[5]!),
      int.parse(m[6]!),
    );
  }
}
