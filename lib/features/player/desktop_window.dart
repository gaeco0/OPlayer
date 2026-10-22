import 'dart:io';
import 'package:flutter/services.dart';

class DesktopWindow {
  static const _channel = MethodChannel('oplayer/window');
  static Future<void> openDefaultApps() => _channel.invokeMethod<void>('defaultApps');
  static Future<void> compact(bool enabled) async {
    if (Platform.isWindows) await _channel.invokeMethod<void>('compact', enabled);
  }

  static Future<void> fullscreen(bool enabled) async {
    if (Platform.isWindows) await _channel.invokeMethod<void>('fullscreen', enabled);
  }
}
