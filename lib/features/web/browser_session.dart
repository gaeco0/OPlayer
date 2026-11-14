import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// One native browser instance, shared by the visible page and media consumers.
/// Removing the widget must not destroy cookies, TLS connections or fetch readers.
class BrowserSession {
  static final _pages = <String, BrowserSession>{};
  static BrowserSession? find(String page) => _pages[page];

  final keepAlive = InAppWebViewKeepAlive();
  InAppWebViewController? _controller;
  Future<void>? _detaching;
  bool _attached = true;
  bool _disposed = false;
  Object? _failure;
  int _users = 0;
  bool get inUse => _users > 0;

  void attach(InAppWebViewController controller) => _controller = controller;

  void remember(String page) {
    if (_attached && !_disposed) _pages[page] = this;
  }

  void forgetPages() => _pages.removeWhere((_, session) => identical(session, this));

  void retain() {
    if (_disposed) throw StateError('브라우저 세션이 종료됐습니다');
    _users++;
  }

  Future<InAppWebViewController> get controller async {
    await _detaching;
    if (_failure != null) throw StateError('브라우저 세션 유지 실패: $_failure');
    if (_disposed || _controller == null) throw StateError('브라우저 세션이 종료됐습니다');
    return _controller!;
  }

  /// The plugin disposes the widget's Dart controller even with keepAlive.
  /// Rebind only after that disposal, to the same retained native view ID.
  void detach() {
    if (!_attached) return;
    _attached = false;
    forgetPages();
    final id = _controller?.getViewId();
    if (id == null) {
      _disposed = true;
      return;
    }
    final done = Completer<void>();
    _detaching = done.future;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (_users > 0) {
          _controller = InAppWebViewController.fromPlatformCreationParams(
            params: PlatformInAppWebViewControllerCreationParams(id: id),
          );
        } else {
          await _dispose();
        }
      } catch (error) {
        _failure = error;
      } finally {
        done.complete();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> release() async {
    if (_users > 0) _users--;
    if (!_attached && _users == 0) {
      await _detaching;
      await _dispose();
    }
  }

  Future<void> _dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await InAppWebViewController.disposeKeepAlive(keepAlive);
    } finally {
      _controller?.dispose();
      _controller = null;
    }
  }
}
