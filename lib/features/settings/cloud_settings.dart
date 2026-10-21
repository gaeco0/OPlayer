import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/settings.dart';
import '../../sources/cloud/cloud_config.dart';
import '../../sources/server_store.dart';

bool cloudConfigured(CloudProvider provider) => switch (provider) {
  CloudProvider.dropbox => CloudConfig.dropboxAppKey.isNotEmpty,
  CloudProvider.onedrive => CloudConfig.oneDriveClientId.isNotEmpty,
  CloudProvider.gdrive => false,
};

Future<bool> showCloudSetup(BuildContext context, CloudProvider provider) async {
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
                    const Text(
                      '위 주소 두 개를 등록하면 Android와 Windows에서 같은 앱 등록을 사용할 수 있습니다. 로그인은 시스템 브라우저에서 진행됩니다.',
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton.icon(
                          icon: const Icon(Icons.open_in_new),
                          label: const Text('개발자 콘솔'),
                          onPressed: () async {
                            final uri = Uri.parse(
                              dropbox
                                  ? 'https://www.dropbox.com/developers/apps'
                                  : 'https://entra.microsoft.com/',
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

class CloudSettings extends StatelessWidget {
  const CloudSettings({super.key});
  @override
  Widget build(BuildContext context) => Column(
    children: [
      const ListTile(title: Text('클라우드 계정 연결'), subtitle: Text('앱 등록 정보를 저장한 뒤 사이드바에서 클라우드 연결을 눌러 로그인하세요.')),
      for (final provider in [CloudProvider.onedrive, CloudProvider.dropbox])
        ListTile(
          title: Text(provider.label),
          subtitle: Text(cloudConfigured(provider) ? '앱 등록 정보 설정됨' : '앱 등록 정보 필요'),
          trailing: const Icon(Icons.edit_outlined),
          enabled:
              Platform.isAndroid ||
              Platform.isIOS ||
              Platform.isWindows ||
              Platform.isMacOS ||
              Platform.isLinux,
          onTap: () => showCloudSetup(context, provider),
        ),
      const ListTile(title: Text('Google Drive'), subtitle: Text('추후 지원 예정'), enabled: false),
    ],
  );
}
