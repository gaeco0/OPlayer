import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../network/network_service.dart';
import '../secure_store.dart';
import 'plugin.dart';
import 'plugin_runtime.dart';
import 'plugin_legacy_settings.dart';
import '../../sources/cloud/cloud_config.dart';

const defaultPluginRepository = 'https://raw.githubusercontent.com/gaeco0/OPlayer/main/plugins/repository.json';

class PluginListing {
  PluginListing(this.repository, this.data);
  final Uri repository;
  final Map<String, dynamic> data;
  String get id => data['id'] as String;
  String get name => data['name'] as String;
  String get version => data['version'] as String;
  String get description => data['description'] as String? ?? '';
  List<String> get features => (data['features'] as List? ?? []).cast<String>();
  String get author => data['author'] as String? ?? '';
  String get kind => switch (data['kind']) {
    'cloud' => 'resource',
    'site' => 'browser',
    'subtitle' => 'player',
    final String value => value,
    _ => '',
  };
  Uri get url => repository.resolve((data['downloadUrl'] ?? data['url']) as String);
}

class PluginStore extends ChangeNotifier {
  PluginStore._();
  @visibleForTesting
  PluginStore.forTesting();
  static final instance = PluginStore._();
  final Map<String, OPlugin> installed = {};
  final Set<String> disabled = {};
  final List<String> repositories = [];
  final Map<String, String> errors = {};
  final Map<String, String> repositoryNames = {};
  SharedPreferences? _prefs;
  Iterable<OPlugin> get enabled => installed.values.where((p) => !disabled.contains(p.id));
  OPlugin require(String id) {
    final p = installed[id];
    if (p == null || disabled.contains(id)) throw StateError('$id 확장앱을 설치하고 켜 주세요 (설정 → 확장앱)');
    return p;
  }

  // OAuth registration belongs to its extension; account-bound IDs stay unchanged.
  String oauthClientId(OPlugin plugin) =>
      _prefs?.getString('pluginOAuthClientId:${plugin.id}') ??
      plugin.oauth['clientId'] as String? ??
      (plugin.oauth['clientIdSource'] == 'app.google' ? CloudConfig.googleClientId : '');

  Future<void> setOAuthClientId(String id, String value) async {
    if (installed[id]?.cloud != true) throw StateError('설치된 클라우드 확장앱이 아닙니다');
    if (!await _prefs!.setString('pluginOAuthClientId:$id', value.trim())) {
      throw StateError('확장앱 설정을 저장하지 못했습니다');
    }
    notifyListeners();
  }

  static String oauthSecretKey(String id, String clientId) => 'pluginOAuthSecret:$id:$clientId';
  bool hasCredentials(String id) => _prefs?.getBool('pluginConfigured:$id') ?? false;
  Map<String, dynamic> publicSettings(OPlugin plugin) => plugin.publicConfig(
    (jsonDecode(_prefs?.getString('pluginSettings:${plugin.id}') ?? '{}') as Map).cast<String, dynamic>(),
  );
  Future<Map<String, dynamic>> credentials(String id) async {
    final plugin = installed[id];
    final defaults = {
      if (plugin?.oauth['clientIdSource'] == 'app.google')
        plugin!.oauth['clientIdSetting'] as String? ?? 'clientId': oauthClientId(plugin),
      ...await legacyPluginSettings(id),
    };
    if (!hasCredentials(id)) return defaults;
    final raw = await SecureStore.instance.readRequired('pluginCredentials:$id');
    return {...defaults, if (raw != null) ...(jsonDecode(raw) as Map).cast<String, dynamic>()};
  }

  Future<void> setCredentials(String id, Map<String, dynamic> values) async {
    final plugin = installed[id];
    if (plugin == null) throw StateError('설치된 확장앱이 아닙니다');
    await SecureStore.instance.writeRequired('pluginCredentials:$id', jsonEncode(values));
    if (!await _prefs!.setString('pluginSettings:$id', jsonEncode(plugin.publicConfig(values)))) {
      throw StateError('확장앱 설정 저장 실패');
    }
    if (!await _prefs!.setBool('pluginConfigured:$id', true)) throw StateError('확장앱 설정 저장 실패');
    notifyListeners();
  }

  Future<void> init() async {
    if (_prefs != null) return;
    _prefs = await SharedPreferences.getInstance();
    repositories.addAll(_prefs!.getStringList('pluginRepositories') ?? [defaultPluginRepository]);
    disabled.addAll(_prefs!.getStringList('disabledPlugins') ?? []);
    final sources = _prefs!.getStringList('plugins') ?? <String>[];
    for (final source in sources) {
      try {
        final p = await _settingsDefinition(OPlugin.parse(source));
        installed[p.id] = p;
      } catch (e) {
        errors['load'] = '$e';
      }
    }
  }

  Future<OPlugin> _settingsDefinition(OPlugin plugin) async {
    if (plugin.manifest.containsKey('settings')) return plugin;
    // Old installed scripts keep their executable code and permissions. Only
    // trusted bundled UI metadata fills in their pre-schema settings screen.
    try {
      final bundled = OPlugin.parse(await rootBundle.loadString('plugins/${plugin.id}.js'));
      if (bundled.id == plugin.id) {
        plugin.manifest['settings'] = bundled.manifest['settings'];
        plugin.manifest['setup'] = bundled.manifest['setup'];
        if (bundled.manifest['platforms'] != null) plugin.manifest['platforms'] = bundled.manifest['platforms'];
      }
    } catch (_) {}
    if (plugin.cloud && plugin.authType == 'oauth' && plugin.settings.isEmpty) {
      plugin.manifest['settings'] = [
        {'key': 'clientId', 'type': 'text', 'label': 'OAuth Client ID', 'required': true},
        if (plugin.oauth['requiresClientSecret'] == true)
          {'key': 'clientSecret', 'type': 'password', 'label': 'Client Secret', 'required': true},
      ];
    }
    return plugin;
  }

  Future<void> _save() async {
    await _prefs!.setStringList('plugins', installed.values.map((p) => p.source).toList());
    await _prefs!.setStringList('disabledPlugins', disabled.toList());
    await _prefs!.setStringList('pluginRepositories', repositories);
    notifyListeners();
  }

  Future<void> load(String source) async {
    final p = await _settingsDefinition(OPlugin.parse(source));
    await callPlugin(p, 'validate', {}, validateOnly: true);
    installed[p.id] = p;
    disabled.remove(p.id);
    errors.remove(p.id);
    await _save();
  }

  Future<void> setEnabled(String id, bool value) async {
    if (value) {
      disabled.remove(id);
    } else {
      disabled.add(id);
    }
    await _save();
  }

  Future<void> remove(String id) async {
    installed.remove(id);
    disabled.remove(id);
    errors.remove(id);
    await _save();
  }

  Future<void> addRepository(String url) async {
    final normalized = repositoryUri(url).toString();
    await listings(normalized); // Validate before saving; never execute or install here.
    if (!repositories.contains(normalized)) repositories.add(normalized);
    await _save();
  }

  Future<void> removeRepository(String url) async {
    repositories.remove(url);
    await _save();
  }

  Future<List<PluginListing>> listings(String url) async {
    final uri = repositoryUri(url);
    final body = await fetch(uri, 1024 * 1024);
    final json = jsonDecode(utf8.decode(body)) as Map;
    if (json['name'] is String) repositoryNames[url] = json['name'] as String;
    if (json['api'] != 1 || json['plugins'] is! List || (json['plugins'] as List).length > 200) {
      throw const FormatException('지원하지 않는 저장소 JSON');
    }
    return (json['plugins'] as List).map((item) {
      final data = (item as Map).cast<String, dynamic>();
      final listing = PluginListing(uri, data);
      if (data['features'] != null &&
          (data['features'] is! List || (data['features'] as List).any((v) => v is! String))) {
        throw const FormatException('잘못된 확장앱 기능 목록');
      }
      if (data['id'] is! String ||
          data['name'] is! String ||
          data['version'] is! String ||
          !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch('${data['sha256']}')) {
        throw const FormatException('잘못된 확장앱 목록');
      }
      if (data['kind'] != null && !OPlugin.contracts.containsKey(listing.kind)) {
        throw const FormatException('지원하지 않는 확장앱 유형');
      }
      final capabilities = data['capabilities'];
      if (capabilities != null &&
          (!OPlugin.contracts.containsKey(listing.kind) ||
              capabilities is! List ||
              capabilities.isEmpty ||
              capabilities.any((c) => !OPlugin.contracts[listing.kind]!.containsKey(c)) ||
              capabilities.toSet().length != capabilities.length)) {
        throw const FormatException('지원하지 않는 확장앱 기능 목록');
      }
      repositoryUri(listing.url.toString());
      return listing;
    }).toList();
  }

  Future<OPlugin> download(PluginListing listing) async {
    final bytes = await fetch(listing.url, 1024 * 1024);
    if (sha256.convert(bytes).toString() != '${listing.data['sha256']}'.toLowerCase()) {
      throw const FormatException('확장앱 SHA-256 불일치');
    }
    final p = OPlugin.parse(utf8.decode(bytes));
    if (p.id != listing.id || p.version != listing.version) throw const FormatException('목록과 확장앱 정보가 다릅니다');
    final capabilities = listing.data['capabilities'] as List?;
    if (listing.kind.isNotEmpty && listing.kind != p.kind ||
        capabilities != null &&
            (capabilities.length != p.capabilities.length || !capabilities.every(p.capabilities.contains)) ||
        listing.data['pluginApi'] != null && listing.data['pluginApi'] != p.manifest['api']) {
      throw const FormatException('목록과 확장앱 유형·기능이 다릅니다');
    }
    return p;
  }

  static Future<List<int>> fetch(Uri uri, int maxBytes) async {
    final client = IOClient(NetworkService.instance.createHttpClient());
    try {
      final response = await client
          .send(http.Request('GET', uri)..followRedirects = false)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) throw StateError('HTTP ${response.statusCode}');
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(const Duration(seconds: 20))) {
        bytes.addAll(chunk);
        if (bytes.length > maxBytes) throw const FormatException('확장앱 응답 크기 제한 초과');
      }
      return bytes;
    } finally {
      client.close();
    }
  }
}
