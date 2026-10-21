import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PlayerPip extends ChangeNotifier {
  PlayerPip._();
  static final instance = PlayerPip._();
  static const _channel = MethodChannel('oplayer/pip');
  bool available = false;
  bool active = false;
  Future<void> Function(String command)? onCommand;
  VoidCallback? onBackground;
  String? _lastState;

  Future<void> initialize() async {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'changed':
          active = call.arguments == true;
          notifyListeners();
        case 'playPause':
        case 'rewind':
        case 'forward':
        case 'audioOnly':
        case 'previous':
        case 'next':
          await onCommand?.call(call.method);
        case 'backgrounded':
          onBackground?.call();
      }
    });
    try {
      available = await _channel.invokeMethod<bool>('available') ?? false;
      notifyListeners();
    } on MissingPluginException {
      available = false;
    }
  }

  Future<void> update({
    required bool enabled,
    required bool playing,
    double aspect = 16 / 9,
    bool canPrevious = false,
    bool canNext = false,
  }) async {
    if (!available) return;
    final state = '$enabled/$playing/$aspect/$canPrevious/$canNext';
    if (_lastState == state) return;
    _lastState = state;
    try {
      await _channel.invokeMethod<void>('update', {
        'active': enabled,
        'playing': playing,
        'aspect': aspect,
        'canPrevious': canPrevious,
        'canNext': canNext,
      });
    } on PlatformException {
      _lastState = null;
    }
  }

  Future<bool> enter() async {
    if (!available) return false;
    try {
      return await _channel.invokeMethod<bool>('enter') ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> background() async {
    if (Platform.isAndroid) await _channel.invokeMethod<void>('background');
  }
}
