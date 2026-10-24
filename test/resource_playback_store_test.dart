import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:oplayer/core/resume_store.dart';
import 'package:oplayer/features/browser/video_tile.dart';
import 'package:oplayer/core/media_item.dart';
import 'package:oplayer/core/resource_playback_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  MediaItem item(String key, String resource, List<String> folders) =>
      MediaItem(key: key, uri: 'https://temporary.invalid/play', title: 'Movie').inResource(resource, folders);

  test('opaque folder IDs and file names remain independent per resource and persist across restarts', () async {
    final store = ResourcePlaybackStore();
    await store.init();
    final a = item('gdrive://one/file-A', 'account-one', ['gdrive://one/root', 'gdrive://one/folder-7']);
    final b = item('webdav://two/movie.mp4', 'account-two', ['webdav://two/']);
    await store.record(a);
    await store.record(b);
    expect(store.highlighted('account-one', a.key), true);
    expect(store.highlighted('account-one', 'gdrive://one/folder-7', folder: true), true);
    expect(store.highlighted('account-two', b.key), true);
    expect(store.highlighted('account-two', a.key), false);

    final next = item('gdrive://one/file-B', 'account-one', ['gdrive://one/root', 'gdrive://one/folder-8']);
    await store.record(next);
    expect(store.highlighted('account-one', a.key), false);
    expect(store.highlighted('account-one', 'gdrive://one/folder-7', folder: true), false);
    final restored = ResourcePlaybackStore();
    await restored.init();
    expect(restored.highlighted('account-one', next.key), true);
    expect(restored.highlighted('account-two', b.key), true);
    // Replaying through recent/playlist has no browsing metadata but keeps its known resource.
    await restored.record(MediaItem(key: a.key, uri: a.uri, title: a.title));
    expect(restored.highlighted('account-one', a.key), true);
    expect(restored.highlighted('account-one', next.key), false);
  });

  test('overlapping registered local roots each retain their own latest file', () async {
    final store = ResourcePlaybackStore();
    await store.record(item('/media/shared/movie.mp4', 'home', ['/media', '/media/shared']));
    await store.record(item('/media/shared/movie.mp4', 'folder', ['/media/shared']));
    expect(store.highlighted('home', '/media/shared/movie.mp4'), true);
    expect(store.highlighted('home', '/media', folder: true), true);
    expect(store.highlighted('folder', '/media/shared/movie.mp4'), true);
    await store.relocate('/media/shared/movie.mp4', '/media/shared/renamed.mp4');
    expect(store.highlighted('home', '/media/shared/renamed.mp4'), true);
    expect(store.highlighted('folder', '/media/shared/renamed.mp4'), true);
    await store.forget('/media/shared', directory: true);
    expect(store.highlighted('home', '/media', folder: true), false);
    expect(store.highlighted('folder', '/media/shared/renamed.mp4'), false);
  });

  testWidgets('file and folder labels are blue in list and grid for both themes', (tester) async {
    await ResumeStore.instance.init();
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Scaffold(
            body: Wrap(
              children: [
                SizedBox(
                  width: 380,
                  child: VideoListTile(
                    resumeKey: 'test',
                    name: 'File list',
                    lastPlayed: true,
                    onTap: () {},
                    onChanged: () {},
                  ),
                ),
                SizedBox(
                  width: 380,
                  child: FolderListTile(name: 'Folder list', lastPlayed: true, onTap: () {}),
                ),
                SizedBox(
                  width: 180,
                  child: VideoGridTile(
                    resumeKey: 'test',
                    name: 'File grid',
                    lastPlayed: true,
                    onTap: () {},
                    onChanged: () {},
                  ),
                ),
                SizedBox(
                  width: 180,
                  child: FolderGridTile(name: 'Folder grid', lastPlayed: true, onTap: () {}),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final name in ['File list', 'Folder list', 'File grid', 'Folder grid']) {
        final finder = find.text(name);
        expect(tester.widget<Text>(finder).style!.color, lastPlayedColor(tester.element(finder)));
      }
    }
  });
}
