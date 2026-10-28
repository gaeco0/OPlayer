import 'dart:io';
import 'package:oplayer/core/plugins/upscale_network.dart';

void main() {
  for (final name in ['anime4k-s', 'anime4k-denoise-s', 'fsrcnnx-8']) {
    final bytes = upscaleNetwork(File('third_party/ai-upscale/$name.glsl').readAsStringSync());
    if (bytes == null) throw StateError('No network for $name');
    File('.dart_tool/$name.ous').writeAsBytesSync(bytes);
    stdout.writeln('$name: ${bytes.length} bytes');
  }
}
