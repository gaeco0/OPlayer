import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:oplayer/core/ffmpeg.dart';
import 'package:oplayer/core/media_item.dart';
import 'package:oplayer/core/resource_locks.dart';
import 'package:oplayer/core/resume_store.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/player/player_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SubtitlePlayer extends PlatformPlayer {
  _SubtitlePlayer() : super(configuration: const PlayerConfiguration());
  final loaded = <SubtitleTrack>[];
  bool supportsSami = false;
  @override
  Future<void> open(Playable playable, {bool play = true}) async {}
  @override
  Future<void> setRate(double value) async {}
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    if (!supportsSami && Uri.parse(track.id).path.endsWith('.smi')) throw UnsupportedError('SAMI');
    if (track.uri) loaded.add(track);
    state = state.copyWith(track: state.track.copyWith(subtitle: track));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('oplayer/ffmpeg');
  late Directory directory;
  late _SubtitlePlayer engine;
  late PlayerController controller;
  final executions = <List<String>>[];
  Completer<void>? converting;
  var succeeds = true;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await AppSettings.instance.init();
    await ResourceLocks.instance.init();
    await ResumeStore.instance.init();
    directory = await Directory.systemTemp.createTemp('oplayer_subtitle_load_');
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    Ffmpeg.reset();
    converting = null;
    succeeds = true;
    executions.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'version') return 'test';
      final args = List<String>.from((call.arguments as Map)['arguments'] as List);
      executions.add(args);
      await converting?.future;
      if (!succeeds) return {'code': 1, 'error': 'bad SAMI'};
      await File(args.last).writeAsString('1\n00:00:00,100 --> 00:00:03,900\n자막 테스트\n');
      return {'code': 0, 'error': ''};
    });
    engine = _SubtitlePlayer();
    controller = PlayerController(
      playlist: const [MediaItem(key: 'test', uri: 'https://example.com/video.mp4', title: 'Video')],
      startIndex: 0,
      playbackEngine: Player(platformPlayer: engine),
    );
  });
  tearDown(() async {
    controller.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await directory.delete(recursive: true);
    debugDefaultTargetPlatformOverride = null;
    Ffmpeg.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'SMI converts to UTF-8 SRT before loading; original subtitle is preserved and SRT needs no conversion',
    () async {
      final smi = File('${directory.path}/한글 자막.smi');
      const original = '<SAMI><BODY><SYNC Start=100><P>자막 테스트</BODY></SAMI>';
      await smi.writeAsString(original);
      await controller.loadExternalSubtitle(SubtitleRef(smi.uri.toString(), 'Korean'));
      final converted = File.fromUri(Uri.parse(engine.loaded.single.id));
      expect(converted.path, endsWith('.srt'));
      expect(await converted.readAsString(), contains('자막 테스트'));
      expect(await smi.readAsString(), original);
      final args = executions.single;
      expect(args[args.indexOf('-sub_charenc') + 1], 'UTF-8');
      expect(args[args.indexOf('-i') + 1], smi.uri.toFilePath());
      expect(engine.loaded.single.title, 'Korean');
      await controller.loadExternalSubtitle(SubtitleRef(converted.uri.toString(), 'SRT'));
      expect(executions, hasLength(1));
      expect(engine.loaded, hasLength(2));
    },
  );

  test('legacy Korean SMI uses CP949, and a failed conversion is not marked as selected', () async {
    final smi = File('${directory.path}/legacy.smi');
    await smi.writeAsBytes([0xb0, 0xa1]);
    succeeds = false;
    await expectLater(controller.loadExternalSubtitle(SubtitleRef(smi.uri.toString(), 'Legacy')), throwsStateError);
    final args = executions.single;
    expect(args[args.indexOf('-sub_charenc') + 1], 'CP949');
    expect(engine.loaded, isEmpty);
    expect(engine.state.track.subtitle.id, 'auto');
    expect(await File(args.last).exists(), false);
  });

  test('an engine that already supports SAMI keeps native loading without FFmpeg', () async {
    engine.supportsSami = true;
    final smi = File('${directory.path}/native.smi');
    await smi.writeAsString('<SAMI></SAMI>');
    await controller.loadExternalSubtitle(SubtitleRef(smi.uri.toString(), 'Native'));
    expect(engine.loaded.single.id, smi.uri.toString());
    expect(executions, isEmpty);
  });

  test('a slow subtitle conversion cannot replace the subtitle of a newly opened video', () async {
    final smi = File('${directory.path}/old.smi');
    await smi.writeAsString('<SAMI></SAMI>');
    converting = Completer<void>();
    final loading = controller.loadExternalSubtitle(SubtitleRef(smi.uri.toString(), 'Old'));
    while (executions.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await controller.open(askResume: false);
    converting!.complete();
    await loading;
    expect(engine.loaded, isEmpty);
    expect(await File(executions.single.last).exists(), false);
  });
}
