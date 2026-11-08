import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'browser_history.dart';

class BrowserTab {
  BrowserTab(this.history, {this.title = ''});
  final BrowserHistory history;
  String title;
}

/// Tabs keep independent navigation stacks. Only the selected tab owns a WebView;
/// switching reloads its saved URL, as returning from another app menu does.
class BrowserTabs {
  BrowserTabs(BrowserHistory history) : tabs = [BrowserTab(history)];
  final List<BrowserTab> tabs;
  int selected = 0;
  BrowserTab get active => tabs[selected];
  bool get canCloseOnBack => selected > 0 && !active.history.canBack;

  bool closeOnBack() {
    if (!canCloseOnBack) return false;
    final previous = selected - 1;
    close(selected);
    selected = previous;
    return true;
  }

  static BrowserTabs? restore(String? encoded) {
    try {
      final data = jsonDecode(encoded!);
      final saved = data['tabs'] as List;
      final index = data['selected'] as int;
      if (saved.isEmpty || saved.length > 32 || index < 0 || index >= saved.length) return null;
      final result = BrowserTabs(BrowserHistory())..tabs.clear();
      for (final tab in saved) {
        result.tabs.add(BrowserTab(BrowserHistory.restore(tab['history'] as String), title: tab['title'] as String));
      }
      result.selected = index;
      return result;
    } catch (_) {
      return null;
    }
  }

  String encode() => jsonEncode({
    'selected': selected,
    'tabs': [
      for (final tab in tabs) {'history': tab.history.encode(), 'title': tab.title},
    ],
  });

  bool add(String url) {
    if (tabs.length >= 32) return false;
    tabs.add(BrowserTab(BrowserHistory()..record(url, 0)));
    selected = tabs.length - 1;
    return true;
  }

  void close(int index) {
    tabs.removeAt(index);
    if (tabs.isEmpty) tabs.add(BrowserTab(BrowserHistory()));
    if (index < selected || selected >= tabs.length) selected--;
    if (selected < 0) selected = 0;
  }
}

class BrowserTabsStore {
  static const _key = 'web_tabs_v1';
  static String? _snapshot;
  static Future<void>? _loading;
  static Future<void> _writes = Future.value();

  static Future<BrowserTabs> load() async {
    await (_loading ??= SharedPreferences.getInstance().then((prefs) {
      _snapshot = prefs.getString(_key);
    }));
    return BrowserTabs.restore(_snapshot) ?? BrowserTabs(await BrowserHistoryStore.load());
  }

  static Future<void> save(BrowserTabs tabs) {
    final snapshot = tabs.encode();
    _snapshot = snapshot;
    return _writes = _writes.catchError((Object _) {}).then((_) async {
      await (await SharedPreferences.getInstance()).setString(_key, snapshot);
    });
  }
}
