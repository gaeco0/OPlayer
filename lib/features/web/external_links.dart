import 'dart:io';

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

bool isExternalBrowserLink(Uri uri) =>
    uri.hasScheme &&
    !const ['http', 'https', 'about', 'data', 'blob', 'file', 'content', 'javascript', 'vbscript'].contains(uri.scheme);

Uri? intentBrowserFallback(Uri uri) {
  if (uri.scheme != 'intent') return null;
  final match = RegExp(r'(?:#Intent;|;)S\.browser_fallback_url=([^;]*)(?:;|$)').firstMatch(uri.toString());
  if (match == null) return null;
  try {
    final fallback = Uri.parse(Uri.decodeComponent(match[1]!));
    return ['http', 'https'].contains(fallback.scheme) && fallback.host.isNotEmpty && fallback.userInfo.isEmpty
        ? fallback
        : null;
  } on FormatException {
    return null;
  }
}

Future<bool> openExternalBrowserLink(Uri uri) async {
  if (!isExternalBrowserLink(uri)) return false;
  if (Platform.isAndroid && uri.scheme == 'intent') {
    return await const MethodChannel('oplayer/externalLinks').invokeMethod<bool>('openIntent', uri.toString()) ?? false;
  }
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}
