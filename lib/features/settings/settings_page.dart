import 'upscale_models_page.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'dart:io';

import '../../app/theme.dart';
import '../../core/ffmpeg.dart';
import '../../core/settings.dart';
import '../../core/thumbnail_service.dart';
import '../browser/home_screen.dart';
import '../../sources/server_store.dart';
import '../../sources/source_registry.dart';
import '../network/remote_folder_picker.dart';
import '../web/download_manager.dart';
import 'network_settings.dart';
import 'privacy_settings.dart';
import 'appearance_settings.dart';
import 'plugins_page.dart';
import 'app_update_page.dart';
import 'google_sync_page.dart';
import 'issue_report_page.dart';
import '../player/desktop_window.dart';
import '../player/player_orientation.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.onOpenDrawer});
  final VoidCallback onOpenDrawer;

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: shouldShowDrawerButton(context)
            ? IconButton(icon: const Icon(Icons.menu), onPressed: onOpenDrawer)
            : null,
        title: const Text('설정'),
      ),
      body: ListenableBuilder(
        listenable: s,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.only(bottom: 48),
          children: [
            const AppearanceSettings(),
            ListTile(
              leading: const Icon(Icons.cloud_sync_outlined),
              title: const Text('Google 동기화'),
              subtitle: const Text('재생목록·최근 재생·이어보기 · Drive 앱 전용 저장소'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const GoogleSyncPage())),
            ),
            ListTile(
              leading: const Icon(Icons.extension_outlined),
              title: const Text('확장앱'),
              subtitle: const Text('사이트 다운로드·광고 차단·클라우드 · 저장소 JSON 추가'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PluginsPage())),
            ),
            const NetworkSettings(),
            const PrivacySettings(),
            const _Header('재생'),
            if (PlayerOrientation.supported)
              _choice<PlaybackOrientation>(
                context,
                title: '플레이어 화면 회전',
                value: s.playbackOrientation,
                options: {for (final mode in PlaybackOrientation.values) mode: mode.label},
                onChanged: (v) => s.update((x) => x.playbackOrientation = v),
              ),
            if (Platform.isWindows)
              ListTile(
                title: const Text('Windows 기본 미디어 플레이어로 설정'),
                subtitle: const Text('Windows 설정에서 OPlayer를 선택해 동영상·음악 파일을 연결하세요.'),
                leading: const Icon(Icons.video_file_outlined),
                onTap: () async {
                  try {
                    await DesktopWindow.openDefaultApps();
                  } catch (_) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('Windows 기본 앱 설정을 열지 못했습니다. 다시 시도해 주세요.')));
                    }
                  }
                },
              ),
            _choice<ResumeMode>(
              context,
              title: '이어보기',
              value: s.resumeMode,
              options: const {ResumeMode.auto: '자동으로 이어서', ResumeMode.ask: '물어보기', ResumeMode.off: '사용 안 함'},
              onChanged: (v) => s.update((x) => x.resumeMode = v),
            ),
            SwitchListTile(
              title: const Text('다음 파일 자동 재생'),
              value: s.autoPlayNext,
              onChanged: (v) => s.update((x) => x.autoPlayNext = v),
            ),
            SwitchListTile(
              title: const Text('하드웨어 디코딩'),
              subtitle: const Text('끄면 호환성↑ 배터리↓ (다음 재생부터 적용)'),
              value: s.hardwareDecoding,
              onChanged: (v) => s.update((x) => x.hardwareDecoding = v),
            ),
            _choice<double>(
              context,
              title: '기본 재생 속도',
              value: s.defaultSpeed,
              options: {0.75: '0.75x', 1.0: '1.0x', 1.25: '1.25x', 1.5: '1.5x', 2.0: '2.0x'},
              onChanged: (v) => s.update((x) => x.defaultSpeed = v),
            ),
            SwitchListTile(
              title: const Text('가벼운 프레임 보간'),
              subtitle: const Text('화면 주사율에 맞춰 프레임을 혼합해 끊김 완화 · 기본 꺼짐'),
              value: s.frameInterpolation,
              onChanged: (v) => s.update((x) => x.frameInterpolation = v),
            ),
            SwitchListTile(
              title: const Text('고화질 업스케일'),
              subtitle: const Text('낮은 해상도 영상을 화면 크기로 선명하게 확대 · GPU 사용'),
              value: s.videoUpscaling,
              onChanged: (v) => s.update((x) => x.videoUpscaling = v),
            ),
            ListTile(
              title: const Text('업스케일 모델'),
              subtitle: Text(
                s.upscalingModel == 'lanczos' ? 'Lanczos · 기본 AI 모델 3개 · URL 추가' : 'AI 모델 선택됨 · 변경·URL 추가',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const UpscaleModelsPage())),
            ),
            _choice<DefaultAspect>(
              context,
              title: '기본 화면 비율',
              value: s.defaultAspect,
              options: const {DefaultAspect.fit: '화면 맞춤', DefaultAspect.fill: '가득 채우기', DefaultAspect.stretch: '늘이기'},
              onChanged: (v) => s.update((x) => x.defaultAspect = v),
            ),
            const _Header('제스처'),
            _choice<int>(
              context,
              title: '더블탭 탐색 간격',
              value: s.doubleTapSeekSeconds,
              options: const {5: '5초', 10: '10초', 15: '15초', 30: '30초'},
              onChanged: (v) => s.update((x) => x.doubleTapSeekSeconds = v),
            ),
            _choice<int>(
              context,
              title: '방향키 탐색 간격 (데스크톱)',
              value: s.keyboardSeekSeconds,
              options: const {3: '3초', 5: '5초', 10: '10초', 30: '30초'},
              onChanged: (v) => s.update((x) => x.keyboardSeekSeconds = v),
            ),
            _choice<double>(
              context,
              title: '좌우 스와이프 감도 (화면 폭 = )',
              value: s.swipeSeekSpanSeconds,
              options: {60.0: '1분', 120.0: '2분', 180.0: '3분', 300.0: '5분', 600.0: '10분'},
              onChanged: (v) => s.update((x) => x.swipeSeekSpanSeconds = v),
            ),
            _choice<int>(
              context,
              title: '마우스 휠 볼륨 단위 (데스크톱)',
              value: s.wheelVolumeStep,
              options: const {1: '1%', 2: '2%', 3: '3%', 5: '5%'},
              onChanged: (v) => s.update((x) => x.wheelVolumeStep = v),
            ),
            SwitchListTile(
              title: const Text('좌우 스와이프로 탐색'),
              value: s.gestureSeek,
              onChanged: (v) => s.update((x) => x.gestureSeek = v),
            ),
            SwitchListTile(
              title: const Text('왼쪽 상하 스와이프로 밝기'),
              value: s.gestureBrightness,
              onChanged: (v) => s.update((x) => x.gestureBrightness = v),
            ),
            SwitchListTile(
              title: const Text('오른쪽 상하 스와이프로 볼륨'),
              value: s.gestureVolume,
              onChanged: (v) => s.update((x) => x.gestureVolume = v),
            ),
            SwitchListTile(
              title: const Text('길게 눌러 2배속'),
              value: s.longPressSpeed,
              onChanged: (v) => s.update((x) => x.longPressSpeed = v),
            ),
            const _Header('자막'),
            SwitchListTile(
              title: const Text('같은 이름 자막 자동 불러오기'),
              value: s.subtitleAutoLoad,
              onChanged: (v) => s.update((x) => x.subtitleAutoLoad = v),
            ),
            _choice<String>(
              context,
              title: '자막 인코딩',
              value: s.subtitleEncoding,
              options: const {
                'auto': '자동 감지',
                'utf-8': 'UTF-8',
                'cp949': 'CP949 (EUC-KR, 한국어 SMI)',
                'shift_jis': 'Shift_JIS',
              },
              onChanged: (v) => s.update((x) => x.subtitleEncoding = v),
            ),
            ListTile(
              title: const Text('자막 크기'),
              subtitle: Slider(
                value: s.subtitleFontSize,
                min: 20,
                max: 80,
                divisions: 30,
                label: s.subtitleFontSize.round().toString(),
                onChanged: (v) => s.update((x) => x.subtitleFontSize = v),
              ),
              trailing: Text('${s.subtitleFontSize.round()}'),
            ),
            _choice<int>(
              context,
              title: '자막 색상',
              value: s.subtitleColor,
              options: const {0xFFFFFFFF: '흰색', 0xFFFFEB3B: '노란색', 0xFF80DEEA: '하늘색'},
              onChanged: (v) => s.update((x) => x.subtitleColor = v),
            ),
            SwitchListTile(
              title: const Text('자막 배경'),
              value: s.subtitleBackground,
              onChanged: (v) => s.update((x) => x.subtitleBackground = v),
            ),
            const _Header('파일 목록'),
            SwitchListTile(
              title: const Text('썸네일 표시'),
              value: s.showThumbnails,
              onChanged: (v) => s.update((x) => x.showThumbnails = v),
            ),
            SwitchListTile(
              title: const Text('숨김 파일 표시'),
              value: s.showHiddenFiles,
              onChanged: (v) => s.update((x) => x.showHiddenFiles = v),
            ),
            ListTile(
              title: const Text('썸네일 캐시 지우기'),
              onTap: () async {
                await ThumbnailService.instance.clearCache();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('썸네일 캐시를 지웠습니다')));
                }
              },
            ),
            const _Header('웹 브라우저'),
            ListTile(title: const Text('홈페이지'), subtitle: Text(s.homepage), onTap: () => editHomepage(context)),
            const _Header('다운로드'),
            _choice<OutputQuality>(
              context,
              title: 'MP4 생성 옵션',
              value: s.outputQuality,
              options: {for (final q in OutputQuality.values) q: q.label},
              onChanged: (v) => s.update((x) => x.outputQuality = v),
            ),
            const _DownloadTargetTile(),
            FutureBuilder<String?>(
              future: Ffmpeg.locate(),
              builder: (_, snap) => ListTile(
                title: const Text('ffmpeg (MP4 생성·화질 변환)'),
                subtitle: Text(
                  snap.data ??
                      (Ffmpeg.embedded ? '내장 FFmpeg를 확인하지 못했습니다' : '찾지 못함 — HLS는 .ts로 저장됩니다. 탭해서 ffmpeg 실행 파일 위치 지정'),
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: Ffmpeg.embedded
                    ? const Icon(Icons.check_circle_outline)
                    : IconButton(
                        tooltip: s.ffmpegPath == null ? '다시 찾기' : '자동 탐색으로',
                        icon: Icon(s.ffmpegPath == null ? Icons.refresh : Icons.restore),
                        onPressed: () {
                          Ffmpeg.reset();
                          s.update((x) => x.ffmpegPath = null);
                        },
                      ),
                onTap: Ffmpeg.embedded
                    ? () => showLicensePage(context: context)
                    : () async {
                        final r = await FilePicker.pickFiles(dialogTitle: 'ffmpeg 실행 파일 선택');
                        final path = r?.files.single.path;
                        if (path != null) {
                          Ffmpeg.reset();
                          s.update((x) => x.ffmpegPath = path);
                        }
                      },
              ),
            ),
            _choice<int>(
              context,
              title: '동시 다운로드',
              value: s.maxConcurrentDownloads,
              options: const {1: '1개', 2: '2개', 3: '3개', 5: '5개'},
              onChanged: (v) => s.update((x) => x.maxConcurrentDownloads = v),
            ),
            _choice<int>(
              context,
              title: 'HLS 병렬 조각 수',
              value: s.hlsParallelSegments,
              options: const {1: '1', 4: '4', 8: '8', 16: '16'},
              onChanged: (v) => s.update((x) => x.hlsParallelSegments = v),
            ),
            const _Header('정보'),
            ListTile(
              leading: const Icon(Icons.bug_report_outlined),
              title: const Text('진단 정보 보내기'),
              subtitle: const Text('문제 신고 · GitHub Issues'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const IssueReportPage())),
            ),
            ListTile(
              leading: const Icon(Icons.system_update),
              title: const Text('앱 업데이트'),
              subtitle: const Text('새 버전 자동 확인 · stable / beta / nightly'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AppUpdatePage())),
            ),
            const ListTile(title: Text('OPlayer'), subtitle: Text('Flutter + media_kit (libmpv)')),
          ],
        ),
      ),
    );
  }

  Widget _choice<T>(
    BuildContext context, {
    required String title,
    required T value,
    required Map<T, String> options,
    required ValueChanged<T> onChanged,
  }) => ListTile(
    title: Text(title),
    subtitle: Text(options[value] ?? '$value', style: TextStyle(color: OColors.of(context).accent)),
    onTap: () async {
      final v = await showDialog<T>(
        context: context,
        builder: (c) => SimpleDialog(
          title: Text(title),
          children: [
            for (final e in options.entries)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(c, e.key),
                child: Row(
                  children: [
                    Icon(
                      e.key == value ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                      size: 20,
                      color: e.key == value ? OColors.of(context).accent : null,
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(e.value)),
                  ],
                ),
              ),
          ],
        ),
      );
      if (v != null) onChanged(v);
    },
  );
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(
      text,
      style: TextStyle(color: OColors.of(context).accent, fontSize: 13, fontWeight: FontWeight.w700),
    ),
  );
}

/// 다운로드 저장 위치: 이 기기 폴더 또는 등록된 서버(SMB/FTP/SFTP/WebDAV)의 폴더
class _DownloadTargetTile extends StatelessWidget {
  const _DownloadTargetTile();

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    final server = s.downloadServerId == null ? null : ServerStore.instance.server(s.downloadServerId!);
    final account = s.downloadServerId == null ? null : ServerStore.instance.account(s.downloadServerId!);
    return FutureBuilder(
      future: DownloadManager.downloadDir(),
      builder: (_, snap) => ListTile(
        title: const Text('저장 위치'),
        subtitle: Text(
          server != null
              ? '${server.name} (${server.type.name.toUpperCase()}) : ${s.downloadServerDir ?? '/'}\n받은 뒤 서버로 올리고 기기에서는 지웁니다'
              : account != null
              ? '${account.name} · 클라우드 : ${s.downloadServerDir ?? 'root'}\n받은 뒤 클라우드로 올리고 기기에서는 지웁니다'
              : '이 기기: ${snap.data?.path ?? '…'}',
          style: const TextStyle(fontSize: 12),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _choose(context),
      ),
    );
  }

  Future<void> _choose(BuildContext context) async {
    final s = AppSettings.instance;
    final servers = ServerStore.instance.servers;
    final clouds = SourceRegistry.instance.uploadAccounts.toList();
    final choice = await showModalBottomSheet<Object>(
      context: context,
      backgroundColor: OColors.of(context).surface,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('저장 위치', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            ListTile(
              leading: const Icon(Icons.phone_android),
              title: const Text('이 기기 — 기본 다운로드 폴더'),
              onTap: () => Navigator.pop(c, 'default'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('이 기기 — 폴더 직접 선택'),
              onTap: () => Navigator.pop(c, 'pick'),
            ),
            if (servers.isNotEmpty) const Divider(),
            for (final srv in servers)
              ListTile(
                leading: Icon(serverIcon(srv.type)),
                title: Text(srv.name),
                subtitle: Text('${srv.type.name.toUpperCase()} · ${srv.host}', style: const TextStyle(fontSize: 12)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.pop(c, srv),
              ),
            for (final account in clouds)
              ListTile(
                leading: const Icon(Icons.cloud_upload_outlined),
                title: Text(account.name),
                subtitle: const Text('클라우드 · 업로드 지원'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.pop(c, account),
              ),
            if (servers.isEmpty && clouds.isEmpty)
              const ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('서버에 저장하려면 사이드바에서 서버를 먼저 추가하세요', style: TextStyle(fontSize: 13)),
              ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    if (choice == 'default') {
      s.update((x) {
        x.downloadDir = null;
        x.downloadServerId = null;
        x.downloadServerDir = null;
      });
    } else if (choice == 'pick') {
      final d = await FilePicker.getDirectoryPath(dialogTitle: '다운로드 폴더');
      if (d != null) {
        s.update((x) {
          x.downloadDir = d;
          x.downloadServerId = null;
          x.downloadServerDir = null;
        });
      }
    } else if (choice is ServerConfig || choice is CloudAccount) {
      final id = choice is ServerConfig ? choice.id : (choice as CloudAccount).id;
      final src = await SourceRegistry.instance.forDestination(id);
      if (!src.canUpload) throw UnsupportedError('이 저장소는 업로드를 지원하지 않습니다');
      if (!context.mounted) return;
      final dir = await RemoteFolderPicker.pick(
        context,
        src,
        initialPath: s.downloadServerId == id ? s.downloadServerDir : null,
      );
      if (dir != null) {
        s.update((x) {
          x.downloadServerId = id;
          x.downloadServerDir = dir;
        });
      }
    }
  }
}
