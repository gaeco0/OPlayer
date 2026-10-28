import 'package:flutter/material.dart';

import '../../core/plugins/plugin_store.dart';
import '../../core/plugins/upscale_models.dart';
import '../../core/settings.dart';
import 'plugins_page.dart';
import 'upscale_target_tile.dart';

class UpscaleModelsPage extends StatefulWidget {
  const UpscaleModelsPage({super.key});
  @override
  State<UpscaleModelsPage> createState() => _UpscaleModelsPageState();
}

class _UpscaleModelsPageState extends State<UpscaleModelsPage> {
  late Future<List<UpscaleModel>> _models;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _models = UpscaleModels.instance.catalog();
    PluginStore.instance.addListener(_reload);
  }

  @override
  void dispose() {
    PluginStore.instance.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (mounted) {
      setState(() {
        _models = UpscaleModels.instance.catalog();
      });
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      _reload();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addUrl() async {
    final values = await showDialog<(String, String)>(context: context, builder: (_) => const _ModelUrlDialog());
    if (!mounted || values == null) return;
    await _run(() async {
      await UpscaleModels.instance.addUrl(values.$1, values.$2);
    });
  }

  Future<void> _choose(UpscaleModel model) => _run(() async {
    await UpscaleModels.instance.materialize(model);
    if (mounted) AppSettings.instance.update((s) => s.upscalingModel = model.key);
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: AppSettings.instance,
    builder: (context, _) {
      final settings = AppSettings.instance;
      return Scaffold(
        appBar: AppBar(
          title: const Text('업스케일 모델'),
          actions: [
            IconButton(
              tooltip: '모델 URL 추가',
              onPressed: _busy || !UpscaleModels.instance.available ? null : _addUrl,
              icon: const Icon(Icons.add_link),
            ),
          ],
        ),
        body: Column(
          children: [
            if (_busy) const LinearProgressIndicator(),
            SwitchListTile(
              title: const Text('업스케일 켜기'),
              value: settings.videoUpscaling,
              onChanged: _busy ? null : (v) => settings.update((s) => s.videoUpscaling = v),
            ),
            const UpscaleTargetTile(),
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('AI 모델은 설치하고 켠 확장앱에서 제공합니다. 모델 선택은 현재 영상에 적용되며 켜기·끄기 상태는 유지합니다.'),
            ),
            if (_error != null) Padding(padding: const EdgeInsets.all(16), child: Text(_error!)),
            Expanded(
              child: FutureBuilder<List<UpscaleModel>>(
                future: _models,
                builder: (context, snapshot) => ListView(
                  children: [
                    ListTile(
                      leading: Icon(
                        settings.upscalingModel == 'lanczos'
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                      ),
                      title: const Text('Lanczos'),
                      subtitle: const Text('기존 확대 · AI 사용 안 함 · 기본값'),
                      enabled: !_busy,
                      onTap: () => settings.update((s) => s.upscalingModel = 'lanczos'),
                    ),
                    if (!UpscaleModels.instance.available) const ListTile(title: Text('업스케일 모델 확장앱을 설치하고 켜 주세요')),
                    if (snapshot.connectionState != ConnectionState.done) const LinearProgressIndicator(),
                    if (snapshot.hasError)
                      ListTile(
                        title: Text('모델 목록: ${snapshot.error}'),
                        trailing: IconButton(onPressed: _reload, icon: const Icon(Icons.refresh)),
                      ),
                    for (final issue in UpscaleModels.instance.errors.entries)
                      ListTile(title: Text('${issue.key}: ${issue.value}')),
                    for (final model in snapshot.data ?? <UpscaleModel>[])
                      ListTile(
                        leading: Icon(
                          settings.upscalingModel == model.key
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                        ),
                        title: Text(model.name),
                        subtitle: Text('${model.description}\n${model.license}'),
                        isThreeLine: true,
                        enabled: !_busy,
                        onTap: () => _choose(model),
                        trailing: model.key.startsWith('url/')
                            ? IconButton(
                                tooltip: '모델 삭제',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: _busy
                                    ? null
                                    : () => _run(() async {
                                        if (settings.upscalingModel == model.key) {
                                          settings.update((s) => s.upscalingModel = 'lanczos');
                                        }
                                        await UpscaleModels.instance.removeUrl(model);
                                      }),
                              )
                            : null,
                      ),
                    ListTile(
                      leading: const Icon(Icons.add_link),
                      title: const Text('URL로 모델 추가'),
                      enabled: !_busy && UpscaleModels.instance.available,
                      onTap: _addUrl,
                    ),
                    ListTile(
                      leading: const Icon(Icons.extension_outlined),
                      title: const Text('모델 확장앱 관리'),
                      onTap: () =>
                          Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const PluginsPage())),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _ModelUrlDialog extends StatefulWidget {
  const _ModelUrlDialog();
  @override
  State<_ModelUrlDialog> createState() => _ModelUrlDialogState();
}

class _ModelUrlDialogState extends State<_ModelUrlDialog> {
  final name = TextEditingController();
  final url = TextEditingController();
  @override
  void dispose() {
    name.dispose();
    url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('모델 URL 추가'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: name,
            decoration: const InputDecoration(labelText: '모델 이름 (선택)'),
            maxLength: 100,
          ),
          TextField(
            controller: url,
            decoration: const InputDecoration(labelText: 'HTTPS .glsl 주소'),
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 12),
          const Text('mpv용 GLSL 모델 · 512KB 이하 · ONNX·NCNN 파일은 지원하지 않습니다. 원본 모델의 라이선스를 확인해 주세요.'),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
      TextButton(
        onPressed: () => Navigator.pop(context, (url.text.trim(), name.text.trim())),
        child: const Text('다운로드·추가'),
      ),
    ],
  );
}
