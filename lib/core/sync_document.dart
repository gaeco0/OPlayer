import 'dart:math';

/// Per-entity last-writer merge. Tombstones prevent deleted items from returning
/// when an offline device reconnects. Each device writes its own Drive file.
class SyncDocument {
  SyncDocument(this.device, [Map<String, dynamic>? saved]) {
    if (saved != null) merge(saved);
  }
  final String device;
  int _clock = 0;
  final records = <String, Map<String, dynamic>>{};

  void change(String key, Map<String, dynamic>? value) {
    _clock = max(_clock + 1, DateTime.now().toUtc().microsecondsSinceEpoch);
    records[key] = {'time': _clock, 'device': device, 'value': value};
  }

  void merge(Map<String, dynamic> document) {
    if (document['version'] != 1 || document['records'] is! Map) throw const FormatException('지원하지 않는 동기화 형식');
    final incoming = (document['records'] as Map).cast<String, dynamic>();
    if (incoming.length > 20000) throw const FormatException('동기화 항목이 너무 많습니다');
    // Validate completely before changing local state.
    for (final entry in incoming.entries) {
      final value = entry.value;
      if ((!entry.key.startsWith('playlist:') && !entry.key.startsWith('resume:')) ||
          value is! Map ||
          value['time'] is! int ||
          (value['time'] as int) < 0 ||
          (value['time'] as int) >= 9007199254740991 ||
          value['device'] is! String ||
          (value['device'] as String).isEmpty ||
          (value['device'] as String).length > 128 ||
          (value['value'] != null && value['value'] is! Map)) {
        throw const FormatException('잘못된 동기화 항목');
      }
    }
    for (final entry in incoming.entries) {
      final next = Map<String, dynamic>.from(entry.value as Map);
      final previous = records[entry.key];
      final time = next['time'] as int;
      _clock = max(_clock, time);
      if (previous == null ||
          time > (previous['time'] as int) ||
          time == previous['time'] && (next['device'] as String).compareTo(previous['device'] as String) > 0) {
        records[entry.key] = next;
      }
    }
  }

  Map<String, dynamic> toJson() => {'version': 1, 'records': records};
  Map<String, Map<String, dynamic>> get values => {
    for (final entry in records.entries)
      if (entry.value['value'] != null) entry.key: Map<String, dynamic>.from(entry.value['value'] as Map),
  };
  static bool same(Object? a, Object? b) {
    if (a is Map && b is Map) {
      return a.length == b.length && a.keys.every((key) => b.containsKey(key) && same(a[key], b[key]));
    }
    if (a is List && b is List) {
      return a.length == b.length && List.generate(a.length, (i) => i).every((i) => same(a[i], b[i]));
    }
    return a == b;
  }
}
