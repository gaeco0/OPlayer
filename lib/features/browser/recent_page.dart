import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/resume_store.dart';
import '../../core/resource_locks.dart';
import '../../sources/source_registry.dart';
import '../player/player_screen.dart';
import 'home_screen.dart';
import 'video_tile.dart';
import '../settings/privacy_settings.dart';
import '../settings/resource_access_view.dart';

/// 최근 재생 (로컬 + 네트워크 + 클라우드 + URL)
class RecentPage extends StatefulWidget {
  const RecentPage({super.key, required this.onOpenDrawer});
  final VoidCallback onOpenDrawer;

  @override
  State<RecentPage> createState() => _RecentPageState();
}

class _RecentPageState extends State<RecentPage> {
  String _sourceLabel(String key) {
    if (!key.contains('://')) return '로컬';
    final scheme = Uri.tryParse(key)?.scheme ?? '';
    return switch (scheme) {
      'smb' => 'SMB',
      'ftp' => 'FTP',
      'sftp' => 'SFTP',
      'webdav' => 'WebDAV',
      'gdrive' => 'Google Drive',
      'dropbox' => 'Dropbox',
      'onedrive' => 'OneDrive',
      _ => 'URL',
    };
  }

  Future<void> _open(ResumeEntry e) async {
    try {
      await ResourceLocks.instance.requireAccess(recentResourceKey);
      await ResourceLocks.instance.requireAccess(e.path);
    } on ResourceLockedException {
      return;
    }
    final item = await SourceRegistry.instance.itemFromKey(e.path, title: e.title);
    if (!mounted) return;
    if (item == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('파일 또는 서버를 찾을 수 없습니다')));
      return;
    }
    await Navigator.of(context).push(PlayerScreen.route([item], 0));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final items = ResumeStore.instance.recent();
    return ListenableBuilder(
      listenable: ResourceLocks.instance,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: shouldShowDrawerButton(context)
              ? IconButton(icon: const Icon(Icons.menu), onPressed: widget.onOpenDrawer)
              : null,
          title: const Text('최근 재생'),
          actions: [
            IconButton(
              tooltip: '최근 재생 목록 잠금 설정',
              icon: Icon(ResourceLocks.instance.hasExact(recentResourceKey) ? Icons.lock_outline : Icons.lock_open),
              onPressed: () => toggleResourceLock(context, recentResourceKey, '최근 재생'),
            ),
          ],
        ),
        body: ResourceAccessView(
          resources: const [recentResourceKey],
          child: items.isEmpty
              ? Center(
                  child: Text('재생 기록이 없습니다', style: TextStyle(color: OColors.of(context).textSecondary)),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: items.length,
                  itemBuilder: (_, i) {
                    final e = items[i];
                    final isLocal = !e.path.contains('://');
                    final missing = isLocal && !File(e.path).existsSync();
                    final name = e.title ?? e.path.split(RegExp(r'[\\/]')).last;
                    return Opacity(
                      opacity: missing ? 0.4 : 1,
                      child: VideoListTile(
                        resumeKey: e.path,
                        name: name,
                        localPath: isLocal && !missing ? e.path : null,
                        location: '${_sourceLabel(e.path)} · ${e.path}',
                        onTap: missing ? () {} : () => _open(e),
                        onChanged: () => setState(() {}),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}
