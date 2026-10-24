import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/google_sync.dart';
import '../../core/resource_locks.dart';
import '../../core/resume_store.dart';
import '../../core/sync_references.dart';
import '../../core/secure_store.dart';
import '../../sources/cloud/cloud_config.dart';
import '../../sources/cloud/oauth.dart';
import '../../sources/server_store.dart';
import '../browser/file_actions.dart';

class GoogleSyncPage extends StatefulWidget {
  const GoogleSyncPage({super.key});
  @override
  State<GoogleSyncPage> createState() => _GoogleSyncPageState();
}

class _GoogleSyncPageState extends State<GoogleSyncPage> {
  final sync = GoogleSync.instance;
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

  Future<void> _register() async {
    String? registration;
    if (Platform.isAndroid) {
      try {
        final info = await GoogleAndroidOAuthClient.channel.invokeMapMethod<String, dynamic>('registrationInfo');
        registration = '패키지: ${info?['package']}\n배포 서명 SHA-1: ${info?['sha1']}';
      } catch (_) {
        registration = '앱의 패키지명·배포 서명 SHA-1을 Google Cloud에 등록하세요.';
      }
    }
    final secret = Platform.isAndroid
        ? ''
        : await SecureStore.instance.readRequired(CloudConfig.googleSecretKey(sync.clientId)) ?? '';
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _GoogleRegistration(clientId: sync.clientId, secret: secret, registration: registration),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([sync, ServerStore.instance]),
    builder: (context, _) {
      final blocked = _working || sync.busy;
      final roots = <String, String>{
        for (final folder in ResumeStore.instance.folders) folder: folder,
        for (final server in ServerStore.instance.servers) '${server.type.name}://${server.id}': server.name,
        for (final account in ServerStore.instance.accounts) '${account.provider.name}://${account.id}': account.name,
        for (final root in SyncReferences.instance.bindings.keys) root: root,
      };
      return Scaffold(
        appBar: AppBar(title: const Text('Google 동기화')),
        body: ListView(
          children: [
            if (blocked) const LinearProgressIndicator(),
            const ListTile(
              title: Text('Google Drive 앱 전용 저장소'),
              subtitle: Text(
                '재생목록·최근 재생·이어보기 위치를 같은 Google 계정의 기기에서 동기화합니다. '
                '파일 내용·비밀번호·사이트 세션은 업로드하지 않습니다. 일반 Drive 목록에 표시되지 않는 앱 데이터입니다.',
              ),
            ),
            if (!GoogleSync.supported)
              const ListTile(
                subtitle: Text(
                  '현재 Android·Android TV와 Windows·Linux·macOS에서 지원합니다. '
                  'Android는 Google Play 서비스가 필요합니다. iOS는 별도 Google 로그인 등록 후 지원할 예정입니다.',
                ),
              ),
            ListTile(
              leading: const Icon(Icons.account_circle_outlined),
              title: Text(sync.email ?? 'Google 계정 연결'),
              subtitle: Text(sync.connected ? '계정 연결됨' : '연결하면 기존 기록과 앱 저장소의 기록을 병합합니다'),
              trailing: sync.connected ? null : const Icon(Icons.login),
              onTap: !blocked && !sync.connected && GoogleSync.supported ? () => _run(sync.connect) : null,
            ),
            SwitchListTile(
              title: const Text('자동 동기화'),
              subtitle: const Text('앱 시작·복귀 및 사용 중 최대 분당 한 번 · 오프라인 변경은 기기에 보관'),
              value: sync.automatic,
              onChanged: sync.connected && !blocked ? (v) => _run(() => sync.setAutomatic(v)) : null,
            ),
            ListTile(
              leading: const Icon(Icons.sync),
              title: const Text('지금 동기화'),
              subtitle: Text(sync.lastSync == null ? '아직 동기화하지 않았습니다' : '마지막 성공: ${sync.lastSync!.toLocal()}'),
              onTap: sync.connected && !blocked
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
                subtitle: const Text('기기 기록과 Google에 저장한 기록은 유지됩니다'),
                onTap: blocked ? null : () => _run(sync.disconnect),
              ),
            ListTile(
              leading: const Icon(Icons.key),
              title: const Text('Google 앱 등록 정보'),
              subtitle: const Text('같은 Google Cloud 프로젝트의 OAuth 클라이언트를 모든 기기에서 사용하세요'),
              onTap: !blocked && !sync.connected ? () => _run(_register) : null,
            ),
            ListTile(
              title: const Text('Google Cloud 등록 안내'),
              trailing: const Icon(Icons.open_in_new),
              onTap: () => launchUrl(
                Uri.parse('https://console.cloud.google.com/auth/clients'),
                mode: LaunchMode.externalApplication,
              ),
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

class _GoogleRegistration extends StatefulWidget {
  const _GoogleRegistration({required this.clientId, required this.secret, this.registration});
  final String clientId;
  final String secret;
  final String? registration;
  @override
  State<_GoogleRegistration> createState() => _GoogleRegistrationState();
}

class _GoogleRegistrationState extends State<_GoogleRegistration> {
  late final id = TextEditingController(text: widget.clientId);
  late final secret = TextEditingController(text: widget.secret);
  bool saving = false;
  String? error;
  @override
  void dispose() {
    id.dispose();
    secret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Google 동기화 앱 등록'),
    content: SizedBox(
      width: 500,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Google Cloud에서 Drive API를 사용 설정하고 OAuth 동의 화면에 drive.appdata 권한을 추가하세요. '
              'Android는 패키지명·서명으로 Android 클라이언트를 등록하고, 데스크톱은 데스크톱 앱 클라이언트를 만드세요. '
              'Play 스토어 등록은 필요하지 않습니다.',
            ),
            if (widget.registration != null) SelectableText(widget.registration!),
            TextField(
              controller: id,
              decoration: InputDecoration(
                labelText: Platform.isAndroid ? 'Android Client ID (선택)' : 'Desktop Client ID',
              ),
            ),
            if (!Platform.isAndroid)
              TextField(
                controller: secret,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Desktop Client Secret', helperText: '기기 보안 저장소에 보관'),
              ),
            if (error != null) Text(error!),
            if (saving) const LinearProgressIndicator(),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: saving ? null : () => Navigator.pop(context), child: const Text('취소')),
      FilledButton(
        onPressed: saving
            ? null
            : () async {
                setState(() {
                  saving = true;
                  error = null;
                });
                try {
                  await GoogleSync.instance.configure(id.text, secret.text);
                  if (context.mounted) Navigator.pop(context);
                } catch (e) {
                  if (mounted) setState(() => error = '$e');
                } finally {
                  if (mounted) setState(() => saving = false);
                }
              },
        child: const Text('저장'),
      ),
    ],
  );
}
