import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:file_picker/file_picker.dart';

import '../../../app/theme.dart';
import '../../../core/plugins/plugin_store.dart';
import '../../../core/settings.dart';
import '../player_controller.dart';
import '../../settings/upscale_models_page.dart';
import '../../settings/upscale_target_tile.dart';
import '../../settings/interpolation_models_page.dart';
import 'controls_overlay.dart' show PanelKind;
import 'online_subtitles_dialog.dart';

/// nPlayer식 우측 슬라이드 패널 (배속 / 자막 / 오디오 / 화면비 / 재생목록 / 더보기)
class SidePanel extends StatelessWidget {
  const SidePanel({super.key, required this.kind, required this.c, required this.onClose, required this.onToast});
  final PanelKind kind;
  final PlayerController c;
  final VoidCallback onClose;
  final ValueChanged<String> onToast;

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final width = (w * 0.45).clamp(280.0, 380.0);
    final open = kind != PanelKind.none;

    return AnimatedPositioned(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      top: 0,
      bottom: 0,
      right: open ? 0 : -width - 20,
      width: width,
      child: Material(
        color: OColors.panel,
        child: SafeArea(
          left: false,
          child: open
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _title,
                              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, color: Colors.white70),
                            onPressed: onClose,
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1, color: Colors.white12),
                    Expanded(
                      child: ListenableBuilder(listenable: c, builder: (_, __) => _body(context)),
                    ),
                  ],
                )
              : const SizedBox.shrink(),
        ),
      ),
    );
  }

  String get _title => switch (kind) {
    PanelKind.speed => '재생 속도',
    PanelKind.subtitle => '자막',
    PanelKind.audio => '오디오',
    PanelKind.aspect => '화면·화질',
    PanelKind.playlist => '재생목록',
    PanelKind.more => '설정',
    PanelKind.none => '',
  };

  Widget _body(BuildContext context) => switch (kind) {
    PanelKind.speed => _SpeedPanel(c: c),
    PanelKind.subtitle => _SubtitlePanel(c: c, onToast: onToast),
    PanelKind.audio => _AudioPanel(c: c),
    PanelKind.aspect => _AspectPanel(c: c),
    PanelKind.playlist => _PlaylistPanel(c: c, onClose: onClose),
    PanelKind.more => _MorePanel(c: c, onToast: onToast),
    PanelKind.none => const SizedBox.shrink(),
  };
}

const _label = TextStyle(color: Colors.white60, fontSize: 12, fontWeight: FontWeight.w600);
const _white = TextStyle(color: Colors.white);

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
    child: Text(title, style: _label),
  );
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.value, required this.onMinus, required this.onPlus, this.onReset});
  final String value;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Row(
      children: [
        IconButton.filledTonal(onPressed: onMinus, icon: const Icon(Icons.remove)),
        Expanded(
          child: GestureDetector(
            onTap: onReset,
            child: Text(
              value,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700),
            ),
          ),
        ),
        IconButton.filledTonal(onPressed: onPlus, icon: const Icon(Icons.add)),
      ],
    ),
  );
}

// ---------------- 배속 ----------------
class _SpeedPanel extends StatelessWidget {
  const _SpeedPanel({required this.c});
  final PlayerController c;

  @override
  Widget build(BuildContext context) {
    const presets = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0];
    return ListView(
      children: [
        const SizedBox(height: 12),
        _Stepper(
          value: '${fmtRate(c.baseRate)}x',
          onMinus: () => c.setRate(c.baseRate - 0.1),
          onPlus: () => c.setRate(c.baseRate + 0.1),
          onReset: () => c.setRate(1.0),
        ),
        Slider(value: c.baseRate, min: 0.25, max: 4.0, divisions: 75, onChanged: c.setRate),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final r in presets)
                ChoiceChip(label: Text('${fmtRate(r)}x'), selected: c.baseRate == r, onSelected: (_) => c.setRate(r)),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.all(20),
          child: Text('화면을 길게 누르면 현재 속도의 2배로 재생됩니다.', style: TextStyle(color: Colors.white38, fontSize: 12)),
        ),
      ],
    );
  }
}

// ---------------- 자막 ----------------
class _SubtitlePanel extends StatelessWidget {
  const _SubtitlePanel({required this.c, required this.onToast});
  final PlayerController c;
  final ValueChanged<String> onToast;

  String _trackName(SubtitleTrack t) {
    if (t.id == 'no') return '사용 안 함';
    if (t.id == 'auto') return '자동';
    final parts = [t.title, t.language].whereType<String>().where((e) => e.isNotEmpty);
    return parts.isEmpty ? '트랙 ${t.id}' : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Tracks>(
      stream: c.player.stream.tracks,
      initialData: c.player.state.tracks,
      builder: (_, snap) => StreamBuilder<Track>(
        stream: c.player.stream.track,
        initialData: c.player.state.track,
        builder: (_, sel) {
          final tracks = (snap.data?.subtitle ?? []).where((t) => t.id != 'auto').toList();
          final current = sel.data?.subtitle;
          final ext = c.externalSubtitles;
          return ListView(
            children: [
              ListTile(
                leading: const Icon(Icons.add, color: Colors.white70),
                title: const Text('자막 파일 열기', style: _white),
                onTap: () async {
                  try {
                    final result = await FilePicker.pickFiles(
                      type: FileType.custom,
                      allowedExtensions: ['srt', 'smi', 'ass', 'ssa', 'vtt', 'lrc', 'sub'],
                      allowMultiple: false,
                    );
                    final path = result?.files.single.path;
                    if (path != null) await c.pickSubtitle(path);
                  } catch (e) {
                    onToast('$e');
                  }
                },
              ),
              const _Section('자막 트랙'),
              ListTile(
                leading: const Icon(Icons.travel_explore, color: Colors.white70),
                title: const Text('온라인 자막 검색·적용', style: _white),
                onTap: () => showOnlineSubtitles(context, c),
              ),
              if (c.onlineSubtitleBusy) const LinearProgressIndicator(),
              if (c.onlineSubtitleError != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(c.onlineSubtitleError!, style: _white),
                ),
              _Radios<String>(
                values: [for (final t in tracks) t.id],
                selected: current?.id,
                label: (id) => _trackName(tracks.firstWhere((t) => t.id == id)),
                onChanged: (id) => c.selectSubtitleTrack(tracks.firstWhere((t) => t.id == id)),
              ),
              if (ext.isNotEmpty) ...[
                const _Section('외부 자막 파일'),
                for (final f in ext)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.subtitles_outlined, color: Colors.white70),
                    title: Text(f.title, style: _white),
                    onTap: () async {
                      try {
                        await c.selectExternalSubtitle(f);
                      } catch (e) {
                        onToast('$e');
                      }
                    },
                  ),
              ],
              const _Section('싱크 (탭하면 초기화)'),
              _Stepper(
                value:
                    '${c.subtitleDelay.inMilliseconds >= 0 ? '+' : ''}${(c.subtitleDelay.inMilliseconds / 1000).toStringAsFixed(1)}초',
                onMinus: () => c.setSubtitleDelay(c.subtitleDelay - const Duration(milliseconds: 100)),
                onPlus: () => c.setSubtitleDelay(c.subtitleDelay + const Duration(milliseconds: 100)),
                onReset: () => c.setSubtitleDelay(Duration.zero),
              ),
              const _Section('크기'),
              _Stepper(
                value: '${(c.subtitleScale * 100).round()}%',
                onMinus: () => c.setSubtitleScale(c.subtitleScale - 0.1),
                onPlus: () => c.setSubtitleScale(c.subtitleScale + 0.1),
                onReset: () => c.setSubtitleScale(1.0),
              ),
              const _Section('자막 높이'),
              Slider(
                value: c.subtitleBottom,
                min: 0,
                max: 0.8,
                divisions: 40,
                label: '${(c.subtitleBottom * 100).round()}%',
                onChanged: c.setSubtitleBottom,
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }
}

// ---------------- 오디오 ----------------
class _AudioPanel extends StatelessWidget {
  const _AudioPanel({required this.c});
  final PlayerController c;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Tracks>(
      stream: c.player.stream.tracks,
      initialData: c.player.state.tracks,
      builder: (_, snap) => StreamBuilder<Track>(
        stream: c.player.stream.track,
        initialData: c.player.state.track,
        builder: (_, sel) {
          final tracks = (snap.data?.audio ?? []).where((t) => t.id != 'auto').toList();
          return ListView(
            children: [
              const _Section('오디오 트랙'),
              _Radios<String>(
                values: [for (final t in tracks) t.id],
                selected: sel.data?.audio.id,
                label: (id) {
                  final t = tracks.firstWhere((t) => t.id == id);
                  return t.id == 'no'
                      ? '음소거'
                      : [
                          t.title,
                          t.language,
                          t.codec,
                        ].whereType<String>().where((e) => e.isNotEmpty).join(' · ').ifEmpty('트랙 ${t.id}');
                },
                onChanged: (id) => c.player.setAudioTrack(tracks.firstWhere((t) => t.id == id)),
              ),
              const _Section('오디오 싱크 (탭하면 초기화)'),
              _Stepper(
                value: '${(c.audioDelay.inMilliseconds / 1000).toStringAsFixed(1)}초',
                onMinus: () => c.setAudioDelay(c.audioDelay - const Duration(milliseconds: 100)),
                onPlus: () => c.setAudioDelay(c.audioDelay + const Duration(milliseconds: 100)),
                onReset: () => c.setAudioDelay(Duration.zero),
              ),
              const _Section('볼륨 증폭'),
              _Stepper(
                value: '+${c.audioBoost.round()} dB',
                onMinus: () => c.setAudioBoost(c.audioBoost - 1),
                onPlus: () => c.setAudioBoost(c.audioBoost + 1),
                onReset: () => c.setAudioBoost(0),
              ),
              const _Section('10밴드 이퀄라이저'),
              TextButton(onPressed: c.resetEqualizer, child: const Text('이퀄라이저 초기화')),
              for (var i = 0; i < c.equalizer.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 48,
                        child: Text(
                          PlayerController.equalizerFrequencies[i] >= 1000
                              ? '${PlayerController.equalizerFrequencies[i] / 1000}k'
                              : '${PlayerController.equalizerFrequencies[i]}',
                          style: _label,
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          value: c.equalizer[i],
                          min: -12,
                          max: 12,
                          divisions: 24,
                          label: '${c.equalizer[i].round()} dB',
                          onChanged: (v) => c.setEqualizer(i, v, commit: false),
                          onChangeEnd: (v) => c.setEqualizer(i, v),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

// 화면·화질과 더보기에서 동일한 재생 설정을 제공합니다.
class _QualityControls extends StatelessWidget {
  const _QualityControls({required this.c});
  final PlayerController c;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: AppSettings.instance,
    builder: (context, _) => Column(
      children: [
        const _Section('업스케일'),
        SwitchListTile(
          title: const Text('고화질 업스케일', style: _white),
          subtitle: Text(c.audioOnly ? '오디오 전용 재생에는 적용하지 않습니다' : '화면에 맞춰 선명하게 확대 · 설정 자동 저장', style: _label),
          value: AppSettings.instance.videoUpscaling,
          onChanged: (c.upscalingBusy && !AppSettings.instance.videoUpscaling) || c.audioOnly
              ? null
              : (v) => AppSettings.instance.update((s) => s.videoUpscaling = v),
        ),
        ListTile(
          title: const Text('업스케일 모델', style: _white),
          subtitle: Text(
            AppSettings.instance.upscalingModel == 'lanczos' ? 'Lanczos · AI 모델은 확장앱 설치 필요' : 'AI 모델 선택됨 · 변경·URL 추가',
            style: _label,
          ),
          trailing: const Icon(Icons.chevron_right, color: Colors.white70),
          onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const UpscaleModelsPage())),
        ),
        if (Platform.isAndroid)
          SwitchListTile(
            title: const Text('AI 업스케일 NPU 가속', style: _white),
            subtitle: const Text('Snapdragon·Exynos 지원 NPU · 미지원 시 GPU 복귀', style: _label),
            value: AppSettings.instance.upscalingNpu,
            onChanged: (v) => AppSettings.instance.update((s) => s.upscalingNpu = v),
          ),
        if (c.aiUpscaling.applied)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Text(
              'NPU + GPU · ${c.aiUpscaling.inferenceMs.toStringAsFixed(1)}ms/프레임 · 음성·자막 100ms 싱크 보정',
              style: _label,
            ),
          ),
        const UpscaleTargetTile(color: Colors.white),
        if (c.upscalingBusy) const LinearProgressIndicator(),
        if (c.upscalingIssue != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Text(c.upscalingIssue!, style: _label),
          )
        else if (c.upscalingApplied)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Text(
              c.upscalingOutput == null
                  ? (AppSettings.instance.upscalingResolution == 0 ? '확대되는 화면에서 적용됩니다' : '선택한 목표가 원본 이하라 원본 해상도를 유지합니다')
                  : '${c.upscalingSource.width.toInt()}×${c.upscalingSource.height.toInt()} → ${c.upscalingOutput!.width.toInt()}×${c.upscalingOutput!.height.toInt()}',
              style: _label,
            ),
          ),
        const _Section('프레임 보간'),
        ListTile(
          title: const Text('보간 방식', style: _white),
          subtitle: Text(
            AppSettings.instance.interpolationMode == 'rife' ? 'AI · RIFE v4.6 · 중간 프레임 생성' : '가벼운 프레임 혼합',
            style: _label,
          ),
          trailing: const Icon(Icons.chevron_right, color: Colors.white70),
          onTap: () =>
              Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const InterpolationModelsPage())),
        ),
        SwitchListTile(
          title: const Text('프레임 보간', style: _white),
          subtitle: Text(
            c.audioOnly
                ? '오디오 전용 재생에는 적용하지 않습니다'
                : AppSettings.instance.interpolationMode == 'rife'
                ? '최대 긴 변 320px로 실시간 처리 · 250ms 지연 · 속도 부족 시 원본 복귀 · 업스케일과 동시 적용 안 됨'
                : '가벼운 프레임 혼합으로 끊김 완화 · 설정 자동 저장',
            style: _label,
          ),
          value: AppSettings.instance.frameInterpolation,
          onChanged: (c.interpolationBusy && !AppSettings.instance.frameInterpolation) || c.audioOnly
              ? null
              : (v) => AppSettings.instance.update((s) => s.frameInterpolation = v),
        ),
        if (Platform.isAndroid && AppSettings.instance.interpolationMode == 'rife')
          SwitchListTile(
            title: const Text('AI 보간 NPU 가속', style: _white),
            subtitle: const Text('Snapdragon·Exynos 지원 NPU · 미지원·속도 부족 시 GPU 복귀', style: _label),
            value: AppSettings.instance.interpolationNpu,
            onChanged: (v) => AppSettings.instance.update((s) => s.interpolationNpu = v),
          ),
        if (c.interpolationBusy) const LinearProgressIndicator(),
        if (c.interpolationIssue != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Text(c.interpolationIssue!, style: _label),
          )
        else if (c.interpolationApplied)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Text(
              AppSettings.instance.interpolationMode == 'rife'
                  ? 'RIFE · ${c.aiInterpolation.backend} · ${c.aiInterpolation.inferenceMs.toStringAsFixed(1)}ms/프레임${c.aiInterpolation.npuFallback ? ' · NPU 미지원/속도 부족' : ''}'
                  : '프레임 혼합 설정 적용됨',
              style: _label,
            ),
          ),
      ],
    ),
  );
}

// ---------------- 화면 비율 ----------------
class _AspectPanel extends StatelessWidget {
  const _AspectPanel({required this.c});
  final PlayerController c;

  @override
  Widget build(BuildContext context) => ListView(
    children: [
      _QualityControls(c: c),
      const _Section('화면 비율'),
      _Radios<AspectMode>(values: AspectMode.values, selected: c.aspect, label: (m) => m.label, onChanged: c.setAspect),
      const _Section('영상 필터 확장앱'),
      ListenableBuilder(
        listenable: PluginStore.instance,
        builder: (context, _) => Column(
          children: [
            if (c.videoFilterBusy) const LinearProgressIndicator(),
            for (final plugin in PluginStore.instance.enabled.where(
              (p) => p.kind == 'player' && p.supports('videoFilter'),
            ))
              ListTile(
                title: Text(plugin.name, style: _white),
                leading: const Icon(Icons.filter, color: Colors.white70),
                enabled: !c.videoFilterBusy,
                onTap: () async {
                  try {
                    await c.applyVideoFilter(plugin);
                  } catch (e) {
                    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
                  }
                },
              ),
          ],
        ),
      ),
      const _Section('확대'),
      _Stepper(
        value: '${(c.zoom * 100).round()}%',
        onMinus: () => c.setZoom(c.zoom - 0.1),
        onPlus: () => c.setZoom(c.zoom + 0.1),
        onReset: () => c.setZoom(1.0),
      ),
      const _Section('영상 회전·반전'),
      ListTile(
        title: Text('영상 회전 ${c.videoRotation}°', style: _white),
        leading: const Icon(Icons.rotate_90_degrees_cw, color: Colors.white70),
        onTap: () => c.setVideoTransform(rotation: c.videoRotation + 90),
      ),
      SwitchListTile(
        title: const Text('좌우 반전', style: _white),
        value: c.flipHorizontal,
        onChanged: (v) => c.setVideoTransform(horizontal: v),
      ),
      SwitchListTile(
        title: const Text('상하 반전', style: _white),
        value: c.flipVertical,
        onChanged: (v) => c.setVideoTransform(vertical: v),
      ),
      const _Section('영상 색상'),
      for (final entry in {
        'brightness': ('밝기', c.videoBrightness),
        'contrast': ('대비', c.videoContrast),
        'saturation': ('채도', c.videoSaturation),
      }.entries) ...[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(entry.value.$1, style: _label),
        ),
        Slider(
          value: entry.value.$2,
          min: -100,
          max: 100,
          divisions: 40,
          label: '${entry.value.$2.round()}',
          onChanged: (v) => c.setVideoColor(entry.key, v, commit: false),
          onChangeEnd: (v) => c.setVideoColor(entry.key, v),
        ),
      ],
    ],
  );
}

// ---------------- 재생목록 ----------------
class _PlaylistPanel extends StatelessWidget {
  const _PlaylistPanel({required this.c, required this.onClose});
  final PlayerController c;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => ListView.builder(
    itemCount: c.playlist.length,
    itemBuilder: (_, i) {
      final cur = i == c.index;
      final item = c.playlist[i];
      return ListTile(
        dense: true,
        selected: cur,
        selectedColor: OColors.of(context).accent,
        leading: cur
            ? Icon(Icons.equalizer, color: OColors.of(context).accent)
            : Text('${i + 1}', style: const TextStyle(color: Colors.white54)),
        title: Text(
          item.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: cur ? OColors.of(context).accent : Colors.white),
        ),
        onTap: () {
          c.jumpTo(i);
          onClose();
        },
      );
    },
  );
}

// ---------------- 더보기 ----------------
class _MorePanel extends StatelessWidget {
  const _MorePanel({required this.c, required this.onToast});
  final PlayerController c;
  final ValueChanged<String> onToast;

  @override
  Widget build(BuildContext context) {
    final s = c.player.state;
    return ListView(
      children: [
        _QualityControls(c: c),
        const _Section('취침 타이머'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            c.sleepUntil == null
                ? '사용 안 함'
                : '남은 시간 ${c.sleepRemaining.inMinutes}분 ${c.sleepRemaining.inSeconds % 60}초',
            style: _white,
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 8,
            children: [
              for (final minutes in [0, 15, 30, 45, 60, 90])
                ChoiceChip(
                  label: Text(minutes == 0 ? '끄기' : '$minutes분'),
                  selected: minutes == 0 ? c.sleepUntil == null : c.sleepDuration?.inMinutes == minutes,
                  onSelected: (_) => c.setSleepTimer(minutes == 0 ? null : Duration(minutes: minutes)),
                ),
            ],
          ),
        ),
        ListTile(
          leading: const Icon(Icons.photo_camera_outlined, color: Colors.white70),
          title: const Text('현재 화면 저장', style: _white),
          onTap: () async {
            try {
              onToast('화면 저장: ${await c.screenshot()}');
            } catch (e) {
              onToast('$e');
            }
          },
        ),
        const _Section('반복'),
        _Radios<LoopMode>(
          values: LoopMode.values,
          selected: c.repeat,
          label: (m) => switch (m) {
            LoopMode.off => '반복 안 함 (다음 파일 자동 재생)',
            LoopMode.one => '한 파일 반복',
            LoopMode.all => '전체 반복',
          },
          onChanged: (v) {
            while (c.repeat != v) {
              c.cycleRepeat();
            }
          },
        ),
        ListTile(
          dense: true,
          leading: const Icon(Icons.compare_arrows, color: Colors.white70),
          title: Text(c.abA == null ? 'A-B 구간 반복: A 지점 설정' : (c.abB == null ? 'B 지점 설정' : 'A-B 반복 해제'), style: _white),
          onTap: () {
            final m = c.tapAB();
            if (m != null) onToast(m);
          },
        ),
        const _Section('정보'),
        _info('해상도', s.width != null ? '${s.width} × ${s.height}' : '-'),
        _info('경로', c.current.localPath ?? c.current.key),
        if (s.audioParams.format != null) _info('오디오', '${s.audioParams.format} · ${s.audioParams.channels ?? ''}'),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _info(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 64,
          child: Text(k, style: const TextStyle(color: Colors.white54, fontSize: 13)),
        ),
        Expanded(
          child: Text(v, style: const TextStyle(color: Colors.white, fontSize: 13)),
        ),
      ],
    ),
  );
}

class _Radios<T> extends StatelessWidget {
  const _Radios({required this.values, required this.selected, required this.label, required this.onChanged});
  final List<T> values;
  final T? selected;
  final String Function(T) label;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => RadioGroup<T>(
    groupValue: selected,
    onChanged: (v) {
      if (v != null) onChanged(v);
    },
    child: Column(
      children: [
        for (final v in values)
          RadioListTile<T>(
            dense: true,
            value: v,
            title: Text(label(v), style: _white),
          ),
      ],
    ),
  );
}
