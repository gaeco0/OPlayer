import 'package:flutter/widgets.dart';

import '../../../core/settings.dart';

/// Android can ignore Activity orientation requests on unfolded displays.
/// Keep the player usable in the requested direction using its actual bounds.
class PlayerOrientationViewport extends StatelessWidget {
  const PlayerOrientationViewport({super.key, required this.mode, required this.enabled, required this.child});

  final PlaybackOrientation mode;
  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      final rotate =
          enabled &&
          size.isFinite &&
          size.width != size.height &&
          switch (mode) {
            PlaybackOrientation.landscape => size.width < size.height,
            PlaybackOrientation.portrait => size.width > size.height,
            PlaybackOrientation.auto => false,
          };
      final data = MediaQuery.of(context);
      EdgeInsets turn(EdgeInsets value) => EdgeInsets.fromLTRB(value.top, value.right, value.bottom, value.left);
      // Keep the subtree stable when Android eventually rotates, folds/unfolds,
      // or enters PiP. RotatedBox also transforms hit testing and layout bounds.
      return RotatedBox(
        quarterTurns: rotate ? 1 : 0,
        child: MediaQuery(
          data: data.copyWith(
            size: rotate ? Size(size.height, size.width) : size,
            padding: rotate ? turn(data.padding) : data.padding,
            viewPadding: rotate ? turn(data.viewPadding) : data.viewPadding,
            viewInsets: rotate ? turn(data.viewInsets) : data.viewInsets,
            systemGestureInsets: rotate ? turn(data.systemGestureInsets) : data.systemGestureInsets,
          ),
          child: child,
        ),
      );
    },
  );
}
