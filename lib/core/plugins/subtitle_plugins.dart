import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../network/network_service.dart';
import 'plugin.dart';
import 'plugin_http.dart';
import 'plugin_runtime.dart';
import 'plugin_store.dart';
import 'plugin_values.dart';

String subtitleSearchTitle(String title) {
  final uri = Uri.tryParse(title);
  if (uri != null && ['http', 'https'].contains(uri.scheme)) {
    title = uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? '';
  }
  return title
      .replaceAll('\\', '/')
      .split('/')
      .last
      .replaceFirst(RegExp(r'\.(mp4|mkv|avi|mov|webm|m4v|ts|m2ts)$', caseSensitive: false), '')
      .replaceAll(RegExp(r'[._]+'), ' ')
      .trim();
}

class SubtitleResults {
  SubtitleResults(this.items, this.page, this.totalPages);
  final List<Map<String, dynamic>> items;
  final int page;
  final int totalPages;
}

/// Providers own search, login and download URL resolution. Only declared hosts
/// can be contacted; credentials are never attached to a video request.
class SubtitlePlugins {
  SubtitlePlugins(this.store, {http.Client Function()? clientFactory})
    : _clientFactory = clientFactory ?? (() => IOClient(NetworkService.instance.createHttpClient(browser: true)));
  final PluginStore store;
  final http.Client Function() _clientFactory;
  static const _maxBytes = 8 * 1024 * 1024;
  Iterable<OPlugin> get providers => store.enabled.where((p) => p.subtitle);

  Future<Object?> _call(OPlugin plugin, String method, Map<String, dynamic> input) async {
    store.require(plugin.id);
    final config = store.publicSettings(plugin);
    final credentials = await store.credentials(plugin.id);
    return callPlugin(
      plugin,
      method,
      input,
      config: config,
      credentials: credentials,
      allowsRequest: (url) => plugin.allowsConfigured(url, config),
      request: (url, options) async {
        store.require(plugin.id);
        if (usesPluginSecret(options) && !plugin.allowsConfigured(url, config, auth: true)) {
          throw StateError('허용되지 않은 자막 인증 도메인');
        }
        final response = await _send(
          pluginHttpRequest(options['method'] as String? ?? 'GET', url, options, credentials),
        );
        return decodePluginResponse(response, options['response'] as String? ?? 'json', url);
      },
    );
  }

  Future<http.Response> _send(http.Request request) async {
    final client = _clientFactory();
    try {
      return await (() async {
        final response = await client.send(request).timeout(const Duration(seconds: 20));
        final bytes = <int>[];
        await for (final chunk in response.stream.timeout(const Duration(seconds: 20))) {
          bytes.addAll(chunk);
          if (bytes.length > _maxBytes) throw StateError('자막 응답은 8MB 이하여야 합니다');
        }
        return http.Response.bytes(bytes, response.statusCode, headers: response.headers);
      })().timeout(const Duration(seconds: 30));
    } finally {
      client.close();
    }
  }

  Future<SubtitleResults> search(OPlugin plugin, String query, String language, {int page = 1}) async {
    if (query.trim().isEmpty || query.length > 512) throw const FormatException('검색할 영상 제목을 입력해 주세요');
    if (!RegExp(r'^[a-z]{2,3}(?:-[a-z]{2,4})?$').hasMatch(language)) throw const FormatException('언어 코드를 확인해 주세요');
    final value = await _call(plugin, 'searchSubtitles', {'query': query.trim(), 'language': language, 'page': page});
    if (value is! Map || value['items'] is! List || (value['items'] as List).length > 100) {
      throw StateError('자막 검색 응답 형식이 잘못됐습니다');
    }
    final items = (value['items'] as List).map((item) {
      if (item is! Map ||
          item['id'] is! String ||
          item['title'] is! String ||
          (item['id'] as String).length > 200 ||
          (item['title'] as String).length > 512) {
        throw StateError('자막 검색 항목 형식이 잘못됐습니다');
      }
      return item.cast<String, dynamic>();
    }).toList();
    return SubtitleResults(items, page, ((value['totalPages'] as num?)?.toInt() ?? page).clamp(page, 1000));
  }

  /// The caller owns the temporary file and deletes it when playback ends.
  Future<File> download(OPlugin plugin, Map<String, dynamic> item, Directory directory) async {
    final value = await _call(plugin, 'downloadSubtitle', {'item': item});
    if (value is! Map) throw StateError('자막 다운로드 응답 형식이 잘못됐습니다');
    final format = '${value['format'] ?? 'srt'}'.toLowerCase();
    if (!['srt', 'smi', 'ass', 'ssa', 'vtt', 'lrc', 'sub'].contains(format)) throw StateError('지원하지 않는 자막 형식');
    List<int> bytes;
    if (value['content'] is String) {
      bytes = utf8.encode(value['content'] as String);
    } else {
      var url = '${value['url'] ?? ''}';
      final config = store.publicSettings(plugin);
      final options = {'headers': value['headers'] ?? <String, String>{}};
      final credentials = await store.credentials(plugin.id);
      http.Response? response;
      for (var redirects = 0; redirects <= 5; redirects++) {
        store.require(plugin.id);
        if (!plugin.allowsConfigured(url, config) ||
            (usesPluginSecret(options) && !plugin.allowsConfigured(url, config, auth: true))) {
          throw StateError('허용되지 않은 자막 다운로드 도메인');
        }
        response = await _send(pluginHttpRequest('GET', url, options, credentials));
        if (![301, 302, 303, 307, 308].contains(response.statusCode)) break;
        final location = response.headers['location'];
        if (location == null || redirects == 5) throw StateError('자막 다운로드 리디렉션 오류');
        final next = Uri.parse(url).resolve(location);
        // Never forward bearer tokens, cookies, or any headers across origins.
        if (next.origin != Uri.parse(url).origin) options['headers'] = <String, String>{};
        url = next.toString();
      }
      if (response == null || response.statusCode != 200) throw StateError('자막 다운로드 실패 (HTTP ${response?.statusCode})');
      if ((response.headers['content-type'] ?? '').contains('text/html')) throw StateError('자막 대신 웹페이지를 받았습니다');
      bytes = response.bodyBytes;
    }
    if (bytes.isEmpty || bytes.length > _maxBytes) throw StateError('빈 자막이거나 자막 파일이 너무 큽니다');
    if (bytes.length >= 2 && bytes[0] == 0x50 && bytes[1] == 0x4b) throw StateError('압축된 자막 묶음은 지원하지 않습니다');
    if (utf8
        .decode(bytes.take(256).toList(), allowMalformed: true)
        .trimLeft()
        .toLowerCase()
        .startsWith('<!doctype html')) {
      throw StateError('자막 대신 웹페이지를 받았습니다');
    }
    await directory.create(recursive: true);
    final file = File('${directory.path}/${DateTime.now().microsecondsSinceEpoch}.$format');
    try {
      await file.writeAsBytes(bytes, flush: true);
    } catch (_) {
      await file.delete().catchError((Object _) => file);
      rethrow;
    }
    return file;
  }
}
