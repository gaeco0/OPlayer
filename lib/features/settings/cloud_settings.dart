import 'dart:io';
import 'package:flutter/material.dart';
import '../../core/settings.dart';
import '../../core/plugins/plugin.dart';
import '../../core/plugins/plugin_store.dart';
import '../../sources/cloud/cloud_config.dart';
import '../../sources/server_store.dart';
import 'plugin_settings_dialog.dart';

CloudProvider cloudPluginProvider(OPlugin plugin) =>
    CloudProvider.values.firstWhere((p) => plugin.id == 'cloud.${p.name}', orElse: () => CloudProvider.plugin);

bool cloudPluginConfigured(OPlugin plugin) {
  final store = PluginStore.instance;
  if (store.hasCredentials(plugin.id)) return true;
  if (plugin.authType != 'oauth') return false;
  if (store.oauthClientId(plugin).isNotEmpty) return true;
  // Compatibility for registrations created before extension-owned settings.
  return switch (cloudPluginProvider(plugin)) {
    CloudProvider.dropbox => CloudConfig.dropboxAppKey.isNotEmpty,
    CloudProvider.onedrive => CloudConfig.oneDriveClientId.isNotEmpty,
    CloudProvider.gdrive =>
      Platform.isAndroid ? CloudConfig.googleAndroidClientId.isNotEmpty : CloudConfig.googleDesktopClientId.isNotEmpty,
    _ => false,
  };
}

class CloudPluginSettingsPage extends StatelessWidget {
  const CloudPluginSettingsPage({super.key, required this.pluginId, this.forConnection = false});
  final String pluginId;
  final bool forConnection;
  Future<void> _configure(BuildContext context, OPlugin plugin) async {
    try {
      final saved = await showPluginSettingsDialog(context, plugin);
      if (saved && forConnection && context.mounted) Navigator.pop(context, true);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('확장앱 설정을 열 수 없습니다. 보안 저장소 상태를 확인해 주세요.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([PluginStore.instance, AppSettings.instance]),
    builder: (context, _) {
      final store = PluginStore.instance;
      final plugin = store.installed[pluginId];
      if (plugin == null || (!plugin.cloud && plugin.settings.isEmpty)) {
        return Scaffold(
          appBar: AppBar(title: const Text('확장앱 설정')),
          body: const Center(child: Text('확장앱이 설치되어 있지 않습니다')),
        );
      }
      final supported = (plugin.manifest['platforms'] as List?)?.contains(Platform.operatingSystem) ?? true;
      final configured = cloudPluginConfigured(plugin);
      return Scaffold(
        appBar: AppBar(title: Text('${plugin.name} 설정')),
        body: ListView(
          children: [
            ListTile(title: Text(plugin.name), subtitle: Text('${plugin.version} · ${plugin.kindLabel} 확장앱')),
            if (store.disabled.contains(pluginId))
              const ListTile(subtitle: Text('꺼진 확장앱입니다. 설정은 보관되며, 사용하려면 확장앱을 켜 주세요.')),
            ListTile(
              title: Text(plugin.cloud && plugin.authType == 'oauth' ? '앱 등록 정보' : '연결 설정'),
              subtitle: Text(configured ? '설정됨' : '설정 필요'),
              trailing: const Icon(Icons.edit_outlined),
              enabled: supported && plugin.settings.isNotEmpty,
              onTap: () => _configure(context, plugin),
            ),
            ListTile(
              subtitle: Text(
                plugin.cloud
                    ? '설정을 저장한 뒤 사이드바의 클라우드 연결에서 계정을 추가하세요. 기존 연결 계정은 유지됩니다.'
                    : plugin.subtitle
                    ? '설정을 저장한 뒤 플레이어의 자막 메뉴에서 온라인 자막을 검색하세요.'
                    : '설정을 저장한 뒤 열려 있는 웹페이지를 새로고침해 주세요.',
              ),
            ),
            if (forConnection)
              Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton(
                  onPressed: supported && configured && !store.disabled.contains(pluginId)
                      ? () => Navigator.pop(context, true)
                      : null,
                  child: const Text('연결 계속'),
                ),
              ),
          ],
        ),
      );
    },
  );
}
