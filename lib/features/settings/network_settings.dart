import 'package:flutter/material.dart';

import '../../core/network/doh_resolver.dart';
import '../../core/network/network_service.dart';
import '../../core/settings.dart';

class NetworkSettings extends StatelessWidget {
  const NetworkSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final network = NetworkService.instance;
    final settings = AppSettings.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([network, settings]),
      builder: (context, _) {
        Future<void> apply({bool? doh, bool? bye, String? url, bool? resources}) async {
          try {
            await network.configure(
              doh: doh ?? settings.dohEnabled,
              bye: bye ?? settings.byeDpiEnabled,
              url: url ?? settings.dohUrl,
              resources: resources,
            );
            if (context.mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('적용했습니다. 열려 있는 웹페이지는 새로고침하고 영상은 다시 열어 주세요.')));
            }
          } catch (e) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('네트워크 설정 실패: $e')));
            }
          }
        }

        final available = NetworkService.supported && network.port != null && !network.busy;
        return Column(
          children: [
            const ListTile(
              title: Text('앱 네트워크'),
              subtitle: Text('적용 범위를 선택할 수 있습니다. 내부 네트워크와 SMB·FTP·SFTP는 직접 연결합니다.'),
            ),
            SwitchListTile(
              title: const Text('등록한 리소스에도 DoH·ByeDPI 적용'),
              subtitle: const Text('브라우저·다운로드는 한 묶음으로 적용합니다. 켜면 등록한 WebDAV·클라우드 등의 HTTP(S) 연결에도 적용합니다.'),
              value: settings.networkForResources,
              onChanged: available ? (value) => apply(resources: value) : null,
            ),
            SwitchListTile(
              title: const Text('DNS over HTTPS (DoH)'),
              subtitle: const Text('도메인 조회를 암호화된 HTTPS로 전송'),
              value: settings.dohEnabled,
              onChanged: available ? (value) => apply(doh: value) : null,
            ),
            ListTile(
              title: const Text('DoH 쿼리 URL'),
              subtitle: Text(settings.dohUrl),
              trailing: const Icon(Icons.edit_outlined),
              onTap: !available
                  ? null
                  : () async {
                      var edited = settings.dohUrl;
                      final formKey = GlobalKey<FormState>();
                      final value = await showDialog<String>(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                          title: const Text('DoH 쿼리 URL'),
                          content: Form(
                            key: formKey,
                            child: TextFormField(
                              initialValue: edited,
                              onChanged: (value) => edited = value,
                              autofocus: true,
                              keyboardType: TextInputType.url,
                              autocorrect: false,
                              decoration: const InputDecoration(hintText: 'https://dns.example/dns-query'),
                              validator: (value) => validDohUrl(value ?? '') ? null : '올바른 HTTPS URL을 입력해 주세요',
                            ),
                          ),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('취소')),
                            FilledButton(
                              onPressed: () {
                                if (formKey.currentState!.validate()) {
                                  Navigator.pop(dialogContext, edited.trim());
                                }
                              },
                              child: const Text('저장'),
                            ),
                          ],
                        ),
                      );
                      if (value != null) await apply(url: value);
                    },
            ),
            SwitchListTile(
              title: const Text('ByeDPI'),
              subtitle: const Text('내장 ByeDPI로 TCP 연결 처리'),
              value: settings.byeDpiEnabled,
              onChanged: available ? (value) => apply(bye: value) : null,
            ),
            if (network.busy) const LinearProgressIndicator(),
            if (network.error != null) ListTile(leading: const Icon(Icons.error_outline), title: Text(network.error!)),
          ],
        );
      },
    );
  }
}
