import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/media_item.dart';
import '../../core/media_utils.dart';
import '../../sources/dlna_source.dart';
import 'cast_controller.dart';

class CastSheet extends StatefulWidget {
  const CastSheet({
    super.key,
    required this.media,
    required this.position,
    required this.onStarted,
  });
  final MediaItem media;
  final Duration position;
  final VoidCallback onStarted;
  @override
  State<CastSheet> createState() => _CastSheetState();
}

class _CastSheetState extends State<CastSheet> {
  final cast = CastController.instance;
  final _devices = <String, DlnaDevice>{};
  StreamSubscription<DlnaDevice>? _discovery;
  bool _scanning = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  void _scan() {
    _discovery?.cancel();
    setState(() {
      _devices.clear();
      _scanning = true;
      _error = null;
    });
    _discovery =
        DlnaDiscovery.discover(
          serviceType: 'urn:schemas-upnp-org:service:AVTransport:1',
        ).listen(
          (device) {
            if (mounted) setState(() => _devices[device.udn] = device);
          },
          onError: (Object error) {
            if (mounted) {
              setState(() {
                _error = '$error';
                _scanning = false;
              });
            }
          },
          onDone: () {
            if (mounted) setState(() => _scanning = false);
          },
        );
  }

  @override
  void dispose() {
    _discovery?.cancel();
    super.dispose();
  }

  Future<void> _connect(DlnaDevice? device) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final media = await widget.media.resolve();
      if (device == null) {
        if (!await cast.googleCast(media, widget.position)) return;
      } else {
        await cast.dlnaCast(device, media, widget.position);
      }
      widget.onStarted();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.72,
      child: ListenableBuilder(
        listenable: cast,
        builder: (_, __) => Column(
          children: [
            ListTile(
              title: const Text('외부 기기로 재생'),
              subtitle: const Text('TV와 같은 Wi-Fi / 로컬 네트워크에 연결해 주세요'),
              trailing: IconButton(
                onPressed: _busy ? null : _scan,
                icon: const Icon(Icons.refresh),
              ),
            ),
            if (_busy || _scanning) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Expanded(
              child: ListView(
                children: [
                  if (cast.active) ...[
                    ListTile(
                      leading: const Icon(Icons.cast_connected),
                      title: Text(cast.deviceName!),
                      subtitle: Text(cast.title),
                    ),
                    const CastControls(),
                    const Divider(),
                  ],
                  if (Platform.isAndroid) ...[
                    ListTile(
                      leading: const Icon(Icons.cast),
                      title: const Text('Google Cast / Chromecast'),
                      subtitle: const Text('연결할 기기 선택'),
                      enabled: !_busy,
                      onTap: () => _connect(null),
                    ),
                    ListTile(
                      leading: const Icon(Icons.connected_tv),
                      title: const Text('시스템 화면·오디오 출력'),
                      onTap: () async {
                        try {
                          await CastController.systemOutput();
                        } catch (e) {
                          if (mounted) setState(() => _error = '$e');
                        }
                      },
                    ),
                  ],
                  const ListTile(title: Text('DLNA 재생 기기')),
                  for (final device in _devices.values)
                    ListTile(
                      leading: const Icon(Icons.tv),
                      title: Text(device.name),
                      enabled: !_busy,
                      onTap: () => _connect(device),
                    ),
                  if (!_scanning && _devices.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(20),
                      child: Text(
                        'DLNA 재생 기기를 찾지 못했습니다. TV의 미디어 공유/원격 재생 설정을 확인해 주세요.',
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class CastControls extends StatelessWidget {
  const CastControls({super.key});
  Future<void> _run(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cast = CastController.instance;
    return ListenableBuilder(
      listenable: cast,
      builder: (_, __) {
        final total = cast.duration.inMilliseconds;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Slider(
              value: total <= 0
                  ? 0
                  : cast.position.inMilliseconds.clamp(0, total).toDouble(),
              max: total <= 0 ? 1 : total.toDouble(),
              onChanged: total <= 0
                  ? null
                  : (v) => _run(
                      context,
                      () => cast.seek(Duration(milliseconds: v.round())),
                    ),
            ),
            Text(
              '${formatDuration(cast.position)} / ${formatDuration(cast.duration)}',
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  onPressed: () => _run(
                    context,
                    () =>
                        cast.seek(cast.position - const Duration(seconds: 10)),
                  ),
                  icon: const Icon(Icons.replay_10),
                ),
                IconButton(
                  iconSize: 40,
                  onPressed: () => _run(context, cast.playOrPause),
                  icon: Icon(cast.playing ? Icons.pause : Icons.play_arrow),
                ),
                IconButton(
                  onPressed: () => _run(
                    context,
                    () =>
                        cast.seek(cast.position + const Duration(seconds: 10)),
                  ),
                  icon: const Icon(Icons.forward_10),
                ),
                IconButton(
                  tooltip: '출력 종료',
                  onPressed: () => _run(context, cast.stop),
                  icon: const Icon(Icons.stop),
                ),
              ],
            ),
            if (cast.supportsVolume)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('TV 음량'),
                    for (final v in [0.25, 0.5, 0.75, 1.0])
                      TextButton(
                        onPressed: () => _run(context, () => cast.volume(v)),
                        child: Text('${(v * 100).round()}%'),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
