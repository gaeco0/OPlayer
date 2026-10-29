import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/resume_store.dart';
import '../../core/playlist_store.dart';
import '../../core/sync_references.dart';
import '../../core/resource_locks.dart';
import '../../sources/source_registry.dart';
import '../player/player_screen.dart';
import 'home_screen.dart';
import 'video_tile.dart';
import 'file_actions.dart';
import 'playlists_page.dart';
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
  final _selected = <String>{};
  bool _selecting = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    ResourceLocks.instance.addListener(_onLocksChanged);
  }

  @override
  void dispose() {
    ResourceLocks.instance.removeListener(_onLocksChanged);
    super.dispose();
  }

  void _exitSelection() => setState(() {
    _selecting = false;
    _selected.clear();
  });

  void _onLocksChanged() {
    if (_selecting && ResourceLocks.instance.isLocked(recentResourceKey)) _exitSelection();
  }

  void _select(String path) => setState(() {
    _selecting = true;
    if (!_selected.add(path)) _selected.remove(path);
  });

  String _name(ResumeEntry entry) => entry.title ?? entry.path.split(RegExp(r'[\\/]')).last;

  Future<void> _add(List<ResumeEntry> entries) => runFileAction(context, () async {
    await ResourceLocks.instance.requireAccess(recentResourceKey);
    if (!mounted) return;
    await addToPlaylist(context, entries.map((e) => PlaylistTrack(e.path, _name(e))).toList());
  });

  Future<void> _remove(List<ResumeEntry> entries) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${entries.length}개 재생 기록 삭제'),
        content: const Text('선택한 항목의 재생 기록과 이어보기 위치를 삭제합니다. 원본 파일은 유지됩니다.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('취소')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('기록 삭제')),
        ],
      ),
    );
    if (confirmed != true || !mounted || !_selecting) return;
    setState(() => _busy = true);
    try {
      await runFileAction(context, () async {
        await ResourceLocks.instance.requireAccess(recentResourceKey);
        if (!mounted || !_selecting) return;
        await ResumeStore.instance.removeAll(entries.map((e) => e.path));
        if (mounted) _exitSelection();
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _sourceLabel(String key) {
    if (key.startsWith(SyncReferences.prefix)) return '동기화 · 리소스 연결 필요';
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
    return ListenableBuilder(
      listenable: Listenable.merge([ResourceLocks.instance, ResumeStore.instance]),
      builder: (context, _) {
        final items = ResumeStore.instance.recent();
        _selected.retainAll(items.map((e) => e.path));
        final chosen = items.where((e) => _selected.contains(e.path)).toList();
        final locked = ResourceLocks.instance.isLocked(recentResourceKey);
        return PopScope(
          canPop: !_selecting || locked,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _exitSelection();
          },
          child: Scaffold(
            appBar: AppBar(
              automaticallyImplyLeading: false,
              leading: _selecting && !locked
                  ? IconButton(tooltip: '선택 취소', icon: const Icon(Icons.close), onPressed: _exitSelection)
                  : shouldShowDrawerButton(context)
                  ? IconButton(icon: const Icon(Icons.menu), onPressed: widget.onOpenDrawer)
                  : null,
              title: Text(_selecting && !locked ? '${_selected.length}개 선택' : '최근 재생'),
              actions: [
                if (_selecting && !locked)
                  FileSelectionActions(
                    onSelectAll: () => setState(() {
                      if (_selected.length == items.length) {
                        _selected.clear();
                      } else {
                        _selected.addAll(items.map((e) => e.path));
                      }
                    }),
                    onAdd: _busy || chosen.isEmpty ? null : () => _add(chosen),
                    onDelete: _busy || chosen.isEmpty ? null : () => _remove(chosen),
                    removeLabel: '재생 기록 삭제',
                  )
                else if (!locked && items.isNotEmpty)
                  IconButton(
                    tooltip: '선택모드',
                    icon: const Icon(Icons.checklist),
                    onPressed: () => setState(() => _selecting = true),
                  ),
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
                        final isLocal = !e.path.contains('://') && !e.path.startsWith(SyncReferences.prefix);
                        final missing = isLocal && !File(e.path).existsSync();
                        final name = _name(e);
                        return FileSelectionTile(
                          key: ValueKey(e.path),
                          active: _selecting,
                          selected: _selected.contains(e.path),
                          onToggle: () => _select(e.path),
                          child: Opacity(
                            opacity: missing ? 0.4 : 1,
                            child: VideoListTile(
                              resumeKey: e.path,
                              name: name,
                              localPath: isLocal && !missing ? e.path : null,
                              location: '${_sourceLabel(e.path)} · ${e.path}',
                              onTap: missing ? () {} : () => _open(e),
                              onChanged: () => setState(() {}),
                              onSelect: () => _select(e.path),
                              onAddToPlaylist: () => _add([e]),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
        );
      },
    );
  }
}
