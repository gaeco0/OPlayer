import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/player/widgets/player_orientation_viewport.dart';

class _Probe extends StatefulWidget {
  const _Probe({super.key});
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  int taps = 0;
  Offset? tapPosition;
  late Size bounds;
  late MediaQueryData media;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      bounds = constraints.biggest;
      media = MediaQuery.of(context);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (event) => tapPosition = event.localPosition,
        onTap: () => setState(() => taps++),
        child: const SizedBox.expand(),
      );
    },
  );
}

void main() {
  testWidgets('ignored Android rotation swaps player layout, safe areas and gesture coordinates', (tester) async {
    final probe = GlobalKey<_ProbeState>();
    Widget screen(Size size, PlaybackOrientation mode, {bool enabled = true}) => Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(
          padding: EdgeInsets.fromLTRB(2, 12, 4, 20),
          viewPadding: EdgeInsets.fromLTRB(2, 12, 4, 20),
          viewInsets: EdgeInsets.only(bottom: 100),
          systemGestureInsets: EdgeInsets.fromLTRB(3, 5, 7, 9),
        ),
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox.fromSize(
            size: size,
            child: PlayerOrientationViewport(
              mode: mode,
              enabled: enabled,
              child: _Probe(key: probe),
            ),
          ),
        ),
      ),
    );

    // Nearly square unfolded Fold screen, with the OS remaining in portrait.
    await tester.pumpWidget(screen(const Size(360, 400), PlaybackOrientation.landscape));
    final state = probe.currentState!;
    expect(state.bounds, const Size(400, 360));
    expect(state.media.size, state.bounds);
    expect(state.media.orientation, Orientation.landscape);
    expect(state.media.padding, const EdgeInsets.fromLTRB(12, 4, 20, 2));
    expect(state.media.viewPadding, state.media.padding);
    expect(state.media.viewInsets, const EdgeInsets.only(right: 100));
    expect(state.media.systemGestureInsets, const EdgeInsets.fromLTRB(5, 7, 9, 3));
    await tester.tapAt(const Offset(180, 80));
    await tester.pump();
    expect(state.tapPosition!.dx, closeTo(80, 0.001));
    expect(state.tapPosition!.dy, closeTo(180, 0.001));
    expect(state.taps, 1);

    // Android finally rotates: remove the fallback without recreating playback.
    await tester.pumpWidget(screen(const Size(400, 360), PlaybackOrientation.landscape));
    expect(probe.currentState, same(state));
    expect(state.taps, 1);
    expect(state.bounds, const Size(400, 360));
    expect(state.media.padding, const EdgeInsets.fromLTRB(2, 12, 4, 20));

    // A fixed portrait request also works when Android leaves a wide window.
    await tester.pumpWidget(screen(const Size(400, 360), PlaybackOrientation.portrait));
    expect(state.bounds, const Size(360, 400));
    expect(state.media.orientation, Orientation.portrait);

    // Automatic rotation follows the OS; PiP/desktop/TV can disable the fallback.
    await tester.pumpWidget(screen(const Size(360, 400), PlaybackOrientation.auto));
    expect(state.bounds, const Size(360, 400));
    await tester.pumpWidget(screen(const Size(360, 400), PlaybackOrientation.landscape, enabled: false));
    expect(state.bounds, const Size(360, 400));
    expect(probe.currentState, same(state));

    await tester.pumpWidget(screen(const Size(400, 400), PlaybackOrientation.landscape));
    expect(state.bounds, const Size(400, 400));
    expect(state.media.padding, const EdgeInsets.fromLTRB(2, 12, 4, 20));
  });
}
