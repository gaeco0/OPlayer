import 'dart:convert';
import 'resource_locks.dart';
import 'package:flutter/foundation.dart';
import 'sync_references.dart';

import 'package:shared_preferences/shared_preferences.dart';

class ResumeEntry {
  ResumeEntry({
    required this.path,
    required this.position,
    required this.duration,
    required this.updatedAt,
    this.title,
    this.browserMedia = false,
  });

  final String path;
  final Duration position;
  final Duration duration;
  final DateTime updatedAt;
  final String? title;
  final bool browserMedia;

  double get progress =>
      duration.inMilliseconds == 0 ? 0 : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);

  /// 95% 이상 봤으면 시청 완료로 본다.
  bool get finished => progress >= 0.95;

  Map<String, dynamic> toJson() => {
    'p': position.inMilliseconds,
    'd': duration.inMilliseconds,
    'u': updatedAt.millisecondsSinceEpoch,
    if (title != null) 't': title,
    if (browserMedia) 'browser': true,
  };

  static ResumeEntry fromJson(String path, Map<String, dynamic> j) => ResumeEntry(
    path: path,
    position: Duration(milliseconds: j['p'] as int),
    duration: Duration(milliseconds: j['d'] as int),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(j['u'] as int),
    title: j['t'] as String?,
    browserMedia: j['browser'] == true,
  );
}

/// 이어보기 위치 + 최근 재생 기록 + 사용자 추가 폴더 저장소.
class ResumeStore extends ChangeNotifier {
  ResumeStore._();
  static final instance = ResumeStore._();

  static const _kResume = 'resume_v1';
  static const _kFolders = 'folders_v1';
  late SharedPreferences _prefs;
  final Map<String, ResumeEntry> _entries = {};

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final raw = _prefs.getString(_kResume);
    _entries.clear();
    if (raw != null) {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      m.forEach((k, v) => _entries[k] = ResumeEntry.fromJson(k, v as Map<String, dynamic>));
    }
  }

  ResumeEntry? get(String path) {
    final direct = _entries[path] ?? _entries[SyncReferences.instance.resolve(path)];
    final portable = _entries[SyncReferences.instance.portable(path)];
    if (direct == null) return portable;
    return portable != null && portable.updatedAt.isAfter(direct.updatedAt) ? portable : direct;
  }

  Map<String, ResumeEntry> get entries => Map.unmodifiable(_entries);

  Map<String, dynamic> playbackSettings(String path) {
    try {
      final raw = _prefs.getString('playback_settings_$path');
      return raw == null ? {} : (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return {};
    }
  }

  Future<void> savePlaybackSettings(String path, Map<String, dynamic> values) async {
    await _prefs.setString('playback_settings_$path', jsonEncode(values));
  }

  List<ResumeEntry> recent({int limit = 50}) {
    final unique = <String, ResumeEntry>{};
    for (final entry in _entries.values) {
      final key = SyncReferences.instance.portable(entry.path) ?? entry.path;
      if (unique[key] == null || entry.updatedAt.isAfter(unique[key]!.updatedAt)) unique[key] = entry;
    }
    final l = unique.values.toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return l.take(limit).toList();
  }

  Future<void> save(
    String path,
    Duration position,
    Duration duration, {
    String? title,
    bool browserMedia = false,
  }) async {
    if (duration == Duration.zero) return;
    _entries.remove(SyncReferences.instance.portable(path));
    _entries[path] = ResumeEntry(
      path: path,
      position: position,
      duration: duration,
      updatedAt: DateTime.now(),
      title: title ?? _entries[path]?.title,
      browserMedia: browserMedia,
    );
    await _prefs.setString(_kResume, jsonEncode(_entries.map((k, v) => MapEntry(k, v.toJson()))));
    notifyListeners();
  }

  Future<void> remove(String path) async {
    _entries.remove(path);
    _entries.remove(SyncReferences.instance.portable(path));
    final resolved = SyncReferences.instance.resolve(path);
    if (resolved != null) _entries.remove(resolved);
    await _prefs.setString(_kResume, jsonEncode(_entries.map((k, v) => MapEntry(k, v.toJson()))));
    notifyListeners();
  }

  Future<void> toggleWatched(String path, {String? title}) async {
    await ResourceLocks.instance.requireAccess(SyncReferences.instance.resolve(path) ?? path);
    final previous = get(path);
    final duration = previous?.duration ?? const Duration(seconds: 1);
    await save(
      path,
      previous?.finished == true ? Duration.zero : duration,
      duration,
      title: title ?? previous?.title,
      browserMedia: previous?.browserMedia ?? false,
    );
  }

  Future<void> relocate(String oldPath, String newPath, String title) async {
    if (oldPath != newPath) {
      final settings = _prefs.getString('playback_settings_$oldPath');
      if (settings != null) {
        await _prefs.setString('playback_settings_$newPath', settings);
        await _prefs.remove('playback_settings_$oldPath');
      }
    }
    final entry = get(oldPath);
    _entries.remove(oldPath);
    _entries.remove(SyncReferences.instance.portable(oldPath));
    if (entry != null) {
      await save(newPath, entry.position, entry.duration, title: title, browserMedia: entry.browserMedia);
    }
  }

  Future<void> applySynced(Map<String, ResumeEntry?> changes) async {
    for (final entry in changes.entries) {
      _entries.removeWhere((key, _) => key == entry.key || SyncReferences.instance.portable(key) == entry.key);
      if (entry.value != null) _entries[entry.value!.path] = entry.value!;
    }
    if (!await _prefs.setString(_kResume, jsonEncode(_entries.map((k, v) => MapEntry(k, v.toJson()))))) {
      throw StateError('동기화한 재생 기록을 저장하지 못했습니다');
    }
    notifyListeners();
  }

  List<String> get folders => _prefs.getStringList(_kFolders) ?? [];
  Future<void> addFolder(String path) async {
    final f = folders;
    if (!f.contains(path)) await _prefs.setStringList(_kFolders, [...f, path]);
  }

  Future<void> removeFolder(String path) async =>
      _prefs.setStringList(_kFolders, folders.where((e) => e != path).toList());
}
