import 'dart:io';
import 'package:flutter/material.dart';
import '../../core/media_item.dart';
import '../../core/playlist_store.dart';
import '../../core/resource_locks.dart';
import '../settings/privacy_settings.dart';
import '../settings/resource_access_view.dart';
import '../../sources/source_registry.dart';
import '../player/player_screen.dart';
import 'file_actions.dart';
import 'home_screen.dart';
import 'video_tile.dart';

Future<bool> _playlistAccess(String id) async {
  try {
    await ResourceLocks.instance.requireAccess(playlistsResourceKey);
    await ResourceLocks.instance.requireAccess(playlistResourceKey(id));
    return true;
  } on ResourceLockedException {
    return false;
  }
}

Future<void> addToPlaylist(BuildContext context, List<PlaylistTrack> tracks, {String? exclude}) async {
  if (tracks.isEmpty) return;
  try {
    await ResourceLocks.instance.requireAccess(playlistsResourceKey);
  } on ResourceLockedException {
    return;
  }
  if (!context.mounted) return;
  final store = PlaylistStore.instance;
  await store.init();
  if (!context.mounted) return;
  final choice = await showDialog<String>(
    context: context,
    builder: (c) => SimpleDialog(
      title: Text('재생목록에 추가 (${tracks.length}개)'),
      children: [
        SimpleDialogOption(onPressed: () => Navigator.pop(c, ''), child: const Text('새 재생목록 만들기')),
        for (final list in store.lists.where((p) => p.id != exclude))
          SimpleDialogOption(onPressed: () => Navigator.pop(c, list.id), child: Text(list.name)),
      ],
    ),
  );
  if (choice == null || !context.mounted) return;
  if (choice.isEmpty) {
    final name = await askName(context, '새 재생목록');
    if (name == null) return;
    await store.create(name, tracks);
  } else {
    if (!await _playlistAccess(choice)) return;
    await store.add(choice, tracks);
  }
  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('재생목록에 추가했습니다')));
}

class PlaylistsPage extends StatefulWidget {
  const PlaylistsPage({super.key, required this.onOpenDrawer});
  final VoidCallback onOpenDrawer;
  @override
  State<PlaylistsPage> createState() => _PlaylistsPageState();
}

class _PlaylistsPageState extends State<PlaylistsPage> {
  final store = PlaylistStore.instance;
  @override
  void initState() {
    super.initState();
    store.init().then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _create() async {
    try {
      await ResourceLocks.instance.requireAccess(playlistsResourceKey);
    } on ResourceLockedException {
      return;
    }
    if (!mounted) return;
    final name = await askName(context, '새 재생목록');
    if (name != null && mounted) {
      await runFileAction(context, () async {
        await store.create(name);
      });
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([store, ResourceLocks.instance]),
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('재생목록'),
        leading: shouldShowDrawerButton(context)
            ? IconButton(icon: const Icon(Icons.menu), onPressed: widget.onOpenDrawer)
            : null,
        automaticallyImplyLeading: false,
        actions: [
          IconButton(tooltip: '새 재생목록', icon: const Icon(Icons.playlist_add), onPressed: _create),
          IconButton(
            tooltip: '재생목록 메뉴 잠금 설정',
            icon: Icon(ResourceLocks.instance.hasExact(playlistsResourceKey) ? Icons.lock_outline : Icons.lock_open),
            onPressed: () => toggleResourceLock(context, playlistsResourceKey, '재생목록'),
          ),
        ],
      ),
      body: ResourceAccessView(
        resources: const [playlistsResourceKey],
        child: store.lists.isEmpty
            ? const Center(child: Text('재생목록을 만들어 파일을 추가하세요'))
            : ListView(
                children: [
                  for (final list in store.lists)
                    ListTile(
                      leading: Icon(
                        ResourceLocks.instance.isLocked(playlistResourceKey(list.id))
                            ? Icons.lock_outline
                            : Icons.playlist_play,
                      ),
                      title: Text(list.name),
                      subtitle: Text(
                        ResourceLocks.instance.isLocked(playlistResourceKey(list.id)) ? '잠김' : '${list.tracks.length}개',
                      ),
                      onTap: () async {
                        if (!await _playlistAccess(list.id) || !context.mounted) return;
                        await Navigator.of(
                          context,
                        ).push(MaterialPageRoute<void>(builder: (_) => PlaylistPage(id: list.id)));
                      },
                      trailing: PopupMenuButton<String>(
                        onSelected: (action) async {
                          if (action == 'lock') {
                            await toggleResourceLock(context, playlistResourceKey(list.id), list.name);
                            return;
                          }
                          if (!await _playlistAccess(list.id) || !context.mounted) return;
                          if (action == 'rename') {
                            final name = await askName(context, '재생목록 이름변경', initial: list.name);
                            if (name != null && context.mounted) {
                              await runFileAction(context, () => store.rename(list.id, name));
                            }
                          } else {
                            final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (c) => AlertDialog(
                                title: const Text('재생목록 삭제'),
                                content: Text('${list.name} 목록을 삭제합니다. 원본 파일은 유지됩니다.'),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(c), child: const Text('취소')),
                                  TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('삭제')),
                                ],
                              ),
                            );
                            if (confirmed == true && context.mounted) {
                              await runFileAction(context, () => store.delete(list.id));
                            }
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'lock',
                            child: Text(
                              ResourceLocks.instance.hasExact(playlistResourceKey(list.id)) ? '잠금 설정 해제' : '이 재생목록 잠금',
                            ),
                          ),
                          const PopupMenuItem(value: 'rename', child: Text('이름변경')),
                          const PopupMenuItem(value: 'delete', child: Text('재생목록 삭제')),
                        ],
                      ),
                    ),
                ],
              ),
      ),
    ),
  );
}

class PlaylistPage extends StatefulWidget {
  const PlaylistPage({super.key, required this.id});
  final String id;
  @override
  State<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends State<PlaylistPage> {
  final store = PlaylistStore.instance;
  final selected = <String>{};
  bool selecting = false;
  void toggle(String key) => setState(() {
    if (!selected.add(key)) selected.remove(key);
  });
  Future<void> play(SavedPlaylist list, int index) async {
    if (!await _playlistAccess(widget.id) || !mounted) return;
    final items = list.tracks
        .map(
          (t) => MediaItem(
            key: t.key,
            uri: t.key,
            title: t.title,
            resolver: () async {
              final item = await SourceRegistry.instance.itemFromKey(t.key, title: t.title);
              if (item == null) throw StateError('${t.title}: 파일 또는 저장소를 찾을 수 없습니다');
              return item.resolve();
            },
          ),
        )
        .toList();
    await Navigator.of(context).push(PlayerScreen.route(items, index));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([store, ResourceLocks.instance]),
    builder: (context, _) {
      final list = store.find(widget.id);
      final tracks = list?.tracks ?? <PlaylistTrack>[];
      final locked =
          ResourceLocks.instance.isLocked(playlistsResourceKey) ||
          ResourceLocks.instance.isLocked(playlistResourceKey(widget.id));
      return PopScope(
        canPop: !selecting || locked,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) {
            setState(() {
              selecting = false;
              selected.clear();
            });
          }
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(selecting && !locked ? '${selected.length}개 선택' : list?.name ?? '재생목록'),
            leading: selecting && !locked
                ? IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() {
                      selecting = false;
                      selected.clear();
                    }),
                  )
                : null,
            actions: [
              if (selecting && !locked)
                FileSelectionActions(
                  onSelectAll: () => setState(() {
                    if (selected.length == tracks.length) {
                      selected.clear();
                    } else {
                      selected.addAll(tracks.map((t) => t.key));
                    }
                  }),
                  onAdd: selected.isEmpty
                      ? null
                      : () => runFileAction(
                          context,
                          () => addToPlaylist(
                            context,
                            tracks.where((t) => selected.contains(t.key)).toList(),
                            exclude: widget.id,
                          ),
                        ),
                  onDelete: selected.isEmpty
                      ? null
                      : () => runFileAction(context, () async {
                          await store.remove(widget.id, selected);
                          if (mounted) setState(selected.clear);
                        }),
                  removeLabel: '재생목록에서 삭제',
                )
              else if (!locked)
                IconButton(
                  tooltip: '선택모드',
                  icon: const Icon(Icons.checklist),
                  onPressed: () => setState(() => selecting = true),
                ),
              IconButton(
                tooltip: '이 재생목록 잠금 설정',
                icon: Icon(
                  ResourceLocks.instance.hasExact(playlistResourceKey(widget.id))
                      ? Icons.lock_outline
                      : Icons.lock_open,
                ),
                onPressed: () => toggleResourceLock(context, playlistResourceKey(widget.id), list?.name ?? '재생목록'),
              ),
            ],
          ),
          body: ResourceAccessView(
            resources: [playlistsResourceKey, playlistResourceKey(widget.id)],
            child: tracks.isEmpty
                ? const Center(child: Text('재생목록이 비어 있습니다'))
                : ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    itemCount: tracks.length,
                    onReorderItem: (a, b) => runFileAction(context, () => store.reorder(widget.id, a, b)),
                    itemBuilder: (_, i) {
                      final t = tracks[i];
                      final local = !t.key.contains('://') && File(t.key).existsSync();
                      return FileSelectionTile(
                        key: ValueKey(t.key),
                        active: selecting,
                        selected: selected.contains(t.key),
                        onToggle: () => toggle(t.key),
                        child: Row(
                          children: [
                            Expanded(
                              child: VideoListTile(
                                resumeKey: t.key,
                                name: t.title,
                                localPath: local ? t.key : null,
                                onTap: () => play(list!, i),
                                onChanged: () => setState(() {}),
                                onAddToPlaylist: () =>
                                    runFileAction(context, () => addToPlaylist(context, [t], exclude: widget.id)),
                                onSelect: () => setState(() {
                                  selecting = true;
                                  selected.add(t.key);
                                }),
                                onRemoveFromPlaylist: () =>
                                    runFileAction(context, () => store.remove(widget.id, {t.key})),
                              ),
                            ),
                            if (!selecting)
                              ReorderableDragStartListener(
                                index: i,
                                child: const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: Tooltip(message: '순서 변경', child: Icon(Icons.drag_handle)),
                                ),
                              ),
                          ],
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
