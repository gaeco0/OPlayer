import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
// media_kit exposes the player handle publicly, but not its resolved DLL path.
// Reuse its exact loaded engine; never open a second mpv implementation.
// ignore: implementation_imports
import 'package:media_kit/src/player/native/core/native_library.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/media_item.dart';
import '../../core/media_utils.dart';
import '../../core/ffmpeg.dart';
import '../../core/resume_store.dart';
import '../../core/resource_playback_store.dart';
import '../../core/google_sync.dart';
import '../../core/settings.dart';
import '../../core/resource_locks.dart';
import '../../core/network/network_service.dart';
import '../../core/network/local_proxy.dart';
import '../../core/plugins/plugin.dart';
import '../../core/plugins/plugin_store.dart';
import '../../core/plugins/subtitle_plugins.dart';
import '../../core/plugins/player_plugins.dart';
import '../../core/plugins/upscale_models.dart';
import '../cast/cast_controller.dart';
import 'frame_interpolation.dart';
import 'ai_interpolation.dart';
import 'video_upscaling.dart';
import 'package:flutter/painting.dart';

/// 화면 비율 모드 (nPlayer: 화면 맞춤 → 가득 채우기 → 늘이기 → 16:9 → 4:3 → 원본)
enum AspectMode { fit, fill, stretch, r16x9, r4x3, r1x1, r3x2, r5x3, cinema185, cinema235, original }

extension AspectModeX on AspectMode {
  String get label => switch (this) {
    AspectMode.fit => '화면 맞춤',
    AspectMode.fill => '가득 채우기',
    AspectMode.stretch => '늘이기',
    AspectMode.r16x9 => '16:9',
    AspectMode.r4x3 => '4:3',
    AspectMode.r1x1 => '1:1',
    AspectMode.r3x2 => '3:2',
    AspectMode.r5x3 => '5:3',
    AspectMode.cinema185 => '1.85:1',
    AspectMode.cinema235 => '2.35:1',
    AspectMode.original => '원본 크기',
  };
}

enum LoopMode { off, one, all }

/// 1.00 → 1.0, 1.25 → 1.25, 1.50 → 1.5
String fmtRate(double r) => r.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');

bool audioOnlyTracks(Tracks tracks) {
  bool actual(String id) => id != 'auto' && id != 'no';
  return tracks.audio.any((track) => actual(track.id)) &&
      !tracks.video.any((track) => actual(track.id) && track.albumart != true && track.image != true);
}

bool backgroundPlaybackAllowed({required bool android, required bool audioOnly, required bool enabled}) =>
    enabled || (android && audioOnly);

/// Bitmap codecs require native OSD: their subtitle text stream is empty.
bool bitmapSubtitle(SubtitleTrack track) =>
    track.id != 'no' &&
    const {
      'hdmv_pgs_subtitle',
      'pgssub',
      'dvd_subtitle',
      'dvdsub',
      'dvb_subtitle',
      'dvbsub',
      'xsub',
    }.contains(track.codec?.toLowerCase());

VideoControllerConfiguration playbackVideoConfiguration({
  required bool hardwareDecoding,
  required TargetPlatform platform,
}) => VideoControllerConfiguration(
  // The Windows ANGLE texture path must not sample decoder surface padding.
  hwdec: !hardwareDecoding
      ? 'no'
      : platform == TargetPlatform.windows
      ? 'auto-copy'
      : 'auto-safe',
);

/// 플레이어 상태 전체. UI는 이 컨트롤러와 media_kit 스트림만 바라본다.
class PlayerController extends ChangeNotifier {
  PlayerController({
    required this.playlist,
    required int startIndex,
    this.folderFiles = const [],
    Player? playbackEngine,
  }) : _index = startIndex,
       player = playbackEngine ?? Player(configuration: const PlayerConfiguration(title: 'OPlayer')) {
    final st = AppSettings.instance;
    baseRate = st.defaultSpeed;
    aspect = switch (st.defaultAspect) {
      DefaultAspect.fit => AspectMode.fit,
      DefaultAspect.fill => AspectMode.fill,
      DefaultAspect.stretch => AspectMode.stretch,
    };
    _applyNativeOptions();
    ResourceLocks.instance.addListener(_enforceResourceLock);
    AppSettings.instance.addListener(_onInterpolationSettings);
    AppSettings.instance.addListener(_onUpscalingSettings);
    PluginStore.instance.addListener(_onUpscalingProvidersChanged);
    _subs.addAll([
      player.stream.log.listen((event) {
        if (_aiShaderError == null &&
            AppSettings.instance.videoUpscaling &&
            AppSettings.instance.upscalingModel != 'lanczos' &&
            const {'error', 'fatal'}.contains(event.level) &&
            RegExp(r'shader|glsl', caseSensitive: false).hasMatch(event.text)) {
          _aiShaderError = event.text.trim();
          _queueUpscaling();
        }
      }),
      player.stream.playing.listen((playing) {
        if (playing) _enforceResourceLock();
        if (playing && !preparing && AppSettings.instance.frameInterpolation) unawaited(_refreshInterpolation());
      }),
      player.stream.width.listen((_) {
        if (!preparing) unawaited(_refreshInterpolation());
      }),
      player.stream.videoParams.listen((_) => _queueUpscaling()),
      player.stream.position.listen(_onPosition),
      player.stream.tracks.listen((_) {
        unawaited(_refreshSubtitleRendering());
        notifyListeners();
        final audio = audioOnly;
        if (_lastAudioOnly != audio) {
          _lastAudioOnly = audio;
          if (!preparing) unawaited(_refreshInterpolation());
        }
      }),
      player.stream.track.listen((_) => unawaited(_refreshSubtitleRendering())),
      player.stream.completed.listen((done) {
        if (done) _onCompleted();
      }),
    ]);
  }

  final List<MediaItem> playlist;
  int? _playbackPermit;
  void _enforceResourceLock() {
    final locks = ResourceLocks.instance;
    _playbackPermit =
        locks.authorizePlayback([
          current.key,
          current.localPath ?? current.uri,
          if (resolved != null) resolved!.key,
          if (resolved != null) resolved!.localPath ?? resolved!.uri,
        ]) ??
        _playbackPermit;
    if (!locks.canContinuePlayback(_playbackPermit)) {
      player.pause();
    }
  }

  final List<String> folderFiles;
  final Player player;
  late final video = _createVideoController();
  bool _hasVideoController = false;
  VideoController _createVideoController() {
    _hasVideoController = true;
    final output = VideoController(player, configuration: _videoConfiguration);
    output.rect.addListener(_queueUpscaling);
    return output;
  }

  bool upscalingBusy = false;
  bool upscalingApplied = false;
  String? upscalingIssue;
  Size? upscalingOutput;
  Size _upscalingViewport = Size.zero;
  BoxFit _upscalingFit = BoxFit.contain;
  Timer? _upscalingTimer;
  int _upscalingRequest = 0;
  bool _upscalingPreference = AppSettings.instance.videoUpscaling;
  String _upscalingModelPreference = AppSettings.instance.upscalingModel;
  String? _aiShaderError;
  late final _upscaleShader = UpscaleShader((args) async {
    if (_disposed || player.platform is! NativePlayer) throw UnsupportedError('현재 엔진은 AI 업스케일을 지원하지 않습니다');
    await (player.platform as NativePlayer).command(args);
  });

  void _onUpscalingProvidersChanged() {
    if (AppSettings.instance.upscalingModel != 'lanczos') _queueUpscaling();
  }

  late final _upscaler = VideoUpscaler(
    read: (key) async {
      if (_disposed) throw StateError('플레이어가 종료됐습니다');
      final native = player.platform;
      if (native is! NativePlayer) throw UnsupportedError('현재 재생 엔진은 GPU 업스케일을 지원하지 않습니다');
      return native.getProperty(key);
    },
    write: (key, value) async {
      if (_disposed) throw StateError('플레이어가 종료됐습니다');
      await (player.platform as NativePlayer).setProperty(key, value);
    },
    resize: (size) async {
      if (_disposed) throw StateError('플레이어가 종료됐습니다');
      await video.setSize(width: size?.width.toInt(), height: size?.height.toInt());
    },
  );

  Size get upscalingSource {
    final params = player.state.videoParams;
    final w = (params.dw ?? player.state.width ?? 0).toDouble();
    final h = (params.dh ?? player.state.height ?? 0).toDouble();
    return (params.rotate ?? 0) % 180 == 0 ? Size(w, h) : Size(h, w);
  }

  void setUpscalingViewport(Size size, BoxFit fit) {
    if (_disposed || size == _upscalingViewport && fit == _upscalingFit) return;
    _upscalingViewport = size;
    _upscalingFit = fit;
    _queueUpscaling();
  }

  void _onUpscalingSettings() {
    final value = AppSettings.instance.videoUpscaling;
    final model = AppSettings.instance.upscalingModel;
    if (_upscalingPreference == value && _upscalingModelPreference == model) return;
    _upscalingPreference = value;
    _upscalingModelPreference = model;
    _aiShaderError = null;
    _upscalingTimer?.cancel();
    unawaited(_refreshUpscaling());
  }

  void _queueUpscaling() {
    if (_disposed) return;
    _upscalingTimer?.cancel();
    _upscalingTimer = Timer(const Duration(milliseconds: 150), _refreshUpscaling);
  }

  Future<void> _refreshUpscaling() async {
    if (_disposed || preparing) return;
    final request = ++_upscalingRequest;
    final source = upscalingSource;
    final enabled =
        AppSettings.instance.videoUpscaling &&
        !aiInterpolation.running &&
        !audioOnly &&
        source.width > 0 &&
        source.height > 0;
    final target = enabled ? upscaleTarget(source, _upscalingViewport, _upscalingFit) : null;
    upscalingBusy = true;
    upscalingIssue = null;
    if (aiInterpolation.running && AppSettings.instance.videoUpscaling) {
      upscalingIssue = 'AI 보간 중에는 업스케일을 잠시 중지합니다';
    }
    notifyListeners();
    try {
      final model = AppSettings.instance.upscalingModel;
      String? shader;
      if (enabled &&
          target != null &&
          target.width / source.width > 1.3 &&
          target.height / source.height > 1.3 &&
          model != 'lanczos' &&
          _aiShaderError == null) {
        if (source.longestSide > 1920 || source.width * source.height > 2073600) {
          throw UnsupportedError('저사양용 AI 모델은 1080p 이하 입력만 지원합니다');
        }
        shader = await UpscaleModels.instance.resolve(model);
        if (_disposed || request != _upscalingRequest) return;
      }
      await _upscaleShader.apply(shader);
      if (_disposed || request != _upscalingRequest) return;
      await _upscaler.apply(enabled, target);
      if (_disposed || request != _upscalingRequest) return;
      upscalingApplied = enabled;
      upscalingOutput = target;
      if (enabled && model != 'lanczos' && shader == null && _aiShaderError == null) {
        upscalingIssue = '화면을 1.3배보다 크게 확대하면 AI 모델을 적용합니다. 현재는 Lanczos를 사용합니다';
      }
      if (_aiShaderError != null && model != 'lanczos') upscalingIssue = 'AI 적용 실패 · Lanczos로 재생합니다: $_aiShaderError';
    } catch (e) {
      if (!_disposed && request == _upscalingRequest) {
        upscalingApplied = false;
        upscalingOutput = null;
        upscalingIssue = '$e';
        try {
          await _upscaleShader.apply(null);
          await _upscaler.apply(enabled, target);
          if (!_disposed && request == _upscalingRequest) {
            upscalingApplied = enabled;
            upscalingOutput = target;
            if (enabled && AppSettings.instance.upscalingModel != 'lanczos') {
              upscalingIssue = 'AI 적용 실패 · Lanczos로 재생합니다: $e';
            }
          }
        } catch (_) {
          // Existing renderer rollback errors stay visible; never claim AI success.
        }
      }
    } finally {
      if (!_disposed && request == _upscalingRequest) {
        upscalingBusy = false;
        notifyListeners();
      }
    }
  }

  final _subs = <StreamSubscription>[];
  double _displayRate = 0;
  bool _lastAudioOnly = false;
  bool interpolationBusy = false;
  bool interpolationApplied = false;
  String? interpolationIssue;
  int _interpolationRequest = 0;
  Timer? _interpolationCheck;
  bool _interpolationPreference = AppSettings.instance.frameInterpolation;
  String _interpolationMode = AppSettings.instance.interpolationMode;
  Future<void> _interpolationTail = Future.value();
  bool _bitmapSubtitle = false;
  bool _aiVisible = true;
  late final aiInterpolation = AiInterpolation(changed: _aiChanged);

  void _aiChanged() {
    if (_disposed) return;
    interpolationBusy = aiInterpolation.busy;
    interpolationApplied = aiInterpolation.applied;
    interpolationIssue = aiInterpolation.issue;
    unawaited(_applyAiTiming());
    _queueUpscaling();
    notifyListeners();
  }

  double get _aiDelay => aiInterpolation.applied ? AiInterpolation.delay.inMilliseconds / 1000 : 0;
  Future<void> _timingTail = Future.value();
  Future<void> _applyAiTiming() {
    final result = _timingTail.then((_) async {
      await _nativeProperty('audio-delay', '${audioDelay.inMilliseconds / 1000 + _aiDelay}');
      await _nativeProperty('sub-delay', '${subtitleDelay.inMilliseconds / 1000 + _aiDelay}');
    });
    _timingTail = result.catchError((Object _) {});
    return result;
  }

  void setAiVisible(bool visible) {
    if (_aiVisible == visible || _disposed) return;
    _aiVisible = visible;
    unawaited(_refreshInterpolation());
  }

  late final _frameInterpolation = FrameInterpolation(
    read: (key) async {
      if (_disposed) throw StateError('플레이어가 종료됐습니다');
      final native = player.platform;
      if (native is! NativePlayer) throw UnsupportedError('현재 재생 엔진은 프레임 혼합을 지원하지 않습니다');
      return native.getProperty(key);
    },
    write: (key, value) async {
      if (_disposed) throw StateError('플레이어가 종료됐습니다');
      await (player.platform as NativePlayer).setProperty(key, value);
    },
  );

  void _onInterpolationSettings() {
    final value = AppSettings.instance.frameInterpolation;
    final mode = AppSettings.instance.interpolationMode;
    if (_interpolationPreference == value && _interpolationMode == mode) return;
    _interpolationPreference = value;
    _interpolationMode = mode;
    aiInterpolation.issue = null;
    unawaited(_refreshInterpolation());
  }

  void setDisplayRefreshRate(double rate) {
    rate = rate.isFinite && rate >= 20 && rate <= 1000 ? rate : 0;
    if (_disposed || (rate - _displayRate).abs() < .01) return;
    _displayRate = rate;
    if (!preparing) unawaited(_refreshInterpolation());
  }

  Future<void> _refreshInterpolation() {
    final request = ++_interpolationRequest;
    final result = _interpolationTail.then((_) => _applyInterpolation(request));
    _interpolationTail = result.catchError((Object _) {});
    return result;
  }

  Future<void> _applyInterpolation(int request) async {
    if (request != _interpolationRequest) return;
    if (_disposed || preparing) return;
    final desired = AppSettings.instance.frameInterpolation && !audioOnly && (player.state.width ?? 0) > 0;
    final enabled = desired && _displayRate > 0;
    // The screen supplies its actual display, including when moving monitors.
    _interpolationCheck?.cancel();
    interpolationBusy = true;
    interpolationIssue = null;
    notifyListeners();
    try {
      if (AppSettings.instance.interpolationMode == 'rife' && desired) {
        await _frameInterpolation.apply(false, _displayRate);
        if (_disposed || request != _interpolationRequest) return;
        if (!_aiVisible || _bitmapSubtitle || baseRate != 1 || fastForwarding || CastController.instance.active) {
          await aiInterpolation.stop();
          await _applyAiTiming();
          _queueUpscaling();
          interpolationApplied = false;
          interpolationIssue = _bitmapSubtitle ? '비트맵 자막 재생 중에는 AI 보간을 중지합니다' : 'AI 보간은 화면에서 1배속으로 재생할 때 적용됩니다';
          return;
        }
        if (aiInterpolation.issue != null) {
          interpolationIssue = aiInterpolation.issue;
          interpolationApplied = false;
          return;
        }
        if (!aiInterpolation.running) {
          final gamma = await (player.platform as NativePlayer).getProperty('video-params/gamma');
          if (_disposed || request != _interpolationRequest) return;
          if (gamma == 'pq' || gamma == 'hlg') {
            throw UnsupportedError('HDR 영상은 원본 화질로 재생합니다. AI 보간은 SDR 영상에서 사용할 수 있습니다');
          }
          await aiInterpolation.start(handle: await player.handle, mpvLibrary: NativeLibrary.path);
          await _applyAiTiming();
          _queueUpscaling();
        }
        interpolationApplied = aiInterpolation.applied;
        interpolationIssue = aiInterpolation.issue;
        return;
      }
      await aiInterpolation.stop();
      if (_disposed || request != _interpolationRequest) return;
      await _applyAiTiming();
      _queueUpscaling();
      await _frameInterpolation.apply(enabled, _displayRate);
      if (_disposed || request != _interpolationRequest) return;
      interpolationApplied = enabled;
      if (desired && !enabled) interpolationIssue = '화면 주사율을 확인할 수 없어 프레임 혼합 적용을 기다리는 중입니다';
      if (enabled) {
        _scheduleInterpolationCheck(request);
      }
    } catch (e) {
      if (!_disposed && request == _interpolationRequest) {
        interpolationApplied = false;
        interpolationIssue = '$e';
      }
    } finally {
      if (!_disposed && request == _interpolationRequest) {
        interpolationBusy = aiInterpolation.busy;
        notifyListeners();
      }
    }
  }

  void _scheduleInterpolationCheck(int request) {
    _interpolationCheck = Timer(const Duration(seconds: 2), () async {
      if (_disposed || request != _interpolationRequest || !player.state.playing) return;
      if (player.state.buffering) {
        _scheduleInterpolationCheck(request);
        return;
      }
      try {
        final active = await (player.platform as NativePlayer).getProperty('display-sync-active');
        if (_disposed || request != _interpolationRequest || active == 'yes') return;
        await _frameInterpolation.apply(false, _displayRate);
        if (_disposed || request != _interpolationRequest) return;
        interpolationApplied = false;
        interpolationIssue = '이 영상 출력에서는 화면 동기화를 지원하지 않아 프레임 혼합을 해제했습니다';
      } catch (_) {
        if (!_disposed && request == _interpolationRequest) interpolationIssue = '프레임 혼합 상태를 확인하지 못했습니다';
      }
      if (!_disposed && request == _interpolationRequest) notifyListeners();
    });
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  int _index;
  int get index => _index;
  MediaItem get current => playlist[_index];

  /// resolve() 이후 실제로 재생 중인 항목 (임시 링크/프록시 URL 포함)
  MediaItem? resolved;
  String get title => current.title;
  String? error;
  bool preparing = false;
  int _openGeneration = 0;
  Future<void> Function()? _releaseMedia;
  StreamSubscription<String>? _mediaErrors;
  Timer? _startWatchdog;
  bool get audioOnly => audioOnlyTracks(player.state.tracks);
  bool get allowsBackgroundPlayback => backgroundPlaybackAllowed(
    android: Platform.isAndroid,
    audioOnly: audioOnly,
    enabled: AppSettings.instance.backgroundAudio,
  );

  bool get hasPrev => _index > 0;
  bool get hasNext => _index < playlist.length - 1;

  // ---- UI 상태 ----
  bool controlsVisible = true;
  bool locked = false;
  AspectMode aspect = AspectMode.fit;
  double zoom = 1.0;
  LoopMode repeat = LoopMode.off;
  Duration? abA;
  Duration? abB;
  Duration subtitleDelay = Duration.zero;
  double subtitleScale = 1.0;
  double subtitleBottom = 0.06;
  Duration audioDelay = Duration.zero;
  double audioBoost = 0;
  final equalizer = List<double>.filled(10, 0);
  static const equalizerFrequencies = [31, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
  int videoRotation = 0;
  bool flipHorizontal = false;
  bool flipVertical = false;
  double videoBrightness = 0;
  double videoContrast = 0;
  double videoSaturation = 0;
  DateTime? sleepUntil;
  Duration? sleepDuration;
  Timer? _sleepTimer;
  String? warning;
  final _pickedSubtitles = <SubtitleRef>[];
  final _onlineSubtitleFiles = <File>[];
  int _subtitleRequest = 0;
  int _subtitleLoad = 0;
  bool onlineSubtitleBusy = false;
  String? onlineSubtitleError;
  final onlineSubtitles = SubtitlePlugins(PluginStore.instance);
  bool videoFilterBusy = false;

  Future<void> applyVideoFilter(OPlugin plugin) async {
    if (videoFilterBusy || _disposed) return;
    final generation = _openGeneration;
    final store = PluginStore.instance;
    store.require(plugin.id);
    videoFilterBusy = true;
    notifyListeners();
    try {
      final values = await videoFilterValues(plugin, store.publicSettings(plugin));
      if (_disposed || generation != _openGeneration) return;
      if (!identical(store.require(plugin.id), plugin)) throw StateError('확장앱이 변경되었습니다. 다시 선택하세요');
      for (final property in ['brightness', 'contrast', 'saturation']) {
        if (_disposed || generation != _openGeneration) return;
        if (values.containsKey(property)) await setVideoColor(property, (values[property] as num).toDouble());
      }
      if (!_disposed && generation == _openGeneration) {
        await setVideoTransform(
          rotation: values['rotation'] as int?,
          horizontal: values['horizontal'] as bool?,
          vertical: values['vertical'] as bool?,
        );
      }
    } finally {
      videoFilterBusy = false;
      notifyListeners();
    }
  }

  /// 일반 재생 속도(롱프레스 2배속과 별개로 기억)
  double baseRate = 1.0;
  bool fastForwarding = false;

  DateTime _lastSave = DateTime.fromMillisecondsSinceEpoch(0);
  String? _markedPlayingKey;

  /// 이어보기 위치가 있으면 반환 (UI에서 "이어서 보기" 물어봄)
  Duration? pendingResume;
  Duration? _resumeStart;
  bool _positionReady = false;
  bool _awaitingResumeChoice = false;
  bool get awaitingResumeChoice => _awaitingResumeChoice;
  int get openGeneration => _openGeneration;

  bool isCurrentOpen(int generation) => !_disposed && generation == _openGeneration;

  Future<void> finishResume(int generation, {bool fromBeginning = false}) async {
    if (!isCurrentOpen(generation) || preparing || error != null || pendingResume == null) return;
    try {
      if (fromBeginning) {
        await restartFromBeginning();
        if (!isCurrentOpen(generation)) return;
      }
      if (_awaitingResumeChoice) await player.play();
      if (!isCurrentOpen(generation)) return;
      _awaitingResumeChoice = false;
      pendingResume = null;
    } catch (e) {
      if (!isCurrentOpen(generation)) return;
      error = '재생 위치를 복원할 수 없습니다: $e';
      notifyListeners();
    }
  }

  Future<void> open({bool askResume = true}) async {
    preparing = true;
    await aiInterpolation.stop();
    if (_disposed) return;
    aiInterpolation.issue = null;
    _subtitleLoad++;
    preparing = true;
    _positionReady = false;
    pendingResume = null;
    _resumeStart = null;
    _awaitingResumeChoice = false;
    _markedPlayingKey = null;
    _playbackPermit = null;
    final generation = ++_openGeneration;
    _startWatchdog?.cancel();
    if (current.browserMedia) {
      _startWatchdog = Timer(const Duration(seconds: 60), () {
        if (isCurrentOpen(generation) && !_awaitingResumeChoice && player.state.position == Duration.zero) {
          error ??= '60초 동안 재생 데이터를 받지 못했습니다. 웹페이지에서 재생 상태를 확인한 뒤 다시 시도해 주세요.';
          preparing = false;
          unawaited(player.stop());
          notifyListeners();
        }
      });
    }
    final st = AppSettings.instance;
    if (st.resumeMode != ResumeMode.off) {
      preparing = true;
      notifyListeners();
      await GoogleSync.instance.refreshForPlayback(current.key);
      if (_disposed || generation != _openGeneration) return;
    }
    final r = st.resumeMode == ResumeMode.off ? null : ResumeStore.instance.get(current.key);
    pendingResume = (askResume && r != null && !r.finished && r.position > const Duration(seconds: 10))
        ? r.position
        : null;
    _resumeStart = pendingResume;
    _awaitingResumeChoice = pendingResume != null && st.resumeMode == ResumeMode.ask;
    abA = abB = null;
    subtitleDelay = Duration.zero;
    error = null;
    resolved = null;
    preparing = true;
    notifyListeners();
    try {
      await _mediaErrors?.cancel();
      _mediaErrors = null;
      final release = _releaseMedia;
      _releaseMedia = null;
      if (release != null) {
        await player.pause();
        await release();
      }
      final item = await current.resolve();
      if (_disposed || generation != _openGeneration) {
        await item.onRelease?.call();
        return;
      }
      _releaseMedia = item.onRelease;
      _mediaErrors = item.playbackErrors?.listen((message) {
        if (!_disposed && generation == _openGeneration) {
          error = message;
          preparing = false;
          notifyListeners();
        }
      });
      resolved = item;
      final native = player.platform;
      if (native is NativePlayer && NetworkService.supported) {
        final uri = Uri.tryParse(item.uri);
        final useProxy = uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && !localNetworkHost(uri.host);
        await native.setProperty(
          'http-proxy',
          useProxy
              ? NetworkService.instance.proxyFor(uri, browser: current.browserMedia || item.browserMedia) ?? ''
              : '',
        );
      }
      await _applyNativeOptions();
      final headers = await _applyHttpIdentity(item.headers);
      if (!isCurrentOpen(generation)) return;
      final opening = player.open(
        Media(item.uri, httpHeaders: headers, start: _resumeStart),
        play: !_awaitingResumeChoice,
      );
      if (current.browserMedia) {
        await opening.timeout(const Duration(seconds: 60));
      } else {
        await opening;
      }
      if (_disposed || generation != _openGeneration) return;
      await player.setRate(baseRate);
      await _restorePlaybackSettings();
      if (st.subtitleAutoLoad) unawaited(_attachSiblingSubtitles(generation));
      unawaited(_autoOnlineSubtitles(generation));
    } catch (e) {
      if (generation == _openGeneration) _startWatchdog?.cancel();
      if (generation == _openGeneration) error = '열 수 없습니다: $e';
    } finally {
      if (generation == _openGeneration) preparing = false;
      if (!_disposed && generation == _openGeneration) unawaited(_refreshInterpolation());
      if (!_disposed && generation == _openGeneration) unawaited(_refreshUpscaling());
      if (!_disposed) notifyListeners();
    }
  }

  /// mpv는 User-Agent/Referer를 별도 옵션으로 보낸다. http-header-fields 에 같이 넣으면
  /// 중복 헤더가 생겨 일부 서버가 거부하므로, 두 값은 옵션으로 옮기고 나머지만 헤더로 보낸다.
  Future<Map<String, String>?> _applyHttpIdentity(Map<String, String>? headers) async {
    final pl = player.platform;
    String? pick(String name) {
      for (final e in (headers ?? const <String, String>{}).entries) {
        if (e.key.toLowerCase() == name) return e.value;
      }
      return null;
    }

    if (pl is NativePlayer) {
      try {
        await pl.setProperty('user-agent', pick('user-agent') ?? 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) OPlayer');
        await pl.setProperty('referrer', pick('referer') ?? '');
      } catch (_) {}
    }
    if (headers == null) return null;
    final rest = Map.of(headers)
      ..removeWhere((k, _) => k.toLowerCase() == 'user-agent' || k.toLowerCase() == 'referer');
    return rest.isEmpty ? null : rest;
  }

  Future<void> _applyNativeOptions() async {
    final pl = player.platform;
    if (pl is! NativePlayer) return;
    final st = AppSettings.instance;
    try {
      await pl.setProperty('hwdec', _videoConfiguration.hwdec!);
      if (st.subtitleEncoding != 'auto') {
        await pl.setProperty('sub-codepage', st.subtitleEncoding);
      }
      // 네트워크 스트림 버퍼
      await pl.setProperty('cache', 'yes');
      await pl.setProperty('demuxer-max-bytes', '${64 * 1024 * 1024}');
      await pl.setProperty('demuxer-readahead-secs', '20');
    } catch (_) {}
  }

  VideoControllerConfiguration get _videoConfiguration => playbackVideoConfiguration(
    hardwareDecoding: AppSettings.instance.hardwareDecoding,
    platform: defaultTargetPlatform,
  );

  List<String> _folderFilesFor(String path) {
    if (folderFiles.isNotEmpty && p.dirname(folderFiles.first) == p.dirname(path)) {
      return folderFiles;
    }
    try {
      return Directory(p.dirname(path)).listSync().map((e) => e.path).toList();
    } catch (_) {
      return const [];
    }
  }

  /// 같은 폴더의 외부 자막 파일 목록 (movie.srt, movie.ko.smi ...)
  List<SubtitleRef> get externalSubtitles {
    final local = current.localPath;
    final siblings = local == null
        ? const <SubtitleRef>[]
        : siblingSubtitles(
            local,
            _folderFilesFor(local),
          ).map((f) => SubtitleRef(Uri.file(f).toString(), p.basename(f))).toList();
    return [...siblings, ...(resolved ?? current).subtitles, ..._pickedSubtitles];
  }

  Future<void> _attachSiblingSubtitles(int generation) async {
    final subs = externalSubtitles;
    if (subs.isNotEmpty) {
      // 첫 번째 외부 자막 자동 선택 (내장 자막은 자막 패널에서 선택)
      try {
        await loadExternalSubtitle(subs.first);
      } catch (e) {
        if (isCurrentOpen(generation)) {
          warning = '자막을 열지 못했습니다: $e';
          notifyListeners();
        }
      }
    }
  }

  Future<void> loadExternalSubtitle(SubtitleRef s) async {
    final generation = _openGeneration, ticket = ++_subtitleLoad;
    bool active() => isCurrentOpen(generation) && ticket == _subtitleLoad;
    final previous = player.state.track.subtitle;
    try {
      var uri = s.uri;
      var codepage = AppSettings.instance.subtitleEncoding;
      final source = Uri.tryParse(uri);
      if (source?.scheme == 'file' && {'.smi', '.sami'}.contains(p.extension(source!.path).toLowerCase())) {
        // Android's bundled libmpv disables iconv: selecting legacy SAMI can
        // succeed while emitting mojibake. Normalize it before native loading.
        if (!Ffmpeg.embedded) {
          try {
            await _nativeProperty('sub-codepage', codepage);
            await player.setSubtitleTrack(SubtitleTrack.uri(uri, title: s.title));
            if (!active() || await _externalSubtitleSelected(uri, s.title)) return;
          } catch (_) {
            if (!active()) return;
          }
        }
        Directory temporary;
        try {
          temporary = await getTemporaryDirectory();
        } catch (_) {
          temporary = Directory.systemTemp;
        }
        final directory = await Directory(p.join(temporary.path, 'oplayer-subtitles')).create(recursive: true);
        final converted = File(p.join(directory.path, 'sami_${DateTime.now().microsecondsSinceEpoch}_$ticket.srt'));
        final (ok, error) = await Ffmpeg.convertSubtitle(input: source.toFilePath(), output: converted.path);
        if (!active() || !ok) {
          if (await converted.exists()) await converted.delete();
          if (!active()) return;
          throw StateError(error.isEmpty ? 'SMI 자막 변환에 실패했습니다' : error);
        }
        _onlineSubtitleFiles.add(converted);
        uri = Uri.file(converted.path).toString();
        codepage = 'utf-8';
      }
      if (!active()) return;
      await _nativeProperty('sub-codepage', codepage);
      await player.setSubtitleTrack(SubtitleTrack.uri(uri, title: s.title));
      if (!active()) return;
      if (!await _externalSubtitleSelected(uri, s.title)) {
        throw StateError('재생 엔진이 자막을 열지 못했습니다. 자막 형식·파일·인코딩을 확인해 주세요');
      }
    } catch (_) {
      if (active()) {
        try {
          await player.setSubtitleTrack(previous);
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<bool> _externalSubtitleSelected(String uri, String title) async {
    final native = player.platform;
    if (native is! NativePlayer) return true;
    List<dynamic> tracks;
    try {
      tracks = jsonDecode(await native.getProperty('track-list')) as List;
    } catch (_) {
      return false;
    }
    if (_disposed) return false;
    return tracks.any((t) {
      if (t['type'] != 'sub' || t['external'] != true || t['selected'] != true || t['title'] != title) return false;
      final file = t['external-filename'] as String?;
      if (file == null || file == uri) return true;
      final expected = Uri.tryParse(uri);
      if (expected?.scheme != 'file') return false;
      final actual = Uri.tryParse(file);
      return p.equals(actual?.scheme == 'file' ? actual!.toFilePath() : file, expected!.toFilePath());
    });
  }

  Future<void> pickSubtitle(String path) async {
    _cancelOnlineSubtitle();
    final subtitle = SubtitleRef(Uri.file(path).toString(), p.basename(path));
    if (!_pickedSubtitles.any((s) => s.uri == subtitle.uri)) {
      _pickedSubtitles.add(subtitle);
    }
    await loadExternalSubtitle(subtitle);
    notifyListeners();
  }

  void _cancelOnlineSubtitle() {
    _subtitleRequest++;
    onlineSubtitleBusy = false;
    onlineSubtitleError = null;
    notifyListeners();
  }

  Future<void> selectSubtitleTrack(SubtitleTrack track) {
    _subtitleLoad++;
    _cancelOnlineSubtitle();
    return player.setSubtitleTrack(track);
  }

  // Flutter renders text subtitles; bitmap subtitles have no sub-text to draw.
  // Keep native OSD enabled only for those tracks to avoid duplicate text.
  Future<void> _refreshSubtitleRendering() async {
    final native = player.platform;
    if (_disposed || native is! NativePlayer) return;
    // External track state may contain only a URI, without its decoder/codec.
    List<dynamic> tracks;
    try {
      tracks = jsonDecode(await native.getProperty('track-list')) as List;
    } catch (_) {
      return; // The player may have closed while the property read was pending.
    }
    if (_disposed) return;
    final bitmap = tracks.any(
      (t) =>
          t['type'] == 'sub' &&
          t['selected'] == true &&
          bitmapSubtitle(SubtitleTrack('${t['id']}', null, null, codec: t['codec'] as String?)),
    );
    if (_bitmapSubtitle != bitmap) {
      _bitmapSubtitle = bitmap;
      unawaited(_refreshInterpolation());
    }
    await _nativeProperty('sub-visibility', bitmap ? 'yes' : 'no');
    await _nativeProperty('sub-scale', '$subtitleScale');
    await _nativeProperty('sub-pos', '${((1 - subtitleBottom) * 100).round()}');
  }

  Future<void> selectExternalSubtitle(SubtitleRef subtitle) {
    _cancelOnlineSubtitle();
    return loadExternalSubtitle(subtitle);
  }

  Future<bool> applyOnlineSubtitle(
    OPlugin plugin,
    Map<String, dynamic> item, {
    int? generation,
    bool Function()? active,
  }) async {
    final expected = generation ?? _openGeneration;
    if (_disposed || expected != _openGeneration) return false;
    final ticket = ++_subtitleRequest;
    onlineSubtitleBusy = true;
    onlineSubtitleError = null;
    notifyListeners();
    File? file;
    try {
      final temp = await getTemporaryDirectory();
      file = await onlineSubtitles.download(plugin, item, Directory('${temp.path}/oplayer-subtitles'));
      if (_disposed ||
          expected != _openGeneration ||
          ticket != _subtitleRequest ||
          active?.call() == false ||
          !PluginStore.instance.enabled.any((p) => p.id == plugin.id)) {
        return false;
      }
      final subtitle = SubtitleRef(Uri.file(file.path).toString(), '${plugin.name} · ${item['title']}');
      await loadExternalSubtitle(subtitle);
      if (_disposed || expected != _openGeneration || ticket != _subtitleRequest) return false;
      _pickedSubtitles.add(subtitle);
      _onlineSubtitleFiles.add(file);
      file = null; // Owned until playback switches or the controller is disposed.
      return true;
    } catch (e) {
      if (!_disposed && expected == _openGeneration && ticket == _subtitleRequest) onlineSubtitleError = '$e';
      rethrow;
    } finally {
      if (file != null) await file.delete().catchError((Object _) => file!);
      if (ticket == _subtitleRequest) {
        onlineSubtitleBusy = false;
        notifyListeners();
      }
    }
  }

  Future<void> _autoOnlineSubtitles(int generation) async {
    if (audioOnly ||
        externalSubtitles.isNotEmpty ||
        player.state.tracks.subtitle.any((s) => s.id != 'auto' && s.id != 'no')) {
      return;
    }
    final provider = onlineSubtitles.providers
        .where((p) => PluginStore.instance.publicSettings(p)['autoApply'] == true)
        .firstOrNull;
    if (provider == null) return;
    final ticket = ++_subtitleRequest;
    onlineSubtitleBusy = true;
    onlineSubtitleError = null;
    notifyListeners();
    try {
      final language = '${PluginStore.instance.publicSettings(provider)['language'] ?? 'ko'}';
      final results = await onlineSubtitles.search(provider, subtitleSearchTitle(title), language);
      if (_disposed || generation != _openGeneration || ticket != _subtitleRequest) return;
      if (results.items.isEmpty) {
        onlineSubtitleError = '온라인 자막 검색 결과가 없습니다';
      } else {
        await applyOnlineSubtitle(provider, results.items.first, generation: generation);
      }
    } catch (e) {
      if (!_disposed && generation == _openGeneration && ticket == _subtitleRequest) onlineSubtitleError = '$e';
    } finally {
      if (ticket == _subtitleRequest) {
        onlineSubtitleBusy = false;
        notifyListeners();
      }
    }
  }

  void _clearOnlineSubtitleFiles() {
    for (final file in _onlineSubtitleFiles) {
      unawaited(file.delete().catchError((Object _) => file));
    }
    _onlineSubtitleFiles.clear();
  }

  void _onPosition(Duration pos) {
    // Opening/sync events may still describe the previous file or a temporary zero.
    if (_disposed || preparing || error != null) return;
    if (!_positionReady) {
      if (pos <= Duration.zero || player.state.duration <= Duration.zero) return;
      if (_resumeStart != null && pos < _resumeStart! - const Duration(seconds: 1)) return;
      _positionReady = true;
      _resumeStart = null;
    }
    if (_awaitingResumeChoice) return;
    if (player.state.playing && pos > Duration.zero && _markedPlayingKey != current.key) {
      _markedPlayingKey = current.key;
      unawaited(ResourcePlaybackStore.instance.record(current).catchError((Object _) {}));
    }
    if (pos > Duration.zero) _startWatchdog?.cancel();
    // A-B 반복
    if (abA != null && abB != null && pos >= abB!) {
      player.seek(abA!);
    }
    // 5초마다 이어보기 저장
    final now = DateTime.now();
    if (now.difference(_lastSave) > const Duration(seconds: 5)) {
      _lastSave = now;
      ResumeStore.instance.save(
        current.key,
        pos,
        player.state.duration,
        title: current.title,
        browserMedia: current.browserMedia,
      );
    }
  }

  Future<void> _onCompleted() async {
    final completedGeneration = _openGeneration;
    if (aiInterpolation.running) await Future<void>.delayed(AiInterpolation.delay);
    if (!isCurrentOpen(completedGeneration) || !player.state.completed) return;
    if (!_canSavePosition) return;
    final generation = _openGeneration;
    await ResumeStore.instance.save(
      current.key,
      player.state.duration,
      player.state.duration,
      title: current.title,
      browserMedia: current.browserMedia,
    );
    if (!isCurrentOpen(generation)) return;
    switch (repeat) {
      case LoopMode.one:
        await player.seek(Duration.zero);
        await player.play();
      case LoopMode.all:
        _index = hasNext ? _index + 1 : 0;
        await open(askResume: false);
      case LoopMode.off:
        if (hasNext && AppSettings.instance.autoPlayNext) {
          _index++;
          await open(askResume: false);
        }
    }
  }

  bool get _canSavePosition => !_disposed && !preparing && error == null && !_awaitingResumeChoice && _positionReady;

  Future<void> saveNow() async {
    if (!_canSavePosition) return;
    await ResumeStore.instance.save(
      current.key,
      player.state.position,
      player.state.duration,
      title: current.title,
      browserMedia: current.browserMedia,
    );
  }

  Future<void> next() async {
    if (!hasNext) return;
    await saveNow();
    _index++;
    await open();
  }

  Future<void> prev() async {
    // nPlayer처럼 3초 이상 재생 중이면 처음으로, 아니면 이전 파일
    if (player.state.position > const Duration(seconds: 3) || !hasPrev) {
      await restartFromBeginning();
      return;
    }
    await saveNow();
    _index--;
    await open();
  }

  Future<void> jumpTo(int i) async {
    if (i == _index || i < 0 || i >= playlist.length) return;
    await saveNow();
    _index = i;
    await open();
  }

  Future<void> seekRelative(Duration d) async {
    final dur = player.state.duration;
    var t = player.state.position + d;
    if (t < Duration.zero) t = Duration.zero;
    if (dur > Duration.zero && t > dur) t = dur;
    await player.seek(t);
  }

  Future<void> restartFromBeginning() async {
    final generation = _openGeneration;
    await player.seek(Duration.zero);
    if (!isCurrentOpen(generation)) return;
    _resumeStart = null;
    _positionReady = false;
  }

  // ---- 컨트롤 표시 ----
  Timer? _hideTimer;
  void showControls({bool autoHide = true}) {
    controlsVisible = true;
    notifyListeners();
    _hideTimer?.cancel();
    if (autoHide) _hideTimer = Timer(const Duration(seconds: 4), hideControls);
  }

  void hideControls() {
    _hideTimer?.cancel();
    controlsVisible = false;
    notifyListeners();
  }

  void toggleControls() => controlsVisible ? hideControls() : showControls();

  void keepControls() => showControls(autoHide: player.state.playing);

  // ---- 기능 ----
  void toggleLock() {
    locked = !locked;
    showControls();
  }

  void cycleAspect() {
    aspect = AspectMode.values[(aspect.index + 1) % AspectMode.values.length];
    zoom = 1.0;
    notifyListeners();
  }

  void setAspect(AspectMode m) {
    aspect = m;
    zoom = 1.0;
    notifyListeners();
  }

  void setZoom(double z) {
    zoom = z.clamp(0.5, 4.0);
    notifyListeners();
  }

  Future<void> setRate(double r) async {
    aiInterpolation.issue = null;
    baseRate = double.parse(r.clamp(0.25, 4.0).toStringAsFixed(2));
    await player.setRate(baseRate);
    unawaited(_refreshInterpolation());
    notifyListeners();
  }

  Future<void> startFastForward() async {
    fastForwarding = true;
    await aiInterpolation.stop();
    await _applyAiTiming();
    await player.setRate(baseRate * 2);
    notifyListeners();
  }

  Future<void> stopFastForward() async {
    if (!fastForwarding) return;
    fastForwarding = false;
    aiInterpolation.issue = null;
    await player.setRate(baseRate);
    unawaited(_refreshInterpolation());
    notifyListeners();
  }

  void cycleRepeat() {
    repeat = LoopMode.values[(repeat.index + 1) % LoopMode.values.length];
    notifyListeners();
  }

  /// A-B 반복: 1회 탭 = A 지정, 2회 = B 지정(반복 시작), 3회 = 해제
  String? tapAB() {
    final pos = player.state.position;
    String msg;
    if (abA == null) {
      abA = pos;
      msg = 'A 지점 설정 ${formatDuration(pos)}';
    } else if (abB == null) {
      if (pos <= abA!) return null;
      abB = pos;
      player.seek(abA!);
      msg = 'A-B 구간 반복';
    } else {
      abA = abB = null;
      msg = 'A-B 반복 해제';
    }
    notifyListeners();
    return msg;
  }

  Future<void> setSubtitleDelay(Duration d) async {
    subtitleDelay = d;
    await _applyAiTiming();
    notifyListeners();
    await _savePlaybackSettings();
  }

  /// Text uses Flutter styling; bitmap tracks apply scale to native OSD too.
  void setSubtitleScale(double s) {
    subtitleScale = s.clamp(0.5, 3.0);
    unawaited(_refreshSubtitleRendering());
    notifyListeners();
    _savePlaybackSettings();
  }

  Future<void> _nativeProperty(String name, String value) async {
    if (_disposed) return;
    final backend = player.platform;
    if (backend is! NativePlayer) return;
    try {
      await backend.setProperty(name, value);
    } catch (_) {
      warning = '이 재생 환경에서는 해당 설정을 적용하지 못했습니다';
      notifyListeners();
    }
  }

  Future<void> _applyAudioFilters() async {
    final filters = <String>[];
    for (var i = 0; i < equalizer.length; i++) {
      if (equalizer[i] != 0) {
        filters.add('equalizer=f=${equalizerFrequencies[i]}:t=o:w=1:g=${equalizer[i]}');
      }
    }
    if (audioBoost != 0) filters.add('volume=${audioBoost}dB');
    await _nativeProperty('af', filters.isEmpty ? '' : 'lavfi=[${filters.join(',')}]');
  }

  Future<void> setAudioBoost(double db) async {
    audioBoost = db.clamp(0, 12);
    await _applyAudioFilters();
    await _savePlaybackSettings();
    notifyListeners();
  }

  Future<void> setEqualizer(int index, double db, {bool commit = true}) async {
    equalizer[index] = db.clamp(-12, 12);
    if (commit) {
      await _applyAudioFilters();
      await _savePlaybackSettings();
    }
    notifyListeners();
  }

  Future<void> resetEqualizer() async {
    equalizer.fillRange(0, equalizer.length, 0);
    await _applyAudioFilters();
    await _savePlaybackSettings();
    notifyListeners();
  }

  Future<void> setAudioDelay(Duration value) async {
    audioDelay = Duration(milliseconds: value.inMilliseconds.clamp(-10000, 10000));
    await _applyAiTiming();
    await _savePlaybackSettings();
    notifyListeners();
  }

  void setSubtitleBottom(double value) {
    subtitleBottom = value.clamp(0, 0.8);
    unawaited(_refreshSubtitleRendering());
    _savePlaybackSettings();
    notifyListeners();
  }

  Future<void> setVideoTransform({int? rotation, bool? horizontal, bool? vertical}) async {
    videoRotation = ((rotation ?? videoRotation) ~/ 90 * 90) % 360;
    flipHorizontal = horizontal ?? flipHorizontal;
    flipVertical = vertical ?? flipVertical;
    await _nativeProperty('video-rotate', '$videoRotation');
    await _nativeProperty('vf', [if (flipHorizontal) 'hflip', if (flipVertical) 'vflip'].join(','));
    await _savePlaybackSettings();
    notifyListeners();
  }

  Future<void> setVideoColor(String property, double value, {bool commit = true}) async {
    value = value.clamp(-100, 100);
    switch (property) {
      case 'brightness':
        videoBrightness = value;
      case 'contrast':
        videoContrast = value;
      case 'saturation':
        videoSaturation = value;
      default:
        return;
    }
    if (commit) {
      await _nativeProperty(property, '$value');
      await _savePlaybackSettings();
    }
    notifyListeners();
  }

  Duration get sleepRemaining {
    final remaining = sleepUntil?.difference(DateTime.now()) ?? Duration.zero;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  void setSleepTimer(Duration? duration) {
    _sleepTimer?.cancel();
    sleepDuration = duration;
    sleepUntil = duration == null ? null : DateTime.now().add(duration);
    if (duration != null) {
      _sleepTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (sleepRemaining == Duration.zero) {
          player.pause();
          final cast = CastController.instance;
          if (cast.active && cast.mediaKey == current.key) cast.stop();
          setSleepTimer(null);
        } else {
          notifyListeners();
        }
      });
    }
    notifyListeners();
  }

  Future<String> screenshot() async {
    if (AppSettings.instance.preventCapture || ResourceLocks.instance.forcesCaptureProtection) {
      throw const FormatException('캡처 방지가 켜져 있습니다');
    }
    final bytes = await player.screenshot(format: 'image/png');
    if (bytes == null) throw const FormatException('현재 프레임을 저장할 수 없습니다');
    final directory = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'OPlayer', 'Screenshots'));
    await directory.create(recursive: true);
    final title = current.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final short = title.length > 80 ? title.substring(0, 80) : title;
    final path = p.join(directory.path, '${short}_${DateTime.now().millisecondsSinceEpoch}.png');
    await File(path).writeAsBytes(bytes);
    return path;
  }

  Future<void> _savePlaybackSettings() => ResumeStore.instance.savePlaybackSettings(current.key, {
    'boost': audioBoost,
    'audioDelay': audioDelay.inMilliseconds,
    'eq': equalizer,
    'subtitleDelay': subtitleDelay.inMilliseconds,
    'subtitleScale': subtitleScale,
    'subtitleBottom': subtitleBottom,
    'rotation': videoRotation,
    'flipH': flipHorizontal,
    'flipV': flipVertical,
    'brightness': videoBrightness,
    'contrast': videoContrast,
    'saturation': videoSaturation,
  });

  Future<void> _restorePlaybackSettings() async {
    final values = ResumeStore.instance.playbackSettings(current.key);
    audioBoost = ((values['boost'] as num?)?.toDouble() ?? 0).clamp(0, 12);
    audioDelay = Duration(milliseconds: ((values['audioDelay'] as num?)?.toInt() ?? 0).clamp(-10000, 10000));
    final eq = values['eq'];
    for (var i = 0; i < 10; i++) {
      equalizer[i] = eq is List && eq.length == 10 && eq[i] is num ? (eq[i] as num).toDouble().clamp(-12, 12) : 0;
    }
    subtitleDelay = Duration(milliseconds: (values['subtitleDelay'] as num?)?.toInt() ?? 0);
    subtitleScale = ((values['subtitleScale'] as num?)?.toDouble() ?? 1).clamp(0.5, 3);
    subtitleBottom = ((values['subtitleBottom'] as num?)?.toDouble() ?? 0.06).clamp(0, 0.8);
    videoRotation = ((values['rotation'] as num?)?.toInt() ?? 0) ~/ 90 * 90 % 360;
    flipHorizontal = values['flipH'] == true;
    flipVertical = values['flipV'] == true;
    videoBrightness = ((values['brightness'] as num?)?.toDouble() ?? 0).clamp(-100, 100);
    videoContrast = ((values['contrast'] as num?)?.toDouble() ?? 0).clamp(-100, 100);
    videoSaturation = ((values['saturation'] as num?)?.toDouble() ?? 0).clamp(-100, 100);
    _pickedSubtitles.clear();
    _subtitleRequest++;
    onlineSubtitleBusy = false;
    onlineSubtitleError = null;
    _clearOnlineSubtitleFiles();
    await _applyAudioFilters();
    await _applyAiTiming();
    await _refreshSubtitleRendering();
    await _nativeProperty('video-rotate', '$videoRotation');
    await _nativeProperty('vf', [if (flipHorizontal) 'hflip', if (flipVertical) 'vflip'].join(','));
    await _nativeProperty('brightness', '$videoBrightness');
    await _nativeProperty('contrast', '$videoContrast');
    await _nativeProperty('saturation', '$videoSaturation');
  }

  @override
  void dispose() {
    unawaited(saveNow());
    _startWatchdog?.cancel();
    _openGeneration++;
    _subtitleRequest++;
    _mediaErrors?.cancel();
    final release = _releaseMedia;
    _releaseMedia = null;
    if (release != null) unawaited(release().catchError((Object _) {}));
    ResourceLocks.instance.removeListener(_enforceResourceLock);
    AppSettings.instance.removeListener(_onInterpolationSettings);
    AppSettings.instance.removeListener(_onUpscalingSettings);
    PluginStore.instance.removeListener(_onUpscalingProvidersChanged);
    _upscalingRequest++;
    _upscalingTimer?.cancel();
    if (_hasVideoController) video.rect.removeListener(_queueUpscaling);
    _interpolationRequest++;
    _interpolationCheck?.cancel();
    _disposed = true;
    _hideTimer?.cancel();
    _sleepTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    unawaited(aiInterpolation.dispose().then((_) => player.dispose()).whenComplete(_clearOnlineSubtitleFiles));
    super.dispose();
  }
}
