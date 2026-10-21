import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fc_native_video_thumbnail/fc_native_video_thumbnail.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 로컬 동영상 썸네일 생성 + 디스크 캐시.
/// 경로+수정시각+크기로 캐시 키를 만들고, 동시에 2개까지만 생성한다.
class ThumbnailService {
  ThumbnailService._();
  static final instance = ThumbnailService._();

  final _plugin = FcNativeVideoThumbnail();
  final _memory = <String, String?>{}; // videoPath -> thumb path (null = 실패)
  final _pending = <String, Completer<String?>>{};
  final _queue = Queue<String>();
  int _running = 0;
  static const _maxParallel = 2;
  Directory? _dir;

  Future<Directory> _cacheDir() async {
    if (_dir != null) return _dir!;
    final d = Directory(p.join((await getApplicationCacheDirectory()).path, 'thumbs'));
    await d.create(recursive: true);
    return _dir = d;
  }

  /// 메모리에 이미 있으면 즉시 반환 (위젯 첫 프레임용)
  String? cached(String videoPath) => _memory[videoPath];
  bool isKnown(String videoPath) => _memory.containsKey(videoPath);

  Future<String?> get(String videoPath) {
    if (_memory.containsKey(videoPath)) return SynchronousFuture(_memory[videoPath]);
    final existing = _pending[videoPath];
    if (existing != null) return existing.future;
    final c = Completer<String?>();
    _pending[videoPath] = c;
    _queue.add(videoPath);
    _pump();
    return c.future;
  }

  /// 화면 밖으로 나간 항목은 대기열에서 뺀다 (스크롤 성능)
  void cancel(String videoPath) {
    if (_queue.remove(videoPath)) {
      _pending.remove(videoPath)?.complete(null);
    }
  }

  void _pump() {
    while (_running < _maxParallel && _queue.isNotEmpty) {
      final path = _queue.removeFirst();
      _running++;
      _generate(path).then((r) {
        _memory[path] = r;
        _pending.remove(path)?.complete(r);
      }).whenComplete(() {
        _running--;
        _pump();
      });
    }
  }

  Future<String?> _generate(String videoPath) async {
    try {
      final f = File(videoPath);
      final st = await f.stat();
      final key = sha1.convert('$videoPath|${st.modified.millisecondsSinceEpoch}|${st.size}'.codeUnits).toString();
      final out = p.join((await _cacheDir()).path, '$key.jpg');
      if (await File(out).exists()) return out;
      final ok = await _plugin.saveThumbnailToFile(
        srcFile: videoPath,
        destFile: out,
        width: 320,
        height: 180,
        format: 'jpeg',
        quality: 80,
      );
      return ok && await File(out).exists() ? out : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> clearCache() async {
    _memory.clear();
    final d = await _cacheDir();
    if (await d.exists()) await d.delete(recursive: true);
    _dir = null;
  }
}
