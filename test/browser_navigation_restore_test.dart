import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/media_item.dart';
import 'package:oplayer/core/resource_locks.dart';
import 'package:oplayer/core/resume_store.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/network/remote_browser_page.dart';
import 'package:oplayer/sources/media_source.dart';

class _Source extends MediaSource {
  @override
  String get scheme => 'gdrive';
  @override
  String get id => 'navigation';
  @override
  String get displayName => 'Test source';
  @override
  String get rootPath => 'opaque-root';
  final requests = <String>[];
  @override
  Future<List<RemoteEntry>> list(String path) async {
    requests.add(path);
    return path == rootPath
        ? [const RemoteEntry(name: 'Season', path: 'opaque-child', isDir: true)]
        : List.generate(
            60,
            (i) => RemoteEntry(name: 'Track ${i.toString().padLeft(2, '0')}.mp3', path: 'id-$i', isDir: false),
          );
  }

  @override
  MediaItem itemFor(RemoteEntry e, List<RemoteEntry> siblings) => MediaItem.url('https://example.com/${e.path}');
}

void main() {
  testWidgets('remote folder with opaque IDs and scroll offset survive menu changes and listing refreshes', (t) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await AppSettings.instance.init();
    await ResumeStore.instance.init();
    await ResourceLocks.instance.init();
    final bucket = PageStorageBucket();
    final source = _Source();
    Widget app(bool open) => MaterialApp(
      home: PageStorage(
        bucket: bucket,
        child: open ? RemoteBrowserPage(source: source) : const Scaffold(body: Text('Another menu')),
      ),
    );
    await t.pumpWidget(app(true));
    await t.pumpAndSettle();
    await t.tap(find.text('Season'));
    await t.pumpAndSettle();
    await t.drag(find.byType(ListView), const Offset(0, -700));
    await t.pumpAndSettle();
    final offset = t.state<ScrollableState>(find.byType(Scrollable).first).position.pixels;
    expect(offset, greaterThan(0));
    await t.pumpWidget(app(false));
    await t.pumpAndSettle();
    await t.pumpWidget(app(true));
    await t.pumpAndSettle();
    expect(find.text('Season'), findsOneWidget);
    expect(source.requests, ['opaque-root', 'opaque-child', 'opaque-child']);
    expect(t.state<ScrollableState>(find.byType(Scrollable).first).position.pixels, closeTo(offset, 1));
    await t.pumpWidget(const SizedBox());
  });
}
