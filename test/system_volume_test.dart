import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oplayer/features/player/system_volume.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const method = MethodChannel('com.kurenai7968.volume_controller.method');
  const events = 'com.kurenai7968.volume_controller.volume_listener_event';
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late double osVolume;
  late List<double> writes;
  setUp(() {
    osVolume = .37;
    writes = [];
    messenger.setMockMethodCallHandler(method, (call) async {
      if (call.method == 'getVolume') return osVolume;
      if (call.method == 'setVolume') {
        osVolume = (call.arguments as Map)['volume'] as double;
        writes.add(osVolume);
      }
      return null;
    });
    messenger.setMockMethodCallHandler(const MethodChannel(events), (_) async => null);
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(method, null);
    messenger.setMockMethodCallHandler(const MethodChannel(events), null);
  });

  test('inherits OS volume without writes; external keys and rapid inputs use current OS values', () async {
    final volume = SystemVolume();
    await volume.ready;
    expect(volume.value, .37);
    expect(writes, isEmpty);
    osVolume = .8; // An OS change whose event has not reached the app yet.
    await Future.wait([volume.adjust(.02), volume.adjust(.02)]);
    expect(osVolume, closeTo(.84, .00001));
    expect(writes, hasLength(2));
    await volume.set(2);
    expect(osVolume, 1);
    await volume.adjust(-2);
    expect(osVolume, 0);
    final writesBeforeDispose = writes.length;
    volume.dispose();
    await expectLater(volume.adjust(.1), throwsStateError);
    expect(writes.length, writesBeforeDispose);
  });

  test('OS events update gesture baseline and opening another file preserves volume', () async {
    final volume = SystemVolume();
    await volume.ready;
    await Future<void>.delayed(Duration.zero);
    final delivered = Completer<void>();
    messenger.handlePlatformMessage(
      events,
      const StandardMethodCodec().encodeSuccessEnvelope(.63),
      (_) => delivered.complete(),
    );
    await delivered.future;
    await Future<void>.delayed(Duration.zero);
    expect(volume.value, .63);
    osVolume = .63;
    volume.dispose();
    final next = SystemVolume();
    await next.ready;
    expect(next.value, .63);
    expect(writes, isEmpty);
    next.dispose();
  });

  test('an absent device does not change OS volume and control recovers when it returns', () async {
    var absent = true;
    messenger.setMockMethodCallHandler(method, (call) async {
      if (absent) throw PlatformException(code: 'no-device');
      if (call.method == 'getVolume') return osVolume;
      osVolume = (call.arguments as Map)['volume'] as double;
      writes.add(osVolume);
      return null;
    });
    final volume = SystemVolume();
    await expectLater(volume.ready, throwsA(isA<PlatformException>()));
    await expectLater(volume.adjust(.1), throwsA(isA<PlatformException>()));
    expect(writes, isEmpty);
    absent = false;
    await volume.adjust(.1);
    expect(osVolume, closeTo(.47, .00001));
    volume.dispose();
  });
}
