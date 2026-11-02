import 'dart:convert';
import 'plugin_compatibility.dart';

/// A single JS file with a JSON metadata header, followed by `globalThis.plugin`.
class OPlugin {
  OPlugin._(this.source, this.manifest);
  final String source;
  final Map<String, dynamic> manifest;
  String get id => manifest['id'] as String;
  String get name => manifest['name'] as String;
  String get version => manifest['version'] as String;
  // Legacy manifests keep their source/identity, but use the same host contract.
  String get kind => switch (manifest['kind']) {
    'cloud' => 'resource',
    'site' => 'browser',
    'subtitle' => 'player',
    final String value => value,
    _ => '',
  };
  static const contracts = {
    'player': {
      'subtitles': ['searchSubtitles', 'downloadSubtitle'],
      'videoFilter': ['videoFilter'],
      'upscaling': ['upscaleModels', 'upscaleModel'],
      'interpolation': ['interpolationModels'],
    },
    'browser': {
      'page': ['page'],
      'resolveDownload': ['resolveDownload'],
      'blockRequests': <String>[],
    },
    'resource': {
      'storage': ['accountName', 'list', 'stream'],
    },
  };
  String? compatibilityIssue({String? platform}) => pluginCompatibilityIssue(manifest, platform: platform);
  bool get typed => contracts.containsKey(manifest['kind']);
  List<String> get capabilities => typed
      ? (manifest['capabilities'] as List).cast<String>()
      : switch (manifest['kind']) {
          'cloud' => ['storage'],
          'subtitle' => ['subtitles'],
          _ => ['page', 'resolveDownload', 'blockRequests'],
        };
  bool supports(String capability) => capabilities.contains(capability);
  bool get cloud => kind == 'resource';
  bool get site => kind == 'browser';
  bool get subtitle => kind == 'player' && supports('subtitles');
  String get kindLabel => switch (kind) {
    'player' => '플레이어',
    'resource' => '리소스',
    _ => '브라우저',
  };
  Set<String> get allowedMethods => {
    'validateSettings',
    for (final capability in capabilities) ...contracts[kind]![capability]!,
    if (cloud) ...[
      'authenticate',
      'refresh',
      if (manifest['canDelete'] == true) 'delete',
      if (manifest['canRename'] == true) 'rename',
      if (manifest['canSearch'] == true) 'search',
      if (manifest['canUpload'] == true) ...['upload', 'uploadComplete'],
      if (manifest['uploadRoot'] != null) 'uploadRoot',
    ],
  };
  List<String> get hosts => (manifest['hosts'] as List).cast<String>();
  List<String> get authHosts => (manifest['authHosts'] as List? ?? []).cast<String>();
  List<String> get sites => (manifest['sites'] as List? ?? []).cast<String>();
  Map<String, dynamic> get oauth => (manifest['oauth'] as Map? ?? {}).cast<String, dynamic>();
  String get authType => (manifest['auth'] as Map?)?['type'] as String? ?? 'oauth';
  List<Map<String, dynamic>> get settings => (manifest['settings'] as List? ?? []).cast<Map<String, dynamic>>();
  Map<String, dynamic> publicConfig(Map<String, dynamic> values) => {
    for (final field in settings)
      if (field['type'] != 'password' && (values.containsKey(field['key']) || field.containsKey('default')))
        field['key'] as String: values[field['key']] ?? field['default'],
  };

  bool allowsConfigured(String url, Map<String, dynamic> config, {bool auth = false}) {
    if (allows(url, auth: auth)) return true;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasFragment) return false;
    for (final key in (manifest[auth ? 'authSettings' : 'networkSettings'] as List? ?? []).cast<String>()) {
      final base = Uri.tryParse('${config[key] ?? ''}');
      if (base == null || base.host.isEmpty || !['https', 'http'].contains(uri.scheme)) continue;
      try {
        repositoryUri(base.toString());
      } catch (_) {
        continue;
      }
      if (base.hasQuery || base.hasFragment) continue;
      if (uri.origin == base.origin &&
          (uri.path == base.path || uri.path.startsWith(base.path.endsWith('/') ? base.path : '${base.path}/'))) {
        return true;
      }
    }
    return false;
  }

  static OPlugin parse(String source) {
    if (utf8.encode(source).length > 1024 * 1024) throw const FormatException('확장앱 파일은 1MB 이하여야 합니다');
    final first = source.trimLeft().split('\n').first;
    if (!first.startsWith('// @oplayer ')) throw const FormatException('확장앱 메타데이터가 없습니다');
    final meta = jsonDecode(first.substring(12)) as Map<String, dynamic>;
    if (![1, 2, 3, 4, 5].contains(meta['api']) ||
        !RegExp(r'^[a-z][a-z0-9._-]{1,79}$').hasMatch('${meta['id']}') ||
        meta['name'] is! String ||
        '${meta['name']}'.isEmpty ||
        meta['version'] is! String ||
        !['site', 'cloud', 'subtitle', ...contracts.keys].contains(meta['kind'])) {
      throw const FormatException('지원하지 않는 확장앱 형식입니다');
    }
    for (final key in ['hosts', 'authHosts', 'sites']) {
      final values = meta[key] ?? [];
      if (values is! List ||
          values.length > 100 ||
          values.any(
            (v) =>
                v is! String ||
                !(key == 'sites' && v == '*') && !RegExp(r'^(\*\.)?[a-zA-Z0-9][a-zA-Z0-9.-]*$').hasMatch(v),
          )) {
        throw FormatException('잘못된 도메인 권한: $key');
      }
    }
    meta['hosts'] ??= <String>[];
    final plugin = OPlugin._(source, meta);
    if (plugin.typed) {
      final capabilities = meta['capabilities'];
      if (![4, 5].contains(meta['api']) ||
          capabilities is! List ||
          capabilities.isEmpty ||
          capabilities.any((c) => c is! String || !contracts[plugin.kind]!.containsKey(c)) ||
          capabilities.toSet().length != capabilities.length) {
        throw const FormatException('유형에 맞는 API 4/5 기능(capabilities)을 선언하세요');
      }
      if (!plugin.site && (meta.containsKey('sites') || meta.containsKey('blockRules')) ||
          !plugin.cloud &&
              ['oauth', 'auth', 'canDelete', 'canRename', 'canSearch', 'canUpload'].any(meta.containsKey)) {
        throw const FormatException('다른 유형의 확장앱 권한은 사용할 수 없습니다');
      }
      if (plugin.site && !plugin.supports('blockRequests') && meta.containsKey('blockRules')) {
        throw const FormatException('광고 차단에는 blockRequests 기능 선언이 필요합니다');
      }
    }
    if (meta['canDelete'] != null && meta['canDelete'] is! bool) {
      throw const FormatException('잘못된 삭제 지원 선언');
    }
    if (meta['canRename'] != null && meta['canRename'] is! bool) {
      throw const FormatException('잘못된 이름변경 지원 선언');
    }
    if (meta['canSearch'] != null && meta['canSearch'] is! bool) {
      throw const FormatException('잘못된 검색 지원 선언');
    }
    if (meta['canUpload'] != null && meta['canUpload'] is! bool) {
      throw const FormatException('잘못된 업로드 지원 선언');
    }
    if (meta['uploadRoot'] != null) {
      final root = meta['uploadRoot'];
      if (!plugin.cloud ||
          meta['api'] != 5 ||
          meta['canUpload'] != true ||
          root is! Map ||
          root['title'] is! String ||
          (root['title'] as String).isEmpty ||
          (root['title'] as String).length > 100 ||
          !((meta['requiresHost'] as List?)?.contains('fixedUploadRoot') ?? false)) {
        throw const FormatException('고정 업로드 폴더에는 API 5·fixedUploadRoot·폴더 제목 선언이 필요합니다');
      }
    }
    final requirements = meta['requiresHost'];
    if (requirements != null &&
        (meta['api'] != 5 ||
            requirements is! List ||
            requirements.length > 30 ||
            requirements.any((v) => v is! String || !RegExp(r'^[a-zA-Z][a-zA-Z0-9.]{0,63}$').hasMatch(v)) ||
            requirements.toSet().length != requirements.length)) {
      throw const FormatException('requiresHost 기능 선언에는 API 5와 올바른 기능 목록이 필요합니다');
    }
    if (meta['platforms'] != null &&
        (meta['platforms'] is! List ||
            (meta['platforms'] as List).isEmpty ||
            (meta['platforms'] as List).any((p) => !['android', 'ios', 'windows', 'linux', 'macos'].contains(p)))) {
      throw const FormatException('잘못된 지원 플랫폼 선언');
    }
    if (plugin.authHosts.any((h) => !plugin.hosts.contains(h))) {
      throw const FormatException('인증 도메인은 네트워크 권한에도 있어야 합니다');
    }
    if (plugin.site && plugin.sites.isEmpty) throw const FormatException('사이트 확장앱에는 sites 권한이 필요합니다');
    if (plugin.subtitle && ![4, 5].contains(meta['api'])) throw const FormatException('자막 검색에는 확장앱 API 4 이상이 필요합니다');
    final rules = meta['blockRules'] ?? [];
    if (rules is! List || rules.length > 500) throw const FormatException('광고 차단 규칙 제한 초과');
    for (final rule in rules) {
      if (rule is! Map || rule['urlFilter'] is! String || (rule['urlFilter'] as String).length > 500) {
        throw const FormatException('잘못된 광고 차단 규칙');
      }
      RegExp(rule['urlFilter'] as String);
    }
    if (plugin.cloud && !['oauth', 'bearer', 's3', 'script'].contains(plugin.authType)) {
      throw const FormatException('지원하지 않는 클라우드 인증 방식');
    }
    final fields = meta['settings'] ?? [];
    if (fields is! List || fields.length > 100) throw const FormatException('잘못된 확장앱 설정 선언');
    final keys = <String>{};
    for (final field in fields) {
      if (field is! Map ||
          field['key'] is! String ||
          !RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,63}$').hasMatch(field['key']) ||
          !keys.add(field['key']) ||
          field['label'] is! String ||
          !['text', 'password', 'boolean', 'select', 'url'].contains(field['type'])) {
        throw const FormatException('잘못된 확장앱 설정 항목');
      }
      if (field['type'] == 'select' &&
          (field['options'] is! List ||
              (field['options'] as List).isEmpty ||
              (field['options'] as List).length > 50 ||
              (field['options'] as List).any((v) => v is! String))) {
        throw const FormatException('잘못된 확장앱 선택 항목');
      }
      if (field.containsKey('default') &&
          (field['type'] == 'password' ||
              (field['type'] == 'boolean' ? field['default'] is! bool : field['default'] is! String))) {
        throw const FormatException('잘못된 확장앱 설정 기본값');
      }
      if (field['required'] != null && field['required'] is! bool ||
          field['description'] != null && field['description'] is! String ||
          field['platforms'] != null &&
              (field['platforms'] is! List ||
                  (field['platforms'] as List).any(
                    (p) => !['android', 'ios', 'windows', 'linux', 'macos'].contains(p),
                  )) ||
          field['type'] == 'select' &&
              field.containsKey('default') &&
              !(field['options'] as List).contains(field['default'])) {
        throw const FormatException('잘못된 확장앱 설정 속성');
      }
    }
    for (final name in ['networkSettings', 'authSettings']) {
      final references = meta[name] ?? [];
      if (references is! List ||
          references.any(
            (key) => !plugin.settings.any(
              (f) =>
                  f['key'] == key &&
                  f['type'] == 'url' &&
                  (name != 'authSettings' || (meta['networkSettings'] as List? ?? []).contains(key)),
            ),
          )) {
        throw const FormatException('사용자 지정 서버는 URL 설정을 참조해야 합니다');
      }
    }
    for (final section in [plugin.oauth, (meta['auth'] as Map? ?? {}), (meta['setup'] as Map? ?? {})]) {
      if (section['consoleUrl'] != null) repositoryUri(section['consoleUrl'] as String);
      if (section['redirectUris'] != null &&
          (section['redirectUris'] is! List || (section['redirectUris'] as List).any((v) => v is! String))) {
        throw const FormatException('잘못된 복귀 주소 안내');
      }
    }
    if (plugin.cloud && plugin.authType != 'oauth' && ![2, 3, 4, 5].contains(meta['api'])) {
      throw const FormatException('이 인증 방식에는 확장앱 API 2 이상이 필요합니다');
    }
    if (meta['canUpload'] == true && plugin.authType != 'oauth') {
      throw const FormatException('현재 업로드 전송은 OAuth 리소스 확장앱만 지원합니다');
    }
    if (plugin.cloud && plugin.authType == 'oauth') {
      if (plugin.oauth.containsKey('clientIdSource') && plugin.oauth['clientIdSource'] != 'app.google') {
        throw const FormatException('지원하지 않는 OAuth clientIdSource');
      }
      for (final key in ['authEndpoint', 'tokenEndpoint']) {
        repositoryUri('${plugin.oauth[key]}');
      }
      final extra = plugin.oauth['extraAuthParams'];
      if (extra != null && (extra is! Map || extra.entries.any((e) => e.key is! String || e.value is! String))) {
        throw const FormatException('OAuth extraAuthParams는 문자열 옵션만 허용합니다');
      }
      final native = plugin.oauth['nativeAndroid'];
      if (native != null &&
          (native != 'google' ||
              plugin.oauth['authEndpoint'] != 'https://accounts.google.com/o/oauth2/v2/auth' ||
              plugin.oauth['tokenEndpoint'] != 'https://oauth2.googleapis.com/token')) {
        throw const FormatException('네이티브 Google 인증은 공식 Google OAuth 서버만 지원합니다');
      }
      if (native == 'google' && extra is Map) {
        for (final key in ['trigger_onepick', 'allow_multiple', 'allow_folder_selection', 'include_granted_scopes']) {
          if (extra.containsKey(key) && !['true', 'false'].contains(extra[key])) {
            throw const FormatException('Google 인증 선택 옵션은 true/false여야 합니다');
          }
        }
      }
      if (native == 'google' &&
          extra is Map &&
          extra.keys.any(
            (key) => !const {
              'access_type',
              'prompt',
              'include_granted_scopes',
              'trigger_onepick',
              'allow_multiple',
              'mimetypes',
              'file_ids',
              'allow_folder_selection',
            }.contains(key),
          )) {
        throw const FormatException('지원하지 않는 Android Google 인증 옵션');
      }
      if (plugin.oauth['scopes'] is! List || (plugin.oauth['scopes'] as List).any((v) => v is! String)) {
        throw const FormatException('OAuth scopes 형식 오류');
      }
    }
    return plugin;
  }

  static bool matchesHost(String host, Iterable<String> domains) => domains.any((domain) {
    domain = domain.toLowerCase();
    host = host.toLowerCase();
    return host.isNotEmpty &&
        (domain == '*' || (domain.startsWith('*.') ? host.endsWith(domain.substring(1)) : host == domain));
  });
  bool matches(String url) => matchesHost(Uri.tryParse(url)?.host ?? '', sites);
  bool allows(String url, {bool auth = false}) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        uri.userInfo.isEmpty &&
        (uri.scheme == 'https' || (uri.scheme == 'http' && ['localhost', '127.0.0.1'].contains(uri.host))) &&
        matchesHost(uri.host, auth ? authHosts : hosts);
  }
}

Uri repositoryUri(String value) {
  final uri = Uri.parse(value.trim());
  if (uri.userInfo.isNotEmpty ||
      uri.host.isEmpty ||
      (uri.scheme != 'https' && !(uri.scheme == 'http' && ['localhost', '127.0.0.1'].contains(uri.host)))) {
    throw const FormatException('HTTPS 저장소 URL을 입력하세요');
  }
  return uri;
}
