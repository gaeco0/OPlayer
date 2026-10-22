import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/media_item.dart';
import '../../core/media_utils.dart';
import '../../core/resume_store.dart';
import '../../core/settings.dart';
import '../../core/resource_locks.dart';
import '../../core/network/network_service.dart';
import '../../core/network/local_proxy.dart';
import '../../core/plugins/plugin.dart';
import '../../core/plugins/plugin_store.dart';
import '../../core/plugins/subtitle_plugins.dart';
import '../../core/plugins/player_plugins.dart';
import '../cast/cast_controller.dart';
import 'frame_interpolation.dart';
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

/// 플레이어 상태 전체. UI는 이 컨트롤러와 media_kit 스트림만 바라본다.
class PlayerController extends ChangeNotifier {
  PlayerController({required this.playlist, required int startIndex, this.folderFiles = const []})
    : _index = startIndex {
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
    _subs.addAll([
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
        notifyListeners();
        final audio = audioOnly;
        if (_lastAudioOnly != audio) {
          _lastAudioOnly = audio;
          if (!preparing) unawaited(_refreshInterpolation());
        }
      }),
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
  final player = Player(configuration: const PlayerConfiguration(title: 'OPlayer'));
  late final video = _createVideoController();
  bool _hasVideoController = false;
  VideoController _createVideoController() {
    _hasVideoController = true;
    final output = VideoController(player);
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
    if (_upscalingPreference == value) return;
    _upscalingPreference = value;
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
    final enabled = AppSettings.instance.videoUpscaling && !audioOnly && source.width > 0 && source.height > 0;
    final target = enabled ? upscaleTarget(source, _upscalingViewport, _upscalingFit) : null;
    upscalingBusy = true;
    upscalingIssue = null;
    notifyListeners();
    try {
      await _upscaler.apply(enabled, target);
      if (_disposed || request != _upscalingRequest) return;
      upscalingApplied = enabled;
      upscalingOutput = target;
    } catch (e) {
      if (!_disposed && request == _upscalingRequest) {
        upscalingApplied = false;
        upscalingOutput = null;
        upscalingIssue = '$e';
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
    if (_interpolationPreference == value) return;
    _interpolationPreference = value;
    unawaited(_refreshInterpolation());
  }

  void setDisplayRefreshRate(double rate) {
    rate = rate.isFinite && rate >= 20 && rate <= 1000 ? rate : 0;
    if (_disposed || (rate - _displayRate).abs() < .01) return;
    _displayRate = rate;
    if (!preparing) unawaited(_refreshInterpolation());
  }

  Future<void> _refreshInterpolation() async {
    if (_disposed || preparing) return;
    final desired = AppSettings.instance.frameInterpolation && !audioOnly && (player.state.width ?? 0) > 0;
    final enabled = desired && _displayRate > 0;
    // The screen supplies its actual display, including when moving monitors.
    final request = ++_interpolationRequest;
    _interpolationCheck?.cancel();
    interpolationBusy = true;
    interpolationIssue = null;
    notifyListeners();
    try {
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
        interpolationBusy = false;
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

  /// 이어보기 위치가 있으면 반환 (UI에서 "이어서 보기" 물어봄)
  Duration? pendingResume;

  Future<void> open({bool askResume = true}) async {
    _playbackPermit = null;
    final generation = ++_openGeneration;
    _startWatchdog?.cancel();
    if (current.browserMedia) {
      _startWatchdog = Timer(const Duration(seconds: 60), () {
        if (!_disposed && generation == _openGeneration && player.state.position == Duration.zero) {
          error ??= '60초 동안 재생 데이터를 받지 못했습니다. 웹페이지에서 재생 상태를 확인한 뒤 다시 시도해 주세요.';
          preparing = false;
          unawaited(player.stop());
          notifyListeners();
        }
      });
    }
    final st = AppSettings.instance;
    final r = st.resumeMode == ResumeMode.off ? null : ResumeStore.instance.get(current.key);
    pendingResume = (askResume && r != null && !r.finished && r.position > const Duration(seconds: 10))
        ? r.position
        : null;
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
      final opening = player.open(Media(item.uri, httpHeaders: await _applyHttpIdentity(item.headers)), play: true);
      if (current.browserMedia) {
        await opening.timeout(const Duration(seconds: 60));
      } else {
        await opening;
      }
      if (_disposed || generation != _openGeneration) return;
      await player.setRate(baseRate);
      await _restorePlaybackSettings();
      if (st.subtitleAutoLoad) _attachSiblingSubtitles();
      unawaited(_autoOnlineSubtitles(generation));
    } catch (e) {
      if (generation == _openGeneration) _startWatchdog?.cancel();
      if (generation == _openGeneration) error = '열 수 없습니다: $e';
    } finally {
      if (generation == _openGeneration) preparing = false;
      if (!_disposed && generation == _openGeneration) unawaited(_refreshInterpolation());
      if (!_disposed && generation == _openGeneration) unawaited(_refreshUpscaling());
      notifyListeners();
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
      await pl.setProperty('hwdec', st.hardwareDecoding ? 'auto-safe' : 'no');
      if (st.subtitleEncoding != 'auto') {
        await pl.setProperty('sub-codepage', st.subtitleEncoding);
      }
      // 네트워크 스트림 버퍼
      await pl.setProperty('cache', 'yes');
      await pl.setProperty('demuxer-max-bytes', '${64 * 1024 * 1024}');
      await pl.setProperty('demuxer-readahead-secs', '20');
    } catch (_) {}
  }

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

  void _attachSiblingSubtitles() {
    final subs = externalSubtitles;
    if (subs.isNotEmpty) {
      // 첫 번째 외부 자막 자동 선택 (내장 자막은 자막 패널에서 선택)
      loadExternalSubtitle(subs.first);
    }
  }

  Future<void> loadExternalSubtitle(SubtitleRef s) => player.setSubtitleTrack(SubtitleTrack.uri(s.uri, title: s.title));

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
    _cancelOnlineSubtitle();
    return player.setSubtitleTrack(track);
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
    await ResumeStore.instance.save(
      current.key,
      player.state.duration,
      player.state.duration,
      title: current.title,
      browserMedia: current.browserMedia,
    );
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

  Future<void> saveNow() => ResumeStore.instance.save(
    current.key,
    player.state.position,
    player.state.duration,
    title: current.title,
    browserMedia: current.browserMedia,
  );

  Future<void> next() async {
    if (!hasNext) return;
    await saveNow();
    _index++;
    await open();
  }

  Future<void> prev() async {
    // nPlayer처럼 3초 이상 재생 중이면 처음으로, 아니면 이전 파일
    if (player.state.position > const Duration(seconds: 3) || !hasPrev) {
      await player.seek(Duration.zero);
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
    baseRate = double.parse(r.clamp(0.25, 4.0).toStringAsFixed(2));
    await player.setRate(baseRate);
    notifyListeners();
  }

  Future<void> startFastForward() async {
    fastForwarding = true;
    await player.setRate(baseRate * 2);
    notifyListeners();
  }

  Future<void> stopFastForward() async {
    if (!fastForwarding) return;
    fastForwarding = false;
    await player.setRate(baseRate);
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
    final p = player.platform;
    if (p is NativePlayer) {
      await p.setProperty('sub-delay', (d.inMilliseconds / 1000).toStringAsFixed(2));
    }
    notifyListeners();
    await _savePlaybackSettings();
  }

  /// 자막은 media_kit_video의 Flutter SubtitleView가 그리므로 폰트 배율만 상태로 둔다.
  void setSubtitleScale(double s) {
    subtitleScale = s.clamp(0.5, 3.0);
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
    await _nativeProperty('audio-delay', '${audioDelay.inMilliseconds / 1000}');
    await _savePlaybackSettings();
    notifyListeners();
  }

  void setSubtitleBottom(double value) {
    subtitleBottom = value.clamp(0, 0.8);
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
    await _nativeProperty('audio-delay', '${audioDelay.inMilliseconds / 1000}');
    await _nativeProperty('sub-delay', '${subtitleDelay.inMilliseconds / 1000}');
    await _nativeProperty('video-rotate', '$videoRotation');
    await _nativeProperty('vf', [if (flipHorizontal) 'hflip', if (flipVertical) 'vflip'].join(','));
    await _nativeProperty('brightness', '$videoBrightness');
    await _nativeProperty('contrast', '$videoContrast');
    await _nativeProperty('saturation', '$videoSaturation');
  }

  @override
  void dispose() {
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
    saveNow();
    unawaited(player.dispose().whenComplete(_clearOnlineSubtitleFiles));
    super.dispose();
  }
}
