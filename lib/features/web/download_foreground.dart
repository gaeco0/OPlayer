import 'dart:async';

import 'package:flutter/services.dart';

/// Serializes service commands so an old progress update cannot restart a stopped service.
class DownloadForeground {
  DownloadForeground({required this.onPause, required this.onOpen, required this.onError}) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'pause') onPause(null);
      if (call.method == 'timeout') onPause('Android 백그라운드 실행 시간 제한으로 일시정지했습니다. 앱에서 다시 시작해 주세요.');
      if (call.method == 'open') onOpen();
    });
  }
  static const _channel = MethodChannel('oplayer/downloads');
  final void Function(String? reason) onPause;
  final void Function() onOpen;
  final void Function(Object error) onError;
  Future<void> _tail = Future.value();
  Timer? _timer;
  Map<String, Object?>? _pending;

  Future<void> _send(String method, Map<String, Object?> state) {
    final result = _tail.then(
      (_) => _channel.invokeMethod<void>(method, state).timeout(const Duration(seconds: 10)),
    );
    _tail = result.catchError((Object _) {});
    return result;
  }

  Future<void> update(Map<String, Object?> state) {
    _timer?.cancel();
    _timer = null;
    _pending = null;
    return _send('update', state);
  }

  void schedule(Map<String, Object?> state) {
    _pending = state;
    if (state['active'] != true) {
      unawaited(update(state).catchError(onError));
      return;
    }
    _timer ??= Timer(const Duration(seconds: 1), () {
      _timer = null;
      final latest = _pending;
      _pending = null;
      if (latest != null) unawaited(update(latest).catchError(onError));
    });
  }

  Future<void> finished({required String id, required String name, required bool success}) =>
      _send('finished', {'id': id, 'name': name, 'success': success});

  Future<bool> consumeOpen() async => await _channel.invokeMethod<bool>('consumeOpen') ?? false;
}
