import 'dart:io';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/app_updater.dart';
import '../../core/app_release.dart';
import '../../core/media_utils.dart';

class AppUpdatePage extends StatefulWidget {
  const AppUpdatePage({super.key, this.updater});
  final AppUpdater? updater;
  @override
  State<AppUpdatePage> createState() => _AppUpdatePageState();
}

class _AppUpdatePageState extends State<AppUpdatePage> {
  late final updater = widget.updater ?? AppUpdater.instance;
  @override
  void initState() {
    super.initState();
    updater.init();
  }

  Future<void> _apply() async {
    try {
      if (updater.verifiedFile == null) await updater.download();
      if (!mounted || updater.verifiedFile == null) return;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('업데이트 설치'),
          content: Text(
            Platform.isWindows
                ? '검증한 업데이트로 앱 파일을 교체하고 다시 시작합니다. 진행 중인 재생·다운로드를 마친 뒤 설치해 주세요.'
                : Platform.isAndroid
                ? '검증한 APK를 시스템 설치 화면에서 확인하고 설치합니다.'
                : '검증한 압축 파일을 엽니다. 앱을 종료하고 기존 앱 폴더를 새 파일로 교체해 주세요.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('나중에')),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(Platform.isAndroid || Platform.isWindows ? '설치' : '파일 열기'),
            ),
          ],
        ),
      );
      if (accepted == true) await updater.install();
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('업데이트 설치를 시작하지 못했습니다. $error')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('앱 업데이트')),
    body: ListenableBuilder(
      listenable: updater,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            '현재 버전 ${updater.current.name} (${updater.installedChannel.name})',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('새 버전 자동 확인'),
            subtitle: const Text('앱 시작·복귀 시 최대 6시간마다 확인 · 다운로드와 설치는 직접 선택'),
            value: updater.automatic,
            onChanged: updater.busy ? null : (value) => updater.setAutomatic(value),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<UpdateChannel>(
            key: ValueKey(updater.channel),
            initialValue: updater.channel,
            decoration: const InputDecoration(labelText: '업데이트 채널', border: OutlineInputBorder()),
            items: [
              for (final channel in UpdateChannel.values) DropdownMenuItem(value: channel, child: Text(channel.name)),
            ],
            onChanged: updater.busy
                ? null
                : (value) {
                    if (value != null) updater.setChannel(value);
                  },
          ),
          const SizedBox(height: 8),
          const Text(
            'stable: 정식만(기본값) · beta: 베타·정식 · nightly: 모든 채널\n현재보다 새 버전만 알립니다. 같은 기본 버전은 nightly → beta → stable 순서로 판단합니다.',
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: updater.busy ? null : () => updater.check(force: true),
            icon: const Icon(Icons.refresh),
            label: Text(updater.checking ? '업데이트 확인 중…' : '지금 확인'),
          ),
          if (updater.checking || updater.installing) const LinearProgressIndicator(),
          if (updater.installing) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(updater.phase)),
          if (updater.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(updater.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          if (updater.available) ...[
            const SizedBox(height: 20),
            Text('${updater.release!.version.name} 업데이트', style: Theme.of(context).textTheme.titleMedium),
            if (updater.asset != null) Text('${updater.asset!.name} · ${formatSize(updater.asset!.size)}'),
            if (updater.asset == null) const Text('이 기기에 맞는 설치 파일이 없습니다. 릴리스 페이지에서 지원 플랫폼을 확인해 주세요.'),
            const SizedBox(height: 12),
            if (updater.downloading) ...[
              LinearProgressIndicator(value: updater.total > 0 ? updater.received / updater.total : null),
              Text('${updater.phase} · ${formatSize(updater.received)} / ${formatSize(updater.total)}'),
              TextButton(onPressed: updater.cancelDownload, child: const Text('다운로드 취소')),
            ] else if (updater.asset != null)
              FilledButton.icon(
                onPressed: updater.busy ? null : _apply,
                icon: const Icon(Icons.system_update),
                label: Text(
                  updater.installing
                      ? '설치 준비 중…'
                      : updater.verifiedFile != null
                      ? (Platform.isAndroid || Platform.isWindows ? '업데이트 설치' : '압축 파일 열기')
                      : (Platform.isAndroid || Platform.isWindows ? '다운로드 및 설치' : '업데이트 파일 받기'),
                ),
              ),
            TextButton(
              onPressed: () => launchUrl(updater.release!.url, mode: LaunchMode.externalApplication),
              child: const Text('GitHub 릴리스 열기'),
            ),
            const Divider(),
            const Text('릴리즈노트'),
            const SizedBox(height: 8),
            SelectableText(updater.release!.notes),
          ] else if (!updater.checking && updater.error == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                updater.hasChecked
                    ? (updater.release == null ? '선택한 채널에 배포된 업데이트가 없습니다.' : '선택한 채널의 최신 버전입니다.')
                    : '선택한 채널에 새 업데이트가 있는지 확인해 주세요.',
              ),
            ),
        ],
      ),
    ),
  );
}
