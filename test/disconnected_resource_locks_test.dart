import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/resource_locks.dart';
import 'package:oplayer/core/secure_store.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/core/plugins/plugin_store.dart';
import 'package:oplayer/sources/server_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final store = ServerStore.instance;
  final locks = ResourceLocks.instance;
  final hash = base64Encode(List<int>.filled(32, 1));
  Future<void> seed(Map<String, String> resources) async {
    await SecureStore.instance.writeRequired(
      ResourceLocks.storageKey,
      jsonEncode({
        'salt': hash,
        'hash': hash,
        'patternSalt': hash,
        'patternHash': hash,
        'resources': {for (final entry in resources.entries) resourceKey(entry.key): entry.value},
        'biometric': true,
        'appLock': true,
      }),
    );
    await locks.init();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    store.servers.clear();
    store.accounts.clear();
    await store.init();
    await AppSettings.instance.init();
    await locks.init();
  });
  test('disconnect removes only that account namespace and persists shared credentials unchanged', () async {
    final removed = CloudAccount(id: 'account', provider: CloudProvider.gdrive, name: 'Removed');
    final kept = CloudAccount(id: 'account-other', provider: CloudProvider.gdrive, name: 'Keep');
    await store.saveAccount(removed);
    await store.saveAccount(kept);
    await SecureStore.instance.writeRequired(removed.tokenKey, 'old-token');
    await seed({
      'gdrive://account': 'Removed',
      'gdrive://account/private/file.mp4': 'Nested',
      'gdrive://account-other': 'Keep',
      recentResourceKey: 'Recent',
      'C:/Movies/private': 'Local',
    });
    await store.removeAccount(removed);
    expect(locks.hasExact('gdrive://account'), false);
    expect(locks.hasExact('gdrive://account/private/file.mp4'), false);
    expect(locks.hasExact('gdrive://account-other'), true);
    expect(locks.hasExact(recentResourceKey), true);
    expect(locks.hasExact('C:/Movies/private'), true);
    expect(await SecureStore.instance.readRequired(removed.tokenKey), null);
    final saved = jsonDecode((await SecureStore.instance.readRequired(ResourceLocks.storageKey))!) as Map;
    for (final key in ['salt', 'hash', 'patternSalt', 'patternHash']) {
      expect(saved[key], hash);
    }
    expect(saved['biometric'], true);
    expect(saved['appLock'], true);
    await locks.init();
    expect(locks.hasExact('gdrive://account'), false);
    expect(locks.hasPin, true);
    expect(locks.hasPattern, true);
  });
  test('each network server deletion clears root and descendants without clearing sibling connections', () async {
    final servers = [
      for (final type in ServerType.values)
        ServerConfig(id: 'id-${type.name}', type: type, name: type.name, host: 'nas.example'),
    ];
    for (final server in servers) {
      await store.saveServer(server);
    }
    final roots = {for (final server in servers) serverResourceKey(server): server.name};
    await seed({
      ...roots,
      for (final entry in roots.entries) '${entry.key}/private': entry.value,
      recentResourceKey: 'Recent',
    });
    for (final server in servers) {
      final root = serverResourceKey(server);
      await store.removeServer(server);
      expect(locks.hasExact(root), false);
      expect(locks.hasExact('$root/private'), false);
      for (final kept in store.servers) {
        expect(locks.hasExact(serverResourceKey(kept)), true);
      }
    }
    expect(locks.hasExact(recentResourceKey), true);
  });
  test('startup repair removes legacy disconnected IDs while preserving registered and independent locks', () async {
    await store.saveAccount(
      CloudAccount(
        id: 'registered',
        provider: CloudProvider.plugin,
        name: 'Disabled extension account',
        pluginId: 'missing.plugin',
      ),
    );
    await store.saveServer(ServerConfig(id: 'nas', type: ServerType.webdav, name: 'NAS', host: 'nas.example'));
    await seed({
      'gdrive://old': 'Old',
      'gdrive://old/private': 'Old nested',
      'webdav://old': 'Old NAS',
      'plugin://old/file': 'Old extension',
      'plugin://registered': 'Registered',
      'webdav://nas/private': 'Registered nested',
      recentResourceKey: 'Recent',
      downloadsResourceKey: 'Downloads',
      playlistsResourceKey: 'Playlists',
      playlistResourceKey('movie'): 'Movie playlist',
      'C:/Movies': 'Local',
      'https://media.example/private': 'Direct URL',
    });
    await locks.pruneDisconnectedConnections();
    expect(
      locks.resources.keys,
      unorderedEquals([
        'plugin://registered',
        'webdav://nas/private',
        recentResourceKey,
        downloadsResourceKey,
        playlistsResourceKey,
        playlistResourceKey('movie'),
        resourceKey('C:/Movies'),
        'https://media.example/private',
      ]),
    );
    await locks.init();
    expect(locks.hasExact('gdrive://old'), false);
    expect(locks.biometricEnabled, true);
    await SecureStore.instance.writeRequired(ResourceLocks.storageKey, 'unreadable');
    await locks.init();
    expect(locks.unavailable, true);
    await expectLater(locks.pruneDisconnectedConnections(), throwsStateError);
    expect(await SecureStore.instance.readRequired(ResourceLocks.storageKey), 'unreadable');
  });
  test('uninstalling a resource extension also clears its disconnected account locks', () async {
    final plugins = PluginStore.instance;
    await plugins.init();
    await plugins.load(
      '// @oplayer ${jsonEncode({
            'api': 4,
            'id': 'test.cleanup',
            'name': 'Cleanup',
            'version': '1',
            'kind': 'resource',
            'capabilities': ['storage'],
            'hosts': <String>[],
            'auth': {'type': 'bearer'},
            'settings': <Object>[],
          })}\nglobalThis.plugin={accountName(){return "test"},list(){return []},stream(){return null}};',
    );
    final account = CloudAccount(
      id: 'plugin-account',
      provider: CloudProvider.plugin,
      name: 'Plugin',
      pluginId: 'test.cleanup',
    );
    await store.saveAccount(account);
    await seed({
      'plugin://plugin-account': 'Plugin',
      'plugin://plugin-account/folder': 'Nested',
      recentResourceKey: 'Recent',
    });
    await plugins.remove('test.cleanup');
    expect(store.account(account.id), null);
    expect(locks.resources, {recentResourceKey: 'Recent'});
  });
}
