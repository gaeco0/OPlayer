import 'package:flutter/foundation.dart';
import 'plugin_store.dart';

/// SemVer comparison accepts legacy one/two-part plugin versions as well.
bool newerPluginVersion(String candidate, String installed) {
  if (candidate.length > 100 || installed.length > 100) return false;
  final pattern = RegExp(r'^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$');
  final a = pattern.firstMatch(candidate), b = pattern.firstMatch(installed);
  if (a == null || b == null) return false;
  for (var i = 1; i <= 3; i++) {
    final av = int.tryParse(a[i] ?? '0'), bv = int.tryParse(b[i] ?? '0');
    if (av == null || bv == null) return false;
    final comparison = av.compareTo(bv);
    if (comparison != 0) return comparison > 0;
  }
  if (a[4] == null || b[4] == null) return a[4] == null && b[4] != null;
  final ap = a[4]!.split('.'), bp = b[4]!.split('.');
  for (var i = 0; i < ap.length && i < bp.length; i++) {
    final an = int.tryParse(ap[i]), bn = int.tryParse(bp[i]);
    final comparison = an != null && bn != null
        ? an.compareTo(bn)
        : an != null
        ? -1
        : bn != null
        ? 1
        : ap[i].compareTo(bp[i]);
    if (comparison != 0) return comparison > 0;
  }
  return ap.length > bp.length;
}

class PluginUpdates extends ChangeNotifier {
  PluginUpdates(this.store, {Future<List<PluginListing>> Function(String)? listings, DateTime Function()? now})
    : _listings = listings ?? store.listings,
      _now = now ?? DateTime.now;
  static final instance = PluginUpdates(PluginStore.instance);
  final PluginStore store;
  final Future<List<PluginListing>> Function(String) _listings;
  final DateTime Function() _now;
  final _repositories = <String, List<PluginListing>>{};
  DateTime? _lastCheck;
  Future<void>? _checking;

  List<PluginListing> get available {
    final found = <String, PluginListing>{};
    for (final repository in store.repositories) {
      for (final entry in _repositories[repository] ?? <PluginListing>[]) {
        final installed = store.installed[entry.id];
        if (installed == null ||
            entry.compatibilityIssue() != null ||
            !newerPluginVersion(entry.version, installed.version)) {
          continue;
        }
        if (found[entry.id] == null || newerPluginVersion(entry.version, found[entry.id]!.version)) {
          found[entry.id] = entry;
        }
      }
    }
    return found.values.toList();
  }

  Future<void> check({bool force = false}) {
    if (_checking != null) return _checking!;
    if (store.installed.isEmpty ||
        !force && _lastCheck != null && _now().difference(_lastCheck!) < const Duration(hours: 1)) {
      return Future.value();
    }
    final job = _check();
    _checking = job;
    return job.whenComplete(() => _checking = null);
  }

  Future<void> _check() async {
    _lastCheck = _now();
    await Future.wait(
      store.repositories.toList().map((repository) async {
        try {
          _repositories[repository] = await _listings(repository);
        } catch (_) {
          /* An offline repository must not interrupt playback or lose a known update. */
        }
      }),
    );
    notifyListeners();
  }
}
