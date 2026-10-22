import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../app/theme.dart';
import '../../core/media_item.dart';
import '../../core/media_utils.dart';
import '../../core/resource_locks.dart';
import '../settings/privacy_settings.dart';
import '../settings/resource_access_view.dart';
import '../photos/photo_viewer.dart';
import '../../sources/server_store.dart';
import '../../sources/source_registry.dart';
import '../player/player_screen.dart';
import 'download_manager.dart';

String _dest(DownloadTask t) {
  if (!t.isRemote) return '';
  final name = ServerStore.instance.server(t.remoteServerId!)?.name ?? '삭제된 서버';
  return ' → $name:${t.remoteDir ?? '/'}';
}

String _speed(double bps) => bps <= 0 ? '' : '${formatSize(bps.round())}/s';

/// 다운로드 목록: 진행률, 일시정지/재개, 완료 파일 재생
class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key, this.leading});
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final m = DownloadManager.instance;
    return ListenableBuilder(
      listenable: ResourceLocks.instance,
      builder: (context, _) => TooltipVisibility(
        visible: false,
        child: Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: leading == null,
            leading: leading,
            title: const Text('다운로드'),
            actions: [
              IconButton(
                icon: Icon(ResourceLocks.instance.hasExact(downloadsResourceKey) ? Icons.lock : Icons.lock_open),
                onPressed: () => toggleResourceLock(context, downloadsResourceKey, '다운로드'),
              ),
              if (!ResourceLocks.instance.isLocked(downloadsResourceKey))
                PopupMenuButton<String>(
                  tooltip: '목록 정리',
                  icon: const Icon(Icons.cleaning_services_outlined),
                  onSelected: (v) async {
                    final n = switch (v) {
                      'done' => await m.clear(done: true, failed: false),
                      'failed' => await m.clear(done: false, failed: true),
                      _ => await m.clear(done: true, failed: true, paused: true),
                    };
                    if (context.mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text(n == 0 ? '지울 항목이 없습니다' : '$n개 항목을 목록에서 지웠습니다')));
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'done', child: Text('완료 항목 지우기')),
                    PopupMenuItem(value: 'failed', child: Text('실패 항목 지우기')),
                    PopupMenuItem(value: 'all', child: Text('진행 중 제외 모두 지우기')),
                  ],
                ),
            ],
          ),
          body: ResourceAccessView(
            resources: const [downloadsResourceKey],
            child: ListenableBuilder(
              listenable: m,
              builder: (context, _) {
                if (m.tasks.isEmpty) {
                  return Center(
                    child: Text(
                      '다운로드한 파일이 없습니다\n웹 브라우저나 원격 저장소에서 파일을 다운로드해 보세요',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: OColors.of(context).textSecondary),
                    ),
                  );
                }
                return ListView.separated(
                  itemCount: m.tasks.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, indent: 16, endIndent: 16),
                  itemBuilder: (_, i) => _Tile(task: m.tasks[i]),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.task});
  final DownloadTask task;

  @override
  Widget build(BuildContext context) {
    final m = DownloadManager.instance;
    final t = task;
    final status = switch (t.status) {
      DownloadStatus.queued => '대기 중${_dest(t)}',
      DownloadStatus.running =>
        t.kind == DownloadKind.hls && !t.uploading
            ? '${t.phase ?? ''}${t.total > 0 ? ' · ${t.done}/${t.total} 조각' : ''} · ${formatSize(t.received)} ${_speed(t.speed)}'
            : '${t.phase == null ? '' : '${t.phase} · '}${formatSize(t.received)}${t.total > 0 ? ' / ${formatSize(t.total)}' : ''} ${_speed(t.speed)}',
      DownloadStatus.paused => '일시정지 · ${((t.progress ?? 0) * 100).toStringAsFixed(0)}%',
      DownloadStatus.done =>
        '완료 · ${formatSize(t.total > 0 && t.kind != DownloadKind.hls ? t.total : t.received)}'
            '${t.note == null ? '' : '\n${t.note}'}',
      DownloadStatus.failed => '실패: ${t.error ?? ''}',
    };

    Future<void> play() async {
      MediaItem? item;
      if (t.remoteKey != null) {
        item = await SourceRegistry.instance.itemFromKey(t.remoteKey!, title: p.basenameWithoutExtension(t.fileName));
      } else if (t.savePath != null && File(t.savePath!).existsSync()) {
        item = MediaItem.local(t.savePath!);
      }
      if (!context.mounted) return;
      if (item == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('파일을 찾을 수 없습니다')));
        return;
      }
      if (isImage(t.fileName)) {
        await Navigator.of(context).push(PhotoViewer.route([item], 0));
      } else {
        await Navigator.of(context).push(PlayerScreen.route([item], 0));
      }
    }

    return ListTile(
      onTap: t.status == DownloadStatus.done && (isPlayable(t.fileName) || isImage(t.fileName)) ? play : null,
      leading: SizedBox(
        width: 40,
        height: 40,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (t.status == DownloadStatus.running || t.status == DownloadStatus.paused)
              CircularProgressIndicator(
                value: t.progress,
                strokeWidth: 3,
                backgroundColor: OColors.of(context).surfaceHigh,
              ),
            Icon(
              switch (t.status) {
                DownloadStatus.done =>
                  isImage(t.fileName)
                      ? Icons.image_outlined
                      : isPlayable(t.fileName)
                      ? Icons.play_circle_outline
                      : Icons.insert_drive_file_outlined,
                DownloadStatus.failed => Icons.error_outline,
                _ =>
                  t.kind == DownloadKind.hls
                      ? Icons.stream
                      : t.kind == DownloadKind.resource
                      ? Icons.download_outlined
                      : Icons.movie_outlined,
              },
              size: t.status == DownloadStatus.done ? 32 : 20,
              color: t.status == DownloadStatus.failed ? Colors.redAccent : OColors.of(context).accent,
            ),
          ],
        ),
      ),
      title: Text(t.fileName, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        status,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: t.status == DownloadStatus.failed ? Colors.redAccent : OColors.of(context).textSecondary,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (t.status == DownloadStatus.running)
            IconButton(icon: const Icon(Icons.pause), tooltip: '일시정지', onPressed: () => m.pause(t)),
          if (t.status == DownloadStatus.paused || t.status == DownloadStatus.failed)
            IconButton(icon: const Icon(Icons.play_arrow), tooltip: '재개', onPressed: () => m.resume(t)),
          PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'remove':
                  await m.remove(t);
                case 'delete':
                  await m.remove(t, deleteFile: true);
                case 'info':
                  if (!context.mounted) return;
                  await showDialog<void>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: Text(t.fileName),
                      content: SelectableText(
                        '저장 위치: ${t.remoteKey ?? t.savePath ?? (t.isRemote ? '(업로드 예정)${_dest(t)}' : '-')}\n\n원본: ${t.url}'
                        '${t.pageUrl == null ? '' : '\n\n페이지: ${t.pageUrl}'}',
                      ),
                      actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('닫기'))],
                    ),
                  );
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'info', child: Text('정보')),
              const PopupMenuItem(value: 'remove', child: Text('목록에서 제거')),
              PopupMenuItem(
                value: 'delete',
                child: Text(t.savePath == null ? '취소' : '파일 삭제 (${p.extension(t.savePath!)})'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
