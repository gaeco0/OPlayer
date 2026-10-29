import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/playlist_store.dart';
import 'package:oplayer/core/resource_locks.dart';
import 'package:oplayer/core/resume_store.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/core/sync_references.dart';
import 'package:oplayer/features/browser/recent_page.dart';
import 'package:oplayer/features/browser/file_actions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('batch history removal deletes portable aliases with one change notification', () async {
    final refs = SyncReferences.instance;
    refs.bindings['webdav://batch-test'] = 'Shared';
    addTearDown(refs.bindings.clear);
    const path = 'webdav://batch-test/movie.mp4';
    final portable = refs.portable(path)!;
    final entry = {'p': 10000, 'd': 60000, 'u': 1};
    SharedPreferences.setMockInitialValues({
      'resume_v1': jsonEncode({path: entry, portable: entry, 'https://example.com/keep.mp4': entry}),
    });
    final resume = ResumeStore.instance;
    await resume.init();
    var changes = 0;
    void changed() => changes++;
    resume.addListener(changed);
    try {
      await resume.removeAll([portable]);
      expect(changes, 1);
      expect(resume.get(path), isNull);
      await resume.init();
      expect(resume.entries.keys, ['https://example.com/keep.mp4']);
    } finally {
      resume.removeListener(changed);
    }
  });

  testWidgets('recent multi-select adds mixed sources, cancels back, deletes only history and clears on lock', (
    t,
  ) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final locks = ResourceLocks.instance;
    final resume = ResumeStore.instance;
    final playlists = PlaylistStore.instance;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(privacyChannel, (_) async => null);
    final dir = (await t.runAsync(() => Directory.systemTemp.createTemp('oplayer-recent-selection-')))!;
    final file = File('${dir.path}/local.mp3')..writeAsStringSync('original');
    final missing = '${dir.path}/missing.mp3';
    const remote = 'webdav://recent-test/music/remote.mp3';
    Future<void> save(String path, String title) =>
        resume.save(path, const Duration(seconds: 20), const Duration(minutes: 1), title: title);
    addTearDown(() async {
      locks.onAuthenticate = null;
      locks.background(false);
      FlutterSecureStorage.setMockInitialValues({});
      await locks.init();
      messenger.setMockMethodCallHandler(privacyChannel, null);
      file.deleteSync();
      dir.deleteSync();
    });
    final listId = (await t.runAsync(() async {
      await AppSettings.instance.init();
      AppSettings.instance.showThumbnails = false;
      await SyncReferences.instance.init();
      await resume.init();
      await locks.init();
      await save(file.path, 'Local');
      await save(remote, 'Remote');
      await save(missing, 'Missing');
      return playlists.create('Selected tracks');
    }))!;
    await t.pumpWidget(MaterialApp(home: RecentPage(onOpenDrawer: () {})));
    await t.pumpAndSettle();
    Finder selection(String path) => find.byWidgetPredicate((w) => w is FileSelectionTile && w.key == ValueKey(path));
    await t.tap(find.byTooltip('선택모드'));
    await t.pumpAndSettle();
    await t.tap(selection(file.path));
    await t.tap(selection(remote));
    await t.pumpAndSettle();
    expect(find.text('2개 선택'), findsOneWidget);
    await t.tap(find.byTooltip('선택 메뉴'));
    await t.pumpAndSettle();
    await t.tap(find.text('재생목록에 추가'));
    await t.pumpAndSettle();
    await t.tap(find.text('Selected tracks'));
    await t.pumpAndSettle();
    expect(playlists.find(listId)!.tracks.map((e) => e.key).toSet(), {file.path, remote});
    await t.tap(find.byTooltip('전체 선택/해제'));
    await t.pumpAndSettle();
    expect(find.text('3개 선택'), findsOneWidget);
    await t.tap(find.byTooltip('전체 선택/해제'));
    await t.pumpAndSettle();
    expect(find.text('0개 선택'), findsOneWidget);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.text('최근 재생'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);

    await t.longPress(find.text('Missing'));
    await t.pumpAndSettle();
    await t.tap(find.text('선택모드'));
    await t.pumpAndSettle();
    expect(find.text('1개 선택'), findsOneWidget);
    await t.tap(find.byTooltip('전체 선택/해제'));
    await t.pumpAndSettle();
    Future<void> removeMenu() async {
      await t.tap(find.byTooltip('선택 메뉴'));
      await t.pumpAndSettle();
      await t.tap(find.text('재생 기록 삭제'));
      await t.pumpAndSettle();
    }

    await removeMenu();
    expect(find.textContaining('원본 파일은 유지됩니다'), findsOneWidget);
    await t.tap(find.text('취소'));
    await t.pumpAndSettle();
    expect(resume.recent(), hasLength(3));
    await removeMenu();
    await t.tap(find.text('기록 삭제'));
    await t.pumpAndSettle();
    expect(resume.recent(), isEmpty);
    expect(file.readAsStringSync(), 'original');
    expect(playlists.find(listId)!.tracks, hasLength(2));
    await t.runAsync(() => resume.init());
    expect(resume.recent(), isEmpty);

    await t.runAsync(() => save(remote, 'Remote'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('선택모드'));
    await t.pumpAndSettle();
    await t.tap(selection(remote));
    await t.pumpAndSettle();
    await t.runAsync(() async {
      await locks.setPin('123456');
      locks.onAuthenticate = (_) => locks.verifyPin('123456');
      await locks.toggle(recentResourceKey, 'Recent');
    });
    await t.pumpAndSettle();
    expect(find.text('Remote'), findsNothing);
    expect(find.byTooltip('선택 메뉴'), findsNothing);
    await t.runAsync(() => locks.requireAccess(recentResourceKey));
    await t.pumpAndSettle();
    expect(find.text('Remote'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
    await t.pumpWidget(const SizedBox());
  });
}
