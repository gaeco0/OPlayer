import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/file_deletion.dart';
import 'package:oplayer/core/media_item.dart';
import 'package:oplayer/core/resource_locks.dart';
import 'package:oplayer/core/resume_store.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/browser/swipe_delete_tile.dart';
import 'package:oplayer/features/network/remote_browser_page.dart';
import 'package:oplayer/sources/media_source.dart';
import 'package:oplayer/sources/server_store.dart';
import 'package:oplayer/sources/webdav_source.dart';
import 'package:oplayer/sources/smb_source.dart';

class _Source extends MediaSource {
  final entries = [const RemoteEntry(name: 'movie.mp4', path: '/media/movie.mp4', isDir: false)];
  bool fail = false;
  int loads = 0;
  @override
  String get scheme => 'test';
  @override
  String get id => 'test';
  @override
  String get displayName => 'Test';
  @override
  String get rootPath => '/media';
  @override
  bool get canDelete => true;
  @override
  Future<List<RemoteEntry>> list(String path) async {
    loads++;
    return List.of(entries);
  }

  @override
  Future<void> delete(RemoteEntry entry) async {
    if (fail) throw StateError('server denied deletion');
    entries.removeWhere((e) => e.path == entry.path);
  }

  @override
  MediaItem itemFor(RemoteEntry entry, List<RemoteEntry> siblings) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await AppSettings.instance.init();
    AppSettings.instance.showThumbnails = false;
    await ResumeStore.instance.init();
    await ResourceLocks.instance.init();
    ResourceLocks.instance.onAuthenticate = null;
  });
  tearDown(() => ResourceLocks.instance.onAuthenticate = null);

  test('local deletion removes only the selected file or folder, never an outside target', () async {
    final root = await Directory.systemTemp.createTemp('oplayer_delete_');
    addTearDown(() => root.delete(recursive: true));
    final folder = await Directory(p.join(root.path, 'folder')).create();
    await File(p.join(folder.path, 'child.mp3')).writeAsString('test');
    final kept = await File(p.join(root.path, 'keep.mp3')).writeAsString('test');
    await expectLater(deleteLocalEntry(root.path, parent: root.path), throwsA(isA<FileSystemException>()));
    await expectLater(deleteLocalEntry(kept.path, parent: folder.path), throwsA(isA<FileSystemException>()));
    expect(await kept.exists(), true);
    await deleteLocalEntry(folder.path, parent: root.path);
    expect(await folder.exists(), false);
    expect(await kept.exists(), true);
    await deleteLocalEntry(kept.path, parent: root.path);
    expect(await kept.exists(), false);
  });

  test('a protected descendant prevents deleting the entire local parent directory', () async {
    final root = await Directory.systemTemp.createTemp('oplayer_delete_lock_');
    addTearDown(() => root.delete(recursive: true));
    final folder = await Directory(p.join(root.path, 'folder')).create();
    final secret = await File(p.join(folder.path, 'secret.mp3')).writeAsString('test');
    final locks = ResourceLocks.instance;
    await locks.setPin('123456');
    locks.onAuthenticate = (_) => locks.verifyPin('123456');
    await locks.toggle(secret.path, 'secret');
    locks.relock();
    locks.onAuthenticate = (_) async => false;
    await expectLater(deleteLocalEntry(folder.path, parent: root.path), throwsA(isA<ResourceLockedException>()));
    expect(await secret.exists(), true);
    locks.onAuthenticate = (_) => locks.verifyPin('123456');
    await deleteLocalEntry(folder.path, parent: root.path);
    expect(await folder.exists(), false);
  });

  test('WebDAV sends an authenticated encoded DELETE, rejects roots and reports partial failures', () async {
    final previous = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previous);
    final server = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() => server.close(force: true));
    var status = 204, requests = 0;
    server.listen((request) async {
      requests++;
      expect(request.method, 'DELETE');
      expect(request.headers.value('authorization'), 'Basic ${base64Encode(utf8.encode('user:password'))}');
      expect(Uri.decodeComponent(request.uri.path), '/media/a #한글.mp4');
      request.response.statusCode = status;
      await request.response.close();
    });
    final source = WebDavSource(
      ServerConfig(
        id: 'test',
        type: ServerType.webdav,
        name: 'Test',
        host: '127.0.0.1',
        port: server.port,
        path: '/media/',
        username: 'user',
      ),
      'password',
    );
    const entry = RemoteEntry(name: 'a #한글.mp4', path: '/media/a #한글.mp4', isDir: false);
    expect(source.canDeleteEntry(entry), true);
    for (final bad in ['/media', '/media/', '/', '/other/a', '/media/../other/a', '/media/a\r\nDELETE /']) {
      final target = RemoteEntry(name: 'bad', path: bad, isDir: true);
      expect(source.canDeleteEntry(target), false);
      await expectLater(source.delete(target), throwsFormatException);
    }
    expect(requests, 0);
    await source.delete(entry);
    for (final value in [207, 403, 302]) {
      status = value;
      await expectLater(source.delete(entry), throwsA(isA<HttpException>()));
    }
    expect(requests, 4);
    final smb = SmbSource(ServerConfig(id: 'smb', type: ServerType.smb, name: 'SMB', host: 'unused'), '');
    expect(smb.canDeleteEntry(const RemoteEntry(name: 'share', path: '/share/', isDir: true)), false);
    expect(smb.canDeleteEntry(const RemoteEntry(name: 'file', path: '/share/file.mp4', isDir: false)), true);
  });

  testWidgets('a full left swipe only reveals delete; tapping it blocks duplicates and shows progress', (t) async {
    var calls = 0;
    final done = Completer<void>();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SlidableAutoCloseBehavior(
            child: SwipeDeleteTile(
              key: const ValueKey('row'),
              onDelete: () {
                calls++;
                return done.future;
              },
              child: const ListTile(title: Text('File')),
            ),
          ),
        ),
      ),
    );
    await t.drag(find.byKey(const ValueKey('row')), const Offset(-650, 0));
    await t.pumpAndSettle();
    expect(calls, 0);
    await t.tap(find.text('삭제'));
    await t.pump();
    expect(calls, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await t.tap(find.byType(CircularProgressIndicator));
    expect(calls, 1);
    done.complete();
    await t.pumpAndSettle();
    expect(find.text('File'), findsOneWidget);
  });

  testWidgets('remote delete refreshes the list on success and preserves failed entries', (t) async {
    final source = _Source()..fail = true;
    await t.pumpWidget(MaterialApp(home: RemoteBrowserPage(source: source)));
    await t.pumpAndSettle();
    Future<void> remove() async {
      await t.drag(find.byKey(const ValueKey('/media/movie.mp4')), const Offset(-650, 0));
      await t.pumpAndSettle();
      await t.tap(find.text('삭제'));
      await t.pumpAndSettle();
    }

    await remove();
    expect(find.text('movie.mp4'), findsOneWidget);
    expect(find.textContaining('server denied deletion'), findsOneWidget);
    source.fail = false;
    await remove();
    expect(find.text('movie.mp4'), findsNothing);
    expect(find.text('항목이 없습니다'), findsOneWidget);
    expect(source.loads, 3);
  });
}
