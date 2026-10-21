/// Keeps request headers together even when DevTools sends ExtraInfo first.
class BrowserRequestHeaders {
  final _urls = <String, Map<String, String>>{};
  final _requests = <String, List<Map<String, String>>>{};
  final _extras = <String, List<Map<String, String>>>{};
  final _native = <String>{};

  Map<String, String>? forUrl(String url) => _urls[url];
  bool hasNative(String url) => _native.contains(url);
  Map<String, Map<String, String>> snapshot() => {for (final e in _urls.entries) e.key: Map.of(e.value)};

  void clear() {
    _urls.clear();
    _requests.clear();
    _extras.clear();
    _native.clear();
  }

  void capture(String url, Map? headers, {bool fallback = false}) {
    if (headers == null || headers.isEmpty) return;
    final h = _normalize(headers);
    if (fallback && _native.contains(url)) return;
    _urls[url] = h;
    if (!fallback) _native.add(url);
    _trim();
  }

  void request(String id, String url, Map? headers) {
    final requests = _requests.putIfAbsent(id, () => []);
    final h = _normalize(headers ?? const {});
    requests.add(h);
    final extras = _extras[id];
    if (extras != null && extras.length >= requests.length) {
      h.addAll(extras[requests.length - 1]);
    }
    _urls[url] = h;
    _native.add(url);
    _trim();
  }

  void extra(String id, Map? headers) {
    final extras = _extras.putIfAbsent(id, () => []);
    extras.add(_normalize(headers ?? const {}));
    final requests = _requests[id];
    if (requests != null && requests.length >= extras.length) {
      requests[extras.length - 1].addAll(extras.last);
    }
    _trim();
  }

  void _trim() {
    if (_urls.length > 600) {
      _native.remove(_urls.keys.first);
      _urls.remove(_urls.keys.first);
    }
    if (_requests.length > 1500) {
      _extras.remove(_requests.keys.first);
      _requests.remove(_requests.keys.first);
    }
    if (_extras.length > 1500) _extras.remove(_extras.keys.first);
  }

  static Map<String, String> _normalize(Map headers) => {
    for (final e in headers.entries) '${e.key}'.toLowerCase(): '${e.value}',
  };

  /// Transport, range and cache headers must be chosen for the new request.
  static Map<String, String> replay(Map<String, String> headers) {
    const drop = {
      'host',
      'range',
      'content-length',
      'connection',
      'accept-encoding',
      'if-range',
      'if-none-match',
      'if-modified-since',
      'upgrade-insecure-requests',
      'te',
      'trailer',
      'transfer-encoding',
      'proxy-connection',
      'keep-alive',
    };
    return {
      for (final e in headers.entries)
        if (!e.key.startsWith(':') && !drop.contains(e.key.toLowerCase()))
          e.key.split('-').map((s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).toLowerCase()).join('-'):
              e.value,
    };
  }
}
