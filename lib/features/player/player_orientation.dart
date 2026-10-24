import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/settings.dart';

class PlayerOrientation {
  static const _channel = MethodChannel('oplayer/orientation');

  static bool get supported =>
      appFlavor != 'tv' && [TargetPlatform.android, TargetPlatform.iOS].contains(defaultTargetPlatform);

  static Future<Map<String, dynamic>> diagnostics() async {
    if (!supported || defaultTargetPlatform != TargetPlatform.android) return {};
    return await _channel.invokeMapMethod<String, dynamic>('diagnostics') ?? {};
  }

  /// null restores the OS policy outside fullscreen playback.
  static Future<void> apply(PlaybackOrientation? mode) async {
    if (!supported) return;
    if (defaultTargetPlatform == TargetPlatform.android) {
      // Flutter maps a landscape pair to USER_LANDSCAPE and [] to UNSPECIFIED.
      // The native bridge uses SENSOR_LANDSCAPE/FULL_SENSOR to ignore rotation lock.
      await _channel.invokeMethod<void>('set', mode?.name ?? 'system');
    } else {
      await SystemChrome.setPreferredOrientations(switch (mode) {
        PlaybackOrientation.landscape => [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
        PlaybackOrientation.portrait => [DeviceOrientation.portraitUp],
        PlaybackOrientation.auto => DeviceOrientation.values,
        null => [],
      });
    }
  }
}
