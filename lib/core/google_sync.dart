import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../sources/cloud/cloud_config.dart';
import '../sources/cloud/oauth.dart';
import 'google_app_data.dart';
import 'network/network_service.dart';
import 'playlist_store.dart';
import 'resource_locks.dart';
import 'resume_store.dart';
import 'secure_store.dart';
import 'sync_document.dart';
import 'sync_references.dart';

class GoogleSync extends ChangeNotifier with WidgetsBindingObserver {
  GoogleSync({http.Client Function()? clientFactory})
    : _clientFactory = clientFactory ?? (() => IOClient(NetworkService.instance.createHttpClient()));
  static final instance = GoogleSync();
  final http.Client Function() _clientFactory;
  late SharedPreferences _prefs;
  String? _accountId;
  String? email;
  String _clientId = '';
  String _device = '';
  SyncDocument? _document;
  Map<String, Map<String, dynamic>> _baseline = {};
  GoogleAppData? _api;
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
  String get clientId =>
      _prefs.getString('sync_google_client_${Platform.operatingSystem}') ??
      (Platform.isAndroid ? CloudConfig.googleAndroidClientId : CloudConfig.googleDesktopClientId);
  String get _tokenKey => 'google_sync_token_$_accountId';
  String get _stateKey => 'google_sync_state_$_accountId';

  OAuthClient _oauth(String id, {String? email}) => Platform.isAndroid
      ? GoogleAndroidOAuthClient(clientId: id, accountEmail: email, requestedScopes: const [googleSyncScope])
      : OAuthClient(
          authEndpoint: 'https://accounts.google.com/o/oauth2/v2/auth',
          tokenEndpoint: 'https://oauth2.googleapis.com/token',
          clientId: id,
          clientSecretKey: CloudConfig.googleSecretKey(id),
          scopes: const [googleSyncScope],
          mobileScheme: CloudConfig.mobileScheme,
          extraAuthParams: const {'access_type': 'offline', 'prompt': 'consent'},
        );

  Future<void> configure(String id, String secret) async {
    if (connected || busy) throw StateError('계정 연결을 해제한 뒤 등록 정보를 변경하세요');
    id = id.trim();
    if ((!Platform.isAndroid || id.isNotEmpty) && !id.endsWith('.apps.googleusercontent.com')) {
      throw const FormatException('Google OAuth Client ID를 입력하세요');
    }
    if (!Platform.isAndroid) await SecureStore.instance.writeRequired(CloudConfig.googleSecretKey(id), secret.trim());
    await _prefs.setString('sync_google_client_${Platform.operatingSystem}', id);
    notifyListeners();
  }

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    _prefs = await SharedPreferences.getInstance();
    await SyncReferences.instance.init();
    _device = Platform.isAndroid
        ? (await GoogleAndroidOAuthClient.channel.invokeMethod<String>('syncDeviceId'))!
        : _prefs.getString('google_sync_device') ??
              base64Url.encode(List.generate(16, (_) => Random.secure().nextInt(256))).replaceAll('=', '');
    await _prefs.setString('google_sync_device', _device);
    final saved = _prefs.getString('google_sync_connection');
    if (saved != null) {
      final value = jsonDecode(saved) as Map;
      _accountId = value['id'] as String;
      email = value['email'] as String;
      _clientId = value['clientId'] as String;
      _loadState();
      automatic = _prefs.getBool('google_sync_auto_$_accountId') ?? true;
    }
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
    final last = _prefs.getInt('google_sync_last_$_accountId');
    lastSync = last == null ? null : DateTime.fromMillisecondsSinceEpoch(last);
    _api?.close();
    _api = GoogleAppData(TokenHolder(_tokenKey, _oauth(_clientId, email: email)), _clientFactory());
  }

  Future<void> connect() async {
    if (busy || connected) return;
    if (!supported) throw UnsupportedError('Google 동기화는 현재 Android와 데스크톱에서 지원합니다');
    final id = clientId;
    if (!Platform.isAndroid && id.isEmpty) throw StateError('Google OAuth 앱 등록 정보를 먼저 입력하세요');
    busy = true;
    error = null;
    notifyListeners();
    final temporaryKey = 'google_sync_pending_$_device';
    GoogleAppData? temporary;
    try {
      final tokens = await _oauth(id).authorize();
      final holder = TokenHolder(temporaryKey, _oauth(id));
      await holder.save(tokens);
      temporary = GoogleAppData(holder, _clientFactory());
      final who = await temporary.account();
      await SecureStore.instance.writeRequired('google_sync_token_${who.id}', jsonEncode(tokens.toJson()));
      await _prefs.setString('google_sync_connection', jsonEncode({'id': who.id, 'email': who.email, 'clientId': id}));
      _accountId = who.id;
      email = who.email;
      _clientId = id;
      automatic = true;
      await _prefs.setBool('google_sync_auto_$_accountId', true);
      _loadState();
      _changed();
    } catch (e) {
      error = '$e';
      rethrow;
    } finally {
      temporary?.close();
      try {
        await SecureStore.instance.writeRequired(temporaryKey, null);
      } finally {
        busy = false;
        notifyListeners();
      }
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
    await _prefs.setBool('google_sync_auto_$_accountId', value);
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
    if (!connected || _api == null) throw StateError('Google 계정을 먼저 연결하세요');
    if (ResourceLocks.instance.shielded || ResourceLocks.instance.isLocked(recentResourceKey)) return;
    final generation = _generation;
    final api = _api!;
    void check() {
      if (generation != _generation || !connected) throw StateError('동기화가 취소되었습니다');
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
      if (who.id != _accountId) throw StateError('Google 계정이 변경되었습니다. 다시 연결하세요');
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
      await _prefs.setInt('google_sync_last_$_accountId', lastSync!.millisecondsSinceEpoch);
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
    await SecureStore.instance.writeRequired(_tokenKey, null);
    await _prefs.remove('google_sync_connection');
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
      PlaylistStore.instance.removeListener(_changed);
      ResumeStore.instance.removeListener(_changed);
      ResourceLocks.instance.removeListener(_schedule);
      WidgetsBinding.instance.removeObserver(this);
    }
    super.dispose();
  }
}
