import 'plugin.dart';
import 'plugin_runtime.dart';

/// Plugins return data, never native property names, shader paths or commands.
Future<Map<String, dynamic>> videoFilterValues(OPlugin plugin, Map<String, dynamic> config) async {
  if (plugin.kind != 'player' || !plugin.supports('videoFilter')) {
    throw StateError('영상 필터 확장앱이 아닙니다');
  }
  final result = await callPlugin(plugin, 'videoFilter', {}, config: config);
  if (result is! Map || result.isEmpty || result.length > 6) throw const FormatException('영상 필터 응답 오류');
  for (final entry in result.entries) {
    final value = entry.value;
    final valid = switch (entry.key) {
      'brightness' || 'contrast' || 'saturation' => value is num && value.isFinite && value >= -100 && value <= 100,
      'rotation' => value is int && [0, 90, 180, 270].contains(value),
      'horizontal' || 'vertical' => value is bool,
      _ => false,
    };
    if (!valid) throw FormatException('지원하지 않는 영상 필터 값: ${entry.key}');
  }
  return result.cast<String, dynamic>();
}
