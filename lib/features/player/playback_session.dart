import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../../core/mouse_nav.dart';
import '../cast/cast_controller.dart';
import 'media_session.dart';
import 'pip_controller.dart';
import 'player_controller.dart';
import 'player_screen.dart';

/// Keeps the same player alive when its full-screen route is closed to a mini player.
class PlaybackSession extends ChangeNotifier with WidgetsBindingObserver {
  PlaybackSession._() {
    WidgetsBinding.instance.addObserver(this);
  }
  static final instance = PlaybackSession._();
  PlayerController? controller;
  bool minimized = false;
  bool forceBackground = false;
  bool _backgrounded = false;
  final _subscriptions = <StreamSubscription>[];
  DateTime _lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  void _changed() => scheduleMicrotask(notifyListeners);
  void attach(PlayerController next) {
    final old = controller;
    _unwatch();
    if (old != null && old != next) {
      old.player.pause();
      if (minimized) old.dispose();
    }
    controller = next;
    minimized = false;
    forceBackground = false;
    _changed();
  }

  bool retains(PlayerController player) => controller == player && minimized;
  void release(PlayerController player) {
    if (controller == player) {
      _unwatch();
      controller = null;
      minimized = false;
      _changed();
    }
  }

  void _unwatch() {
    controller?.removeListener(_update);
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
  }

  Future<void> minimize(PlayerController player, {bool background = false}) async {
    if (controller != player || minimized) return;
    minimized = true;
    forceBackground = background;
    player.hideControls();
    player.addListener(_update);
    _subscriptions.addAll([
      player.player.stream.playing.listen((_) => _update()),
      player.player.stream.duration.listen((_) => _update()),
      player.player.stream.position.listen((_) {
        if (DateTime.now().difference(_lastUpdate).inMilliseconds >= 250) _update();
      }),
    ]);
    NativeMediaSession.instance.onLocalCommand = (command, argument) async {
      final c = controller;
      if (c == null || !minimized) return;
      switch (command) {
        case 'play':
          await c.player.play();
        case 'pause':
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
        case 'stop':
          await stop();
        case 'open':
          await restore();
      }
      _update();
    };
    await PlayerPip.instance.update(enabled: false, playing: false);
    await _notifyMedia();
    _changed();
  }

  Future<void> _notifyMedia() async {
    final c = controller;
    if (c == null || !minimized || CastController.instance.active) return;
    final allowBackground = forceBackground || c.allowsBackgroundPlayback;
    await NativeMediaSession.instance.update(
      enabled: !_backgrounded || allowBackground,
      playing: c.player.state.playing,
      title: c.title,
      position: c.player.state.position,
      duration: c.player.state.duration,
      foreground: allowBackground,
      canPrevious: c.hasPrev || c.player.state.position > Duration.zero,
      canNext: c.hasNext,
      rate: c.baseRate,
    );
  }

  void _update() {
    _lastUpdate = DateTime.now();
    _notifyMedia();
    _changed();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _backgrounded = state == AppLifecycleState.paused || state == AppLifecycleState.hidden;
    if (minimized &&
        _backgrounded &&
        !forceBackground &&
        !(controller?.allowsBackgroundPlayback ?? false) &&
        Platform.isAndroid) {
      controller?.player.pause();
    }
    _notifyMedia();
  }

  Future<void> restore({bool compact = false}) async {
    final c = controller;
    final nav = MouseNav.navigatorKey.currentState;
    if (c == null || !minimized || nav == null) return;
    _unwatch();
    minimized = false;
    _changed();
    await nav.push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          playlist: c.playlist,
          index: c.index,
          folderFiles: c.folderFiles,
          existingController: c,
          compactInitially: compact,
        ),
      ),
    );
  }

  Future<void> stop() async {
    final c = controller;
    _unwatch();
    controller = null;
    minimized = false;
    forceBackground = false;
    NativeMediaSession.instance.onLocalCommand = null;
    c?.dispose();
    if (!CastController.instance.active) {
      await NativeMediaSession.instance.update(
        enabled: false,
        playing: false,
        title: '',
        position: Duration.zero,
        duration: Duration.zero,
      );
    }
    _changed();
  }
}
