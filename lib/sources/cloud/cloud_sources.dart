import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../core/media_item.dart';
import '../../core/plugins/plugin.dart';
import '../../core/plugins/plugin_store.dart';
import '../../core/plugins/plugin_runtime.dart';
import '../../core/plugins/plugin_values.dart';
import '../../core/plugins/plugin_http.dart';
import '../../core/plugins/plugin_upload.dart';
import '../../core/secure_store.dart';
import '../../core/network/network_service.dart';
import '../../core/stream_proxy.dart';
import '../../core/file_deletion.dart';
import '../../core/file_renaming.dart';
import '../media_source.dart';
import '../server_store.dart';
import 'cloud_config.dart';
import 'oauth.dart';
import 's3_credentials.dart';

/// OAuth/transport remain native; provider endpoints and behavior live in JS.
OAuthClient oauthClientFor(CloudProvider provider, {String? clientId, String? accountEmail, String? pluginId}) {
  final definition = PluginStore.instance.require(pluginId ?? 'cloud.${provider.name}');
  if (definition.authType != 'oauth') throw StateError('OAuth 확장앱이 아닙니다');
  final oauth = definition.oauth;
  if (Platform.isAndroid && (definition.oauth['nativeAndroid'] == 'google' || provider == CloudProvider.gdrive)) {
    return GoogleAndroidOAuthClient(
      clientId:
          clientId ??
          (PluginStore.instance.oauthClientId(definition).isNotEmpty
              ? PluginStore.instance.oauthClientId(definition)
              : CloudConfig.googleAndroidClientId),
      accountEmail: accountEmail,
      requestedScopes: (oauth['scopes'] as List).cast<String>(),
    );
  }
  final id =
      clientId ??
      (PluginStore.instance.oauthClientId(definition).isNotEmpty
          ? PluginStore.instance.oauthClientId(definition)
          : null) ??
      switch (provider) {
        CloudProvider.gdrive => CloudConfig.googleDesktopClientId,
        CloudProvider.dropbox => CloudConfig.dropboxAppKey,
        CloudProvider.onedrive => CloudConfig.oneDriveClientId,
        CloudProvider.plugin => PluginStore.instance.oauthClientId(definition),
      };
  return OAuthClient(
    authEndpoint: oauth['authEndpoint'] as String,
    tokenEndpoint: oauth['tokenEndpoint'] as String,
    clientId: id,
    clientSecret:
        oauth['tokenEndpoint'] == 'https://oauth2.googleapis.com/token' &&
            oauth['authEndpoint'] == 'https://accounts.google.com/o/oauth2/v2/auth'
        ? CloudConfig.googleBundledSecret(id)
        : null,
    clientSecretKey: provider == CloudProvider.gdrive || oauth['requiresClientSecret'] == true
        ? PluginStore.oauthSecretKey(definition.id, id)
        : null,
    clientSecretFallbackKey: provider == CloudProvider.gdrive ? CloudConfig.googleSecretKey(id) : null,
    scopes: (oauth['scopes'] as List).cast<String>(),
    mobileScheme: CloudConfig.mobileScheme,
    mobileRedirectUri: switch (provider) {
      CloudProvider.dropbox => CloudConfig.dropboxRedirect,
      CloudProvider.onedrive => CloudConfig.oneDriveRedirect,
      _ => oauth['mobileRedirectUri'] as String?,
    },
    extraAuthParams: (oauth['extraAuthParams'] as Map? ?? {}).cast<String, String>(),
    loopbackHost: oauth['loopbackHost'] as String? ?? '127.0.0.1',
    usePkce: oauth['pkce'] != false,
    loopbackOnMobile: oauth['loopbackOnMobile'] == true,
  );
}

/// 로그인 → 계정 이름 조회 → 저장
Future<CloudAccount> connectCloudAccount(CloudProvider provider, {String? pluginId, String? clientId}) async {
  final definition = PluginStore.instance.require(pluginId ?? 'cloud.${provider.name}');
  final client = definition.authType == 'oauth'
      ? oauthClientFor(provider, pluginId: pluginId, clientId: clientId)
      : null;
  final tokens = await client?.authorize();
  final credentials = client == null ? await PluginStore.instance.credentials(definition.id) : null;
  if (definition.authType == 's3') S3Credentials(credentials!);
  if (definition.authType == 'bearer' && '${credentials?['accessToken'] ?? ''}'.isEmpty) {
    throw StateError('확장앱 설정에 개인 액세스 토큰을 입력해 주세요');
  }
  final account = CloudAccount(
    id: ServerStore.newId(),
    provider: provider,
    name: definition.name,
    pluginId: pluginId,
    oauthClientId: client?.clientId,
  );
  if (client != null) {
    await TokenHolder(account.tokenKey, client).save(tokens!);
  } else {
    await SecureStore.instance.writeRequired(
      account.tokenKey,
      jsonEncode({...credentials!, 'authType': definition.authType, 'pluginId': definition.id}),
    );
  }
  final src = cloudSourceFor(account);
  try {
    if (definition.authType == 'script') await src.authenticate();
    final name = await src.accountName();
    final chosenName = '${credentials?['displayName'] ?? ''}'.trim();
    account.name = chosenName.isEmpty ? name : chosenName;
    await ServerStore.instance.saveAccount(account);
  } catch (_) {
    await SecureStore.instance.writeRequired(account.tokenKey, null);
    rethrow;
  } finally {
    await src.close();
  }
  return account;
}

CloudSource cloudSourceFor(CloudAccount a) => CloudSource(a);

class CloudSource extends MediaSource {
  CloudSource(this.account);
  TokenHolder? _tokens;
  TokenHolder get tokens {
    if (_tokens != null) return _tokens!;
    if (_closed) throw StateError('계정 연결이 해제되었습니다');
    return _tokens ??= TokenHolder(
      account.tokenKey,
      oauthClientFor(
        account.provider,
        pluginId: account.pluginId,
        clientId: account.oauthClientId,
        accountEmail: account.name.contains('@') ? account.name : null,
      ),
    );
  }

  final CloudAccount account;
  bool _closed = false;
  final _proxyUrls = <String>{};

  @override
  Future<void> close() async {
    _closed = true;
    _tokens?.close();
    for (final url in _proxyUrls) {
      StreamProxy.instance.unregister(url);
    }
    _proxyUrls.clear();
  }

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

  @override
  bool get canDelete => definition.manifest['canDelete'] == true;

  @override
  bool get canRename => definition.manifest['canRename'] == true;
  @override
  bool canRenameEntry(RemoteEntry entry) =>
      canRename && !entry.isDir && entry.path.isNotEmpty && ![rootPath, '/', '.', '..'].contains(entry.path);
  @override
  String renamedPath(RemoteEntry entry, String name) {
    if (!canRenameEntry(entry)) throw UnsupportedError('이 확장앱은 이름변경을 지원하지 않습니다');
    validateFileName(name);
    return entry.path; // Cloud IDs remain stable when the display name changes.
  }

  @override
  Future<String> rename(RemoteEntry entry, String name) async {
    final path = renamedPath(entry, name);
    final result = await _call('rename', {'path': path, 'name': entry.name, 'newName': name}, retry: false);
    if (result != true) throw StateError('확장앱이 이름변경 완료를 확인하지 못했습니다');
    return path;
  }

  @override
  bool canDeleteEntry(RemoteEntry entry) =>
      canDelete && entry.path.isNotEmpty && ![rootPath, '/', '.', '..'].contains(entry.path);

  @override
  Future<void> delete(RemoteEntry entry) async {
    if (!canDeleteEntry(entry)) throw UnsupportedError('이 확장앱은 해당 항목 삭제를 지원하지 않습니다');
    // ponytail: opaque IDs have no ancestry; verify all account locks for folder
    // deletion until the extension SDK provides descendant IDs.
    if (entry.isDir) await authorizeDeletion('$scheme://$id', directory: true);
    final result = await _call('delete', {'path': entry.path, 'name': entry.name, 'isDir': entry.isDir}, retry: false);
    if (result != true) throw StateError('확장앱이 삭제 완료를 확인하지 못했습니다');
  }

  Future<Map<String, dynamic>> _credentials() async {
    if (_closed) throw StateError('계정 연결이 해제되었습니다');
    final raw = await SecureStore.instance.readRequired(account.tokenKey);
    if (raw == null) throw StateError('확장앱 설정에서 인증 정보를 등록하고 계정을 다시 연결해 주세요');
    final values = (jsonDecode(raw) as Map).cast<String, dynamic>();
    if (values['pluginId'] != definition.id || values['authType'] != definition.authType) {
      throw StateError('확장앱 인증 방식이 변경되었습니다. 계정을 다시 연결해 주세요');
    }
    return values;
  }

  Future<void> authenticate({bool refresh = false}) async {
    final changed = await _call(refresh ? 'refresh' : 'authenticate', {}, retry: false);
    if (changed == null) {
      if (refresh) throw StateError('인증이 만료되었습니다. 계정을 다시 연결해 주세요');
      return;
    }
    if (changed is! Map ||
        changed.keys.any(
          (key) =>
              key is! String ||
              ['authType', 'pluginId'].contains(key) ||
              definition.settings.any((f) => f['key'] == key),
        )) {
      throw StateError('확장앱 인증 응답이 설정을 덮어쓸 수 없습니다');
    }
    await SecureStore.instance.writeRequired(account.tokenKey, jsonEncode({...await _credentials(), ...changed}));
  }

  Future<Object?> _call(String method, Map<String, dynamic> input, {bool retry = true}) async {
    if (_closed) throw StateError('계정 연결이 해제되었습니다');
    final plugin = definition;
    final values = plugin.authType == 'oauth'
        ? await PluginStore.instance.credentials(plugin.id)
        : await _credentials();
    final s3 = plugin.authType == 's3' ? S3Credentials(values) : null;
    final config = {
      ...plugin.publicConfig(values),
      ...?s3?.publicConfig,
      if (plugin.authType == 'oauth') plugin.oauth['clientIdSetting'] as String? ?? 'clientId': tokens.client.clientId,
    };
    var unauthorized = false;
    try {
      return await callPlugin(
        plugin,
        method,
        input,
        config: config,
        credentials: values,
        allowsRequest: s3?.allows ?? (url) => plugin.allowsConfigured(url, config),
        request: (url, options) async {
          final verb = options['method'] as String? ?? 'GET';
          if (!['GET', 'POST', 'HEAD', 'PUT', 'PATCH', 'DELETE'].contains(verb) ||
              (s3 != null && !['GET', 'HEAD'].contains(verb))) {
            throw StateError('지원하지 않는 클라우드 요청 방식');
          }
          if (options['response'] == 'signedUrl') {
            if (s3 == null || verb != 'GET') throw StateError('S3 읽기 URL만 서명할 수 있습니다');
            return s3.presign(Uri.parse(url)).toString();
          }
          return _request(
            url,
            verb,
            body: options['body'],
            responseType: options['response'] as String? ?? 'json',
            s3: s3,
            options: options,
            onUnauthorized: () => unauthorized = true,
          );
        },
      );
    } catch (_) {
      if (retry && unauthorized && plugin.authType == 'script') {
        await authenticate(refresh: true);
        return _call(method, input, retry: false);
      }
      rethrow;
    }
  }

  Future<String> accountName() async => await _call('accountName', {}) as String? ?? definition.name;

  @override
  Future<List<RemoteEntry>> list(String path) async {
    return _entries(await _call('list', {'path': path}));
  }

  @override
  bool get canSearch => definition.manifest['canSearch'] == true;

  @override
  bool get canUpload => definition.manifest['canUpload'] == true && definition.authType == 'oauth';

  @override
  Future<String> upload(
    File local,
    String remoteDir,
    String name, {
    String? overwritePath,
    void Function(int sent)? onProgress,
    Future<void>? cancelled,
  }) async {
    if (!canUpload) throw UnsupportedError('이 확장앱은 업로드를 지원하지 않습니다');
    validateFileName(name);
    var stopped = false, finished = false;
    cancelled?.then((_) {
      if (!finished) stopped = true;
    });
    void check() {
      if (stopped || _closed) throw StateError('업로드가 중단되었습니다');
      definition;
    }

    try {
      check();
      final size = await local.length();
      final plan = await _call('upload', {
        'path': remoteDir,
        'name': name,
        'size': size,
        'overwritePath': overwritePath,
      }, retry: false);
      check();
      if (plan is! Map || plan['protocol'] != 'http-content-range' || plan['url'] is! String) {
        throw StateError('지원하지 않는 확장앱 업로드 방식');
      }
      final uri = Uri.tryParse(plan['url'] as String);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.userInfo.isNotEmpty ||
          uri.hasFragment ||
          !definition.allows(uri.toString(), auth: true)) {
        throw StateError('허용되지 않은 업로드 도메인');
      }
      final response = await uploadPluginFile(
        local,
        uri,
        client: http.Client(),
        authHeaders: (refresh) => _authHeader(refresh: refresh),
        check: check,
        onProgress: onProgress,
        cancelled: cancelled,
      );
      check();
      final path = await _call('uploadComplete', {'response': response}, retry: false);
      if (path is! String || path.isEmpty || path.length > 4096) throw StateError('업로드 파일 ID가 올바르지 않습니다');
      return path;
    } finally {
      finished = true;
    }
  }

  @override
  Future<List<RemoteEntry>> search(String query, {required String path}) async {
    if (!canSearch) throw UnsupportedError('이 확장앱은 검색을 지원하지 않습니다');
    if (query.trim().isEmpty) return [];
    return _entries(await _call('search', {'query': query.trim(), 'path': path}));
  }

  List<RemoteEntry> _entries(Object? result) {
    if (result is! List) throw StateError('확장앱이 파일 목록을 반환하지 않았습니다');
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
    final result = await _remoteStream(path);
    if (result['refreshEachRequest'] == true) {
      final length = (result['size'] as num?)?.toInt() ?? -1;
      if (length < 0) throw StateError('클라우드 파일 크기를 얻지 못했습니다');
      Map? first = result;
      final local = await StreamProxy.instance.register(
        name: result['name'] as String? ?? path,
        length: length,
        opener: (start, end) async {
          final initial = first;
          first = null;
          final remote = initial ?? await _remoteStream(path, refresh: true);
          return _openRange(remote, start, end);
        },
      );
      _proxyUrls.add(local);
      return (url: local, headers: null);
    }
    return (url: result['url'] as String, headers: await _streamHeaders(result));
  }

  Future<Map> _remoteStream(String path, {bool refresh = false}) async {
    final result = await _call('stream', {'path': path, if (refresh) 'refresh': true}) as Map;
    final url = result['url'] as String;
    final uri = Uri.parse(url);
    final localS3 = definition.authType == 's3' && S3Credentials(await _credentials()).allows(url);
    if (definition.authType == 's3' && !localS3) throw StateError('S3 재생 주소가 등록한 버킷 밖에 있습니다');
    if ((!localS3 && uri.scheme != 'https') || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      throw StateError('잘못된 클라우드 재생 주소');
    }
    final auth = result['authenticated'] == true;
    if (auth && !definition.allows(url, auth: true)) throw StateError('재생 주소에 인증을 보낼 수 없습니다');
    return result;
  }

  Future<Map<String, String>?> _streamHeaders(Map result) async =>
      result['authenticated'] == true ? await _authHeader() : null;

  Future<Map<String, String>> _authHeader({bool refresh = false}) async {
    if (_closed) throw StateError('계정 연결이 해제되었습니다');
    if (definition.authType == 'oauth') return tokens.authHeader(forceRefresh: refresh);
    if (definition.authType != 'bearer') throw StateError('Bearer 인증을 보낼 수 없는 확장앱입니다');
    final value = (await _credentials())['accessToken'] as String? ?? '';
    if (value.isEmpty) throw StateError('개인 액세스 토큰을 다시 등록하고 계정을 연결해 주세요');
    return {'Authorization': 'Bearer $value'};
  }

  Future<Stream<List<int>>> _openRange(Map result, int start, int end) async {
    if (_closed) throw StateError('계정 연결이 해제되었습니다');
    definition; // Check enabled/installed state for every seek, too.
    final client = NetworkService.instance.createHttpClient();
    try {
      var uri = Uri.parse(result['url'] as String);
      var headers = await _streamHeaders(result) ?? <String, String>{};
      late HttpClientResponse response;
      for (var redirects = 0; ; redirects++) {
        final request = await client.getUrl(uri).timeout(const Duration(seconds: 30));
        request.followRedirects = false;
        headers.forEach(request.headers.set);
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        request.headers.set('Range', 'bytes=$start-${end - 1}');
        response = await request.close().timeout(const Duration(seconds: 30));
        final location = response.headers.value('location');
        if (![301, 302, 303, 307, 308].contains(response.statusCode) || location == null) break;
        await response.listen((_) {}).cancel();
        final next = uri.resolve(location);
        if (redirects >= 4 || next.scheme != 'https' || next.host.isEmpty || next.userInfo.isNotEmpty) {
          throw StateError('지원하지 않는 클라우드 재생 리디렉션');
        }
        if (next.origin != uri.origin) headers = {};
        uri = next;
      }
      if (response.statusCode != 206 && response.statusCode != 200) {
        throw StateError('클라우드 재생 HTTP ${response.statusCode}');
      }
      if (response.statusCode == 206 && !('${response.headers.value('content-range')}'.startsWith('bytes $start-'))) {
        throw StateError('클라우드 Range 응답이 올바르지 않습니다');
      }
      Stream<List<int>> body() async* {
        var skip = response.statusCode == 200 ? start : 0;
        var remaining = end - start;
        try {
          await for (final bytes in response.timeout(const Duration(seconds: 40))) {
            final offset = skip.clamp(0, bytes.length);
            skip -= offset;
            final count = (bytes.length - offset).clamp(0, remaining);
            if (count > 0) {
              yield bytes.sublist(offset, offset + count);
              remaining -= count;
            }
            if (remaining == 0) break;
          }
          if (remaining != 0) throw StateError('클라우드 미디어 수신이 중단되었습니다');
        } finally {
          client.close(force: true);
        }
      }

      return body();
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }

  void _release(String url) {
    if (_proxyUrls.remove(url)) StreamProxy.instance.unregister(url);
  }

  Future<Map<String, dynamic>> getJson(String url) async => await _request(url, 'GET') as Map<String, dynamic>;
  Future<Map<String, dynamic>> postJson(String url, Object? body) async =>
      await _request(url, 'POST', body: body) as Map<String, dynamic>;

  Future<Object?> _request(
    String url,
    String method, {
    Object? body,
    String responseType = 'json',
    S3Credentials? s3,
    Map<String, dynamic> options = const {},
    void Function()? onUnauthorized,
  }) async {
    if (_closed) throw StateError('계정 연결이 해제되었습니다');
    final values = definition.authType == 'oauth'
        ? await PluginStore.instance.credentials(definition.id)
        : await _credentials();
    final config = definition.publicConfig(values);
    if (!(s3?.allows(url) ?? definition.allowsConfigured(url, config))) throw StateError('허용되지 않은 확장앱 도메인');
    final auth = definition.authType != 'script' && definition.authType != 's3' && options['authenticated'] != false;
    final protected =
        usesPluginSecret(options) ||
        (options['headers'] as Map? ?? {}).keys.any((k) => ['authorization', 'cookie'].contains('$k'.toLowerCase()));
    if ((auth || protected) && !definition.allowsConfigured(url, config, auth: true)) {
      throw StateError('허용되지 않은 인증 도메인');
    }
    final client = http.Client();
    try {
      Future<http.Response> send(bool refresh) async {
        final current = definition.authType == 'oauth' ? values : await _credentials();
        final request = pluginHttpRequest(
          method,
          url,
          {...options, if (!options.containsKey('body') && body != null) 'body': body},
          current,
          sign: s3 == null ? null : (uri) => s3.presign(uri, method: method),
          authHeaders: auth ? await _authHeader(refresh: refresh) : const {},
        );
        final response = await client.send(request).timeout(const Duration(seconds: 30));
        if (responseType == 'redirect' || responseType == 'headers') {
          await response.stream.listen((_) {}).cancel();
          return http.Response.bytes([], response.statusCode, headers: response.headers);
        }
        final bytes = <int>[];
        await for (final chunk in response.stream.timeout(const Duration(seconds: 30))) {
          bytes.addAll(chunk);
          if (bytes.length > 8 * 1024 * 1024) throw StateError('클라우드 응답 크기 제한 초과');
        }
        return http.Response.bytes(bytes, response.statusCode, headers: response.headers);
      }

      var response = await send(false);
      if (response.statusCode == 401 && definition.authType == 'oauth') response = await send(true);
      if (responseType != 'raw' && response.statusCode == 401) onUnauthorized?.call();
      if (responseType != 'json' || definition.authType == 'script') {
        return decodePluginResponse(response, responseType, url);
      }
      return _decode(response);
    } finally {
      client.close();
    }
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
          _release(ss.url);
        }
        return MediaItem(
          key: key,
          uri: s.url,
          title: title,
          headers: s.headers,
          subtitles: refs,
          onRelease: () async => _release(s.url),
        );
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
        return MediaItem(
          key: key,
          uri: s.url,
          title: title,
          headers: s.headers,
          onRelease: () async => _release(s.url),
        );
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
