import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'plugins/sync_storage.dart';
import 'plugins/plugin_store.dart';
import 'plugins/plugin.dart';
import '../sources/cloud/cloud_sources.dart';
import '../sources/server_store.dart';
import 'network/network_service.dart';
import 'playlist_store.dart';
import 'resource_locks.dart';
import 'resume_store.dart';
import 'secure_store.dart';
import 'sync_document.dart';
import 'sync_references.dart';

class PlaybackSync extends ChangeNotifier with WidgetsBindingObserver {
  PlaybackSync({http.Client Function()? clientFactory})
    : _clientFactory = clientFactory ?? (() => IOClient(NetworkService.instance.createHttpClient()));
  static final instance = PlaybackSync();
  final http.Client Function() _clientFactory;
  late SharedPreferences _prefs;
  String? _accountId;
  String? email;
  String? providerId;
  CloudAccount? _account;
  Iterable<OPlugin> get providers => PluginStore.instance.enabled.where((p) => p.supports('sync'));
  String? get providerName => PluginStore.instance.installed[providerId]?.name;
  bool get available => providers.any((p) => p.id == providerId);
  bool get legacyConnection => _prefs.getKeys().any((key) => key.endsWith('_sync_connection'));
  String _device = '';
  SyncDocument? _document;
  Map<String, Map<String, dynamic>> _baseline = {};
  PluginSyncStorage? _api;
  Future<void>? _running;
  Future<void> _writing = Future.value();
  Timer? _timer;
  Timer? _poll;
  bool _initialized = false;
  bool _applying = false;
  bool _foreground = true;
  bool _needsSync = false;
  DateTime? _lastAttempt;
  int _generation = 0;
  bool automatic = false;
  bool busy = false;
  String? error;
  DateTime? lastSync;
  bool get connected => _accountId != null;
  static bool get supported => Platform.isAndroid || Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  String get _connectionKey => 'pluginSyncConnection:$providerId';
  String get _stateKey => 'pluginSyncState:$providerId:$_accountId';
  String get _autoKey => 'pluginSyncAuto:$providerId:$_accountId';
  String get _lastKey => 'pluginSyncLast:$providerId:$_accountId';

  Future<void> selectProvider(String id) async {
    final plugin = PluginStore.instance.require(id);
    if (!plugin.supports('sync')) throw StateError('동기화 확장앱이 아닙니다');
    if (busy) throw StateError('동기화 중에는 제공자를 변경할 수 없습니다');
    if (providerId == id) return;
    if (connected) await disconnect();
    providerId = id;
    _lastAttempt = null;
    lastSync = null;
    _needsSync = false;
    await _prefs.setString('sync_provider', id);
    notifyListeners();
  }

  void _pluginChanged() {
    if (providerId != null && !PluginStore.instance.installed.containsKey(providerId)) {
      _generation++;
      _api?.close();
      _api = null;
      _accountId = null;
      _account = null;
      email = null;
      automatic = false;
    }
    if (!available) {
      _generation++;
      _timer?.cancel();
      _timer = null;
    }
    notifyListeners();
    _schedule();
  }

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    _prefs = await SharedPreferences.getInstance();
    await SyncReferences.instance.init();
    _device = Platform.isAndroid
        ? (await const MethodChannel('oplayer/google-drive').invokeMethod<String>('syncDeviceId'))!
        : _prefs.getString('sync_device') ??
              _prefs.getString('google_sync_device') ??
              base64Url.encode(List.generate(16, (_) => Random.secure().nextInt(256))).replaceAll('=', '');
    await _prefs.setString('sync_device', _device);
    providerId = _prefs.getString('sync_provider');
    final saved = _prefs.getString(_connectionKey);
    if (saved != null) {
      final value = jsonDecode(saved) as Map;
      _accountId = value['id'] as String;
      email = value['email'] as String;
      _account = CloudAccount.fromJson((value['account'] as Map).cast<String, dynamic>());
      _loadState();
      automatic = _prefs.getBool(_autoKey) ?? true;
    }
    PluginStore.instance.addListener(_pluginChanged);
    PlaylistStore.instance.addListener(_changed);
    ResumeStore.instance.addListener(_changed);
    ResourceLocks.instance.addListener(_schedule);
    WidgetsBinding.instance.addObserver(this);
    _poll = Timer.periodic(const Duration(minutes: 1), (_) => _schedule());
    _schedule();
  }

  void _loadState() {
    final saved = jsonDecode(_prefs.getString(_stateKey) ?? '{}') as Map;
    _document = SyncDocument(_device, (saved['document'] as Map?)?.cast<String, dynamic>());
    _baseline = {
      for (final e in ((saved['baseline'] as Map?) ?? {}).entries)
        e.key as String: Map<String, dynamic>.from(e.value as Map),
    };
    final last = _prefs.getInt(_lastKey);
    lastSync = last == null ? null : DateTime.fromMillisecondsSinceEpoch(last);
    _api?.close();
    _api = PluginSyncStorage(_account!, clientFactory: _clientFactory);
  }

  Future<void> connect() async {
    if (busy || connected) return;
    if (providerId == null || !available) throw StateError('설치하고 활성화한 동기화 확장앱을 먼저 선택하세요');
    busy = true;
    error = null;
    notifyListeners();
    CloudAccount? pending;
    PluginSyncStorage? temporary;
    String? legacyPrefix;
    String? legacyAccount;
    try {
      pending = await http.runWithClient(
        () => connectCloudAccount(CloudProvider.plugin, pluginId: providerId, saveAccount: false),
        _clientFactory,
      );
      temporary = PluginSyncStorage(pending!, clientFactory: _clientFactory);
      final who = await temporary.account();
      final legacy = PluginStore.instance.require(providerId!).manifest['legacySyncKey'] as String?;
      if (legacy != null) {
        final raw = _prefs.getString('${legacy}_sync_connection');
        if (raw != null && (jsonDecode(raw) as Map)['id'] == who.id) {
          for (final pair in [('state', 'pluginSyncState'), ('auto', 'pluginSyncAuto'), ('last', 'pluginSyncLast')]) {
            final value = _prefs.get('${legacy}_sync_${pair.$1}_${who.id}');
            final target = '${pair.$2}:$providerId:${who.id}';
            if (value is String) await _prefs.setString(target, value);
            if (value is bool) await _prefs.setBool(target, value);
            if (value is int) await _prefs.setInt(target, value);
          }
          legacyPrefix = legacy;
          legacyAccount = who.id;
        }
      }
      if (!await _prefs.setString(
        _connectionKey,
        jsonEncode({'id': who.id, 'email': who.email, 'account': pending.toJson()}),
      )) {
        throw StateError('동기화 연결을 저장하지 못했습니다');
      }
      _account = pending;
      _accountId = who.id;
      email = who.email;
      automatic = _prefs.getBool(_autoKey) ?? true;
      await _prefs.setBool(_autoKey, automatic);
      _loadState();
      _changed();
      await _writing;
      if (legacyPrefix != null) {
        await SecureStore.instance.writeRequired('${legacyPrefix}_sync_token_$legacyAccount', null);
        await _prefs.remove('${legacyPrefix}_sync_connection');
        for (final field in ['state', 'auto', 'last']) {
          await _prefs.remove('${legacyPrefix}_sync_${field}_$legacyAccount');
        }
      }
    } catch (e) {
      if (pending != null) await SecureStore.instance.writeRequired(pending.tokenKey, null);
      await _api?.close();
      _api = null;
      _account = null;
      _accountId = null;
      email = null;
      automatic = false;
      await _prefs.remove(_connectionKey);
      error = '$e';
      rethrow;
    } finally {
      await temporary?.close();
      busy = false;
      notifyListeners();
    }
    await syncNow();
  }

  Map<String, dynamic> _playlist(SavedPlaylist p) => {
    'id': p.id,
    'name': p.name,
    'tracks': [
      for (final t in p.tracks)
        if (SyncReferences.instance.portable(t.key) case final String key) {'key': key, 'title': t.title},
    ],
  };

  Map<String, Map<String, dynamic>> _snapshot() {
    final values = <String, Map<String, dynamic>>{
      for (final p in PlaylistStore.instance.lists) 'playlist:${p.id}': _playlist(p),
    };
    for (final e in ResumeStore.instance.entries.values) {
      final key = SyncReferences.instance.portable(e.path);
      if (key == null || e.browserMedia) continue;
      final recordKey = 'resume:$key';
      if (values[recordKey] == null || (values[recordKey]!['u'] as int) < e.updatedAt.millisecondsSinceEpoch) {
        values[recordKey] = e.toJson();
      }
    }
    return values;
  }

  bool _capture() {
    final current = _snapshot();
    var changed = false;
    for (final key in {..._baseline.keys, ...current.keys}) {
      if (!SyncDocument.same(_baseline[key], current[key])) {
        _document!.change(key, current[key]);
        changed = true;
      }
    }
    _baseline = current;
    _needsSync |= changed;
    return changed;
  }

  Future<void> _persist() {
    final key = _stateKey;
    final data = jsonEncode({'document': _document!.toJson(), 'baseline': _baseline});
    final result = _writing.then((_) async {
      if (!await _prefs.setString(key, data)) throw StateError('동기화 대기 기록을 저장하지 못했습니다');
    });
    _writing = result.catchError((Object _) {});
    return result;
  }

  void _changed() {
    if (!connected || _applying) return;
    if (_capture()) {
      unawaited(
        _persist().catchError((Object e) {
          error = '$e';
          notifyListeners();
        }),
      );
      _schedule();
    }
  }

  void _schedule() {
    if (!supported ||
        !connected ||
        !available ||
        !automatic ||
        !_foreground ||
        busy ||
        _timer != null ||
        ResourceLocks.instance.shielded ||
        ResourceLocks.instance.isLocked(recentResourceKey)) {
      return;
    }
    final previous = _lastAttempt ?? lastSync;
    final since = previous == null ? const Duration(minutes: 1) : DateTime.now().difference(previous);
    final delay = since < const Duration(minutes: 1) ? const Duration(minutes: 1) - since : const Duration(seconds: 2);
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(syncNow().catchError((Object _) {}));
    });
  }

  Future<void> setAutomatic(bool value) async {
    automatic = value;
    await _prefs.setBool(_autoKey, value);
    _timer?.cancel();
    _timer = null;
    notifyListeners();
    _schedule();
  }

  Future<void> bindReference(String root, String alias) async {
    if (_running != null) await _running!.catchError((Object _) {});
    busy = true;
    _timer?.cancel();
    _timer = null;
    notifyListeners();
    try {
      final refs = SyncReferences.instance;
      // Linking a previously local-only file is an addition, not deletion of the
      // cloud playlist that did not yet contain it. Unlinking never erases history.
      final localTracks = {
        for (final p in PlaylistStore.instance.lists)
          p.id: p.tracks.where((t) => refs.portable(t.key) == null).toList(),
      };
      final localResume = ResumeStore.instance.entries.values.where((e) => refs.portable(e.path) == null).toList();
      _changed();
      await refs.bind(root, alias);
      if (!connected) {
        notifyListeners();
        return;
      }
      for (final p in PlaylistStore.instance.lists) {
        final additions = [
          for (final t in localTracks[p.id] ?? <PlaylistTrack>[])
            if (refs.portable(t.key) case final String key) {'key': key, 'title': t.title},
        ];
        if (additions.isEmpty) continue;
        final value = _document!.values['playlist:${p.id}'] ?? _playlist(p);
        final tracks = List<Map<String, dynamic>>.from(
          (value['tracks'] as List).map((t) => Map<String, dynamic>.from(t as Map)),
        );
        final keys = tracks.map((t) => t['key']).toSet();
        tracks.addAll(additions.where((t) => keys.add(t['key'])));
        _document!.change('playlist:${p.id}', {...value, 'tracks': tracks});
      }
      for (final entry in localResume) {
        final key = refs.portable(entry.path);
        if (key != null && !entry.browserMedia) _document!.change('resume:$key', entry.toJson());
      }
      await _apply();
      _needsSync = true;
      _schedule();
      notifyListeners();
    } finally {
      busy = false;
      _schedule();
      notifyListeners();
    }
  }

  void _validate(Map<String, dynamic> document) {
    final parsed = SyncDocument('validation', document);
    for (final entry in parsed.values.entries) {
      if (entry.key.startsWith('playlist:')) {
        final data = entry.value;
        if (data['id'] != entry.key.substring(9) || data['name'] is! String || data['tracks'] is! List) {
          throw const FormatException('잘못된 동기화 재생목록');
        }
        for (final track in data['tracks'] as List) {
          if (track is! Map ||
              track['key'] is! String ||
              track['title'] is! String ||
              SyncReferences.instance.decode(track['key'] as String) == null) {
            throw const FormatException('잘못된 동기화 파일 참조');
          }
        }
      } else {
        if (SyncReferences.instance.decode(entry.key.substring(7)) == null) throw const FormatException('잘못된 이어보기 참조');
        final value = ResumeEntry.fromJson(entry.key.substring(7), entry.value);
        if (value.position.isNegative || value.duration <= Duration.zero || value.browserMedia) {
          throw const FormatException('잘못된 이어보기 위치');
        }
      }
    }
  }

  Future<void> _apply() async {
    final before = _snapshot();
    final playlists = <String, SavedPlaylist?>{};
    final resumes = <String, ResumeEntry?>{};
    for (final entry in _document!.records.entries) {
      final data = (entry.value['value'] as Map?)?.cast<String, dynamic>();
      if (entry.key.startsWith('playlist:')) {
        final id = entry.key.substring(9);
        playlists[id] = data == null
            ? null
            : SavedPlaylist(id, data['name'] as String, [
                for (final t in data['tracks'] as List)
                  PlaylistTrack(
                    SyncReferences.instance.resolve(t['key'] as String) ?? t['key'] as String,
                    t['title'] as String,
                  ),
              ]);
      } else {
        final key = entry.key.substring(7);
        resumes[key] = data == null ? null : ResumeEntry.fromJson(SyncReferences.instance.resolve(key) ?? key, data);
      }
    }
    _applying = true;
    try {
      await PlaylistStore.instance.applySynced(playlists, (id) {
        final current = PlaylistStore.instance.find(id);
        return SyncDocument.same(current == null ? null : _playlist(current), before['playlist:$id']);
      });
      final current = _snapshot();
      resumes.removeWhere((key, _) => !SyncDocument.same(current['resume:$key'], before['resume:$key']));
      await ResumeStore.instance.applySynced(resumes);
      _baseline = _document!.values;
    } finally {
      _applying = false;
    }
    _capture();
    await _persist();
  }

  Future<void> syncNow() {
    if (_running != null) return _running!;
    if (busy) return Future.value();
    return _running = _sync().whenComplete(() => _running = null);
  }

  Future<void> refreshForPlayback(String key) async {
    if (!connected || !automatic || SyncReferences.instance.portable(key) == null) return;
    try {
      await syncNow().timeout(const Duration(seconds: 5));
    } catch (_) {
      // Offline playback remains available using the last local position.
    }
  }

  Future<void> _sync() async {
    if (!connected || !available || _api == null) throw StateError('동기화 계정을 먼저 연결하세요');
    if (ResourceLocks.instance.shielded || ResourceLocks.instance.isLocked(recentResourceKey)) return;
    final generation = _generation;
    final api = _api!;
    void check() {
      if (generation != _generation || !connected || !available) throw StateError('동기화가 취소되었습니다');
    }

    busy = true;
    _lastAttempt = DateTime.now();
    error = null;
    _timer?.cancel();
    _timer = null;
    notifyListeners();
    try {
      _capture();
      await _persist();
      final who = await api.account();
      check();
      if (who.id != _accountId) throw StateError('동기화 계정이 변경되었습니다. 다시 연결하세요');
      final files = await api.files();
      final remote = <Map<String, dynamic>>[];
      var size = 0;
      for (final file in files) {
        final document = await api.read(file.id);
        check();
        _validate(document);
        size += utf8.encode(jsonEncode(document)).length;
        if (size > 32 * 1024 * 1024) throw StateError('동기화 데이터 합계가 너무 큽니다');
        remote.add(document);
      }
      _capture(); // Preserve edits made while the network request was pending.
      for (final document in remote) {
        _document!.merge(document);
      }
      check();
      await _apply();
      check();
      final snapshot = jsonDecode(jsonEncode(_document!.toJson())) as Map<String, dynamic>;
      _needsSync = false;
      await api.write(_device, snapshot, id: files.where((f) => f.name == api.fileName(_device)).firstOrNull?.id);
      check();
      lastSync = DateTime.now();
      await _prefs.setInt(_lastKey, lastSync!.millisecondsSinceEpoch);
    } catch (e) {
      if (generation == _generation) error = '$e';
      rethrow;
    } finally {
      busy = false;
      notifyListeners();
      if (_needsSync) _schedule();
    }
  }

  Future<void> disconnect() async {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _api?.close();
    _api = null;
    if (_account != null) await SecureStore.instance.writeRequired(_account!.tokenKey, null);
    await _prefs.remove(_connectionKey);
    _account = null;
    _accountId = null;
    email = null;
    automatic = false;
    error = null;
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _schedule();
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    _poll?.cancel();
    _api?.close();
    if (_initialized) {
      PluginStore.instance.removeListener(_pluginChanged);
      PlaylistStore.instance.removeListener(_changed);
      ResumeStore.instance.removeListener(_changed);
      ResourceLocks.instance.removeListener(_schedule);
      WidgetsBinding.instance.removeObserver(this);
    }
    super.dispose();
  }
}
