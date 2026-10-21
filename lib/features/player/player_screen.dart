import '../settings/resource_access_view.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/media_item.dart';
import '../../core/media_utils.dart';
import '../../core/settings.dart';
import '../cast/cast_controller.dart';
import '../cast/cast_sheet.dart';
import 'player_controller.dart';
import 'pip_controller.dart';
import 'media_session.dart';
import 'playback_session.dart';
import 'desktop_window.dart';
import 'widgets/controls_overlay.dart';
import 'widgets/gesture_layer.dart';
import 'widgets/side_panels.dart';

enum _Orient { landscape, portrait, auto }

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.playlist,
    required this.index,
    this.folderFiles = const [],
    this.existingController,
    this.compactInitially = false,
  });
  final List<MediaItem> playlist;
  final int index;
  final List<String> folderFiles;
  final PlayerController? existingController;
  final bool compactInitially;

  static Route<void> route(List<MediaItem> playlist, int index, {List<String> folderFiles = const []}) =>
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => PlayerScreen(playlist: playlist, index: index, folderFiles: folderFiles),
        transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
      );

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> with WidgetsBindingObserver {
  late final PlayerController c;
  final _gestureKey = GlobalKey<GestureLayerState>();
  final _focus = FocusNode();
  PanelKind _panel = PanelKind.none;
  _Orient _orient = _Orient.landscape;
  String? _toast;
  Timer? _toastTimer;
  Duration? _resumeOffer;
  Timer? _resumeTimer;
  final _pip = PlayerPip.instance;
  final _cast = CastController.instance;
  final _mediaSession = NativeMediaSession.instance;
  bool _backgrounded = false;
  bool _hideNotification = false;
  bool _compactWindow = false;
  final _session = PlaybackSession.instance;
  final _pipSubscriptions = <StreamSubscription>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c =
        widget.existingController ??
        PlayerController(playlist: widget.playlist, startIndex: widget.index, folderFiles: widget.folderFiles);
    _session.attach(c);
    c.addListener(_onController);
    _pip.addListener(_onPipChanged);
    _cast.addListener(_onCastChanged);
    _pip.onCommand = (command) async {
      switch (command) {
        case 'playPause':
          await c.player.playOrPause();
        case 'rewind':
          await c.seekRelative(const Duration(seconds: -10));
        case 'forward':
          await c.seekRelative(const Duration(seconds: 10));
      }
      _syncPip();
    };
    _pip.onBackground = () {
      if (_session.minimized || _session.controller != c) return;
      _backgrounded = true;
      if (!c.allowsBackgroundPlayback && !_pip.active) c.player.pause();
      _syncMediaSession();
    };
    _mediaSession.onLocalCommand = (command, argument) async {
      switch (command) {
        case 'play':
          _hideNotification = false;
          await c.player.play();
        case 'pause':
          await c.player.pause();
        case 'stop':
          _hideNotification = true;
          await c.player.pause();
        case 'next':
          await c.next();
        case 'previous':
          await c.prev();
        case 'seek':
          await c.player.seek(Duration(milliseconds: (argument as num).toInt()));
        case 'rewind':
          await c.seekRelative(const Duration(seconds: -10));
        case 'forward':
          await c.seekRelative(const Duration(seconds: 10));
      }
      _syncMediaSession();
    };
    _pipSubscriptions.addAll([
      c.player.stream.playing.listen((_) => _syncPip()),
      c.player.stream.width.listen((_) => _syncPip()),
      c.player.stream.height.listen((_) => _syncPip()),
      c.player.stream.position.listen((_) => _syncPip()),
    ]);
    _pip.initialize().then((_) {
      if (mounted) _syncPip();
    });
    WakelockPlus.enable();
    if (isMobile) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      _applyOrientation();
    }
    if (widget.existingController == null) {
      _start();
    } else {
      c.showControls();
    }
    if (widget.compactInitially) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _setCompact(true);
      });
    }
  }

  void _syncPip() {
    if (_session.controller != c || _session.minimized) return;
    final s = c.player.state;
    final ratio = (s.width ?? 0) > 0 && (s.height ?? 0) > 0 ? s.width! / s.height! : 16 / 9;
    _pip.update(
      enabled: !_castingCurrent && !c.audioOnly && (s.width ?? 0) > 0 && (s.height ?? 0) > 0,
      playing: s.playing,
      aspect: ratio,
    );
    if (s.playing) _hideNotification = false;
    _syncMediaSession();
  }

  void _syncMediaSession() {
    if (_cast.active || _session.controller != c || _session.minimized) return;
    final state = c.player.state;
    _mediaSession.update(
      enabled: !_hideNotification && (!_backgrounded || c.allowsBackgroundPlayback || _pip.active),
      playing: state.playing,
      title: c.title,
      position: state.position,
      duration: state.duration,
      foreground: c.allowsBackgroundPlayback || _pip.active,
      canPrevious: c.hasPrev || state.position > Duration.zero,
      canNext: c.hasNext,
      rate: c.baseRate,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_session.controller != c || _session.minimized) return;
    if (state == AppLifecycleState.resumed) {
      _backgrounded = false;
      _syncMediaSession();
    } else if (state == AppLifecycleState.paused && !_pip.active) {
      _backgrounded = true;
      if (!c.allowsBackgroundPlayback && !_cast.active) {
        c.player.pause();
      }
      _syncMediaSession();
    }
  }

  bool get _castingCurrent => _cast.active && _cast.mediaKey == c.current.key;
  void _onCastChanged() {
    if (mounted) {
      if (_castingCurrent) {
        WakelockPlus.disable();
      } else {
        WakelockPlus.enable();
      }
      _syncPip();
      setState(() {});
    }
  }

  Future<void> _openCast() async {
    try {
      final media = c.resolved ?? await c.current.resolve();
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => CastSheet(
          media: media,
          position: c.player.state.position,
          onStarted: () {
            c.player.pause();
            _syncPip();
          },
        ),
      );
    } catch (e) {
      if (mounted) _showToast('$e');
    }
  }

  void _onPipChanged() {
    if (!mounted) return;
    if (_pip.active) {
      _panel = PanelKind.none;
      c.hideControls();
    }
    _syncMediaSession();
    setState(() {});
  }

  Future<void> _enterPip() async {
    if (c.audioOnly) {
      await _minimize(background: true);
      return;
    }
    if (!await _pip.enter() && mounted) {
      _showToast('기기 설정에서 OPlayer의 화면 속 화면 권한을 확인해 주세요');
    }
  }

  Future<void> _start() async {
    await c.open();
    c.showControls();
  }

  Future<void> _minimize({bool background = false}) async {
    if (_castingCurrent || _session.minimized) return;
    if (_compactWindow) await _setCompact(false);
    await _session.minimize(c, background: background || Platform.isAndroid);
    if (!mounted) return;
    Navigator.of(context).pop();
    if (Platform.isAndroid) await _pip.background();
  }

  Future<void> _setCompact(bool compact) async {
    try {
      await DesktopWindow.compact(compact);
      if (mounted) setState(() => _compactWindow = compact);
    } on PlatformException catch (e) {
      if (mounted) _showToast(e.message ?? '작은 창으로 전환할 수 없습니다');
    }
  }

  /// nPlayer: 이전 위치에서 자동으로 이어서 재생하고, "처음부터" 버튼을 잠시 보여준다.
  Future<void> _maybeResume() async {
    final at = c.pendingResume;
    if (at == null) return;
    c.pendingResume = null;
    if (AppSettings.instance.resumeMode == ResumeMode.ask && mounted) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('이어서 보기'),
          content: Text('${formatDuration(at)}부터 이어서 재생할까요?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('처음부터')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('이어서 보기')),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (c.player.state.duration == Duration.zero) {
      await c.player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 10), onTimeout: () => Duration.zero);
    }
    await c.player.seek(at);
    if (!mounted) return;
    setState(() => _resumeOffer = at);
    _resumeTimer?.cancel();
    _resumeTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _resumeOffer = null);
    });
  }

  String? _lastPath;
  void _onController() {
    _syncPip();
    if (c.warning != null) {
      final warning = c.warning!;
      c.warning = null;
      _showToast(warning);
    }
    // 다음/이전 파일로 넘어갔을 때 이어보기 처리
    if (_lastPath != c.current.key) {
      _lastPath = c.current.key;
      if (c.pendingResume != null) _maybeResume();
    }
    setState(() {});
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    _resumeTimer?.cancel();
    _pip.removeListener(_onPipChanged);
    _cast.removeListener(_onCastChanged);
    WidgetsBinding.instance.removeObserver(this);
    final keepPlaying = _session.retains(c);
    final ownsSession = _session.controller == c;
    if (ownsSession && !keepPlaying) _mediaSession.onLocalCommand = null;
    if (ownsSession && !keepPlaying && !_cast.active) {
      _mediaSession.update(enabled: false, playing: false, title: '', position: Duration.zero, duration: Duration.zero);
    }
    for (final subscription in _pipSubscriptions) {
      subscription.cancel();
    }
    if (ownsSession) {
      _pip.onCommand = null;
      _pip.onBackground = null;
      _pip.update(enabled: false, playing: false);
    }
    c.removeListener(_onController);
    if (!keepPlaying) {
      _session.release(c);
      c.dispose();
    }
    if (_compactWindow) DesktopWindow.compact(false);
    _focus.dispose();
    if (ownsSession) WakelockPlus.disable();
    if (isMobile && ownsSession) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations([]);
    }
    super.dispose();
  }

  void _applyOrientation() {
    SystemChrome.setPreferredOrientations(switch (_orient) {
      _Orient.landscape => [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
      _Orient.portrait => [DeviceOrientation.portraitUp],
      _Orient.auto => [],
    });
  }

  void _rotate() {
    _orient = _Orient.values[(_orient.index + 1) % _Orient.values.length];
    _applyOrientation();
    _showToast(switch (_orient) {
      _Orient.landscape => '가로 고정',
      _Orient.portrait => '세로 고정',
      _Orient.auto => '자동 회전',
    });
  }

  void _showToast(String msg) {
    _toastTimer?.cancel();
    setState(() => _toast = msg);
    _toastTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  void _openPanel(PanelKind k) {
    setState(() => _panel = k);
    c.hideControls();
  }

  bool _closePanelIfOpen() {
    if (_panel == PanelKind.none) return false;
    setState(() => _panel = PanelKind.none);
    return true;
  }

  // ---------------- 키보드 (데스크톱 / 외장 키보드) ----------------
  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final g = _gestureKey.currentState;
    final k = e.logicalKey;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final ks = AppSettings.instance.keyboardSeekSeconds;
    if (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.keyK) {
      c.player.playOrPause();
      c.showControls();
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      g?.flashSeek(shift ? -60 : -ks);
    } else if (k == LogicalKeyboardKey.arrowRight) {
      g?.flashSeek(shift ? 60 : ks);
    } else if (k == LogicalKeyboardKey.keyJ) {
      g?.flashSeek(-10);
    } else if (k == LogicalKeyboardKey.keyL) {
      g?.flashSeek(10);
    } else if (k == LogicalKeyboardKey.arrowUp) {
      g?.nudgeVolume(AppSettings.instance.wheelVolumeStep * 2 / 100);
    } else if (k == LogicalKeyboardKey.arrowDown) {
      g?.nudgeVolume(-AppSettings.instance.wheelVolumeStep * 2 / 100);
    } else if (k == LogicalKeyboardKey.bracketLeft || k == LogicalKeyboardKey.minus) {
      c.setRate(c.baseRate - 0.1);
      g?.flashText('${fmtRate(c.baseRate)}x', icon: Icons.speed);
    } else if (k == LogicalKeyboardKey.bracketRight || k == LogicalKeyboardKey.equal) {
      c.setRate(c.baseRate + 0.1);
      g?.flashText('${fmtRate(c.baseRate)}x', icon: Icons.speed);
    } else if (k == LogicalKeyboardKey.backspace) {
      c.setRate(1.0);
      g?.flashText('1.0x', icon: Icons.speed);
    } else if (k == LogicalKeyboardKey.comma) {
      c.setSubtitleDelay(c.subtitleDelay - const Duration(milliseconds: 100));
      g?.flashText('자막 ${(c.subtitleDelay.inMilliseconds / 1000).toStringAsFixed(1)}초');
    } else if (k == LogicalKeyboardKey.period) {
      c.setSubtitleDelay(c.subtitleDelay + const Duration(milliseconds: 100));
      g?.flashText('자막 ${(c.subtitleDelay.inMilliseconds / 1000).toStringAsFixed(1)}초');
    } else if (k == LogicalKeyboardKey.pageDown || k == LogicalKeyboardKey.keyN) {
      c.next();
    } else if (k == LogicalKeyboardKey.pageUp || k == LogicalKeyboardKey.keyP) {
      c.prev();
    } else if (k == LogicalKeyboardKey.keyA) {
      c.cycleAspect();
      g?.flashText(c.aspect.label, icon: Icons.aspect_ratio);
    } else if (k == LogicalKeyboardKey.keyR) {
      final m = c.tapAB();
      if (m != null) g?.flashText(m);
    } else if (k == LogicalKeyboardKey.escape) {
      if (!_closePanelIfOpen()) Navigator.maybePop(context);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // ---------------- 영상 레이어 ----------------
  Widget _video() {
    if (c.audioOnly) return const ColoredBox(color: Colors.black);
    final st = AppSettings.instance;
    final subtitleCfg = SubtitleViewConfiguration(
      style: TextStyle(
        fontSize: st.subtitleFontSize * c.subtitleScale,
        height: 1.35,
        color: Color(st.subtitleColor),
        fontWeight: FontWeight.w600,
        shadows: const [
          Shadow(blurRadius: 4, color: Colors.black),
          Shadow(offset: Offset(1.5, 1.5), blurRadius: 2, color: Colors.black),
        ],
        backgroundColor: st.subtitleBackground ? const Color(0x99000000) : Colors.transparent,
      ),
      padding: EdgeInsets.fromLTRB(16, 0, 16, MediaQuery.sizeOf(context).height * c.subtitleBottom + 8),
    );

    Widget v(BoxFit fit) => Video(
      controller: c.video,
      controls: NoVideoControls,
      fit: fit,
      fill: Colors.black,
      // Playback lifecycle is owned by this screen and PlaybackSession, including PiP.
      pauseUponEnteringBackgroundMode: false,
      subtitleViewConfiguration: subtitleCfg,
    );

    if (_pip.active) return v(BoxFit.contain);
    final Widget base = switch (c.aspect) {
      AspectMode.fit => v(BoxFit.contain),
      AspectMode.fill => v(BoxFit.cover),
      AspectMode.stretch => v(BoxFit.fill),
      AspectMode.original => v(BoxFit.none),
      AspectMode.r16x9 => Center(
        child: AspectRatio(aspectRatio: 16 / 9, child: v(BoxFit.fill)),
      ),
      AspectMode.r4x3 => Center(
        child: AspectRatio(aspectRatio: 4 / 3, child: v(BoxFit.fill)),
      ),
      AspectMode.r1x1 => Center(child: AspectRatio(aspectRatio: 1, child: v(BoxFit.fill))),
      AspectMode.r3x2 => Center(
        child: AspectRatio(aspectRatio: 3 / 2, child: v(BoxFit.fill)),
      ),
      AspectMode.r5x3 => Center(
        child: AspectRatio(aspectRatio: 5 / 3, child: v(BoxFit.fill)),
      ),
      AspectMode.cinema185 => Center(child: AspectRatio(aspectRatio: 1.85, child: v(BoxFit.fill))),
      AspectMode.cinema235 => Center(child: AspectRatio(aspectRatio: 2.35, child: v(BoxFit.fill))),
    };
    return ClipRect(
      child: Transform.scale(scale: c.zoom, child: base),
    );
  }

  @override
  Widget build(BuildContext context) => ResourceAccessView(
    resources: [
      c.current.key,
      c.current.localPath ?? c.current.uri,
      if (c.resolved != null) c.resolved!.localPath ?? c.resolved!.uri,
    ],
    child: _buildContent(context),
  );

  Widget _buildContent(BuildContext context) {
    if (_compactWindow) {
      final state = c.player.state;
      return Scaffold(
        backgroundColor: Colors.black,
        body: Column(
          children: [
            Expanded(
              child: GestureDetector(onDoubleTap: () => _setCompact(false), child: _video()),
            ),
            Material(
              color: Colors.black,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (state.duration > Duration.zero)
                    Slider(
                      value: state.position.inMilliseconds.toDouble().clamp(
                        0,
                        state.duration.inMilliseconds.toDouble(),
                      ),
                      max: state.duration.inMilliseconds.toDouble(),
                      onChanged: (value) => c.player.seek(Duration(milliseconds: value.round())),
                    ),
                  Row(
                    children: [
                      IconButton(
                        onPressed: () => c.player.playOrPause(),
                        icon: Icon(state.playing ? Icons.pause : Icons.play_arrow),
                      ),
                      Expanded(child: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                      IconButton(tooltip: '앱 하단으로', onPressed: _minimize, icon: const Icon(Icons.minimize)),
                      IconButton(
                        tooltip: '큰 화면',
                        onPressed: () => _setCompact(false),
                        icon: const Icon(Icons.open_in_full),
                      ),
                      IconButton(
                        tooltip: '재생 종료',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    if (_castingCurrent) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('외부 기기로 재생'),
          actions: [IconButton(onPressed: _openCast, icon: const Icon(Icons.cast_connected))],
        ),
        body: Center(
          child: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.connected_tv, size: 72),
                const SizedBox(height: 16),
                Text(_cast.deviceName!, style: Theme.of(context).textTheme.titleLarge),
                Padding(padding: const EdgeInsets.all(16), child: Text(_cast.title)),
                const CastControls(),
                FilledButton(
                  onPressed: () async {
                    final at = _cast.position;
                    await _cast.stop();
                    if (!mounted) return;
                    await c.player.seek(at);
                    await c.player.play();
                  },
                  child: const Text('이 기기에서 이어서 재생'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return PopScope(
      canPop: _panel == PanelKind.none,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closePanelIfOpen();
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              Positioned.fill(child: _video()),
              if (!_pip.active) ...[
                Positioned.fill(
                  child: GestureLayer(
                    key: _gestureKey,
                    c: c,
                    onTapOutsidePanel: _closePanelIfOpen,
                    seekStep: AppSettings.instance.doubleTapSeekSeconds,
                  ),
                ),
                if (c.error != null)
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      margin: const EdgeInsets.all(32),
                      decoration: BoxDecoration(color: const Color(0xCC000000), borderRadius: BorderRadius.circular(8)),
                      child: Text(
                        c.error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                Positioned.fill(
                  child: ControlsOverlay(
                    c: c,
                    onBack: () => Navigator.maybePop(context),
                    onPanel: _openPanel,
                    onToast: _showToast,
                    onRotate: _rotate,
                    onPip: _pip.available && (c.audioOnly || (c.player.state.width ?? 0) > 0) ? _enterPip : null,
                    onMinimize: _minimize,
                    onCompact: Platform.isWindows ? () => _setCompact(true) : null,
                    onCast: _openCast,
                    orientationIcon: switch (_orient) {
                      _Orient.landscape => Icons.stay_current_landscape,
                      _Orient.portrait => Icons.stay_current_portrait,
                      _Orient.auto => Icons.screen_rotation,
                    },
                  ),
                ),
                if (_resumeOffer != null) _resumeChip(),
                if (_toast != null)
                  Positioned(
                    top: 72,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: const Color(0xCC000000),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(_toast!, style: const TextStyle(color: Colors.white, fontSize: 14)),
                        ),
                      ),
                    ),
                  ),
                SidePanel(
                  kind: _panel,
                  c: c,
                  onClose: () => setState(() => _panel = PanelKind.none),
                  onToast: _showToast,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _resumeChip() => Positioned(
    left: 24,
    bottom: 120,
    child: SafeArea(
      child: Material(
        color: const Color(0xDD1C1C1F),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${formatDuration(_resumeOffer!)}부터 이어서 재생',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () {
                  c.player.seek(Duration.zero);
                  setState(() => _resumeOffer = null);
                },
                child: const Text('처음부터'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
