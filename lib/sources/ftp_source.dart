import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ftpconnect/ftpconnect.dart';
import 'package:path/path.dart' as p;

import '../core/media_item.dart';
import '../core/network/android_trust_store.dart';
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
  Future<void> download(
    RemoteEntry entry,
    File target, {
    void Function(int received, int total)? onProgress,
    Future<void>? cancelled,
  }) async {
    if (entry.isDir || [entry.path, cfg.username, password].any((s) => RegExp(r'[\r\n\x00]').hasMatch(s))) {
      throw const FormatException('잘못된 FTP 파일 경로 또는 인증 정보');
    }
    // ftpconnect's high-level download cannot cancel/resume its data socket,
    // and its FTPS control connection accepts invalid certificates.
    Socket? control;
    Socket? data;
    var stopped = false;
    var finished = false;
    cancelled?.then((_) {
      if (finished) return;
      stopped = true;
      data?.destroy();
      control?.destroy();
    });
    void check() {
      if (stopped) throw StateError('다운로드가 중단되었습니다');
    }

    try {
      const timeout = Duration(seconds: 20);
      final trust = AndroidTrustStore();
      if (cfg.secure && Platform.isAndroid) await trust.refresh();
      control = cfg.secure
          ? await SecureSocket.connect(cfg.host, cfg.effectivePort, context: trust.context, timeout: timeout)
          : await Socket.connect(cfg.host, cfg.effectivePort, timeout: timeout);
      check();
      final lines = StreamIterator(control.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()));
      Future<(int, String)> reply() async {
        String? code;
        for (var count = 0; count < 1000; count++) {
          if (!await lines.moveNext().timeout(timeout)) throw const SocketException('FTP 서버 연결이 종료되었습니다');
          final line = lines.current;
          if (line.length < 4 || int.tryParse(line.substring(0, 3)) == null) continue;
          code ??= line.substring(0, 3);
          if (line.startsWith('$code ')) return (int.parse(code), line.substring(4));
        }
        throw const FormatException('FTP 응답이 너무 깁니다');
      }

      Future<(int, String)> command(String value) async {
        check();
        control!.add(utf8.encode('$value\r\n'));
        await control.flush();
        return reply();
      }

      if ((await reply()).$1 != 220) throw StateError('FTP 서버 접속 실패');
      var login = await command('USER ${cfg.username.isEmpty ? 'anonymous' : cfg.username}');
      if (login.$1 == 331) login = await command('PASS ${cfg.username.isEmpty ? 'anonymous@' : password}');
      if (login.$1 != 230) throw StateError('FTP 로그인 실패 (${login.$1})');
      if (cfg.secure) {
        if ((await command('PBSZ 0')).$1 != 200 || (await command('PROT P')).$1 != 200) {
          throw StateError('FTPS 데이터 보호 설정 실패');
        }
      }
      if ((await command('TYPE I')).$1 != 200) throw StateError('FTP 바이너리 전송 설정 실패');
      final sizeReply = await command('SIZE ${entry.path}');
      final total = sizeReply.$1 == 213 ? int.tryParse(sizeReply.$2.trim()) ?? 0 : entry.size;
      var offset = await target.exists() ? await target.length() : 0;
      if (offset > 0 && (total == 0 || offset >= total)) offset = 0;
      final epsv = await command('EPSV');
      int port;
      if (epsv.$1 == 229) {
        final match = RegExp(r'\(\|\|\|(\d+)\|\)').firstMatch(epsv.$2);
        if (match == null) throw const FormatException('잘못된 FTP EPSV 응답');
        port = int.parse(match[1]!);
      } else {
        final passive = await command('PASV');
        final match = RegExp(r'\((?:\d+,){4}(\d+),(\d+)\)').firstMatch(passive.$2);
        if (passive.$1 != 227 || match == null) throw StateError('FTP 수동 연결 실패');
        final high = int.parse(match[1]!), low = int.parse(match[2]!);
        if (high > 255 || low > 255) throw const FormatException('잘못된 FTP PASV 응답');
        port = high * 256 + low;
      }
      if (port < 1 || port > 65535) throw const FormatException('잘못된 FTP 데이터 포트');
      // Always connect to the configured server, ignoring PASV's advertised IP.
      data = await Socket.connect(cfg.host, port, timeout: timeout);
      check();
      if (offset > 0 && (await command('REST $offset')).$1 != 350) offset = 0;
      final transfer = await command('RETR ${entry.path}');
      if (![125, 150, 226, 250].contains(transfer.$1)) throw StateError('FTP 파일을 열 수 없습니다 (${transfer.$1})');
      if (cfg.secure) data = await SecureSocket.secure(data, host: cfg.host, context: trust.context).timeout(timeout);
      check();
      var received = offset;
      onProgress?.call(received, total);
      final sink = target.openWrite(mode: offset > 0 ? FileMode.append : FileMode.write);
      try {
        await sink.addStream(
          data.timeout(const Duration(seconds: 60)).map((chunk) {
            check();
            received += chunk.length;
            onProgress?.call(received, total);
            return chunk;
          }),
        );
        await sink.flush();
      } finally {
        await sink.close();
      }
      check();
      if (transfer.$1 == 125 || transfer.$1 == 150) {
        final end = await reply();
        if (![226, 250].contains(end.$1)) throw StateError('FTP 전송 완료 확인 실패 (${end.$1})');
      }
      if (total > 0 && received != total) throw StateError('FTP 파일을 끝까지 받지 못했습니다');
      onProgress?.call(received, received);
    } finally {
      finished = true;
      data?.destroy();
      control?.destroy();
    }
  }

  @override
  bool get canUpload => true;

  @override
  bool get canDelete => true;

  @override
  bool get canRename => true;

  @override
  Future<String> rename(RemoteEntry entry, String name) async {
    final target = renamedPath(entry, name);
    final ftp = _new();
    try {
      if (!await ftp.connect()) throw StateError('FTP 접속 실패');
      if (!await ftp.changeDirectory(p.url.dirname(entry.path))) throw StateError('폴더를 열 수 없습니다');
      if ((await ftp.listDirectoryContent()).any((e) => e.name == name)) throw StateError('같은 이름의 항목이 이미 있습니다');
      if (!await ftp.rename(p.url.basename(deletionPath(entry)), name)) throw StateError('FTP 이름변경 실패');
      return target;
    } finally {
      try {
        await ftp.disconnect();
      } catch (_) {}
    }
  }

  @override
  Future<void> delete(RemoteEntry entry) async {
    final path = deletionPath(entry);
    final ftp = _new();
    try {
      if (!await ftp.connect()) throw StateError('FTP 접속 실패');
      if (!await ftp.changeDirectory(p.url.dirname(path))) throw StateError('삭제할 항목의 폴더를 열 수 없습니다');
      Future<void> remove(String name, bool directory, int depth) async {
        if (depth > 128) throw StateError('삭제할 폴더의 깊이 한도 초과');
        if (name == '.' || name == '..' || RegExp(r'[/\\\x00-\x1f]').hasMatch(name)) {
          throw const FormatException('잘못된 FTP 삭제 경로');
        }
        if (directory) {
          if (!await ftp.changeDirectory(name)) throw StateError('FTP 폴더를 열 수 없습니다');
          for (final child in await ftp.listDirectoryContent()) {
            if (child.name == '.' || child.name == '..') continue;
            // Unlink symlinks rather than recursively entering their targets.
            await remove(child.name, child.type == FTPEntryType.dir, depth + 1);
          }
          if (!await ftp.changeDirectory('..') || !await ftp.deleteEmptyDirectory(name)) {
            throw StateError('FTP 폴더 삭제 실패');
          }
        } else if (!await ftp.deleteFile(name)) {
          throw StateError('FTP 파일 삭제 실패');
        }
      }

      await remove(p.url.basename(path.replaceFirst(RegExp(r'/+$'), '')), entry.isDir, 0);
    } finally {
      try {
        await ftp.disconnect();
      } catch (_) {}
    }
  }

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
