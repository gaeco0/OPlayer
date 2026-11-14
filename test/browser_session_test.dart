import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:oplayer/features/web/browser_download_transport.dart';
import 'package:oplayer/features/web/browser_session.dart';

class _Engine extends InAppWebViewPlatform {
  final attachedIds = <dynamic>[];
  final requests = <Map<String, dynamic>>[];
  final cancelled = <String>[];
  int disposals = 0;
  @override
  PlatformInAppWebViewController createPlatformInAppWebViewController(
    PlatformInAppWebViewControllerCreationParams params,
  ) {
    attachedIds.add(params.id);
    return _Controller(params, this);
  }

  @override
  PlatformInAppWebViewController createPlatformInAppWebViewControllerStatic() =>
      _Controller(const PlatformInAppWebViewControllerCreationParams(id: null), this);
}

class _Controller extends PlatformInAppWebViewController {
  _Controller(super.params, this.engine) : super.implementation();
  final _Engine engine;
  @override
  void dispose({bool isKeepAlive = false}) {}
  @override
  dynamic getViewId() => params.id;
  @override
  Future<void> disposeKeepAlive(InAppWebViewKeepAlive keepAlive) async => engine.disposals++;
  @override
  Future<CallAsyncJavaScriptResult?> callAsyncJavaScript({
    required String functionBody,
    Map<String, dynamic> arguments = const {},
    ContentWorld? contentWorld,
  }) async {
    if (arguments.containsKey('url')) {
      engine.requests.add(arguments);
      return CallAsyncJavaScriptResult(value: {'status': 200, 'url': arguments['url'], 'headers': {}}, error: null);
    }
    if (arguments['ids'] case final List ids) engine.cancelled.addAll(ids.cast<String>());
    return CallAsyncJavaScriptResult(value: {'done': true}, error: null);
  }
}

void main() {
  testWidgets('queued media retains the original native view after closing its tab; last user disposes it', (
    tester,
  ) async {
    final engine = _Engine();
    InAppWebViewPlatform.instance = engine;
    final session = BrowserSession();
    session.attach(
      InAppWebViewController.fromPlatformCreationParams(
        params: const PlatformInAppWebViewControllerCreationParams(id: 'original-view'),
      ),
    );
    session.remember('https://page.example/watch');
    final first = BrowserDownloadTransport('https://page.example/watch');
    final second = BrowserDownloadTransport('https://page.example/watch');
    expect(session.inUse, true);
    final uri = Uri.parse('https://cdn.example/video.mp4');
    await first.open(uri, const {});
    await second.open(uri, const {});
    expect(engine.requests[0]['id'], isNot(engine.requests[1]['id']));
    session.detach();
    expect(BrowserSession.find('https://page.example/watch'), isNull);
    await tester.pump();
    await session.controller;
    expect(engine.attachedIds, ['original-view', 'original-view']);
    expect(engine.disposals, 0);
    await first.close();
    expect(engine.cancelled, [engine.requests.first['id']]);
    expect(engine.disposals, 0);
    final response = await second.open(uri, const {'Range': 'bytes=4-'}, method: 'HEAD');
    expect(
      await response.body.fold<BytesBuilder>(BytesBuilder(), (b, bytes) => b..add(bytes)).then((b) => b.length),
      0,
    );
    await second.close();
    expect(engine.disposals, 1);
    await second.close();
    expect(engine.disposals, 1);
  });
}
