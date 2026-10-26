import 'package:flutter/material.dart';
import 'dart:io';
import 'package:url_launcher/url_launcher.dart';
import '../../core/plugins/plugin.dart';
import '../../core/plugins/plugin_runtime.dart';
import '../../core/plugins/plugin_store.dart';
import '../../core/secure_store.dart';
import '../../sources/cloud/oauth.dart';
import '../../sources/cloud/cloud_config.dart';

/// The extension owns the schema; the app only renders standard controls.
Future<bool> showPluginSettingsDialog(BuildContext context, OPlugin plugin) async {
  final store = PluginStore.instance;
  final values = <String, dynamic>{
    for (final f in plugin.settings)
      if (f.containsKey('default')) f['key'] as String: f['default'],
    ...await store.credentials(plugin.id),
  };
  final idKey = plugin.oauth['clientIdSetting'] as String? ?? 'clientId';
  if (plugin.cloud && plugin.authType == 'oauth' && '${values[idKey] ?? ''}'.isEmpty) {
    values[idKey] = store.oauthClientId(plugin);
  }
  final secretKey = plugin.oauth['clientSecretSetting'] as String? ?? 'clientSecret';
  bool usesBundledGoogleSecret() =>
      plugin.oauth['tokenEndpoint'] == 'https://oauth2.googleapis.com/token' &&
      plugin.oauth['authEndpoint'] == 'https://accounts.google.com/o/oauth2/v2/auth' &&
      (CloudConfig.googleBundledSecret('${values[idKey] ?? ''}')?.isNotEmpty ?? false);
  if (plugin.authType == 'oauth' && '${values[secretKey] ?? ''}'.isEmpty && '${values[idKey] ?? ''}'.isNotEmpty) {
    values[secretKey] =
        await SecureStore.instance.readRequired(PluginStore.oauthSecretKey(plugin.id, values[idKey] as String)) ?? '';
  }
  String? registration;
  final info =
      plugin.manifest['setup'] as Map? ??
      (plugin.authType == 'oauth' ? plugin.oauth : (plugin.manifest['auth'] as Map? ?? {}));
  if (Platform.isAndroid && (plugin.oauth['nativeAndroid'] == 'google' || info['nativeRegistration'] == 'google')) {
    final result = await GoogleAndroidOAuthClient.channel.invokeMapMethod<String, dynamic>('registrationInfo');
    registration = '패키지: ${result?['package']}\n서명 SHA-1: ${result?['sha1']}';
  }
  final platform = Platform.operatingSystem;
  final fields = plugin.settings.where((f) => (f['platforms'] as List?)?.contains(platform) ?? true).toList();
  for (final field in fields) {
    if (field['type'] == 'select' && !(field['options'] as List).contains(values[field['key']])) {
      values[field['key'] as String] = field['default'];
    }
  }
  if (!context.mounted) return false;
  final form = GlobalKey<FormState>();
  var saving = false;
  String? error;
  return await showDialog<bool>(
        context: context,
        builder: (c) => StatefulBuilder(
          builder: (c, setState) => AlertDialog(
            title: Text('${plugin.name} 설정'),
            content: SizedBox(
              width: 500,
              child: SingleChildScrollView(
                child: Form(
                  key: form,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (info['help'] is String) Text(info['help'] as String),
                      if (registration != null) SelectableText(registration),
                      for (final uri in (info['redirectUris'] as List? ?? []).cast<String>()) SelectableText(uri),
                      for (final field in fields)
                        if (field['type'] == 'boolean')
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(field['label'] as String),
                            subtitle: field['description'] is String ? Text(field['description'] as String) : null,
                            value: values[field['key']] == true,
                            onChanged: saving ? null : (v) => setState(() => values[field['key'] as String] = v),
                          )
                        else if (field['type'] == 'select')
                          DropdownButtonFormField<String>(
                            initialValue: values[field['key']] as String?,
                            decoration: InputDecoration(labelText: field['label'] as String),
                            items: [
                              for (final option in (field['options'] as List).cast<String>())
                                DropdownMenuItem(value: option, child: Text(option)),
                            ],
                            onChanged: saving ? null : (v) => values[field['key'] as String] = v,
                            validator: (v) => field['required'] == true && v == null ? '값을 선택해 주세요' : null,
                          )
                        else
                          TextFormField(
                            initialValue: values[field['key']] as String? ?? '',
                            enabled: !saving,
                            obscureText: field['type'] == 'password',
                            autocorrect: false,
                            enableSuggestions: false,
                            decoration: InputDecoration(
                              labelText: field['label'] as String,
                              helperText: field['key'] == secretKey && usesBundledGoogleSecret()
                                  ? '비워 두면 앱에 포함된 Client Secret을 자동 사용합니다.'
                                  : field['description'] as String?,
                              helperMaxLines: 3,
                            ),
                            onChanged: (v) {
                              values[field['key'] as String] = field['type'] == 'password' ? v : v.trim();
                              if (field['key'] == idKey) setState(() {});
                            },
                            validator: (v) {
                              final text = (v ?? '').trim();
                              if (field['key'] == secretKey && text.isEmpty && usesBundledGoogleSecret()) {
                                return null;
                              }
                              if (field['required'] == true && text.isEmpty) return '${field['label']} 값을 입력해 주세요';
                              if (field['type'] == 'url' && text.isNotEmpty) {
                                try {
                                  final uri = repositoryUri(text);
                                  if (uri.hasFragment || uri.hasQuery) return '서버 URL의 쿼리·조각을 제거해 주세요';
                                } catch (_) {
                                  return 'HTTPS 서버 URL을 입력해 주세요';
                                }
                              }
                              return null;
                            },
                          ),
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text('인증 정보는 이 기기의 보안 저장소에 보관합니다.'),
                      ),
                      if (info['consoleUrl'] is String)
                        TextButton.icon(
                          icon: const Icon(Icons.open_in_new),
                          label: const Text('발급·등록 안내'),
                          onPressed: () => launchUrl(
                            repositoryUri(info['consoleUrl'] as String),
                            mode: LaunchMode.externalApplication,
                          ),
                        ),
                      if (error != null) Text(error!, style: TextStyle(color: Theme.of(c).colorScheme.error)),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: saving ? null : () => Navigator.pop(c, false), child: const Text('취소')),
              FilledButton(
                onPressed: saving
                    ? null
                    : () async {
                        if (!form.currentState!.validate()) return;
                        setState(() {
                          saving = true;
                          error = null;
                        });
                        try {
                          final validation = await callPlugin(
                            plugin,
                            'validateSettings',
                            {},
                            config: plugin.publicConfig(values),
                          );
                          if (validation is String && validation.isNotEmpty) throw FormatException(validation);
                          if (plugin.cloud && plugin.authType == 'oauth') {
                            final id = values[plugin.oauth['clientIdSetting'] ?? 'clientId'] as String? ?? '';
                            final secret = values[plugin.oauth['clientSecretSetting'] ?? 'clientSecret'] as String?;
                            if (secret != null) {
                              await SecureStore.instance.writeRequired(
                                PluginStore.oauthSecretKey(plugin.id, id),
                                secret,
                              );
                            }
                            await store.setOAuthClientId(plugin.id, id);
                          }
                          await store.setCredentials(plugin.id, values);
                          if (c.mounted) Navigator.pop(c, true);
                        } catch (e) {
                          if (c.mounted) {
                            setState(() {
                              saving = false;
                              error = e is FormatException ? e.message : '설정을 저장하지 못했습니다. 입력값을 확인하고 다시 시도해 주세요.';
                            });
                          }
                        }
                      },
                child: saving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('저장'),
              ),
            ],
          ),
        ),
      ) ??
      false;
}
