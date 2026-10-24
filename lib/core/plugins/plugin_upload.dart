import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

/// Standard HTTP Content-Range resumable transport. JS prepares the session and
/// interprets completion metadata; file bytes and account tokens stay native.
Future<Object?> uploadPluginFile(
  File file,
  Uri url, {
  required http.Client client,
  required Future<Map<String, String>> Function(bool refresh) authHeaders,
  required void Function() check,
  void Function(int sent)? onProgress,
  Future<void>? cancelled,
}) async {
  final int size;
  try {
    size = await file.length();
  } catch (_) {
    client.close();
    rethrow;
  }
  const chunkSize = 8 * 1024 * 1024; // Multiple of the protocol's 256 KiB unit.
  var offset = 0, failures = 0;
  var finished = false;
  cancelled?.then((_) {
    if (!finished) client.close();
  });
  Future<http.Response> send({required bool probe}) async {
    for (var retry = 0; ; retry++) {
      check();
      final end = (offset + chunkSize).clamp(0, size);
      final request = http.AbortableRequest('PUT', url, abortTrigger: cancelled)
        ..followRedirects = false
        ..headers.addAll(await authHeaders(retry > 0))
        ..headers['Content-Type'] = 'application/octet-stream'
        ..headers['Content-Range'] = probe || size == 0 ? 'bytes */$size' : 'bytes $offset-${end - 1}/$size';
      if (!probe && size > 0) {
        final bytes = await file.openRead(offset, end).fold(BytesBuilder(copy: false), (b, d) => b..add(d));
        check();
        request.bodyBytes = bytes.takeBytes();
        if (request.bodyBytes.length != end - offset) throw StateError('업로드 중 원본 파일이 변경되었습니다');
      }
      final streamed = await client.send(request).timeout(const Duration(seconds: 120));
      final body = BytesBuilder(copy: false);
      await for (final bytes in streamed.stream.timeout(const Duration(seconds: 60))) {
        body.add(bytes);
        if (body.length > 1024 * 1024) throw StateError('업로드 응답 크기 제한 초과');
      }
      final response = http.Response.bytes(body.takeBytes(), streamed.statusCode, headers: streamed.headers);
      if (response.statusCode == 401 && retry == 0) continue;
      return response;
    }
  }

  Object? complete(http.Response response) {
    check();
    onProgress?.call(size);
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  int position(http.Response response, int maximum) {
    final range = response.headers['range'];
    final match = RegExp(r'^bytes=0-(\d+)$').firstMatch(range ?? '');
    if (range != null && match == null) throw StateError('잘못된 업로드 확인 범위');
    final next = match == null ? 0 : int.parse(match[1]!) + 1;
    if (next < offset || next > maximum || next > size) throw StateError('잘못된 업로드 확인 위치');
    return next;
  }

  void status(http.Response response) {
    if (response.statusCode == 403) throw StateError('저장소 쓰기 권한이 필요합니다. 확장앱 업데이트 후 계정을 다시 연결하세요');
    if (response.statusCode >= 500) throw HttpException('업로드 서버 일시 오류 (${response.statusCode})');
    throw StateError('업로드 실패 (HTTP ${response.statusCode}). 계정 권한 또는 업로드 세션을 확인하세요');
  }

  try {
    onProgress?.call(0);
    while (true) {
      check();
      final end = (offset + chunkSize).clamp(0, size);
      try {
        final response = await send(probe: offset == size);
        if ([200, 201].contains(response.statusCode)) {
          if (end != size) throw StateError('파일을 모두 보내기 전에 업로드가 완료되었습니다');
          return complete(response);
        }
        if (response.statusCode != 308) status(response);
        final next = position(response, end);
        if (next == offset) throw const HttpException('업로드가 진행되지 않았습니다');
        offset = next;
        onProgress?.call(offset);
      } catch (error) {
        if (error is! IOException && error is! TimeoutException && error is! http.ClientException) rethrow;
        check();
        if (++failures > 3) rethrow;
        // Query the acknowledged offset before resending after a lost response.
        final response = await send(probe: true);
        if ([200, 201].contains(response.statusCode)) {
          if (end != size) throw StateError('잘못된 업로드 완료 응답');
          return complete(response);
        }
        if (response.statusCode != 308) status(response);
        offset = position(response, end);
        onProgress?.call(offset);
      }
    }
  } finally {
    finished = true;
    client.close();
  }
}
