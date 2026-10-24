import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../sources/cloud/oauth.dart';

const googleSyncScope = 'https://www.googleapis.com/auth/drive.appdata';

class GoogleAppData {
  GoogleAppData(this.tokens, this.client);
  final TokenHolder tokens;
  final http.Client client;
  static const maxBytes = 4 * 1024 * 1024;

  Future<http.Response> _request(
    String method,
    String path, {
    Map<String, String> query = const {},
    String? body,
    String type = 'application/json',
    bool refresh = false,
  }) async {
    final request = http.Request(method, Uri.https('www.googleapis.com', path, query))
      ..followRedirects = false
      ..headers.addAll(await tokens.authHeader(forceRefresh: refresh));
    if (body != null) {
      request.headers['Content-Type'] = type;
      request.bodyBytes = utf8.encode(body);
      if (request.bodyBytes.length > maxBytes) throw StateError('동기화 데이터는 4MiB까지 지원합니다');
    }
    final response = await client.send(request).timeout(const Duration(seconds: 30));
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(const Duration(seconds: 30))) {
      if (bytes.length + chunk.length > maxBytes) throw StateError('동기화 응답이 너무 큽니다');
      bytes.add(chunk);
    }
    final result = http.Response.bytes(bytes.takeBytes(), response.statusCode, headers: response.headers);
    if (result.statusCode == 401 && !refresh) {
      return _request(method, path, query: query, body: body, type: type, refresh: true);
    }
    if (result.statusCode < 200 || result.statusCode >= 300) {
      throw StateError('Google 동기화 요청 실패 (HTTP ${result.statusCode})');
    }
    return result;
  }

  Future<({String id, String email})> account() async {
    final response = await _request('GET', '/drive/v3/about', query: {'fields': 'user(permissionId,emailAddress)'});
    final user = (jsonDecode(utf8.decode(response.bodyBytes)) as Map)['user'] as Map;
    final id = user['permissionId'] as String?;
    final email = user['emailAddress'] as String?;
    if (id == null || id.isEmpty || email == null || email.isEmpty) throw StateError('Google 계정을 확인하지 못했습니다');
    return (id: id, email: email);
  }

  Future<List<({String id, String name})>> files() async {
    final files = <({String id, String name})>[];
    String? page;
    final seen = <String>{};
    do {
      final response = await _request(
        'GET',
        '/drive/v3/files',
        query: {
          'spaces': 'appDataFolder',
          'pageSize': '100',
          'q': "appProperties has { key='oplayerSync' and value='1' }",
          'fields': 'nextPageToken,files(id,name)',
          if (page != null) 'pageToken': page,
        },
      );
      final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
      for (final file in data['files'] as List) {
        files.add((id: (file as Map)['id'] as String, name: file['name'] as String));
      }
      page = data['nextPageToken'] as String?;
      if (page != null && !seen.add(page)) throw StateError('Google 목록 페이지가 반복됩니다');
    } while (page != null);
    return files;
  }

  Future<Map<String, dynamic>> read(String id) async {
    final response = await _request('GET', '/drive/v3/files/${Uri.encodeComponent(id)}', query: {'alt': 'media'});
    return (jsonDecode(utf8.decode(response.bodyBytes)) as Map).cast<String, dynamic>();
  }

  String fileName(String device) => 'oplayer-sync-v1-$device.json';

  Future<void> write(String device, Map<String, dynamic> document, {String? id}) async {
    final content = jsonEncode(document);
    if (id != null) {
      await _request(
        'PATCH',
        '/upload/drive/v3/files/${Uri.encodeComponent(id)}',
        query: {'uploadType': 'media'},
        body: content,
      );
      return;
    }
    final boundary = 'oplayer-${Random.secure().nextInt(1 << 32)}-${DateTime.now().microsecondsSinceEpoch}';
    final metadata = jsonEncode({
      'name': fileName(device),
      'parents': ['appDataFolder'],
      'appProperties': {'oplayerSync': '1', 'device': device},
    });
    await _request(
      'POST',
      '/upload/drive/v3/files',
      query: {'uploadType': 'multipart'},
      type: 'multipart/related; boundary=$boundary',
      body:
          '--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$metadata\r\n'
          '--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$content\r\n--$boundary--\r\n',
    );
  }

  void close() {
    client.close();
    tokens.close();
  }
}
