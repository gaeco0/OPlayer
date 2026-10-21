import 'dart:io';

import 'package:flutter/services.dart';

import '../cast/cast_controller.dart';

class NativeMediaSession {
  NativeMediaSession._() {
    if (Platform.isAndroid) {
      _channel.setMethodCallHandler((call) async {
        final cast = CastController.instance;
        if (cast.active) {
          switch (call.method) {
            case 'play':
              if (!cast.playing) await cast.playOrPause();
            case 'pause':
              if (cast.playing) await cast.playOrPause();
            case 'stop':
              await cast.stop();
            case 'seek':
              await cast.seek(Duration(milliseconds: (call.arguments as num).toInt()));
            case 'next':
              await cast.seek(cast.position + const Duration(seconds: 30));
            case 'previous':
              await cast.seek(cast.position - const Duration(seconds: 10));
            case 'rewind':
              await cast.seek(cast.position - const Duration(seconds: 10));
            case 'forward':
              await cast.seek(cast.position + const Duration(seconds: 10));
          }
        } else {
          await onLocalCommand?.call(call.method, call.arguments);
        }
      });
    }
  }
  static final instance = NativeMediaSession._();
  static const _channel = MethodChannel('oplayer/media');
  Future<void> Function(String command, dynamic argument)? onLocalCommand;
  String? _signature;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> update({
    required bool enabled,
    required bool playing,
    required String title,
    String subtitle = '',
    required Duration position,
    required Duration duration,
    bool foreground = false,
    bool remote = false,
    bool canPrevious = true,
    bool canNext = true,
    double rate = 1,
  }) async {
    if (!Platform.isAndroid) return;
    final signature = '$enabled/$playing/$title/$subtitle/$foreground/$remote/$duration/$rate/$canPrevious/$canNext';
    final now = DateTime.now();
    if (signature == _signature && now.difference(_last) < const Duration(seconds: 3)) {
      return;
    }
    _signature = signature;
    _last = now;
    try {
      await _channel.invokeMethod<void>('update', {
        'enabled': enabled,
        'playing': playing,
        'title': title,
        'subtitle': subtitle,
        'position': position.inMilliseconds,
        'duration': duration.inMilliseconds,
        'foreground': foreground,
        'remote': remote,
        'canPrevious': canPrevious,
        'canNext': canNext,
        'rate': rate,
      });
    } on PlatformException {
      _signature = null;
    } on MissingPluginException {
      // Native media controls are unavailable in widget tests.
    }
  }
}
