import 'dart:convert';
import 'dart:io';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import '../../core/network/network_service.dart';
import '../../core/plugins/plugin.dart';
import '../../core/plugins/plugin_runtime.dart';
import '../../core/plugins/plugin_store.dart';
import '../../core/plugins/plugin_values.dart';
import '../../core/plugins/plugin_http.dart';
import '../../core/plugins/plugin_parser.dart';
import 'request_headers.dart';

String sitePluginScript(OPlugin p) =>
    '''(() => {
  const domains = ${jsonEncode(p.sites)};
  const host = location.hostname.toLowerCase();
  if (!domains.some(d => d.startsWith('*.') ? host.endsWith(d.slice(1)) : host === d)) return;
  const marker = ${jsonEncode('__oplayer_${p.id}')};
  if (window[marker]) return; window[marker] = true;
  try {
    const config = Object.freeze(${jsonEncode(PluginStore.instance.publicSettings(p))});
    $pluginParserFactory
    $pluginPageParser
    const sandbox = {OPlayer:Object.freeze({config,parse:createOPlayerPageParser()})};
    (function(globalThis,OPlayer) { ${p.source}\n }).call(sandbox, sandbox, sandbox.OPlayer);
    const api = Object.freeze({
      config,
      reportMedia: (url, hint = '') => window.flutter_inappwebview?.callHandler('oplayerMedia',
        new URL(url, location.href).href, document.title, hint, 0, location.href)
    });
    if (typeof sandbox.plugin?.page === 'function') Promise.resolve(sandbox.plugin.page(api)).catch(e => console.warn('OPlayer extension error', e));
  } catch(e) { console.warn('OPlayer extension error', e); }
})();''';

List<ContentBlocker> pluginContentBlockers() => [
  if (!Platform.isAndroid && !Platform.isWindows)
    for (final p in PluginStore.instance.enabled.where((p) => p.site))
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
    .where((p) => p.site && p.matches(pageUrl))
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
  for (final p in PluginStore.instance.enabled.where((p) => p.site).toList()) {
    if (!p.matches('${media['pageUrl']}') && !p.matches('${media['referer'] ?? ''}')) continue;
    final value = await callPlugin(
      p,
      'resolveDownload',
      current,
      config: PluginStore.instance.publicSettings(p),
      credentials: await PluginStore.instance.credentials(p.id),
      allowsRequest: (url) => p.allowsConfigured(url, PluginStore.instance.publicSettings(p)),
      request: (url, options) async {
        final client = IOClient(NetworkService.instance.createHttpClient(browser: true));
        try {
          final method = options['method'] as String? ?? 'GET';
          if (usesPluginSecret(options) &&
              !p.allowsConfigured(url, PluginStore.instance.publicSettings(p), auth: true)) {
            throw StateError('허용되지 않은 인증 도메인');
          }
          final request = pluginHttpRequest(method, url, options, await PluginStore.instance.credentials(p.id));
          final replay = BrowserRequestHeaders.replay(request.headers);
          request.headers
            ..clear()
            ..addAll(replay);
          final response = await client.send(request).timeout(const Duration(seconds: 20));
          final bytes = <int>[];
          await for (final chunk in response.stream.timeout(const Duration(seconds: 20))) {
            bytes.addAll(chunk);
            if (bytes.length > 8 * 1024 * 1024) throw StateError('확장앱 응답이 너무 큽니다');
          }
          return decodePluginResponse(
            http.Response.bytes(bytes, response.statusCode, headers: response.headers),
            options['response'] as String? ?? 'json',
            url,
          );
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
