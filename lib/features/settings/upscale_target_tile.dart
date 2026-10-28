import 'package:flutter/material.dart';
import '../../core/settings.dart';

const upscaleResolutions = {0: '자동 · 화면 크기', 720: '720p', 1080: '1080p', 1440: '1440p', 2160: '2160p · 4K'};

class UpscaleTargetTile extends StatelessWidget {
  const UpscaleTargetTile({super.key, this.color});
  final Color? color;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: AppSettings.instance,
    builder: (context, _) => ListTile(
      title: Text('업스케일 목표 해상도', style: TextStyle(color: color)),
      subtitle: Text(
        upscaleResolutions[AppSettings.instance.upscalingResolution]!,
        style: TextStyle(color: color?.withValues(alpha: .7)),
      ),
      trailing: Icon(Icons.chevron_right, color: color),
      onTap: () async {
        final value = await showDialog<int>(
          context: context,
          builder: (c) => SimpleDialog(
            title: const Text('업스케일 목표 해상도'),
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('영상 비율 유지 · 원본보다 작게 축소하지 않음 · 최대 4096px/4K 픽셀 상한 적용'),
              ),
              for (final e in upscaleResolutions.entries)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(c, e.key),
                  child: Text('${e.value}${e.key == AppSettings.instance.upscalingResolution ? ' ✓' : ''}'),
                ),
            ],
          ),
        );
        if (value != null) AppSettings.instance.update((s) => s.upscalingResolution = value);
      },
    ),
  );
}
