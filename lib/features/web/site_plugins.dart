import 'dart:convert';
import 'dart:io';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import '../../core/network/network_service.dart';
import '../../core/plugins/plugin.dart';
import '../../core/plugins/plugin_runtime.dart';
import '../../core/plugins/plugin_store.dart';
import 'request_headers.dart';

String sitePluginScript(OPlugin p) =>
    '''(() => {
  const domains = ${jsonEncode(p.sites)};
  const host = location.hostname.toLowerCase();
  if (!domains.some(d => d.startsWith('*.') ? host.endsWith(d.slice(1)) : host === d)) return;
  const marker = ${jsonEncode('__oplayer_${p.id}')};
  if (window[marker]) return; window[marker] = true;
  try {
    const sandbox = {};
    (function(globalThis) { ${p.source}\n }).call(sandbox, sandbox);
    const api = Object.freeze({
      reportMedia: (url, hint = '') => window.flutter_inappwebview?.callHandler('oplayerMedia',
        new URL(url, location.href).href, document.title, hint, 0, location.href)
    });
    if (typeof sandbox.plugin?.page === 'function') sandbox.plugin.page(api);
  } catch(e) { console.warn('OPlayer extension error', e); }
})();''';

List<ContentBlocker> pluginContentBlockers() => [
  if (!Platform.isAndroid && !Platform.isWindows)
    for (final p in PluginStore.instance.enabled.where((p) => !p.cloud))
      for (final rule in (p.manifest['blockRules'] as List? ?? []).cast<Map>())
        ContentBlocker(
          trigger: ContentBlockerTrigger(
            urlFilter: rule['urlFilter'] as String,
            ifTopUrl: [for (final site in p.sites) siteUrlPattern(site)],
          ),
          action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
        ),
];

bool blockedBySitePlugin(String pageUrl, String requestUrl) => PluginStore.instance.enabled
    .where((p) => !p.cloud && p.matches(pageUrl))
    .any(
      (p) => (p.manifest['blockRules'] as List? ?? []).cast<Map>().any(
        (r) => RegExp(r['urlFilter'] as String).hasMatch(requestUrl),
      ),
    );

String siteUrlPattern(String site) {
  final host = site.startsWith('*.') ? '([a-zA-Z0-9-]+\\.)+${RegExp.escape(site.substring(2))}' : RegExp.escape(site);
  return '^https?://$host(:[0-9]+)?/';
}

/// Resolves in the same pipeline for playback and download, preserving headers.
Future<Map<String, dynamic>> resolveSiteMedia(Map<String, dynamic> media) async {
  var current = Map<String, dynamic>.of(media);
  for (final p in PluginStore.instance.enabled.where((p) => !p.cloud).toList()) {
    if (!p.matches('${media['pageUrl']}') && !p.matches('${media['referer'] ?? ''}')) continue;
    final value = await callPlugin(
      p,
      'resolveDownload',
      current,
      request: (url, options) async {
        final client = IOClient(NetworkService.instance.createHttpClient(browser: true));
        try {
          final method = options['method'] as String? ?? 'GET';
          if (!['GET', 'POST'].contains(method)) throw StateError('지원하지 않는 요청 방식');
          final request = http.Request(method, Uri.parse(url))..followRedirects = false;
          request.headers.addAll(
            BrowserRequestHeaders.replay((options['headers'] as Map? ?? {}).cast<String, String>()),
          );
          if (options.containsKey('body')) {
            request.body = options['body'] is String ? options['body'] as String : jsonEncode(options['body']);
          }
          final response = await client.send(request).timeout(const Duration(seconds: 20));
          if (response.statusCode >= 300) throw StateError('HTTP ${response.statusCode}');
          final bytes = <int>[];
          await for (final chunk in response.stream.timeout(const Duration(seconds: 20))) {
            bytes.addAll(chunk);
            if (bytes.length > 8 * 1024 * 1024) throw StateError('확장앱 응답이 너무 큽니다');
          }
          final text = utf8.decode(bytes);
          return options['response'] == 'text' ? text : jsonDecode(text);
        } finally {
          client.close();
        }
      },
    );
    if (value == null) continue;
    if (value is! Map) throw StateError('${p.name}: 다운로드 응답 형식 오류');
    final url = Uri.tryParse('${value['url'] ?? current['url']}');
    if (url == null || !['http', 'https'].contains(url.scheme) || url.host.isEmpty || url.userInfo.isNotEmpty) {
      throw StateError('확장앱 다운로드 URL 오류');
    }
    current = {
      ...current,
      ...value.cast<String, dynamic>(),
      'headers': {...(current['headers'] as Map? ?? {}), ...(value['headers'] as Map? ?? {})},
    };
  }
  return current;
}
