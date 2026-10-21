import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/settings/cloud_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('cloud setup validates and saves public app IDs; Google stays unavailable', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.init();
    AppSettings.instance.dropboxAppKey = '';
    AppSettings.instance.oneDriveClientId = '';
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: CloudSettings())));
    final google = tester.widget<ListTile>(
      find.ancestor(of: find.text('Google Drive'), matching: find.byType(ListTile)),
    );
    expect(google.enabled, false);
    await tester.tap(find.text('Dropbox'));
    await tester.pumpAndSettle();
    expect(find.text('com.oplayer.oplayer://oauth/dropbox'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), 'testappkey123');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(AppSettings.instance.dropboxAppKey, 'testappkey123');
    await tester.tap(find.text('OneDrive'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'invalid');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(find.text('발급받은 Client ID를 확인해 주세요'), findsOneWidget);
    const id = '12345678-1234-1234-1234-123456789abc';
    await tester.enterText(find.byType(TextFormField), id);
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(AppSettings.instance.oneDriveClientId, id);
    await AppSettings.instance.init();
    expect(AppSettings.instance.oneDriveClientId, id);
    expect(AppSettings.instance.dropboxAppKey, 'testappkey123');
  });
}
