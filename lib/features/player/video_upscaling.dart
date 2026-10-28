import 'dart:math' as math;
import 'package:flutter/painting.dart';

/// Preserve the source aspect ratio; Flutter still owns contain/cover/stretch.
/// Limit additional render targets to 4096 per edge and approximately 4K pixels.
Size? upscaleTarget(Size source, Size viewport, BoxFit fit) {
  if (![source.width, source.height, viewport.width, viewport.height].every((v) => v.isFinite && v > 0)) return null;
  final x = viewport.width / source.width, y = viewport.height / source.height;
  var factor = switch (fit) {
    BoxFit.none || BoxFit.scaleDown => 1.0,
    BoxFit.contain => math.min(x, y),
    BoxFit.cover || BoxFit.fill => math.max(x, y),
    BoxFit.fitWidth => x,
    BoxFit.fitHeight => y,
  };
  factor = math.min(
    factor,
    math.min(4096 / math.max(source.width, source.height), math.sqrt(8294400 / (source.width * source.height))),
  );
  if (factor <= 1) return null;
  final result = Size((source.width * factor).floorToDouble(), (source.height * factor).floorToDouble());
  return result.width <= source.width && result.height <= source.height ? null : result;
}

/// Lanczos is useful only when the GPU renders into a larger output texture.
class VideoUpscaler {
  VideoUpscaler({required this.read, required this.write, required this.resize});
  final Future<String> Function(String) read;
  final Future<void> Function(String, String) write;
  final Future<void> Function(Size?) resize;
  final _original = <String, String>{};
  Future<void> _tail = Future.value();
  Size? _size;
  bool _resizePending = false;
  bool _configured = false;

  Future<void> apply(bool enabled, Size? target) {
    final result = _tail.then((_) => _apply(enabled, target));
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> _set(String key, String value) async {
    await write(key, value);
    if (await read('options/$key') != value) throw UnsupportedError('이 재생 엔진에서는 고화질 업스케일을 지원하지 않습니다');
  }

  Future<void> _resize(Size? target) async {
    if (_size == target && !_resizePending) return;
    // Native outputs can store the requested dimensions before allocation fails.
    _resizePending = true;
    await resize(target);
    _size = target;
    _resizePending = false;
  }

  Future<void> _restore() async {
    _configured = false;
    Object? failure;
    for (final entry in _original.entries) {
      try {
        await _set(entry.key, entry.value);
      } catch (e) {
        failure ??= e;
      }
    }
    try {
      await _resize(null);
    } catch (e) {
      failure ??= e;
    }
    if (failure != null) throw StateError('업스케일 해제·원래 출력 복원에 실패했습니다. 영상을 다시 열어 주세요');
    _original.clear();
  }

  Future<void> _apply(bool enabled, Size? target) async {
    if (!enabled) return _restore();
    if (target != null &&
        (!target.width.isFinite ||
            !target.height.isFinite ||
            target.width <= 0 ||
            target.height <= 0 ||
            target.longestSide > 4096 ||
            target.width * target.height > 8294400)) {
      throw ArgumentError('잘못된 업스케일 출력 크기');
    }
    try {
      if (_original.isEmpty) {
        final values = <String, String>{};
        for (final key in ['scale', 'cscale']) {
          final value = await read('options/$key');
          // An unset cscale inherits scale. Distinguish that valid empty
          // default from an option that does not exist on this engine.
          if (value.isEmpty && (await read('option-info/$key/type')).isEmpty) {
            throw UnsupportedError('현재 재생 엔진은 GPU 업스케일을 지원하지 않습니다');
          }
          values[key] = value;
        }
        _original.addAll(values);
      }
      if (!_configured) {
        await _set('scale', 'lanczos');
        await _set('cscale', 'lanczos');
        _configured = true;
      }
      await _resize(target);
    } catch (_) {
      await _restore();
      rethrow;
    }
  }
}

/// Own only our shader entry; never clear shaders installed by another feature.
class UpscaleShader {
  UpscaleShader(this.command);
  final Future<void> Function(List<String>) command;
  Future<void> _tail = Future.value();
  String? _active;

  Future<void> apply(String? path) {
    final result = _tail.then((_) => _apply(path));
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> _apply(String? path) async {
    if (_active == path) return;
    final previous = _active;
    if (previous != null) await command(['change-list', 'glsl-shaders', 'remove', previous]);
    _active = null;
    try {
      _active = path;
      if (path != null) await command(['change-list', 'glsl-shaders', 'append', path]);
    } catch (_) {
      // An append can mutate the list before a native error is returned.
      if (path != null) await command(['change-list', 'glsl-shaders', 'remove', path]);
      _active = previous;
      if (previous != null) await command(['change-list', 'glsl-shaders', 'append', previous]);
      rethrow;
    }
  }
}
