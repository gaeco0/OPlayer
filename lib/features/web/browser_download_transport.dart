import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'browser_environment.dart';
import 'browser_session.dart';
import '../../core/network/network_service.dart';

/// Uses OS trust first, then the original browser session for TLS/access failures.
/// Playback and downloads share this policy on every OS.
class BrowserDownloadClient extends http.BaseClient {
  BrowserDownloadClient(this.browser, {http.Client? native, this.browserOpen})
    : _nativeOverride = native,
      _native = native == null ? NetworkService.instance.createHttpClient(browser: true) : null;
  final BrowserDownloadTransport browser;
  final http.Client? _nativeOverride;
  final HttpClient? _native;
  final Future<BrowserFetchResponse> Function(Uri, Map<String, String>, String)? browserOpen;
  final _browserOrigins = <String, Object>{};
  bool _closed = false;
  Future<void>? _closing;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw http.ClientException('다운로드 연결이 종료됐습니다', request.url);
    if (!['GET', 'HEAD'].contains(request.method) || !['http', 'https'].contains(request.url.scheme)) {
      throw http.ClientException('지원하지 않는 브라우저 미디어 요청입니다', request.url);
    }
    final origin = request.url.origin;
    var nativeFailure = _browserOrigins[origin];
    if (nativeFailure == null) {
      try {
        final response = await (_nativeOverride?.send(request) ?? _sendNative(request));
        final challenge = response.statusCode == 202 && response.headers['x-amzn-waf-action'] == 'challenge';
        if (response.statusCode != 401 && response.statusCode != 403 && !challenge) return response;
        nativeFailure = HttpException('HTTP ${response.statusCode}${challenge ? ' (WAF challenge)' : ''}');
        await response.stream.listen((_) {}).cancel();
      } on TlsException catch (error) {
        // The browser must perform its own certificate validation; never bypass it.
        nativeFailure = error;
      }
      if (_closed) throw http.ClientException('다운로드 연결이 종료됐습니다', request.url);
      _browserOrigins[origin] = nativeFailure;
    }
    Never failed(Object error, StackTrace stack) {
      if (identical(_browserOrigins[origin], nativeFailure)) _browserOrigins.remove(origin);
      Error.throwWithStackTrace(BrowserFallbackException(nativeFailure!, error), stack);
    }

    final BrowserFetchResponse response;
    try {
      response = browserOpen == null
          ? await browser.open(request.url, request.headers, method: request.method)
          : await browserOpen!(request.url, request.headers, request.method);
    } catch (error, stack) {
      failed(error, stack);
    }
    if (_closed) {
      await response.body.listen((_) {}).cancel();
      throw http.ClientException('다운로드 연결이 종료됐습니다', request.url);
    }
    final headers = {...response.headers};
    // Browser fetch returns decompressed bytes, so encoded lengths cannot be reused.
    if (headers.containsKey('content-encoding')) {
      headers.remove('content-encoding');
      headers.remove('content-length');
    }
    Stream<List<int>> body() async* {
      try {
        await for (final chunk in response.body) {
          yield chunk;
        }
      } catch (error, stack) {
        failed(error, stack);
      }
    }

    return http.StreamedResponse(
      body(),
      response.status,
      headers: headers,
      contentLength: int.tryParse(headers['content-length'] ?? ''),
      request: http.Request(request.method, response.uri),
    );
  }

  Future<void> closeBrowser() => _closing ??= browser.close();

  Future<http.StreamedResponse> _sendNative(http.BaseRequest request) async {
    final upstream = await _native!.openUrl(request.method, request.url).timeout(const Duration(seconds: 30));
    upstream
      ..followRedirects = request.followRedirects
      ..maxRedirects = request.maxRedirects
      ..persistentConnection = request.persistentConnection;
    request.headers.forEach(upstream.headers.set);
    final response = await request.finalize().pipe(upstream).timeout(const Duration(seconds: 30));
    var finalUri = request.url;
    for (final redirect in response.redirects) {
      finalUri = finalUri.resolveUri(redirect.location);
    }
    final headers = <String, String>{};
    response.headers.forEach((name, values) => headers[name.toLowerCase()] = values.join(', '));
    if (response.compressionState == HttpClientResponseCompressionState.decompressed) {
      headers.remove('content-encoding');
      headers.remove('content-length');
    }
    return http.StreamedResponse(
      response,
      response.statusCode,
      headers: headers,
      contentLength: int.tryParse(headers['content-length'] ?? ''),
      request: http.Request(request.method, finalUri),
    );
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _native?.close(force: true);
    _nativeOverride?.close();
    unawaited(closeBrowser().catchError((Object _) {}));
  }
}

/// Keep both failures: a WebView fetch error must not hide the native TLS/status error.
class BrowserFallbackException implements Exception {
  BrowserFallbackException(this.nativeFailure, this.browserFailure);
  final Object nativeFailure;
  final Object browserFailure;

  @override
  String toString() => '기본 HTTP 요청 실패: $nativeFailure → WebView 폴백 실패: $browserFailure';
}

/// Reuses the original browser; restores a browser when no live session remains.
class BrowserDownloadTransport {
  BrowserDownloadTransport(this.pageUrl) : _session = BrowserSession.find(pageUrl) {
    _session?.retain();
  }
  final BrowserSession? _session;
  final _active = <String>{};
  static int _nextRequest = 0;
  Future<InAppWebViewController> get _web async => _session == null ? _controller! : await _session.controller;
  final String pageUrl;
  HeadlessInAppWebView? _browser;
  InAppWebViewController? _controller;
  Future<void>? _ready;
  bool _closed = false;

  Future<void> _start() async {
    if (_closed) throw StateError('브라우저 다운로드 연결이 종료됐습니다');
    if (_session != null) return;
    final environment = await browserEnvironment();
    if (_closed) throw StateError('브라우저 다운로드 연결이 종료됐습니다');
    final loaded = Completer<void>();
    _browser = HeadlessInAppWebView(
      webViewEnvironment: environment,
      initialUrlRequest: URLRequest(url: WebUri(pageUrl)),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        mediaPlaybackRequiresUserGesture: true,
        isInspectable: false,
        // On Android this also keeps the WebView visible to its renderer while
        // the Activity is backgrounded, so fetch callbacks keep running.
        allowBackgroundAudioPlaying: true,
      ),
      onWebViewCreated: (controller) => _controller = controller,
      onLoadStop: (_, __) {
        if (!loaded.isCompleted) loaded.complete();
      },
      onReceivedError: (_, request, error) {
        if (request.isForMainFrame == true && !loaded.isCompleted) {
          loaded.completeError(StateError('브라우저 연결 실패: ${error.description}'));
        }
      },
    );
    await _browser!.run();
    await loaded.future.timeout(const Duration(seconds: 30));
    if (_closed) throw StateError('브라우저 다운로드 연결이 종료됐습니다');
  }

  Future<BrowserFetchResponse> open(Uri uri, Map<String, String> headers, {String method = 'GET'}) async {
    await (_ready ??= _start());
    if (_closed) throw StateError('브라우저 연결이 종료됐습니다');
    final id = '${_nextRequest++}';
    _active.add(id);
    final result = await (await _web)
        .callAsyncJavaScript(
          arguments: {'url': uri.toString(), 'headers': headers, 'id': id, 'method': method},
          functionBody: r'''
      const allowed = {};
      const forbidden = /^(?:host|origin|referer|cookie|user-agent|accept-encoding|content-length|connection|sec-.*)$/i;
      for (const [name,value] of Object.entries(headers)) {
        if (!forbidden.test(name)) allowed[name] = value;
      }
      const credentials = Object.keys(headers).some(k=>k.toLowerCase()==='cookie') ? 'include' : 'same-origin';
      const abort = new AbortController();
      const timer = setTimeout(()=>abort.abort(), 30000);
      window.__oplayerStreams = window.__oplayerStreams || {};
      window.__oplayerStreams[id] = {reader:null,abort};
      try {
        const response = await fetch(url,{method,headers:allowed,credentials,signal:abort.signal});
        if (response.body && method !== 'HEAD') window.__oplayerStreams[id] = {reader:response.body.getReader(),abort};
        else delete window.__oplayerStreams[id];
        return {status:response.status,url:response.url,headers:Object.fromEntries(response.headers.entries())};
      } catch(error) { delete window.__oplayerStreams[id]; return {error:String(error)}; }
      finally { clearTimeout(timer); }
    ''',
        )
        .timeout(const Duration(seconds: 40));
    final value = result?.value;
    if (result?.error != null || value is! Map || value['error'] != null) {
      _active.remove(id);
      throw StateError('브라우저 요청 실패: ${value is Map ? value['error'] : result?.error}');
    }
    return BrowserFetchResponse(
      (value['status'] as num).toInt(),
      {for (final entry in (value['headers'] as Map).entries) '${entry.key}'.toLowerCase(): '${entry.value}'},
      Uri.parse(value['url'] as String),
      method == 'HEAD' ? const Stream.empty() : _read(id),
    );
  }

  Stream<List<int>> _read(String id) async* {
    try {
      while (!_closed) {
        final result = await (await _web)
            .callAsyncJavaScript(
              arguments: {'id': id},
              functionBody: r'''
          const stream = (window.__oplayerStreams || {})[id];
          if (!stream) return {error:'Browser media stream was lost'};
          try {
            const part = await stream.reader.read();
            if (part.done) return {done:true};
            const chunks = [];
            for (let i=0;i<part.value.length;i+=32768) chunks.push(String.fromCharCode(...part.value.subarray(i,i+32768)));
            return {body:btoa(chunks.join(''))};
          } catch(error) { return {error:String(error)}; }
        ''',
            )
            .timeout(const Duration(seconds: 40));
        final value = result?.value;
        if (result?.error != null || value is! Map || value['error'] != null) {
          throw StateError('브라우저 미디어 수신 실패');
        }
        if (value['done'] == true) return;
        yield base64Decode(value['body'] as String);
      }
      throw StateError('브라우저 연결이 종료됐습니다');
    } finally {
      _active.remove(id);
      if (!_closed) {
        try {
          await (await _web).callAsyncJavaScript(
            arguments: {'id': id},
            functionBody: r'''
            const stream = (window.__oplayerStreams || {})[id];
            if (stream) { delete window.__oplayerStreams[id]; stream.abort.abort(); await stream.reader?.cancel().catch(()=>{}); }
          ''',
          );
        } catch (_) {}
      }
    }
  }

  Future<(int, Uint8List)> get(Uri uri, Map<String, String> headers) async {
    final response = await open(uri, headers);
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.body) {
      if (response.status < 300) {
        bytes.add(chunk);
      } else {
        break;
      }
    }
    return (response.status, bytes.takeBytes());
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      if (_active.isNotEmpty && (_session != null || _controller != null)) {
        await (await _web).callAsyncJavaScript(
          arguments: {'ids': _active.toList()},
          functionBody: r"""
            for (const id of ids) {
              const stream = (window.__oplayerStreams || {})[id];
              if (stream) { delete window.__oplayerStreams[id]; stream.abort.abort(); stream.reader?.cancel().catch(()=>{}); }
            }
          """,
        );
      }
    } finally {
      _active.clear();
      await _session?.release();
    }
    final browser = _browser;
    _browser = null;
    await browser?.dispose();
  }
}

class BrowserFetchResponse {
  BrowserFetchResponse(this.status, this.headers, this.uri, this.body);
  final int status;
  final Map<String, String> headers;
  final Uri uri;
  final Stream<List<int>> body;
}
