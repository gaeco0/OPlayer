import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'folder_sort.dart';

enum ResumeMode { auto, ask, off }

enum DefaultAspect { fit, fill, stretch }

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
  double defaultSpeed = 1.0;
  DefaultAspect defaultAspect = DefaultAspect.fit;
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
  final Map<String, FolderSort> _folderSorts = {};

  FolderSort folderSort(String key) => _folderSorts[key] ?? const FolderSort();

  void setFolderSort(String key, FolderSort sort) => update((s) => s._folderSorts[key] = sort);

  bool preventCapture = false;
  bool showThumbnails = true;
  bool dohEnabled = false;
  String dohUrl = 'https://dns.google/dns-query';
  bool byeDpiEnabled = false;
  bool networkForResources = true;
  String dropboxAppKey = '';
  String oneDriveClientId = '';

  // ---- 다운로드 ----
  String? downloadDir; // null이면 기본 폴더
  String? downloadServerId; // 설정 시 받은 뒤 이 서버로 업로드
  String? downloadServerDir;
  int maxConcurrentDownloads = 2;
  int hlsParallelSegments = 4;
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
    notifyListeners();
    _prefs.setString(_k, jsonEncode(_toJson()));
  }

  Map<String, dynamic> _toJson() => {
    'resumeMode': resumeMode.index,
    'autoPlayNext': autoPlayNext,
    'hw': hardwareDecoding,
    'speed': defaultSpeed,
    'aspect': defaultAspect.index,
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
    'dlDir': downloadDir,
    'dlSrv': downloadServerId,
    'dlSrvDir': downloadServerDir,
    'dlMax': maxConcurrentDownloads,
    'hlsPar': hlsParallelSegments,
    'ffmpeg': ffmpegPath,
  };

  void _fromJson(Map<String, dynamic> j) {
    T v<T>(String k, T d) => j[k] is T ? j[k] as T : d;
    resumeMode = ResumeMode.values[v('resumeMode', 0)];
    autoPlayNext = v('autoPlayNext', true);
    hardwareDecoding = v('hw', true);
    defaultSpeed = (j['speed'] as num?)?.toDouble() ?? 1.0;
    defaultAspect = DefaultAspect.values[v('aspect', 0)];
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
    networkForResources = v('networkForResources', true);
    dropboxAppKey = v('dropboxAppKey', '');
    oneDriveClientId = v('oneDriveClientId', '');
    downloadDir = j['dlDir'] as String?;
    downloadServerId = j['dlSrv'] as String?;
    downloadServerDir = j['dlSrvDir'] as String?;
    maxConcurrentDownloads = v('dlMax', 2);
    hlsParallelSegments = v('hlsPar', 4);
    ffmpegPath = j['ffmpeg'] as String?;
  }
}
