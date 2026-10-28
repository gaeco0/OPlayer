import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ai_frame_engine/engine.dart' as rife;
import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// A small delayed display queue; mpv continues decoding and owns audio/seek.
class AiInterpolation {
  AiInterpolation({required this.changed});
  final void Function() changed;
  final frame = ValueNotifier<ui.Image?>(null);
  static const delay = Duration(milliseconds: 250);
  static Future<String>? _model;
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
  double _lastPts = -1;
  final _startup = Stopwatch();
  final _stale = Stopwatch();
  bool get running => _engine != nullptr;
  bool get applied => frame.value != null;

  static Future<String> _prepareModel() async {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/ai-interpolation/rife-v4.6');
    await dir.create(recursive: true);
    const hashes = {
      'flownet.param': '724569596bcd1e7b9fa50455c604777ebed99746d2ef40aa86e31b5725f1053c',
      'flownet.bin': 'f334ed2260149ce0188a6dcf049844e8b0cdd912e01cbcfb63553157d2508958',
    };
    for (final entry in hashes.entries) {
      final file = File('${dir.path}/${entry.key}');
      if (await file.exists() && sha256.convert(await file.readAsBytes()).toString() == entry.value) continue;
      final asset = await rootBundle.load('assets/models/rife-v4.6/${entry.key}');
      final bytes = asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes);
      if (sha256.convert(bytes).toString() != entry.value) throw StateError('AI 보간 모델 검증 실패');
      await file.writeAsBytes(bytes, flush: true);
    }
    return dir.path;
  }

  Future<void> start({required int handle, required String mpvLibrary}) async {
    await stop();
    final generation = ++_generation;
    busy = true;
    issue = null;
    changed();
    try {
      final path = await (_model ??= _prepareModel().catchError((Object e) {
        _model = null;
        throw e;
      }));
      if (generation != _generation) return;
      final library = DynamicLibrary.open(mpvLibrary);
      final modelPath = path.toNativeUtf8();
      try {
        _engine = rife.start(
          modelPath.cast(),
          Pointer.fromAddress(handle),
          library.lookup<Void>('mpv_get_property'),
          library.lookup<Void>('mpv_command_ret'),
          library.lookup<Void>('mpv_free_node_contents'),
        );
      } finally {
        calloc.free(modelPath);
      }
      if (_engine == nullptr) throw StateError('AI 보간 엔진 시작 실패');
      _pixels = calloc<Uint8>(320 * 320 * 4);
      _info = calloc<Int>(6);
      _timing = calloc<Double>(2);
      _lastPts = -1;
      _startup
        ..reset()
        ..start();
      _stale
        ..reset()
        ..start();
      _timer = Timer.periodic(const Duration(milliseconds: 8), (_) => _poll());
    } catch (e) {
      if (generation != _generation) return;
      issue = 'AI 보간을 시작하지 못했습니다: $e';
      busy = false;
      changed();
    }
  }

  void _poll() {
    if (_engine == nullptr || _decoding) return;
    final result = rife.poll(_engine, _pixels, _info, _timing);
    if (_info[5] != 0) {
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
    final stalled = applied && _info[5] == 0 && _stale.elapsed > const Duration(seconds: 1);
    if (_info[0] == 2 || result < 0 || stalled || (busy && _startup.elapsed > const Duration(seconds: 30))) {
      final reason = switch (_info[1]) {
        1 => '모델을 읽지 못했습니다',
        2 => '현재 영상 출력에서 프레임을 가져올 수 없습니다',
        4 => 'AI 보간은 1배속에서 사용할 수 있습니다',
        5 => '기기의 처리 속도가 부족합니다',
        6 => '다른 플레이어에서 AI 보간 엔진을 사용 중입니다',
        7 => 'AI 보간은 10~60fps 입력 영상에서 사용할 수 있습니다',
        _ => '프레임 생성이 지연되거나 실패했습니다',
      };
      issue = '$reason · 원본 영상으로 재생합니다';
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
    final width = _info[3], height = _info[4], generation = _generation;
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
    ++_generation;
    _timer?.cancel();
    _timer = null;
    busy = false;
    _replaceImage(null);
    if (_stopping != null) return _stopping;
    final engine = _engine;
    _engine = nullptr;
    changed();
    if (engine == nullptr) return;
    rife.stop(engine);
    final done = Completer<void>();
    _stopping = done.future;
    // Never block the UI on GPU completion or destroy mpv while capture is alive.
    while (rife.finished(engine) == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    rife.destroy(engine);
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
