import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// URL history survives destruction of the native view. Native indices are
/// bindings for this view only; restored entries load on demand, never in a loop.
class BrowserHistory {
  final List<String> _urls = [];
  final Map<int, int> _native = {};
  int _index = -1;
  bool _bindCurrent = true;

  String? get current => _index < 0 ? null : _urls[_index];
  bool get canBack => _index > 0;
  bool get canForward => _index >= 0 && _index + 1 < _urls.length;

  BrowserHistory();

  BrowserHistory.restore(String? encoded) {
    try {
      final data = jsonDecode(encoded ?? '');
      final urls = (data['urls'] as List).cast<String>();
      final index = data['index'] as int;
      if (urls.isEmpty || urls.length > 500 || index < 0 || index >= urls.length || !urls.every(_valid)) return;
      _urls.addAll(urls);
      _index = index;
    } catch (_) {
      // A corrupt/older snapshot falls back to the configured homepage.
    }
  }

  static bool _valid(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && ['http', 'https', 'file', 'about'].contains(uri.scheme) && url.length <= 32768;
  }

  String encode() => jsonEncode({'urls': _urls, 'index': _index});

  void prepareReload() {
    _native.clear();
    _bindCurrent = true;
  }

  /// Returns a native target when that entry still exists in this WebView.
  /// Otherwise the caller loads [current] as a fresh request.
  int? move(int steps) {
    final target = _index + steps;
    if (target < 0 || target >= _urls.length) return null;
    _index = target;
    for (final binding in _native.entries) {
      if (binding.value == target) return binding.key;
    }
    prepareReload();
    return null;
  }

  void record(String url, int nativeIndex, {bool reload = false}) {
    if (!_valid(url) || url == 'about:blank') return;
    final known = _native[nativeIndex];
    if (_bindCurrent && _index >= 0) {
      _urls[_index] = url;
    } else if (known != null && (known == _index || _urls[known] == url)) {
      _index = known;
      _urls[_index] = url;
    } else if (reload && _index >= 0) {
      _urls[_index] = url;
    } else {
      _urls.removeRange(_index + 1, _urls.length);
      _native.removeWhere((_, value) => value > _index);
      _urls.add(url);
      _index++;
    }
    _bindCurrent = false;
    _native[nativeIndex] = _index;
    if (_urls.length > 500) {
      _urls.removeAt(0);
      _index--;
      final bindings = Map<int, int>.from(_native);
      _native.clear();
      for (final entry in bindings.entries) {
        if (entry.value > 0) _native[entry.key] = entry.value - 1;
      }
    }
  }
}

class BrowserHistoryStore {
  static const _key = 'web_navigation_history_v1';
  static Future<void> _writes = Future.value();
  static String? _snapshot;
  static Future<void>? _loading;

  static Future<BrowserHistory> load() async {
    await (_loading ??= SharedPreferences.getInstance().then((prefs) {
      _snapshot = prefs.getString(_key);
    }));
    return BrowserHistory.restore(_snapshot);
  }

  static Future<void> save(BrowserHistory history) {
    final encoded = history.encode();
    _snapshot = encoded;
    // Serialize disk writes across page instances, including rapid menu changes.
    return _writes = _writes.catchError((Object _) {}).then((_) async {
      await (await SharedPreferences.getInstance()).setString(_key, encoded);
    });
  }
}
