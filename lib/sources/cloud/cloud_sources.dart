import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../core/media_item.dart';
import '../../core/plugins/plugin.dart';
import '../../core/plugins/plugin_store.dart';
import '../../core/plugins/plugin_runtime.dart';
import '../../core/secure_store.dart';
import '../media_source.dart';
import '../server_store.dart';
import 'cloud_config.dart';
import 'oauth.dart';

/// OAuth/transport remain native; provider endpoints and behavior live in JS.
OAuthClient oauthClientFor(CloudProvider provider, {String? clientId, String? accountEmail, String? pluginId}) {
  final definition = PluginStore.instance.require(pluginId ?? 'cloud.${provider.name}');
  final oauth = definition.oauth;
  if (provider == CloudProvider.gdrive && Platform.isAndroid) {
    return GoogleAndroidOAuthClient(
      clientId: clientId ?? CloudConfig.googleAndroidClientId,
      accountEmail: accountEmail,
    );
  }
  final id =
      clientId ??
      switch (provider) {
        CloudProvider.gdrive => CloudConfig.googleDesktopClientId,
        CloudProvider.dropbox => CloudConfig.dropboxAppKey,
        CloudProvider.onedrive => CloudConfig.oneDriveClientId,
        CloudProvider.plugin => oauth['clientId'] as String? ?? '',
      };
  return OAuthClient(
    authEndpoint: oauth['authEndpoint'] as String,
    tokenEndpoint: oauth['tokenEndpoint'] as String,
    clientId: id,
    clientSecretKey: provider == CloudProvider.gdrive ? CloudConfig.googleSecretKey(id) : null,
    scopes: (oauth['scopes'] as List).cast<String>(),
    mobileScheme: CloudConfig.mobileScheme,
    mobileRedirectUri: switch (provider) {
      CloudProvider.dropbox => CloudConfig.dropboxRedirect,
      CloudProvider.onedrive => CloudConfig.oneDriveRedirect,
      _ => oauth['mobileRedirectUri'] as String?,
    },
    extraAuthParams: (oauth['extraAuthParams'] as Map? ?? {}).cast<String, String>(),
    loopbackHost: oauth['loopbackHost'] as String? ?? '127.0.0.1',
  );
}

/// 로그인 → 계정 이름 조회 → 저장
Future<CloudAccount> connectCloudAccount(CloudProvider provider, {String? pluginId, String? clientId}) async {
  final client = oauthClientFor(provider, pluginId: pluginId, clientId: clientId);
  final tokens = await client.authorize();
  final account = CloudAccount(
    id: ServerStore.newId(),
    provider: provider,
    name: PluginStore.instance.require(pluginId ?? 'cloud.${provider.name}').name,
    pluginId: pluginId,
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

CloudSource cloudSourceFor(CloudAccount a) => CloudSource(a);

class CloudSource extends MediaSource {
  CloudSource(this.account)
    : tokens = TokenHolder(
        account.tokenKey,
        oauthClientFor(
          account.provider,
          pluginId: account.pluginId,
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

  OPlugin get definition => PluginStore.instance.require(account.pluginId ?? 'cloud.${account.provider.name}');
  @override
  String get scheme => account.provider.name;
  @override
  String get rootPath => definition.manifest['root'] as String? ?? '';
  @override
  String get rootTitle => definition.manifest['rootTitle'] as String? ?? definition.name;

  Future<Object?> _call(String method, Map<String, dynamic> input) => callPlugin(
    definition,
    method,
    input,
    request: (url, options) async {
      if (!definition.allows(url, auth: true)) throw StateError('인증이 허용되지 않은 클라우드 도메인');
      return switch (options['method'] ?? 'GET') {
        'GET' => getJson(url),
        'POST' => postJson(url, options['body']),
        _ => throw StateError('지원하지 않는 클라우드 요청 방식'),
      };
    },
  );

  Future<String> accountName() async => await _call('accountName', {}) as String? ?? definition.name;

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final result = await _call('list', {'path': path}) as List;
    return result.map((value) {
      final e = value as Map;
      return RemoteEntry(
        name: e['name'] as String,
        path: e['path'] as String,
        isDir: e['isDir'] == true,
        size: (e['size'] as num?)?.toInt() ?? 0,
        modified: DateTime.tryParse(e['modified'] as String? ?? ''),
        thumbnailUrl: e['thumbnailUrl'] as String?,
      );
    }).toList();
  }

  @override
  String keyFor(String path) => '$scheme://$id/$path';

  /// 파일 ID → 재생 URL + 헤더
  Future<({String url, Map<String, String>? headers})> streamFor(String path) async {
    final result = await _call('stream', {'path': path}) as Map;
    final url = result['url'] as String;
    final uri = Uri.parse(url);
    if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) throw StateError('잘못된 클라우드 재생 주소');
    final auth = result['authenticated'] == true;
    if (auth && !definition.allows(url, auth: true)) throw StateError('재생 주소에 인증을 보낼 수 없습니다');
    return (url: url, headers: auth ? await tokens.authHeader() : null);
  }

  Future<Map<String, dynamic>> getJson(String url) => _request(url, 'GET');
  Future<Map<String, dynamic>> postJson(String url, Object? body) => _request(url, 'POST', body);

  Future<Map<String, dynamic>> _request(String url, String method, [Object? body]) async {
    if (!definition.allows(url, auth: true)) throw StateError('허용되지 않은 인증 도메인');
    final client = http.Client();
    try {
      Future<http.Response> send(bool refresh) async {
        final request = http.Request(method, Uri.parse(url))..followRedirects = false;
        request.headers.addAll(await tokens.authHeader(forceRefresh: refresh));
        if (method == 'POST') {
          request.headers['Content-Type'] = 'application/json'; request.body = jsonEncode(body);
        }
        final response = await client.send(request).timeout(const Duration(seconds: 30));
        final bytes = <int>[];
        await for (final chunk in response.stream.timeout(const Duration(seconds: 30))) {
          bytes.addAll(chunk);
          if (bytes.length > 8 * 1024 * 1024) throw StateError('클라우드 응답 크기 제한 초과');
        }
        return http.Response.bytes(bytes, response.statusCode);
      }
      var response = await send(false);
      if (response.statusCode == 401) response = await send(true);
      return _decode(response);
    } finally { client.close(); }
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

// Compatibility names keep callers stable; all provider behavior comes from JS.
class GoogleDriveSource extends CloudSource {
  GoogleDriveSource(super.account);
}

class DropboxSource extends CloudSource {
  DropboxSource(super.account);
}

class OneDriveSource extends CloudSource {
  OneDriveSource(super.account);
}
