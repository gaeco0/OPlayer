/// Native mpv temporal frame mixing. Does not change decoding, vf or file FPS.
class FrameInterpolation {
  FrameInterpolation({required this.read, required this.write});
  final Future<String> Function(String) read;
  final Future<void> Function(String, String) write;
  final _original = <String, String>{};
  Future<void> _tail = Future.value();

  /// Serializes rapid toggles/display changes so the last request wins.
  Future<void> apply(bool enabled, double refreshRate) {
    final result = _tail.then((_) => _apply(enabled, refreshRate));
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> _set(String name, String value) async {
    await write(name, value);
    final actual = await read('options/$name');
    final expectedNumber = double.tryParse(value);
    final actualNumber = double.tryParse(actual);
    if (actual != value &&
        (expectedNumber == null || actualNumber == null || (actualNumber - expectedNumber).abs() > .001)) {
      throw UnsupportedError('보간 설정을 적용하지 못했습니다: $name');
    }
  }

  Future<void> _restore() async {
    if (_original.isEmpty) return;
    Object? failure;
    for (final entry in [
      const MapEntry('interpolation', 'no'),
      ..._original.entries.where((e) => e.key != 'interpolation'),
      MapEntry('interpolation', _original['interpolation']!),
    ]) {
      try {
        await _set(entry.key, entry.value);
      } catch (e) {
        failure ??= e;
      }
    }
    if (failure != null) throw StateError('원래 재생 설정을 복원하지 못했습니다: $failure');
    _original.clear();
  }

  Future<void> _apply(bool enabled, double rate) async {
    if (!enabled) return _restore();
    if (!rate.isFinite || rate < 20 || rate > 1000) throw UnsupportedError('화면 주사율을 확인할 수 없습니다');
    if (_original.isEmpty) {
      // Older bundled mpv uses override-display-fps; newer releases renamed it.
      final rateKey = (await read('options/display-fps-override')).isNotEmpty
          ? 'display-fps-override'
          : 'override-display-fps';
      final original = <String, String>{};
      for (final key in [rateKey, 'tscale', 'video-sync', 'interpolation']) {
        final value = await read('options/$key');
        if (value.isEmpty) throw UnsupportedError('현재 재생 엔진은 프레임 혼합을 지원하지 않습니다');
        original[key] = value;
      }
      _original.addAll(original);
    }
    try {
      await _set('interpolation', 'no');
      final rateKey = _original.keys.first;
      await _set(rateKey, rate.toStringAsFixed(6));
      await _set('tscale', 'oversample');
      await _set('video-sync', 'display-resample');
      await _set('interpolation', 'yes');
    } catch (error) {
      try {
        await _restore();
      } catch (_) {
        throw StateError('프레임 혼합 적용·원래 설정 복원에 실패했습니다. 영상을 다시 열어 주세요');
      }
      rethrow;
    }
  }
}
