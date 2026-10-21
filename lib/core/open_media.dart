import 'dart:io';
import 'package:flutter/material.dart';
import 'media_item.dart';
import 'media_utils.dart';
import '../features/photos/photo_viewer.dart';
import '../features/player/player_screen.dart';

Future<void> openLocalMedia(BuildContext context, Iterable<String> paths, {bool waitForClose = true}) async {
  final files = <String>[];
  for (final path in paths.toSet()) {
    if (isBrowsableMedia(path) && await File(path).exists()) files.add(path);
  }
  if (!context.mounted) return;
  if (files.isEmpty) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('재생 가능한 영상·오디오 또는 사진 파일을 선택해 주세요')));
    return;
  }
  final photos = isImage(files.first);
  final selected = files
      .where((path) => photos ? isImage(path) : isPlayable(path))
      .map(MediaItem.local)
      .toList();
  final closed = Navigator.of(context).pushAndRemoveUntil(
    photos ? PhotoViewer.route(selected, 0) : PlayerScreen.route(selected, 0),
    (route) => route.isFirst,
  );
  if (waitForClose) await closed;
}
