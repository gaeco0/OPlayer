import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

/// Mirrors Android's app-approved CA anchors without weakening TLS validation.
/// Contexts are replaced on change so removed CAs do not accumulate over time.
class AndroidTrustStore {
  AndroidTrustStore({bool? enabled}) : enabled = enabled ?? Platform.isAndroid;
  final bool enabled;
  static const channel = MethodChannel('oplayer/network-trust');
  SecurityContext? context;
  String? _pem;
  Future<bool>? _refreshing;

  Future<bool> refresh() => _refreshing ??= _load().whenComplete(() => _refreshing = null);

  Future<bool> _load() async {
    if (!enabled) return false;
    try {
      final pem = await channel.invokeMethod<String>('certificates');
      if (pem == null || pem.trim().isEmpty) throw StateError('Android CA 목록을 읽지 못했습니다');
      if (pem == _pem) return false;
      // The native list contains both system and approved user roots. Do not
      // merge into defaultContext, which cannot remove subsequently deleted CAs.
      final next = SecurityContext(withTrustedRoots: false);
      next.setTrustedCertificatesBytes(utf8.encode(pem));
      context = next;
      _pem = pem;
      return true;
    } catch (_) {
      context = null;
      _pem = null;
      rethrow;
    }
  }
}
