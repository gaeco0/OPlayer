import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/plugins/plugin.dart';
import 'package:oplayer/core/plugins/plugin_runtime.dart';
import 'package:oplayer/core/plugins/plugin_store.dart';
import 'package:oplayer/core/secure_store.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/settings/cloud_settings.dart';
import 'package:oplayer/sources/cloud/cloud_sources.dart';
import 'package:oplayer/sources/server_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final store = PluginStore.instance;
  late OPlugin plugin;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await AppSettings.instance.init();
    await store.init();
    await ServerStore.instance.init();
    final source = (await File(
      'plugins/examples/cloud.custom.example.js',
    ).readAsString()).replaceFirst('cloud.custom.example', 'cloud.never.registered');
    await store.load(source);
    plugin = store.installed['cloud.never.registered']!;
  });

  testWidgets('an unknown extension supplies its entire settings UI and private/public persistence', (t) async {
    await t.pumpWidget(MaterialApp(home: CloudPluginSettingsPage(pluginId: plugin.id)));
    await t.tap(find.text('연결 설정'));
    await t.pumpAndSettle();
    expect(find.text('서버 주소'), findsOneWidget);
    expect(find.text('사용자 이름'), findsOneWidget);
    expect(find.text('비밀번호'), findsOneWidget);
    expect(t.widget<TextField>(find.byType(TextField).last).obscureText, true);
    await t.enterText(find.byType(TextFormField).at(0), 'https://custom.example/api');
    await t.enterText(find.byType(TextFormField).at(1), 'test-account');
    await t.enterText(find.byType(TextFormField).at(2), 'test-password');
    await t.tap(find.text('숨김 항목 포함'));
    await t.pump();
    await t.tap(find.text('저장'));
    await t.pumpAndSettle();
    final config = store.publicSettings(plugin);
    expect(config['account'], 'test-account');
    expect(config['includeHidden'], true);
    expect(config.containsKey('password'), false);
    expect((await store.credentials(plugin.id))['password'], 'test-password');
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys()) {
      expect(jsonEncode(prefs.get(key)), isNot(contains('test-password')));
    }
  });

  test(
    'a newly loaded provider logs in, stores opaque session state, signs and renews requests without native registration',
    () async {
      await store.setCredentials(plugin.id, {
        'endpoint': 'https://custom.example/api',
        'account': 'test-account',
        'password': 'test-password',
        'collection': 'all',
        'includeHidden': true,
      });
      var logins = 0, lists = 0, requests = 0;
      await http.runWithClient(
        () async {
          final account = await connectCloudAccount(CloudProvider.plugin, pluginId: plugin.id);
          expect(account.name, 'Custom Account');
          final source = cloudSourceFor(account);
          addTearDown(source.close);
          final rows = await source.list('root');
          expect(rows.single.name, 'movie.mp4');
          expect(logins, 2);
          expect(lists, 2);
          final state = jsonDecode((await SecureStore.instance.readRequired(account.tokenKey))!) as Map;
          expect(state['sessionKey'], 'session-2');
          final stream = await source.streamFor('file-1');
          expect(stream.url, 'https://cdn.example/movie.mp4');
          expect(stream.headers, null);
          final original = store.installed[plugin.id]!;
          final firstLine = original.source.split('\n').first;
          final meta = (jsonDecode(firstLine.substring(12)) as Map<String, dynamic>)..['hosts'] = ['cdn.example'];
          store.installed[plugin.id] = OPlugin.parse(
            original.source
                .replaceFirst(firstLine, '// @oplayer ${jsonEncode(meta)}')
                .replaceFirst("OPlayer.config.endpoint + '/profile'", "'https://cdn.example/profile'"),
          );
          final before = requests;
          try {
            await expectLater(source.accountName(), throwsStateError);
            expect(requests, before); // A declared network host is not automatically an authentication host.
          } finally {
            store.installed[plugin.id] = original;
          }
          final prefs = await SharedPreferences.getInstance();
          for (final key in prefs.getKeys()) {
            expect(jsonEncode(prefs.get(key)), isNot(contains('session-2')));
          }
          await ServerStore.instance.removeAccount(account);
          await expectLater(source.list('root'), throwsStateError);
        },
        () => MockClient((r) async {
          requests++;
          expect(r.url.origin, 'https://custom.example');
          expect(r.followRedirects, false);
          expect(r.headers.containsKey('Authorization'), false);
          if (r.url.path == '/api/session') {
            logins++;
            expect(r.bodyFields, {'account': 'test-account', 'password': 'test-password'});
            return http.Response(jsonEncode({'sessionKey': 'session-$logins'}), 200);
          }
          expect(r.headers['X-Session'], 'session-$logins');
          if (r.url.path == '/api/profile') return http.Response('{"name":"Custom Account"}', 200);
          if (r.url.path == '/api/files') {
            lists++;
            final expected = Hmac(sha256, utf8.encode('session-$logins')).convert(utf8.encode('list:all')).toString();
            expect(r.headers['X-Proof'], expected);
            expect(r.url.queryParameters, {'collection': 'all', 'hidden': 'true'});
            if (lists == 1) return http.Response('{"error":"expired"}', 401);
            return http.Response('{"entries":[{"name":"movie.mp4","id":"file-1","size":100}]}', 200);
          }
          return http.Response('{"url":"https://cdn.example/movie.mp4"}', 200);
        }),
      );
    },
  );

  test('configurable endpoints, schema and crypto remain bounded', () async {
    final config = {'endpoint': 'https://custom.example/api'};
    for (final url in [
      'https://custom.example/api2',
      'https://custom.example.evil/api',
      'https://user@custom.example/api',
      'http://custom.example/api',
      'https://other.example/api',
    ]) {
      expect(plugin.allowsConfigured(url, config), false);
    }
    expect(plugin.allowsConfigured('https://custom.example/api/files', config, auth: true), true);
    final modified = plugin.source.replaceFirst(
      "OPlayer.config.endpoint + '/profile'",
      "'https://other.example/profile'",
    );
    final bad = OPlugin.parse(modified);
    var sent = false;
    await expectLater(
      callPlugin(
        bad,
        'accountName',
        {},
        config: config,
        allowsRequest: (url) => bad.allowsConfigured(url, config),
        request: (_, __) async {
          sent = true;
          return {};
        },
      ),
      throwsStateError,
    );
    expect(sent, false);
    expect(
      () => OPlugin.parse(plugin.source.replaceFirst('"type":"password"', '"type":"password","default":"unsafe"')),
      throwsFormatException,
    );
    expect(
      () => OPlugin.parse(plugin.source.replaceFirst('"authSettings":["endpoint"]', '"authSettings":["password"]')),
      throwsFormatException,
    );
    final hashSource = plugin.source.replaceFirst(
      'globalThis.plugin = {',
      "globalThis.plugin = {hash(){return OPlayer.crypto.hash('sha256','abc')},",
    );
    expect(
      await callPlugin(OPlugin.parse(hashSource), 'hash', {}),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });
}
