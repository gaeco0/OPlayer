import 'dart:convert';

/// A single JS file with a JSON metadata header, followed by `globalThis.plugin`.
class OPlugin {
  OPlugin._(this.source, this.manifest);
  final String source;
  final Map<String, dynamic> manifest;
  String get id => manifest['id'] as String;
  String get name => manifest['name'] as String;
  String get version => manifest['version'] as String;
  bool get cloud => manifest['kind'] == 'cloud';
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
    if (![1, 2].contains(meta['api']) ||
        !RegExp(r'^[a-z][a-z0-9._-]{1,79}$').hasMatch('${meta['id']}') ||
        meta['name'] is! String ||
        '${meta['name']}'.isEmpty ||
        meta['version'] is! String ||
        !['site', 'cloud'].contains(meta['kind'])) {
      throw const FormatException('지원하지 않는 확장앱 형식입니다');
    }
    for (final key in ['hosts', 'authHosts', 'sites']) {
      final values = meta[key] ?? [];
      if (values is! List ||
          values.length > 100 ||
          values.any((v) => v is! String || !RegExp(r'^(\*\.)?[a-zA-Z0-9][a-zA-Z0-9.-]*$').hasMatch(v))) {
        throw FormatException('잘못된 도메인 권한: $key');
      }
    }
    meta['hosts'] ??= <String>[];
    final plugin = OPlugin._(source, meta);
    if (meta['platforms'] != null &&
        (meta['platforms'] is! List ||
            (meta['platforms'] as List).any((p) => !['android', 'ios', 'windows', 'linux', 'macos'].contains(p)))) {
      throw const FormatException('잘못된 지원 플랫폼 선언');
    }
    if (plugin.authHosts.any((h) => !plugin.hosts.contains(h))) {
      throw const FormatException('인증 도메인은 네트워크 권한에도 있어야 합니다');
    }
    if (!plugin.cloud && plugin.sites.isEmpty) throw const FormatException('사이트 확장앱에는 sites 권한이 필요합니다');
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
    if (plugin.cloud && plugin.authType != 'oauth' && meta['api'] != 2) {
      throw const FormatException('이 인증 방식에는 확장앱 API 2가 필요합니다');
    }
    if (plugin.cloud && plugin.authType == 'oauth') {
      for (final key in ['authEndpoint', 'tokenEndpoint']) {
        repositoryUri('${plugin.oauth[key]}');
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
    return domain.startsWith('*.') ? host.endsWith(domain.substring(1)) : host == domain;
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
