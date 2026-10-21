import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oplayer/core/media_item.dart';
import 'package:oplayer/features/network/remote_browser_page.dart';
import 'package:oplayer/sources/media_source.dart';

class _Source extends MediaSource {
  int calls = 0;
  @override
  String get scheme => 'test';
  @override
  String get id => 'test';
  @override
  String get displayName => 'Test server';
  @override
  String get rootPath => '/';
  @override
  Future<List<RemoteEntry>> list(String path) async =>
      ++calls == 1 ? [] : [const RemoteEntry(name: 'New folder', path: '/new', isDir: true)];
  @override
  MediaItem itemFor(RemoteEntry e, List<RemoteEntry> siblings) => throw UnimplementedError();
}

void main() {
  testWidgets('pulling an empty server list refreshes the source instead of its cache', (tester) async {
    final source = _Source();
    await tester.pumpWidget(MaterialApp(home: RemoteBrowserPage(source: source)));
    await tester.pumpAndSettle();
    expect(source.calls, 1);
    expect(find.text('항목이 없습니다'), findsOneWidget);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(source.calls, 2);
    expect(find.text('New folder'), findsOneWidget);
  });
}
