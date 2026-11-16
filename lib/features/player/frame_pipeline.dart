import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../../core/plugins/pixel_program.dart';

final _pixelShader = ui.FragmentProgram.fromAsset('shaders/pixel_program.frag');

/// Same extension instruction stream as mpv, on native AI output images.
/// Each pass consumes the previous pass, so independent plugins compose too.
Future<ui.Image> renderFramePrograms(ui.Image source, List<PixelProgram> programs) async {
  var current = source.clone();
  try {
    if (programs.isEmpty) return current;
    final compiled = await _pixelShader;
    for (final program in programs) {
      final shader = compiled.fragmentShader();
      ui.Picture? picture;
      try {
        shader.setFloat(0, current.width.toDouble());
        shader.setFloat(1, current.height.toDouble());
        shader.setFloat(2, program.code.length.toDouble());
        final uniforms = program.uniforms;
        for (var i = 0; i < uniforms.length; i++) {
          shader.setFloat(i + 3, uniforms[i]);
        }
        shader.setImageSampler(0, current);
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder).drawRect(
          ui.Rect.fromLTWH(0, 0, current.width.toDouble(), current.height.toDouble()),
          ui.Paint()..shader = shader,
        );
        picture = recorder.endRecording();
        final next = await picture.toImage(current.width, current.height);
        current.dispose();
        current = next;
      } finally {
        picture?.dispose();
        shader.dispose();
      }
    }
    return current;
  } catch (_) {
    current.dispose();
    rethrow;
  }
}

/// One render in flight, one pending input. Slow effects drop stale frames rather
/// than growing a queue or switching to black while an image is being produced.
class FramePipelineView extends StatefulWidget {
  const FramePipelineView({
    super.key,
    required this.image,
    required this.programs,
    required this.fit,
    required this.onError,
  });
  final ui.Image image;
  final List<PixelProgram> programs;
  final BoxFit fit;
  final ValueChanged<String> onError;
  @override
  State<FramePipelineView> createState() => _FramePipelineViewState();
}

class _FramePipelineViewState extends State<FramePipelineView> {
  ui.Image? _pending, _output;
  bool _running = false, _closed = false, _reported = false;
  int _revision = 0;
  @override
  void initState() {
    super.initState();
    _request();
  }

  @override
  void didUpdateWidget(FramePipelineView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.programs != widget.programs) {
      _revision++;
      _reported = false;
    }
    if (oldWidget.image != widget.image || oldWidget.programs != widget.programs) _request();
  }

  void _request() {
    _pending?.dispose();
    _pending = widget.image.clone();
    if (!_running) _drain();
  }

  Future<void> _drain() async {
    _running = true;
    while (!_closed && _pending != null) {
      final input = _pending!, revision = _revision, programs = widget.programs;
      _pending = null;
      try {
        final output = await renderFramePrograms(input, programs);
        if (_closed || revision != _revision) {
          output.dispose();
          continue;
        }
        final old = _output;
        setState(() => _output = output);
        if (old != null) SchedulerBinding.instance.addPostFrameCallback((_) => old.dispose());
      } catch (e) {
        if (!_closed && !_reported) {
          _reported = true;
          widget.onError('프레임 처리 실패: $e');
        }
      } finally {
        input.dispose();
      }
    }
    _running = false;
  }

  @override
  void dispose() {
    _closed = true;
    _pending?.dispose();
    _pending = null;
    _output?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      RawImage(image: _output ?? widget.image, fit: widget.fit, filterQuality: FilterQuality.medium);
}
