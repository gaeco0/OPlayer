import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../core/plugins/plugin.dart';
import '../../core/plugins/plugin_store.dart';
import 'cloud_settings.dart';

class PluginsPage extends StatefulWidget {
  const PluginsPage({super.key});
  @override
  State<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends State<PluginsPage> {
  final store = PluginStore.instance;
  final listings = <String, List<PluginListing>>{};
  final errors = <String, String>{};
  bool busy = false;
  String category = '';
  static const categories = {'': '전체', 'player': '플레이어', 'browser': '브라우저', 'resource': '리소스'};
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _refresh() => _guard(() async {
    for (final repository in List.of(store.repositories)) {
      try {
        listings[repository] = await store.listings(repository);
        errors.remove(repository);
      } catch (e) {
        errors[repository] = '$e';
      }
    }
  });
  Future<void> _install(OPlugin p) async {
    if (!mounted) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${p.name} ${p.version} 설치'),
        content: SingleChildScrollView(
          child: Text(
            '유형: ${p.kindLabel}\n기능: ${p.capabilities.join(', ')}\n\n${p.cloud
                ? '클라우드 목록·재생 주소 조회 및 계정 인증'
                : p.subtitle
                ? '영상 제목으로 자막 검색, 선택한 자막 다운로드·적용'
                : p.supports('upscaling')
                ? 'AI 업스케일 모델 목록·가중치 셰이더 제공'
                : p.supports('interpolation')
                ? '내장 엔진에서 사용할 AI 보간 모델 목록 제공'
                : p.kind == 'player'
                ? '영상 색상·회전·반전 필터 적용'
                : '지정한 사이트의 페이지와 요청 헤더·쿠키 접근, 다운로드 보완·광고 차단'}\n\n'
            '사이트: ${p.sites.contains('*') ? '모든 웹사이트' : p.sites.join(', ')}\n네트워크: ${p.hosts.join(', ')}\n인증: ${p.authHosts.join(', ')}\n'
            '${(p.manifest['networkSettings'] as List? ?? []).isEmpty ? '' : '사용자 지정 서버 설정: ${(p.manifest['networkSettings'] as List).join(', ')}\n'}'
            '${p.cloud && p.authType == 'oauth' ? '로그인 서버: ${p.oauth['authEndpoint']}\n토큰 서버: ${p.oauth['tokenEndpoint']}\n' : ''}'
            '${p.authType == 's3' ? '등록할 S3 Endpoint·버킷에 대한 서명된 읽기 요청\n' : ''}\n'
            '신뢰하는 개발자의 확장앱만 설치하세요. 같은 ID의 확장앱은 교체되며 기존 계정에도 적용됩니다.',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('설치')),
        ],
      ),
    );
    if (approved == true) await store.load(p.source);
  }

  Future<void> _import() => _guard(() async {
    final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['js'], withData: false);
    if (result == null) return;
    final file = result.files.single;
    if (file.size > 1024 * 1024) throw const FormatException('확장앱은 1MB 이하여야 합니다');
    final bytes = file.bytes ?? await File(file.path!).readAsBytes();
    await _install(OPlugin.parse(utf8.decode(bytes)));
  });
  Future<void> _addRepository() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('확장앱 저장소 추가'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(labelText: '저장소 JSON URL', hintText: 'https://example.com/repository.json'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(c, controller.text), child: const Text('추가')),
        ],
      ),
    );
    controller.dispose();
    if (url == null) return;
    await _guard(() async {
      await store.addRepository(url);
    });
    await _refresh();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('확장앱'),
        actions: [
          IconButton(onPressed: busy ? null : _refresh, icon: const Icon(Icons.refresh), tooltip: '목록 새로고침'),
          IconButton(
            onPressed: busy ? null : _import,
            icon: const Icon(Icons.file_open_outlined),
            tooltip: 'JS 파일 가져오기',
          ),
          IconButton(onPressed: busy ? null : _addRepository, icon: const Icon(Icons.add), tooltip: '저장소 추가'),
        ],
      ),
      body: Column(
        children: [
          if (busy) const LinearProgressIndicator(),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final entry in categories.entries)
                  Padding(
                    padding: const EdgeInsets.all(4),
                    child: ChoiceChip(
                      label: Text(entry.value),
                      selected: category == entry.key,
                      onSelected: (_) => setState(() => category = entry.key),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                const ListTile(
                  title: Text('설치됨'),
                  subtitle: Text('사이트 변경은 페이지를 새로고침한 뒤 적용됩니다. 클라우드를 끄거나 삭제하면 계정 정보는 보관됩니다.'),
                ),
                for (final p in store.installed.values.where((p) => category.isEmpty || p.kind == category))
                  ListTile(
                    title: Text(p.name),
                    subtitle: Text('${p.version} · ${p.kindLabel}\n${p.capabilities.join(' · ')}'),
                    leading: Switch(
                      value: !store.disabled.contains(p.id),
                      onChanged: busy ? null : (v) => _guard(() => store.setEnabled(p.id, v)),
                    ),
                    onTap: (p.cloud || p.settings.isNotEmpty) && !busy
                        ? () => Navigator.of(
                            context,
                          ).push(MaterialPageRoute<void>(builder: (_) => CloudPluginSettingsPage(pluginId: p.id)))
                        : null,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (p.cloud || p.settings.isNotEmpty)
                          IconButton(
                            icon: const Icon(Icons.settings_outlined),
                            tooltip: '${p.name} 설정',
                            onPressed: busy
                                ? null
                                : () => Navigator.of(context).push(
                                    MaterialPageRoute<void>(builder: (_) => CloudPluginSettingsPage(pluginId: p.id)),
                                  ),
                          ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: '확장앱 삭제',
                          onPressed: busy
                              ? null
                              : () => _guard(() async {
                                  final yes = await showDialog<bool>(
                                    context: context,
                                    builder: (c) => AlertDialog(
                                      title: Text('${p.name} 삭제'),
                                      content: const Text('확장앱을 삭제합니다. 기존 클라우드 계정은 유지되며 다시 설치하면 사용할 수 있습니다.'),
                                      actions: [
                                        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('취소')),
                                        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('삭제')),
                                      ],
                                    ),
                                  );
                                  if (yes == true) await store.remove(p.id);
                                }),
                        ),
                      ],
                    ),
                  ),
                for (final repository in store.repositories) ...[
                  const Divider(),
                  ListTile(
                    title: Text(store.repositoryNames[repository] ?? '확장앱 저장소'),
                    subtitle: Text(repository),
                    trailing: IconButton(
                      icon: const Icon(Icons.remove_circle_outline),
                      tooltip: '저장소 제거',
                      onPressed: busy ? null : () => _guard(() => store.removeRepository(repository)),
                    ),
                  ),
                  if (errors[repository] != null)
                    ListTile(title: const Text('저장소 목록을 받지 못했습니다'), subtitle: Text(errors[repository]!)),
                  for (final entry in (listings[repository] ?? <PluginListing>[]).where(
                    (p) => category.isEmpty || p.kind == category,
                  ))
                    ListTile(
                      title: Text(entry.name),
                      subtitle: Text(
                        '${entry.version} · ${categories[entry.kind] ?? '기존 규약'}${entry.author.isEmpty ? '' : ' · ${entry.author}'}\n${entry.description}'
                        '${entry.features.isEmpty ? '' : '\n기능: ${entry.features.join(' · ')}'}',
                      ),
                      trailing: FilledButton(
                        onPressed: busy || store.installed[entry.id]?.version == entry.version
                            ? null
                            : () => _guard(() async => _install(await store.download(entry))),
                        child: Text(
                          store.installed.containsKey(entry.id)
                              ? (store.installed[entry.id]?.version == entry.version ? '설치됨' : '교체')
                              : '설치',
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
