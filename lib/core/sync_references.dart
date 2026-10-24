import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Device paths and resource IDs stay local; only an explicit shared alias and
/// relative path/file ID leave the device. Never export browser/session URLs.
class SyncReferences {
  static final instance = SyncReferences();
  static const prefix = 'oplayer-sync:';
  final Map<String, String> bindings = {};

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    bindings
      ..clear()
      ..addAll((jsonDecode(prefs.getString('sync_sources_v1') ?? '{}') as Map).cast<String, String>());
  }

  Future<void> bind(String root, String alias) async {
    alias = alias.trim();
    if (alias.isEmpty) {
      bindings.remove(root);
    } else {
      if (bindings.entries.any((e) => e.key != root && e.value == alias)) {
        throw StateError('이 기기에서 이미 사용 중인 동기화 이름입니다');
      }
      bindings[root] = alias;
    }
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString('sync_sources_v1', jsonEncode(bindings))) throw StateError('리소스 연결을 저장하지 못했습니다');
  }

  String? portable(String key) {
    if (key.startsWith(prefix)) return decode(key) == null ? null : key;
    final roots = bindings.keys.toList()..sort((a, b) => b.length.compareTo(a.length));
    for (final root in roots) {
      String? relative;
      if (root.contains('://')) {
        if (key.startsWith('$root/')) relative = key.substring(root.length + 1);
      } else if (!key.contains('://') && p.isWithin(root, key)) {
        relative = p.split(p.relative(key, from: root)).join('/');
      }
      if (relative != null) {
        return '$prefix${base64Url.encode(utf8.encode(jsonEncode([bindings[root], relative]))).replaceAll('=', '')}';
      }
    }
    return null;
  }

  (String, String)? decode(String key) {
    if (!key.startsWith(prefix) || key.length > 16384) return null;
    try {
      final parts = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(key.substring(prefix.length)))));
      if (parts is! List || parts.length != 2 || parts.any((p) => p is! String)) return null;
      if ((parts[0] as String).isEmpty || (parts[1] as String).isEmpty) return null;
      return (parts[0] as String, parts[1] as String);
    } catch (_) {
      return null;
    }
  }

  String? resolve(String key) {
    final parts = decode(key);
    if (parts == null) return null;
    final root = bindings.entries.where((e) => e.value == parts.$1).firstOrNull?.key;
    if (root == null) return null;
    if (root.contains('://')) return '$root/${parts.$2}';
    // A remote document must never escape the folder selected on this device.
    final relative = parts.$2;
    if (relative.contains('\\') || relative.split('/').any((s) => s == '..' || s == '.')) return null;
    final target = p.normalize(p.join(root, relative));
    return p.isWithin(root, target) ? target : null;
  }
}
