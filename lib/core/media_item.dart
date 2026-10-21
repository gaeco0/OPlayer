import 'package:path/path.dart' as p;
import 'resource_locks.dart';

/// 재생 가능한 항목 하나. 로컬 파일, 네트워크(SMB/FTP/WebDAV/DLNA), 클라우드, 웹 URL 모두 이 형태로 플레이어에 전달된다.
class MediaItem {
  const MediaItem({
    required this.key,
    required this.uri,
    required this.title,
    this.headers,
    this.subtitles = const [],
    this.localPath,
    this.resolver,
    this.browserMedia = false,
    this.onRelease,
    this.playbackErrors,
  });

  /// 이어보기/최근 재생 저장 키 (로컬은 경로, 원격은 "smb://서버ID/경로" 같은 고유값)
  final String key;

  /// media_kit에 넘길 URI (파일 경로, http(s)://, ftp:// ...)
  final String uri;
  final String title;

  /// http 요청 헤더 (Authorization, Referer, Cookie ...)
  final Map<String, String>? headers;
  final bool browserMedia;
  final Future<void> Function()? onRelease;
  final Stream<String>? playbackErrors;

  /// 외부 자막 (uri, 표시이름)
  final List<SubtitleRef> subtitles;

  /// 로컬 파일일 때만 존재. 같은 폴더 자막 자동 탐색에 사용.
  final String? localPath;

  /// 재생 직전에 실제 URI를 다시 얻어야 하는 경우(만료되는 임시 링크, 프록시 등록 등)
  final Future<MediaItem> Function()? resolver;

  bool get isLocal => localPath != null;

  factory MediaItem.local(String path) =>
      MediaItem(key: path, uri: path, title: p.basenameWithoutExtension(path), localPath: path);

  factory MediaItem.url(String url, {String? title, Map<String, String>? headers, bool browserMedia = false}) =>
      MediaItem(key: url, uri: url, title: title ?? _titleFromUrl(url), headers: headers, browserMedia: browserMedia);

  Future<MediaItem> resolve() async {
    await ResourceLocks.instance.requireAccess(key);
    await ResourceLocks.instance.requireAccess(localPath ?? uri);
    final item = resolver == null ? this : await resolver!();
    try {
      await ResourceLocks.instance.requireAccess(item.key);
      await ResourceLocks.instance.requireAccess(item.localPath ?? item.uri);
      return item;
    } catch (_) {
      await item.onRelease?.call();
      rethrow;
    }
  }

  static String _titleFromUrl(String url) {
    final u = Uri.tryParse(url);
    final last = u?.pathSegments.where((s) => s.isNotEmpty).lastOrNull;
    return last == null ? url : Uri.decodeComponent(last);
  }

  Map<String, dynamic> toJson() => {'k': key, 'u': uri, 't': title, if (headers != null) 'h': headers};
}

class SubtitleRef {
  const SubtitleRef(this.uri, this.title);
  final String uri;
  final String title;
}
