// flutter run -d windows --debug --no-pub -t tool/window_native_smoke.dart
// Uses only this test process's runner window; no user settings or media.
import 'dart:ffi';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

typedef _WindowCallback = Int32 Function(IntPtr, IntPtr);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('OPlayer window mode test'))),
    ),
  );
  await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
  await Future<void>.delayed(const Duration(milliseconds: 300));
  final user32 = DynamicLibrary.open('user32.dll');
  final allocate = DynamicLibrary.open(
    'ole32.dll',
  ).lookupFunction<Pointer<Void> Function(UintPtr), Pointer<Void> Function(int)>('CoTaskMemAlloc');
  final free = DynamicLibrary.open(
    'ole32.dll',
  ).lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('CoTaskMemFree');
  final memory = allocate(64).cast<Int32>();
  final processOf = user32.lookupFunction<Uint32 Function(IntPtr, Pointer<Int32>), int Function(int, Pointer<Int32>)>(
    'GetWindowThreadProcessId',
  );
  final isVisible = user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsWindowVisible');
  final enumerate = user32
      .lookupFunction<
        Int32 Function(Pointer<NativeFunction<_WindowCallback>>, IntPtr),
        int Function(Pointer<NativeFunction<_WindowCallback>>, int)
      >('EnumWindows');
  final getRect = user32.lookupFunction<Int32 Function(IntPtr, Pointer<Int32>), int Function(int, Pointer<Int32>)>(
    'GetWindowRect',
  );
  final getStyle = user32.lookupFunction<IntPtr Function(IntPtr, Int32), int Function(int, int)>('GetWindowLongPtrW');
  final monitorOf = user32.lookupFunction<IntPtr Function(IntPtr, Uint32), int Function(int, int)>('MonitorFromWindow');
  final monitorInfo = user32.lookupFunction<Int32 Function(IntPtr, Pointer<Int32>), int Function(int, Pointer<Int32>)>(
    'GetMonitorInfoW',
  );
  final show = user32.lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>('ShowWindow');
  final zoomed = user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsZoomed');
  var window = 0;
  final callback = NativeCallable<_WindowCallback>.isolateLocal((int hwnd, int _) {
    processOf(hwnd, memory);
    if (memory.value == pid && isVisible(hwnd) != 0) {
      window = hwnd;
      return 0;
    }
    return 1;
  }, exceptionalReturn: 0);
  const channel = MethodChannel('oplayer/window');
  const frame = 0x00cf0000; // WS_OVERLAPPEDWINDOW
  List<int> rect() {
    getRect(window, memory);
    return memory.asTypedList(4).toList();
  }

  bool same(List<int> a, List<int> b) => List.generate(a.length, (i) => a[i] == b[i]).every((v) => v);
  void check(bool value, String message) {
    if (!value) throw StateError(message);
  }

  Future<void> mode(String name, bool enabled) async {
    await channel.invokeMethod<void>(name, enabled);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  try {
    enumerate(callback.nativeFunction, 0);
    check(window != 0, 'Runner not found');
    final original = rect();
    final originalStyle = getStyle(window, -16);
    memory.value = 40;
    check(monitorInfo(monitorOf(window, 2), memory) != 0, 'Monitor info failed');
    final monitor = memory.asTypedList(5).skip(1).toList();
    Future<void> fullscreen() async {
      await mode('fullscreen', true);
      check((getStyle(window, -16) & frame) == 0, 'Window frame still present');
      check(same(rect(), monitor), 'Fullscreen does not cover monitor');
      await mode('fullscreen', true); // Idempotent, original placement must survive.
    }

    await fullscreen();
    await mode('fullscreen', false);
    check(same(rect(), original) && getStyle(window, -16) == originalStyle, 'Normal placement/style not restored');
    await mode('compact', true);
    check((getStyle(window, -20) & 8) != 0, 'Compact is not topmost');
    await fullscreen();
    check((getStyle(window, -20) & 8) == 0, 'Compact topmost leaked into fullscreen');
    await mode('fullscreen', false);
    check(same(rect(), original), 'Compact to fullscreen did not restore normal placement');
    await fullscreen();
    await mode('compact', true);
    check((getStyle(window, -16) & frame) == (originalStyle & frame), 'Compact retained borderless style');
    await mode('compact', false);
    check(same(rect(), original), 'Fullscreen to compact did not restore placement');
    show(window, 3); // SW_MAXIMIZE
    await fullscreen();
    await mode('fullscreen', false);
    check(zoomed(window) != 0, 'Maximized placement not restored');
    debugPrint('WINDOW_MODE_SMOKE_OK: normal, maximized, fullscreen and compact restoration');
  } finally {
    await channel.invokeMethod<void>('fullscreen', false);
    await channel.invokeMethod<void>('compact', false);
    callback.close();
    free(memory.cast<Void>());
  }
  await Future<void>.delayed(const Duration(seconds: 2));
  exit(0);
}
