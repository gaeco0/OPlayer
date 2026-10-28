import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/media_item.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/player/player_controller.dart';
import 'package:oplayer/features/player/widgets/controls_overlay.dart';
import 'package:oplayer/features/player/widgets/side_panels.dart';

class _Engine extends PlatformPlayer {
  _Engine() : super(configuration: const PlayerConfiguration());

  void selectSubtitle(SubtitleTrack subtitle) {
    state = state.copyWith(track: state.track.copyWith(subtitle: subtitle));
    trackController.add(state.track);
  }
}

void main() {
  testWidgets('AI overlay toggle stays visible at compact width and moves to more in portrait', (t) async {
    SharedPreferences.setMockInitialValues({'settings_v1': '{}'});
    await AppSettings.instance.init();
    final controller = PlayerController(
      playlist: const [MediaItem(key: 'ai-test', uri: 'https://example.com/video.mp4', title: 'Video')],
      startIndex: 0,
      playbackEngine: Player(platformPlayer: _Engine()),
    );
    t.view.physicalSize = const Size(800, 450);
    t.view.devicePixelRatio = 1;
    addTearDown(() {
      controller.dispose();
      t.view.reset();
    });
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ControlsOverlay(
            c: controller,
            onBack: () {},
            onToast: (_) {},
            onRotate: null,
            orientationIcon: Icons.screen_rotation,
            onPanel: (_) {},
          ),
        ),
      ),
    );
    AppSettings.instance.update((s) {
      s.interpolationMode = 'rife';
      s.frameInterpolation = true;
    });
    await t.pumpAndSettle();
    final button = find.widgetWithText(TextButton, 'AI 보간');
    expect(button.hitTestable(), findsOneWidget);
    expect(t.widget<TextButton>(button).style!.backgroundColor!.resolve({}), Colors.white);
    expect(t.takeException(), isNull);
    t.view.physicalSize = const Size(600, 360);
    await t.pumpAndSettle();
    final compactButton = find.widgetWithText(TextButton, '보간');
    expect(compactButton.hitTestable(), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.tap(compactButton);
    await t.pumpAndSettle();
    expect(AppSettings.instance.frameInterpolation, false);
    expect(AppSettings.instance.interpolationMode, 'rife');
    t.view.physicalSize = const Size(360, 800);
    await t.pumpAndSettle();
    expect(button, findsNothing);
    expect(compactButton, findsNothing);
    expect(find.byTooltip('재생 설정'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('player screen button opens quality controls and both switches change playback settings', (t) async {
    SharedPreferences.setMockInitialValues({'settings_v1': '{}'});
    await AppSettings.instance.init();
    final engine = _Engine();
    final controller = PlayerController(
      playlist: const [MediaItem(key: 'test', uri: 'https://example.com/video.mp4', title: 'Video')],
      startIndex: 0,
      playbackEngine: Player(platformPlayer: engine),
    );
    t.view.physicalSize = const Size(1200, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(() {
      controller.dispose();
      t.view.reset();
    });
    var panel = PanelKind.none;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) => Stack(
              children: [
                ControlsOverlay(
                  c: controller,
                  onBack: () {},
                  onToast: (_) {},
                  onRotate: null,
                  orientationIcon: Icons.screen_rotation,
                  onPanel: (value) => update(() => panel = value),
                ),
                SidePanel(
                  kind: panel,
                  c: controller,
                  onClose: () => update(() => panel = PanelKind.none),
                  onToast: (_) {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await t.tap(find.byTooltip('화면·화질'));
    await t.pumpAndSettle();
    expect(panel, PanelKind.aspect);
    final upscaling = find.widgetWithText(SwitchListTile, '고화질 업스케일');
    final interpolation = find.widgetWithText(SwitchListTile, '프레임 보간');
    expect(upscaling.hitTestable(), findsOneWidget);
    expect(interpolation.hitTestable(), findsOneWidget);
    await t.tap(upscaling);
    await t.pumpAndSettle();
    expect(AppSettings.instance.videoUpscaling, true);
    await t.tap(interpolation);
    await t.pumpAndSettle();
    expect(AppSettings.instance.frameInterpolation, true);
    await t.tap(upscaling);
    await t.pumpAndSettle();
    await t.tap(interpolation);
    await t.pumpAndSettle();
    expect(AppSettings.instance.videoUpscaling, false);
    expect(AppSettings.instance.frameInterpolation, false);
    // 데스크톱 더보기에서도 두 설정을 바로 조작할 수 있어야 합니다.
    await t.tap(find.byIcon(Icons.close));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('더보기'));
    await t.pumpAndSettle();
    expect(panel, PanelKind.more);
    expect(upscaling.hitTestable(), findsOneWidget);
    expect(interpolation.hitTestable(), findsOneWidget);
    await t.tap(upscaling);
    await t.pumpAndSettle();
    await t.tap(interpolation);
    await t.pumpAndSettle();
    expect(AppSettings.instance.videoUpscaling, true);
    expect(AppSettings.instance.frameInterpolation, true);
    await t.tap(find.byIcon(Icons.close));
    await t.pumpAndSettle();
    final upscaleButton = find.widgetWithText(TextButton, '업스케일');
    final interpolateButton = find.widgetWithText(TextButton, '보간');
    final subtitleButton = find.widgetWithText(TextButton, '자막');
    Color? background(Finder button) => t.widget<TextButton>(button).style!.backgroundColor!.resolve({});
    Color? foreground(Finder button) => t.widget<TextButton>(button).style!.foregroundColor!.resolve({});
    expect(background(upscaleButton), Colors.white);
    expect(foreground(upscaleButton), Colors.black);
    expect(background(interpolateButton), Colors.white);
    await t.tap(upscaleButton);
    await t.pumpAndSettle();
    await t.tap(interpolateButton);
    await t.pumpAndSettle();
    expect(AppSettings.instance.videoUpscaling, false);
    expect(AppSettings.instance.frameInterpolation, false);
    expect(background(upscaleButton), Colors.transparent);
    expect(foreground(upscaleButton), Colors.white);
    expect(background(subtitleButton), Colors.transparent);
    engine.selectSubtitle(const SubtitleTrack('1', 'ko', 'Korean'));
    await t.pumpAndSettle();
    expect(background(subtitleButton), Colors.white);
    expect(foreground(subtitleButton), Colors.black);
    await t.tap(subtitleButton);
    await t.pumpAndSettle();
    expect(panel, PanelKind.subtitle);
    await t.tap(find.byIcon(Icons.close));
    await t.pumpAndSettle();
    engine.selectSubtitle(SubtitleTrack.no());
    await t.pumpAndSettle();
    expect(background(subtitleButton), Colors.transparent);
    // 최소 가로 폭에서는 버튼이 넘치지 않아야 합니다.
    t.view.physicalSize = const Size(600, 360);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(upscaleButton.hitTestable(), findsOneWidget);
    // 작은 세로 화면에서는 오버레이 버튼 대신 더보기에서 설정합니다.
    t.view.physicalSize = const Size(360, 800);
    await t.pumpAndSettle();
    expect(upscaleButton, findsNothing);
    expect(interpolateButton, findsNothing);
    await t.tap(find.byTooltip('재생 설정'));
    await t.pumpAndSettle();
    await t.tap(find.text('더보기'));
    await t.pumpAndSettle();
    expect(panel, PanelKind.more);
    expect(upscaling.hitTestable(), findsOneWidget);
    expect(interpolation.hitTestable(), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
