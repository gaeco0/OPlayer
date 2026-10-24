import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:oplayer/core/media_item.dart';
import 'package:oplayer/core/resource_locks.dart';
import 'package:oplayer/core/resource_playback_store.dart';
import 'package:oplayer/core/resume_store.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/player/player_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Engine extends PlatformPlayer {
  _Engine() : super(configuration: const PlayerConfiguration());
  Media? opened;
  bool? autoplay;
  final seeks = <Duration>[];
  int plays = 0;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opened = playable as Media;
    autoplay = play;
    state = PlayerState(duration: const Duration(minutes: 10), playing: play);
    positionController.add(Duration.zero);
  }

  Future<void> position(Duration value) async {
    state = state.copyWith(position: value);
    positionController.add(value);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> complete() async {
    completedController.add(true);
    await Future<void>.delayed(Duration.zero);
  }

  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> play() async {
    plays++;
    state = state.copyWith(playing: true);
  }

  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration value) async {
    seeks.add(value);
    await position(value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const saved = Duration(minutes: 3);
  const item = MediaItem(key: 'test://movie', uri: 'https://example.com/movie.mp4', title: 'Movie');
  final store = ResumeStore.instance;
  late _Engine engine;
  late PlayerController controller;
  var disposed = false;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await AppSettings.instance.init();
    await ResourceLocks.instance.init();
    await ResourcePlaybackStore.instance.init();
    await store.init();
    await store.save(item.key, saved, const Duration(minutes: 10));
    engine = _Engine();
    disposed = false;
  });

  tearDown(() async {
    if (!disposed) controller.dispose();
    await Future<void>.delayed(Duration.zero);
  });

  PlayerController create(List<MediaItem> items) => controller = PlayerController(
    playlist: items,
    startIndex: 0,
    playbackEngine: Player(platformPlayer: engine),
  );

  test('early notifications and zero positions cannot erase the native resume start', () async {
    create([item]);
    final offers = <Duration>[];
    var earlyNotification = false;
    controller.addListener(() {
      if (controller.preparing && controller.pendingResume == null) earlyNotification = true;
      if (!controller.preparing && controller.pendingResume != null) offers.add(controller.pendingResume!);
    });
    await controller.open();
    expect(controller.error, isNull);
    expect(earlyNotification, isTrue);
    expect(offers, contains(saved));
    expect(engine.opened!.start, saved);
    await controller.finishResume(controller.openGeneration);
    await engine.position(Duration.zero);
    await controller.saveNow();
    await engine.complete();
    expect(store.get(item.key)!.position, saved);
    await engine.position(saved + const Duration(seconds: 2));
    await controller.saveNow();
    expect(store.get(item.key)!.position, saved + const Duration(seconds: 2));
    expect(engine.seeks, isEmpty);
  });

  test('a delayed failed resolve preserves the saved position', () async {
    final resolving = Completer<MediaItem>();
    create([MediaItem(key: item.key, uri: item.uri, title: item.title, resolver: () => resolving.future)]);
    final opening = controller.open();
    await Future<void>.delayed(Duration.zero);
    engine.state = PlayerState(duration: const Duration(minutes: 10));
    await engine.position(Duration.zero);
    await controller.saveNow();
    expect(store.get(item.key)!.position, saved);
    // Simulate a failed source without allowing its zero state to replace history.
    resolving.completeError(StateError('connection lost'));
    await opening;
    expect(controller.error, contains('connection lost'));
    await controller.saveNow();
    expect(store.get(item.key)!.position, saved);
  });

  test('closing while resolving does not replace the bookmark or notify a disposed controller', () async {
    final resolving = Completer<MediaItem>();
    create([MediaItem(key: item.key, uri: item.uri, title: item.title, resolver: () => resolving.future)]);
    final opening = controller.open();
    await Future<void>.delayed(Duration.zero);
    engine.state = PlayerState(duration: const Duration(minutes: 10));
    controller.dispose();
    disposed = true;
    resolving.complete(item);
    await opening;
    expect(store.get(item.key)!.position, saved);
    expect(engine.opened, isNull);
  });

  test('automatic resume records progress even without a visible player screen', () async {
    create([item]);
    await controller.open();
    expect(engine.opened!.start, saved);
    await engine.position(saved + const Duration(seconds: 4));
    await controller.saveNow();
    expect(store.get(item.key)!.position, saved + const Duration(seconds: 4));
  });

  test('ask mode pauses at the saved start and only explicit start-over clears it', () async {
    AppSettings.instance.resumeMode = ResumeMode.ask;
    create([item]);
    await controller.open();
    expect(engine.autoplay, isFalse);
    await engine.position(saved);
    await controller.saveNow();
    expect(store.get(item.key)!.position, saved);
    await controller.finishResume(controller.openGeneration, fromBeginning: true);
    expect(engine.seeks, [Duration.zero]);
    expect(engine.plays, 1);
    await engine.position(const Duration(seconds: 2));
    await controller.saveNow();
    expect(store.get(item.key)!.position, const Duration(seconds: 2));
  });

  test('an old resume answer cannot seek or play the next file', () async {
    const next = MediaItem(key: 'test://next', uri: 'https://example.com/next.mp4', title: 'Next');
    create([item, next]);
    await controller.open();
    final oldGeneration = controller.openGeneration;
    await controller.next();
    await controller.finishResume(oldGeneration, fromBeginning: true);
    expect(engine.seeks, isEmpty);
    expect(engine.plays, 0);
    expect(controller.current.key, next.key);
    expect(store.get(item.key)!.position, saved);
    expect(engine.opened!.start, isNull);
  });

  test('resume off and automatic next still open from the beginning', () async {
    AppSettings.instance.resumeMode = ResumeMode.off;
    create([item]);
    await controller.open();
    expect(engine.opened!.start, isNull);
    expect(controller.pendingResume, isNull);
    expect(engine.autoplay, isTrue);
    AppSettings.instance.resumeMode = ResumeMode.auto;
    await controller.open(askResume: false);
    expect(engine.opened!.start, isNull);
    expect(controller.pendingResume, isNull);
  });
}
