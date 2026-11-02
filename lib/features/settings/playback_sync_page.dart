import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../core/playback_sync.dart';
import '../../core/plugins/plugin_store.dart';
import 'plugin_settings_dialog.dart';
import 'plugins_page.dart';
import '../../core/resource_locks.dart';
import '../../core/resume_store.dart';
import '../../core/sync_references.dart';
import '../../sources/server_store.dart';
import '../browser/file_actions.dart';

class PlaybackSyncPage extends StatefulWidget {
  const PlaybackSyncPage({super.key});
  @override
  State<PlaybackSyncPage> createState() => _PlaybackSyncPageState();
}

class _PlaybackSyncPageState extends State<PlaybackSyncPage> {
  final sync = PlaybackSync.instance;
  bool _working = false;
  Future<void> _run(Future<void> Function() action) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await action();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _bind(String root, String title) async {
    final alias = await askName(context, '$title 동기화 이름', initial: SyncReferences.instance.bindings[root] ?? '');
    if (alias == null) return;
    await _run(() async {
      await sync.bindReference(root, alias);
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([sync, ServerStore.instance, PluginStore.instance]),
    builder: (context, _) {
      final blocked = _working || sync.busy;
      final roots = <String, String>{
        for (final folder in ResumeStore.instance.folders) folder: folder,
        for (final server in ServerStore.instance.servers) '${server.type.name}://${server.id}': server.name,
        for (final account in ServerStore.instance.accounts) '${account.provider.name}://${account.id}': account.name,
        for (final root in SyncReferences.instance.bindings.keys) root: root,
      };
      return Scaffold(
        appBar: AppBar(title: const Text('재생 동기화')),
        body: ListView(
          children: [
            if (blocked) const LinearProgressIndicator(),
            const ListTile(
              title: Text('재생 동기화'),
              subtitle: Text('동기화 확장앱을 선택해 재생목록·최근 재생·이어보기를 기기 간 공유합니다. 파일 내용·비밀번호·사이트 세션은 전송하지 않습니다.'),
            ),
            DropdownButtonFormField<String>(
              key: ValueKey('${sync.providerId}:${sync.available}'),
              initialValue: sync.available ? sync.providerId : null,
              decoration: const InputDecoration(labelText: '동기화 확장앱'),
              items: [for (final p in sync.providers) DropdownMenuItem(value: p.id, child: Text(p.name))],
              onChanged: blocked
                  ? null
                  : (id) {
                      if (id != null) _run(() => sync.selectProvider(id));
                    },
            ),
            if (sync.providers.isEmpty || !sync.available)
              ListTile(
                title: const Text('동기화 확장앱 설치·활성화'),
                subtitle: const Text('공식 저장소에서 Google Drive·Dropbox·OneDrive·Box·S3 호환 저장소·네이버 MYBOX 동기화 확장앱을 선택하세요.'),
                trailing: const Icon(Icons.extension),
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PluginsPage())),
              ),
            if (sync.legacyConnection && !sync.connected)
              const ListTile(subtitle: Text('이전 동기화 연결 정보가 남아 있습니다. 해당 확장앱을 설치·선택하고 같은 계정에 연결하면 대기 기록을 이전합니다.')),
            if (sync.available)
              ListTile(
                title: const Text('선택한 확장앱 설정'),
                trailing: const Icon(Icons.settings),
                onTap: blocked
                    ? null
                    : () => _run(() async {
                        await showPluginSettingsDialog(context, PluginStore.instance.require(sync.providerId!));
                      }),
              ),
            ListTile(
              leading: const Icon(Icons.account_circle_outlined),
              title: Text(sync.email ?? '동기화 계정 연결'),
              subtitle: Text(sync.connected ? '계정 연결됨' : '연결하면 기존 기록과 앱 저장소의 기록을 병합합니다'),
              trailing: sync.connected ? null : const Icon(Icons.login),
              onTap: !blocked && !sync.connected && sync.available && PlaybackSync.supported
                  ? () => _run(sync.connect)
                  : null,
            ),
            SwitchListTile(
              title: const Text('자동 동기화'),
              subtitle: const Text('앱 시작·복귀 및 사용 중 최대 분당 한 번 · 오프라인 변경은 기기에 보관'),
              value: sync.automatic,
              onChanged: sync.connected && sync.available && !blocked ? (v) => _run(() => sync.setAutomatic(v)) : null,
            ),
            ListTile(
              leading: const Icon(Icons.sync),
              title: const Text('지금 동기화'),
              subtitle: Text(sync.lastSync == null ? '아직 동기화하지 않았습니다' : '마지막 성공: ${sync.lastSync!.toLocal()}'),
              onTap: sync.connected && sync.available && !blocked
                  ? () => _run(() async {
                      await ResourceLocks.instance.requireAccess(recentResourceKey);
                      await sync.syncNow();
                    })
                  : null,
            ),
            if (sync.error != null) ListTile(title: const Text('동기화하지 못했습니다'), subtitle: Text(sync.error!)),
            if (sync.connected)
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('계정 연결 해제'),
                subtitle: const Text('기기 기록과 저장소에 보관한 기록은 유지됩니다'),
                onTap: blocked ? null : () => _run(sync.disconnect),
              ),
            const Divider(),
            const ListTile(
              title: Text('기기별 폴더·리소스 연결'),
              subtitle: Text(
                '같은 파일이 있는 폴더·계정·서버에 각 기기에서 같은 동기화 이름을 지정하세요. '
                '예: Windows D:\\Videos와 Android 영화 폴더에 모두 “영화”. '
                '폴더 안의 상대 경로 또는 저장소 파일 ID가 일치해야 이어볼 수 있습니다. '
                '연결하지 않은 파일·브라우저 임시 URL은 이 기기에만 남습니다.',
              ),
            ),
            for (final root in roots.entries)
              ListTile(
                title: Text(root.value),
                subtitle: Text(SyncReferences.instance.bindings[root.key] ?? '동기화 이름 미지정'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (SyncReferences.instance.bindings.containsKey(root.key))
                      IconButton(
                        tooltip: '동기화 연결 이름 해제',
                        icon: const Icon(Icons.link_off),
                        onPressed: blocked
                            ? null
                            : () => _run(() async {
                                await sync.bindReference(root.key, '');
                              }),
                      ),
                    IconButton(
                      tooltip: '동기화 이름 지정',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: blocked ? null : () => _bind(root.key, root.value),
                    ),
                  ],
                ),
              ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('로컬 폴더 연결'),
              onTap: blocked
                  ? null
                  : () async {
                      final folder = await FilePicker.getDirectoryPath(dialogTitle: '동기화할 로컬 폴더');
                      if (folder != null && mounted) await _bind(folder, folder);
                    },
            ),
          ],
        ),
      );
    },
  );
}
