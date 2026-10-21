import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:oplayer/core/secure_store.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/settings/cloud_settings.dart';
import 'package:oplayer/features/settings/plugins_page.dart';
import 'package:oplayer/features/settings/settings_page.dart';
import 'package:oplayer/core/plugins/plugin.dart';
import 'package:oplayer/core/plugins/plugin_store.dart';
import 'package:oplayer/sources/cloud/cloud_sources.dart';
import 'package:oplayer/sources/server_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.init();
    await PluginStore.instance.init();
    PluginStore.instance.repositories.clear(); // No remote repository requests in widget tests.
    for (final id in ['box', 'mybox', 's3']) {
      await PluginStore.instance.load(await File('plugins/cloud.$id.js').readAsString());
    }
  });

  testWidgets('cloud setup validates and saves provider IDs and securely stores Google desktop secret', (tester) async {
    AppSettings.instance.dropboxAppKey = '';
    AppSettings.instance.oneDriveClientId = '';
    Future<void> open(String id) async {
      await tester.pumpWidget(MaterialApp(home: CloudPluginSettingsPage(pluginId: 'cloud.$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('앱 등록 정보'));
      await tester.pumpAndSettle();
    }

    await open('dropbox');
    await tester.pumpAndSettle();
    expect(find.text('com.oplayer.oplayer://oauth/dropbox'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), 'testappkey123');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(PluginStore.instance.oauthClientId(PluginStore.instance.installed['cloud.dropbox']!), 'testappkey123');
    await open('onedrive');
    await tester.enterText(find.byType(TextFormField), 'invalid');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(find.text('발급받은 Client ID를 확인해 주세요'), findsOneWidget);
    const id = '12345678-1234-1234-1234-123456789abc';
    await tester.enterText(find.byType(TextFormField), id);
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(PluginStore.instance.oauthClientId(PluginStore.instance.installed['cloud.onedrive']!), id);
    await AppSettings.instance.init();
    expect(PluginStore.instance.oauthClientId(PluginStore.instance.installed['cloud.onedrive']!), id);
    expect(PluginStore.instance.oauthClientId(PluginStore.instance.installed['cloud.dropbox']!), 'testappkey123');
    await open('gdrive');
    const googleId = '123-test.apps.googleusercontent.com';
    await tester.enterText(find.byType(TextFormField).first, googleId);
    await tester.enterText(find.byType(TextFormField).last, 'desktop-secret');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(PluginStore.instance.oauthClientId(PluginStore.instance.installed['cloud.gdrive']!), googleId);
    expect(
      await SecureStore.instance.readRequired(PluginStore.oauthSecretKey('cloud.gdrive', googleId)),
      'desktop-secret',
    );
    await AppSettings.instance.init();
    expect(PluginStore.instance.oauthClientId(PluginStore.instance.installed['cloud.gdrive']!), googleId);
    expect((await SharedPreferences.getInstance()).getString('settings_v1'), isNot(contains('desktop-secret')));
  });

  testWidgets('cloud registration belongs only to its extension, including when disabled', (tester) async {
    await PluginStore.instance.setCredentials('cloud.dropbox', {'clientId': 'existing-registration'});
    await tester.pumpWidget(MaterialApp(home: SettingsPage(onOpenDrawer: () {})));
    await tester.pump();
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    final labels = <String>{};
    do {
      labels.addAll(tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? ''));
      if (scroll.pixels >= scroll.maxScrollExtent) break;
      scroll.jumpTo((scroll.pixels + 350).clamp(0, scroll.maxScrollExtent));
      await tester.pump();
    } while (true);
    expect(labels, isNot(contains('클라우드 계정 연결')));
    for (final name in ['Google Drive', 'Dropbox', 'OneDrive']) {
      expect(labels, isNot(contains(name)));
    }
    final store = PluginStore.instance;
    await store.setEnabled('cloud.dropbox', false);
    await tester.pumpWidget(const MaterialApp(home: PluginsPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Dropbox 설정'));
    await tester.pumpAndSettle();
    expect(find.text('Dropbox 설정'), findsOneWidget);
    expect(find.textContaining('꺼진 확장앱입니다.'), findsOneWidget);
    expect(find.text('Google Drive'), findsNothing);
    expect(find.text('OneDrive'), findsNothing);
    await tester.tap(find.text('앱 등록 정보'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextFormField>(find.byType(TextFormField)).initialValue, 'existing-registration');
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    final plugin = store.installed['cloud.dropbox']!;
    await store.remove(plugin.id);
    await tester.pumpAndSettle();
    expect(find.text('확장앱이 설치되어 있지 않습니다'), findsOneWidget);
    expect(find.text('앱 등록 정보'), findsNothing);
    store.installed[plugin.id] = plugin;
    await store.setEnabled(plugin.id, true);
    expect(cloudPluginConfigured(plugin), true);
  });

  testWidgets('custom cloud registration persists per extension and is used by OAuth', (tester) async {
    OPlugin custom(String id) => OPlugin.parse(
      '// @oplayer ${jsonEncode({
        'api': 1,
        'id': id,
        'name': id,
        'version': '1.0.0',
        'kind': 'cloud',
        'hosts': ['cloud.example'],
        'oauth': {
          'authEndpoint': 'https://cloud.example/auth',
          'tokenEndpoint': 'https://cloud.example/token',
          'scopes': ['read'],
          'clientId': 'manifest-default',
        },
      })}\nglobalThis.plugin = {accountName(){},list(){},stream(){}};',
    );
    final store = PluginStore.instance;
    final first = custom('cloud.first');
    final second = custom('cloud.second');
    await store.load(first.source);
    await store.load(second.source);
    await tester.pumpWidget(MaterialApp(home: CloudPluginSettingsPage(pluginId: first.id)));
    await tester.tap(find.text('앱 등록 정보'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextFormField>(find.byType(TextFormField)).initialValue, 'manifest-default');
    await tester.enterText(find.byType(TextFormField), ' first-client ');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(store.oauthClientId(first), 'first-client');
    expect(store.oauthClientId(second), 'manifest-default');
    expect((await SharedPreferences.getInstance()).getString('pluginOAuthClientId:${first.id}'), 'first-client');
    expect(oauthClientFor(CloudProvider.plugin, pluginId: first.id).clientId, 'first-client');
    expect(
      oauthClientFor(CloudProvider.plugin, pluginId: first.id, clientId: 'account-bound').clientId,
      'account-bound',
    );
    await store.setEnabled(first.id, false);
    expect(() => oauthClientFor(CloudProvider.plugin, pluginId: first.id), throwsStateError);
    await store.remove(first.id);
    store.installed[first.id] = first;
    expect(store.oauthClientId(first), 'first-client');
    await store.remove(first.id);
    await store.remove(second.id);
  });

  testWidgets('MYBOX token and Box secret are configured inside their own extension and stored securely', (
    tester,
  ) async {
    final store = PluginStore.instance;
    await tester.pumpWidget(const MaterialApp(home: CloudPluginSettingsPage(pluginId: 'cloud.mybox')));
    await tester.tap(find.text('연결 설정'));
    await tester.pumpAndSettle();
    expect(find.text('OAuth Client ID'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField).last).obscureText, true);
    await tester.enterText(find.byType(TextFormField).last, 'test-mybox-pat');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(store.hasCredentials('cloud.mybox'), true);
    expect((await store.credentials('cloud.mybox'))['accessToken'], 'test-mybox-pat');
    expect(find.text('설정됨'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: CloudPluginSettingsPage(pluginId: 'cloud.box')));
    await tester.tap(find.text('앱 등록 정보'));
    await tester.pumpAndSettle();
    expect(find.textContaining('http://localhost:53682/callback'), findsOneWidget);
    expect(find.textContaining('com.oplayer.oplayer://oauth/box'), findsNothing);
    await tester.enterText(find.byType(TextFormField).first, 'test-box-client');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(find.text('Client Secret 값을 입력해 주세요'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).last, 'test-box-client-secret');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(store.oauthClientId(store.installed['cloud.box']!), 'test-box-client');
    expect(
      await SecureStore.instance.readRequired(PluginStore.oauthSecretKey('cloud.box', 'test-box-client')),
      'test-box-client-secret',
    );
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys()) {
      expect(jsonEncode(prefs.get(key)), isNot(contains('test-box-client-secret')));
      expect(jsonEncode(prefs.get(key)), isNot(contains('test-mybox-pat')));
    }
  });
}
