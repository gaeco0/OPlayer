import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../core/media_utils.dart';
import '../player_controller.dart';

/// 진행바: 버퍼 표시, A-B 마커, 드래그 중 미리보기 시간, 시간 탭 → 남은 시간 전환.
class SeekBar extends StatefulWidget {
  const SeekBar({super.key, required this.c});
  final PlayerController c;

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  final _subs = <StreamSubscription>[];
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  Duration _buf = Duration.zero;
  double? _drag;
  bool _remaining = false;

  @override
  void initState() {
    super.initState();
    final s = widget.c.player.state;
    _pos = s.position;
    _dur = s.duration;
    _buf = s.buffer;
    final st = widget.c.player.stream;
    _subs.addAll([
      st.position.listen((v) => setState(() => _pos = v)),
      st.duration.listen((v) => setState(() => _dur = v)),
      st.buffer.listen((v) => setState(() => _buf = v)),
    ]);
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  double _frac(Duration d) => _dur.inMilliseconds == 0
      ? 0
      : (d.inMilliseconds / _dur.inMilliseconds).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final value = _drag ?? _frac(_pos);
    final shown = _drag != null
        ? Duration(milliseconds: (_drag! * _dur.inMilliseconds).round())
        : _pos;
    final c = widget.c;
    const timeStyle = TextStyle(
      color: Colors.white,
      fontSize: 13,
      fontFeatures: [FontFeature.tabularFigures()],
    );

    return Row(
      children: [
        SizedBox(
          width: 64,
          child: Text(
            formatDuration(shown),
            textAlign: TextAlign.center,
            style: timeStyle,
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              // Slider 내부 트랙은 좌우 overlayRadius(14)만큼 들어가 있다.
              const pad = 14.0;
              final w = box.maxWidth - pad * 2;
              Widget marker(Duration d, String t) => Positioned(
                left: pad + w * _frac(d) - 6,
                top: 0,
                child: Text(
                  t,
                  style: const TextStyle(
                    color: OColors.accent,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              );
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Slider(
                    value: value,
                    secondaryTrackValue: _frac(_buf),
                    onChangeStart: (v) {
                      c.keepControls();
                      setState(() => _drag = v);
                    },
                    onChanged: (v) => setState(() => _drag = v),
                    onChangeEnd: (v) {
                      c.player.seek(
                        Duration(
                          milliseconds: (v * _dur.inMilliseconds).round(),
                        ),
                      );
                      setState(() => _drag = null);
                      c.showControls();
                    },
                  ),
                  if (c.abA != null) marker(c.abA!, 'A'),
                  if (c.abB != null) marker(c.abB!, 'B'),
                ],
              );
            },
          ),
        ),
        GestureDetector(
          onTap: () => setState(() => _remaining = !_remaining),
          child: SizedBox(
            width: 64,
            child: Text(
              _remaining
                  ? '-${formatDuration(_dur - shown)}'
                  : formatDuration(_dur),
              textAlign: TextAlign.center,
              style: timeStyle,
            ),
          ),
        ),
      ],
    );
  }
}
