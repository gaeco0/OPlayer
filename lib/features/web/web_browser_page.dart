import 'dart:async';
import 'dart:collection';

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/theme.dart';
import '../../core/settings.dart';
import '../../core/plugins/plugin_store.dart';
import 'site_plugins.dart';
import '../../core/media_utils.dart';
import '../../core/mouse_nav.dart';
import '../../core/media_item.dart';
import '../browser/home_screen.dart';
import 'download_name_dialog.dart';
import '../player/player_screen.dart';
import 'download_manager.dart';
import 'browser_interactions.dart';
import 'browser_history.dart';
import 'downloads_page.dart';
import 'hls.dart';
import 'request_headers.dart';
import 'browser_environment.dart';
import 'browser_playback_proxy.dart';

enum MediaKind { file, hls, dash }

class DetectedMedia {
  DetectedMedia({
    required this.url,
    required this.kind,
    required this.pageUrl,
    required this.pageTitle,
    this.size = 0,
    this.referer,
  });
  final String url;

  /// 실제로 요청을 보낸 문서(iframe 포함)의 주소 — Referer/Origin 기준
  final String? referer;
  final int size;
  final MediaKind kind;
  final String pageUrl;
  final String pageTitle;

  String get label => switch (kind) {
    MediaKind.hls => 'HLS 스트림 (m3u8)',
    MediaKind.dash => 'DASH 스트림 (mpd)',
    MediaKind.file => (Uri.tryParse(url)?.pathSegments.lastOrNull ?? url),
  };
}

/// 페이지 안의 동영상을 찾아내는 스크립트 (모든 프레임에 주입):
///  · <video>/<source> 의 src (blob: 제외)
///  · fetch / XMLHttpRequest 요청·응답 — 주소에 확장자가 없어도 응답 Content-Type 이나
///    본문(#EXTM3U, <MPD)으로 판별 (hls.js, video.js 등 MSE 플레이어 대응)
///  · PerformanceObserver 로 로드된 리소스
///  · MediaSource 사용 여부 → 받을 주소가 없을 때 안내용
///  · iframe 안의 플레이어는 최상위 창으로 postMessage → 최상위에서 앱으로 전달
const _snifferJs = r'''
(function(){
  if (window.__oplayerSniffer) return; window.__oplayerSniffer = true;
  var isTop = (window === window.top);
  var seen = {};
  var extRe = /\.(m3u8|mpd|mp4|webm|mkv|mov|m4v|flv)(\?|#|$)/i;
  var segRe = /\.(ts|m4s|aac|m4a|vtt|webvtt|key)(\?|#|$)/i;
  var imgRe = /\.(gif|jpe?g|png|webp|avif|svg|ico|bmp)(\?|#|$)/i;
  var PREVIEW_MAX = 1536 * 1024; // 1.5MB 미만 영상 파일은 미리보기/광고로 간주
  var mseSent = false;
  function send(u, kind, size, headers){
    if (kind === 'mse') { if (mseSent) return; mseSent = true; }
    var msg = {__oplayer: 1, url: u, kind: kind, size: size || 0, title: document.title || '', ref: location.href, headers: headers || {}};
    if (isTop) {
      try { window.flutter_inappwebview.callHandler('oplayerMedia', msg.url, msg.title, msg.kind, msg.size, msg.ref, msg.headers); } catch(e) {}
    } else {
      try { window.top.postMessage(msg, '*'); } catch(e) {}
    }
  }
  if (isTop) {
    window.addEventListener('message', function(e){
      var d = e.data;
      if (d && d.__oplayer === 1 && typeof d.url === 'string') {
        if (d.kind === 'hls-playlist') {
          try { window.flutter_inappwebview.callHandler('oplayerHlsPlaylist', d.url, d.text); } catch(err) {}
          return;
        }
        if (d.kind === 'hls-key') {
          try { window.flutter_inappwebview.callHandler('oplayerHlsKey', d.url, d.key); } catch(err) {}
          return;
        }
        if (d.kind === 'hls-prepare-error') {
          try { window.flutter_inappwebview.callHandler('oplayerHlsPrepareError', d.url, d.error); } catch(err) {}
          return;
        }
        try { window.flutter_inappwebview.callHandler('oplayerMedia', d.url, d.title || document.title, d.kind || '', d.size || 0, d.ref || '', d.headers || {}); } catch(err) {}
      }
    });
  }
  function reportPlaylist(u, text){
    if (typeof text !== 'string' || text.length > 4 * 1024 * 1024 || kindFromText(text) !== 'hls') return;
    if (isTop) {
      try { window.flutter_inappwebview.callHandler('oplayerHlsPlaylist', u, text); } catch(e) {}
    } else {
      try { window.top.postMessage({__oplayer: 1, kind: 'hls-playlist', url: u, text: text}, '*'); } catch(e) {}
    }
  }
  // Observe identity AES-128 keys after the site's own HLS loader has decoded them.
  // EME/DRM keys are excluded; no site bytecode or key algorithm is copied here.
  var keySeen = {};
  var hlsPlayers = [];
  function keyLoaderFor(player){
    return player.keyLoader || (player.streamController && player.streamController.keyLoader);
  }
  function reportKey(d){
    if (!d || d.method !== 'AES-128' || (d.keyFormat && d.keyFormat !== 'identity') || d.isCommonEncryption) return;
    var u = d.uri, k = d.key;
    if (typeof u !== 'string' || !/^https?:\/\//i.test(u) || !k || k.length !== 16) return;
    var bytes = Array.from(k);
    if (!bytes.every(function(v){ return Number.isInteger(v) && v >= 0 && v <= 255; })) return;
    var signature = bytes.join(',');
    if (keySeen[u] === signature) return;
    keySeen[u] = signature;
    if (isTop) {
      try { window.flutter_inappwebview.callHandler('oplayerHlsKey', u, bytes); } catch(e) {}
    } else {
      try { window.top.postMessage({__oplayer: 1, kind: 'hls-key', url: u, key: bytes}, '*'); } catch(e) {}
    }
  }
  function watchHls(Hls){
    if (!Hls || !Hls.prototype || typeof Hls.prototype.trigger !== 'function') return;
    var original = Hls.prototype.trigger;
    if (original.__oplayerKeys) return;
    var trigger = function(event, data){
      try {
        if (hlsPlayers.indexOf(this) < 0) hlsPlayers.push(this);
        if (event === 'hlsKeyLoaded') reportKey(data && data.frag && data.frag.decryptdata);
        if (event === 'hlsFragChanged') {
          var loader = keyLoaderFor(this);
          var cache = loader && loader.keyUriToKeyInfo;
          if (cache) Object.keys(cache).forEach(function(u){ reportKey(cache[u].decryptdata); });
        }
      } catch(e) {}
      return original.apply(this, arguments);
    };
    trigger.__oplayerKeys = true;
    Hls.prototype.trigger = trigger;
  }
  async function prepareKeys(url){
    for (var player of hlsPlayers) {
      try {
        var tracks = (player.levels || []).concat(player.audioTracks || []);
        if (player.url !== url && !tracks.some(function(t){ return t.details && t.details.url === url; })) continue;
        var loader = keyLoaderFor(player);
        if (!loader || typeof loader.load !== 'function') throw new Error('HLS key loader unavailable');
        var fragments = [];
        tracks.forEach(function(t){ if (t.details && t.details.fragments) fragments = fragments.concat(t.details.fragments); });
        var requested = {};
        for (var frag of fragments) {
          var d = frag.decryptdata;
          if (!d || d.method !== 'AES-128' || (d.keyFormat && d.keyFormat !== 'identity') || requested[d.uri]) continue;
          requested[d.uri] = true;
          if (!d.key) await loader.load(frag);
          reportKey(frag.decryptdata);
        }
      } catch(e) {
        var error = String(e && (e.message || (e.data && e.data.error && e.data.error.message)) || e).slice(0, 240);
        if (isTop) {
          try { window.flutter_inappwebview.callHandler('oplayerHlsPrepareError', url, error); } catch(err) {}
        } else {
          try { window.top.postMessage({__oplayer: 1, kind: 'hls-prepare-error', url: url, error: error}, '*'); } catch(err) {}
        }
      }
    }
  }
  window.addEventListener('message', function(e){
    var d = e.data;
    if (!d || typeof d.__oplayerPrepareKeys !== 'string') return;
    prepareKeys(d.__oplayerPrepareKeys);
    document.querySelectorAll('iframe,frame').forEach(function(f){
      try { f.contentWindow.postMessage(d, '*'); } catch(err) {}
    });
  });
  try {
    var currentHls = window.Hls;
    watchHls(currentHls);
    Object.defineProperty(window, 'Hls', {
      configurable: true, enumerable: true,
      get: function(){ return currentHls; },
      set: function(value){ currentHls = value; watchHls(value); }
    });
  } catch(e) {}
  function abs(u){ try { return new URL(u, location.href).href; } catch(e) { return null; } }
  function report(u, kind, size, headers){
    if (!u || typeof u !== 'string') return;
    if (u.indexOf('blob:') === 0 || u.indexOf('data:') === 0) return;
    var a = abs(u); if (!a) return;
    if (!kind) { if (!extRe.test(a) || segRe.test(a)) return; }
    // 이미지 확장자(움짤 미리보기 등)는 재생목록으로 확인된 경우만 허용
    if (imgRe.test(a) && kind !== 'hls' && kind !== 'dash') return;
    if (kind === 'file' && size > 0 && size < PREVIEW_MAX) return;
    var key = a + '|' + (kind || '');
    if ((!headers || Object.keys(headers).length === 0) && (seen[key] || (!kind && seen[a]))) return;
    seen[a] = 1; seen[key] = 1;
    send(a, kind || '', size || 0, headers);
  }
  function kindFromType(ct){
    ct = (ct || '').toLowerCase();
    if (ct.indexOf('mpegurl') >= 0) return 'hls';
    if (ct.indexOf('dash+xml') >= 0) return 'dash';
    if (ct.indexOf('video/mp2t') >= 0 || ct.indexOf('iso.segment') >= 0) return null; // 조각
    if (ct.indexOf('video/') === 0) return 'file';
    return null;
  }
  function kindFromText(t){
    if (typeof t !== 'string') return null;
    var h = t.slice(0, 300).replace(/^﻿/, '').trim();
    if (h.indexOf('#EXTM3U') === 0) return 'hls';
    if (h.indexOf('<MPD') >= 0 || (h.indexOf('<?xml') === 0 && t.indexOf('<MPD') >= 0)) return 'dash';
    return null;
  }
  function kindFromBytes(buf){
    try { return kindFromText(new TextDecoder().decode(new Uint8Array(buf, 0, Math.min(buf.byteLength, 300)))); } catch(e) { return null; }
  }
  // 응답 본문을 확인해 볼 가치가 있는지 (이미지/폰트/스크립트 등은 제외)
  function sniffable(ct, len){
    ct = (ct || '').toLowerCase();
    if (/^(image|font|audio)\//.test(ct) || /javascript|css|html|json|woff/.test(ct)) return false;
    if (/^video\//.test(ct)) return false;
    return !(len > 4 * 1024 * 1024);
  }
  function scan(){
    document.querySelectorAll('video').forEach(function(v){
      // 자동재생·무음·반복 = 썸네일 미리보기
      if (v.loop && v.muted) return;
      if (v.duration && isFinite(v.duration) && v.duration < 30) return;
      var srcs = [v.currentSrc, v.src, v.getAttribute('src')];
      v.querySelectorAll('source').forEach(function(s){ srcs.push(s.src); if (/mpegurl/i.test(s.type || '')) report(s.src, 'hls'); });
      srcs.forEach(function(s){
        if (!s) return;
        if (s.indexOf('blob:') === 0) { send(location.href, 'mse'); return; }
        report(s, extRe.test(s) ? '' : 'file');
      });
    });
  }
  // fetch
  var of = window.fetch;
  if (of) window.fetch = function(input, init){
    var url = typeof input === 'string' ? input : (input && (input.url || String(input)));
    var headers = {};
    try {
      new Headers(init && init.headers !== undefined ? init.headers : (input && input.headers)).forEach(function(v, k){ headers[k] = v; });
    } catch(e){}
    var p = of.apply(this, arguments);
    try {
      p.then(function(res){
        try {
          var ct = res.headers.get('content-type');
          var len = parseInt(res.headers.get('content-length') || '0', 10);
          var u = res.url || url;
          var k = kindFromType(ct);
          if (k) {
            report(u, k, len, headers);
            if (k === 'hls') res.clone().text().then(function(t){ reportPlaylist(u, t); }).catch(function(){});
            return;
          }
          if (extRe.test(u)) report(u, '', len, headers);
          if (!sniffable(ct, len) || !res.body) return;
          var rd = res.clone().body.getReader();
          rd.read().then(function(r){
            try { rd.cancel(); } catch(e){}
            if (r && r.value) {
              var kb = kindFromBytes(r.value.buffer);
              if (kb) report(u, kb, 0, headers);
              if (kb === 'hls') res.clone().text().then(function(t){ reportPlaylist(u, t); }).catch(function(){});
            }
          }).catch(function(){});
        } catch(e){}
      }).catch(function(){});
    } catch(e){}
    return p;
  };
  // XHR (hls.js 기본 로더)
  var oo = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function(m, u){
    try { this.__oplayerUrl = String(u); } catch(e){}
    this.__oplayerHeaders = {};
    if (!this.__oplayerListening) this.addEventListener('load', function(){
      try {
        var ct = this.getResponseHeader('content-type');
        var len = parseInt(this.getResponseHeader('content-length') || '0', 10);
        var url = this.responseURL || this.__oplayerUrl;
        var k = kindFromType(ct);
        if (!k && sniffable(ct, len)) {
          if (this.responseType === '' || this.responseType === 'text') k = kindFromText(this.responseText);
          else if (this.responseType === 'arraybuffer' && this.response) k = kindFromBytes(this.response);
        }
        if (k) report(url, k, len, this.__oplayerHeaders); else report(url, '', len, this.__oplayerHeaders);
        if (k === 'hls') {
          if (this.responseType === '' || this.responseType === 'text') reportPlaylist(url, this.responseText);
          else if (this.responseType === 'arraybuffer' && this.response) reportPlaylist(url, new TextDecoder().decode(this.response));
        }
      } catch(e){}
    });
    this.__oplayerListening = true;
    return oo.apply(this, arguments);
  };
  var osh = XMLHttpRequest.prototype.setRequestHeader;
  XMLHttpRequest.prototype.setRequestHeader = function(name, value){
    var result = osh.apply(this, arguments);
    var h = this.__oplayerHeaders || (this.__oplayerHeaders = {});
    var key = String(name).toLowerCase();
    h[key] = h[key] === undefined ? String(value) : h[key] + ', ' + value;
    return result;
  };
  // MediaSource 사용 감지
  try {
    var oc = URL.createObjectURL;
    URL.createObjectURL = function(o){
      try { if (window.MediaSource && o instanceof MediaSource) send(location.href, 'mse'); } catch(e){}
      return oc.apply(this, arguments);
    };
  } catch(e){}
  try {
    new PerformanceObserver(function(l){ l.getEntries().forEach(function(e){ report(e.name, '', e.decodedBodySize || e.transferSize || 0); }); })
      .observe({entryTypes:['resource']});
  } catch(e) {}
  document.addEventListener('play', function(){ scan(); }, true);
  setInterval(scan, 2000);
  if (document.readyState !== 'loading') scan(); else document.addEventListener('DOMContentLoaded', scan);
})();
''';

class WebBrowserPage extends StatefulWidget {
  const WebBrowserPage({super.key, required this.onOpenDrawer});
  final VoidCallback onOpenDrawer;

  @override
  State<WebBrowserPage> createState() => _WebBrowserPageState();
}

class _WebBrowserPageState extends State<WebBrowserPage> {
  static const _kBookmarks = 'web_bookmarks';
  String get _home => AppSettings.instance.homepage;

  InAppWebViewController? _web;
  PullToRefreshController? _pullToRefresh;
  final _address = TextEditingController();
  final _addressFocus = FocusNode();
  final _found = <String, DetectedMedia>{};
  final _hlsKeys = <String, Uint8List>{};
  final _hlsPlaylists = <String, String>{};
  bool _preparingDownload = false;
  String? _preparingUrl;
  String? _keyPreparationError;
  String _url = '';
  String _title = '';
  double _progress = 0;
  bool _canBack = false;
  bool _canForward = false;
  BrowserHistory _history = BrowserHistory();
  bool _historyReady = false;
  bool _historyMoving = false;
  int _historyRead = 0;
  List<String> _bookmarks = [];

  @override
  void initState() {
    super.initState();
    PluginStore.instance.addListener(_pluginsChanged);
    MouseNav.addForwardHandler(_forward);
    HardwareKeyboard.instance.addHandler(_onKey);
    BrowserHistoryStore.load()
        .catchError((Object error) {
          debugPrint('Browser history restore failed: $error');
          return BrowserHistory();
        })
        .then((history) {
          if (!mounted) return;
          setState(() {
            _history = history;
            _historyReady = true;
            _canBack = history.canBack;
            _canForward = history.canForward;
            _url = history.current ?? _home;
            _address.text = _url;
          });
        });
    if (Platform.isAndroid || Platform.isIOS) {
      _pullToRefresh = PullToRefreshController(
        settings: PullToRefreshSettings(color: Color(AppSettings.instance.primaryColor)),
        onRefresh: () async {
          try {
            if (_web == null) {
              await _pullToRefresh?.endRefreshing();
            } else {
              await _web!.reload();
            }
          } catch (_) {
            await _pullToRefresh?.endRefreshing();
          }
        },
      );
    }
    if (Platform.isWindows) {
      _windowsEnv().then((env) {
        if (mounted) {
          setState(() {
            _env = env;
            _envReady = true;
          });
        }
      });
    }
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() {
        _bookmarks = p.getStringList(_kBookmarks) ?? [];
      });
    });
  }

  Future<DetectedMedia> _resolvePluginMedia(DetectedMedia m) async {
    final result = await resolveSiteMedia({
      'url': m.url,
      'pageUrl': m.pageUrl,
      'referer': m.referer,
      'title': m.pageTitle,
      'kind': m.kind.name,
      'headers': await _headersFor(m),
    });
    final url = result['url'] as String;
    _capturedHeaders.capture(url, result['headers'] as Map?);
    return DetectedMedia(
      url: url,
      kind: MediaKind.values.firstWhere((e) => e.name == result['kind'], orElse: () => m.kind),
      pageUrl: m.pageUrl,
      pageTitle: result['title'] as String? ?? m.pageTitle,
      size: url == m.url ? m.size : 0,
      referer: m.referer,
    );
  }

  bool _forward() {
    if (!_canForward) return false;
    unawaited(_navigateHistory(1));
    return true;
  }

  void _saveHistory() {
    unawaited(
      BrowserHistoryStore.save(_history).catchError((Object error) {
        debugPrint('Browser history save failed: $error');
      }),
    );
  }

  Future<void> _navigateHistory(int steps) async {
    final web = _web;
    if (web == null || _historyMoving || (steps < 0 ? !_history.canBack : !_history.canForward)) return;
    _historyMoving = true;
    try {
      final native = await web.getCopyBackForwardList();
      if (!mounted) return;
      final nativeTarget = _history.move(steps);
      _historyRead++; // Discard a history query issued before this navigation.
      _saveHistory();
      setState(() {
        _canBack = _history.canBack;
        _canForward = _history.canForward;
      });
      final index = native?.currentIndex;
      if (nativeTarget != null && index != null) {
        await web.goBackOrForward(steps: nativeTarget - index);
        return;
      }
      _history.prepareReload();
      await web.loadUrl(urlRequest: URLRequest(url: WebUri(_history.current!)));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('페이지 이동 실패: $error')));
    } finally {
      _historyMoving = false;
    }
  }

  Future<void> _syncHistory(InAppWebViewController web, {bool reload = false}) async {
    final read = ++_historyRead;
    WebHistory? native;
    try {
      native = await web.getCopyBackForwardList();
    } catch (_) {
      return; // The platform view may have been disposed during a menu change.
    }
    if (!mounted || read != _historyRead) return;
    final index = native?.currentIndex;
    final entries = native?.list;
    if (index == null || entries == null || index < 0 || index >= entries.length) return;
    final url = entries[index].url?.toString();
    if (url == null || url == 'about:blank') return;
    _history.record(url, index, reload: reload);
    _saveHistory();
    setState(() {
      _url = url;
      if (!_addressFocus.hasFocus) _address.text = _url;
      _canBack = _history.canBack;
      _canForward = _history.canForward;
    });
  }

  @override
  void dispose() {
    if (_historyReady) _saveHistory();
    PluginStore.instance.removeListener(_pluginsChanged);
    MouseNav.removeForwardHandler(_forward);
    HardwareKeyboard.instance.removeHandler(_onKey);
    _address.dispose();
    _addressFocus.dispose();
    super.dispose();
  }

  Future<void> _pluginsChanged() async {
    final web = _web;
    if (web == null) return;
    try {
      if (Platform.isWindows) await _configureAdBlock(web);
      await web.setSettings(settings: InAppWebViewSettings(contentBlockers: pluginContentBlockers()));
      await web.removeUserScriptsByGroupName(groupName: 'oplayerPlugins');
      for (final p in PluginStore.instance.enabled.where((p) => p.site)) {
        await web.addUserScript(
          userScript: UserScript(
            source: sitePluginScript(p),
            groupName: 'oplayerPlugins',
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
            forMainFrameOnly: false,
          ),
        );
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('확장앱 적용 실패: $e')));
    }
  }

  /// 페이지가 MediaSource(blob:)로 재생 중인지 — 받을 주소를 못 찾았을 때 안내에 사용
  bool _mse = false;

  /// 네트워크 응답 기록 (데스크톱 DevTools 감지용, 진단 화면에 표시)
  final _netLog = <_NetEntry>[];
  final _pendingBodies = <String, String>{}; // requestId → url (본문 확인 대기)

  /// 실제 요청 헤더: Windows DevTools / Android 요청 콜백 / fetch·XHR 스크립트.
  final _capturedHeaders = BrowserRequestHeaders();

  /// Windows: 사이트 격리를 끈 WebView2 환경.
  /// 다른 도메인 iframe(영상 플레이어)도 같은 프로세스에서 돌게 해서
  /// 감지 스크립트와 네트워크 감시가 iframe 안까지 닿게 한다.
  WebViewEnvironment? _env;
  bool _envReady = !Platform.isWindows;

  static Future<WebViewEnvironment?> _windowsEnv() => browserEnvironment();

  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent || !mounted) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? false)) return false;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.f5 || (ctrl && k == LogicalKeyboardKey.keyR)) {
      (ctrl && k == LogicalKeyboardKey.f5) || (shift && k == LogicalKeyboardKey.keyR) ? _hardReload() : _reload();
      return true;
    }
    if (ctrl && k == LogicalKeyboardKey.keyL) {
      _addressFocus.requestFocus();
      _address.selection = TextSelection(baseOffset: 0, extentOffset: _address.text.length);
      return true;
    }
    return false;
  }

  void _reload() => _web?.reload();

  /// Ctrl+F5: 캐시 무시 새로고침
  Future<void> _hardReload() async {
    final w = _web;
    if (w == null) return;
    setState(() {
      _found.clear();
      _mse = false;
      _netLog.clear();
    });
    try {
      if (Platform.isWindows) {
        await w.callDevToolsProtocolMethod(methodName: 'Network.clearBrowserCache');
        await w.callDevToolsProtocolMethod(methodName: 'Page.reload', parameters: {'ignoreCache': true});
      } else if (Platform.isMacOS || Platform.isIOS) {
        await w.reloadFromOrigin();
      } else {
        await InAppWebViewController.clearAllCache();
        await w.reload();
      }
    } catch (_) {
      await w.reload();
    }
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('캐시를 비우고 새로고침했습니다'), duration: Duration(seconds: 1)));
    }
  }

  /// DevTools Network 이벤트로 모든 응답(iframe 포함)을 본다. Windows 전용.
  Future<void> _attachNetworkMonitor(InAppWebViewController c) async {
    if (!Platform.isWindows) return;
    try {
      await c.addDevToolsProtocolEventListener(
        eventName: 'Fetch.requestPaused',
        callback: (data) async {
          final id = data?['requestId'];
          if (id == null) return;
          final url = '${data?['request']?['url'] ?? ''}';
          final blocked = blockedBySitePlugin(_url, url);
          try {
            await c.callDevToolsProtocolMethod(
              methodName: blocked ? 'Fetch.failRequest' : 'Fetch.continueRequest',
              parameters: {'requestId': id, if (blocked) 'errorReason': 'BlockedByClient'},
            );
          } catch (_) {}
        },
      );
      await _configureAdBlock(c);
    } catch (_) {} // Ad blocking failure must not disable request/header capture.
    try {
      await c.addDevToolsProtocolEventListener(
        eventName: 'Network.requestWillBeSent',
        callback: (data) {
          if (data is! Map) return;
          final req = data['request'];
          if (req is! Map) return;
          final id = '${data['requestId'] ?? ''}';
          final url = '${req['url'] ?? ''}';
          if (!url.startsWith('http')) return;
          _capturedHeaders.request(id, url, req['headers'] as Map?);
        },
      );
      // 쿠키 등 실제 전송된 전체 헤더
      await c.addDevToolsProtocolEventListener(
        eventName: 'Network.requestWillBeSentExtraInfo',
        callback: (data) {
          if (data is! Map) return;
          _capturedHeaders.extra('${data['requestId'] ?? ''}', data['headers'] as Map?);
        },
      );
      await c.addDevToolsProtocolEventListener(
        eventName: 'Network.responseReceived',
        callback: (data) {
          if (data is! Map) return;
          final res = data['response'];
          if (res is! Map) return;
          final url = '${res['url'] ?? ''}';
          if (!url.startsWith('http')) return;
          final mime = '${res['mimeType'] ?? ''}'.toLowerCase();
          final type = '${data['type'] ?? ''}';
          final headers = (res['headers'] as Map?) ?? const {};
          String? h(String n) {
            for (final e in headers.entries) {
              if ('${e.key}'.toLowerCase() == n) return '${e.value}';
            }
            return null;
          }

          final len = int.tryParse(h('content-length') ?? '') ?? 0;
          final total = int.tryParse((h('content-range') ?? '').split('/').last) ?? len;
          _logNet(_NetEntry(url, mime, type, total));

          if (mime.contains('mpegurl')) {
            _pendingBodies['${data['requestId'] ?? ''}'] = url;
            return _onMedia(url, _title, 'hls');
          }
          if (mime.contains('dash+xml')) return _onMedia(url, _title, 'dash');
          if (mime.startsWith('video/') && !mime.contains('mp2t') && !mime.contains('iso.segment')) {
            if (total == 0 || total >= 1536 * 1024) {
              _onMedia(url, _title, 'file', total);
            }
            return;
          }
          // 형식이 애매한 작은 응답은 본문 앞부분을 확인 (재생목록을 octet-stream/text로 주는 사이트)
          final ambiguous =
              mime.isEmpty ||
              mime.contains('octet-stream') ||
              mime.startsWith('text/plain') ||
              mime.contains('binary') ||
              (type == 'XHR' || type == 'Fetch') &&
                  !mime.contains('json') &&
                  !mime.contains('html') &&
                  !mime.contains('javascript');
          if (ambiguous && !mime.startsWith('image/') && (total == 0 || total < 2 * 1024 * 1024)) {
            final id = '${data['requestId'] ?? ''}';
            if (id.isNotEmpty) _pendingBodies[id] = url;
          }
        },
      );
      await c.addDevToolsProtocolEventListener(
        eventName: 'Network.loadingFinished',
        callback: (data) async {
          if (data is! Map) return;
          final id = '${data['requestId'] ?? ''}';
          final url = _pendingBodies.remove(id);
          if (url == null) return;
          try {
            final body = await c.callDevToolsProtocolMethod(
              methodName: 'Network.getResponseBody',
              parameters: {'requestId': id},
            );
            if (body is! Map) return;
            var text = '${body['body'] ?? ''}';
            if (body['base64Encoded'] == true) {
              final raw = base64.decode(text);
              text = utf8.decode(raw, allowMalformed: true);
            }
            final head = text.trimLeft().replaceFirst('\uFEFF', '');
            if (head.startsWith('#EXTM3U')) {
              _recordPlaylist(url, text);
              _onMedia(url, _title, 'hls');
            } else if (head.contains('<MPD')) {
              _onMedia(url, _title, 'dash');
            }
          } catch (_) {}
        },
      );
      await c.callDevToolsProtocolMethod(methodName: 'Network.enable');
    } catch (_) {}
  }

  Future<void> _configureAdBlock(InAppWebViewController c) async {
    final enabled = PluginStore.instance.enabled.any(
      (p) => p.site && (p.manifest['blockRules'] as List? ?? []).isNotEmpty,
    );
    await c.callDevToolsProtocolMethod(
      methodName: enabled ? 'Fetch.enable' : 'Fetch.disable',
      parameters: enabled
          ? {
              'patterns': [
                {'urlPattern': '*', 'requestStage': 'Request'},
              ],
            }
          : {},
    );
  }

  void _recordPlaylist(String url, String text) {
    if (text.length > 4 * 1024 * 1024 || !Hls.isPlaylist(text)) return;
    _hlsPlaylists[url] = text;
    while (_hlsPlaylists.length > 40 ||
        _hlsPlaylists.values.fold<int>(0, (sum, value) => sum + value.length) > 8 * 1024 * 1024) {
      _hlsPlaylists.remove(_hlsPlaylists.keys.first);
    }
  }

  Future<void> _prepareDownloadKeys(DetectedMedia media) async {
    final needed = <String>{};
    final visited = <String>{};
    void collect(String url) {
      if (!visited.add(url)) return;
      final text = _hlsPlaylists[url];
      if (text == null) return;
      final base = Uri.parse(url);
      if (Hls.isMaster(text)) {
        final master = Hls.parseMasterFull(text, base);
        for (final variant in master.variants) {
          collect(variant.uri.toString());
        }
        for (final audio in master.audios) {
          if (audio.uri != null) collect(audio.uri.toString());
        }
      } else {
        for (final segment in Hls.parseMedia(text, base).segments) {
          if (segment.key?.method == 'AES-128' && segment.key?.uri != null) {
            needed.add(segment.key!.uri.toString());
          }
          if (segment.uri.path.toLowerCase().endsWith('.m3u8')) {
            collect(segment.uri.toString());
          }
        }
      }
    }

    collect(media.url);
    // A browser-resolved key means the page's own key loader is available.
    if (_hlsKeys.isEmpty || needed.every(_hlsKeys.containsKey)) return;
    final web = _web;
    if (web == null) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('구간별 암호화 키를 준비하는 중입니다…'), duration: Duration(seconds: 90)));
    try {
      _preparingUrl = media.url;
      _keyPreparationError = null;
      await web.evaluateJavascript(
        source: "window.postMessage({__oplayerPrepareKeys: ${jsonEncode(media.url)}}, '*');",
      );
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      while (!needed.every(_hlsKeys.containsKey)) {
        if (_keyPreparationError != null) {
          throw FormatException('구간별 암호화 키를 준비하지 못했습니다: $_keyPreparationError');
        }
        if (!mounted || DateTime.now().isAfter(deadline)) {
          throw const FormatException('모든 구간의 암호화 키를 준비하지 못했습니다. 페이지에서 재생 상태를 확인한 뒤 다시 시도해 주세요.');
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    } finally {
      _preparingUrl = null;
      if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
    }
  }

  void _logNet(_NetEntry e) {
    _netLog.add(e);
    if (_netLog.length > 400) _netLog.removeRange(0, _netLog.length - 400);
  }

  Future<void> _showNetLog() async {
    final items = _netLog.reversed
        .where((e) => e.failed || (!e.mime.startsWith('image/') && !e.mime.contains('font') && !e.mime.contains('css')))
        .toList();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: OColors.of(context).surface,
      builder: (c) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.75,
          child: Column(
            children: [
              ListTile(
                title: Text('네트워크 요청 ${items.length}개 (실패한 리소스 포함)'),
                subtitle: const Text('길게 누르면 주소 복사 · 탭하면 재생 시도', style: TextStyle(fontSize: 12)),
              ),
              const Divider(height: 1),
              Expanded(
                child: items.isEmpty
                    ? const Center(child: Text('감지된 요청이나 실패 기록이 없습니다'))
                    : ListView.builder(
                        itemCount: items.length,
                        itemBuilder: (_, i) {
                          final e = items[i];
                          return ListTile(
                            dense: true,
                            title: Text(
                              e.url,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                            subtitle: Text(
                              '${e.type} · ${e.mime}${e.size > 0 ? ' · ${formatSize(e.size)}' : ''}',
                              style: TextStyle(fontSize: 11, color: OColors.of(context).textSecondary),
                            ),
                            onLongPress: () {
                              Clipboard.setData(ClipboardData(text: e.url));
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('주소를 복사했습니다')));
                            },
                            onTap: e.failed
                                ? null
                                : () async {
                                    Navigator.pop(c);
                                    final m = DetectedMedia(
                                      url: e.url,
                                      kind: MediaKind.file,
                                      pageUrl: _url,
                                      pageTitle: _title,
                                    );
                                    await _playDetectedMedia(m);
                                  },
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _onMedia(String url, String title, [String hint = '', int size = 0, String? referer]) {
    if (hint == 'mse') {
      if (!_mse) setState(() => _mse = true);
      return;
    }
    final lower = url.toLowerCase();
    final kind = switch (hint) {
      'hls' => MediaKind.hls,
      'dash' => MediaKind.dash,
      'file' => MediaKind.file,
      _ =>
        lower.contains('.m3u8')
            ? MediaKind.hls
            : lower.contains('.mpd')
            ? MediaKind.dash
            : MediaKind.file,
    };
    final existing = _found[url];
    // 확장자로 file로 잡혔다가 응답 확인 결과 hls/dash로 바뀌는 경우 갱신
    if (existing != null &&
        (existing.kind == kind || hint.isEmpty) &&
        (referer == null || referer == existing.referer)) {
      return;
    }
    setState(() {
      _found[url] = DetectedMedia(
        url: url,
        kind: existing != null && hint.isEmpty ? existing.kind : kind,
        pageUrl: _url,
        pageTitle: title.isEmpty ? _title : title,
        size: size > 0 ? size : (existing?.size ?? 0),
        referer: referer ?? existing?.referer,
      );
    });
  }

  /// 재생/다운로드 요청에 붙일 헤더 — 사이트에서 재생할 때와 최대한 같게.
  ///  1) Windows: 웹뷰가 실제로 보낸 요청 헤더(쿠키 포함)를 그대로 재사용
  ///  2) Android: 네이티브 요청 헤더 + 웹뷰 UA·쿠키
  ///  3) 네이티브 수집 불가 시: fetch/XHR 헤더 + 문서(iframe) 기준 대체값
  Future<void> _playDetectedMedia(DetectedMedia media) async {
    if (_preparingDownload) return;
    setState(() => _preparingDownload = true);
    try {
      media = await _resolvePluginMedia(media);
      final hls = media.kind == MediaKind.hls || _hlsPlaylists.containsKey(media.url);
      if (hls) await _prepareDownloadKeys(media);
      final headers = await _headersFor(media);
      if (!mounted) return;
      final item = media.kind == MediaKind.dash
          ? MediaItem.url(media.url, title: media.pageTitle, headers: headers, browserMedia: true)
          : BrowserPlaybackRegistry.remember(
              url: media.url,
              title: media.pageTitle.isEmpty ? media.label : media.pageTitle,
              pageUrl: media.pageUrl,
              headers: headers,
              hls: hls,
              length: media.size,
              keys: _hlsKeys,
              playlists: _hlsPlaylists,
              requestHeaders: _capturedHeaders.snapshot(),
            );
      setState(() => _preparingDownload = false);
      await Navigator.of(context).push(PlayerScreen.route([item], 0));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('재생 준비 실패: $error')));
    } finally {
      if (mounted) setState(() => _preparingDownload = false);
    }
  }

  Future<Map<String, String>> _headersFor(DetectedMedia m) async {
    final captured = _capturedHeaders.forUrl(m.url);
    final h = BrowserRequestHeaders.replay(captured ?? const {});
    final native = _capturedHeaders.hasNative(m.url);
    // Windows captures browser-added headers too: do not invent absent headers.
    if (Platform.isWindows && native) return h;
    String? ua = h['User-Agent'];
    if (ua == null) {
      try {
        final r = await _web?.evaluateJavascript(source: 'navigator.userAgent');
        if (r is String && r.isNotEmpty) ua = r;
      } catch (_) {}
    }
    final referer = h['Referer'] ?? m.referer ?? m.pageUrl;
    final refUri = Uri.tryParse(referer);
    final target = Uri.tryParse(m.url);
    if (!native) h.putIfAbsent('Referer', () => referer);
    if (ua != null) h.putIfAbsent('User-Agent', () => ua!);
    if (!native) {
      h.putIfAbsent('Accept', () => '*/*');
      h.putIfAbsent(
        'Accept-Language',
        () => '${WidgetsBinding.instance.platformDispatcher.locale.toLanguageTag()},ko;q=0.9,en-US;q=0.8,en;q=0.7',
      );
    }
    if (!native && refUri != null && refUri.hasAuthority) {
      final origin = '${refUri.scheme}://${refUri.authority}';
      final sameOrigin = target != null && '${target.scheme}://${target.authority}' == origin;
      if (!sameOrigin) h.putIfAbsent('Origin', () => origin);
      h.putIfAbsent('Sec-Fetch-Dest', () => 'empty');
      h.putIfAbsent('Sec-Fetch-Mode', () => 'cors');
      h.putIfAbsent(
        'Sec-Fetch-Site',
        () => sameOrigin
            ? 'same-origin'
            : (target != null && _site(target.host) == _site(refUri.host) ? 'same-site' : 'cross-site'),
      );
    }
    if (!native && !h.containsKey('Cookie')) {
      try {
        final cookies = await CookieManager.instance(webViewEnvironment: _env).getCookies(url: WebUri(m.url));
        if (cookies.isNotEmpty) {
          h['Cookie'] = cookies.map((c) => '${c.name}=${c.value}').join('; ');
        }
      } catch (_) {}
    }
    return h;
  }

  /// 대략적인 등록 도메인 (a.b.example.com → example.com)
  static String _site(String host) {
    final parts = host.split('.');
    return parts.length <= 2 ? host : parts.sublist(parts.length - 2).join('.');
  }

  void _go(String input) {
    var s = input.trim();
    if (s.isEmpty) return;
    if (!s.contains('://')) {
      s = (s.contains('.') && !s.contains(' '))
          ? 'https://$s'
          : 'https://www.google.com/search?q=${Uri.encodeQueryComponent(s)}';
    }
    _addressFocus.unfocus();
    _web?.loadUrl(urlRequest: URLRequest(url: WebUri(s)));
  }

  Future<void> _toggleBookmark() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      if (_bookmarks.contains(_url)) {
        _bookmarks.remove(_url);
      } else {
        _bookmarks.insert(0, _url);
      }
    });
    await prefs.setStringList(_kBookmarks, _bookmarks);
  }

  Future<void> _showBookmarks() async {
    final url = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: OColors.of(context).surface,
      builder: (c) => SafeArea(
        child: _bookmarks.isEmpty
            ? const Padding(padding: EdgeInsets.all(32), child: Text('북마크가 없습니다'))
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final b in _bookmarks)
                    ListTile(
                      leading: const Icon(Icons.bookmark),
                      title: Text(Uri.tryParse(b)?.host ?? b),
                      subtitle: Text(b, maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => Navigator.pop(c, b),
                    ),
                ],
              ),
      ),
    );
    if (url != null) _go(url);
  }

  Future<void> _showFound() async {
    Tooltip.dismissAllToolTips();
    // 스트림(HLS/DASH) 먼저, 그다음 큰 파일 순 — 본편이 위로
    final items = _found.values.toList()
      ..sort((a, b) {
        int rank(DetectedMedia m) => m.kind == MediaKind.file ? 1 : 0;
        final r = rank(a).compareTo(rank(b));
        return r != 0 ? r : b.size.compareTo(a.size);
      });
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: OColors.of(context).surface,
      builder: (c) => StatefulBuilder(
        builder: (c, updateSheet) => TooltipVisibility(
          visible: false,
          child: SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    title: Text(
                      _preparingDownload ? '구간별 암호화 키 준비 중…' : '감지된 동영상 ${items.length}개',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: const Text('DRM으로 보호된 영상은 재생/다운로드되지 않을 수 있습니다', style: TextStyle(fontSize: 12)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (Platform.isWindows || Platform.isAndroid)
                          TextButton(
                            onPressed: () {
                              Navigator.pop(c);
                              _showNetLog();
                            },
                            child: const Text('요청 기록'),
                          ),
                        TextButton(
                          onPressed: () {
                            setState(() {
                              _found.clear();
                              _mse = false;
                            });
                            Navigator.pop(c);
                          },
                          child: const Text('비우기'),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Flexible(
                    child: items.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(32),
                            child: Text(
                              _mse
                                  ? '이 페이지는 영상을 조각으로 받아 브라우저 안에서 조립하는 방식(MediaSource)으로 재생 중이고,\n'
                                        '받을 수 있는 스트림 주소(m3u8/mp4)를 찾지 못했습니다.\n'
                                        '보호된 스트리밍이거나 지원하지 않는 방식이라 재생/받기를 할 수 없습니다.'
                                  : '아직 찾은 동영상이 없습니다.\n페이지에서 영상을 재생하면 감지됩니다.',
                              textAlign: TextAlign.center,
                            ),
                          )
                        : ListView(
                            shrinkWrap: true,
                            children: [
                              for (final m in items)
                                ListTile(
                                  leading: Icon(
                                    m.kind == MediaKind.file ? Icons.movie_outlined : Icons.stream,
                                    color: OColors.of(context).accent,
                                  ),
                                  title: Text(m.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                                  subtitle: Text(
                                    m.size > 0 ? '${formatSize(m.size)} · ${m.url}' : m.url,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        tooltip: '재생',
                                        icon: const Icon(Icons.play_arrow),
                                        onPressed: _preparingDownload
                                            ? null
                                            : () async {
                                                Navigator.pop(c);
                                                await _playDetectedMedia(m);
                                              },
                                      ),
                                      IconButton(
                                        tooltip: m.kind == MediaKind.dash ? 'DASH는 다운로드 미지원' : '다운로드',
                                        icon: _preparingDownload
                                            ? const SizedBox(
                                                width: 20,
                                                height: 20,
                                                child: CircularProgressIndicator(strokeWidth: 2),
                                              )
                                            : const Icon(Icons.download),
                                        onPressed: m.kind == MediaKind.dash || _preparingDownload
                                            ? null
                                            : () async {
                                                if (_preparingDownload) return;
                                                updateSheet(() => _preparingDownload = true);
                                                try {
                                                  final quality = await showDialog<OutputQuality>(
                                                    context: context,
                                                    builder: (dialog) => SimpleDialog(
                                                      title: const Text('MP4 생성 옵션'),
                                                      children: [
                                                        for (final q in OutputQuality.values)
                                                          SimpleDialogOption(
                                                            onPressed: () => Navigator.pop(dialog, q),
                                                            child: Text(
                                                              '${q == AppSettings.instance.outputQuality ? '✓ ' : ''}${q.label}',
                                                            ),
                                                          ),
                                                      ],
                                                    ),
                                                  );
                                                  if (quality == null) return;
                                                  if (!mounted || !c.mounted) return;
                                                  final fileName = await askDownloadName(
                                                    context,
                                                    initialName: DownloadManager.suggestedFileName(
                                                      url: m.url,
                                                      title: m.pageTitle.isEmpty ? m.label : m.pageTitle,
                                                      hls: m.kind == MediaKind.hls,
                                                      outputQuality: quality,
                                                    ),
                                                  );
                                                  if (fileName == null || !mounted || !c.mounted) return;
                                                  final resolved = await _resolvePluginMedia(m);
                                                  if (resolved.kind == MediaKind.hls) {
                                                    await _prepareDownloadKeys(resolved);
                                                  }
                                                  final h = await _headersFor(resolved);
                                                  if (!mounted || !c.mounted) {
                                                    return;
                                                  }
                                                  DownloadManager.instance.add(
                                                    url: resolved.url,
                                                    title: m.pageTitle.isEmpty ? m.label : m.pageTitle,
                                                    fileName: fileName.name,
                                                    overwriteTarget: fileName.overwriteTarget,
                                                    headers: h,
                                                    hlsKeys: _hlsKeys,
                                                    hlsPlaylists: _hlsPlaylists,
                                                    pageUrl: m.pageUrl,
                                                    hls: resolved.kind == MediaKind.hls,
                                                    outputQuality: quality,
                                                  );
                                                  if (c.mounted) {
                                                    Navigator.pop(c);
                                                  }
                                                  if (mounted) {
                                                    ScaffoldMessenger.of(context).showSnackBar(
                                                      SnackBar(
                                                        content: const Text('다운로드를 시작했습니다'),
                                                        // 액션이 있는 스낵바는 기본으로 자동으로 닫히지 않음 → 3초 후 닫히게
                                                        persist: false,
                                                        duration: const Duration(seconds: 3),
                                                        showCloseIcon: true,
                                                        action: SnackBarAction(
                                                          label: '보기',
                                                          onPressed: () => Navigator.of(context).push(
                                                            MaterialPageRoute<void>(
                                                              builder: (_) => const DownloadsPage(),
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    );
                                                  }
                                                } catch (e) {
                                                  if (mounted) {
                                                    ScaffoldMessenger.of(
                                                      context,
                                                    ).showSnackBar(SnackBar(content: Text('$e')));
                                                  }
                                                } finally {
                                                  _preparingDownload = false;
                                                  if (c.mounted) {
                                                    updateSheet(() {});
                                                  }
                                                }
                                              },
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bookmarked = _bookmarks.contains(_url);
    return TooltipVisibility(
      visible: false,
      child: PopScope(
        canPop: !_canBack,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_navigateHistory(-1));
        },
        child: Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            titleSpacing: 0,
            leading: shouldShowDrawerButton(context)
                ? IconButton(icon: const Icon(Icons.menu), onPressed: widget.onOpenDrawer)
                : null,
            title: Container(
              height: 40,
              margin: const EdgeInsets.only(left: 8),
              decoration: BoxDecoration(
                color: OColors.of(context).surfaceHigh,
                borderRadius: BorderRadius.circular(20),
              ),
              child: TextField(
                controller: _address,
                focusNode: _addressFocus,
                selectAllOnFocus: true,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.go,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  hintText: '주소 또는 검색어',
                  suffixIcon: IconButton(
                    icon: Icon(bookmarked ? Icons.star : Icons.star_border, size: 20),
                    color: bookmarked ? Colors.amber : null,
                    onPressed: _url.isEmpty ? null : _toggleBookmark,
                  ),
                ),
                onSubmitted: _go,
              ),
            ),
            actions: [
              IconButton(icon: const Icon(Icons.bookmarks_outlined), tooltip: '북마크', onPressed: _showBookmarks),
              IconButton(
                icon: const Icon(Icons.download_outlined),
                tooltip: '다운로드 목록',
                onPressed: () =>
                    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DownloadsPage())),
              ),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(2),
              child: _progress < 1
                  ? LinearProgressIndicator(value: _progress, minHeight: 2)
                  : const SizedBox(height: 2),
            ),
          ),
          body: !_envReady || !_historyReady
              ? const SizedBox.shrink()
              : InAppWebView(
                  webViewEnvironment: _env,
                  pullToRefreshController: _pullToRefresh,
                  initialUrlRequest: URLRequest(url: WebUri(_history.current ?? _home)),
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    useOnLoadResource: true,
                    useShouldInterceptRequest: Platform.isAndroid,
                    useHybridComposition: true,
                    mediaPlaybackRequiresUserGesture: false,
                    allowsInlineMediaPlayback: true,
                    isInspectable: false,
                    contentBlockers: pluginContentBlockers(),
                  ),
                  initialUserScripts: UnmodifiableListView([
                    for (final plugin in PluginStore.instance.enabled.where((p) => p.site))
                      UserScript(
                        source: sitePluginScript(plugin),
                        groupName: 'oplayerPlugins',
                        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                        forMainFrameOnly: false,
                      ),
                    UserScript(
                      source: browserInteractionScript,
                      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                      forMainFrameOnly: false,
                    ),
                    UserScript(
                      source: _snifferJs,
                      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                      forMainFrameOnly: false, // iframe 안 플레이어까지
                    ),
                  ]),
                  onWebViewCreated: (c) {
                    _web = c;
                    _attachNetworkMonitor(c);
                    c.addJavaScriptHandler(
                      handlerName: 'oplayerHlsPlaylist',
                      callback: (args) {
                        if (args.length >= 2 && args[0] is String && args[1] is String) {
                          _recordPlaylist(args[0] as String, args[1] as String);
                        }
                        return null;
                      },
                    );
                    c.addJavaScriptHandler(
                      handlerName: 'oplayerHlsKey',
                      callback: (args) {
                        if (args.length < 2 || args[0] is! String || args[1] is! List) {
                          return null;
                        }
                        final url = Uri.tryParse(args[0] as String);
                        final bytes = args[1] as List;
                        if (url == null ||
                            !['http', 'https'].contains(url.scheme) ||
                            bytes.length != 16 ||
                            !bytes.every((v) => v is int && v >= 0 && v <= 255)) {
                          return null;
                        }
                        _hlsKeys[url.toString()] = Uint8List.fromList(bytes.cast<int>());
                        if (_hlsKeys.length > 1024) {
                          _hlsKeys.remove(_hlsKeys.keys.first);
                        }
                        return null;
                      },
                    );
                    c.addJavaScriptHandler(
                      handlerName: 'oplayerHlsPrepareError',
                      callback: (args) {
                        if (args.length >= 2 && args[0] == _preparingUrl) {
                          _keyPreparationError = '${args[1]}';
                        }
                        return null;
                      },
                    );
                    c.addJavaScriptHandler(
                      handlerName: 'oplayerMedia',
                      callback: (args) {
                        if (args.isNotEmpty) {
                          if (args.length > 5 && args[5] is Map) {
                            _capturedHeaders.capture('${args[0]}', args[5] as Map, fallback: true);
                          }
                          _onMedia(
                            '${args[0]}',
                            args.length > 1 ? '${args[1] ?? ''}' : '',
                            args.length > 2 ? '${args[2] ?? ''}' : '',
                            args.length > 3 ? (num.tryParse('${args[3]}') ?? 0).toInt() : 0,
                            args.length > 4 && '${args[4] ?? ''}'.isNotEmpty ? '${args[4]}' : null,
                          );
                        }
                        return null;
                      },
                    );
                  },
                  shouldInterceptRequest: (c, request) async {
                    _capturedHeaders.capture(request.url.toString(), request.headers);
                    if (blockedBySitePlugin(_url, request.url.toString())) {
                      return WebResourceResponse(
                        data: Uint8List(0),
                        contentType: 'text/plain',
                        statusCode: 403,
                        reasonPhrase: 'Blocked by extension',
                      );
                    }
                    return null;
                  },
                  onLoadResource: (c, r) {
                    final u = r.url?.toString();
                    if (u != null &&
                        RegExp(r'\.(m3u8|mpd|mp4|webm|mkv|mov|m4v)(\?|#|$)', caseSensitive: false).hasMatch(u)) {
                      _onMedia(u, _title);
                    }
                  },
                  onLoadStart: (c, url) {
                    setState(() {
                      _url = url?.toString() ?? '';
                      if (!_addressFocus.hasFocus) _address.text = _url;
                      _found.clear(); // 새 페이지
                      _mse = false;
                      _netLog.clear();
                      _pendingBodies.clear();
                      _capturedHeaders.clear();
                      _hlsKeys.clear();
                      _hlsPlaylists.clear();
                    });
                  },
                  onLoadStop: (c, url) async {
                    await _pullToRefresh?.endRefreshing();
                    // 페이지에 따라 document_start 주입이 안 되는 경우 대비
                    await c.evaluateJavascript(source: _snifferJs);
                    await c.evaluateJavascript(source: browserInteractionScript);
                    await _syncHistory(c);
                  },
                  onUpdateVisitedHistory: (c, url, reload) async {
                    await _syncHistory(c, reload: reload ?? false);
                  },
                  onTitleChanged: (c, t) => setState(() => _title = t ?? ''),
                  onReceivedError: (c, request, error) {
                    _logNet(
                      _NetEntry(request.url.toString(), error.description, '로드 실패 · ${error.type}', 0, failed: true),
                    );
                    if (request.isForMainFrame == true) {
                      _pullToRefresh?.endRefreshing();
                    }
                  },
                  onReceivedHttpError: (c, request, response) {
                    _logNet(
                      _NetEntry(
                        request.url.toString(),
                        response.reasonPhrase ?? '',
                        'HTTP ${response.statusCode}',
                        0,
                        failed: true,
                      ),
                    );
                    if (request.isForMainFrame == true) {
                      _pullToRefresh?.endRefreshing();
                    }
                  },
                  onProgressChanged: (c, p) {
                    if (p == 100) _pullToRefresh?.endRefreshing();
                    if (mounted) setState(() => _progress = p / 100);
                  },
                ),
          bottomNavigationBar: SafeArea(
            child: SizedBox(
              height: 52,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new, size: 20),
                    onPressed: _canBack ? () => _navigateHistory(-1) : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.arrow_forward_ios, size: 20),
                    onPressed: _canForward ? () => _navigateHistory(1) : null,
                  ),
                  IconButton(icon: const Icon(Icons.home_outlined), onPressed: () => _go(_home)),
                  GestureDetector(
                    onLongPress: _hardReload,
                    child: IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: '새로고침 (F5) · 길게: 캐시 무시 (Ctrl+F5)',
                      onPressed: _reload,
                    ),
                  ),
                  Badge(
                    isLabelVisible: _found.isNotEmpty,
                    label: Text('${_found.length}'),
                    backgroundColor: OColors.of(context).accent,
                    child: IconButton(
                      icon: Icon(
                        Icons.video_library_outlined,
                        color: _found.isEmpty ? null : OColors.of(context).accent,
                      ),
                      tooltip: '감지된 동영상',
                      onPressed: _showFound,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NetEntry {
  _NetEntry(this.url, this.mime, this.type, this.size, {this.failed = false});
  final String url;
  final String mime;
  final String type;
  final int size;
  final bool failed;
}
