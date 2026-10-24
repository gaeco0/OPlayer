import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../player_controller.dart';
import 'seek_bar.dart';

enum PanelKind { none, speed, subtitle, audio, aspect, playlist, more }

/// nPlayer 레이아웃
///  상단: ← 제목 | 자막 · 오디오 · 배속 · 더보기
///  중앙: ⏮  ▶/❚❚  ⏭
///  좌측 중앙: 잠금 / 우측 중앙: 화면 회전
///  하단: 시간 ━━━●━━ 시간
///        A-B · 반복 · ⟲10  ⟳10 · 화면비 · 재생목록
class ControlsOverlay extends StatelessWidget {
  const ControlsOverlay({
    super.key,
    required this.c,
    required this.onBack,
    required this.onPanel,
    required this.onToast,
    required this.onRotate,
    required this.orientationIcon,
    this.onPip,
    this.onRotationDiagnostics,
    this.onCast,
    this.onMinimize,
    this.onCompact,
    this.onFullscreen,
    this.fullscreen = false,
  });

  final PlayerController c;
  final VoidCallback onBack;
  final ValueChanged<PanelKind> onPanel;
  final ValueChanged<String> onToast;
  final VoidCallback? onRotate;
  final VoidCallback? onRotationDiagnostics;
  final IconData orientationIcon;
  final VoidCallback? onPip;
  final VoidCallback? onCast;
  final VoidCallback? onMinimize;
  final VoidCallback? onCompact;
  final VoidCallback? onFullscreen;
  final bool fullscreen;

  @override
  Widget build(BuildContext context) {
    final visible = c.controlsVisible;
    if (c.locked) {
      return AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        child: IgnorePointer(
          ignoring: !visible,
          child: SafeArea(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 16),
                child: _RoundButton(icon: Icons.lock, onTap: c.toggleLock, highlighted: true),
              ),
            ),
          ),
        ),
      );
    }

    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 200),
      child: IgnorePointer(
        ignoring: !visible,
        child: Stack(
          children: [
            // 상·하단 그라데이션
            const Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xAA000000), Color(0x00000000), Color(0x00000000), Color(0xCC000000)],
                      stops: [0, 0.25, 0.65, 1],
                    ),
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Column(
                children: [
                  _TopBar(
                    c: c,
                    onBack: onBack,
                    onPanel: onPanel,
                    onPip: onPip,
                    onCast: onCast,
                    onMinimize: onMinimize,
                    onCompact: onCompact,
                    onFullscreen: onFullscreen,
                    fullscreen: fullscreen,
                  ),
                  Expanded(
                    child: Row(
                      children: [
                        const SizedBox(width: 16),
                        _RoundButton(
                          icon: Icons.lock_open,
                          onTap: () {
                            c.toggleLock();
                            onToast('화면 잠금');
                          },
                        ),
                        const Spacer(),
                        _CenterControls(c: c),
                        const Spacer(),
                        if (onRotate != null)
                          GestureDetector(
                            onLongPress: onRotationDiagnostics,
                            child: _RoundButton(icon: orientationIcon, onTap: onRotate!),
                          )
                        else
                          const SizedBox(width: 48),
                        const SizedBox(width: 16),
                      ],
                    ),
                  ),
                  _BottomBar(c: c, onPanel: onPanel, onToast: onToast),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.c,
    required this.onBack,
    required this.onPanel,
    this.onPip,
    this.onCast,
    this.onMinimize,
    this.onCompact,
    this.onFullscreen,
    this.fullscreen = false,
  });
  final PlayerController c;
  final VoidCallback onBack;
  final ValueChanged<PanelKind> onPanel;
  final VoidCallback? onPip;
  final VoidCallback? onCast;
  final VoidCallback? onMinimize;
  final VoidCallback? onCompact;
  final VoidCallback? onFullscreen;
  final bool fullscreen;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 8, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: onBack,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  c.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                ),
                if (c.playlist.length > 1)
                  Text(
                    '${c.index + 1} / ${c.playlist.length}',
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
              ],
            ),
          ),
          if (onMinimize != null) _IconBtn(icon: Icons.minimize, tooltip: '접어서 계속 재생', onTap: onMinimize),
          if (onFullscreen != null)
            _IconBtn(
              icon: fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
              tooltip: fullscreen ? '전체화면 해제 (Alt+Enter)' : '전체화면 (Alt+Enter)',
              onTap: onFullscreen,
            ),
          if (onCompact != null) _IconBtn(icon: Icons.picture_in_picture, tooltip: '작은 창', onTap: onCompact),
          if (onCast != null) _IconBtn(icon: Icons.cast, tooltip: '외부 기기로 재생', onTap: onCast),
          if (onPip != null) _IconBtn(icon: Icons.picture_in_picture_alt, tooltip: '화면 속 화면', onTap: onPip),
          if (!narrow)
            _IconBtn(icon: Icons.closed_caption_outlined, tooltip: '자막', onTap: () => onPanel(PanelKind.subtitle)),
          if (!narrow) _IconBtn(icon: Icons.audiotrack_outlined, tooltip: '오디오', onTap: () => onPanel(PanelKind.audio)),
          if (!narrow)
            TextButton(
              onPressed: () => onPanel(PanelKind.speed),
              child: Text(
                '${fmtRate(c.baseRate)}x',
                style: TextStyle(
                  color: c.baseRate == 1 ? Colors.white : OColors.of(context).accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          if (narrow)
            PopupMenuButton<PanelKind>(
              tooltip: '재생 설정',
              onSelected: onPanel,
              itemBuilder: (_) => const [
                PopupMenuItem(value: PanelKind.subtitle, child: Text('자막')),
                PopupMenuItem(value: PanelKind.audio, child: Text('오디오')),
                PopupMenuItem(value: PanelKind.speed, child: Text('재생 속도')),
                PopupMenuItem(value: PanelKind.more, child: Text('더보기')),
              ],
            )
          else
            _IconBtn(icon: Icons.more_vert, tooltip: '더보기', onTap: () => onPanel(PanelKind.more)),
        ],
      ),
    );
  }
}

class _CenterControls extends StatelessWidget {
  const _CenterControls({required this.c});
  final PlayerController c;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _IconBtn(icon: Icons.skip_previous_rounded, size: 38, onTap: c.prev, tooltip: '이전'),
        const SizedBox(width: 28),
        StreamBuilder<bool>(
          stream: c.player.stream.playing,
          initialData: c.player.state.playing,
          builder: (_, s) {
            final playing = s.data ?? false;
            return StreamBuilder<bool>(
              stream: c.player.stream.buffering,
              initialData: c.player.state.buffering,
              builder: (_, b) => SizedBox(
                width: 72,
                height: 72,
                child: c.error == null && (c.preparing || (b.data ?? false))
                    ? const Padding(
                        padding: EdgeInsets.all(18),
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
                      )
                    : _IconBtn(
                        icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        size: 60,
                        onTap: () {
                          c.player.playOrPause();
                          c.showControls(autoHide: !playing);
                        },
                      ),
              ),
            );
          },
        ),
        const SizedBox(width: 28),
        _IconBtn(icon: Icons.skip_next_rounded, size: 38, onTap: c.hasNext ? c.next : null, tooltip: '다음'),
      ],
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.c, required this.onPanel, required this.onToast});
  final PlayerController c;
  final ValueChanged<PanelKind> onPanel;
  final ValueChanged<String> onToast;

  @override
  Widget build(BuildContext context) {
    final abActive = c.abA != null;
    final repeatIcon = switch (c.repeat) {
      LoopMode.off => Icons.repeat,
      LoopMode.one => Icons.repeat_one,
      LoopMode.all => Icons.repeat,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SeekBar(c: c),
          Row(
            children: [
              _IconBtn(
                icon: Icons.compare_arrows,
                tooltip: 'A-B 반복',
                active: abActive,
                label: c.abA == null ? 'A-B' : (c.abB == null ? 'A-' : 'A-B'),
                onTap: () {
                  final m = c.tapAB();
                  if (m != null) onToast(m);
                },
              ),
              _IconBtn(
                icon: repeatIcon,
                tooltip: '반복',
                active: c.repeat != LoopMode.off,
                onTap: () {
                  c.cycleRepeat();
                  onToast(switch (c.repeat) {
                    LoopMode.off => '반복 안 함',
                    LoopMode.one => '한 파일 반복',
                    LoopMode.all => '전체 반복',
                  });
                },
              ),
              const Spacer(),
              _IconBtn(
                icon: Icons.replay_10_rounded,
                tooltip: '10초 뒤로',
                onTap: () => c.seekRelative(const Duration(seconds: -10)),
              ),
              const SizedBox(width: 12),
              _IconBtn(
                icon: Icons.forward_10_rounded,
                tooltip: '10초 앞으로',
                onTap: () => c.seekRelative(const Duration(seconds: 10)),
              ),
              const Spacer(),
              _IconBtn(
                icon: Icons.aspect_ratio,
                tooltip: '화면 비율',
                onTap: () {
                  c.cycleAspect();
                  onToast(c.aspect.label);
                },
              ),
              _IconBtn(icon: Icons.playlist_play, tooltip: '재생목록', onTap: () => onPanel(PanelKind.playlist)),
            ],
          ),
        ],
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.size = 24,
    this.active = false,
    this.label,
  });
  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final double size;
  final bool active;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final color = onTap == null ? Colors.white30 : (active ? OColors.of(context).accent : Colors.white);
    final btn = IconButton(
      tooltip: tooltip,
      iconSize: size,
      color: color,
      onPressed: onTap,
      icon: label == null
          ? Icon(icon)
          : Text(
              label!,
              style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 14),
            ),
    );
    return btn;
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.onTap, this.highlighted = false});
  final IconData icon;
  final VoidCallback onTap;
  final bool highlighted;

  @override
  Widget build(BuildContext context) => Material(
    color: highlighted ? OColors.of(context).accent.withValues(alpha: 0.85) : Colors.black38,
    shape: const CircleBorder(),
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Icon(icon, color: Colors.white, size: 24),
      ),
    ),
  );
}
