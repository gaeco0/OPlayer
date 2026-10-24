import 'dart:async';
import 'package:volume_controller/volume_controller.dart';

/// The OS owns volume. Opening/closing playback must never reset it.
class SystemVolume {
  double? value;
  bool _disposed = false;
  StreamSubscription<double>? _subscription;
  Future<void> _pending = Future.value();
  late final Future<void> ready = _initialize();

  Future<void> _initialize() async {
    if (_disposed) return;
    _subscription = VolumeController.instance.addListener((level) => value = level);
    _subscription!.onError((Object _) {});
    value = await VolumeController.instance.getVolume();
  }

  Future<double> _change(double Function(double) change) {
    final result = _pending.then((_) async {
      try {
        await ready;
      } catch (_) {} // A newly attached output device may now be available.
      if (_disposed) throw StateError('플레이어가 닫혔습니다');
      // Re-read before each input so hardware keys, OS sliders and device changes
      // are respected even when their notification has not reached Dart yet.
      final current = await VolumeController.instance.getVolume();
      if (_disposed) throw StateError('플레이어가 닫혔습니다');
      final next = change(current).clamp(0.0, 1.0);
      await VolumeController.instance.setVolume(next);
      value = next;
      return next;
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<double> set(double level) => _change((_) => level);
  Future<double> adjust(double delta) => _change((current) => current + delta);

  void dispose() {
    _disposed = true;
    _subscription?.cancel();
  }
}
