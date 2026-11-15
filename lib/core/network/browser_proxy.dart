import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// null means this engine has no ProxyOverride API (for example, WebView2
/// takes its proxy through its environment). false means an outdated engine
/// implements the API but cannot enable the requested feature.
Future<bool?> browserProxyOverrideSupport() async {
  if (InAppWebViewPlatform.instance == null) return null;
  try {
    return await WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE);
  } on UnimplementedError {
    return null;
  } on UnsupportedError {
    return null;
  } on MissingPluginException {
    return null;
  }
}

Future<void> configureBrowserProxy({String? url, bool clear = false}) async {
  if (url != null) {
    await ProxyController.instance().setProxyOverride(
      settings: ProxySettings(
        proxyRules: [ProxyRule(url: url)],
        bypassRules: const ['localhost', '127.0.0.1', '[::1]', '*.local', '*.lan', '*.home.arpa'],
        bypassSimpleHostnames: true,
      ),
    );
  } else if (clear) {
    await ProxyController.instance().clearProxyOverride();
  }
}
