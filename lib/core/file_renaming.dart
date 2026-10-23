import 'dart:io';
import 'package:path/path.dart' as p;
import 'playlist_store.dart';
import 'resume_store.dart';
import 'resource_locks.dart';

String validateFileName(String name) {
  if (name.isEmpty ||
      name == '.' ||
      name == '..' ||
      RegExp(r'[/\\\x00-\x1f]').hasMatch(name) ||
      (Platform.isWindows && (RegExp(r'[<>:"|?*]').hasMatch(name) || name.endsWith('.') || name.endsWith(' ')))) {
    throw const FormatException('파일 이름에 경로나 사용할 수 없는 문자를 넣을 수 없습니다');
  }
  return name;
}

Future<void> updateRenamedFile(String oldKey, String newKey, String name) async {
  await ResumeStore.instance.relocate(oldKey, newKey, p.basenameWithoutExtension(name));
  await PlaylistStore.instance.relocate(oldKey, newKey, name);
}

Future<String> renameLocalFile(String path, String name, {required String parent}) async {
  validateFileName(name);
  final oldPath = p.normalize(p.absolute(path));
  if (!p.equals(p.dirname(oldPath), p.normalize(p.absolute(parent)))) {
    throw const FileSystemException('현재 폴더의 파일만 이름을 바꿀 수 있습니다');
  }
  if (await FileSystemEntity.type(oldPath, followLinks: false) != FileSystemEntityType.file) {
    throw const FileSystemException('일반 파일만 이름을 바꿀 수 있습니다');
  }
  final newPath = p.join(p.dirname(oldPath), name);
  if (oldPath == newPath) return path;
  if (await FileSystemEntity.type(newPath, followLinks: false) != FileSystemEntityType.notFound) {
    throw const FileSystemException('같은 이름의 항목이 이미 있습니다');
  }
  await ResourceLocks.instance.renameFile(oldPath, newPath, () async {
    await File(oldPath).rename(newPath);
  });
  await updateRenamedFile(path, newPath, name);
  return newPath;
}
