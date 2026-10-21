import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import 'plugin_values.dart';

http.Request pluginHttpRequest(
  String method,
  String url,
  Map<String, dynamic> options,
  Map<String, dynamic> credentials, {
  Uri Function(Uri)? sign,
  Map<String, String> authHeaders = const {},
}) {
  if (!['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE'].contains(method)) throw StateError('지원하지 않는 요청 방식');
  final resolved = resolvePluginValue(options, credentials) as Map;
  var uri = Uri.parse(url);
  if (resolved['query'] is Map) {
    uri = uri.replace(queryParameters: {...uri.queryParameters, ...(resolved['query'] as Map).cast<String, dynamic>()});
  }
  final request = http.Request(method, sign?.call(uri) ?? uri)..followRedirects = false;
  request.headers.addAll(authHeaders);
  for (final e in (resolved['headers'] as Map? ?? {}).entries) {
    if (RegExp(
      r'^(host|connection|content-length|transfer-encoding|proxy-.*)$',
      caseSensitive: false,
    ).hasMatch('${e.key}')) {
      throw StateError('허용되지 않은 요청 헤더');
    }
    request.headers['${e.key}'] = '${e.value}';
  }
  if (resolved['bodyFields'] is Map) {
    request.bodyFields = (resolved['bodyFields'] as Map).cast<String, String>();
  } else if (resolved.containsKey('body')) {
    final body = resolved['body'];
    if (body is! String) request.headers.putIfAbsent('Content-Type', () => 'application/json');
    request.body = body is String ? body : jsonEncode(body);
  }
  return request;
}

Object? decodePluginResponse(http.Response response, String type, String url) {
  if (type == 'raw') {
    return {'status': response.statusCode, 'headers': response.headers, 'body': utf8.decode(response.bodyBytes)};
  }
  if (type == 'redirect') {
    if (![301, 302, 303, 307, 308].contains(response.statusCode) || response.headers['location'] == null) {
      throw StateError('다운로드 주소를 얻을 수 없습니다 (HTTP ${response.statusCode})');
    }
    final location = Uri.parse(url).resolve(response.headers['location']!);
    if (location.scheme != 'https' || location.host.isEmpty || location.userInfo.isNotEmpty) {
      throw StateError('잘못된 다운로드 주소');
    }
    return {'url': location.toString()};
  }
  if (response.statusCode >= 300) throw StateError('HTTP ${response.statusCode}');
  if (type == 'headers') return response.headers;
  if (type == 'text') return utf8.decode(response.bodyBytes);
  if (type == 'xml') {
    Map<String, dynamic> node(XmlElement e) => {
      'name': e.name.local,
      if (e.childElements.isEmpty) 'text': e.innerText,
      'children': e.childElements.map(node).toList(),
    };
    return node(XmlDocument.parse(utf8.decode(response.bodyBytes)).rootElement);
  }
  return jsonDecode(utf8.decode(response.bodyBytes));
}
