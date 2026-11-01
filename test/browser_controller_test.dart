import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oplayer/features/web/browser_interactions.dart';

class _PlatformController extends Fake implements PlatformInAppWebViewController {}

void main() {
  test('creation and navigation wrappers for one native view are accepted; closed views are rejected', () {
    final platform = _PlatformController();
    final created = InAppWebViewController.fromPlatform(platform: platform);
    final callback = InAppWebViewController.fromPlatform(platform: platform);
    expect(identical(created, callback), isFalse);
    expect(isSameBrowserView(callback, created), isTrue);
    final nextTab = InAppWebViewController.fromPlatform(platform: _PlatformController());
    expect(isSameBrowserView(callback, nextTab), isFalse);
    expect(isSameBrowserView(callback, null), isFalse);
  });
}
