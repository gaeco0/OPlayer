import 'dart:io';

import 'package:ftpconnect/ftpconnect.dart';
import 'package:path/path.dart' as p;

import '../core/media_item.dart';
import 'media_source.dart';
import 'server_store.dart';

/// FTP: 목록은 ftpconnect, 재생은 ffmpeg의 ftp:// 프로토콜로 직접 스트리밍(탐색 지원).
class FtpSource extends MediaSource {
  FtpSource(this.cfg, this.password);
  final ServerConfig cfg;
  final String password;

  @override
  String get scheme => 'ftp';
  @override
  String get id => cfg.id;
  @override
  String get displayName => cfg.name;
  @override
  String get rootPath => cfg.path.isEmpty ? '/' : cfg.path;

  FTPConnect _new() => FTPConnect(
    cfg.host,
    port: cfg.effectivePort,
    user: cfg.username.isEmpty ? 'anonymous' : cfg.username,
    pass: cfg.username.isEmpty ? 'anonymous@' : password,
    securityType: cfg.secure ? SecurityType.ftps : SecurityType.ftp,
    timeout: 20,
  );

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final ftp = _new();
    try {
      if (!await ftp.connect()) throw 'FTP 접속 실패';
      await ftp.setTransferType(TransferType.binary);
      if (!await ftp.changeDirectory(path)) throw '폴더를 열 수 없습니다: $path';
      final entries = await ftp.listDirectoryContent();
      return [
        for (final e in entries)
          if (e.name != '.' && e.name != '..' && e.type != FTPEntryType.unknown)
            RemoteEntry(
              name: e.name,
              path: p.url.join(path, e.name),
              isDir: e.type == FTPEntryType.dir,
              size: e.size ?? 0,
              modified: e.modifyTime,
            ),
      ];
    } finally {
      try {
        await ftp.disconnect();
      } catch (_) {}
    }
  }

  String _url(String path) {
    final user = cfg.username.isEmpty ? '' : '${Uri.encodeComponent(cfg.username)}:${Uri.encodeComponent(password)}@';
    final enc = path.split('/').map(Uri.encodeComponent).join('/');
    return 'ftp://$user${cfg.host}:${cfg.effectivePort}$enc';
  }

  @override
  MediaItem itemFor(RemoteEntry e, List<RemoteEntry> siblings) => MediaItem(
    key: keyFor(e.path),
    uri: _url(e.path),
    title: p.basenameWithoutExtension(e.name),
    subtitles: [for (final s in MediaSource.matchSubtitles(e, siblings)) SubtitleRef(_url(s.path), s.name)],
  );

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
    final ftp = _new();
    try {
      if (!await ftp.connect()) throw 'FTP 접속 실패';
      await ftp.setTransferType(TransferType.binary);
      if (!await ftp.changeDirectory(remoteDir)) throw '폴더를 열 수 없습니다: $remoteDir';
      final ok = await ftp.uploadFile(local, sRemoteName: name, onProgress: (_, sent, __) => onProgress?.call(sent));
      if (!ok) throw 'FTP 업로드 실패';
      return MediaSource.joinRemote(remoteDir, name);
    } finally {
      try {
        await ftp.disconnect();
      } catch (_) {}
    }
  }
}
