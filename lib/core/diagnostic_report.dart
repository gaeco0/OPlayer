import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';

import '../features/player/player_orientation.dart';
import 'settings.dart';
import 'playlist_store.dart';
import 'resource_locks.dart';
import 'sync_references.dart';
import '../sources/server_store.dart';

class DiagnosticReport {
  static Future<String> collect({Map<String, dynamic>? orientation}) async {
    final data = <String, dynamic>{
      'os': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'architecture': Abi.current().toString(),
      'buildChannel': const String.fromEnvironment('OPLAYER_UPDATE_CHANNEL', defaultValue: 'nightly'),
    };
    try {
      final manifest = await rootBundle.loadString('pubspec.yaml').timeout(const Duration(seconds: 3));
      data['appVersion'] = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(manifest)?.group(1);
    } catch (_) {
      data['appVersion'] = 'unavailable';
    }
    final settings = AppSettings.instance;
    data['network'] = {
      'doh': settings.dohEnabled,
      'byeDpi': settings.byeDpiEnabled,
      'resources': settings.networkForResources,
    };
    data['selectedOrientation'] = settings.playbackOrientation.name;
    data['playlistSync'] = playlistSync();
    try {
      final values = orientation ?? await PlayerOrientation.diagnostics().timeout(const Duration(seconds: 3));
      // Explicit allowlist: never export arbitrary native fields, settings,
      // playback URLs, paths, headers, accounts, or credentials.
      const fields = {
        'manufacturer',
        'model',
        'android',
        'sdk',
        'targetSdk',
        'requestedOrientation',
        'configurationOrientation',
        'screenWidthDp',
        'screenHeightDp',
        'smallestScreenWidthDp',
        'multiWindow',
        'pip',
        'displayRotation',
        'windowWidthPx',
        'windowHeightPx',
      };
      const properties = {
        'PROPERTY_COMPAT_ALLOW_ORIENTATION_OVERRIDE',
        'PROPERTY_COMPAT_ALLOW_DISPLAY_ORIENTATION_OVERRIDE',
        'PROPERTY_COMPAT_ALLOW_IGNORING_ORIENTATION_REQUEST_WHEN_LOOP_DETECTED',
        'PROPERTY_COMPAT_IGNORE_REQUESTED_ORIENTATION',
        'PROPERTY_COMPAT_ALLOW_RESTRICTED_RESIZABILITY',
      };
      data['screen'] = {
        for (final entry in values.entries)
          if ((fields.contains(entry.key) ||
                  ['application', 'activity'].any((scope) => properties.any((p) => entry.key == '$scope.$p'))) &&
              (entry.value == null || entry.value is num || entry.value is bool || entry.value is String))
            entry.key: entry.value,
      };
    } catch (_) {
      data['screen'] = 'unavailable';
    }
    return const JsonEncoder.withIndent('  ').convert(data);
  }

  static Map<String, dynamic> playlistSync() {
    final locks = ResourceLocks.instance;
    if (locks.shielded || locks.isLocked(playlistsResourceKey)) return {'locked': true};
    final refs = SyncReferences.instance;
    String fingerprint(String value) => sha256.convert(utf8.encode(value)).toString().substring(0, 16);
    final registered = {
      for (final s in ServerStore.instance.servers) '${s.type.name}://${s.id}',
      for (final a in ServerStore.instance.accounts) '${a.provider.name}://${a.id}',
    };
    final lists = PlaylistStore.instance.lists;
    return {
      'bindings': [
        for (final entry in refs.bindings.entries)
          {'resource': fingerprint(entry.key), 'alias': fingerprint(entry.value)},
      ],
      'playlists': [
        for (var i = 0; i < lists.length; i++)
          if (locks.isLocked(playlistResourceKey(lists[i].id)))
            {'index': i + 1, 'locked': true}
          else
            (() {
              final excluded = <String, int>{};
              var portable = 0;
              for (final track in lists[i].tracks) {
                if (refs.portable(track.key) != null) {
                  portable++;
                  continue;
                }
                final separator = track.key.indexOf('://');
                final slash = separator < 0 ? -1 : track.key.indexOf('/', separator + 3);
                final root = separator < 0
                    ? 'local'
                    : slash < 0
                    ? track.key
                    : track.key.substring(0, slash);
                excluded.update(root, (count) => count + 1, ifAbsent: () => 1);
              }
              return {
                'index': i + 1,
                'tracks': lists[i].tracks.length,
                'portable': portable,
                'excluded': [
                  for (final entry in excluded.entries)
                    {
                      'resource': fingerprint(entry.key),
                      'registered': registered.contains(entry.key),
                      'binding': refs.bindings.containsKey(entry.key),
                      'count': entry.value,
                    },
                ],
              };
            })(),
      ],
    };
  }

  static String body(String description, String steps, {String? diagnostics}) =>
      '## 증상\n${description.trim()}\n\n## 재현 방법\n${steps.trim().isEmpty ? "미작성" : steps.trim()}\n'
      '${diagnostics == null ? "" : "\n## 진단 정보\n```json\n$diagnostics\n```\n"}';

  static Uri issueUrl(String title, {String? body}) =>
      Uri.https('github.com', '/gaeco0/OPlayer/issues/new', {'title': title.trim(), if (body != null) 'body': body});
}
