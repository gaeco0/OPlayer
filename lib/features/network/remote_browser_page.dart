import '../settings/resource_access_view.dart';
import 'package:flutter/material.dart';
import '../../core/resource_locks.dart';

import '../../app/theme.dart';
import '../../core/media_utils.dart';
import '../../core/settings.dart';
import 'dart:convert';
import 'dart:async';
import '../../sources/media_source.dart';
import '../browser/home_screen.dart';
import '../browser/local_browser_page.dart' show ErrorView, ScrollablePlaceholder;
import '../browser/video_tile.dart';
import '../browser/swipe_delete_tile.dart';
import '../../core/file_deletion.dart';
import '../../core/file_renaming.dart';
import '../../core/playlist_store.dart';
import '../browser/file_actions.dart';
import '../browser/playlists_page.dart';
import '../player/player_screen.dart';
import '../photos/photo_viewer.dart';
import '../web/download_manager.dart';
import '../web/download_name_dialog.dart';

/// SMB / FTP / WebDAV / DLNA / 클라우드 공용 폴더 브라우저
class RemoteBrowserPage extends StatefulWidget {
  const RemoteBrowserPage({super.key, required this.source, this.onOpenDrawer, this.actions = const []});
  final MediaSource source;
  final VoidCallback? onOpenDrawer;
  final List<Widget> actions;

  @override
  State<RemoteBrowserPage> createState() => _RemoteBrowserPageState();
}

class _Crumb {
  _Crumb(this.path, this.title);
  final String path;
  final String title;
}

class _RemoteBrowserPageState extends State<RemoteBrowserPage> {
  late final List<_Crumb> _stack = [_Crumb(widget.source.rootPath, widget.source.rootTitle)];
  final _cache = <String, List<RemoteEntry>>{};
  List<RemoteEntry> _all = [];
  List<RemoteEntry> _items = [];
  bool _loading = true;
  String? _error;
  SortBy _sort = SortBy.name;
  bool _asc = true;
  bool _foldersFirst = true;
  bool _grid = false;
  bool _videosOnly = true;
  int _loadGeneration = 0;
  final _searchController = TextEditingController();
  Timer? _searchTimer;
  bool _searchOpen = false;
  String get _query => _searchOpen ? _searchController.text.trim() : '';
  bool _selecting = false;
  bool _busy = false;
  final _selected = <String>{};
  List<RemoteEntry> get _selectedFiles => _items.where((e) => !e.isDir && _selected.contains(e.path)).toList();
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

  PlaylistTrack _track(RemoteEntry e) => PlaylistTrack(e.directUrl ?? widget.source.keyFor(e.path), e.name);
  Future<void> _addSelected() => runFileAction(
    context,
    () => addToPlaylist(context, _selectedFiles.where((e) => e.isPlayableMedia).map(_track).toList()),
  );
  Future<void> _deleteSelected() async {
    final files = _selectedFiles;
    if (!await confirmFileDeletion(context, files.length) || !mounted) return;
    await _run(() async {
      final failures = <String>[];
      for (final file in files) {
        try {
          await authorizeDeletion(widget.source.keyFor(file.path), directory: false);
          await widget.source.delete(file);
          _selected.remove(file.path);
        } catch (error) {
          failures.add('${file.name}: $error');
        }
      }
      _cache.clear();
      if (mounted) await _load(force: true);
      if (failures.isNotEmpty) throw StateError(failures.join('\n'));
    });
  }

  Future<void> _rename(RemoteEntry entry) async {
    final name = await askName(context, '파일 이름변경', initial: entry.name);
    if (name == null || name == entry.name || !mounted) return;
    await _run(() async {
      validateFileName(name);
      final source = widget.source;
      await ResourceLocks.instance.requireAccess(source.keyFor(entry.path));
      // Refresh before renaming so a stale cached list cannot hide a collision.
      if ((await source.list(_stack.last.path)).any((e) => e.name == name)) throw StateError('같은 이름의 항목이 이미 있습니다');
      String? target;
      // Filesystem-backed sources keep the same parent. Opaque-ID providers preserve their key.
      final destination = source.renamedPath(entry, name);
      try {
        await ResourceLocks.instance.renameFile(source.keyFor(entry.path), source.keyFor(destination), () async {
          target = await source.rename(entry, name);
        });
        await updateRenamedFile(source.keyFor(entry.path), source.keyFor(target!), name);
      } finally {
        _cache.clear();
        if (mounted) await _load(force: true);
      }
    });
  }

  Future<void> _deleteFromMenu(RemoteEntry entry) async {
    if (await confirmFileDeletion(context, 1) && mounted) await _run(() => _delete(entry));
  }

  Widget _wrap(RemoteEntry entry, Widget tile) => FileSelectionTile(
    active: _selecting && !entry.isDir,
    selected: _selected.contains(entry.path),
    onToggle: () => _toggle(entry.path),
    child: SwipeDeleteTile(
      key: ValueKey(entry.path),
      onDelete: !_selecting && !_busy && widget.source.canDeleteEntry(entry) ? () => _delete(entry) : null,
      watchedKey: !_selecting && entry.isPlayableMedia ? _track(entry).key : null,
      watchedTitle: entry.name,
      onChanged: () => setState(() {}),
      child: tile,
    ),
  );

  String get _sortKey => 'remote:${jsonEncode([widget.source.scheme, widget.source.id, _stack.last.path])}';

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

  @override
  void dispose() {
    _searchTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _searchChanged(String _) {
    _searchTimer?.cancel();
    // Invalidate the old request immediately, before the debounce expires.
    _loadGeneration++;
    setState(() => _loading = true);
    _searchTimer = Timer(const Duration(milliseconds: 350), () => _load());
  }

  void _submitSearch(String _) {
    _searchTimer?.cancel();
    _load();
  }

  void _closeSearch() {
    _searchTimer?.cancel();
    _searchController.clear();
    _searchOpen = false;
    _load();
  }

  Future<void> _load({bool force = false}) async {
    final generation = ++_loadGeneration;
    _restoreSort();
    final path = _stack.last.path;
    final query = _query;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ResourceLocks.instance.requireAccess(widget.source.keyFor(path));
      final list = query.isNotEmpty
          ? await widget.source.search(query, path: path)
          : (!force && _cache.containsKey(path))
          ? _cache[path]!
          : await widget.source.list(path);
      if (!mounted || generation != _loadGeneration) return;
      if (query.isEmpty) _cache[path] = list;
      _all = list;
      _apply();
      _selected.removeWhere((path) => !_items.any((e) => !e.isDir && e.path == path));
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      _error = '불러오지 못했습니다\n$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  void _apply() {
    _items = _all.where((e) => e.isDir || !_videosOnly || e.isMedia).toList()
      ..sort((a, b) {
        if (_foldersFirst && a.isDir != b.isDir) return a.isDir ? -1 : 1;
        final r = switch (_sort) {
          SortBy.name => naturalCompare(a.name, b.name),
          SortBy.date => (a.modified ?? DateTime(0)).compareTo(b.modified ?? DateTime(0)),
          SortBy.size => a.size.compareTo(b.size),
        };
        return _asc ? r : -r;
      });
  }

  void _enter(RemoteEntry e) {
    _closeSelection();
    _searchTimer?.cancel();
    _searchController.clear();
    _searchOpen = false;
    _stack.add(_Crumb(e.path, e.name));
    _load();
  }

  void _up() {
    if (_busy) return;
    if (_selecting) {
      _closeSelection();
      return;
    }
    if (_searchOpen) {
      _closeSearch();
      return;
    }
    if (_stack.length <= 1) return;
    _stack.removeLast();
    _load();
  }

  Future<void> _play(RemoteEntry e) async {
    if (e.isPhoto) {
      final photos = _items.where((x) => x.isPhoto).toList();
      await Navigator.of(
        context,
      ).push(PhotoViewer.route(photos.map((x) => widget.source.itemFor(x, _all)).toList(), photos.indexOf(e)));
      return;
    }
    final videos = _items.where((x) => x.isPlayableMedia).toList();
    final playlist = videos.map((v) => widget.source.itemFor(v, _all)).toList();
    await Navigator.of(context).push(PlayerScreen.route(playlist, videos.indexOf(e)));
    if (mounted) setState(() {});
  }

  Future<void> _delete(RemoteEntry entry) async {
    final source = widget.source;
    if (!source.canDeleteEntry(entry)) throw UnsupportedError('이 항목은 삭제할 수 없습니다');
    await authorizeDeletion(source.keyFor(entry.path), directory: entry.isDir);
    try {
      await source.delete(entry);
    } finally {
      // A recursive deletion may partially succeed even when the server fails.
      _cache.clear();
      if (mounted) await _load(force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final crumbs = _stack.skip(1).map((c) => c.title).join(' / ');
    return PopScope(
      canPop: !_selecting && !_busy && !_searchOpen && _stack.length <= 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _up();
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: _selecting
              ? IconButton(tooltip: '선택 취소', icon: const Icon(Icons.close), onPressed: _busy ? null : _closeSelection)
              : _searchOpen || _stack.length > 1
              ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: _up)
              : (widget.onOpenDrawer != null && shouldShowDrawerButton(context)
                    ? IconButton(icon: const Icon(Icons.menu), onPressed: widget.onOpenDrawer)
                    : (Navigator.canPop(context) ? const BackButton() : null)),
          title: _searchOpen && !_selecting
              ? TextField(
                  controller: _searchController,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  decoration: const InputDecoration(hintText: '저장소 검색', border: InputBorder.none),
                  onChanged: _searchChanged,
                  onSubmitted: _submitSearch,
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _selecting
                          ? '${_selected.length}개 선택'
                          : _stack.length == 1
                          ? widget.source.displayName
                          : _stack.last.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (crumbs.isNotEmpty)
                      Text(
                        '/$crumbs',
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
                onAdd: !_busy && _selectedFiles.any((e) => e.isPlayableMedia) ? _addSelected : null,
                onDelete: !_busy && _selectedFiles.isNotEmpty && _selectedFiles.every(widget.source.canDeleteEntry)
                    ? _deleteSelected
                    : null,
              )
            else ...[
              if (widget.source.canSearch)
                IconButton(
                  tooltip: _searchOpen ? '검색 닫기' : '검색',
                  icon: Icon(_searchOpen ? Icons.close : Icons.search),
                  onPressed: _searchOpen ? _closeSearch : () => setState(() => _searchOpen = true),
                ),
              if (!_searchOpen) ...[
                IconButton(
                  tooltip: '선택모드',
                  icon: const Icon(Icons.checklist),
                  onPressed: () => setState(() => _selecting = true),
                ),
                if (_stack.length > 1 && widget.onOpenDrawer != null && shouldShowDrawerButton(context))
                  IconButton(tooltip: '메뉴', icon: const Icon(Icons.menu), onPressed: widget.onOpenDrawer),
                sortMenu(
                  sort: _sort,
                  asc: _asc,
                  foldersFirst: _foldersFirst,
                  onFoldersFirst: () => setState(() {
                    _foldersFirst = !_foldersFirst;
                    _apply();
                    _saveSort();
                  }),
                  onSort: (v) => setState(() {
                    _asc = _sort == v ? !_asc : true;
                    _sort = v;
                    _apply();
                    _saveSort();
                  }),
                  extra: [
                    const PopupMenuDivider(),
                    CheckedPopupMenuItem(value: 'videos', checked: _videosOnly, child: const Text('미디어만 표시')),
                  ],
                  onExtra: (_) => setState(() {
                    _videosOnly = !_videosOnly;
                    _apply();
                  }),
                ),
                IconButton(
                  tooltip: _grid ? '목록 보기' : '격자 보기',
                  icon: Icon(_grid ? Icons.view_list : Icons.grid_view),
                  onPressed: () => setState(() => _grid = !_grid),
                ),
              ],
              IconButton(tooltip: '새로고침', icon: const Icon(Icons.refresh), onPressed: () => _load(force: true)),
              ...widget.actions,
            ],
          ],
          bottom: _busy
              ? const PreferredSize(preferredSize: Size.fromHeight(3), child: LinearProgressIndicator())
              : null,
        ),
        body: AbsorbPointer(
          absorbing: _busy,
          child: ResourceAccessView(
            resources: [widget.source.keyFor(_stack.last.path)],
            onRefresh: () => _load(force: true),
            child: SlidableAutoCloseBehavior(
              child: RefreshIndicator(onRefresh: () => _load(force: true), child: _body()),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _download(RemoteEntry entry) async {
    try {
      final fileName = await askDownloadName(context, initialName: resourceDownloadName(entry.name), resource: true);
      if (fileName == null || !mounted) return;
      final manager = DownloadManager.instance;
      await manager.addResource(
        widget.source,
        entry,
        fileName: fileName.name,
        overwriteTarget: fileName.overwriteTarget,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${fileName.name} 다운로드를 추가했습니다'),
          action: SnackBarAction(label: '다운로드 보기', onPressed: manager.openDownloads),
        ),
      );
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('다운로드를 추가하지 못했습니다: $error')));
    }
  }

  Widget _body() {
    if (_loading) return const ScrollablePlaceholder(child: Center(child: CircularProgressIndicator()));
    if (_error != null) {
      return ScrollablePlaceholder(
        child: ErrorView(message: _error!, onRetry: () => _load(force: true), icon: Icons.cloud_off),
      );
    }
    if (_items.isEmpty) {
      return ScrollablePlaceholder(
        child: Center(
          child: Text(
            _query.isEmpty ? '항목이 없습니다' : '검색 결과가 없습니다',
            style: TextStyle(color: OColors.of(context).textSecondary),
          ),
        ),
      );
    }
    final src = widget.source;

    Widget fileTile(RemoteEntry e, {required bool grid}) {
      if (!e.isMedia) {
        // Non-media files keep their original extension and bytes, too.
        return ListTile(
          leading: SizedBox(
            width: 96,
            child: Icon(Icons.insert_drive_file_outlined, color: OColors.of(context).textSecondary),
          ),
          title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(formatSize(e.size), style: TextStyle(fontSize: 12, color: OColors.of(context).textSecondary)),
          onTap: _selecting ? () => _toggle(e.path) : null,
          trailing: PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'download':
                  _download(e);
                case 'select':
                  setState(() {
                    _selecting = true;
                    _selected.add(e.path);
                  });
                case 'rename':
                  _rename(e);
                case 'delete':
                  _deleteFromMenu(e);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'download', child: Text('기기에 다운로드')),
              const PopupMenuItem(value: 'select', child: Text('선택모드')),
              PopupMenuItem(value: 'rename', enabled: src.canRenameEntry(e), child: const Text('이름변경')),
              PopupMenuItem(value: 'delete', enabled: src.canDeleteEntry(e), child: const Text('파일 삭제')),
            ],
          ),
        );
      }
      final key = e.directUrl ?? src.keyFor(e.path);
      if (grid) {
        return VideoGridTile(
          resumeKey: key,
          name: e.name,
          size: e.size,
          thumbnailUrl: e.thumbnailUrl,
          onTap: () => _play(e),
          onChanged: () => setState(() {}),
          onDownload: () => _download(e),
          onRename: src.canRenameEntry(e) ? () => _rename(e) : null,
          onDelete: src.canDeleteEntry(e) ? () => _deleteFromMenu(e) : null,
          onAddToPlaylist: e.isPlayableMedia
              ? () => runFileAction(context, () => addToPlaylist(context, [_track(e)]))
              : null,
          onSelect: () => setState(() {
            _selecting = true;
            _selected.add(e.path);
          }),
        );
      }
      return VideoListTile(
        resumeKey: key,
        name: e.name,
        size: e.size,
        modified: e.modified,
        thumbnailUrl: e.thumbnailUrl,
        location: '${src.displayName} · ${_stack.map((c) => c.title).join(' / ')}',
        hasSubtitle: MediaSource.matchSubtitles(e, _all).isNotEmpty,
        onTap: () => _play(e),
        onChanged: () => setState(() {}),
        onDownload: () => _download(e),
        onRename: src.canRenameEntry(e) ? () => _rename(e) : null,
        onDelete: src.canDeleteEntry(e) ? () => _deleteFromMenu(e) : null,
        onAddToPlaylist: e.isPlayableMedia
            ? () => runFileAction(context, () => addToPlaylist(context, [_track(e)]))
            : null,
        onSelect: () => setState(() {
          _selecting = true;
          _selected.add(e.path);
        }),
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
          final e = _items[i];
          final tile = e.isDir
              ? FolderGridTile(name: e.name, resource: src.keyFor(e.path), onTap: () => _enter(e))
              : fileTile(e, grid: true);
          return _wrap(e, tile);
        },
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 96),
      itemCount: _items.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 16, endIndent: 16),
      itemBuilder: (_, i) {
        final e = _items[i];
        final tile = e.isDir
            ? FolderListTile(name: e.name, resource: src.keyFor(e.path), onTap: () => _enter(e))
            : fileTile(e, grid: false);
        return _wrap(e, tile);
      },
    );
  }
}
