import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Opaque credential references are resolved only on the native side.
Object? resolvePluginValue(Object? value, Map<String, dynamic> credentials) {
  if (value is Map) {
    if (value.containsKey(r'$secret')) {
      final key = value[r'$secret'];
      if (key is! String || !credentials.containsKey(key) || credentials[key] is! String) {
        throw StateError('확장앱 인증 정보가 없습니다');
      }
      return '${value['prefix'] ?? ''}${credentials[key]}${value['suffix'] ?? ''}';
    }
    return {for (final e in value.entries) '${e.key}': resolvePluginValue(e.value, credentials)};
  }
  if (value is List) return value.map((v) => resolvePluginValue(v, credentials)).toList();
  return value;
}

bool usesPluginSecret(Object? value) => value is Map
    ? value.containsKey(r'$secret') || value.values.any(usesPluginSecret)
    : value is List && value.any(usesPluginSecret);

Object pluginCrypto(Map args, Map<String, dynamic> credentials) {
  if (args['data'] is! String || (args['data'] as String).length > 1024 * 1024) throw StateError('암호 연산 입력 제한 초과');
  final hash = switch (args['algorithm']) {
    'sha256' => sha256,
    'sha512' => sha512,
    'sha1' => sha1,
    'md5' => md5,
    _ => throw StateError('지원하지 않는 해시 알고리즘'),
  };
  final data = utf8.encode(args['data'] as String);
  if (args['method'] == 'hash') return hash.convert(data).toString();
  if (args['method'] != 'hmac') throw StateError('지원하지 않는 암호 연산');
  final value = resolvePluginValue(args['key'], credentials) as String;
  if (value.length > 65536 || (args['keyEncoding'] == 'hex' && !RegExp(r'^(?:[0-9a-fA-F]{2})*$').hasMatch(value))) {
    throw StateError('잘못된 HMAC 키 형식');
  }
  final key = args['keyEncoding'] == 'hex'
      ? [for (var i = 0; i < value.length; i += 2) int.parse(value.substring(i, i + 2), radix: 16)]
      : utf8.encode(value);
  return Hmac(hash, key).convert(data).toString();
}
