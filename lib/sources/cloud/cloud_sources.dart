import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../core/media_item.dart';
import '../../core/secure_store.dart';
import '../media_source.dart';
import '../server_store.dart';
import 'cloud_config.dart';
import 'oauth.dart';

/// 공급자별 OAuth 클라이언트
OAuthClient oauthClientFor(CloudProvider provider, {String? clientId, String? accountEmail}) {
  final desktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  switch (provider) {
    case CloudProvider.gdrive:
      if (Platform.isAndroid) {
        return GoogleAndroidOAuthClient(
          clientId: clientId ?? CloudConfig.googleAndroidClientId,
          accountEmail: accountEmail,
        );
      }
      if (!desktop) throw '이 플랫폼의 Google Drive 로그인은 지원하지 않습니다';
      final id = clientId ?? CloudConfig.googleDesktopClientId;
      return OAuthClient(
        authEndpoint: 'https://accounts.google.com/o/oauth2/v2/auth',
        tokenEndpoint: 'https://oauth2.googleapis.com/token',
        clientId: id,
        clientSecretKey: CloudConfig.googleSecretKey(id),
        scopes: ['https://www.googleapis.com/auth/drive.readonly'],
        mobileScheme: CloudConfig.mobileScheme,
        extraAuthParams: {'access_type': 'offline', 'prompt': 'consent'},
      );
    case CloudProvider.dropbox:
      return OAuthClient(
        authEndpoint: 'https://www.dropbox.com/oauth2/authorize',
        tokenEndpoint: 'https://api.dropboxapi.com/oauth2/token',
        clientId: clientId ?? CloudConfig.dropboxAppKey,
        scopes: ['files.metadata.read', 'files.content.read', 'account_info.read'],
        mobileScheme: CloudConfig.mobileScheme,
        mobileRedirectUri: CloudConfig.dropboxRedirect,
        extraAuthParams: {'token_access_type': 'offline'},
        loopbackHost: 'localhost',
      );
    case CloudProvider.onedrive:
      return OAuthClient(
        authEndpoint: 'https://login.microsoftonline.com/common/oauth2/v2.0/authorize',
        tokenEndpoint: 'https://login.microsoftonline.com/common/oauth2/v2.0/token',
        clientId: clientId ?? CloudConfig.oneDriveClientId,
        scopes: ['Files.Read', 'User.Read', 'offline_access'],
        mobileScheme: CloudConfig.mobileScheme,
        mobileRedirectUri: CloudConfig.oneDriveRedirect,
        extraAuthParams: {'prompt': 'select_account'},
        loopbackHost: 'localhost',
      );
  }
}

/// 로그인 → 계정 이름 조회 → 저장
Future<CloudAccount> connectCloudAccount(CloudProvider provider) async {
  final client = oauthClientFor(provider);
  final tokens = await client.authorize();
  final account = CloudAccount(
    id: ServerStore.newId(),
    provider: provider,
    name: provider.label,
    oauthClientId: client.clientId,
  );
  final holder = TokenHolder(account.tokenKey, client);
  await holder.save(tokens);
  final src = cloudSourceFor(account);
  try {
    account.name = await src.accountName();
    await ServerStore.instance.saveAccount(account);
  } catch (_) {
    await SecureStore.instance.writeRequired(account.tokenKey, null);
    rethrow;
  }
  return account;
}

CloudSource cloudSourceFor(CloudAccount a) => switch (a.provider) {
  CloudProvider.gdrive => GoogleDriveSource(a),
  CloudProvider.dropbox => DropboxSource(a),
  CloudProvider.onedrive => OneDriveSource(a),
};

abstract class CloudSource extends MediaSource {
  CloudSource(this.account)
    : tokens = TokenHolder(
        account.tokenKey,
        oauthClientFor(
          account.provider,
          clientId: account.oauthClientId,
          accountEmail: account.name.contains('@') ? account.name : null,
        ),
      );
  final CloudAccount account;
  final TokenHolder tokens;

  @override
  Future<void> close() async => tokens.close();

  @override
  String get id => account.id;
  @override
  String get displayName => account.name;

  Future<String> accountName();

  @override
  String keyFor(String path) => '$scheme://$id/$path';

  /// 파일 ID → 재생 URL + 헤더
  Future<({String url, Map<String, String>? headers})> streamFor(String path);

  Future<Map<String, dynamic>> getJson(String url) async {
    var r = await http.get(Uri.parse(url), headers: await tokens.authHeader()).timeout(const Duration(seconds: 30));
    if (r.statusCode == 401) {
      r = await http
          .get(Uri.parse(url), headers: await tokens.authHeader(forceRefresh: true))
          .timeout(const Duration(seconds: 30));
    }
    return _decode(r);
  }

  Future<Map<String, dynamic>> postJson(String url, Object? body) async {
    Future<http.Response> send(bool refresh) async => http
        .post(
          Uri.parse(url),
          headers: {
            ...await tokens.authHeader(forceRefresh: refresh),
            'Content-Type': 'application/json',
          },
          body: body == null ? 'null' : jsonEncode(body),
        )
        .timeout(const Duration(seconds: 30));
    var r = await send(false);
    if (r.statusCode == 401) r = await send(true);
    return _decode(r);
  }

  Map<String, dynamic> _decode(http.Response r) {
    if (r.statusCode == 401) throw '인증이 만료되었습니다. 계정을 다시 연결하세요.';
    final Object? j;
    try {
      j = jsonDecode(utf8.decode(r.bodyBytes));
    } catch (_) {
      throw '클라우드 서버 응답을 읽을 수 없습니다 (HTTP ${r.statusCode})';
    }
    if (r.statusCode >= 300) {
      throw '오류 ${r.statusCode}: ${j is Map ? (j['error_summary'] ?? j['error'] ?? '') : ''}';
    }
    if (j is! Map<String, dynamic>) throw '잘못된 클라우드 서버 응답입니다';
    return j;
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
        final s = await streamFor(e.path);
        final refs = <SubtitleRef>[];
        for (final sub in subs) {
          final ss = await streamFor(sub.path);
          final r = await MediaSource.downloadSubtitle(ss.url, sub.name, headers: ss.headers);
          if (r != null) refs.add(r);
        }
        return MediaItem(key: key, uri: s.url, title: title, headers: s.headers, subtitles: refs);
      },
    );
  }

  @override
  Future<MediaItem?> itemForPath(String path, String title) async {
    final key = keyFor(path);
    return MediaItem(
      key: key,
      uri: '',
      title: title,
      resolver: () async {
        final s = await streamFor(path);
        return MediaItem(key: key, uri: s.url, title: title, headers: s.headers);
      },
    );
  }
}

// ---------------------------------------------------------------- Google Drive
class GoogleDriveSource extends CloudSource {
  GoogleDriveSource(super.account);
  static const _api = 'https://www.googleapis.com/drive/v3';

  @override
  String get scheme => 'gdrive';
  @override
  String get rootPath => 'root';
  @override
  String get rootTitle => '내 드라이브';

  @override
  Future<String> accountName() async {
    final j = await getJson('$_api/about?fields=user');
    return (j['user']?['emailAddress'] as String?) ?? 'Google Drive';
  }

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final out = <RemoteEntry>[];
    String? page;
    do {
      final escapedPath = path.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
      final url = Uri.parse('$_api/files')
          .replace(
            queryParameters: {
              'q': "'$escapedPath' in parents and trashed=false",
              'pageSize': '1000',
              'orderBy': 'folder,name',
              'supportsAllDrives': 'true',
              'includeItemsFromAllDrives': 'true',
              'fields': 'nextPageToken,files(id,name,mimeType,size,modifiedTime,thumbnailLink)',
              if (page != null) 'pageToken': page,
            },
          )
          .toString();
      final j = await getJson(url);
      for (final f in (j['files'] as List).cast<Map<String, dynamic>>()) {
        final mime = f['mimeType'] as String? ?? '';
        final isDir = mime == 'application/vnd.google-apps.folder';
        if (!isDir && mime.startsWith('application/vnd.google-apps')) continue; // 문서/시트 등 제외
        out.add(
          RemoteEntry(
            name: f['name'] as String,
            path: f['id'] as String,
            isDir: isDir,
            size: int.tryParse('${f['size'] ?? 0}') ?? 0,
            modified: DateTime.tryParse(f['modifiedTime'] as String? ?? ''),
            thumbnailUrl: f['thumbnailLink'] as String?,
          ),
        );
      }
      page = j['nextPageToken'] as String?;
    } while (page != null);
    return out;
  }

  @override
  Future<({String url, Map<String, String>? headers})> streamFor(String path) async => (
    url: '$_api/files/${Uri.encodeComponent(path)}?alt=media&supportsAllDrives=true',
    headers: await tokens.authHeader(),
  );
}

// ---------------------------------------------------------------- Dropbox
class DropboxSource extends CloudSource {
  DropboxSource(super.account);
  static const _api = 'https://api.dropboxapi.com/2';

  @override
  String get scheme => 'dropbox';
  @override
  String get rootPath => '';
  @override
  String get rootTitle => 'Dropbox';

  @override
  Future<String> accountName() async {
    final j = await postJson('$_api/users/get_current_account', null);
    return (j['email'] as String?) ?? 'Dropbox';
  }

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final out = <RemoteEntry>[];
    var j = await postJson('$_api/files/list_folder', {'path': path, 'limit': 2000});
    while (true) {
      for (final e in (j['entries'] as List).cast<Map<String, dynamic>>()) {
        final tag = e['.tag'];
        if (tag != 'file' && tag != 'folder') continue;
        out.add(
          RemoteEntry(
            name: e['name'] as String,
            path: e['path_lower'] as String,
            isDir: tag == 'folder',
            size: (e['size'] as num?)?.toInt() ?? 0,
            modified: DateTime.tryParse(e['server_modified'] as String? ?? ''),
          ),
        );
      }
      if (j['has_more'] != true) break;
      j = await postJson('$_api/files/list_folder/continue', {'cursor': j['cursor']});
    }
    return out;
  }

  @override
  Future<({String url, Map<String, String>? headers})> streamFor(String path) async {
    // 4시간짜리 임시 링크 (인증 헤더 불필요, Range 지원)
    final j = await postJson('$_api/files/get_temporary_link', {'path': path});
    return (url: j['link'] as String, headers: null);
  }
}

// ---------------------------------------------------------------- OneDrive
class OneDriveSource extends CloudSource {
  OneDriveSource(super.account);
  static const _api = 'https://graph.microsoft.com/v1.0/me/drive';

  @override
  String get scheme => 'onedrive';
  @override
  String get rootPath => 'root';
  @override
  String get rootTitle => 'OneDrive';

  @override
  Future<String> accountName() async {
    final j = await getJson('https://graph.microsoft.com/v1.0/me');
    return (j['userPrincipalName'] as String?) ?? (j['displayName'] as String?) ?? 'OneDrive';
  }

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final out = <RemoteEntry>[];
    String? next = path == 'root'
        ? '$_api/root/children?\$top=1000&\$expand=thumbnails'
        : '$_api/items/$path/children?\$top=1000&\$expand=thumbnails';
    while (next != null) {
      final j = await getJson(next);
      for (final e in (j['value'] as List).cast<Map<String, dynamic>>()) {
        final thumbs = e['thumbnails'] as List?;
        out.add(
          RemoteEntry(
            name: e['name'] as String,
            path: e['id'] as String,
            isDir: e['folder'] != null,
            size: (e['size'] as num?)?.toInt() ?? 0,
            modified: DateTime.tryParse(e['lastModifiedDateTime'] as String? ?? ''),
            thumbnailUrl: (thumbs != null && thumbs.isNotEmpty) ? (thumbs.first['medium']?['url'] as String?) : null,
          ),
        );
      }
      next = j['@odata.nextLink'] as String?;
    }
    return out;
  }

  @override
  Future<({String url, Map<String, String>? headers})> streamFor(String path) async {
    // downloadUrl은 사전 인증된 단기 URL (헤더 불필요)
    final j = await getJson('$_api/items/$path?\$select=id,@microsoft.graph.downloadUrl');
    final url = j['@microsoft.graph.downloadUrl'] as String?;
    if (url == null) throw '재생 URL을 얻지 못했습니다';
    return (url: url, headers: null);
  }
}
