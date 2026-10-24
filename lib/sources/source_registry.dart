import 'dart:io';

import '../core/media_item.dart';
import '../core/resource_locks.dart';
import '../core/resume_store.dart';
import '../core/sync_references.dart';
import '../features/web/browser_playback_proxy.dart';
import 'cloud/cloud_sources.dart';
import 'ftp_source.dart';
import 'media_source.dart';
import 'server_store.dart';
import 'sftp_source.dart';
import 'smb_source.dart';
import 'webdav_source.dart';

/// 설정 → MediaSource 인스턴스 (연결 재사용을 위해 캐시)
class SourceRegistry {
  SourceRegistry._();
  static final instance = SourceRegistry._();

  final _cache = <String, MediaSource>{};

  Future<MediaSource> forServer(ServerConfig c, {bool authorizedUpload = false}) async {
    if (!authorizedUpload) await ResourceLocks.instance.requireAccess(serverResourceKey(c));
    final cached = _cache[c.id];
    if (cached != null) return cached;
    final pw = await ServerStore.instance.password(c);
    final MediaSource s = switch (c.type) {
      ServerType.smb => SmbSource(c, pw),
      ServerType.ftp => FtpSource(c, pw),
      ServerType.sftp => SftpSource(c, pw),
      ServerType.webdav => WebDavSource(c, pw),
    };
    return _cache[c.id] = s;
  }

  MediaSource forAccount(CloudAccount a) => _cache[a.id] ??= cloudSourceFor(a);

  /// 설정이 바뀌거나 삭제되면 연결을 버린다.
  Future<void> invalidate(String id) async {
    await _cache.remove(id)?.close();
  }

  /// 최근 재생 키 → 재생 항목
  Future<MediaItem?> itemFromKey(String key, {String? title}) async {
    if (key.startsWith(SyncReferences.prefix)) {
      final resolved = SyncReferences.instance.resolve(key);
      if (resolved == null) return null;
      key = resolved;
    }
    try {
      await ResourceLocks.instance.requireAccess(key);
    } on ResourceLockedException {
      return null;
    }
    if (!key.contains('://')) {
      return File(key).existsSync() ? MediaItem.local(key) : null;
    }
    final uri = Uri.tryParse(key);
    if (uri == null) return null;
    final scheme = uri.scheme;
    if (scheme == 'http' || scheme == 'https' || scheme == 'rtsp' || scheme == 'rtmp') {
      final browser = BrowserPlaybackRegistry.find(key);
      if (browser != null) return browser;
      return MediaItem.url(key, title: title, browserMedia: ResumeStore.instance.get(key)?.browserMedia ?? false);
    }
    // scheme://<id><path>
    final rest = key.substring(scheme.length + 3);
    final slash = rest.indexOf('/');
    final id = slash < 0 ? rest : rest.substring(0, slash);
    final path = slash < 0 ? '' : rest.substring(slash);
    final t = title ?? path.split('/').last;

    final server = ServerStore.instance.server(id);
    if (server != null) return (await forServer(server)).itemForPath(path, t);
    final account = ServerStore.instance.account(id);
    if (account != null) {
      // 클라우드 키는 "gdrive://계정ID/파일ID" 형태 → 앞의 '/' 제거
      return forAccount(account).itemForPath(path.startsWith('/') ? path.substring(1) : path, t);
    }
    return null;
  }
}
