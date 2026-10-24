import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oplayer/core/diagnostic_report.dart';
import 'package:oplayer/features/settings/issue_report_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('diagnostic collection excludes URLs, file names and credentials, even in unexpected native fields', () async {
    final text = await DiagnosticReport.collect(
      orientation: {
        'sdk': 37,
        'targetSdk': 36,
        'requestedOrientation': 6,
        'configurationOrientation': 1,
        'model': 'Fold test',
        'Authorization': 'private-token',
        'file': '/private/movie.mp4',
        'url': 'https://private.invalid/?token=secret',
        'application.secret': 'private-key',
        'application.PROPERTY_COMPAT_IGNORE_REQUESTED_ORIENTATION': false,
      },
    );
    final data = jsonDecode(text) as Map;
    expect(data['screen']['sdk'], 37);
    expect(data['screen']['requestedOrientation'], 6);
    expect(data['screen']['configurationOrientation'], 1);
    expect(data['screen']['application.PROPERTY_COMPAT_IGNORE_REQUESTED_ORIENTATION'], false);
    expect(text, isNot(contains('private')));
    expect(text, isNot(contains('secret')));
    expect(text, isNot(contains('movie.mp4')));
  });

  testWidgets('issue form validates, previews optional diagnostics and opens a prefilled GitHub issue', (tester) async {
    tester.view.physicalSize = const Size(1000, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final urls = <Uri>[];
    String? clipboard;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String;
      if (call.method == 'Clipboard.getData') return {'text': clipboard};
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/url_launcher'), (call) async {
      if (call.method == 'launch') {
        urls.add(Uri.parse((call.arguments as Map)['url'] as String));
        return true;
      }
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/url_launcher'), null));
    await tester.pumpWidget(const MaterialApp(home: IssueReportPage(orientation: {'sdk': 37, 'model': 'Fold test'})));
    await tester.pumpAndSettle();
    expect(find.text('진단 정보 보내기'), findsOneWidget);
    await tester.ensureVisible(find.text('GitHub 이슈 작성'));
    await tester.tap(find.text('GitHub 이슈 작성'));
    await tester.pumpAndSettle();
    expect(urls, isEmpty);
    expect(find.text('증상을 입력해 주세요'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).at(1), '펼친 화면에서 회전이 안 됩니다 & 테스트');
    await tester.ensureVisible(find.text('진단 정보 미리보기'));
    await tester.tap(find.text('진단 정보 미리보기'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Fold test'), findsOneWidget);
    await tester.ensureVisible(find.text('GitHub 이슈 작성'));
    await tester.tap(find.text('GitHub 이슈 작성'));
    await tester.pumpAndSettle();
    expect(urls.single.host, 'github.com');
    expect(urls.single.path, '/gaeco0/OPlayer/issues/new');
    expect(urls.single.queryParameters['title'], '화면 회전 문제');
    expect(urls.single.queryParameters['body'], contains('Fold test'));
    expect(urls.single.queryParameters['body'], contains('& 테스트'));

    await tester.ensureVisible(find.text('진단 정보 포함'));
    await tester.tap(find.text('진단 정보 포함'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('GitHub 이슈 작성'));
    await tester.tap(find.text('GitHub 이슈 작성'));
    await tester.pumpAndSettle();
    expect(urls.last.queryParameters['body'], isNot(contains('Fold test')));
    expect(urls.last.queryParameters['body'], isNot(contains('진단 정보')));

    await tester.enterText(find.byType(TextFormField).at(1), List.filled(1000, '재현').join());
    await tester.ensureVisible(find.text('GitHub 이슈 작성'));
    await tester.tap(find.text('GitHub 이슈 작성'));
    await tester.pumpAndSettle();
    expect(find.text('본문 복사 완료'), findsOneWidget);
    expect((await Clipboard.getData(Clipboard.kTextPlain))!.text, contains(List.filled(1000, '재현').join()));
    await tester.tap(find.text('GitHub 열기'));
    await tester.pumpAndSettle();
    expect(urls.last.queryParameters.containsKey('body'), false);
  });
}
