import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/media_item.dart';
import '../../sources/dlna_source.dart';
import 'cast_relay.dart';
import 'dlna_renderer.dart';
import '../player/media_session.dart';

class CastController extends ChangeNotifier {
  CastController._() {
    if (Platform.isAndroid) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'status' && _google && call.arguments is Map) {
          final status = call.arguments as Map;
          if (status['connected'] == false && active) {
            await _clear();
          } else {
            _updateGoogle(status);
            notifyListeners();
          }
        }
      });
    }
  }
  static final instance = CastController._();
  static const _channel = MethodChannel('oplayer/cast');
  CastRelay? _relay;
  DlnaRenderer? _renderer;
  bool _google = false;
  Timer? _poll;
  bool _polling = false;
  String? deviceName;
  String title = '';
  String? mediaKey;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool playing = false;
  bool get active => deviceName != null;
  bool get supportsVolume =>
      _google || _renderer?.device.renderingControlUrl != null;

  Future<bool> googleCast(MediaItem media, Duration start) async {
    await stop();
    _google = true;
    try {
      final device = await _channel.invokeMapMethod<String, dynamic>('connect');
      if (device == null) {
        _google = false;
        return false;
      }
      final address = device['address'] as String?;
      if (address == null) {
        throw const FormatException('Cast 기기의 로컬 네트워크 주소를 확인할 수 없습니다');
      }
      _relay = CastRelay();
      final url = await _relay!.start(
        media,
        Uri(
          scheme: 'http',
          host: address,
          port: (device['port'] as num?)?.toInt() ?? 8009,
        ),
      );
      await _channel.invokeMethod<bool>('load', {
        'url': url,
        'mime': _relay!.mime,
        'title': media.title,
        'position': start.inMilliseconds,
      });
      deviceName = device['name'] as String? ?? 'Google Cast';
      _started(media, start);
      return true;
    } catch (_) {
      await _clear();
      rethrow;
    }
  }

  Future<void> dlnaCast(
    DlnaDevice device,
    MediaItem media,
    Duration start,
  ) async {
    await stop();
    _renderer = DlnaRenderer(device);
    _relay = CastRelay();
    try {
      final url = await _relay!.start(media, Uri.parse(device.controlUrl));
      await _renderer!.load(url, media.title, _relay!.mime);
      if (start > Duration.zero) {
        try {
          await _renderer!.seek(start);
        } catch (_) {}
      }
      deviceName = device.name;
      _started(media, start);
    } catch (_) {
      await _clear();
      rethrow;
    }
  }

  void _started(MediaItem media, Duration start) {
    title = media.title;
    mediaKey = media.key;
    position = start;
    playing = true;
    _notifyMedia();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
    notifyListeners();
  }

  void _notifyMedia() {
    if (!active) return;
    NativeMediaSession.instance.update(
      enabled: true,
      playing: playing,
      title: title,
      subtitle: deviceName!,
      position: position,
      duration: duration,
      foreground: true,
      remote: true,
    );
  }

  void _updateGoogle(Map status) {
    position = Duration(
      milliseconds: (status['position'] as num?)?.toInt() ?? 0,
    );
    duration = Duration(
      milliseconds: (status['duration'] as num?)?.toInt() ?? 0,
    );
    playing = status['playing'] == true;
  }

  Future<void> _refresh() async {
    if (_polling || !active) return;
    _polling = true;
    try {
      if (_google) {
        final status = await _channel.invokeMapMethod<String, dynamic>(
          'status',
        );
        if (status?['connected'] == false) {
          await _clear();
          return;
        }
        if (status != null) _updateGoogle(status);
      } else if (_renderer != null) {
        final state = await _renderer!.status();
        playing = state.playing;
        position = state.position;
        duration = state.duration;
      }
      notifyListeners();
      _notifyMedia();
    } catch (_) {
      // Renderers may briefly reject status queries while changing media.
    } finally {
      _polling = false;
    }
  }

  Future<void> playOrPause() async {
    if (_google) {
      await _channel.invokeMethod<void>(playing ? 'pause' : 'play');
    } else if (playing) {
      await _renderer?.pause();
    } else {
      await _renderer?.play();
    }
    playing = !playing;
    _notifyMedia();
    notifyListeners();
  }

  Future<void> seek(Duration target) async {
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;
    if (_google) {
      await _channel.invokeMethod<void>('seek', {
        'position': target.inMilliseconds,
      });
    } else {
      await _renderer?.seek(target);
    }
    position = target;
    _notifyMedia();
    notifyListeners();
  }

  Future<void> volume(double value) async {
    if (_google) {
      await _channel.invokeMethod<void>('volume', {'value': value.clamp(0, 1)});
    } else {
      await _renderer?.volume(value);
    }
  }

  Future<void> stop() async {
    try {
      if (_google) {
        await _channel.invokeMethod<void>('stop');
      } else {
        await _renderer?.stop();
      }
    } catch (_) {}
    await _clear();
  }

  Future<void> _clear() async {
    _poll?.cancel();
    _poll = null;
    final relay = _relay;
    _relay = null;
    _renderer = null;
    _google = false;
    deviceName = null;
    mediaKey = null;
    playing = false;
    duration = Duration.zero;
    await relay?.close();
    await NativeMediaSession.instance.update(
      enabled: false,
      playing: false,
      title: '',
      position: Duration.zero,
      duration: Duration.zero,
    );
    notifyListeners();
  }

  static Future<void> systemOutput() =>
      _channel.invokeMethod<void>('systemOutput');
}
