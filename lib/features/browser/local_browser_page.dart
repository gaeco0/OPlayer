import '../settings/resource_access_view.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import '../../core/resource_locks.dart';
import 'package:path/path.dart' as p;

import '../../app/theme.dart';
import '../../core/media_item.dart';
import '../../core/media_utils.dart';
import '../../core/settings.dart';
import '../player/player_screen.dart';
import '../photos/photo_viewer.dart';
import 'home_screen.dart';
import 'video_tile.dart';
import 'swipe_delete_tile.dart';
import '../../core/file_deletion.dart';
import '../../core/file_renaming.dart';
import '../../core/playlist_store.dart';
import 'file_actions.dart';
import 'playlists_page.dart';

class FsItem {
  FsItem(this.entity, this.stat);
  final FileSystemEntity entity;
  final FileStat stat;
  bool get isDir => entity is Directory;
  String get path => entity.path;
  String get name => p.basename(entity.path);
}

/// nPlayer 로컬 브라우저: 폴더 먼저, 동영상만 표시, 정렬/보기 전환, 뒤로가기 = 상위 폴더.
class LocalBrowserPage extends StatefulWidget {
  const LocalBrowserPage({
    super.key,
    required this.rootPath,
    required this.rootTitle,
    required this.ensurePermission,
    required this.onOpenDrawer,
  });

  final String rootPath;
  final String rootTitle;
  final Future<bool> Function() ensurePermission;
  final VoidCallback onOpenDrawer;

  @override
  State<LocalBrowserPage> createState() => _LocalBrowserPageState();
}

class _LocalBrowserPageState extends State<LocalBrowserPage> {
  late final List<String> _stack = [widget.rootPath];
  List<FsItem> _items = [];
  List<String> _allFiles = [];
  bool _loading = true;
  String? _error;
  SortBy _sort = SortBy.name;
  bool _asc = true;
  bool _foldersFirst = true;
  bool _grid = false;
  int _loadGeneration = 0;
  bool _selecting = false;
  bool _busy = false;
  final _selected = <String>{};
  List<FsItem> get _selectedFiles => _items.where((e) => !e.isDir && _selected.contains(e.path)).toList();
  void _toggle(String path) => setState(() {
    if (!_selected.add(path)) _selected.remove(path);
  });
  void _closeSelection() => setState(() {
    _selecting = false;
    _selected.clear();
  });
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await runFileAction(context, action);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addSelected() => runFileAction(
    context,
    () => addToPlaylist(
      context,
      _selectedFiles.where((e) => isPlayable(e.path)).map((e) => PlaylistTrack(e.path, e.name)).toList(),
    ),
  );
  Future<void> _deleteSelected() async {
    final files = _selectedFiles;
    if (!await confirmFileDeletion(context, files.length) || !mounted) return;
    await _run(() async {
      final failures = <String>[];
      for (final file in files) {
        try {
          await deleteLocalEntry(file.path, parent: _cwd);
          _selected.remove(file.path);
        } catch (error) {
          failures.add('${file.name}: $error');
        }
      }
      if (mounted) await _load();
      if (failures.isNotEmpty) throw StateError(failures.join('\n'));
    });
  }

  Future<void> _rename(FsItem item) async {
    final name = await askName(context, '파일 이름변경', initial: item.name);
    if (name == null || !mounted) return;
    await _run(() async {
      try {
        await renameLocalFile(item.path, name, parent: _cwd);
      } finally {
        if (mounted) await _load();
      }
    });
  }

  Future<void> _deleteFromMenu(FsItem item) async {
    if (await confirmFileDeletion(context, 1) && mounted) await _run(() => _delete(item));
  }

  Widget _wrap(FsItem item, Widget tile) => FileSelectionTile(
    active: _selecting && !item.isDir,
    selected: _selected.contains(item.path),
    onToggle: () => _toggle(item.path),
    child: SwipeDeleteTile(
      key: ValueKey(item.path),
      onDelete: _selecting || _busy ? null : () => _delete(item),
      watchedKey: !_selecting && !item.isDir && isPlayable(item.path) ? item.path : null,
      watchedTitle: item.name,
      onChanged: () => setState(() {}),
      child: tile,
    ),
  );

  String get _cwd => _stack.last;

  String get _sortKey =>
      'local:${Platform.isWindows ? p.normalize(p.absolute(_cwd)).toLowerCase() : p.normalize(p.absolute(_cwd))}';

  void _restoreSort() {
    final saved = AppSettings.instance.folderSort(_sortKey);
    _sort = saved.by;
    _asc = saved.ascending;
    _foldersFirst = saved.foldersFirst;
  }

  void _saveSort() =>
      AppSettings.instance.setFolderSort(_sortKey, FolderSort(by: _sort, ascending: _asc, foldersFirst: _foldersFirst));

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final path = _cwd;
    _restoreSort();
    setState(() {
      _loading = true;
      _error = null;
    });
    final permitted = await widget.ensurePermission();
    if (!mounted || generation != _loadGeneration) return;
    if (!permitted) {
      setState(() {
        _loading = false;
        _error = '저장소 접근 권한이 필요합니다.';
      });
      return;
    }
    final showHidden = AppSettings.instance.showHiddenFiles;
    try {
      await ResourceLocks.instance.requireAccess(path);
      final entities = await Directory(path).list(followLinks: false).toList();
      final items = <FsItem>[];
      final files = <String>[];
      for (final e in entities) {
        final name = p.basename(e.path);
        if (!showHidden && name.startsWith('.')) continue;
        if (e is File) files.add(e.path);
        if (e is Directory || (e is File && isBrowsableMedia(e.path))) {
          try {
            items.add(FsItem(e, await e.stat()));
          } catch (_) {}
        }
      }
      if (!mounted || generation != _loadGeneration) return;
      _allFiles = files;
      _items = items;
      _selected.removeWhere((path) => !items.any((e) => !e.isDir && e.path == path));
      _applySort();
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      _error = '폴더를 열 수 없습니다\n$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  void _applySort() {
    _items.sort((a, b) {
      if (_foldersFirst && a.isDir != b.isDir) return a.isDir ? -1 : 1; // 폴더 먼저
      final r = switch (_sort) {
        SortBy.name => naturalCompare(a.name, b.name),
        SortBy.date => a.stat.modified.compareTo(b.stat.modified),
        SortBy.size => a.stat.size.compareTo(b.stat.size),
      };
      return _asc ? r : -r;
    });
  }

  void _enter(String dir) {
    _closeSelection();
    _stack.add(dir);
    _load();
  }

  bool _up() {
    if (_selecting) {
      _closeSelection();
      return true;
    }
    if (_busy) return true;
    if (_stack.length <= 1) return false;
    _stack.removeLast();
    _load();
    return true;
  }

  Future<void> _play(FsItem item) async {
    if (isImage(item.path)) {
      final photos = _items.where((e) => !e.isDir && isImage(e.path)).map((e) => e.path).toList();
      await Navigator.of(
        context,
      ).push(PhotoViewer.route(photos.map(MediaItem.local).toList(), photos.indexOf(item.path)));
      return;
    }
    final videos = _items.where((e) => !e.isDir && isPlayable(e.path)).map((e) => e.path).toList();
    final index = videos.indexOf(item.path);
    await Navigator.of(
      context,
    ).push(PlayerScreen.route(videos.map(MediaItem.local).toList(), index, folderFiles: _allFiles));
    if (mounted) setState(() {}); // 이어보기 진행바 갱신
  }

  Future<void> _delete(FsItem item) async {
    final parent = _cwd;
    try {
      await deleteLocalEntry(item.path, parent: parent);
    } finally {
      if (mounted) await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _stack.length == 1 ? widget.rootTitle : p.basename(_cwd);
    final relative = p.relative(_cwd, from: widget.rootPath);

    return PopScope(
      canPop: !_selecting && !_busy && _stack.length <= 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _up();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: _selecting
              ? IconButton(tooltip: '선택 취소', icon: const Icon(Icons.close), onPressed: _busy ? null : _closeSelection)
              : _stack.length > 1
              ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: _up)
              : (shouldShowDrawerButton(context)
                    ? IconButton(icon: const Icon(Icons.menu), onPressed: widget.onOpenDrawer)
                    : null),
          automaticallyImplyLeading: false,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_selecting ? '${_selected.length}개 선택' : title, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (relative != '.')
                Text(
                  '/$relative',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: OColors.of(context).textSecondary),
                ),
            ],
          ),
          actions: [
            if (_selecting)
              FileSelectionActions(
                onSelectAll: () => setState(() {
                  final files = _items.where((e) => !e.isDir).map((e) => e.path).toSet();
                  if (_selected.containsAll(files)) {
                    _selected.clear();
                  } else {
                    _selected.addAll(files);
                  }
                }),
                onAdd: !_busy && _selectedFiles.any((e) => isPlayable(e.path)) ? _addSelected : null,
                onDelete: !_busy && _selected.isNotEmpty ? _deleteSelected : null,
              )
            else ...[
              IconButton(
                tooltip: '선택모드',
                icon: const Icon(Icons.checklist),
                onPressed: () => setState(() => _selecting = true),
              ),
              if (_stack.length > 1 && shouldShowDrawerButton(context))
                IconButton(tooltip: '메뉴', icon: const Icon(Icons.menu), onPressed: widget.onOpenDrawer),
              sortMenu(
                sort: _sort,
                asc: _asc,
                foldersFirst: _foldersFirst,
                onFoldersFirst: () => setState(() {
                  _foldersFirst = !_foldersFirst;
                  _applySort();
                  _saveSort();
                }),
                onSort: (v) => setState(() {
                  _asc = _sort == v ? !_asc : true;
                  _sort = v;
                  _applySort();
                  _saveSort();
                }),
                extra: [
                  const PopupMenuDivider(),
                  CheckedPopupMenuItem(
                    value: 'hidden',
                    checked: AppSettings.instance.showHiddenFiles,
                    child: const Text('숨김 파일 표시'),
                  ),
                ],
                onExtra: (v) {
                  AppSettings.instance.update((s) => s.showHiddenFiles = !s.showHiddenFiles);
                  _load();
                },
              ),
              IconButton(
                tooltip: _grid ? '목록 보기' : '격자 보기',
                icon: Icon(_grid ? Icons.view_list : Icons.grid_view),
                onPressed: () => setState(() => _grid = !_grid),
              ),
              IconButton(tooltip: '새로고침', icon: const Icon(Icons.refresh), onPressed: _load),
            ],
          ],
          bottom: _busy
              ? const PreferredSize(preferredSize: Size.fromHeight(3), child: LinearProgressIndicator())
              : null,
        ),
        body: AbsorbPointer(
          absorbing: _busy,
          child: ResourceAccessView(
            resources: [_cwd],
            onRefresh: _load,
            child: SlidableAutoCloseBehavior(
              child: RefreshIndicator(onRefresh: _load, child: _body()),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const ScrollablePlaceholder(child: Center(child: CircularProgressIndicator()));
    if (_error != null) {
      return ScrollablePlaceholder(
        child: ErrorView(message: _error!, onRetry: _load),
      );
    }
    if (_items.isEmpty) {
      return ScrollablePlaceholder(
        child: Center(
          child: Text('동영상이 없습니다', style: TextStyle(color: OColors.of(context).textSecondary)),
        ),
      );
    }

    if (_grid) {
      return GridView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 220,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.95,
        ),
        itemCount: _items.length,
        itemBuilder: (_, i) {
          final it = _items[i];
          final tile = it.isDir
              ? FolderGridTile(name: it.name, resource: it.path, onTap: () => _enter(it.path))
              : VideoGridTile(
                  resumeKey: it.path,
                  name: it.name,
                  localPath: it.path,
                  size: it.stat.size,
                  onTap: () => _play(it),
                  onChanged: () => setState(() {}),
                  onRename: () => _rename(it),
                  onDelete: () => _deleteFromMenu(it),
                  onAddToPlaylist: isPlayable(it.path)
                      ? () => runFileAction(context, () => addToPlaylist(context, [PlaylistTrack(it.path, it.name)]))
                      : null,
                  onSelect: () => setState(() {
                    _selecting = true;
                    _selected.add(it.path);
                  }),
                );
          return _wrap(it, tile);
        },
      );
    }

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 96),
      itemCount: _items.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 16, endIndent: 16),
      itemBuilder: (_, i) {
        final it = _items[i];
        final tile = it.isDir
            ? FolderListTile(name: it.name, resource: it.path, onTap: () => _enter(it.path))
            : VideoListTile(
                resumeKey: it.path,
                name: it.name,
                localPath: it.path,
                size: it.stat.size,
                modified: it.stat.modified,
                hasSubtitle: siblingSubtitles(it.path, _allFiles).isNotEmpty,
                onTap: () => _play(it),
                onChanged: () => setState(() {}),
                onRename: () => _rename(it),
                onDelete: () => _deleteFromMenu(it),
                onAddToPlaylist: isPlayable(it.path)
                    ? () => runFileAction(context, () => addToPlaylist(context, [PlaylistTrack(it.path, it.name)]))
                    : null,
                onSelect: () => setState(() {
                  _selecting = true;
                  _selected.add(it.path);
                }),
              );
        return _wrap(it, tile);
      },
    );
  }
}

/// Keep pull-to-refresh available for empty, loading and error states too.
class ScrollablePlaceholder extends StatelessWidget {
  const ScrollablePlaceholder({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => CustomScrollView(
    physics: const AlwaysScrollableScrollPhysics(),
    slivers: [SliverFillRemaining(hasScrollBody: false, child: child)],
  );
}

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.message, required this.onRetry, this.icon = Icons.folder_off_outlined});
  final String message;
  final VoidCallback onRetry;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: OColors.of(context).textSecondary),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: OColors.of(context).textSecondary),
          ),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('다시 시도')),
        ],
      ),
    ),
  );
}
