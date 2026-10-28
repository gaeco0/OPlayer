import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Translate the installed provider's exact trained shader, not bundled weights.
/// Unrecognised GLSL stays on the GPU. Binary weights are OHWI, like NNAPI.
Uint8List? upscaleNetwork(String shader) {
  final digest = sha256.convert(utf8.encode(shader)).toString();
  const modes = {
    '4c53ec2e287908f7ee7bcb266b0170421626d663576468b7d7dafc62962649a4': 0,
    '1a45ad3aa20d8368399f2fd46791deed957c2fd0a4afd131cc92516827abab93': 0,
    'e800dbc5c1c95185cc82216c597724533ff5f2880179f256eef600f03e8dc2ae': 1,
  };
  final mode = modes[digest];
  if (mode == null) return null;
  final bytes = BytesBuilder();
  void integer(int value) {
    final b = ByteData(4)..setUint32(0, value, Endian.little);
    bytes.add(b.buffer.asUint8List());
  }

  void number(double value) {
    if (!value.isFinite) throw const FormatException('Invalid weight');
    final b = ByteData(4)..setFloat32(0, value, Endian.little);
    bytes.add(b.buffer.asUint8List());
  }

  List<double> floats(String text) => text.split(',').map((s) => double.parse(s.trim())).toList();
  final names = <String, int>{mode == 0 ? 'MAIN' : 'LUMA': 0};
  final nodes =
      <({int kernel, List<(int, int)> inputs, List<double> weights, List<double> bias, List<double> alpha})>[];
  for (final pass in shader.split(RegExp(r'(?=//!HOOK)')).skip(1)) {
    final matrices = RegExp(
      r'mat4(?:x4)?\(([^)]+)\)\s*\*\s*(go_[01]|\w+_texOff)\((?:(?:vec2\()?([-\d.]+),\s*([-\d.]+)\)?|0)\)',
    ).allMatches(pass).toList();
    final vectors = RegExp(
      r'vec4\(([^)]+)\)\s*\*\s*float\((\w+)_texOff\(vec2\(([-\d.]+),\s*([-\d.]+)\)\)\)',
    ).allMatches(pass).toList();
    if (matrices.isEmpty && vectors.isEmpty) continue;
    final aliases = <(String, int)>{};
    final contributions = <(String, int, int, int, List<double>)>[];
    var radius = 0;
    for (final m in matrices) {
      final symbol = m[2]!;
      var source = '', activation = 0;
      if (symbol.startsWith('go_')) {
        final definition = RegExp('#define $symbol[^\n]+').firstMatch(pass)![0]!;
        source = RegExp(r'\b(\w+)_texOff').firstMatch(definition)![1]!;
        activation = definition.contains('max(') ? (symbol == 'go_1' ? 2 : 1) : 0;
      } else {
        source = symbol.replaceFirst('_texOff', '');
      }
      final x = double.parse(m[3] ?? '0').toInt(), y = double.parse(m[4] ?? '0').toInt();
      if (x.abs() > radius) radius = x.abs();
      if (y.abs() > radius) radius = y.abs();
      aliases.add((source, activation));
      contributions.add((source, activation, x, y, floats(m[1]!)));
    }
    for (final m in vectors) {
      final x = double.parse(m[3] ?? '0').toInt(), y = double.parse(m[4] ?? '0').toInt();
      if (x.abs() > radius) radius = x.abs();
      if (y.abs() > radius) radius = y.abs();
      aliases.add((m[2]!, 0));
      contributions.add((m[2]!, 0, x, y, floats(m[1]!)));
    }
    for (final skip in RegExp(r'res\s*\+=\s*(\w+)_texOff\(0\)').allMatches(pass)) {
      final identity = List<double>.generate(16, (i) => i % 5 == 0 ? 1 : 0);
      aliases.add((skip[1]!, 0));
      contributions.add((skip[1]!, 0, 0, 0, identity));
    }
    final inputs = aliases.toList();
    final offsets = <(String, int), int>{};
    var channels = 0;
    for (final input in inputs) {
      if (!names.containsKey(input.$1)) throw FormatException('Unknown source ${input.$1}: ${names.keys}');
      offsets[input] = channels;
      channels += names[input.$1] == 0 ? (mode == 0 ? 4 : 1) : 4;
    }
    final kernel = radius * 2 + 1;
    final weights = List<double>.filled(4 * kernel * kernel * channels, 0);
    for (final c in contributions) {
      final offset = offsets[(c.$1, c.$2)]!;
      final count = names[c.$1] == 0 ? (mode == 0 ? 4 : 1) : 4;
      if (c.$5.length != 4 * count) throw const FormatException('Invalid convolution');
      for (var out = 0; out < 4; out++) {
        for (var input = 0; input < count; input++) {
          weights[((out * kernel + c.$4 + radius) * kernel + c.$3 + radius) * channels + offset + input] +=
              c.$5[input * 4 + out];
        }
      }
    }
    final b = RegExp(r'(?:result\s*\+=|vec4\s+res\s*=)\s*vec4\(([^)]+)\)').firstMatch(pass);
    if (b == null) throw const FormatException('Missing convolution bias');
    final alpha = RegExp(r'\+\s*vec4\(([^)]+)\)\s*\*\s*min\(res').firstMatch(pass);
    nodes.add((
      kernel: kernel,
      inputs: inputs.map((e) => (names[e.$1]!, e.$2)).toList(),
      weights: weights,
      bias: floats(b[1]!),
      alpha: alpha == null ? [] : floats(alpha[1]!),
    ));
    final save = RegExp(r'//!SAVE\s+(\w+)').firstMatch(pass)![1]!;
    names[save] = nodes.length;
  }
  if (nodes.length != (mode == 0 ? 4 : 13)) throw const FormatException('Unsupported CNN graph');
  integer(0x3153554f);
  integer(mode);
  integer(nodes.length);
  for (final node in nodes) {
    integer(node.kernel);
    integer(node.inputs.length);
    for (final input in node.inputs) {
      integer(input.$1);
      integer(input.$2);
    }
    integer(node.weights.length);
    for (final weight in node.weights) {
      number(weight);
    }
    for (final bias in node.bias) {
      number(bias);
    }
    integer(node.alpha.length);
    for (final alpha in node.alpha) {
      number(alpha);
    }
  }
  return bytes.takeBytes();
}
