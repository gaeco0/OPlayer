import 'plugin.dart';
import 'frame_processor.dart';
import 'plugin_runtime.dart';
import 'plugin_store.dart';

class InterpolationModel {
  const InterpolationModel(this.key, this.name, this.provider, [this.description = '']);
  final String key, name, description;
  final OPlugin provider;
}

/// Plugins select models supported by the native engine; never native code paths.
class InterpolationModels {
  InterpolationModels(this.store);
  static final instance = InterpolationModels(PluginStore.instance);
  final PluginStore store;
  bool get available => store.enabled.any((p) => p.supports('interpolation'));
  final errors = <String, String>{};

  Future<List<InterpolationModel>> catalog() async {
    errors.clear();
    final models = <InterpolationModel>[];
    for (final provider in store.enabled.where((p) => p.supports('interpolation')).toList()) {
      try {
        final result = await callPlugin(provider, 'interpolationModels', {}, config: store.publicSettings(provider));
        if (result is! List || result.length > 30) throw const FormatException('잘못된 보간 모델 목록');
        final ids = <String>{};
        final parsed = <InterpolationModel>[];
        for (final entry in result) {
          if (entry is! Map ||
              entry['engine'] != 'rife-v4.6' ||
              !RegExp(r'^[a-z][a-z0-9_-]{0,63}$').hasMatch('${entry['id']}') ||
              !ids.add(entry['id'] as String) ||
              entry['name'] is! String ||
              (entry['name'] as String).isEmpty ||
              (entry['name'] as String).length > 100) {
            throw const FormatException('지원하지 않는 보간 모델입니다. 현재 엔진: RIFE v4.6');
          }
          parsed.add(
            InterpolationModel(
              '${provider.id}/${entry['id']}',
              entry['name'] as String,
              provider,
              entry['description'] as String? ?? provider.manifest['description'] as String? ?? '',
            ),
          );
        }
        if (!store.disabled.contains(provider.id) && store.installed[provider.id] == provider) models.addAll(parsed);
      } catch (e) {
        errors[provider.name] = '$e';
      }
    }
    return models;
  }

  Future<Map<String, dynamic>> playbackOptions(String key, Map<String, dynamic> context) async {
    final model = await resolve(key);
    final result = await callPlugin(model.provider, 'playbackOptions', {
      'model': key,
      ...context,
    }, config: store.publicSettings(model.provider));
    if (result is! Map ||
        result['ai'] is! bool ||
        result['npu'] is! bool ||
        result['issue'] != null && result['issue'] is! String) {
      throw const FormatException('보간 확장앱의 재생 정책을 업데이트해 주세요');
    }
    return result.cast<String, dynamic>();
  }

  Future<String> prepare(String key) async {
    final model = await resolve(key);
    final program = await frameProcessor(model.provider, {
      'id': key.substring(model.provider.id.length + 1),
      'operation': 'interpolation',
    }, config: store.publicSettings(model.provider));
    if (program == null || program['engine'] != 'rife-v4.6' || program['inputFrames'] != 2) {
      throw const FormatException('지원되는 프레임 처리 프로그램을 제공하는 보간 확장앱이 필요합니다');
    }
    final path = await prepareFrameModel(model.provider, program);
    store.require(model.provider.id);
    return path;
  }

  Future<InterpolationModel> resolve(String key) async {
    final model = (await catalog()).where((m) => m.key == key).firstOrNull;
    if (model == null) throw StateError('보간 모델 확장앱을 설치·활성화한 뒤 모델을 선택해 주세요');
    store.require(model.provider.id);
    return model;
  }
}
