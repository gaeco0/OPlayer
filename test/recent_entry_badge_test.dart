import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oplayer/features/browser/video_tile.dart';

void main() {
  test('recent entry window is three days and excludes missing or future dates', () {
    final now = DateTime.utc(2026, 11, 16, 12);
    expect(isRecentEntry(now.subtract(const Duration(days: 2, hours: 23)), now: now), true);
    expect(isRecentEntry(now.subtract(const Duration(days: 3)), now: now), false);
    expect(isRecentEntry(now.add(const Duration(seconds: 1)), now: now), false);
    expect(isRecentEntry(null, now: now), false);
  });

  testWidgets('file and folder names show red dots in list and grid without losing their text', (tester) async {
    final recent = DateTime.now().subtract(const Duration(days: 2));
    final old = DateTime.now().subtract(const Duration(days: 4));
    for (final date in [recent, old]) {
      final tiles = [
        VideoListTile(resumeKey: 'badge-video', name: 'video.mp4', recentAt: date, onTap: () {}, onChanged: () {}),
        VideoGridTile(resumeKey: 'badge-video', name: 'video.mp4', recentAt: date, onTap: () {}, onChanged: () {}),
        FolderListTile(name: 'folder', recentAt: date, onTap: () {}),
        FolderGridTile(name: 'folder', recentAt: date, onTap: () {}),
      ];
      for (final tile in tiles) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: 260, child: tile),
              ),
            ),
          ),
        );
        expect(find.byIcon(Icons.circle), date == recent ? findsOneWidget : findsNothing);
        expect(tester.takeException(), isNull);
      }
    }
  });
}
