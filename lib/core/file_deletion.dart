import 'dart:io';
import 'package:path/path.dart' as p;

import 'resource_locks.dart';
import 'resource_playback_store.dart';

/// A folder cannot be used to bypass independently protected descendants.
Future<void> authorizeDeletion(String resource, {required bool directory}) async {
  final locks = ResourceLocks.instance;
  final key = resourceKey(resource);
  final targets = [
    resource,
    if (directory) ...locks.resources.keys.where((candidate) => candidate.startsWith('$key/')),
  ];
  for (final target in targets) {
    await locks.requireAccess(target);
  }
  if (targets.any(locks.isLocked)) throw const ResourceLockedException();
}

Future<void> deleteLocalEntry(String path, {required String parent}) async {
  final target = p.normalize(p.absolute(path));
  final folder = p.normalize(p.absolute(parent));
  if (!p.equals(p.dirname(target), folder) || p.equals(target, folder)) {
    throw const FileSystemException('현재 폴더의 항목만 삭제할 수 있습니다');
  }
  // Do not follow symbolic links; deleting a link never deletes its destination.
  final type = await FileSystemEntity.type(target, followLinks: false);
  await authorizeDeletion(target, directory: type == FileSystemEntityType.directory);
  switch (type) {
    case FileSystemEntityType.directory:
      await Directory(target).delete(recursive: true);
    case FileSystemEntityType.file:
      await File(target).delete();
    case FileSystemEntityType.link:
      await Link(target).delete();
    default:
      throw const FileSystemException('삭제할 항목이 존재하지 않습니다');
  }
  await ResourcePlaybackStore.instance.forget(target, directory: type == FileSystemEntityType.directory);
}
