import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/features/web/browser_history.dart';
import 'package:oplayer/features/web/browser_tabs.dart';

void main() {
  const a = 'https://example.com/a';
  const b = 'https://example.com/b';
  const home = 'https://example.com/';

  test('clear keeps only current URL, drops both directions and rebinds the new WebView', () {
    final history = BrowserHistory()
      ..record(a, 0)
      ..record(b, 1)
      ..record(home, 2);
    history.move(-1);
    history.clearNavigation();
    expect(history.current, b);
    expect(history.canBack, isFalse);
    expect(history.canForward, isFalse);
    final restored = BrowserHistory.restore(history.encode());
    restored.record(b, 0);
    expect(restored.canBack, isFalse);
    restored.record(home, 1);
    expect(restored.canBack, isTrue);
    restored.move(-1);
    expect(restored.current, b);
    expect(restored.canBack, isFalse);
  });

  test('tabs restore independently and clearing one leaves other navigation and titles intact', () {
    final tabs = BrowserTabs(
      BrowserHistory()
        ..record(a, 0)
        ..record(b, 1),
    );
    tabs.active.title = 'First';
    tabs.add(home);
    tabs.active.history.prepareReload();
    tabs.active.history.record(home, 0);
    expect(tabs.active.history.canBack, isFalse);
    tabs.active.history.record(a, 1);
    tabs.active.title = 'Second';
    tabs.selected = 0;
    tabs.active.history.clearNavigation();
    final restored = BrowserTabs.restore(tabs.encode())!;
    expect(restored.selected, 0);
    expect(restored.active.history.current, b);
    expect(restored.active.history.canBack, isFalse);
    expect(restored.active.title, 'First');
    restored.selected = 1;
    expect(restored.active.title, 'Second');
    expect(restored.active.history.current, a);
    restored.active.history.move(-1);
    expect(restored.active.history.current, home);
  });

  test('closing an inactive tab preserves active identity; closing last creates a fresh tab', () {
    final tabs = BrowserTabs(BrowserHistory()..record(a, 0));
    tabs.add(b);
    tabs.add(home);
    final active = tabs.active;
    tabs.close(0);
    expect(tabs.selected, 1);
    expect(tabs.active, same(active));
    tabs.close(1);
    expect(tabs.selected, 0);
    expect(tabs.active.history.current, b);
    tabs.close(0);
    expect(tabs.tabs, hasLength(1));
    expect(tabs.selected, 0);
    expect(tabs.active.history.current, isNull);
    expect(tabs.active.history.canBack, isFalse);
  });

  test('invalid sessions fall back and tab limit does not change selection or data', () {
    for (final value in [null, '', '{}', '{"tabs":[],"selected":0}', '{"tabs":[{}],"selected":5}']) {
      expect(BrowserTabs.restore(value), isNull);
    }
    final tabs = BrowserTabs(BrowserHistory());
    for (var i = 1; i < 32; i++) {
      expect(tabs.add('$home$i'), isTrue);
    }
    final snapshot = tabs.encode();
    expect(tabs.add(a), isFalse);
    expect(tabs.encode(), snapshot);
  });

  test(
    'migrates old stack and persists tab changes across rapid menu return without resurrecting closed tabs',
    () async {
      final legacy = BrowserHistory()
        ..record(a, 0)
        ..record(b, 1);
      SharedPreferences.setMockInitialValues({'web_navigation_history_v1': legacy.encode()});
      final tabs = await BrowserTabsStore.load();
      expect(tabs.tabs, hasLength(1));
      expect(tabs.active.history.current, b);
      expect(tabs.active.history.canBack, isTrue);
      tabs.add(home);
      final first = BrowserTabsStore.save(tabs);
      final reopened = await BrowserTabsStore.load();
      expect(reopened.tabs, hasLength(2));
      expect(reopened.selected, 1);
      reopened.close(0);
      final second = BrowserTabsStore.save(reopened);
      await Future.wait([first, second]);
      final stored = (await SharedPreferences.getInstance()).getString('web_tabs_v1');
      final restored = BrowserTabs.restore(stored)!;
      expect(restored.tabs, hasLength(1));
      expect(restored.active.history.current, home);
      expect(restored.active.history.canBack, isFalse);
    },
  );
}
