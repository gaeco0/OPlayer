import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:oplayer/core/media_item.dart';
import 'package:oplayer/core/resource_locks.dart';
import 'package:oplayer/core/resume_store.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/player/player_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Opt-in test against the actual DLL: OPLAYER_TEST_LIBMPV=<absolute DLL path>.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['OPLAYER_TEST_LIBMPV'];
  final enabled = Platform.isWindows && library != null;
  if (Platform.isWindows && library != null) {
    if (!File(library).existsSync()) throw StateError('OPLAYER_TEST_LIBMPV DLL does not exist');
    MediaKit.ensureInitialized(libmpv: library);
  }

  test('native PGS pixels render, then SRT/SMI switch back to the text layer without duplicates', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await AppSettings.instance.init();
    await ResourceLocks.instance.init();
    await ResumeStore.instance.init();
    final player = Player();
    final native = player.platform as NativePlayer;
    final controller = PlayerController(
      playlist: const [MediaItem(key: 'subtitle-test', uri: 'test', title: 'Synthetic subtitle fixture')],
      startIndex: 0,
      playbackEngine: player,
    );
    Future<void> cue() async {
      await player.seek(const Duration(seconds: 1));
      await player.play();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await player.pause();
    }

    try {
      await native.setProperty('vid', 'auto');
      await native.setProperty('vo', 'null');
      await native.setProperty('ao', 'null');
      await native.setProperty('sub-auto', 'no');
      await player.open(Media(File('test/fixtures/subtitles/subtitle-bitmap.mkv').absolute.path), play: false);
      expect(await native.getProperty('hwdec'), 'auto-copy');
      if (player.state.duration == Duration.zero) {
        await player.stream.duration.firstWhere((value) => value > Duration.zero).timeout(const Duration(seconds: 5));
      }
      final track = player.state.tracks.subtitle.firstWhere((t) => t.codec == 'hdmv_pgs_subtitle');
      await controller.selectSubtitleTrack(track);
      await cue();
      expect(await native.getProperty('sub-visibility'), 'yes');
      expect(player.state.subtitle.join(), isEmpty);
      final withSubtitle = await player.screenshot(includeLibassSubtitles: true);
      final withoutSubtitle = await player.screenshot();
      expect(withSubtitle, isNotNull);
      expect(withoutSubtitle, isNotNull);
      expect(
        listEquals(withSubtitle, withoutSubtitle),
        isFalse,
        reason: 'PGS must add actual pixels, not just select a track',
      );

      for (final name in ['subtitle-fixture.srt', 'subtitle-utf8.smi']) {
        final file = File('test/fixtures/subtitles/$name');
        await controller.loadExternalSubtitle(SubtitleRef(file.absolute.uri.toString(), name));
        await cue();
        expect(await native.getProperty('sub-visibility'), 'no');
        expect(player.state.subtitle.join(), isNotEmpty);
      }
      await controller.selectSubtitleTrack(SubtitleTrack.no());
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await native.getProperty('sub-visibility'), 'no');
    } finally {
      controller.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }, skip: enabled ? false : 'Set OPLAYER_TEST_LIBMPV to a Windows libmpv DLL');
}
