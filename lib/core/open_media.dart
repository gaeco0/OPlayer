import 'dart:io';
import 'package:flutter/material.dart';
import 'media_item.dart';
import 'media_utils.dart';
import 'external_files.dart';
import 'package:path/path.dart' as p;
import '../features/photos/photo_viewer.dart';
import '../features/player/player_screen.dart';

Future<void> openLocalMedia(BuildContext context, Iterable<String> paths, {bool waitForClose = true}) async {
  final files = <String>[];
  for (final value in paths.toSet()) {
    final uri = Uri.tryParse(value);
    final path = uri?.scheme == 'file' ? File.fromUri(uri!).path : value;
    if (isBrowsableMedia(path) && await File(path).exists()) files.add(path);
  }
  if (!context.mounted) return;
  if (files.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('재생 가능한 영상·오디오 또는 사진 파일을 선택해 주세요')));
    return;
  }
  final photos = isImage(files.first);
  final selected = files.where((path) => photos ? isImage(path) : isPlayable(path)).map(MediaItem.local).toList();
  final closed = Navigator.of(context).pushAndRemoveUntil(
    photos ? PhotoViewer.route(selected, 0) : PlayerScreen.route(selected, 0),
    (route) => route.isFirst,
  );
  if (waitForClose) await closed;
}

Future<void> openExternalMedia(BuildContext context, List<ExternalFile> files) async {
  final items = <(MediaItem, bool)>[];
  for (final file in files) {
    final uri = Uri.tryParse(file.uri);
    if (uri == null) continue;
    if (uri.scheme == 'content') {
      final image = file.mime.startsWith('image/') || isImage(file.name);
      if (!image &&
          !file.mime.startsWith('audio/') &&
          !file.mime.startsWith('video/') &&
          !isPlayable(file.name) &&
          !const {
            'application/ogg',
            'application/mp4',
            'application/x-matroska',
            'application/vnd.apple.mpegurl',
            'application/x-mpegurl',
            'audio/x-mpegurl',
          }.contains(file.mime)) {
        continue;
      }
      items.add((
        MediaItem(
          key: file.uri,
          uri: file.uri,
          title: file.name.isEmpty ? '외부 파일' : p.basenameWithoutExtension(file.name),
          resolver: !image
              ? null
              : () async {
                  final path = await externalFilesChannel.invokeMethod<String>('prepareImage', file.uri);
                  if (path == null) throw const FileSystemException('사진 파일을 읽을 수 없습니다');
                  return MediaItem(key: file.uri, uri: path, title: file.name, localPath: path);
                },
        ),
        image,
      ));
    } else if (uri.scheme.isEmpty || uri.scheme == 'file' || p.isAbsolute(file.uri)) {
      final path = uri.scheme == 'file' ? File.fromUri(uri).path : file.uri;
      if (isBrowsableMedia(path) && await File(path).exists()) items.add((MediaItem.local(path), isImage(path)));
    }
  }
  if (!context.mounted) return;
  if (items.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('지원하지 않거나 읽을 수 없는 파일입니다')));
    return;
  }
  final photos = items.first.$2;
  final selected = items.where((item) => item.$2 == photos).map((item) => item.$1).toList();
  Navigator.of(context).pushAndRemoveUntil(
    photos ? PhotoViewer.route(selected, 0) : PlayerScreen.route(selected, 0),
    (route) => route.isFirst,
  );
}
