import 'package:flutter_test/flutter_test.dart';
import 'package:oplayer/features/web/external_links.dart';

void main() {
  test('custom app and magnet URLs leave the browser; web and document URLs stay inside', () {
    for (final url in [
      'magnet:?xt=urn:btih:123456&dn=example',
      'intent://watch/123#Intent;scheme=example;package=com.example;end',
      'exampleapp://watch/123',
      'mailto:test@example.com',
      'tel:12345',
      'market://details?id=com.example',
    ]) {
      expect(isExternalBrowserLink(Uri.parse(url)), isTrue, reason: url);
    }
    for (final url in [
      'https://example.com',
      'http://example.com',
      '/relative',
      'about:blank',
      'javascript:alert(1)',
      'vbscript:test',
      'data:text/plain,hello',
      'blob:https://example.com/id',
      'file:///private/file',
      'content://private/file',
    ]) {
      expect(isExternalBrowserLink(Uri.parse(url)), isFalse, reason: url);
    }
  });

  test('intent fallback accepts only a valid HTTP(S) URL and decodes it once', () {
    Uri intent(String fallback) =>
        Uri.parse('intent://watch#Intent;scheme=example;S.browser_fallback_url=${Uri.encodeComponent(fallback)};end');
    const fallback = 'https://example.com/watch?q=a%20b&next=1';
    expect(intentBrowserFallback(intent(fallback)).toString(), fallback);
    expect(intentBrowserFallback(Uri.parse('magnet:?xt=urn:btih:123')), isNull);
    expect(intentBrowserFallback(Uri.parse('intent://watch#Intent;scheme=example;end')), isNull);
    for (final url in [
      'javascript:alert(1)',
      'file:///private/file',
      'example://app',
      'intent://loop',
      'https:///missing-host',
      'https://user:pass@example.com',
    ]) {
      expect(intentBrowserFallback(intent(url)), isNull, reason: url);
    }
    expect(intentBrowserFallback(Uri.parse('intent://watch#Intent;S.browser_fallback_url=%ZZ;end')), isNull);
  });
}
