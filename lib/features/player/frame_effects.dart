import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import '../../core/plugins/plugin.dart';
import '../../core/plugins/plugin_store.dart';
import '../../core/plugins/pixel_program.dart';
import 'video_upscaling.dart';

/// Owns an ordered chain of extension programs, independent of upscaler choice.
class FrameEffects {
  FrameEffects({required Future<void> Function(List<String>) command, required this.changed, PluginStore? store})
    : store = store ?? PluginStore.instance,
      _shader = UpscaleShader(command) {
    this.store.addListener(_onProvidersChanged);
  }
  final PluginStore store;
  final void Function() changed;
  final UpscaleShader _shader;
  Map<String, List<PixelProgram>> _providers = {};
  List<PixelProgram> programs = const [];
  List<String> get ids => List.unmodifiable(_providers.keys);
  bool contains(String id) => _providers.containsKey(id);
  int _pending = 0;
  bool get busy => _pending > 0;
  bool _closed = false;
  String? issue;
  Future<void> _tail = Future.value();
  Directory? _directory;
  String? _path;

  Future<T> _queue<T>(Future<T> Function() action) {
    if (_closed) return Future.error(StateError('프레임 처리기가 종료되었습니다'));
    _pending++;
    changed();
    final result = _tail.then((_) async {
      if (_closed) throw StateError('프레임 처리기가 종료되었습니다');
      try {
        return await action();
      } finally {
        _pending--;
        if (!_closed) changed();
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<bool> activate(OPlugin plugin) => _queue(() async {
    final current = store.require(plugin.id);
    if (!identical(current, plugin) || plugin.kind != 'player' || !plugin.supports('videoFilter')) {
      throw StateError('사용할 수 없는 프레임 확장앱');
    }
    final result = await pixelPrograms(plugin, store.publicSettings(plugin));
    if (!identical(store.require(plugin.id), plugin)) throw StateError('확장앱이 변경되었습니다');
    if (result == null) return false;
    issue = null;
    await _commit({..._providers, plugin.id: result});
    return true;
  });
  Future<void> remove(String id) => _queue(() async {
    final next = Map<String, List<PixelProgram>>.of(_providers)..remove(id);
    await _commit(next);
  });
  Future<void> clear() => _queue(() => _commit({}));
  Future<void> move(String id, int delta) => _queue(() async {
    final keys = _providers.keys.toList();
    final i = keys.indexOf(id);
    if (i < 0 || i + delta < 0 || i + delta >= keys.length) return;
    keys.removeAt(i);
    keys.insert(i + delta, id);
    await _commit({for (final k in keys) k: _providers[k]!});
  });
  Future<void> restore(List<String> ids) => _queue(() async {
    final next = <String, List<PixelProgram>>{};
    for (final id in ids.take(8)) {
      final p = store.enabled.where((p) => p.id == id && p.supports('videoFilter')).firstOrNull;
      if (p == null) continue;
      final result = await pixelPrograms(p, store.publicSettings(p));
      if (result != null) next[id] = result;
    }
    await _commit(next);
  });
  void _onProvidersChanged() {
    if (_closed || _providers.isEmpty) return;
    _queue(() async {
      final next = <String, List<PixelProgram>>{};
      issue = null;
      for (final id in _providers.keys) {
        try {
          final p = store.require(id);
          final result = await pixelPrograms(p, store.publicSettings(p));
          if (result != null && identical(store.require(id), p)) next[id] = result;
        } catch (e) {
          issue = '프레임 확장앱 비활성화: $e';
        }
      }
      await _commit(next);
    }).catchError((Object e) {
      if (!_closed) {
        issue = '$e';
        changed();
      }
    });
  }

  Future<void> _commit(Map<String, List<PixelProgram>> next) async {
    final passes = [for (final p in next.values) ...p];
    if (next.length > 8 || passes.length > 8) throw StateError('동시 프레임 처리 단계는 최대 8개입니다');
    final owners = {for (final id in next.keys) id: store.require(id)};
    void verifyOwners() {
      for (final entry in owners.entries) {
        if (!identical(store.require(entry.key), entry.value)) throw StateError('처리 중 확장앱이 변경되었습니다');
      }
    }

    String? path;
    if (passes.isNotEmpty) {
      final source = passes.map((p) => p.shader).join('\n');
      final hash = sha256.convert(utf8.encode(source));
      final dir = _directory ??= await Directory.systemTemp.createTemp('oplayer_frame_pipeline_');
      final file = File('${dir.path}/$hash.glsl');
      if (!await file.exists()) await file.writeAsString(source, flush: true);
      path = file.path;
    }
    verifyOwners();
    await _shader.apply(path);
    try {
      verifyOwners();
    } catch (_) {
      await _shader.apply(_path);
      rethrow;
    }
    final previous = _path;
    _path = path;
    _providers = next;
    programs = List.unmodifiable(passes);
    if (previous != null && previous != path) {
      try {
        await File(previous).delete();
      } catch (_) {
        /* Retried during pipeline disposal. */
      }
    }
  }

  /// Upscaling can replace its own shader entry. Keep postprocessing last.
  Future<void> reapply() => programs.isEmpty ? Future.value() : _queue(() => _shader.reapply());
  Future<void> dispose() async {
    _closed = true;
    store.removeListener(_onProvidersChanged);
    await _tail;
    try {
      await _shader.apply(null);
    } catch (_) {
      // The native player may already be closing. Never prevent its disposal.
    } finally {
      try {
        await _directory?.delete(recursive: true);
      } catch (_) {
        /* Temporary cache may be locked by teardown. */
      }
    }
  }
}
