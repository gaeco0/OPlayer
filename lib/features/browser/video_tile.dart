import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../app/theme.dart';
import '../../core/media_utils.dart';
import '../../core/resume_store.dart';
import '../../core/settings.dart';
import '../../core/folder_sort.dart';
export '../../core/folder_sort.dart';
import '../../core/resource_locks.dart';
import '../settings/privacy_settings.dart';
import '../../core/thumbnail_service.dart';

/// 썸네일 (로컬: 프레임 추출 캐시 / 원격: 서버 제공 썸네일 URL) + 길이 + 이어보기 진행바
class VideoThumb extends StatefulWidget {
  const VideoThumb({
    super.key,
    required this.resumeKey,
    required this.name,
    this.localPath,
    this.thumbnailUrl,
    this.width = 96,
    this.height = 54,
  });
  final String resumeKey;
  final String name;
  final String? localPath;
  final String? thumbnailUrl;
  final double width;
  final double? height;

  @override
  State<VideoThumb> createState() => _VideoThumbState();
}

class _VideoThumbState extends State<VideoThumb> {
  String? _thumb;

  @override
  void initState() {
    super.initState();
    _load();
    ResourceLocks.instance.addListener(_lockChanged);
  }

  @override
  void didUpdateWidget(VideoThumb old) {
    super.didUpdateWidget(old);
    if (old.localPath != widget.localPath) {
      _thumb = null;
      _load();
    }
  }

  void _lockChanged() {
    if (mounted) {
      setState(() {});
      _load();
    }
  }

  @override
  void dispose() {
    ResourceLocks.instance.removeListener(_lockChanged);
    final lp = widget.localPath;
    if (lp != null && _thumb == null) ThumbnailService.instance.cancel(lp);
    super.dispose();
  }

  void _load() {
    final lp = widget.localPath;
    if (ResourceLocks.instance.isLocked(widget.resumeKey)) return;
    if (lp == null || !isVideo(lp) || !AppSettings.instance.showThumbnails) return;
    final svc = ThumbnailService.instance;
    if (svc.isKnown(lp)) {
      _thumb = svc.cached(lp);
      return;
    }
    svc.get(lp).then((t) {
      if (mounted && t != null) setState(() => _thumb = t);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (ResourceLocks.instance.isLocked(widget.resumeKey)) {
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: const Center(child: Icon(Icons.lock)),
      );
    }
    final r = ResumeStore.instance.get(widget.resumeKey);
    final ext = p.extension(widget.name).replaceFirst('.', '').toUpperCase();
    Widget image = const Center(child: Icon(Icons.movie_outlined, color: Color(0x44FFFFFF), size: 26));
    if (isAudio(widget.name)) {
      image = const Center(child: Icon(Icons.audiotrack, color: OColors.accent, size: 28));
    } else if (widget.localPath != null && isImage(widget.name) && AppSettings.instance.showThumbnails) {
      image = Image.file(
        File(widget.localPath!),
        fit: BoxFit.cover,
        cacheWidth: 440,
        errorBuilder: (_, __, ___) => const Icon(Icons.broken_image),
      );
    } else if (_thumb != null) {
      image = Image.file(File(_thumb!), fit: BoxFit.cover, errorBuilder: (_, __, ___) => image);
    } else if (widget.thumbnailUrl != null && AppSettings.instance.showThumbnails) {
      image = Image.network(widget.thumbnailUrl!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => image);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Container(
        width: widget.width,
        height: widget.height,
        color: OColors.surfaceHigh,
        child: Stack(
          fit: StackFit.expand,
          children: [
            image,
            if (_thumb == null && widget.thumbnailUrl == null && ext.isNotEmpty && ext.length <= 5)
              Positioned(
                left: 4,
                top: 4,
                child: Text(
                  ext,
                  style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: OColors.textSecondary),
                ),
              ),
            if (r != null)
              Positioned(
                right: 4,
                bottom: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                  color: Colors.black54,
                  child: Text(formatDuration(r.duration), style: const TextStyle(fontSize: 9, color: Colors.white)),
                ),
              ),
            if (r != null)
              Align(
                alignment: Alignment.bottomCenter,
                child: LinearProgressIndicator(
                  value: r.progress,
                  minHeight: 3,
                  backgroundColor: Colors.black38,
                  color: r.finished ? OColors.textSecondary : OColors.accent,
                ),
              ),
            if (r?.finished ?? false)
              Container(
                color: Colors.black45,
                child: const Center(child: Icon(Icons.check_circle, color: Colors.white70, size: 22)),
              ),
          ],
        ),
      ),
    );
  }
}

Future<void> showVideoMenu(
  BuildContext context, {
  required String resumeKey,
  required String name,
  String? location,
  required VoidCallback onChanged,
  List<Widget> extra = const [],
}) async {
  final r = ResumeStore.instance.get(resumeKey);
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: OColors.surface,
    builder: (c) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: location == null ? null : Text(location, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: Text(ResourceLocks.instance.hasExact(resumeKey) ? '잠금 설정 해제' : '이 항목 잠금'),
            onTap: () async {
              Navigator.pop(c);
              await toggleResourceLock(context, resumeKey, name);
              onChanged();
            },
          ),
          if (r != null)
            ListTile(
              leading: const Icon(Icons.restart_alt),
              title: const Text('재생 기록 삭제'),
              onTap: () async {
                await ResumeStore.instance.remove(resumeKey);
                if (c.mounted) Navigator.pop(c);
                onChanged();
              },
            ),
          ListTile(
            leading: const Icon(Icons.done_all),
            title: const Text('시청 완료로 표시'),
            onTap: () async {
              final d = r?.duration ?? const Duration(seconds: 1);
              await ResumeStore.instance.save(resumeKey, d, d, title: p.basenameWithoutExtension(name));
              if (c.mounted) Navigator.pop(c);
              onChanged();
            },
          ),
          ...extra,
        ],
      ),
    ),
  );
}

/// 동영상 한 줄 (로컬/원격 공용)
class VideoListTile extends StatelessWidget {
  const VideoListTile({
    super.key,
    required this.resumeKey,
    required this.name,
    required this.onTap,
    required this.onChanged,
    this.size = 0,
    this.modified,
    this.localPath,
    this.thumbnailUrl,
    this.location,
    this.hasSubtitle = false,
  });

  final String resumeKey;
  final String name;
  final int size;
  final DateTime? modified;
  final String? localPath;
  final String? thumbnailUrl;
  final String? location;
  final bool hasSubtitle;
  final VoidCallback onTap;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final r = ResumeStore.instance.get(resumeKey);
    final m = modified;
    final date = m == null
        ? null
        : '${m.year}.${m.month.toString().padLeft(2, '0')}.${m.day.toString().padLeft(2, '0')}';
    final meta = [if (size > 0) formatSize(size), if (date != null) date].join(' · ');
    void menu() =>
        showVideoMenu(context, resumeKey: resumeKey, name: name, location: location ?? localPath, onChanged: onChanged);
    return InkWell(
      onTap: onTap,
      onLongPress: menu,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            VideoThumb(resumeKey: resumeKey, name: name, localPath: localPath, thumbnailUrl: thumbnailUrl),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      color: (r?.finished ?? false) ? OColors.textSecondary : OColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (meta.isNotEmpty)
                        Text(meta, style: const TextStyle(fontSize: 12, color: OColors.textSecondary)),
                      if (hasSubtitle) const _Badge('자막'),
                      if (r != null && !r.finished)
                        Text(
                          '${formatDuration(r.position)}부터',
                          style: const TextStyle(fontSize: 12, color: OColors.accent),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.more_vert, color: OColors.textSecondary),
              onPressed: menu,
            ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
    decoration: BoxDecoration(
      border: Border.all(color: OColors.textSecondary, width: 0.8),
      borderRadius: BorderRadius.circular(3),
    ),
    child: Text(text, style: const TextStyle(fontSize: 10, color: OColors.textSecondary)),
  );
}

class VideoGridTile extends StatelessWidget {
  const VideoGridTile({
    super.key,
    required this.resumeKey,
    required this.name,
    required this.onTap,
    required this.onChanged,
    this.size = 0,
    this.localPath,
    this.thumbnailUrl,
  });
  final String resumeKey;
  final String name;
  final int size;
  final String? localPath;
  final String? thumbnailUrl;
  final VoidCallback onTap;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      onLongPress: () => showVideoMenu(context, resumeKey: resumeKey, name: name, onChanged: onChanged),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: VideoThumb(
              resumeKey: resumeKey,
              name: name,
              localPath: localPath,
              thumbnailUrl: thumbnailUrl,
              width: double.infinity,
              height: null,
            ),
          ),
          const SizedBox(height: 6),
          Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
          if (size > 0) Text(formatSize(size), style: const TextStyle(fontSize: 11, color: OColors.textSecondary)),
        ],
      ),
    );
  }
}

class FolderListTile extends StatelessWidget {
  const FolderListTile({super.key, required this.name, required this.onTap, this.subtitle, this.resource});
  final String name;
  final String? resource;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const SizedBox(width: 96, child: Icon(Icons.folder_rounded, color: Color(0xFFF2B84B), size: 40)),
    title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: subtitle == null
        ? null
        : Text(subtitle!, style: const TextStyle(fontSize: 12, color: OColors.textSecondary)),
    trailing: const Icon(Icons.chevron_right, color: OColors.textSecondary),
    onTap: onTap,
    onLongPress: resource == null ? null : () => toggleResourceLock(context, resource!, name),
  );
}

class FolderGridTile extends StatelessWidget {
  const FolderGridTile({super.key, required this.name, required this.onTap, this.resource});
  final String name;
  final String? resource;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      onLongPress: resource == null ? null : () => toggleResourceLock(context, resource!, name),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(
              decoration: BoxDecoration(color: OColors.surfaceHigh, borderRadius: BorderRadius.circular(4)),
              child: const Icon(Icons.folder_rounded, color: Color(0xFFF2B84B), size: 44),
            ),
          ),
          const SizedBox(height: 6),
          Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }
}

/// 목록/격자 + 정렬 상태 (로컬·원격 브라우저 공용)
String sortLabel(SortBy s) => switch (s) {
  SortBy.name => '이름',
  SortBy.date => '날짜',
  SortBy.size => '크기',
};

PopupMenuButton<Object> sortMenu({
  required SortBy sort,
  required bool asc,
  required void Function(SortBy) onSort,
  required bool foldersFirst,
  required VoidCallback onFoldersFirst,
  List<PopupMenuEntry<Object>> extra = const [],
  void Function(Object)? onExtra,
}) => PopupMenuButton<Object>(
  tooltip: '정렬',
  icon: const Icon(Icons.sort),
  onSelected: (v) {
    if (v is SortBy) {
      onSort(v);
    } else if (v == 'folders-first') {
      onFoldersFirst();
    } else {
      onExtra?.call(v);
    }
  },
  itemBuilder: (_) => [
    for (final s in SortBy.values)
      CheckedPopupMenuItem(
        value: s,
        checked: sort == s,
        child: Text('${sortLabel(s)}${sort == s ? (asc ? '  ↑' : '  ↓') : ''}'),
      ),
    const PopupMenuDivider(),
    CheckedPopupMenuItem(value: 'folders-first', checked: foldersFirst, child: const Text('폴더 먼저 표시')),
    ...extra,
  ],
);
