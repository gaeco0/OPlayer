import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'media_item.dart';
import 'resource_locks.dart';

/// Local-only browsing context. Cloud folders can be opaque IDs, not paths.
class ResourcePlaybackStore extends ChangeNotifier {
  static final instance = ResourcePlaybackStore();
  static const _key = 'resource_playback_v1';
  final _locations = <String, PlaybackLocation>{};
  final _latest = <String, PlaybackLocation>{};
  SharedPreferences? _prefs;

  static String localResource(String root) {
    final normalized = p.normalize(p.absolute(root));
    return 'local:${Platform.isWindows ? normalized.toLowerCase() : normalized}';
  }

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _locations.clear();
    _latest.clear();
    try {
      final data = jsonDecode(_prefs!.getString(_key) ?? '{}') as Map;
      for (final entry in (data['locations'] as Map? ?? {}).entries) {
        _locations[entry.key as String] = _decode(entry.value as Map);
      }
      for (final entry in (data['latest'] as Map? ?? {}).entries) {
        _latest[entry.key as String] = _decode(entry.value as Map);
      }
    } catch (_) {
      _locations.clear();
      _latest.clear();
    }
  }

  Future<void> record(MediaItem item) async {
    if (_prefs == null) await init();
    final location = item.playbackLocation ?? _locations[item.key];
    if (location == null) return;
    _locations[item.key] = location;
    _latest[location.resource] = location;
    notifyListeners();
    await _save();
  }

  bool highlighted(String resource, String key, {bool folder = false}) {
    final location = _latest[resource];
    if (location == null || ResourceLocks.instance.isLocked(location.file)) return false;
    return folder ? location.folders.contains(key) : location.file == key;
  }

  Future<void> relocate(String oldKey, String newKey) async {
    if (_prefs == null) await init();
    final location = _locations.remove(oldKey);
    if (location == null) return;
    _locations[newKey] = PlaybackLocation(resource: location.resource, file: newKey, folders: location.folders);
    _latest.updateAll(
      (_, value) => value.file == oldKey
          ? PlaybackLocation(resource: value.resource, file: newKey, folders: value.folders)
          : value,
    );
    notifyListeners();
    await _save();
  }

  Future<void> forget(String key, {bool directory = false}) async {
    if (_prefs == null) await init();
    if (!_locations.values.any((value) => value.file == key || directory && value.folders.contains(key)) &&
        !_latest.values.any((value) => value.file == key || directory && value.folders.contains(key))) {
      return;
    }
    _locations.removeWhere((_, value) => value.file == key || directory && value.folders.contains(key));
    _latest.removeWhere((_, value) => value.file == key || directory && value.folders.contains(key));
    notifyListeners();
    await _save();
  }

  static PlaybackLocation _decode(Map value) => PlaybackLocation(
    resource: value['resource'] as String,
    file: value['file'] as String,
    folders: List<String>.from(value['folders'] as List),
  );
  static Map<String, dynamic> _encode(PlaybackLocation value) => {
    'resource': value.resource,
    'file': value.file,
    'folders': value.folders,
  };

  Future<void> _save() async {
    await _prefs!.setString(
      _key,
      jsonEncode({
        'latest': _latest.map((key, value) => MapEntry(key, _encode(value))),
        'locations': _locations.map((key, value) => MapEntry(key, _encode(value))),
      }),
    );
  }
}
