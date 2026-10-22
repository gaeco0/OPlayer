import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oplayer/app/theme.dart';
import 'package:oplayer/core/media_utils.dart';
import 'package:oplayer/core/resume_store.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/browser/home_screen.dart';
import 'package:oplayer/features/settings/settings_page.dart';
import 'package:oplayer/features/player/player_controller.dart';
import 'package:oplayer/features/web/download_manager.dart';
import 'package:oplayer/sources/server_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('formatters', () {
    expect(formatDuration(const Duration(seconds: 75)), '01:15');
    expect(formatDuration(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
    expect(fmtRate(1.0), '1.0');
    expect(fmtRate(1.25), '1.25');
    expect(fmtRate(1.5), '1.5');
    expect(siblingSubtitles('/a/Movie.mkv', ['/a/Movie.ko.srt', '/a/Other.srt', '/a/movie.smi']).length, 2);
    final l = ['EP10.mkv', 'EP2.mkv', 'ep1.mkv']..sort(naturalCompare);
    expect(l, ['ep1.mkv', 'EP2.mkv', 'EP10.mkv']);
  });

  testWidgets('home renders sidebar (wide) and drawer (narrow)', (t) async {
    SharedPreferences.setMockInitialValues({});
    await ResumeStore.instance.init();
    final folder = (await t.runAsync(() async {
      final folder = await Directory.systemTemp.createTemp('oplayer_navigation_');
      await Directory('${folder.path}/nested-test').create();
      return folder;
    }))!;
    addTearDown(() => folder.delete(recursive: true));
    await ResumeStore.instance.addFolder(folder.path);
    await AppSettings.instance.init();
    await ServerStore.instance.init();
    await DownloadManager.instance.init();
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    await t.pumpWidget(MaterialApp(theme: OTheme.dark(), home: const HomeScreen()));
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('OPlayer'), findsOneWidget);
    expect(find.text('최근 재생'), findsOneWidget);
    expect(find.text('UPnP / DLNA 검색'), findsOneWidget);
    expect(find.text('설치한 클라우드 확장앱'), findsOneWidget);
    final home = find.widgetWithText(ListTile, '홈 폴더');
    await t.tap(find.descendant(of: home, matching: find.byType(PopupMenuButton<int>)));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.text('이 리소스 잠금'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('공통 잠금 방식 선택'), findsOneWidget);
    t.state<NavigatorState>(find.byType(Navigator).first).pop();
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.text(p.basename(folder.path)));
    for (var i = 0; i < 20 && find.text('nested-test').evaluate().isEmpty; i++) {
      await t.pump(const Duration(milliseconds: 20));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    await t.tap(find.text('nested-test'));
    await t.pump();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    t.view.physicalSize = const Size(400, 800);
    await t.pump();
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.byIcon(Icons.menu), findsOneWidget);
    await t.tap(find.byIcon(Icons.menu));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(Drawer).hitTestable(), findsOneWidget);
    await t.tap(find.text('최근 재생'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    t.view.physicalSize = const Size(1400, 900);
    await t.pump();
    expect(find.text('재생 기록이 없습니다'), findsOneWidget);
    await t.tap(find.text('설정'));
    await t.pump();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500))); // ffmpeg 탐색(실제 프로세스)
    await t.pump();
    await t.scrollUntilVisible(
      find.text('더블탭 탐색 간격'),
      200,
      scrollable: find.descendant(of: find.byType(SettingsPage), matching: find.byType(Scrollable)).first,
    );
    expect(find.text('더블탭 탐색 간격'), findsOneWidget);
    await t.tap(find.text('다운로드').first);
    await t.pump();
    expect(find.textContaining('다운로드한 파일이 없습니다'), findsOneWidget);
    t.view.physicalSize = const Size(400, 800);
    await t.pump();
    expect(find.byIcon(Icons.menu), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 5));
    t.view.reset();
  });
}
