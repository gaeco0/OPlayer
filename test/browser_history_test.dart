import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:oplayer/features/web/browser_history.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const a = 'https://example.com/a';
  const b = 'https://example.com/b';
  const c = 'https://example.com/c';
  const d = 'https://example.com/d';

  test('restores current position with both backward and forward entries', () {
    final history = BrowserHistory()
      ..record(a, 0)
      ..record(b, 1)
      ..record(c, 2);
    expect(history.move(-1), 1);
    final restored = BrowserHistory.restore(history.encode());
    expect(restored.current, b);
    expect(restored.canBack, isTrue);
    expect(restored.canForward, isTrue);
    restored.record(b, 0); // Only the current page loads in the new view.
    expect(restored.move(-1), isNull);
    expect(restored.current, a);
    restored.record(a, 1);
    expect(restored.move(1), isNull);
    expect(restored.current, b);
    restored.record(b, 2);
    expect(restored.move(1), isNull);
    expect(restored.current, c);
  });

  test('reloads, redirects and repeated load-stop events replace current entry', () {
    final history = BrowserHistory()
      ..record(a, 0)
      ..record(b, 1);
    history.record(c, 1);
    history.record(c, 1, reload: true);
    history.record(c, 1);
    expect(history.current, c);
    history.move(-1);
    expect(history.current, a);
    expect(history.canBack, isFalse);
  });

  test('new navigation after back discards forward entries, including native index reuse', () {
    final history = BrowserHistory()
      ..record(a, 0)
      ..record(b, 1)
      ..record(c, 2);
    history.record(b, 1); // Native history.back(), including SPA navigation.
    history.record(d, 2);
    expect(history.current, d);
    expect(history.canForward, isFalse);
    history.move(-1);
    expect(history.current, b);
    history.move(1);
    expect(history.current, d);
  });

  test('new navigation after a restored back visit discards saved forward stack', () {
    final history = BrowserHistory()
      ..record(a, 0)
      ..record(b, 1)
      ..record(c, 2);
    final restored = BrowserHistory.restore(history.encode());
    restored.record(c, 0);
    restored.move(-1);
    restored.record(b, 1);
    restored.record(d, 2);
    expect(restored.current, d);
    expect(restored.canForward, isFalse);
    restored.move(-1);
    expect(restored.current, b);
    restored.move(-1);
    expect(restored.current, a);
  });

  test('same-URL pushState adds an entry, replaceState keeps its position', () {
    final history = BrowserHistory()
      ..record(a, 0)
      ..record(a, 1);
    expect(history.canBack, isTrue);
    history.record(b, 1);
    history.move(-1);
    expect(history.current, a);
    expect(history.canBack, isFalse);
  });

  test('invalid snapshots fall back to homepage, old entries are bounded', () {
    for (final encoded in [null, '', '{}', '{"urls": [1], "index": 0}', '{"urls": ["javascript:x"], "index":0}']) {
      expect(BrowserHistory.restore(encoded).current, isNull);
    }
    final history = BrowserHistory();
    for (var i = 0; i < 510; i++) {
      history.record('https://example.com/$i', i);
    }
    expect((jsonDecode(history.encode())['urls'] as List).length, 500);
    for (var i = 0; i < 499; i++) {
      history.move(-1);
    }
    expect(history.current, 'https://example.com/10');
    expect(history.canBack, isFalse);
  });

  test('rapid menu return and queued persistence preserve latest current index', () async {
    SharedPreferences.setMockInitialValues({});
    final history = await BrowserHistoryStore.load();
    history.record(a, 0);
    final first = BrowserHistoryStore.save(history);
    history.record(b, 1);
    final second = BrowserHistoryStore.save(history);
    final reopened = await BrowserHistoryStore.load();
    expect(reopened.current, b);
    reopened.move(-1);
    await BrowserHistoryStore.save(reopened);
    await Future.wait([first, second]);
    final encoded = (await SharedPreferences.getInstance()).getString('web_navigation_history_v1');
    expect(BrowserHistory.restore(encoded).current, a);
    expect(BrowserHistory.restore(encoded).canForward, isTrue);
  });
}
