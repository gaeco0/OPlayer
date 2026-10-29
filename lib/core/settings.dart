import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'folder_sort.dart';

enum ResumeMode { auto, ask, off }

enum DefaultAspect { fit, fill, stretch }

enum PlaybackOrientation {
  landscape('가로 고정'),
  portrait('세로 고정'),
  auto('자동 회전');

  const PlaybackOrientation(this.label);
  final String label;
}

enum AppThemeMode { system, light, dark }

enum OutputQuality {
  original('원본화질'),
  high('고화질 · 최대 1080p'),
  medium('중화질 · 최대 720p'),
  low('저화질 · 최대 480p'),
  audio('소리만 · M4A');

  const OutputQuality(this.label);
  final String label;
}

/// 앱 설정. 모든 화면이 AppSettings.instance를 듣는다.
class AppSettings extends ChangeNotifier {
  AppSettings._();
  static final instance = AppSettings._();

  static const _k = 'settings_v1';
  late SharedPreferences _prefs;

  // ---- 재생 ----
  ResumeMode resumeMode = ResumeMode.auto;
  bool autoPlayNext = true;
  bool hardwareDecoding = true;
  bool frameInterpolation = false;
  String interpolationMode = 'blend';
  String interpolationModel = '';
  int upscalingResolution = 0;
  bool interpolationNpu = true;
  bool videoUpscaling = false;
  bool upscalingNpu = true;
  String upscalingModel = 'lanczos';
  double defaultSpeed = 1.0;
  DefaultAspect defaultAspect = DefaultAspect.fit;
  PlaybackOrientation playbackOrientation = PlaybackOrientation.landscape;
  bool backgroundAudio = false;

  // ---- 제스처 ----
  int doubleTapSeekSeconds = 10;
  int keyboardSeekSeconds = 5;
  bool gestureSeek = true;
  bool gestureBrightness = true;
  bool gestureVolume = true;
  bool longPressSpeed = true;
  double swipeSeekSpanSeconds = 180; // 화면 전체 폭 = N초
  int wheelVolumeStep = 2; // 마우스 휠 한 칸당 볼륨 % (방향키는 2배)

  // ---- 자막 ----
  double subtitleFontSize = 44;
  bool subtitleAutoLoad = true;
  String subtitleEncoding = 'auto'; // auto, utf-8, cp949(euc-kr) ...
  int subtitleColor = 0xFFFFFFFF;
  bool subtitleBackground = false;

  // ---- 브라우저 ----
  bool showHiddenFiles = false;
  String homepage = 'https://www.google.com';
  AppThemeMode themeMode = AppThemeMode.system;
  int primaryColor = 0xFF2D9CFF;
  int secondaryColor = 0xFF80CBC4;
  OutputQuality outputQuality = OutputQuality.original;
  final Map<String, FolderSort> _folderSorts = {};

  FolderSort folderSort(String key) => _folderSorts[key] ?? const FolderSort();

  void setFolderSort(String key, FolderSort sort) => update((s) => s._folderSorts[key] = sort);

  bool preventCapture = false;
  bool showThumbnails = true;
  bool dohEnabled = false;
  String dohUrl = 'https://dns.google/dns-query';
  bool byeDpiEnabled = false;
  bool networkForResources = false;
  bool get networkEnabled => dohEnabled || byeDpiEnabled;
  String dropboxAppKey = '';
  String oneDriveClientId = '';
  String googleDesktopClientId = '';
  String googleAndroidClientId = '';

  // ---- 다운로드 ----
  String? downloadDir; // null이면 기본 폴더
  String? downloadServerId; // Server or cloud account ID; upload after download.
  String? downloadServerDir;
  int maxConcurrentDownloads = 2;
  int hlsParallelSegments = 4;
  int hlsDecryptionWorkers = 2; // 0: no additional CPU concurrency limit.
  int downloadConversionThreads = -1; // -1: balanced, 0: FFmpeg automatic.
  String? ffmpegPath; // null이면 자동 탐색

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final raw = _prefs.getString(_k);
    if (raw == null) return;
    try {
      _fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {}
  }

  void update(void Function(AppSettings s) fn) {
    fn(this);
    if (!networkEnabled) networkForResources = false;
    notifyListeners();
    _prefs.setString(_k, jsonEncode(_toJson()));
  }

  Map<String, dynamic> _toJson() => {
    'resumeMode': resumeMode.index,
    'autoPlayNext': autoPlayNext,
    'hw': hardwareDecoding,
    'frameInterpolation': frameInterpolation,
    'interpolationMode': interpolationMode,
    'interpolationModel': interpolationModel,
    'upscalingResolution': upscalingResolution,
    'interpolationNpu': interpolationNpu,
    'videoUpscaling': videoUpscaling,
    'upscalingNpu': upscalingNpu,
    'upscalingModel': upscalingModel,
    'speed': defaultSpeed,
    'aspect': defaultAspect.index,
    'playbackOrientation': playbackOrientation.name,
    'bgAudio': backgroundAudio,
    'dt': doubleTapSeekSeconds,
    'ks': keyboardSeekSeconds,
    'gSeek': gestureSeek,
    'gBright': gestureBrightness,
    'gVol': gestureVolume,
    'lp': longPressSpeed,
    'span': swipeSeekSpanSeconds,
    'wheel': wheelVolumeStep,
    'subSize': subtitleFontSize,
    'subAuto': subtitleAutoLoad,
    'subEnc': subtitleEncoding,
    'subColor': subtitleColor,
    'subBg': subtitleBackground,
    'hidden': showHiddenFiles,
    'homepage': homepage,
    'themeMode': themeMode.name,
    'primaryColor': primaryColor,
    'secondaryColor': secondaryColor,
    'outputQuality': outputQuality.name,
    'folderSorts': _folderSorts.map((key, value) => MapEntry(key, value.toJson())),
    'preventCapture': preventCapture,
    'thumbs': showThumbnails,
    'dohEnabled': dohEnabled,
    'networkConfigVersion': 1,
    'dohUrl': dohUrl,
    'byeDpiEnabled': byeDpiEnabled,
    'networkForResources': networkForResources,
    'dropboxAppKey': dropboxAppKey,
    'oneDriveClientId': oneDriveClientId,
    'googleDesktopClientId': googleDesktopClientId,
    'googleAndroidClientId': googleAndroidClientId,
    'dlDir': downloadDir,
    'dlSrv': downloadServerId,
    'dlSrvDir': downloadServerDir,
    'dlMax': maxConcurrentDownloads,
    'hlsPar': hlsParallelSegments,
    'hlsDecryptionWorkers': hlsDecryptionWorkers,
    'downloadConversionThreads': downloadConversionThreads,
    'ffmpeg': ffmpegPath,
  };

  void _fromJson(Map<String, dynamic> j) {
    T v<T>(String k, T d) => j[k] is T ? j[k] as T : d;
    resumeMode = ResumeMode.values[v('resumeMode', 0)];
    autoPlayNext = v('autoPlayNext', true);
    hardwareDecoding = v('hw', true);
    frameInterpolation = j['frameInterpolation'] == true;
    interpolationMode = j['interpolationMode'] == 'rife' ? 'rife' : 'blend';
    interpolationModel = j['interpolationModel'] is String ? j['interpolationModel'] as String : '';
    upscalingResolution =
        j['upscalingResolution'] is int && const [720, 1080, 1440, 2160].contains(j['upscalingResolution'])
        ? j['upscalingResolution'] as int
        : 0;
    interpolationNpu = j['interpolationNpu'] != false;
    videoUpscaling = j['videoUpscaling'] == true;
    upscalingNpu = j['upscalingNpu'] != false;
    upscalingModel = j['upscalingModel'] is String ? j['upscalingModel'] as String : 'lanczos';
    defaultSpeed = (j['speed'] as num?)?.toDouble() ?? 1.0;
    defaultAspect = DefaultAspect.values[v('aspect', 0)];
    playbackOrientation = PlaybackOrientation.values.firstWhere(
      (e) => e.name == j['playbackOrientation'],
      orElse: () => PlaybackOrientation.landscape,
    );
    backgroundAudio = v('bgAudio', false);
    doubleTapSeekSeconds = v('dt', 10);
    keyboardSeekSeconds = v('ks', 5);
    gestureSeek = v('gSeek', true);
    gestureBrightness = v('gBright', true);
    gestureVolume = v('gVol', true);
    longPressSpeed = v('lp', true);
    swipeSeekSpanSeconds = (j['span'] as num?)?.toDouble() ?? 180;
    wheelVolumeStep = v('wheel', 2);
    subtitleFontSize = (j['subSize'] as num?)?.toDouble() ?? 44;
    subtitleAutoLoad = v('subAuto', true);
    subtitleEncoding = v('subEnc', 'auto');
    subtitleColor = v('subColor', 0xFFFFFFFF);
    subtitleBackground = v('subBg', false);
    showHiddenFiles = v('hidden', false);
    homepage = normalizeHomepage(v('homepage', 'https://www.google.com')) ?? 'https://www.google.com';
    themeMode = AppThemeMode.values.firstWhere((e) => e.name == j['themeMode'], orElse: () => AppThemeMode.system);
    primaryColor = v('primaryColor', 0xFF2D9CFF) | 0xFF000000;
    secondaryColor = v('secondaryColor', 0xFF80CBC4) | 0xFF000000;
    outputQuality = OutputQuality.values.firstWhere(
      (e) => e.name == j['outputQuality'],
      orElse: () => OutputQuality.original,
    );
    _folderSorts.clear();
    final sorts = j['folderSorts'];
    if (sorts is Map) {
      for (final entry in sorts.entries) {
        if (entry.key is String && entry.value is Map) {
          _folderSorts[entry.key as String] = FolderSort.fromJson(entry.value as Map);
        }
      }
    }
    preventCapture = v('preventCapture', false);
    showThumbnails = v('thumbs', true);
    dohEnabled = v('dohEnabled', false);
    dohUrl = v('dohUrl', 'https://dns.google/dns-query');
    // The unfinished network settings previously serialized an untested default.
    if (!j.containsKey('networkConfigVersion') && dohUrl == 'https://cloudflare-dns.com/dns-query') {
      dohUrl = 'https://dns.google/dns-query';
    }
    byeDpiEnabled = v('byeDpiEnabled', false);
    networkForResources = networkEnabled && v('networkForResources', false);
    dropboxAppKey = v('dropboxAppKey', '');
    oneDriveClientId = v('oneDriveClientId', '');
    googleDesktopClientId = v('googleDesktopClientId', '');
    googleAndroidClientId = v('googleAndroidClientId', '');
    downloadDir = j['dlDir'] as String?;
    downloadServerId = j['dlSrv'] as String?;
    downloadServerDir = j['dlSrvDir'] as String?;
    maxConcurrentDownloads = v('dlMax', 2);
    hlsParallelSegments = v('hlsPar', 4);
    hlsDecryptionWorkers =
        j['hlsDecryptionWorkers'] is int && const [0, 1, 2, 4, 8, 16].contains(j['hlsDecryptionWorkers'])
        ? j['hlsDecryptionWorkers'] as int
        : 2;
    downloadConversionThreads =
        j['downloadConversionThreads'] is int && const [-1, 0, 1, 2, 4, 8, 16].contains(j['downloadConversionThreads'])
        ? j['downloadConversionThreads'] as int
        : -1;
    ffmpegPath = j['ffmpeg'] as String?;
  }
}

String? normalizeHomepage(String input) {
  final value = input.trim();
  if (value.isEmpty || RegExp(r'\s').hasMatch(value)) return null;
  final uri = Uri.tryParse(value.contains('://') ? value : 'https://$value');
  if (uri == null || !['http', 'https'].contains(uri.scheme) || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri.toString();
}
