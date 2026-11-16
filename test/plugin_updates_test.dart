import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/plugins/plugin.dart';
import 'package:oplayer/core/plugins/plugin_store.dart';
import 'package:oplayer/core/plugins/plugin_updates.dart';
import 'package:oplayer/core/app_updater.dart';
import 'package:oplayer/core/mouse_nav.dart';
import 'package:oplayer/core/resource_locks.dart';
import 'package:oplayer/app/media_shell.dart';
import 'package:oplayer/features/settings/plugins_page.dart';

OPlugin sample(String id, String version) => OPlugin.parse(
  '// @oplayer ${jsonEncode({
    'api': 4,
    'id': id,
    'version': version,
    'name': id,
    'kind': 'player',
    'capabilities': ['videoFilter'],
    'hosts': [],
  })}\nglobalThis.plugin={videoFilter(){return {contrast:0}}};',
);
PluginListing listing(String id, String version, {List<String>? platforms}) =>
    PluginListing(Uri.parse('https://example.com/repository.json'), {
      'id': id,
      'name': id,
      'version': version,
      'kind': 'player',
      'pluginApi': 4,
      if (platforms != null) 'platforms': platforms,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('only newer versions notify, including numeric versions and release promotion', () {
    expect(newerPluginVersion('1.10.0', '1.9.9'), true);
    expect(newerPluginVersion('1.1', '1.0.9'), true);
    expect(newerPluginVersion('1.0.0', '1.0.0-beta.2'), true);
    expect(newerPluginVersion('1.0.0-beta.10', '1.0.0-beta.9'), true);
    expect(newerPluginVersion('1.0.0+other', '1.0.0+build'), false);
    expect(newerPluginVersion('1.0.0-beta.1', '1.0.0'), false);
    expect(newerPluginVersion('0.9.0', '1.0.0'), false);
    expect(newerPluginVersion('invalid', '1.0.0'), false);
    expect(newerPluginVersion('9999999999999999999999999.0.0', '1.0.0'), false);
  });

  test('check deduplicates repositories, ignores incompatible/uninstalled entries and keeps offline results', () async {
    final store = PluginStore.forTesting()
      ..repositories.addAll(['https://example.com/first', 'https://example.com/second'])
      ..installed['test.available'] = sample('test.available', '1.0.0')
      ..installed['test.incompatible'] = sample('test.incompatible', '1.0.0');
    var now = DateTime(2026, 11, 16);
    var requests = 0;
    var offline = false;
    final gate = Completer<void>();
    final updates = PluginUpdates(
      store,
      now: () => now,
      listings: (url) async {
        requests++;
        await gate.future;
        if (offline) throw const SocketException('offline');
        return [
          listing('test.available', url.endsWith('first') ? '1.1.0' : '1.2.0'),
          listing('test.notinstalled', '9.0.0'),
          listing('test.incompatible', '2.0.0', platforms: [Platform.isAndroid ? 'windows' : 'android']),
        ];
      },
    );
    final first = updates.check();
    final repeated = updates.check();
    gate.complete();
    await Future.wait([first, repeated]);
    expect(requests, 2);
    expect(updates.available.single.version, '1.2.0');
    await updates.check();
    expect(requests, 2);
    offline = true;
    now = now.add(const Duration(hours: 2));
    await updates.check();
    expect(updates.available.single.version, '1.2.0');
    store.installed['test.available'] = sample('test.available', '1.2.0');
    expect(updates.available, isEmpty);
  });

  testWidgets('update toast opens filtered extensions and does not repeat for the same version', (tester) async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({'appUpdateAutomatic': false, 'pluginRepositories': <String>[]});
    FlutterSecureStorage.setMockInitialValues({});
    await ResourceLocks.instance.init();
    final store = PluginStore.instance;
    await store.init();
    final installed = sample('test.toast', '1.0.0');
    store.installed[installed.id] = installed;
    final server = (await tester.runAsync(() async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((request) async {
        request.response.write(
          jsonEncode({
            'api': 1,
            'plugins': [
              {
                'id': installed.id,
                'name': 'Test Toast',
                'version': '1.1.0',
                'kind': 'player',
                'pluginApi': 4,
                'sha256': '0' * 64,
                'url': 'https://example.com/plugin.js',
              },
            ],
          }),
        );
        await request.response.close();
      });
      return server;
    }))!;
    addTearDown(() => server.close(force: true));
    store.repositories.add('http://127.0.0.1:${server.port}/repo');
    AppUpdater.instance.automatic = false;
    await tester.runAsync(() => PluginUpdates.instance.check(force: true));
    expect(PluginUpdates.instance.available.single.name, 'Test Toast');
    expect(ResourceLocks.instance.shielded, false);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: MouseNav.navigatorKey,
        builder: (context, child) => MediaShell(child: child!),
        home: const Scaffold(body: Text('home')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Test Toast 1.1.0 업데이트가 있습니다'), findsOneWidget);
    await tester.pumpAndSettle();
    await tester.tap(find.text('업데이트 보기'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PluginsPage), findsOneWidget);
    expect(tester.widget<PluginsPage>(find.byType(PluginsPage)).updatesOnly, true);
    await tester.pump(const Duration(seconds: 13));
    await tester.pumpAndSettle();
    await tester.runAsync(() => store.setEnabled(installed.id, false));
    await tester.pumpAndSettle();
    expect(find.text('Test Toast 1.1.0 업데이트가 있습니다'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 15));
    await tester.runAsync(() => server.close(force: true));
    expect(tester.takeException(), isNull);
  });
}
