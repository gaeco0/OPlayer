// Run with: flutter run -d windows --debug --no-pub -t tool/privacy_native_smoke.dart
// Verifies the actual runner window, without opening an authentication prompt
// or reading/writing app credentials and settings.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

typedef _EnumCallback = Int32 Function(IntPtr, IntPtr);

String referenceHash(String value) {
  final salt = Uint8List.fromList(List.generate(32, (i) => i));
  final hash = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))..init(Pbkdf2Parameters(salt, 210000, 32));
  return base64Encode(hash.process(Uint8List.fromList(utf8.encode(value))));
}

Future<void> main() async {
  if (!Platform.isWindows) throw UnsupportedError('Windows only');
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('OPlayer native privacy test'))),
    ),
  );
  await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
  await Future<void>.delayed(const Duration(milliseconds: 300));
  const channel = MethodChannel('oplayer/privacy');
  final user32 = DynamicLibrary.open('user32.dll');
  final allocate = DynamicLibrary.open(
    'ole32.dll',
  ).lookupFunction<Pointer<Void> Function(UintPtr), Pointer<Void> Function(int)>('CoTaskMemAlloc');
  final free = DynamicLibrary.open(
    'ole32.dll',
  ).lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('CoTaskMemFree');
  final process = allocate(4).cast<Uint32>();
  final affinity = allocate(4).cast<Uint32>();
  final processOf = user32.lookupFunction<Uint32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>(
    'GetWindowThreadProcessId',
  );
  final visible = user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsWindowVisible');
  final enumerate = user32
      .lookupFunction<
        Int32 Function(Pointer<NativeFunction<_EnumCallback>>, IntPtr),
        int Function(Pointer<NativeFunction<_EnumCallback>>, int)
      >('EnumWindows');
  final readAffinity = user32
      .lookupFunction<Int32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>(
        'GetWindowDisplayAffinity',
      );
  var window = 0;
  final callback = NativeCallable<_EnumCallback>.isolateLocal((int hwnd, int _) {
    processOf(hwnd, process);
    if (process.value == pid && visible(hwnd) != 0) {
      window = hwnd;
      return 0;
    }
    return 1;
  }, exceptionalReturn: 0);
  final states = <int>[];
  try {
    enumerate(callback.nativeFunction, 0);
    if (window == 0) throw StateError('Runner window not found');
    Future<void> check(bool enabled) async {
      if (readAffinity(window, affinity) == 0) throw StateError('GetWindowDisplayAffinity failed');
      states.add(affinity.value);
      if ((affinity.value != 0) != enabled) throw StateError('Unexpected native capture state: ${affinity.value}');
    }

    Future<void> policy(bool appLock, bool shield) =>
        channel.invokeMethod('setLockPolicy', {'appLock': appLock, 'shielded': shield, 'preventCapture': false});
    await policy(false, false);
    await check(false);
    await channel.invokeMethod('setCaptureProtection', true);
    await check(true);
    await channel.invokeMethod('setCaptureProtection', false);
    await check(false);
    await policy(true, false);
    await check(true);
    await channel.invokeMethod('setCaptureProtection', false);
    await check(true);
    await policy(false, true);
    await check(true);
    await policy(false, false);
    await check(false);
    final available = await channel.invokeMethod<bool>('biometricAvailable').timeout(const Duration(seconds: 15));
    final timings = <Map<String, Object>>[];
    for (final value in ['123456', 'pattern:0,1,2,5,8']) {
      final watch = Stopwatch()..start();
      final reference = await compute(referenceHash, value);
      final dartMs = watch.elapsedMicroseconds / 1000;
      watch.reset();
      final native = await channel.invokeMethod<Uint8List>('deriveLockHash', {
        'value': value,
        'salt': Uint8List.fromList(List.generate(32, (i) => i)),
      });
      final nativeMs = watch.elapsedMicroseconds / 1000;
      if (native == null || base64Encode(native) != reference) throw StateError('Native PBKDF2 is incompatible');
      timings.add({'kind': value.startsWith('pattern') ? 'pattern' : 'PIN', 'dartMs': dartMs, 'nativeMs': nativeMs});
    }
    final report = {'captureAffinity': states, 'windowsHelloAvailable': available, 'hashTimings': timings};
    await File('D:/Data/Projects/OPlayer/.dart_tool/privacy_native_result.json').writeAsString(jsonEncode(report));
    debugPrint('PRIVACY_NATIVE_OK ${jsonEncode(report)}');
  } catch (error, stack) {
    debugPrint('PRIVACY_NATIVE_FAILED $error\n$stack');
    exitCode = 1;
  } finally {
    callback.close();
    free(process.cast<Void>());
    free(affinity.cast<Void>());
  }
  // Let flutter run attach before this short-lived test exits.
  await Future<void>.delayed(const Duration(seconds: 5));
  exit(exitCode);
}
