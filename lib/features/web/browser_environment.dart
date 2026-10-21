import 'dart:io';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../../core/network/network_service.dart';

Future<WebViewEnvironment?>? _environment;
Future<WebViewEnvironment?> browserEnvironment() async {
  if (!Platform.isWindows) return null;
  return _environment ??= WebViewEnvironment.create(
    settings: WebViewEnvironmentSettings(
      additionalBrowserArguments:
          '--disable-site-isolation-trials --disable-features=IsolateOrigins,site-per-process '
          '${NetworkService.instance.proxyUrl == null ? '' : '--proxy-server=${NetworkService.instance.proxyUrl} --disable-quic'}',
    ),
  );
}
