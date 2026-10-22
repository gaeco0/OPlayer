import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../player_controller.dart';

/// One sizing policy for full screen, compact windows, PiP and the mini player.
class PlayerVideo extends StatelessWidget {
  const PlayerVideo({
    super.key,
    required this.controller,
    this.fit = BoxFit.contain,
    this.renderScale = 1,
    this.subtitleViewConfiguration = const SubtitleViewConfiguration(),
  });
  final PlayerController controller;
  final BoxFit fit;
  final double renderScale;
  final SubtitleViewConfiguration subtitleViewConfiguration;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final ratio = MediaQuery.devicePixelRatioOf(context) * renderScale;
      final size = Size(constraints.maxWidth * ratio, constraints.maxHeight * ratio);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) controller.setUpscalingViewport(size, fit);
      });
      return Video(
        controller: controller.video,
        controls: NoVideoControls,
        fit: fit,
        fill: Colors.black,
        pauseUponEnteringBackgroundMode: false,
        subtitleViewConfiguration: subtitleViewConfiguration,
      );
    },
  );
}
