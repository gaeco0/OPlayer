import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'browser_environment.dart';

/// Uses the browser's HTTP/TLS stack when a CDN rejects the native HTTP client.
class BrowserDownloadTransport {
  BrowserDownloadTransport(this.pageUrl);
  final String pageUrl;
  HeadlessInAppWebView? _browser;
  InAppWebViewController? _controller;
  Future<void>? _ready;
  bool _closed = false;

  Future<void> _start() async {
    if (_closed) throw StateError('브라우저 다운로드 연결이 종료됐습니다');
    final loaded = Completer<void>();
    _browser = HeadlessInAppWebView(
      webViewEnvironment: await browserEnvironment(),
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

  int _nextRequest = 0;
  Future<BrowserFetchResponse> open(Uri uri, Map<String, String> headers, {String method = 'GET'}) async {
    await (_ready ??= _start());
    if (_closed) throw StateError('브라우저 연결이 종료됐습니다');
    final id = '${_nextRequest++}';
    final result = await _controller!
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
      try {
        const response = await fetch(url,{method,headers:allowed,credentials,signal:abort.signal});
        window.__oplayerStreams = window.__oplayerStreams || {};
        if (response.body && method !== 'HEAD') window.__oplayerStreams[id] = {reader:response.body.getReader(),abort};
        return {status:response.status,url:response.url,headers:Object.fromEntries(response.headers.entries())};
      } catch(error) { return {error:String(error)}; }
      finally { clearTimeout(timer); }
    ''',
        )
        .timeout(const Duration(seconds: 40));
    final value = result?.value;
    if (result?.error != null || value is! Map || value['error'] != null) {
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
        final result = await _controller!
            .callAsyncJavaScript(
              arguments: {'id': id},
              functionBody: r'''
          const stream = (window.__oplayerStreams || {})[id];
          if (!stream) return {done:true};
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
      if (!_closed) {
        try {
          await _controller?.callAsyncJavaScript(
            arguments: {'id': id},
            functionBody: r'''
            const stream = (window.__oplayerStreams || {})[id];
            if (stream) { delete window.__oplayerStreams[id]; stream.abort.abort(); await stream.reader.cancel().catch(()=>{}); }
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
    _closed = true;
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
