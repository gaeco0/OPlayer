import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class ByeDpi {
  static const _native = MethodChannel('oplayer/network');
  Process? _process;
  int? port;
  String _lastError = '';
  void Function()? onExit;

  Future<void> start() async {
    if (port != null) return;
    final reservation = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final selectedPort = reservation.port;
    await reservation.close();
    String executable;
    if (Platform.isAndroid) {
      final dir = await _native.invokeMethod<String>('nativeLibraryDir');
      if (dir == null) throw StateError('ByeDPI 설치 경로를 찾지 못했습니다');
      executable = '$dir/libciadpi.so';
    } else if (Platform.isWindows) {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/network/ciadpi-0.17.3.exe');
      await file.parent.create(recursive: true);
      final asset = await rootBundle.load('assets/native/windows/ciadpi.exe');
      await file.writeAsBytes(
        asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
        flush: true,
      );
      executable = file.path;
    } else {
      throw UnsupportedError('ByeDPI는 Android와 Windows에서 지원합니다');
    }
    _lastError = '';
    final process = await Process.start(executable, [
      '--ip',
      '127.0.0.1',
      '--port',
      '$selectedPort',
      '--no-udp',
      '--disorder',
      '1',
      '--auto=torst',
      '--tlsrec',
      '1+s',
    ]);
    _process = process;
    process.stdout.drain<void>();
    process.stderr.transform(utf8.decoder).listen((text) {
      _lastError = text.length > 1024 ? text.substring(text.length - 1024) : text;
    });
    unawaited(
      process.exitCode.then((_) async {
        if (_process == process) {
          _process = null;
          port = null;
          await _native.invokeMethod<void>('forgetProcess');
          onExit?.call();
        }
      }),
    );
    try {
      // Native owners terminate this child when the application exits or crashes.
      await _native.invokeMethod<void>('ownProcess', process.pid);
      for (var attempt = 0; attempt < 30; attempt++) {
        if (_process != process) throw StateError('ByeDPI 시작 실패: $_lastError');
        try {
          final socket = await Socket.connect(
            '127.0.0.1',
            selectedPort,
            timeout: const Duration(milliseconds: 150),
          );
          socket.destroy();
          port = selectedPort;
          return;
        } on SocketException {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      throw StateError('ByeDPI 시작 시간 초과: $_lastError');
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  Future<void> stop() async {
    final process = _process;
    _process = null;
    port = null;
    if (process != null) {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
      }
      await _native.invokeMethod<void>('forgetProcess');
    }
  }
}
