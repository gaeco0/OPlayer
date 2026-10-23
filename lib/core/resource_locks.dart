import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart';

import '../sources/server_store.dart';
import 'secure_store.dart';
import 'settings.dart';

const privacyChannel = MethodChannel('oplayer/privacy');
const recentResourceKey = 'oplayer://recent';
const downloadsResourceKey = 'oplayer://downloads';

String resourceKey(String value) {
  final uri = Uri.tryParse(value);
  if (uri?.scheme == 'file') value = uri!.toFilePath();
  if (!value.contains('://')) {
    try {
      value = File(value).resolveSymbolicLinksSync();
    } catch (_) {
      // Missing descendants must share their existing ancestor's canonical key,
      // including through Windows short paths and directory aliases.
      var ancestor = p.absolute(value);
      final suffix = <String>[];
      while (true) {
        final parent = p.dirname(ancestor);
        if (parent == ancestor) break;
        suffix.add(p.basename(ancestor));
        ancestor = parent;
        try {
          value = p.joinAll([Directory(ancestor).resolveSymbolicLinksSync(), ...suffix.reversed]);
          break;
        } catch (_) {}
      }
    }
    var path = p.normalize(p.absolute(value)).replaceAll('\\', '/');
    if (Platform.isWindows) path = path.toLowerCase();
    return path.length > 1 ? path.replaceFirst(RegExp(r'/+$'), '') : path;
  }
  final u = Uri.parse(value);
  final path = p.posix.normalize(Uri.decodeComponent(u.path));
  final suffix = path == '.' || path == '/' ? '' : path.replaceFirst(RegExp(r'/+$'), '');
  return '${u.scheme.toLowerCase()}://${u.authority.toLowerCase()}$suffix';
}

String serverResourceKey(ServerConfig c) => '${c.type.name}://${c.id}';

String _pinHash(List<Object> input) {
  final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(base64Decode(input[1] as String), 210000, 32));
  return base64Encode(derivator.process(Uint8List.fromList(utf8.encode(input[0] as String))));
}

Future<String> _deriveHash(String value, String salt) async {
  if (Platform.isAndroid || Platform.isWindows) {
    try {
      final bytes = await privacyChannel.invokeMethod<Uint8List>('deriveLockHash', {
        'value': value,
        'salt': base64Decode(salt),
      });
      if (bytes != null) {
        if (bytes.length != 32) throw const FormatException('Invalid credential hash');
        return base64Encode(bytes);
      }
    } on MissingPluginException {
      // Older native runners use the same algorithm in a worker isolate.
    }
  }
  return compute(_pinHash, <Object>[value, salt]);
}

class ResourceLockedException implements Exception {
  const ResourceLockedException();
  @override
  String toString() => '잠긴 리소스입니다. 등록한 PIN·패턴 또는 생체인증으로 잠금을 해제해 주세요.';
}

/// App access control; files themselves are not encrypted or moved.
class ResourceLocks extends ChangeNotifier {
  static final instance = ResourceLocks();
  static const storageKey = 'resource_locks_v1';
  Map<String, String> _resources = {};
  String? _salt;
  String? _hash;
  String? _patternSalt;
  String? _patternHash;
  bool biometricEnabled = false;
  bool _appLockEnabled = false;
  bool _changingAppLock = false;
  bool unavailable = false;
  bool _authorized = false;
  final _unlockedResources = <String>{};
  int _generation = 0;
  int _playbackGeneration = 0;
  bool _verifying = false;
  bool shielded = false;
  bool _background = false;
  int _attempts = 0;
  DateTime? _retryAt;
  Future<bool>? _authentication;
  String? authenticatingResource;
  Future<bool> Function(bool forceCredential)? onAuthenticate;

  bool get configured => hasPin || hasPattern;
  bool get hasPin => _hash != null;
  bool get hasPattern => _patternHash != null;
  static bool get supportsSystemAuthentication => Platform.isAndroid || Platform.isWindows;
  bool get appLockEnabled => _appLockEnabled;
  bool get inBackground => _background;
  bool get forcesCaptureProtection => _appLockEnabled || _changingAppLock || shielded || unavailable;
  Map<String, String> get resources => Map.unmodifiable(_resources);
  int get retrySeconds =>
      _retryAt == null ? 0 : max(0, (_retryAt!.difference(DateTime.now()).inMilliseconds / 1000).ceil());

  Future<void> init() async {
    _playbackGeneration++;
    try {
      final raw = await SecureStore.instance.readRequired(storageKey);
      if (raw != null) {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        _salt = data['salt'] as String?;
        _hash = data['hash'] as String?;
        if ((_salt == null) != (_hash == null) ||
            (_hash != null && (base64Decode(_salt!).length != 32 || base64Decode(_hash!).length != 32))) {
          throw const FormatException();
        }
        _patternSalt = data['patternSalt'] as String?;
        _patternHash = data['patternHash'] as String?;
        if ((_patternSalt == null) != (_patternHash == null) ||
            (_patternHash != null &&
                (base64Decode(_patternSalt!).length != 32 || base64Decode(_patternHash!).length != 32))) {
          throw const FormatException();
        }
        if (!configured) throw const FormatException();
        _resources = (data['resources'] as Map).cast<String, String>();
        biometricEnabled = data['biometric'] == true;
        _appLockEnabled = data['appLock'] == true;
        _attempts = (data['attempts'] as int?) ?? 0;
        _retryAt = DateTime.tryParse(data['retryAt'] as String? ?? '');
      } else {
        _salt = _hash = null;
        _patternSalt = _patternHash = null;
        _resources = {};
        biometricEnabled = false;
        _appLockEnabled = false;
        _attempts = 0;
        _retryAt = null;
      }
      unavailable = false;
    } catch (_) {
      unavailable = true; // Never silently turn unreadable protection into an empty lock list.
    }
    _authorized = false;
    _unlockedResources.clear();
    _generation++;
    shielded = unavailable || _appLockEnabled;
    notifyListeners();
  }

  Iterable<String> _aliases(String value) sync* {
    yield resourceKey(value);
    final uri = Uri.tryParse(value);
    if (uri == null || !value.contains('://')) return;
    final servers = ServerStore.instance.servers;
    final owned = servers.where((c) => c.id == uri.host && c.type.name == uri.scheme).firstOrNull;
    for (final c in servers) {
      final sameServer =
          owned != null &&
          c.type == owned.type &&
          c.host.toLowerCase() == owned.host.toLowerCase() &&
          c.effectivePort == owned.effectivePort;
      final direct =
          owned == null &&
          c.host.toLowerCase() == uri.host.toLowerCase() &&
          c.effectivePort == uri.port &&
          ((c.type == ServerType.webdav && ['http', 'https'].contains(uri.scheme)) ||
              (c.type == ServerType.ftp && ['ftp', 'ftps'].contains(uri.scheme)));
      if (sameServer || direct) yield resourceKey('${serverResourceKey(c)}${uri.path}');
    }
  }

  bool protects(String value) =>
      unavailable ||
      _aliases(value).any(
        (key) => _resources.keys.any((root) => key == root || key.startsWith(root.endsWith('/') ? root : '$root/')),
      );
  String? _resourceScope(String value) {
    String? scope;
    int depth(String root) => root.contains('://') ? Uri.parse(root).path.length : root.length;
    for (final key in _aliases(value)) {
      for (final root in _resources.keys) {
        if ((key == root || key.startsWith(root.endsWith('/') ? root : '$root/')) &&
            (scope == null || depth(root) > depth(scope))) {
          scope = root;
        }
      }
    }
    return scope;
  }

  bool isLocked(String value) {
    final scope = _resourceScope(value);
    return unavailable || (_appLockEnabled && !_authorized) || (scope != null && !_unlockedResources.contains(scope));
  }

  /// A permit keeps an already authorized player alive without unlocking browsing.
  int? authorizePlayback(Iterable<String> resources) =>
      resources.every((value) => !isLocked(value)) ? _playbackGeneration : null;

  bool canContinuePlayback(int? permit) => !unavailable && permit != null && permit == _playbackGeneration;

  bool hasExact(String value) => _resources.containsKey(resourceKey(value));

  Future<bool> authenticate({bool forceCredential = false, String? resource}) async {
    final generation = _generation;
    // Serialize prompts; a result for resource A never authorizes resource B.
    while (_authentication != null) {
      await _authentication;
      if (generation != _generation) return false;
    }
    if (unavailable || !configured || _background) return false;
    final scope = resource == null ? null : _resourceScope(resource);
    if (!forceCredential && (resource == null ? _authorized : scope == null || _unlockedResources.contains(scope))) {
      return true;
    }
    final completed = Completer<bool>();
    _authentication = completed.future;
    authenticatingResource = scope;
    try {
      final verified = await onAuthenticate?.call(forceCredential) ?? false;
      if (!verified || !_authorized || _background || generation != _generation) return false;
      if (scope != null && _resourceScope(resource!) == scope) {
        _unlockedResources.add(scope);
        notifyListeners();
      }
      return true;
    } finally {
      _authentication = null;
      authenticatingResource = null;
      completed.complete(true);
    }
  }

  Future<void> requireAccess(String value) async {
    if (_appLockEnabled && !_authorized && !await authenticate()) throw const ResourceLockedException();
    if (isLocked(value)) await authenticate(resource: value);
    if (isLocked(value)) throw const ResourceLockedException();
  }

  Future<bool> verifyPin(String pin) async {
    return _verifyCredential(pin, _salt, _hash);
  }

  static bool validPattern(List<int> pattern) =>
      pattern.length >= 4 &&
      pattern.length <= 9 &&
      pattern.toSet().length == pattern.length &&
      pattern.every((value) => value >= 0 && value < 9);

  Future<bool> verifyPattern(List<int> pattern) async {
    if (!validPattern(pattern) || !hasPattern) return false;
    return _verifyCredential('pattern:${pattern.join(',')}', _patternSalt, _patternHash);
  }

  Future<bool> _verifyCredential(String value, String? salt, String? hash) async {
    if (_verifying || !configured || unavailable || _background || (_retryAt?.isAfter(DateTime.now()) ?? false)) {
      return false;
    }
    if (salt == null || hash == null) return false;
    _verifying = true;
    final generation = _generation;
    try {
      final expected = base64Decode(hash);
      final actual = base64Decode(await _deriveHash(value, salt));
      if (generation != _generation || _background) return false;
      var difference = 0;
      for (var i = 0; i < expected.length; i++) {
        difference |= expected[i] ^ actual[i];
      }
      if (difference != 0) {
        _attempts++;
        if (_attempts >= 5) _retryAt = DateTime.now().add(const Duration(seconds: 30));
        await _save();
        return false;
      }
      if (_attempts != 0 || _retryAt != null) {
        _attempts = 0;
        _retryAt = null;
        await _save();
      }
      if (generation != _generation || _background) return false;
      _unlock();
      return true;
    } finally {
      _verifying = false;
    }
  }

  Future<bool> biometric() async {
    if (!supportsSystemAuthentication || !configured || !biometricEnabled || unavailable || _background) return false;
    final generation = _generation;
    final success =
        await privacyChannel
            .invokeMethod<bool>('authenticate')
            .timeout(
              const Duration(seconds: 45),
              onTimeout: () async {
                await privacyChannel.invokeMethod('cancelAuthentication');
                return false;
              },
            ) ??
        false;
    if (success && !_background && generation == _generation) _unlock();
    return success && !_background && generation == _generation;
  }

  void _unlock() {
    if (_background) return;
    _authorized = true;
    shielded = false;
    notifyListeners();
  }

  Future<void> setPin(String pin) async {
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) throw const FormatException('PIN은 숫자 6자리로 입력해 주세요');
    if (unavailable || (configured && !await authenticate(forceCredential: true))) {
      throw const ResourceLockedException();
    }
    final oldSalt = _salt, oldHash = _hash;
    final salt = base64Encode(List.generate(32, (_) => Random.secure().nextInt(256)));
    final hash = await _deriveHash(pin, salt);
    _salt = salt;
    _hash = hash;
    try {
      await _save();
    } catch (_) {
      _salt = oldSalt;
      _hash = oldHash;
      rethrow;
    }
    _generation++;
    _playbackGeneration++;
    _unlockedResources.clear();
    _unlock();
  }

  Future<void> setBiometric(bool enabled) async {
    if (!await authenticate(forceCredential: true)) throw const ResourceLockedException();
    if (enabled && !(await privacyChannel.invokeMethod<bool>('biometricAvailable') ?? false)) {
      throw FormatException(
        Platform.isWindows ? 'Windows 설정 → 계정 → 로그인 옵션에서 Windows Hello를 먼저 등록해 주세요' : '휴대폰 설정에서 지문 또는 생체정보를 먼저 등록해 주세요',
      );
    }
    final old = biometricEnabled;
    biometricEnabled = enabled;
    try {
      await _save();
    } catch (_) {
      biometricEnabled = old;
      rethrow;
    }
    notifyListeners();
  }

  Future<void> setPattern(List<int>? pattern) async {
    if (pattern != null && !validPattern(pattern)) throw const FormatException('서로 다른 점을 4개 이상 연결해 주세요');
    if (pattern == null && !hasPin) _checkRemoveLastCredential();
    if (unavailable || (configured && !await authenticate(forceCredential: true))) {
      throw const ResourceLockedException();
    }
    final oldSalt = _patternSalt, oldHash = _patternHash;
    final oldBiometric = biometricEnabled;
    if (pattern == null) {
      _patternSalt = _patternHash = null;
    } else {
      final random = Random.secure();
      final salt = base64Encode(List.generate(32, (_) => random.nextInt(256)));
      final hash = await _deriveHash('pattern:${pattern.join(',')}', salt);
      _patternSalt = salt;
      _patternHash = hash;
    }
    if (!configured) biometricEnabled = false;
    try {
      await _save();
    } catch (_) {
      _patternSalt = oldSalt;
      _patternHash = oldHash;
      biometricEnabled = oldBiometric;
      rethrow;
    }
    _generation++;
    _playbackGeneration++;
    _unlockedResources.clear();
    _unlock();
  }

  void _checkRemoveLastCredential() {
    if (_appLockEnabled || _resources.isNotEmpty) {
      throw const FormatException('마지막 잠금 정보를 삭제하려면 앱 잠금과 리소스 잠금을 먼저 해제해 주세요');
    }
  }

  Future<void> removePin() async {
    if (!hasPin) return;
    if (!hasPattern) _checkRemoveLastCredential();
    if (!await authenticate(forceCredential: true)) throw const ResourceLockedException();
    final salt = _salt, hash = _hash;
    final oldBiometric = biometricEnabled;
    _salt = _hash = null;
    if (!configured) biometricEnabled = false;
    try {
      await _save();
    } catch (_) {
      _salt = salt;
      _hash = hash;
      biometricEnabled = oldBiometric;
      rethrow;
    }
    _generation++;
    _playbackGeneration++;
    _unlockedResources.clear();
    notifyListeners();
  }

  Future<void> setCaptureProtection(bool enabled) async {
    await privacyChannel.invokeMethod('setCaptureProtection', enabled);
    AppSettings.instance.update((settings) => settings.preventCapture = enabled);
    notifyListeners();
  }

  /// Apply the persisted app policy before the first Flutter frame.
  Future<void> syncNativePrivacy() async {
    if (!supportsSystemAuthentication) return;
    await privacyChannel.invokeMethod('setLockPolicy', {
      'appLock': _appLockEnabled || unavailable || _changingAppLock,
      'shielded': shielded || unavailable,
      'preventCapture': AppSettings.instance.preventCapture,
    });
  }

  Future<void> setAppLockEnabled(bool enabled) async {
    if (_changingAppLock) return;
    if (!await authenticate(forceCredential: true)) throw const ResourceLockedException();
    final old = _appLockEnabled;
    _changingAppLock = true;
    try {
      // Protect the window throughout either storage transaction.
      await syncNativePrivacy();
      _appLockEnabled = enabled;
      await _save();
      _changingAppLock = false;
      await syncNativePrivacy();
    } catch (_) {
      _appLockEnabled = old;
      // Retain the previous policy if either storage cannot commit the change.
      try {
        await _save();
      } catch (_) {
        unavailable = true;
        shielded = true;
      }
      _changingAppLock = false;
      try {
        await syncNativePrivacy();
      } catch (_) {
        unavailable = true;
        shielded = true;
      }
      rethrow;
    } finally {
      _changingAppLock = false;
      if (_background && _appLockEnabled) shielded = true;
      notifyListeners();
    }
  }

  Future<void> toggle(String value, String title) async {
    if (!await authenticate(forceCredential: true)) throw const ResourceLockedException();
    final key = resourceKey(value);
    final next = Map<String, String>.of(_resources);
    if (next.containsKey(key)) {
      next.remove(key);
    } else {
      next[key] = title;
    }
    final old = _resources;
    _resources = next;
    try {
      await _save();
    } catch (_) {
      _resources = old;
      rethrow;
    }
    _unlockedResources.remove(key);
    _playbackGeneration++;
    notifyListeners();
  }

  void relock() {
    _playbackGeneration++;
    _lockInterface();
  }

  /// Protect the destination before moving a locked file, including across crashes.
  Future<void> renameFile(String from, String to, Future<void> Function() operation) async {
    await requireAccess(from);
    await requireAccess(to);
    final oldKey = resourceKey(from);
    final newKey = resourceKey(to);
    if (oldKey == newKey || !_resources.containsKey(oldKey)) return operation();
    final previous = Map<String, String>.of(_resources);
    _resources[newKey] = _resources[oldKey]!;
    try {
      await _save();
      await operation();
    } catch (_) {
      _resources = previous;
      await _save();
      rethrow;
    }
    _resources.remove(oldKey);
    _unlockedResources.remove(oldKey);
    _unlockedResources.remove(newKey);
    await _save();
    _playbackGeneration++;
    notifyListeners();
  }

  void _lockInterface() {
    _authorized = false;
    _unlockedResources.clear();
    _generation++;
    shielded = _appLockEnabled || unavailable;
    notifyListeners();
  }

  void background(bool value) {
    _background = value;
    if (value) _lockInterface();
  }

  Future<void> _save() => !configured
      ? SecureStore.instance.writeRequired(storageKey, null)
      : SecureStore.instance.writeRequired(
          storageKey,
          jsonEncode({
            'salt': _salt,
            'hash': _hash,
            'patternSalt': _patternSalt,
            'patternHash': _patternHash,
            'resources': _resources,
            'biometric': biometricEnabled,
            'appLock': _appLockEnabled,
            'attempts': _attempts,
            'retryAt': _retryAt?.toIso8601String(),
          }),
        );
}
