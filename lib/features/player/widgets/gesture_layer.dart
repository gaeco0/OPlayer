import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';

import '../../../core/media_utils.dart';
import '../../../core/settings.dart';
import '../player_controller.dart';

enum _Drag { none, seek, brightness, volume, zoom }

bool get isMobile => Platform.isAndroid || Platform.isIOS;

/// nPlayer 제스처:
///  • 탭: 컨트롤 표시/숨김
///  • 더블탭: 좌측 = -10초, 우측 = +10초, 가운데 = 재생/일시정지
///  • 좌우 스와이프: 탐색 (손 떼면 이동, 미리보기 표시)
///  • 좌측 상하 스와이프: 밝기 / 우측 상하 스와이프: 볼륨
///  • 핀치: 확대/축소
///  • 길게 누르기: 2배속 (떼면 원래 속도)
///  • (데스크톱) 마우스 휠: 볼륨, 마우스 이동: 컨트롤 표시
class GestureLayer extends StatefulWidget {
  const GestureLayer({
    super.key,
    required this.c,
    required this.onTapOutsidePanel,
    this.seekStep = 10,
  });
  final PlayerController c;

  /// 패널이 열려 있으면 탭은 패널 닫기로 쓰인다. true를 반환하면 탭을 소비한 것.
  final bool Function() onTapOutsidePanel;
  final int seekStep;

  @override
  State<GestureLayer> createState() => GestureLayerState();
}

class GestureLayerState extends State<GestureLayer> {
  PlayerController get c => widget.c;

  _Drag _mode = _Drag.none;
  Offset _start = Offset.zero;
  Duration _seekFrom = Duration.zero;
  Duration _seekTo = Duration.zero;
  double _startValue = 0;
  double _brightness = 0.5;
  double _volume = 0.5; // 0~1
  double _startZoom = 1;
  Offset _doubleTapPos = Offset.zero;

  // HUD
  Widget? _hud;
  Timer? _hudTimer;
  int _dtAccum = 0; // 연속 더블탭 누적 초
  Timer? _dtTimer;

  @override
  void initState() {
    super.initState();
    _initLevels();
  }

  Future<void> _initLevels() async {
    if (isMobile) {
      VolumeController.instance.showSystemUI = false;
      try {
        _volume = await VolumeController.instance.getVolume();
        _brightness = await ScreenBrightness.instance.application;
      } catch (_) {}
    } else {
      _volume = c.player.state.volume / 100;
    }
  }

  @override
  void dispose() {
    _hudTimer?.cancel();
    _dtTimer?.cancel();
    if (isMobile) {
      ScreenBrightness.instance.resetApplicationScreenBrightness().catchError(
        (_) {},
      );
      VolumeController.instance.showSystemUI = true;
    }
    super.dispose();
  }

  void _showHud(
    Widget w, {
    Duration hideAfter = const Duration(milliseconds: 700),
  }) {
    _hudTimer?.cancel();
    setState(() => _hud = w);
    _hudTimer = Timer(hideAfter, () {
      if (mounted) setState(() => _hud = null);
    });
  }

  void _holdHud(Widget w) {
    _hudTimer?.cancel();
    setState(() => _hud = w);
  }

  Future<void> setVolume(double v) async {
    _volume = v.clamp(0.0, 1.0);
    if (isMobile) {
      await VolumeController.instance.setVolume(_volume);
    } else {
      await c.player.setVolume(_volume * 100);
    }
  }

  /// 외부(키보드/휠)에서 볼륨 변경 시 HUD 표시
  void nudgeVolume(double delta) {
    setVolume(_volume + delta);
    _showHud(
      _LevelHud(
        icon: _volumeIcon(_volume),
        value: _volume,
        label: '${(_volume * 100).round()}',
      ),
    );
  }

  /// 외부(키보드)에서 탐색 시 HUD 표시
  void flashSeek(int seconds) {
    c.seekRelative(Duration(seconds: seconds));
    _showHud(
      _SeekHud(
        delta: Duration(seconds: seconds),
        target: c.player.state.position + Duration(seconds: seconds),
        duration: c.player.state.duration,
      ),
    );
  }

  void flashText(String text, {IconData? icon}) => _showHud(
    _TextHud(text: text, icon: icon),
    hideAfter: const Duration(milliseconds: 1000),
  );

  IconData _volumeIcon(double v) => v == 0
      ? Icons.volume_off
      : (v < 0.5 ? Icons.volume_down : Icons.volume_up);

  // ---------------- gestures ----------------
  void _onTap() {
    if (widget.onTapOutsidePanel()) return;
    c.toggleControls();
  }

  void _onDoubleTap(Size size) {
    if (c.locked) return;
    final x = _doubleTapPos.dx / size.width;
    if (x > 0.35 && x < 0.65) {
      c.player.playOrPause();
      _showHud(
        _TextHud(
          icon: c.player.state.playing ? Icons.pause : Icons.play_arrow,
          text: c.player.state.playing ? '일시정지' : '재생',
        ),
      );
      return;
    }
    final forward = x >= 0.65;
    final step = widget.seekStep * (forward ? 1 : -1);
    // 연속 더블탭 시 누적 (+10 → +20 → +30)
    _dtAccum = (_dtAccum.sign == step.sign) ? _dtAccum + step : step;
    _dtTimer?.cancel();
    _dtTimer = Timer(const Duration(milliseconds: 900), () => _dtAccum = 0);
    c.seekRelative(Duration(seconds: step));
    _showHud(_DoubleTapHud(forward: forward, seconds: _dtAccum.abs()));
  }

  void _onScaleStart(ScaleStartDetails d) {
    if (c.locked) return;
    _start = d.localFocalPoint;
    _mode = _Drag.none;
    _startZoom = c.zoom;
  }

  void _onScaleUpdate(ScaleUpdateDetails d, Size size) {
    if (c.locked) return;
    if (d.pointerCount >= 2) {
      _mode = _Drag.zoom;
      c.setZoom(_startZoom * d.scale);
      _holdHud(
        _TextHud(icon: Icons.zoom_in, text: '${(c.zoom * 100).round()}%'),
      );
      return;
    }
    final delta = d.localFocalPoint - _start;
    final st = AppSettings.instance;
    if (_mode == _Drag.none) {
      if (delta.distance < 14) return;
      if (delta.dx.abs() > delta.dy.abs()) {
        if (!st.gestureSeek) return;
        _mode = _Drag.seek;
        _seekFrom = c.player.state.position;
      } else {
        final leftSide = _start.dx < size.width / 2;
        _mode = (leftSide && isMobile) ? _Drag.brightness : _Drag.volume;
        if (_mode == _Drag.brightness && !st.gestureBrightness) {
          return _resetMode();
        }
        if (_mode == _Drag.volume && !st.gestureVolume) return _resetMode();
        _startValue = _mode == _Drag.brightness ? _brightness : _volume;
      }
    }

    switch (_mode) {
      case _Drag.seek:
        final dur = c.player.state.duration;
        // 화면 전체 폭 = 최대 3분 (짧은 영상은 영상 길이)
        final maxSpan = (st.swipeSeekSpanSeconds * 1000).round();
        final spanMs = dur.inMilliseconds == 0
            ? maxSpan
            : dur.inMilliseconds.clamp(10000, maxSpan);
        final offset = Duration(
          milliseconds: (delta.dx / size.width * spanMs).round(),
        );
        var t = _seekFrom + offset;
        if (t < Duration.zero) t = Duration.zero;
        if (dur > Duration.zero && t > dur) t = dur;
        _seekTo = t;
        _holdHud(_SeekHud(delta: t - _seekFrom, target: t, duration: dur));
      case _Drag.brightness:
        _brightness = (_startValue - delta.dy / (size.height * 0.75)).clamp(
          0.0,
          1.0,
        );
        ScreenBrightness.instance
            .setApplicationScreenBrightness(_brightness)
            .catchError((_) {});
        _holdHud(
          _LevelHud(
            icon: Icons.brightness_6,
            value: _brightness,
            label: '${(_brightness * 100).round()}',
          ),
        );
      case _Drag.volume:
        setVolume(_startValue - delta.dy / (size.height * 0.75));
        _holdHud(
          _LevelHud(
            icon: _volumeIcon(_volume),
            value: _volume,
            label: '${(_volume * 100).round()}',
          ),
        );
      case _Drag.zoom:
      case _Drag.none:
        break;
    }
  }

  void _resetMode() => _mode = _Drag.none;

  void _onScaleEnd(ScaleEndDetails d) {
    if (_mode == _Drag.seek) c.player.seek(_seekTo);
    if (_mode != _Drag.none) {
      _hudTimer = Timer(const Duration(milliseconds: 500), () {
        if (mounted) setState(() => _hud = null);
      });
    }
    _mode = _Drag.none;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final size = box.biggest;
        return Listener(
          onPointerSignal: (e) {
            if (e is PointerScrollEvent && !c.locked) {
              if (e.scrollDelta.dy == 0) return;
              final step = AppSettings.instance.wheelVolumeStep / 100;
              nudgeVolume(e.scrollDelta.dy < 0 ? step : -step);
            }
          },
          child: MouseRegion(
            onHover: (_) {
              if (!isMobile && !c.controlsVisible) c.showControls();
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _onTap,
              onDoubleTapDown: (d) => _doubleTapPos = d.localPosition,
              onDoubleTap: () => _onDoubleTap(size),
              onLongPressStart: (_) {
                if (c.locked || !AppSettings.instance.longPressSpeed) return;
                c.startFastForward();
                _holdHud(
                  _TextHud(
                    icon: Icons.fast_forward,
                    text: '${(c.baseRate * 2).toStringAsFixed(1)}x 빨리 감기',
                  ),
                );
              },
              onLongPressEnd: (_) {
                c.stopFastForward();
                setState(() => _hud = null);
              },
              onScaleStart: _onScaleStart,
              onScaleUpdate: (d) => _onScaleUpdate(d, size),
              onScaleEnd: _onScaleEnd,
              child: Stack(
                children: [
                  const SizedBox.expand(),
                  if (_hud != null) Center(child: IgnorePointer(child: _hud!)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------- HUD widgets ----------------
class _HudBox extends StatelessWidget {
  const _HudBox({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
    decoration: BoxDecoration(
      color: const Color(0xB3000000),
      borderRadius: BorderRadius.circular(10),
    ),
    child: DefaultTextStyle(
      style: const TextStyle(
        color: Colors.white,
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
      child: child,
    ),
  );
}

class _SeekHud extends StatelessWidget {
  const _SeekHud({
    required this.delta,
    required this.target,
    required this.duration,
  });
  final Duration delta;
  final Duration target;
  final Duration duration;
  @override
  Widget build(BuildContext context) {
    final sign = delta.isNegative ? '-' : '+';
    return _HudBox(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$sign${formatDuration(delta.abs())}',
            style: const TextStyle(fontSize: 26),
          ),
          const SizedBox(height: 4),
          Text(
            '${formatDuration(target)} / ${formatDuration(duration)}',
            style: const TextStyle(fontSize: 13, color: Colors.white70),
          ),
        ],
      ),
    );
  }
}

class _LevelHud extends StatelessWidget {
  const _LevelHud({
    required this.icon,
    required this.value,
    required this.label,
  });
  final IconData icon;
  final double value;
  final String label;
  @override
  Widget build(BuildContext context) => _HudBox(
    child: SizedBox(
      width: 170,
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: value,
                minHeight: 4,
                backgroundColor: Colors.white24,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(width: 28, child: Text(label, textAlign: TextAlign.right)),
        ],
      ),
    ),
  );
}

class _TextHud extends StatelessWidget {
  const _TextHud({required this.text, this.icon});
  final String text;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => _HudBox(
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, color: Colors.white, size: 24),
          const SizedBox(width: 8),
        ],
        Text(text),
      ],
    ),
  );
}

class _DoubleTapHud extends StatelessWidget {
  const _DoubleTapHud({required this.forward, required this.seconds});
  final bool forward;
  final int seconds;
  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: forward ? const Alignment(0.6, 0) : const Alignment(-0.6, 0),
      child: _HudBox(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              forward ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded,
              color: Colors.white,
              size: 32,
            ),
            Text('${forward ? '+' : '-'}$seconds초'),
          ],
        ),
      ),
    );
  }
}
