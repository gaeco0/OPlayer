import 'plugin.dart';
import 'plugin_runtime.dart';
import 'plugin_store.dart';

class InterpolationModel {
  const InterpolationModel(this.key, this.name, this.provider);
  final String key, name;
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
          parsed.add(InterpolationModel('${provider.id}/${entry['id']}', entry['name'] as String, provider));
        }
        if (!store.disabled.contains(provider.id) && store.installed[provider.id] == provider) models.addAll(parsed);
      } catch (e) {
        errors[provider.name] = '$e';
      }
    }
    return models;
  }

  Future<InterpolationModel> resolve(String key) async {
    final model = (await catalog()).where((m) => m.key == key).firstOrNull;
    if (model == null) throw StateError('보간 모델 확장앱을 설치·활성화한 뒤 모델을 선택해 주세요');
    store.require(model.provider.id);
    return model;
  }
}
