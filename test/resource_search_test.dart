import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/media_item.dart';
import 'package:oplayer/core/resource_locks.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/network/remote_browser_page.dart';
import 'package:oplayer/sources/media_source.dart';

class _Source extends MediaSource {
  @override
  String get id => 'search';
  @override
  String get scheme => 'test';
  @override
  String get displayName => 'Search storage';
  @override
  String get rootPath => 'root';
  @override
  bool canSearch = true;
  final requests = <({String query, String path, Completer<List<RemoteEntry>> result})>[];
  final lists = <String>[];
  @override
  Future<List<RemoteEntry>> list(String path) async {
    lists.add(path);
    return [const RemoteEntry(name: 'Original folder', path: 'folder-id', isDir: true)];
  }

  @override
  Future<List<RemoteEntry>> search(String query, {required String path}) {
    final result = Completer<List<RemoteEntry>>();
    requests.add((query: query, path: path, result: result));
    return result.future;
  }

  @override
  MediaItem itemFor(RemoteEntry e, List<RemoteEntry> siblings) => throw UnimplementedError();
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await AppSettings.instance.init();
    await ResourceLocks.instance.init();
  });

  testWidgets('debounced queries reach provider, stale responses cannot replace results, close restores folder', (
    t,
  ) async {
    final source = _Source();
    await t.pumpWidget(MaterialApp(home: RemoteBrowserPage(source: source)));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('검색'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), ' old ');
    await t.pump(const Duration(milliseconds: 350));
    expect(source.requests.single.query, 'old');
    expect(source.requests.single.path, 'root');
    await t.enterText(find.byType(TextField), 'new');
    source.requests.first.result.complete([const RemoteEntry(name: 'Old result', path: 'old', isDir: true)]);
    await t.pump();
    expect(find.text('Old result'), findsNothing);
    await t.pump(const Duration(milliseconds: 350));
    source.requests.last.result.complete([const RemoteEntry(name: 'New result', path: 'new', isDir: true)]);
    await t.pumpAndSettle();
    expect(find.text('New result'), findsOneWidget);
    expect(source.lists, ['root']);
    await t.tap(find.byTooltip('새로고침'));
    await t.pump();
    expect(source.requests.last.query, 'new');
    await t.tap(find.byTooltip('검색 닫기'));
    await t.pumpAndSettle();
    expect(find.text('Original folder'), findsOneWidget);
    source.requests.last.result.complete([]);
    await t.pumpAndSettle();
    expect(find.text('Original folder'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    // Searching inside a folder passes its opaque ID to the provider.
    await t.tap(find.text('Original folder'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('검색'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), '한글 & query');
    await t.testTextInput.receiveAction(TextInputAction.search);
    await t.pump();
    expect(source.requests.last.query, '한글 & query');
    expect(source.requests.last.path, 'folder-id');
    source.requests.last.result.complete([]);
    await t.pumpAndSettle();
    expect(find.text('검색 결과가 없습니다'), findsOneWidget);
    await t.tap(find.byIcon(Icons.arrow_back));
    await t.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(source.lists.last, 'folder-id');
  });

  testWidgets('providers without a search hook keep their normal folder browser', (t) async {
    final source = _Source()..canSearch = false;
    await t.pumpWidget(MaterialApp(home: RemoteBrowserPage(source: source)));
    await t.pumpAndSettle();
    expect(find.byTooltip('검색'), findsNothing);
    expect(find.text('Original folder'), findsOneWidget);
  });
}
