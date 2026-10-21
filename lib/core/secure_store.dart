import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 비밀번호·OAuth 토큰 저장 (Keychain / Keystore / Windows Credential Locker)
class SecureStore {
  SecureStore._();
  static final instance = SecureStore._();

  final _s = const FlutterSecureStorage();

  Future<String?> readRequired(String key) => _s.read(key: key);

  Future<String?> read(String key) async {
    try {
      return await _s.read(key: key);
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String key, String? value) async {
    try {
      if (value == null) {
        await _s.delete(key: key);
      } else {
        await _s.write(key: key, value: value);
      }
    } catch (_) {}
  }

  Future<void> delete(String key) => write(key, null);

  /// Credentials must not appear saved/deleted when secure storage failed.
  Future<void> writeRequired(String key, String? value) async {
    if (value == null) {
      await _s.delete(key: key);
    } else {
      await _s.write(key: key, value: value);
    }
  }
}
