import 'package:flutter/material.dart';
import '../../core/plugins/interpolation_models.dart';
import '../../core/plugins/plugin_store.dart';
import '../../core/settings.dart';
import 'plugins_page.dart';

class InterpolationModelsPage extends StatefulWidget {
  const InterpolationModelsPage({super.key});
  @override
  State<InterpolationModelsPage> createState() => _InterpolationModelsPageState();
}

class _InterpolationModelsPageState extends State<InterpolationModelsPage> {
  late Future<List<InterpolationModel>> _models;
  @override
  void initState() {
    super.initState();
    _models = InterpolationModels.instance.catalog();
    PluginStore.instance.addListener(_reload);
  }

  void _reload() {
    if (mounted) {
      setState(() {
        _models = InterpolationModels.instance.catalog();
      });
    }
  }

  @override
  void dispose() {
    PluginStore.instance.removeListener(_reload);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: AppSettings.instance,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('보간 모델')),
      body: FutureBuilder<List<InterpolationModel>>(
        future: _models,
        builder: (context, snapshot) => ListView(
          children: [
            ListTile(
              leading: Icon(
                AppSettings.instance.interpolationMode == 'blend'
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
              ),
              title: const Text('가벼운 프레임 혼합'),
              subtitle: const Text('기본 보간 · AI 사용 안 함'),
              onTap: () => AppSettings.instance.update((s) => s.interpolationMode = 'blend'),
            ),
            if (!InterpolationModels.instance.available) const ListTile(title: Text('AI 보간 모델 확장앱을 설치하고 켜 주세요')),
            if (snapshot.connectionState != ConnectionState.done) const LinearProgressIndicator(),
            if (snapshot.hasError) ListTile(title: Text('${snapshot.error}')),
            for (final e in InterpolationModels.instance.errors.entries) ListTile(title: Text('${e.key}: ${e.value}')),
            for (final m in snapshot.data ?? <InterpolationModel>[])
              ListTile(
                leading: Icon(
                  AppSettings.instance.interpolationMode == 'rife' && AppSettings.instance.interpolationModel == m.key
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
                enabled: PluginStore.instance.enabled.contains(m.provider),
                title: Text(m.name),
                subtitle: const Text('1배속 SDR · 320px 처리 · 250ms 지연 · NPU/GPU 기기 성능에 따라 원본 복귀'),
                onTap: () => AppSettings.instance.update((s) {
                  s.interpolationMode = 'rife';
                  s.interpolationModel = m.key;
                }),
              ),
            ListTile(
              leading: const Icon(Icons.extension_outlined),
              title: const Text('보간 확장앱 관리'),
              onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const PluginsPage())),
            ),
          ],
        ),
      ),
    ),
  );
}
