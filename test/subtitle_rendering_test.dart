import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:oplayer/features/player/player_controller.dart';

class _Engine extends PlatformPlayer {
  _Engine() : super(configuration: const PlayerConfiguration());
  void subtitle(String text) => subtitleController.add([text, '']);
}

class _Video implements VideoController {
  _Video(this.player);
  @override
  final Player player;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('image subtitle codecs use native rendering; text and disabled tracks do not', () {
    for (final codec in ['hdmv_pgs_subtitle', 'pgssub', 'dvd_subtitle', 'dvdsub', 'dvb_subtitle', 'dvbsub', 'xsub']) {
      expect(bitmapSubtitle(SubtitleTrack('1', null, null, codec: codec)), true);
    }
    for (final codec in ['subrip', 'ass', 'sami', 'webvtt', null]) {
      expect(bitmapSubtitle(SubtitleTrack('1', null, null, codec: codec)), false);
    }
    expect(bitmapSubtitle(SubtitleTrack.no()), false);
  });

  testWidgets('shared text subtitle layer displays Korean cues, updates, and clears', (tester) async {
    final engine = _Engine();
    final player = Player(platformPlayer: engine);
    await tester.pumpWidget(
      MaterialApp(
        home: SubtitleView(controller: _Video(player), configuration: const SubtitleViewConfiguration()),
      ),
    );
    engine.subtitle('한국어 자막 표시');
    await tester.pump();
    final paragraph = tester.renderObject<RenderParagraph>(find.text('한국어 자막 표시'));
    expect(paragraph.size.height, greaterThan(0));
    expect(paragraph.size.width, greaterThan(0));
    expect(paragraph.text.style?.color, Colors.white);
    engine.subtitle('다음 대사');
    await tester.pump();
    await tester.pump();
    expect(find.text('다음 대사'), findsOneWidget);
    expect(find.text('한국어 자막 표시'), findsNothing);
    engine.subtitle('');
    await tester.pump();
    await tester.pump();
    expect(find.text('다음 대사'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await player.dispose();
  });
}
