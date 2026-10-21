import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/plugins/plugin.dart';
import '../../core/plugins/plugin_store.dart';
import '../../sources/cloud/s3_credentials.dart';

Future<bool> showCloudCredentialsDialog(BuildContext context, OPlugin plugin) async {
  final values = await PluginStore.instance.credentials(plugin.id);
  if (!context.mounted) return false;
  final s3 = plugin.authType == 's3';
  final fields = s3
      ? <String, String>{
          'displayName': '연결 이름 (선택)',
          'endpoint': 'S3 Endpoint URL',
          'bucket': '버킷 이름',
          'region': '리전',
          'accessKeyId': 'Access Key ID',
          'secretAccessKey': 'Secret Access Key',
          'sessionToken': 'Session Token (임시 자격 증명 사용 시)',
        }
      : <String, String>{'displayName': '연결 이름 (선택)', 'accessToken': '개인 액세스 토큰 (PAT)'};
  if (s3) values['region'] ??= 'us-east-1';
  final form = GlobalKey<FormState>();
  final auth = (plugin.manifest['auth'] as Map?) ?? {};
  var saving = false;
  String? error;
  return await showDialog<bool>(
        context: context,
        builder: (c) => StatefulBuilder(
          builder: (c, setState) => AlertDialog(
            title: Text('${plugin.name} 연결 설정'),
            content: SizedBox(
              width: 500,
              child: SingleChildScrollView(
                child: Form(
                  key: form,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (auth['help'] is String) Text(auth['help'] as String),
                      for (final field in fields.entries)
                        TextFormField(
                          initialValue: values[field.key] as String? ?? '',
                          enabled: !saving,
                          obscureText: ['secretAccessKey', 'sessionToken', 'accessToken'].contains(field.key),
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: InputDecoration(labelText: field.value),
                          onChanged: (v) => values[field.key] = v.trim(),
                          validator: (v) =>
                              !['displayName', 'sessionToken'].contains(field.key) && (v ?? '').trim().isEmpty
                              ? '${field.value} 값을 입력해 주세요'
                              : null,
                        ),
                      if (s3) ...[
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('버킷을 호스트명 앞에 붙이기'),
                          subtitle: const Text('가상 호스트 방식. 끄면 /버킷/ 경로 방식을 사용합니다.'),
                          value: values['virtualHosted'] == true,
                          onChanged: saving ? null : (v) => setState(() => values['virtualHosted'] = v == true),
                        ),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('ListObjects V1 사용'),
                          subtitle: const Text('네이버 클라우드 Object Storage 등 V2 미지원 서버용'),
                          value: values['listV1'] == true,
                          onChanged: saving ? null : (v) => setState(() => values['listV1'] = v == true),
                        ),
                      ],
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text('인증 정보는 기기 보안 저장소에 보관합니다. 변경한 값은 새로 연결하는 계정에 적용됩니다.'),
                      ),
                      if (auth['consoleUrl'] is String)
                        TextButton.icon(
                          icon: const Icon(Icons.open_in_new),
                          label: const Text('발급·등록 안내'),
                          onPressed: () => launchUrl(
                            repositoryUri(auth['consoleUrl'] as String),
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
                          if (s3) S3Credentials(values);
                          await PluginStore.instance.setCredentials(plugin.id, values);
                          if (c.mounted) Navigator.pop(c, true);
                        } catch (e) {
                          if (c.mounted) {
                            setState(() {
                              saving = false;
                              error = e is FormatException ? e.message : '인증 정보를 저장하지 못했습니다. 다시 시도해 주세요.';
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
