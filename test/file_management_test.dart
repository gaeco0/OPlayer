import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/file_renaming.dart';
import 'package:oplayer/core/playlist_store.dart';
import 'package:oplayer/core/resource_locks.dart';
import 'package:oplayer/core/resume_store.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/browser/local_browser_page.dart';
import 'package:oplayer/features/browser/playlists_page.dart';
import 'package:oplayer/features/browser/swipe_delete_tile.dart';
import 'package:oplayer/features/browser/video_tile.dart';
import 'package:oplayer/features/network/remote_browser_page.dart';
import 'package:oplayer/core/media_item.dart';
import 'package:oplayer/sources/media_source.dart';
import 'package:oplayer/sources/server_store.dart';
import 'package:oplayer/sources/webdav_source.dart';

class _Source extends MediaSource {
  String? listedPath;
  final entries = [
    const RemoteEntry(name: 'one.mp4', path: '/media/one.mp4', isDir: false),
    const RemoteEntry(name: 'two.mp4', path: '/media/two.mp4', isDir: false),
    const RemoteEntry(name: 'folder', path: '/media/folder', isDir: true),
  ];
  @override
  String get scheme => 'test';
  @override
  String get id => 'management';
  @override
  String get displayName => 'Test';
  @override
  String get rootPath => '/media';
  @override
  bool get canDelete => true;
  @override
  bool get canRename => true;
  @override
  Future<List<RemoteEntry>> list(String path) async {
    listedPath = path;
    return List.of(entries);
  }

  @override
  Future<void> delete(RemoteEntry entry) async {
    entries.remove(entry);
  }

  @override
  MediaItem itemFor(RemoteEntry entry, List<RemoteEntry> siblings) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await AppSettings.instance.init();
    AppSettings.instance.showThumbnails = false;
    await ResumeStore.instance.init();
    await PlaylistStore.instance.init();
    await ResourceLocks.instance.init();
  });
  setUp(() async {
    for (final list in PlaylistStore.instance.lists) {
      await PlaylistStore.instance.delete(list.id);
    }
  });

  test('playlists persist references, deduplicate, copy, reorder and serialize concurrent additions', () async {
    final store = PlaylistStore();
    await store.init();
    final id = await store.create('Movies', [const PlaylistTrack('/a.mp4', 'A'), const PlaylistTrack('/a.mp4', 'A')]);
    await Future.wait([
      store.add(id, [const PlaylistTrack('webdav://saved-id/media/b.mp4', 'B')]),
      store.add(id, [const PlaylistTrack('/c.mp4', 'C')]),
    ]);
    expect(store.find(id)!.tracks.length, 3);
    await store.reorder(id, 0, 2);
    expect(store.find(id)!.tracks.map((t) => t.title), ['B', 'C', 'A']);
    final copied = await store.create('Copy', store.find(id)!.tracks);
    await store.remove(id, {'/a.mp4'});
    expect(store.find(copied)!.tracks.length, 3);
    await store.rename(id, 'Renamed');
    final restored = PlaylistStore();
    await restored.init();
    expect(restored.find(id)!.name, 'Renamed');
    expect(restored.find(id)!.tracks.map((t) => t.title), ['B', 'C']);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('playlists_v1')!;
    expect(raw, isNot(contains('Authorization')));
    expect(jsonDecode(raw), hasLength(2));
    await store.delete(copied);
    expect(store.find(copied), null);
  });

  test('folder references survive persistence and copying without changing ordinary tracks', () async {
    final store = PlaylistStore();
    final id = await store.create('Folders', [
      const PlaylistTrack('/movies', 'Movies', isFolder: true),
      const PlaylistTrack('webdav://saved-id/media', 'Remote', isFolder: true),
      const PlaylistTrack('/one.mp4', 'One'),
    ]);
    await store.add(id, [const PlaylistTrack('/movies', 'Movies', isFolder: true)]);
    final restored = PlaylistStore();
    await restored.init();
    final tracks = restored.find(id)!.tracks;
    expect(tracks.map((t) => t.isFolder), [true, true, false]);
    final copy = await restored.create('Copy', tracks);
    await restored.remove(id, {'/movies'});
    expect(restored.find(copy)!.tracks.first.isFolder, true);
    expect(restored.find(copy)!.tracks.first.toJson()['isFolder'], true);
    expect(tracks.last.toJson().containsKey('isFolder'), false);
  });

  testWidgets('local folder menu saves a folder and reopening shows current contents', (tester) async {
    final root = Directory.systemTemp.createTempSync('oplayer_playlist_folder_');
    addTearDown(() => root.delete(recursive: true));
    final folder = Directory(p.join(root.path, 'Movies'))..createSync();
    File(p.join(folder.path, 'one.mp4')).writeAsStringSync('one');
    final id = await PlaylistStore.instance.create('Folder destination');
    await tester.pumpWidget(
      MaterialApp(
        home: LocalBrowserPage(
          rootPath: root.path,
          rootTitle: 'Test',
          ensurePermission: () async => true,
          onOpenDrawer: () {},
        ),
      ),
    );
    Future<void> waitFor(Finder finder) async {
      for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      }
      expect(finder, findsOneWidget);
    }

    await waitFor(find.byType(FolderListTile));
    await tester.tap(find.byTooltip('폴더 메뉴'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('재생목록에 추가'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Folder destination'));
    await tester.pumpAndSettle();
    final saved = PlaylistStore.instance.find(id)!;
    expect(saved.tracks.single.key, folder.path);
    expect(saved.tracks.single.isFolder, true);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MaterialApp(home: PlaylistPage(id: id)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Movies'));
    await tester.pump();
    await waitFor(find.text('one.mp4'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    File(p.join(folder.path, 'two.mp4')).writeAsStringSync('two');
    await tester.tap(find.text('Movies'));
    await tester.pump();
    await waitFor(find.text('two.mp4'));
    await tester.pumpAndSettle();
    expect(PlaylistStore.instance.find(id)!.tracks, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'rename keeps contents, watched status, playlist references and file lock; rejects collision and traversal',
    () async {
      final root = await Directory.systemTemp.createTemp('oplayer_rename_');
      addTearDown(() => root.delete(recursive: true));
      final file = await File(p.join(root.path, 'old.mp4')).writeAsString('media bytes');
      final existing = await File(p.join(root.path, 'existing.mp4')).writeAsString('keep');
      final store = PlaylistStore.instance;
      final id = await store.create('Rename', [PlaylistTrack(file.path, 'old.mp4')]);
      await ResumeStore.instance.save(file.path, const Duration(seconds: 40), const Duration(seconds: 100));
      final locks = ResourceLocks.instance;
      await locks.setPin('123456');
      locks.onAuthenticate = (_) => locks.verifyPin('123456');
      await locks.toggle(file.path, 'old.mp4');
      locks.relock();
      locks.onAuthenticate = (_) async => false;
      await expectLater(
        renameLocalFile(file.path, 'new.mp4', parent: root.path),
        throwsA(isA<ResourceLockedException>()),
      );
      expect(await file.exists(), true);
      locks.onAuthenticate = (_) => locks.verifyPin('123456');
      final failedTarget = p.join(root.path, 'failed.mp4');
      await expectLater(
        locks.renameFile(file.path, failedTarget, () async {
          throw StateError('rename denied');
        }),
        throwsStateError,
      );
      expect(locks.hasExact(file.path), true);
      expect(locks.hasExact(failedTarget), false);
      final target = await renameLocalFile(file.path, 'new.mp4', parent: root.path);
      expect(await File(target).readAsString(), 'media bytes');
      expect(await file.exists(), false);
      expect(ResumeStore.instance.get(target)!.position.inSeconds, 40);
      expect(ResumeStore.instance.get(file.path), null);
      expect(store.find(id)!.tracks.single.key, target);
      expect(locks.hasExact(target), true);
      expect(locks.hasExact(file.path), false);
      await expectLater(
        renameLocalFile(target, existing.uri.pathSegments.last, parent: root.path),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(renameLocalFile(target, '../escape.mp4', parent: root.path), throwsFormatException);
      expect(await existing.readAsString(), 'keep');
      locks.onAuthenticate = null;
      FlutterSecureStorage.setMockInitialValues({});
      await locks.init();
    },
  );

  test('prospective file lock keys match existing file keys under the temporary directory', () async {
    final root = await Directory.systemTemp.createTemp('oplayer_lock_key_');
    addTearDown(() => root.delete(recursive: true));
    var parent = root.path;
    if (Platform.isWindows) {
      final shortPath = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r'(New-Object -ComObject Scripting.FileSystemObject).GetFolder($env:OPLAYER_TEST_LOCK_DIRECTORY).ShortPath',
        ],
        environment: {'OPLAYER_TEST_LOCK_DIRECTORY': root.path},
      );
      expect(shortPath.exitCode, 0, reason: '${shortPath.stderr}');
      parent = '${shortPath.stdout}'.trim();
      expect(parent, isNotEmpty);
    }
    final file = File(p.join(parent, 'not-yet-created.mp4'));
    final before = resourceKey(file.path);
    expect(before, resourceKey(p.join(root.resolveSymbolicLinksSync(), 'not-yet-created.mp4')));
    final missingPath = p.join(parent, 'missing', 'nested', 'movie.mp4');
    expect(
      resourceKey(missingPath),
      resourceKey(p.join(root.resolveSymbolicLinksSync(), 'missing', 'nested', 'movie.mp4')),
    );
    final locks = ResourceLocks();
    await locks.init();
    await locks.setPin('123456');
    var prompts = 0;
    locks.onAuthenticate = (_) {
      prompts++;
      return locks.verifyPin('123456');
    };
    await locks.toggle(p.join(parent, 'missing'), 'missing');
    locks.relock();
    prompts = 0;
    await locks.requireAccess(missingPath);
    expect(prompts, 1);
    FlutterSecureStorage.setMockInitialValues({});
    await file.writeAsString('test');
    expect(resourceKey(file.path), before);
  });

  testWidgets('right swipe toggles watched both ways without removing the row', (tester) async {
    final key = 'https://test.example/right-swipe.mp4';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SwipeDeleteTile(
            onDelete: null,
            watchedKey: key,
            watchedTitle: 'Test',
            child: const SizedBox(height: 100, width: 600, child: Text('Swipe')),
          ),
        ),
      ),
    );
    await tester.timedDrag(find.text('Swipe'), const Offset(700, 0), const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(ResumeStore.instance.get(key)!.finished, true);
    expect(find.text('Swipe'), findsOneWidget);
    await tester.timedDrag(find.text('Swipe'), const Offset(700, 0), const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(ResumeStore.instance.get(key)!.finished, false);
  });

  testWidgets('local selection adds to a new playlist and menu rename updates its reference', (tester) async {
    final root = Directory.systemTemp.createTempSync('oplayer_selection_');
    addTearDown(() => root.delete(recursive: true));
    final file = File(p.join(root.path, 'choose.mp4'))..writeAsStringSync('file');
    await tester.pumpWidget(
      MaterialApp(
        home: LocalBrowserPage(
          rootPath: root.path,
          rootTitle: 'Test',
          ensurePermission: () async => true,
          onOpenDrawer: () {},
        ),
      ),
    );
    Future<void> waitFor(String name) async {
      final fileName = find.descendant(of: find.byType(VideoListTile), matching: find.text(name));
      for (var i = 0; i < 50 && fileName.evaluate().isEmpty; i++) {
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      }
      expect(fileName, findsOneWidget);
    }

    await waitFor('choose.mp4');
    await tester.tap(find.byTooltip('선택모드'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(find.text('1개 선택'), findsOneWidget);
    await tester.tap(find.byTooltip('선택 메뉴'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('재생목록에 추가'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('새 재생목록 만들기'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Chosen');
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();
    expect(PlaylistStore.instance.lists.single.tracks.single.key, file.path);
    await tester.tap(find.byTooltip('선택 취소'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('이름변경'));
    await tester.tap(find.text('이름변경'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'renamed.mp4');
    await tester.tap(find.text('확인'));
    await waitFor('renamed.mp4');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.text('renamed.mp4'), findsOneWidget);
    expect(PlaylistStore.instance.lists.single.tracks.single.key, p.join(root.path, 'renamed.mp4'));
  });

  testWidgets('remote select all deletes files after confirmation and leaves folders intact', (tester) async {
    final source = _Source();
    await tester.pumpWidget(MaterialApp(home: RemoteBrowserPage(source: source)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('선택모드'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('전체 선택/해제'));
    await tester.pumpAndSettle();
    expect(find.text('3개 선택'), findsOneWidget);
    await tester.tap(find.byTooltip('선택 메뉴'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('파일 삭제'));
    await tester.pumpAndSettle();
    expect(source.entries.length, 3);
    await tester.tap(find.text('파일 삭제'));
    await tester.pumpAndSettle();
    expect(source.entries.single.isDir, true);
  });

  testWidgets('remote folder menu stores its reference and folder view refreshes current contents', (tester) async {
    final source = _Source();
    final id = await PlaylistStore.instance.create('Remote destination');
    await tester.pumpWidget(MaterialApp(home: RemoteBrowserPage(source: source)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('폴더 메뉴'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('재생목록에 추가'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remote destination'));
    await tester.pumpAndSettle();
    expect(PlaylistStore.instance.find(id)!.tracks.single.key, 'test://management/media/folder');
    expect(PlaylistStore.instance.find(id)!.tracks.single.isFolder, true);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      MaterialApp(
        home: RemoteBrowserPage(source: source, initialPath: '/media/folder', initialTitle: 'Saved folder'),
      ),
    );
    await tester.pumpAndSettle();
    expect(source.listedPath, '/media/folder');
    expect(find.text('Saved folder'), findsOneWidget);
    source.entries.add(const RemoteEntry(name: 'new.mp4', path: '/media/folder/new.mp4', isDir: false));
    await tester.tap(find.byTooltip('새로고침'));
    await tester.pumpAndSettle();
    expect(find.text('new.mp4'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('playlist selection copies to another list and removes references only', (tester) async {
    final store = PlaylistStore.instance;
    final from = await store.create('From', [
      const PlaylistTrack('/missing-one.mp4', 'One'),
      const PlaylistTrack('/missing-two.mp4', 'Two'),
    ]);
    final to = await store.create('Destination');
    await tester.pumpWidget(MaterialApp(home: PlaylistPage(id: from)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('선택모드'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('선택 메뉴'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('재생목록에 추가'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Destination'));
    await tester.pumpAndSettle();
    expect(store.find(to)!.tracks.single.key, '/missing-one.mp4');
    await tester.tap(find.byTooltip('선택 메뉴'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('재생목록에서 삭제'));
    await tester.pumpAndSettle();
    expect(store.find(from)!.tracks.single.title, 'Two');
    expect(store.find(to)!.tracks.single.title, 'One');
  });

  test('WebDAV rename uses authenticated encoded MOVE with overwrite disabled', () async {
    final previous = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previous);
    final server = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      expect(request.method, 'MOVE');
      expect(request.headers.value('authorization'), 'Basic ${base64Encode(utf8.encode('user:password'))}');
      expect(request.headers.value('overwrite'), 'F');
      expect(Uri.decodeComponent(Uri.parse(request.headers.value('destination')!).path), '/media/새 이름.mp4');
      request.response.statusCode = 201;
      await request.response.close();
    });
    final source = WebDavSource(
      ServerConfig(
        id: 'rename',
        type: ServerType.webdav,
        name: 'Test',
        host: '127.0.0.1',
        port: server.port,
        path: '/media',
        username: 'user',
        secure: false,
      ),
      'password',
    );
    const entry = RemoteEntry(name: 'old.mp4', path: '/media/old.mp4', isDir: false);
    expect(await source.rename(entry, '새 이름.mp4'), '/media/새 이름.mp4');
    await expectLater(source.rename(entry, '../bad.mp4'), throwsFormatException);
  });
}
