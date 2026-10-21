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

  static OPlugin parse(String source) {
    if (utf8.encode(source).length > 1024 * 1024) throw const FormatException('확장앱 파일은 1MB 이하여야 합니다');
    final first = source.trimLeft().split('\n').first;
    if (!first.startsWith('// @oplayer ')) throw const FormatException('확장앱 메타데이터가 없습니다');
    final meta = jsonDecode(first.substring(12)) as Map<String, dynamic>;
    if (meta['api'] != 1 ||
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
    if (plugin.cloud) {
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
