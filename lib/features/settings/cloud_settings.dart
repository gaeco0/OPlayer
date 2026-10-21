import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/settings.dart';
import '../../core/secure_store.dart';
import '../../sources/cloud/cloud_config.dart';
import '../../sources/cloud/oauth.dart';
import '../../sources/server_store.dart';

bool cloudConfigured(CloudProvider provider) => switch (provider) {
  CloudProvider.plugin => true,
  CloudProvider.dropbox => CloudConfig.dropboxAppKey.isNotEmpty,
  CloudProvider.onedrive => CloudConfig.oneDriveClientId.isNotEmpty,
  CloudProvider.gdrive =>
    Platform.isAndroid
        ? CloudConfig.googleAndroidClientId.isNotEmpty
        : (Platform.isWindows || Platform.isMacOS || Platform.isLinux) && CloudConfig.googleDesktopClientId.isNotEmpty,
};

Future<bool> showCloudSetup(BuildContext context, CloudProvider provider) async {
  if (provider == CloudProvider.gdrive) return _showGoogleSetup(context);
  final dropbox = provider == CloudProvider.dropbox;
  var value = dropbox ? CloudConfig.dropboxAppKey : CloudConfig.oneDriveClientId;
  final key = GlobalKey<FormState>();
  return await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('${provider.label} 앱 등록'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Form(
                key: key,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      dropbox
                          ? 'Dropbox 개발자 콘솔에서 Scoped access · Full Dropbox 앱을 만들고 파일 목록·내용 읽기와 계정 정보 읽기 권한을 켜 주세요.'
                          : 'Microsoft Entra에서 개인 Microsoft 계정을 포함하는 앱을 등록하고, 모바일 및 데스크톱 플랫폼을 추가해 주세요. 권한은 Files.Read · User.Read · offline_access입니다.',
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      initialValue: value,
                      onChanged: (text) => value = text.trim(),
                      autocorrect: false,
                      decoration: InputDecoration(labelText: dropbox ? 'App Key' : 'Application (client) ID'),
                      validator: (text) {
                        final v = (text ?? '').trim();
                        final valid = dropbox
                            ? RegExp(r'^[A-Za-z0-9]+$').hasMatch(v)
                            : RegExp(
                                r'^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$',
                              ).hasMatch(v);
                        return valid ? null : '발급받은 ${dropbox ? 'App Key' : 'Client ID'}를 확인해 주세요';
                      },
                    ),
                    const SizedBox(height: 16),
                    const Text('등록할 로그인 복귀 주소'),
                    SelectableText(dropbox ? CloudConfig.dropboxRedirect : CloudConfig.oneDriveRedirect),
                    const SelectableText('http://localhost:53682/callback'),
                    const SizedBox(height: 8),
                    const Text('위 주소 두 개를 등록하면 Android와 Windows에서 같은 앱 등록을 사용할 수 있습니다. 로그인은 시스템 브라우저에서 진행됩니다.'),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton.icon(
                          icon: const Icon(Icons.open_in_new),
                          label: const Text('개발자 콘솔'),
                          onPressed: () async {
                            final uri = Uri.parse(
                              dropbox ? 'https://www.dropbox.com/developers/apps' : 'https://entra.microsoft.com/',
                            );
                            final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
                            if (!opened && dialogContext.mounted) {
                              ScaffoldMessenger.of(
                                dialogContext,
                              ).showSnackBar(const SnackBar(content: Text('브라우저를 열 수 없습니다')));
                            }
                          },
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.copy),
                          label: const Text('복귀 주소 복사'),
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(
                                text:
                                    '${dropbox ? CloudConfig.dropboxRedirect : CloudConfig.oneDriveRedirect}\nhttp://localhost:53682/callback',
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('취소')),
            FilledButton(
              onPressed: () {
                if (!key.currentState!.validate()) return;
                AppSettings.instance.update((s) {
                  if (dropbox) {
                    s.dropboxAppKey = value;
                  } else {
                    s.oneDriveClientId = value;
                  }
                });
                Navigator.pop(dialogContext, true);
              },
              child: const Text('저장'),
            ),
          ],
        ),
      ) ??
      false;
}

Future<bool> _showGoogleSetup(BuildContext context) async {
  final android = Platform.isAndroid;
  if (!android && !Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) return false;
  var id = android ? CloudConfig.googleAndroidClientId : CloudConfig.googleDesktopClientId;
  var secret = android ? '' : await SecureStore.instance.readRequired(CloudConfig.googleSecretKey(id)) ?? '';
  String? registration;
  if (android) {
    final info = await GoogleAndroidOAuthClient.channel.invokeMapMethod<String, dynamic>('registrationInfo');
    registration = '패키지: ${info?['package']}\n서명 SHA-1: ${info?['sha1']}';
  }
  if (!context.mounted) return false;
  final form = GlobalKey<FormState>();
  var saving = false;
  String? error;
  return await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: const Text('Google Drive 앱 등록'),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Form(
                  key: form,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Google Cloud에서 Google Drive API를 켜고 OAuth 동의 화면에 '
                        'drive.readonly 권한과 테스트 사용자를 등록하세요. '
                        '${android ? 'Android 유형의 OAuth 클라이언트를 만들고 아래 패키지와 SHA-1을 등록하세요. Google Play 서비스가 필요합니다. 모바일과 TV는 각각 등록해야 합니다.' : '데스크톱 앱 유형의 OAuth 클라이언트를 만드세요. 로그인은 시스템 브라우저에서 진행됩니다.'}',
                      ),
                      if (registration != null)
                        Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: SelectableText(registration)),
                      TextFormField(
                        initialValue: id,
                        autocorrect: false,
                        decoration: const InputDecoration(labelText: 'OAuth Client ID'),
                        onChanged: (value) => id = value.trim(),
                        validator: (value) =>
                            RegExp(r'^[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$').hasMatch((value ?? '').trim())
                            ? null
                            : '발급받은 Google Client ID를 확인해 주세요',
                      ),
                      if (!android) ...[
                        TextFormField(
                          initialValue: secret,
                          obscureText: true,
                          autocorrect: false,
                          decoration: const InputDecoration(labelText: '데스크톱 Client Secret'),
                          onChanged: (value) => secret = value.trim(),
                          validator: (value) => (value ?? '').trim().isEmpty ? '발급받은 Client Secret을 입력해 주세요' : null,
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Text('Secret은 이 기기의 보안 저장소에 저장됩니다.'),
                        ),
                      ],
                      const Text(
                        '전체 Drive 읽기 권한은 Google 검증 대상입니다. 테스트 모드에서는 등록한 사용자만 로그인할 수 있고, 인증이 7일 후 만료돼 재연결이 필요할 수 있습니다.',
                      ),
                      TextButton.icon(
                        onPressed: () => launchUrl(
                          Uri.parse('https://console.cloud.google.com/apis/credentials'),
                          mode: LaunchMode.externalApplication,
                        ),
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('Google Cloud 콘솔'),
                      ),
                      if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: saving ? null : () => Navigator.pop(dialogContext, false), child: const Text('취소')),
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
                          if (!android) {
                            await SecureStore.instance.writeRequired(CloudConfig.googleSecretKey(id), secret);
                          }
                          AppSettings.instance.update((s) {
                            if (android) {
                              s.googleAndroidClientId = id;
                            } else {
                              s.googleDesktopClientId = id;
                            }
                          });
                          if (dialogContext.mounted) Navigator.pop(dialogContext, true);
                        } catch (_) {
                          if (context.mounted) {
                            setState(() {
                              saving = false;
                              error = '등록 정보를 저장하지 못했습니다. 다시 시도해 주세요.';
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

class CloudSettings extends StatelessWidget {
  const CloudSettings({super.key});
  @override
  Widget build(BuildContext context) => Column(
    children: [
      const ListTile(title: Text('클라우드 계정 연결'), subtitle: Text('앱 등록 정보를 저장한 뒤 사이드바에서 클라우드 연결을 눌러 로그인하세요.')),
      for (final provider in [CloudProvider.onedrive, CloudProvider.dropbox, CloudProvider.gdrive])
        ListTile(
          title: Text(provider.label),
          subtitle: Text(cloudConfigured(provider) ? '앱 등록 정보 설정됨' : '앱 등록 정보 필요'),
          trailing: const Icon(Icons.edit_outlined),
          enabled:
              Platform.isAndroid ||
              (Platform.isIOS && provider != CloudProvider.gdrive) ||
              Platform.isWindows ||
              Platform.isMacOS ||
              Platform.isLinux,
          onTap: () => showCloudSetup(context, provider),
        ),
    ],
  );
}
