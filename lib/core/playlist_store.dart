import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PlaylistTrack {
  const PlaylistTrack(this.key, this.title);
  final String key;
  final String title;
  Map<String, dynamic> toJson() => {'key': key, 'title': title};
}

class SavedPlaylist {
  SavedPlaylist(this.id, this.name, Iterable<PlaylistTrack> tracks)
    : tracks = List.unmodifiable({for (final track in tracks) track.key: track}.values);
  final String id;
  final String name;
  final List<PlaylistTrack> tracks;
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'tracks': tracks.map((t) => t.toJson()).toList()};
}

/// Store references, never temporary stream URLs or authentication headers.
class PlaylistStore extends ChangeNotifier {
  static final instance = PlaylistStore();
  SharedPreferences? _prefs;
  Future<void>? _initializing;
  Future<void>? _writing;
  List<SavedPlaylist> _lists = [];
  List<SavedPlaylist> get lists => List.unmodifiable(_lists);
  SavedPlaylist? find(String id) => _lists.where((p) => p.id == id).firstOrNull;

  Future<void> init() async {
    if (_prefs != null) return;
    await (_initializing ??= _init());
  }

  Future<void> _init() async {
    _prefs = await SharedPreferences.getInstance();
    final raw = jsonDecode(_prefs!.getString('playlists_v1') ?? '[]') as List;
    _lists = [
      for (final p in raw)
        SavedPlaylist(p['id'] as String, p['name'] as String, [
          for (final t in p['tracks'] as List) PlaylistTrack(t['key'] as String, t['title'] as String),
        ]),
    ];
  }

  Future<void> _save(List<SavedPlaylist> Function() change) async {
    final previous = _writing;
    final done = Completer<void>();
    _writing = done.future;
    try {
      if (previous != null) await previous;
      await init();
      final lists = change();
      if (!await _prefs!.setString('playlists_v1', jsonEncode(lists.map((p) => p.toJson()).toList()))) {
        throw StateError('재생목록을 저장하지 못했습니다');
      }
      _lists = lists;
      notifyListeners();
    } finally {
      done.complete();
      if (identical(_writing, done.future)) _writing = null;
    }
  }

  Future<String> create(String name, [Iterable<PlaylistTrack> tracks = const []]) async {
    await init();
    name = name.trim();
    if (name.isEmpty) throw const FormatException('재생목록 이름을 입력해 주세요');
    final random = Random.secure();
    final id = base64Url.encode(List.generate(16, (_) => random.nextInt(256))).replaceAll('=', '');
    final keys = <String>{};
    await _save(() => [..._lists, SavedPlaylist(id, name, tracks.where((t) => keys.add(t.key)))]);
    return id;
  }

  Future<void> rename(String id, String name) async {
    await init();
    name = name.trim();
    if (name.isEmpty) throw const FormatException('재생목록 이름을 입력해 주세요');
    await _save(() => [for (final p in _lists) p.id == id ? SavedPlaylist(id, name, p.tracks) : p]);
  }

  Future<void> delete(String id) async {
    await init();
    await _save(() => _lists.where((p) => p.id != id).toList());
  }

  Future<void> add(String id, Iterable<PlaylistTrack> tracks) => _replace(id, (current) {
    final keys = current.map((t) => t.key).toSet();
    return [...current, ...tracks.where((t) => keys.add(t.key))];
  });

  Future<void> remove(String id, Set<String> keys) =>
      _replace(id, (tracks) => tracks.where((t) => !keys.contains(t.key)).toList());

  Future<void> reorder(String id, int oldIndex, int newIndex) => _replace(id, (current) {
    final tracks = current.toList();
    tracks.insert(newIndex, tracks.removeAt(oldIndex));
    return tracks;
  });

  Future<void> _replace(String id, List<PlaylistTrack> Function(List<PlaylistTrack>) change) => _save(() {
    if (find(id) == null) throw StateError('재생목록이 삭제되었습니다');
    return [for (final p in _lists) p.id == id ? SavedPlaylist(id, p.name, change(p.tracks)) : p];
  });

  Future<void> relocate(String oldKey, String newKey, String title) async {
    await init();
    if (!_lists.any((p) => p.tracks.any((t) => t.key == oldKey))) return;
    await _save(
      () => [
        for (final p in _lists)
          SavedPlaylist(p.id, p.name, p.tracks.map((t) => t.key == oldKey ? PlaylistTrack(newKey, title) : t)),
      ],
    );
  }
}
