import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'plugin.dart';
import 'frame_processor.dart';

/// A small vector instruction set, not a catalog of named video effects.
/// Each instruction is [opcode * 8 + destination, a, b, c]. Eight RGB registers,
/// at most 64 instructions/pass; texture sampling never crosses the JS bridge.
class PixelProgram {
  PixelProgram._(this.code);
  final List<List<double>> code;
  List<double> get uniforms => [for (final op in code) ...op, ...List.filled((64 - code.length) * 4, 0.0)];
  String get digest => sha256.convert(utf8.encode(jsonEncode(code))).toString();
  String get shader {
    final lines = <String>[];
    String n(double v) => v.toString();
    for (final i in code) {
      final op = i[0].toInt() ~/ 8, d = i[0].toInt() % 8;
      final a = i[1].toInt(), b = i[2].toInt(), c = i[3].toInt();
      final expression = switch (op) {
        0 => 'vec3(${i.skip(1).map(n).join(',')})',
        1 || 2 => 'HOOKED_texOff(vec2(${n(i[1])},${n(i[2])})).rgb * ${n(i[3])}',
        3 => 'r$a + r$b',
        4 => 'r$a - r$b',
        5 => 'r$a * r$b',
        6 => 'oplayer_div(r$a,r$b)',
        7 => 'min(r$a,r$b)',
        8 => 'max(r$a,r$b)',
        9 => 'pow(max(r$a,vec3(0.000001)),clamp(r$b,vec3(-16.0),vec3(16.0)))',
        10 => 'clamp(r$a,vec3(${n(i[2])}),vec3(${n(i[3])}))',
        11 => 'vec3(dot(r$a,r$b))',
        12 => 'r$a',
        13 => 'vec3(HOOKED_pos,0.0)',
        14 => 'sin(r$a)',
        15 => 'abs(r$a)',
        17 => 'exp(clamp(r$a,vec3(-16.0),vec3(16.0)))',
        18 => 'sqrt(max(r$a,vec3(0.0)))',
        19 => 'cos(r$a)',
        20 => 'floor(r$a)',
        _ => '',
      };
      lines.add(op == 16 ? 'r$d[$c] = dot(r$a,r$b);' : 'r$d ${op == 2 ? '+=' : '='} $expression;');
    }
    return '''//!HOOK MAIN
//!BIND HOOKED
//!DESC Extension pixel program
vec3 oplayer_div(vec3 a,vec3 b) {
 return a / (mix(vec3(1.0),vec3(-1.0),lessThan(b,vec3(0.0))) * max(abs(b),vec3(0.000001)));
}
vec4 hook() {
 ${[for (var i = 0; i < 8; i++) 'vec3 r$i = vec3(0.0);'].join('\n ')}
 ${lines.join('\n ')}
 return vec4(clamp(r0,0.0,1.0),HOOKED_tex(HOOKED_pos).a);
}
''';
  }
}

Future<List<PixelProgram>?> pixelPrograms(OPlugin plugin, Map<String, dynamic> config) async {
  final result = await frameProcessor(plugin, {'operation': 'videoFilter'}, config: config);
  if (result == null) return null; // Legacy scalar filters retain their old contract.
  return parsePixelPrograms(result);
}

List<PixelProgram> parsePixelPrograms(Map<String, dynamic> program) {
  final passes = program['passes'];
  if (program['engine'] != 'pixel-program-v1' ||
      program['inputFrames'] != 1 ||
      program['outputFrames'] != 1 ||
      passes is! List ||
      passes.length > 8) {
    throw const FormatException('잘못된 프레임 처리 프로그램');
  }
  return passes
      .map((pass) {
        if (pass is! List || pass.isEmpty || pass.length > 64) throw const FormatException('프레임 프로그램 명령 수 제한');
        final initialized = <int>{};
        final code = <List<double>>[];
        bool reg(dynamic v) => v is num && v == v.toInt() && v >= 0 && v < 8 && initialized.contains(v.toInt());
        for (final raw in pass) {
          if (raw is! List || raw.length != 4 || raw.any((v) => v is! num || !v.isFinite || v.abs() > 10000)) {
            throw const FormatException('잘못된 프레임 명령');
          }
          final i = raw.cast<num>();
          final opcode = i[0];
          if (opcode != opcode.toInt() || opcode < 0 || opcode >= 21 * 8) throw const FormatException('지원하지 않는 프레임 명령');
          final op = opcode.toInt() ~/ 8, d = opcode.toInt() % 8;
          final a = i[1], b = i[2], c = i[3];
          final valid = switch (op) {
            0 => true,
            1 || 2 => a.abs() <= 64 && b.abs() <= 64 && c.abs() <= 16 && (op == 1 || initialized.contains(d)),
            3 || 4 || 5 || 6 || 7 || 8 || 9 || 11 => reg(a) && reg(b) && c == 0,
            10 => reg(a) && b <= c,
            12 || 14 || 15 || 17 || 18 || 19 || 20 => reg(a) && b == 0 && c == 0,
            13 => a == 0 && b == 0 && c == 0,
            16 => initialized.contains(d) && reg(a) && reg(b) && c == c.toInt() && c >= 0 && c <= 2,
            _ => false,
          };
          if (!valid) throw const FormatException('잘못된 프레임 명령 피연산자');
          initialized.add(d);
          code.add(List.unmodifiable(i.map((v) => v.toDouble())));
        }
        if (!initialized.contains(0)) throw const FormatException('출력 레지스터가 없습니다');
        return PixelProgram._(List.unmodifiable(code));
      })
      .toList(growable: false);
}
