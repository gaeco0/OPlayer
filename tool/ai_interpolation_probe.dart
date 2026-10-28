import 'dart:ffi';
import 'dart:io';
import 'package:ai_frame_engine/engine.dart' as rife;
import 'package:ffi/ffi.dart';

void main(List<String> args) {
  final path = File('assets/models/rife-v4.6/flownet.param').parent.absolute.path.toNativeUtf8();
  const w = 128, h = 72, length = w * h * 4;
  final a = calloc<Uint8>(length), b = calloc<Uint8>(length), out = calloc<Uint8>(length);
  try {
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = (y * w + x) * 4;
        for (var c = 0; c < 3; c++) {
          a[i + c] = x >= 24 && x < 56 && y >= 20 && y < 52 ? 230 : 20;
          b[i + c] = x >= 40 && x < 72 && y >= 20 && y < 52 ? 230 : 20;
        }
        a[i + 3] = b[i + 3] = 255;
      }
    }
    final clock = Stopwatch()..start();
    final result = rife.probe(
      path.cast(),
      a,
      b,
      out,
      w,
      h,
      (args.contains('--cpu') ? 0 : 1) | (args.contains('--fused') ? 2 : 0),
    );
    if (result != 0) throw StateError('RIFE inference failed: $result');
    var differs = 0;
    for (var i = 0; i < length; i += 4) {
      if ((out[i] - (a[i] + b[i]) / 2).abs() > 15) differs++;
    }
    if (differs < 200) throw StateError('Output resembles frame blending: $differs');
    File(
      args.contains('--fused') ? '.dart_tool/rife-midframe-fused.bgra' : '.dart_tool/rife-midframe.bgra',
    ).writeAsBytesSync(out.asTypedList(length));
    stdout.writeln('RIFE generated midpoint: ${clock.elapsedMilliseconds} ms; $differs pixels differ from blending.');
  } finally {
    calloc.free(path);
    calloc.free(a);
    calloc.free(b);
    calloc.free(out);
  }
}
