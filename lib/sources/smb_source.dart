import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:smb_connect/smb_connect.dart';

import '../core/media_item.dart';
import '../core/stream_proxy.dart';
import 'media_source.dart';
import 'server_store.dart';

/// SMB (Windows 공유, NAS). ffmpeg에 SMB가 없으므로 Dart SMB 클라이언트 → 로컬 HTTP 프록시로 재생.
/// 루트("/")는 공유 폴더 목록, "/공유/폴더/" 형식으로 탐색.
class SmbSource extends MediaSource {
  SmbSource(this.cfg, this.password);
  final ServerConfig cfg;
  final String password;

  SmbConnect? _browse;
  SmbConnect? _stream;

  @override
  String get scheme => 'smb';
  @override
  String get id => cfg.id;
  @override
  String get displayName => cfg.name;
  @override
  String get rootPath => _dir(cfg.path);

  static String _dir(String s) {
    if (s.isEmpty) return '/';
    if (!s.startsWith('/')) s = '/$s';
    return s.endsWith('/') ? s : '$s/';
  }

  Future<SmbConnect> _connect() => SmbConnect.connectAuth(
    host: cfg.host, // smb_connect는 445 포트 고정
    domain: cfg.domain,
    username: cfg.username.isEmpty ? 'guest' : cfg.username,
    password: password,
  );

  Future<T> _withBrowse<T>(Future<T> Function(SmbConnect c) fn) async {
    _browse ??= await _connect();
    try {
      return await fn(_browse!);
    } catch (_) {
      // 끊긴 연결 재시도 1회
      try {
        await _browse?.close();
      } catch (_) {}
      _browse = await _connect();
      return fn(_browse!);
    }
  }

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final dir = _dir(path);
    return _withBrowse((c) async {
      if (dir == '/') {
        final shares = await c.listShares();
        return [
          for (final s in shares)
            if (!s.name.endsWith(r'$')) // ADMIN$, IPC$ 숨김
              RemoteEntry(name: s.name.replaceAll('/', ''), path: _dir('/${s.name.replaceAll('/', '')}'), isDir: true),
        ];
      }
      final folder = await c.file(dir);
      final files = await c.listFiles(folder);
      return [
        for (final f in files)
          if (f.name != '.' && f.name != '..' && !f.isHidden())
            RemoteEntry(
              name: f.name,
              path: f.isDirectory() ? _dir(p.url.join(dir, f.name)) : p.url.join(dir, f.name),
              isDir: f.isDirectory(),
              size: f.size,
              modified: f.lastModified > 0 ? DateTime.fromMillisecondsSinceEpoch(f.lastModified) : null,
            ),
      ];
    });
  }

  Future<String> _proxy(String path) async {
    _stream ??= await _connect();
    final conn = _stream!;
    final file = await conn.file(path);
    return StreamProxy.instance.register(
      name: p.url.basename(path),
      length: file.size,
      opener: (start, end) async {
        try {
          return await conn.openRead(file, start, end);
        } catch (_) {
          // 연결이 끊겼으면 새로 붙어서 재시도
          _stream = await _connect();
          final f2 = await _stream!.file(path);
          return _stream!.openRead(f2, start, end);
        }
      },
    );
  }

  @override
  MediaItem itemFor(RemoteEntry e, List<RemoteEntry> siblings) {
    final subs = MediaSource.matchSubtitles(e, siblings);
    final key = keyFor(e.path);
    final title = p.basenameWithoutExtension(e.name);
    return MediaItem(
      key: key,
      uri: '',
      title: title,
      resolver: () async {
        final url = await _proxy(e.path);
        final refs = <SubtitleRef>[];
        for (final s in subs) {
          try {
            refs.add(SubtitleRef(await _proxy(s.path), s.name));
          } catch (_) {}
        }
        return MediaItem(key: key, uri: url, title: title, subtitles: refs);
      },
    );
  }

  @override
  Future<MediaItem?> itemForPath(String path, String title) async {
    // 최근 재생에서 열 때: 같은 폴더 자막도 다시 찾아본다
    List<RemoteEntry> siblings = const [];
    try {
      siblings = await list(p.url.dirname(path));
    } catch (_) {}
    return itemFor(RemoteEntry(name: p.url.basename(path), path: path, isDir: false), siblings);
  }

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
    final path = MediaSource.joinRemote(_dir(remoteDir), name);
    return _withBrowse((c) async {
      final f = await c.createFile(path);
      final sink = await c.openWrite(f);
      var sent = 0;
      try {
        await for (final chunk in local.openRead()) {
          sink.add(chunk);
          sent += chunk.length;
          onProgress?.call(sent);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      return path;
    });
  }

  @override
  Future<void> close() async {
    try {
      await _browse?.close();
      await _stream?.close();
    } catch (_) {}
    _browse = _stream = null;
  }

  /// 연결 테스트용
  static Future<String?> test(ServerConfig cfg, String password) async {
    try {
      final s = SmbSource(cfg, password);
      await s.list('/');
      await s.close();
      return null;
    } catch (e) {
      return '$e';
    }
  }
}
