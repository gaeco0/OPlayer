import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/secure_store.dart';

enum ServerType { smb, ftp, sftp, webdav }

extension ServerTypeX on ServerType {
  String get label => switch (this) {
    ServerType.smb => 'SMB (Windows 공유)',
    ServerType.ftp => 'FTP',
    ServerType.sftp => 'SFTP (SSH)',
    ServerType.webdav => 'WebDAV',
  };
  int defaultPort(bool secure) => switch (this) {
    ServerType.smb => 445,
    ServerType.ftp => secure ? 990 : 21,
    ServerType.sftp => 22,
    ServerType.webdav => secure ? 443 : 80,
  };
}

class ServerConfig {
  ServerConfig({
    required this.id,
    required this.type,
    required this.name,
    required this.host,
    this.port,
    this.path = '/',
    this.username = '',
    this.domain = '',
    this.secure = false,
    this.useKey = false,
  });

  final String id;
  final ServerType type;
  String name;
  String host;
  int? port;
  String path;
  String username;
  String domain;
  bool secure;

  /// SFTP 개인 키 인증 (키는 SecureStore에 별도 저장)
  bool useKey;

  int get effectivePort => port ?? type.defaultPort(secure);
  String get passwordKey => 'pw_$id';

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'name': name,
    'host': host,
    'port': port,
    'path': path,
    'user': username,
    'domain': domain,
    'secure': secure,
    'key': useKey,
  };

  static ServerConfig fromJson(Map<String, dynamic> j) => ServerConfig(
    id: j['id'] as String,
    type: ServerType.values.byName(j['type'] as String),
    name: j['name'] as String,
    host: j['host'] as String,
    port: j['port'] as int?,
    path: (j['path'] as String?) ?? '/',
    username: (j['user'] as String?) ?? '',
    domain: (j['domain'] as String?) ?? '',
    secure: (j['secure'] as bool?) ?? false,
    useKey: (j['key'] as bool?) ?? false,
  );
}

enum CloudProvider { gdrive, dropbox, onedrive, plugin }

extension CloudProviderX on CloudProvider {
  String get label => switch (this) {
    CloudProvider.gdrive => 'Google Drive',
    CloudProvider.dropbox => 'Dropbox',
    CloudProvider.onedrive => 'OneDrive',
    CloudProvider.plugin => '클라우드 확장앱',
  };
}

class CloudAccount {
  CloudAccount({required this.id, required this.provider, required this.name, this.oauthClientId, this.pluginId});
  final String? pluginId;
  final String id;
  final CloudProvider provider;
  String name;

  String get tokenKey => 'tok_$id';
  final String? oauthClientId;

  Map<String, dynamic> toJson() => {
    'id': id,
    'p': provider.name,
    'n': name,
    'clientId': oauthClientId,
    'pluginId': pluginId,
  };
  static CloudAccount fromJson(Map<String, dynamic> j) => CloudAccount(
    id: j['id'] as String,
    provider: CloudProvider.values.byName(j['p'] as String),
    name: j['n'] as String,
    oauthClientId: j['clientId'] as String?,
    pluginId: j['pluginId'] as String?,
  );
}

/// 네트워크 서버·클라우드 계정 목록. 비밀번호/토큰은 SecureStore에 따로 저장.
class ServerStore extends ChangeNotifier {
  ServerStore._();
  static final instance = ServerStore._();

  static const _kServers = 'servers_v1';
  static const _kAccounts = 'cloud_accounts_v1';
  late SharedPreferences _prefs;

  final servers = <ServerConfig>[];
  final accounts = <CloudAccount>[];

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    for (final s in _prefs.getStringList(_kServers) ?? const <String>[]) {
      try {
        servers.add(ServerConfig.fromJson(jsonDecode(s) as Map<String, dynamic>));
      } catch (_) {}
    }
    for (final s in _prefs.getStringList(_kAccounts) ?? const <String>[]) {
      try {
        accounts.add(CloudAccount.fromJson(jsonDecode(s) as Map<String, dynamic>));
      } catch (_) {}
    }
  }

  static String newId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  ServerConfig? server(String id) => servers.where((s) => s.id == id).firstOrNull;
  CloudAccount? account(String id) => accounts.where((s) => s.id == id).firstOrNull;

  Future<void> saveServer(ServerConfig c, {String? password}) async {
    final i = servers.indexWhere((s) => s.id == c.id);
    if (i >= 0) {
      servers[i] = c;
    } else {
      servers.add(c);
    }
    if (password != null) await SecureStore.instance.write(c.passwordKey, password);
    await _persist();
  }

  Future<void> removeServer(ServerConfig c) async {
    servers.removeWhere((s) => s.id == c.id);
    await SecureStore.instance.delete(c.passwordKey);
    await SecureStore.instance.delete('sshkey_${c.id}');
    await _persist();
  }

  Future<void> saveAccount(CloudAccount a) async {
    final i = accounts.indexWhere((s) => s.id == a.id);
    if (i >= 0) {
      accounts[i] = a;
    } else {
      accounts.add(a);
    }
    await _persist();
  }

  Future<void> removeAccount(CloudAccount a) async {
    await SecureStore.instance.writeRequired(a.tokenKey, null);
    accounts.removeWhere((s) => s.id == a.id);
    await _persist();
  }

  Future<String> password(ServerConfig c) async => await SecureStore.instance.read(c.passwordKey) ?? '';

  Future<void> _persist() async {
    await _prefs.setStringList(_kServers, servers.map((e) => jsonEncode(e.toJson())).toList());
    await _prefs.setStringList(_kAccounts, accounts.map((e) => jsonEncode(e.toJson())).toList());
    notifyListeners();
  }
}
