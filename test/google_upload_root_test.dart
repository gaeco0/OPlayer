import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/media_item.dart';
import 'package:oplayer/core/resource_locks.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/core/plugins/plugin.dart';
import 'package:oplayer/core/plugins/plugin_runtime.dart';
import 'package:oplayer/features/network/remote_folder_picker.dart';
import 'package:oplayer/sources/media_source.dart';

const ownedFolder = {
  'id': 'owned-folder',
  'mimeType': 'application/vnd.google-apps.folder',
  'isAppAuthorized': true,
  'appProperties': {'oplayerUploadFolder': 'v1'},
};

class UploadSource extends MediaSource {
  @override
  String get scheme => 'test';
  @override
  String get id => 'account';
  @override
  String get displayName => 'Drive';
  @override
  String get rootPath => 'root';
  @override
  String get uploadRootTitle => 'OPlayer';
  @override
  bool get hasFixedUploadRoot => true;
  @override
  Future<String> uploadRoot() async => 'owned-folder';
  @override
  Future<List<RemoteEntry>> list(String path) async => throw StateError('Must not list readonly folders for upload');
  @override
  MediaItem itemFor(RemoteEntry e, List<RemoteEntry> siblings) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  OPlugin plugin() => OPlugin.parse(File('plugins/cloud.gdrive.js').readAsStringSync());
  test('creates a marked app folder and reuses it without adopting a same-name folder', () async {
    var created = false, creates = 0;
    Future<Object?> request(String url, Map<String, dynamic> options) async {
      if (options['method'] == 'POST') {
        creates++;
        expect(options['body'], {
          'name': 'OPlayer',
          'mimeType': 'application/vnd.google-apps.folder',
          'parents': ['root'],
          'appProperties': {'oplayerUploadFolder': 'v1'},
        });
        created = true;
        return {'id': 'owned-folder'};
      }
      expect(Uri.parse(url).queryParameters['q'], contains('appProperties'));
      expect(Uri.parse(url).queryParameters['q'], contains("'root' in parents"));
      return {
        'files': created
            ? [ownedFolder]
            : [
                {
                  'id': 'someone-elses-folder',
                  'name': 'OPlayer',
                  'mimeType': 'application/vnd.google-apps.folder',
                  'isAppAuthorized': false,
                },
              ],
      };
    }

    expect(await callPlugin(plugin(), 'uploadRoot', {}, request: request), 'owned-folder');
    expect(await callPlugin(plugin(), 'uploadRoot', {}, request: request), 'owned-folder');
    expect(creates, 1);
  });
  test('legacy root upload resolves to the app folder and writes no arbitrary parent', () async {
    final plan = await callPlugin(
      plugin(),
      'upload',
      {'path': 'root', 'name': 'movie.mp4', 'size': 9},
      request: (url, options) async {
        if (options['response'] == 'headers') {
          expect(options['body'], {
            'name': 'movie.mp4',
            'parents': ['owned-folder'],
          });
          return {'location': 'https://www.googleapis.com/upload/session'};
        }
        final q = Uri.parse(url).queryParameters['q']!;
        return {
          'files': q.contains('appProperties') ? [ownedFolder] : [],
        };
      },
    );
    expect((plan as Map)['protocol'], 'http-content-range');
  });
  test('readonly destination or an unowned existing file never starts a write', () async {
    for (final wrongFolder in [true, false]) {
      var writes = 0;
      await expectLater(
        callPlugin(
          plugin(),
          'upload',
          {'path': 'owned-folder', 'name': 'movie.mp4', 'size': 9, 'overwritePath': 'existing'},
          request: (url, options) async {
            if (options['method'] != null) writes++;
            if (Uri.parse(url).path == '/drive/v3/files/owned-folder') {
              return {...ownedFolder, 'isAppAuthorized': !wrongFolder};
            }
            return {
              'files': [
                {'id': 'existing', 'name': 'movie.mp4', 'mimeType': 'video/mp4', 'isAppAuthorized': false},
              ],
            };
          },
        ),
        throwsStateError,
      );
      expect(writes, 0);
    }
  });
  testWidgets('upload picker resolves and returns the dedicated root without listing readonly folders', (tester) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await AppSettings.instance.init();
    await ResourceLocks.instance.init();
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              child: const Text('open'),
              onPressed: () async {
                selected = await RemoteFolderPicker.pick(context, UploadSource());
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('OPlayer 전용 폴더'), findsOneWidget);
    await tester.tap(find.text('이 폴더에 저장'));
    await tester.pumpAndSettle();
    expect(selected, 'owned-folder');
  });
}
