import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/media_item.dart';
import '../core/media_utils.dart';
import '../core/network/network_service.dart';

/// 원격 폴더 항목
class RemoteEntry {
  const RemoteEntry({
    required this.name,
    required this.path,
    required this.isDir,
    this.size = 0,
    this.modified,
    this.thumbnailUrl,
    this.directUrl,
  });

  final String name;

  /// 소스 내부 식별자 (SMB/FTP/WebDAV는 경로, 클라우드는 파일 ID, DLNA는 ObjectID)
  final String path;
  final bool isDir;
  final int size;
  final DateTime? modified;
  final String? thumbnailUrl;

  /// DLNA처럼 항목 자체가 재생 URL을 가진 경우
  final String? directUrl;

  bool get isVideo => !isDir && (directUrl != null || videoExtensions.contains(p.extension(name).toLowerCase()));
  bool get isPhoto => !isDir && isImage(name);
  bool get isPlayableMedia => !isDir && !isPhoto && (isPlayable(name) || directUrl != null);
  bool get isMedia => isPhoto || isPlayableMedia;
  bool get isSubtitle => !isDir && subtitleExtensions.contains(p.extension(name).toLowerCase());
}

/// SMB / FTP / WebDAV / DLNA / 클라우드 공통 인터페이스
abstract class MediaSource {
  /// 키 접두어 (smb, ftp, webdav, gdrive, dropbox, onedrive, dlna)
  String get scheme;

  /// 서버/계정 ID
  String get id;
  String get displayName;
  String get rootPath;
  String get rootTitle => displayName;

  Future<List<RemoteEntry>> list(String path);

  /// 재생 항목 생성. [siblings]는 같은 폴더 항목(자막 매칭용).
  MediaItem itemFor(RemoteEntry e, List<RemoteEntry> siblings);

  /// 최근 재생 목록에서 다시 열 때 (키 → 항목). 지원하지 않으면 null.
  Future<MediaItem?> itemForPath(String path, String title) async => null;

  String keyFor(String path) => '$scheme://$id$path';

  /// Resolve fresh credentials/URLs on every attempt. The target is a private
  /// .part file; the download manager publishes it only after successful EOF.
  Future<void> download(
    RemoteEntry entry,
    File target, {
    void Function(int received, int total)? onProgress,
    Future<void>? cancelled,
  }) async {
    if (entry.isDir) throw UnsupportedError('폴더 다운로드는 지원하지 않습니다');
    final client = IOClient(NetworkService.instance.createHttpClient());
    MediaItem? item;
    var stopped = false;
    var finished = false;
    cancelled?.then((_) {
      if (finished) return;
      stopped = true;
      client.close();
    });
    void check() {
      if (stopped) throw StateError('다운로드가 중단되었습니다');
    }

    try {
      check();
      item = await itemFor(entry, const []).resolve();
      check();
      final uri = Uri.parse(item.uri);
      if (!['http', 'https'].contains(uri.scheme)) throw UnsupportedError('다운로드를 지원하지 않는 주소입니다');
      var offset = await target.exists() ? await target.length() : 0;
      final request = http.AbortableRequest('GET', uri, abortTrigger: cancelled)
        ..headers.addAll(item.headers ?? const {});
      request.headers['Accept-Encoding'] = 'identity';
      if (offset > 0) {
        request.headers['Range'] = 'bytes=$offset-';
        if (entry.modified != null) request.headers['If-Range'] = HttpDate.format(entry.modified!.toUtc());
      }
      final response = await client.send(request).timeout(const Duration(seconds: 30));
      check();
      var total = response.contentLength ?? 0;
      if (response.statusCode == 200) {
        offset = 0; // Range unsupported or source changed: safely restart.
      } else if (response.statusCode == 206) {
        final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(response.headers['content-range'] ?? '');
        if (range == null ||
            int.parse(range[1]!) != offset ||
            int.parse(range[2]!) < offset ||
            int.parse(range[2]!) >= int.parse(range[3]!)) {
          throw const HttpException('이어받기 응답 범위가 올바르지 않습니다');
        }
        total = int.parse(range[3]!);
      } else {
        // A 416 does not prove that an old partial file matches the new source.
        if (response.statusCode == 416 && await target.exists()) await target.delete();
        throw HttpException('원격 파일 다운로드 실패 (HTTP ${response.statusCode})');
      }
      var received = offset;
      onProgress?.call(received, total);
      final sink = target.openWrite(mode: offset > 0 ? FileMode.append : FileMode.write);
      try {
        await sink.addStream(
          response.stream.timeout(const Duration(seconds: 60)).map((chunk) {
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
      if (total > 0 && received != total) throw const HttpException('원격 파일을 끝까지 받지 못했습니다');
      onProgress?.call(received, received);
    } finally {
      finished = true;
      client.close();
      await item?.onRelease?.call();
    }
  }

  /// 업로드(다운로드 저장 위치로 사용) 지원 여부
  bool get canUpload => false;

  bool get canDelete => false;

  bool canDeleteEntry(RemoteEntry entry) {
    if (!canDelete) return false;
    try {
      deletionPath(entry);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> delete(RemoteEntry entry) => throw UnsupportedError('$scheme 는 삭제를 지원하지 않습니다');

  /// Filesystem-backed sources must never delete the configured root or escape it.
  String deletionPath(RemoteEntry entry) {
    String normalized(String value) => p.posix.normalize('/${value.replaceFirst(RegExp(r'^/+'), '')}');
    final path = entry.path;
    final root = normalized(rootPath);
    final target = normalized(path);
    if (RegExp(r'[\\\x00-\x1f]').hasMatch(path) ||
        path.split('/').any((part) => part == '.' || part == '..') ||
        !p.posix.isWithin(root, target)) {
      throw const FormatException('등록한 루트 내부의 파일·폴더만 삭제할 수 있습니다');
    }
    return path;
  }

  /// [local] 파일을 [remoteDir] 폴더에 [name]으로 올리고 원격 경로를 돌려준다.
  Future<String> upload(
    File local,
    String remoteDir,
    String name, {
    void Function(int sent)? onProgress,
    Future<void>? cancelled,
  }) => throw UnsupportedError('$scheme 는 업로드를 지원하지 않습니다');

  static String joinRemote(String dir, String name) => dir.endsWith('/') ? '$dir$name' : '$dir/$name';

  Future<void> close() async {}

  /// 같은 이름의 자막 파일 찾기
  static List<RemoteEntry> matchSubtitles(RemoteEntry video, List<RemoteEntry> siblings) {
    final base = p.basenameWithoutExtension(video.name).toLowerCase();
    return siblings.where((s) => s.isSubtitle && s.name.toLowerCase().startsWith(base)).toList();
  }

  /// 인증 헤더가 필요한 자막은 임시 파일로 받아서 file:// 로 넘긴다 (mpv 자막 로더는 헤더를 못 붙이는 경우가 있음).
  static Future<SubtitleRef?> downloadSubtitle(String url, String name, {Map<String, String>? headers}) async {
    try {
      final r = await http.get(Uri.parse(url), headers: headers);
      if (r.statusCode >= 300) return null;
      Directory tmp;
      try {
        tmp = await getTemporaryDirectory();
      } catch (_) {
        tmp = Directory.systemTemp;
      }
      final dir = Directory(p.join(tmp.path, 'oplayer_subs'));
      await dir.create(recursive: true);
      final f = File(p.join(dir.path, '${DateTime.now().microsecondsSinceEpoch}_$name'));
      await f.writeAsBytes(r.bodyBytes);
      return SubtitleRef(Uri.file(f.path).toString(), name);
    } catch (_) {
      return null;
    }
  }
}
