import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter/services.dart';
import '../../core/network/network_service.dart';

Future<WebViewEnvironment?>? _environment;
Future<WebViewEnvironment?> browserEnvironment() => _environment ??= _createEnvironment();

Future<WebViewEnvironment?> _createEnvironment() async {
  if (InAppWebViewPlatform.instance == null) return null;
  try {
    return await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        additionalBrowserArguments:
            '--disable-site-isolation-trials --disable-features=IsolateOrigins,site-per-process '
            '${NetworkService.instance.proxyUrl == null ? '' : '--proxy-server=${NetworkService.instance.proxyUrl} --disable-quic'}',
      ),
    );
  } on UnimplementedError {
    return null;
  } on UnsupportedError {
    return null;
  } on MissingPluginException {
    return null;
  }
}

/// Prefer each engine's supported cache-bypass API without naming an OS.
Future<void> reloadBrowserIgnoringCache(InAppWebViewController controller) async {
  try {
    await controller.callDevToolsProtocolMethod(methodName: 'Network.clearBrowserCache');
    await controller.callDevToolsProtocolMethod(methodName: 'Page.reload', parameters: {'ignoreCache': true});
    return;
  } on UnimplementedError {
    // Try the next engine API.
  } on UnsupportedError {
    // Try the next engine API.
  } on MissingPluginException {
    // Try the next engine API.
  }
  try {
    await controller.reloadFromOrigin();
    return;
  } on UnimplementedError {
    // Try the next engine API.
  } on UnsupportedError {
    // Try the next engine API.
  } on MissingPluginException {
    // Try the next engine API.
  }
  await InAppWebViewController.clearAllCache();
  await controller.reload();
}
