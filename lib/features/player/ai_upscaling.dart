import 'dart:async';
import 'dart:ffi';
import 'dart:ui' as ui;

import 'package:ai_frame_engine/engine.dart' as rife;
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import '../../core/settings.dart';

/// A small delayed display queue; mpv continues decoding and owns audio/seek.
class AiUpscaling {
  AiUpscaling({required this.changed});
  final void Function() changed;
  final frame = ValueNotifier<ui.Image?>(null);
  static const delay = Duration(milliseconds: 100);
  Pointer<Void> _engine = nullptr;
  Pointer<Uint8> _pixels = nullptr;
  Pointer<Int> _info = nullptr;
  Pointer<Double> _timing = nullptr;
  Timer? _timer;
  Future<void>? _stopping;
  int _generation = 0;
  bool _decoding = false;
  bool busy = false;
  String? issue;
  double inferenceMs = 0;
  String key = '';
  double _lastPts = -1;
  final _startup = Stopwatch();
  final _stale = Stopwatch();
  bool get running => _engine != nullptr;
  bool get applied => frame.value != null;

  Future<void> start({
    required int handle,
    required String mpvLibrary,
    required String model,
    required String modelKey,
    required int width,
    required int height,
  }) async {
    await stop();
    final generation = ++_generation;
    busy = true;
    key = modelKey;
    issue = null;
    changed();
    try {
      if (generation != _generation) return;
      final library = DynamicLibrary.open(mpvLibrary);
      final modelPath = model.toNativeUtf8();
      try {
        _engine = rife.upscaleStart(
          modelPath.cast(),
          Pointer.fromAddress(handle),
          library.lookup<Void>('mpv_get_property'),
          library.lookup<Void>('mpv_command_ret'),
          library.lookup<Void>('mpv_free_node_contents'),
          width,
          height,
        );
      } finally {
        calloc.free(modelPath);
      }
      if (_engine == nullptr) throw StateError('NPU 업스케일 엔진 시작 실패');
      _pixels = calloc<Uint8>(width * height * 4);
      _info = calloc<Int>(5);
      _timing = calloc<Double>(2);
      _lastPts = -1;
      _startup
        ..reset()
        ..start();
      _stale
        ..reset()
        ..start();
      _timer = Timer.periodic(const Duration(milliseconds: 16), (_) => _poll());
    } catch (e) {
      if (generation != _generation) return;
      issue = 'NPU 업스케일을 시작하지 못했습니다: $e';
      await stop();
    }
  }

  void _poll() {
    if (_engine == nullptr || _decoding) return;
    final result = rife.upscalePoll(
      _engine,
      _pixels,
      _info,
      _timing,
      AppSettings.instance.frameInterpolation && AppSettings.instance.interpolationMode == 'blend' ? 1 : 0,
    );
    if (_info[4] != 0) {
      _stale.reset();
      _startup.reset();
    }
    if (_info[0] == 0 && frame.value != null) {
      _lastPts = -1;
      _replaceImage(null);
      busy = true;
      _startup
        ..reset()
        ..start();
      changed();
    }
    final stalled = applied && _info[4] == 0 && _stale.elapsed > const Duration(seconds: 1);
    if (_info[0] == 2 || result < 0 || stalled || (busy && _startup.elapsed > const Duration(seconds: 30))) {
      final reason = switch (_info[1]) {
        1 => '지원되는 NPU 드라이버 또는 모델 연산이 없습니다',
        2 => 'NPU 업스케일은 1배속 SDR·60fps 이하 입력에서 사용할 수 있습니다',
        3 => 'NPU 업스케일 입력은 1080p 이하 영상에서 사용할 수 있습니다',
        4 => 'NPU 처리 속도가 부족합니다',
        _ => 'NPU 출력이 지연되거나 실패했습니다',
      };
      issue = '$reason · GPU로 재생합니다';
      unawaited(stop());
      changed();
      return;
    }
    if (result != 1 || _lastPts == _timing[1]) return;
    _lastPts = _timing[1];
    _stale
      ..reset()
      ..start();
    inferenceMs = _timing[0];
    final width = _info[2], height = _info[3], generation = _generation;
    final bytes = Uint8List.fromList(_pixels.asTypedList(width * height * 4));
    _decoding = true;
    ui.decodeImageFromPixels(bytes, width, height, ui.PixelFormat.bgra8888, (image) {
      _decoding = false;
      if (generation != _generation) {
        image.dispose();
        return;
      }
      final first = frame.value == null;
      _replaceImage(image);
      busy = false;
      if (first) changed();
    });
  }

  void _replaceImage(ui.Image? image) {
    final old = frame.value;
    frame.value = image;
    if (old != null) SchedulerBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  Future<void> stop() async {
    final wasActive = running || busy || applied;
    ++_generation;
    _timer?.cancel();
    _timer = null;
    busy = false;
    _replaceImage(null);
    if (_stopping != null) return _stopping;
    final engine = _engine;
    _engine = nullptr;
    if (wasActive) changed();
    if (engine == nullptr) return;
    rife.upscaleStop(engine);
    final done = Completer<void>();
    _stopping = done.future;
    // Never block the UI on GPU completion or destroy mpv while capture is alive.
    while (rife.upscaleFinished(engine) == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    rife.upscaleDestroy(engine);
    calloc.free(_pixels);
    calloc.free(_info);
    calloc.free(_timing);
    _pixels = nullptr;
    _info = nullptr;
    _timing = nullptr;
    _stopping = null;
    done.complete();
  }

  Future<void> dispose() async {
    await stop();
    frame.dispose();
  }
}
