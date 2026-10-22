import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/browser/video_tile.dart';

void main() {
  testWidgets('remote list menu and grid button download without opening player', (t) async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.init();
    var downloads = 0;
    var plays = 0;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoListTile(
            resumeKey: 'webdav://server/video.mp4',
            name: 'video.mp4',
            onTap: () => plays++,
            onChanged: () {},
            onDownload: () => downloads++,
          ),
        ),
      ),
    );
    await t.tap(find.byIcon(Icons.more_vert));
    await t.pumpAndSettle();
    await t.tap(find.text('기기에 다운로드'));
    await t.pumpAndSettle();
    expect(downloads, 1);
    expect(plays, 0);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 220,
            height: 240,
            child: VideoGridTile(
              resumeKey: 'webdav://server/video.mp4',
              name: 'video.mp4',
              onTap: () => plays++,
              onChanged: () {},
              onDownload: () => downloads++,
            ),
          ),
        ),
      ),
    );
    await t.tap(find.byTooltip('기기에 다운로드'));
    await t.pump();
    expect(downloads, 2);
    expect(plays, 0);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoListTile(resumeKey: '/local/video.mp4', name: 'video.mp4', onTap: () {}, onChanged: () {}),
        ),
      ),
    );
    await t.tap(find.byIcon(Icons.more_vert));
    await t.pumpAndSettle();
    expect(find.text('기기에 다운로드'), findsNothing);
    await t.pumpWidget(const SizedBox());
    await t.pumpAndSettle();
  });
}
