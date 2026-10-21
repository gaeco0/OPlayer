import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oplayer/core/folder_sort.dart';
import 'package:oplayer/core/media_item.dart';
import 'package:oplayer/core/resume_store.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/browser/local_browser_page.dart';
import 'package:oplayer/features/network/remote_browser_page.dart';
import 'package:oplayer/sources/media_source.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Source extends MediaSource {
  _Source(this.id);
  @override
  final String id;
  @override
  String get scheme => 'test';
  @override
  String get displayName => 'Server';
  @override
  String get rootPath => '/';
  @override
  Future<List<RemoteEntry>> list(String path) async => [
    RemoteEntry(name: 'Z folder', path: '${path}z/', isDir: true, size: 30),
    RemoteEntry(name: 'A.mp3', path: '${path}a.mp3', isDir: false, size: 10),
    RemoteEntry(name: 'B.mp3', path: '${path}b.mp3', isDir: false, size: 20),
  ];
  @override
  MediaItem itemFor(RemoteEntry e, List<RemoteEntry> siblings) => throw UnimplementedError();
}

Future<void> _choose(WidgetTester tester, String label) async {
  await tester.tap(find.byIcon(Icons.sort));
  await tester.pumpAndSettle();
  await tester.tap(find.ancestor(of: find.text(label), matching: find.byType(CheckedPopupMenuItem<Object>)));
  await tester.pumpAndSettle();
}

void _expectOrder(WidgetTester tester, List<String> names) {
  final positions = names
      .map((name) => tester.getTopLeft(find.descendant(of: find.byType(ListView), matching: find.text(name))).dy)
      .toList();
  expect(positions, orderedEquals([...positions]..sort()));
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({'settings_v1': '{}'});
    await AppSettings.instance.init();
    await ResumeStore.instance.init();
    AppSettings.instance.showThumbnails = false;
  });

  testWidgets('remote order, grouping and direction persist per folder and server', (t) async {
    await t.pumpWidget(MaterialApp(home: RemoteBrowserPage(source: _Source('one'))));
    await t.pumpAndSettle();
    _expectOrder(t, ['Z folder', 'A.mp3', 'B.mp3']);
    await _choose(t, '폴더 먼저 표시');
    _expectOrder(t, ['A.mp3', 'B.mp3', 'Z folder']);
    await _choose(t, '크기');
    await _choose(t, '크기  ↑');
    _expectOrder(t, ['Z folder', 'B.mp3', 'A.mp3']);

    await t.tap(find.text('Z folder'));
    await t.pumpAndSettle();
    _expectOrder(t, ['Z folder', 'A.mp3', 'B.mp3']);
    await _choose(t, '이름  ↑');
    _expectOrder(t, ['Z folder', 'B.mp3', 'A.mp3']);
    await t.tap(find.byIcon(Icons.arrow_back));
    await t.pumpAndSettle();
    _expectOrder(t, ['Z folder', 'B.mp3', 'A.mp3']);
    await _choose(t, '크기  ↓');
    _expectOrder(t, ['A.mp3', 'B.mp3', 'Z folder']);

    // Reload persisted preferences and reconstruct the page, like an app restart.
    await t.pumpWidget(const SizedBox());
    await AppSettings.instance.init();
    await t.pumpWidget(MaterialApp(home: RemoteBrowserPage(source: _Source('one'))));
    await t.pumpAndSettle();
    _expectOrder(t, ['A.mp3', 'B.mp3', 'Z folder']);
    await t.tap(find.text('Z folder'));
    await t.pumpAndSettle();
    _expectOrder(t, ['Z folder', 'B.mp3', 'A.mp3']);

    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(MaterialApp(home: RemoteBrowserPage(source: _Source('two'))));
    await t.pumpAndSettle();
    _expectOrder(t, ['Z folder', 'A.mp3', 'B.mp3']);
  });

  testWidgets('local parent and child restore independent sort orders', (t) async {
    final root = (await t.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('oplayer_sort_');
      await Directory('${root.path}/A folder/A child').create(recursive: true);
      await Directory('${root.path}/A folder/Z child').create();
      await Directory('${root.path}/Z folder').create();
      return root;
    }))!;
    addTearDown(() => root.delete(recursive: true));
    Future<void> waitFor(String name) async {
      for (var i = 0; i < 40 && find.text(name).evaluate().isEmpty; i++) {
        await t.pump(const Duration(milliseconds: 20));
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      }
      expect(find.text(name), findsOneWidget);
    }

    await t.pumpWidget(
      MaterialApp(
        home: LocalBrowserPage(
          rootPath: root.path,
          rootTitle: 'Local',
          ensurePermission: () async => true,
          onOpenDrawer: () {},
        ),
      ),
    );
    await waitFor('A folder');
    await _choose(t, '이름  ↑');
    _expectOrder(t, ['Z folder', 'A folder']);
    await t.tap(find.text('A folder'));
    await waitFor('A child');
    _expectOrder(t, ['A child', 'Z child']);
    await t.tap(find.byIcon(Icons.arrow_back));
    await waitFor('Z folder');
    _expectOrder(t, ['Z folder', 'A folder']);
  });

  test('invalid saved sort entries fall back without affecting valid folders', () async {
    SharedPreferences.setMockInitialValues({
      'settings_v1': jsonEncode({
        'folderSorts': {
          'bad': false,
          'unknown': {'by': 'unknown', 'ascending': 0, 'foldersFirst': null},
          'good': {'by': 'date', 'ascending': false, 'foldersFirst': false},
        },
      }),
    });
    await AppSettings.instance.init();
    expect(AppSettings.instance.folderSort('bad').by, SortBy.name);
    expect(AppSettings.instance.folderSort('unknown').foldersFirst, isTrue);
    final good = AppSettings.instance.folderSort('good');
    expect(good.by, SortBy.date);
    expect(good.ascending, isFalse);
    expect(good.foldersFirst, isFalse);
  });
}
