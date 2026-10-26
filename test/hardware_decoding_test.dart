import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oplayer/features/player/player_controller.dart';

void main() {
  test('Windows uses copy-back decoding and disabling decoding keeps GPU rendering available', () {
    for (final platform in TargetPlatform.values) {
      final enabled = playbackVideoConfiguration(hardwareDecoding: true, platform: platform);
      expect(enabled.hwdec, platform == TargetPlatform.windows ? 'auto-copy' : 'auto-safe');
      expect(enabled.enableHardwareAcceleration, true);
      final disabled = playbackVideoConfiguration(hardwareDecoding: false, platform: platform);
      expect(disabled.hwdec, 'no');
      expect(disabled.enableHardwareAcceleration, true);
    }
  });
}
