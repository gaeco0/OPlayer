import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'app_release.dart';

const appUpdateChannel = MethodChannel('oplayer/updates');

class AppUpdater extends ChangeNotifier {
  AppUpdater({
    http.Client Function()? clientFactory,
    Future<Directory> Function()? cacheDirectory,
    String? installedVersion,
    UpdateChannel? installedChannel,
    String? target,
    List<String>? abis,
    this.tv = false,
  }) : _clientFactory = clientFactory ?? (() => IOClient(HttpClient())),
       _cacheDirectory = cacheDirectory ?? getTemporaryDirectory,
       current = AppVersion.parse(installedVersion ?? '0.0.0')!,
       target = target ?? _target(),
       abis = abis ?? [],
       installedChannel =
           installedChannel ??
           (installedVersion != null
               ? AppVersion.parse(installedVersion)!.channel
               : UpdateChannel.values.byName(
                   const String.fromEnvironment('OPLAYER_UPDATE_CHANNEL', defaultValue: 'nightly'),
                 )),
       _metadataReady = installedVersion != null;
  static final instance = AppUpdater();
  final http.Client Function() _clientFactory;
  final Future<Directory> Function() _cacheDirectory;
  AppVersion current;
  final UpdateChannel installedChannel;
  final String target;
  List<String> abis;
  bool tv;
  final bool _metadataReady;
  SharedPreferences? _prefs;
  Future<void>? _initializing;
  UpdateChannel channel = UpdateChannel.stable;
  bool automatic = true;
  bool checking = false, downloading = false, installing = false;
  bool get busy => checking || downloading || installing;
  AppRelease? release;
  File? verifiedFile;
  String? _verifiedHash;
  String? error;
  String phase = '';
  bool hasChecked = false;
  int received = 0, total = 0;
  int _generation = 0;
  bool _cancelled = false;
  http.Client? _checkClient, _downloadClient;
  Completer<void>? _abort;
  DateTime? _lastAttempt;
  bool get available =>
      release != null && (release!.version.channel != installedChannel || release!.version.compareTo(current) > 0);
  ReleaseAsset? get asset => release?.assetFor(target, tv: tv, abis: abis);

  static String _target() => switch (Abi.current()) {
    Abi.androidArm || Abi.androidArm64 || Abi.androidX64 || Abi.androidIA32 => 'android',
    Abi.windowsX64 => 'windows-x64',
    Abi.linuxX64 => 'linux-x64',
    Abi.macosArm64 => 'macos-arm64',
    _ => 'unsupported',
  };

  Future<void> init() => _initializing ??= _init().catchError((Object e) {
    _initializing = null;
    error = '앱 버전 정보를 읽지 못했습니다: $e';
    notifyListeners();
  });

  Future<void> _init() async {
    if (!_metadataReady) {
      final info = await PackageInfo.fromPlatform();
      // Apple's native build name strips prerelease labels. Read the exact
      // bundled source version so beta/nightly ordering is identical on every OS.
      final manifest = await rootBundle.loadString('pubspec.yaml');
      final sourceVersion = RegExp(r'^version:\s*(\S+)\s*$', multiLine: true).firstMatch(manifest)?.group(1);
      final parsed = AppVersion.parse(sourceVersion ?? info.version);
      if (parsed == null) throw const FormatException('지원하지 않는 앱 버전');
      current = parsed;
      tv = info.packageName.endsWith('.tv');
      if (Platform.isAndroid) {
        abis = (await appUpdateChannel.invokeListMethod<String>('abis')) ?? [];
      }
    }
    _prefs = await SharedPreferences.getInstance();
    automatic = _prefs!.getBool('appUpdateAutomatic') ?? true;
    channel = UpdateChannel.values.firstWhere(
      (c) => c.name == _prefs!.getString('appUpdateChannel'),
      orElse: () => installedChannel,
    );
    notifyListeners();
  }

  Future<void> setAutomatic(bool value) async {
    await init();
    if (_prefs == null) return;
    await _prefs!.setBool('appUpdateAutomatic', value);
    automatic = value;
    notifyListeners();
  }

  Future<void> setChannel(UpdateChannel value) async {
    if (downloading || installing) throw StateError('다운로드·설치가 끝난 뒤 채널을 바꿔 주세요');
    await init();
    if (_prefs == null) return;
    _generation++;
    _checkClient?.close();
    checking = false;
    channel = value;
    release = null;
    hasChecked = false;
    verifiedFile = null;
    error = null;
    _lastAttempt = null;
    await _prefs!.setString('appUpdateChannel', value.name);
    notifyListeners();
    await check(force: true);
  }

  Future<void> check({bool force = false}) async {
    await init();
    final prefs = _prefs;
    if (prefs == null || busy || (!force && !automatic)) return;
    final now = DateTime.now();
    final last = prefs.getInt('appUpdateLastCheck:${channel.name}');
    if (!force &&
        ((last != null && now.difference(DateTime.fromMillisecondsSinceEpoch(last)) < const Duration(hours: 6)) ||
            (_lastAttempt != null && now.difference(_lastAttempt!) < const Duration(minutes: 15)))) {
      return;
    }
    _lastAttempt = now;
    final generation = ++_generation;
    final requestedChannel = channel;
    final client = _clientFactory();
    _checkClient = client;
    checking = true;
    error = null;
    notifyListeners();
    try {
      AppRelease? found;
      for (var page = 1; page <= 3; page++) {
        final path = requestedChannel == UpdateChannel.stable
            ? '/repos/gaeco0/OPlayer/releases/latest'
            : '/repos/gaeco0/OPlayer/releases?per_page=30&page=$page';
        final response = await _get(client, Uri.parse('https://api.github.com$path'));
        if (response.statusCode == 404) break;
        if (response.statusCode != 200) throw HttpException('업데이트 확인 실패 (HTTP ${response.statusCode})');
        final json = jsonDecode(utf8.decode(await _read(response, 8 * 1024 * 1024)));
        final values = json is List ? json : [json];
        found = latestRelease(values.whereType<Map>().map(AppRelease.parse).whereType<AppRelease>(), requestedChannel);
        if (found != null || values.length < 30 || requestedChannel == UpdateChannel.stable) break;
      }
      if (generation != _generation) return;
      release = found;
      hasChecked = true;
      verifiedFile = null;
      await prefs.setInt('appUpdateLastCheck:${requestedChannel.name}', now.millisecondsSinceEpoch);
    } catch (e) {
      if (generation == _generation) error = '업데이트를 확인하지 못했습니다. $e';
    } finally {
      client.close();
      if (generation == _generation) {
        _checkClient = null;
        checking = false;
        notifyListeners();
      }
    }
  }

  static Future<http.StreamedResponse> _get(http.Client client, Uri uri, {Future<void>? abort}) async {
    for (var redirects = 0; redirects <= 5; redirects++) {
      if (uri.scheme != 'https' ||
          uri.port != 443 ||
          uri.userInfo.isNotEmpty ||
          !(const ['api.github.com', 'github.com'].contains(uri.host) || uri.host.endsWith('.githubusercontent.com'))) {
        throw const HttpException('허용하지 않는 업데이트 다운로드 주소');
      }
      final request = http.AbortableRequest('GET', uri, abortTrigger: abort)..followRedirects = false;
      request.headers.addAll({
        'Accept': uri.host == 'api.github.com' ? 'application/vnd.github+json' : 'application/octet-stream',
        'User-Agent': 'OPlayer-Updater',
        'Accept-Encoding': 'identity',
      });
      final response = await client.send(request).timeout(const Duration(seconds: 25));
      if (![301, 302, 303, 307, 308].contains(response.statusCode)) return response;
      final location = response.headers['location'];
      if (location == null) throw const HttpException('업데이트 이동 주소가 없습니다');
      await _read(response, 1024 * 1024);
      uri = uri.resolve(location);
    }
    throw const HttpException('업데이트 이동 횟수 초과');
  }

  static Future<List<int>> _read(http.StreamedResponse response, int limit) async {
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(const Duration(seconds: 25))) {
      if (bytes.length + chunk.length > limit) throw const HttpException('업데이트 응답 크기 초과');
      bytes.addAll(chunk);
    }
    return bytes;
  }

  void cancelDownload() {
    _cancelled = true;
    if (_abort?.isCompleted == false) _abort!.complete();
    _downloadClient?.close();
  }

  Future<void> download() async {
    final selected = asset, selectedRelease = release;
    if (busy || !available || selected == null || selectedRelease == null) return;
    final client = _clientFactory();
    _downloadClient = client;
    _abort = Completer<void>();
    _cancelled = false;
    downloading = true;
    received = 0;
    total = selected.size;
    error = null;
    verifiedFile = null;
    phase = '업데이트 다운로드 준비 중';
    notifyListeners();
    File? partial;
    try {
      final sums = selectedRelease.assets.singleWhere((a) => a.name == 'SHA256SUMS.txt');
      final response = await _get(client, sums.url, abort: _abort!.future);
      if (response.statusCode != 200) throw const HttpException('업데이트 체크섬을 받지 못했습니다');
      final checksums = utf8.decode(await _read(response, 1024 * 1024));
      final matches = RegExp(
        r'^([0-9a-fA-F]{64})  (.+)\r?$',
        multiLine: true,
      ).allMatches(checksums).where((m) => m[2]!.trim() == selected.name).toList();
      if (matches.length != 1) throw const FormatException('업데이트 체크섬이 없거나 중복됩니다');
      final expected = matches.single[1]!.toLowerCase();
      if (selected.digest != null && selected.digest != expected) throw const FormatException('업데이트 배포 정보의 체크섬이 다릅니다');
      final directory = await Directory(p.join((await _cacheDirectory()).path, 'updates')).create(recursive: true);
      final destination = File(p.join(directory.path, selected.name));
      partial = File('${destination.path}.part');
      final body = await _get(client, selected.url, abort: _abort!.future);
      if (body.statusCode != 200) throw HttpException('업데이트 다운로드 실패 (HTTP ${body.statusCode})');
      if (body.contentLength != null && body.contentLength != selected.size) {
        throw const HttpException('업데이트 파일 크기가 다릅니다');
      }
      phase = '업데이트 다운로드 중';
      final stopwatch = Stopwatch()..start();
      var last = 0;
      final sink = partial.openWrite();
      try {
        await sink.addStream(
          body.stream.timeout(const Duration(seconds: 30)).map((chunk) {
            if (_cancelled) throw const HttpException('업데이트 다운로드 취소');
            received += chunk.length;
            if (received > total) throw const HttpException('업데이트 파일 크기 초과');
            if (stopwatch.elapsedMilliseconds - last >= 150) {
              last = stopwatch.elapsedMilliseconds;
              notifyListeners();
            }
            return chunk;
          }),
        );
      } finally {
        await sink.close();
      }
      if (received != total) throw const HttpException('업데이트 파일이 완전히 다운로드되지 않았습니다');
      phase = '업데이트 무결성 확인 중';
      notifyListeners();
      if ((await sha256.bind(partial.openRead()).first).toString() != expected) {
        throw const FormatException('업데이트 파일 체크섬 검증 실패');
      }
      if (_cancelled) throw const HttpException('업데이트 다운로드 취소');
      if (await destination.exists()) await destination.delete();
      verifiedFile = await partial.rename(destination.path);
      _verifiedHash = expected;
      phase = '설치 준비 완료';
    } catch (e) {
      error = _cancelled ? null : '업데이트를 다운로드하지 못했습니다. $e';
      phase = _cancelled ? '다운로드 취소됨' : '';
    } finally {
      client.close();
      _downloadClient = null;
      _abort = null;
      downloading = false;
      if (partial != null && await partial.exists()) await partial.delete();
      notifyListeners();
    }
  }

  Future<void> install() async {
    if (busy || verifiedFile == null) return;
    installing = true;
    notifyListeners();
    try {
      await _install();
    } finally {
      installing = false;
      notifyListeners();
    }
  }

  Future<void> _install() async {
    final file = verifiedFile;
    if (file == null || _verifiedHash == null) return;
    if ((await sha256.bind(file.openRead()).first).toString() != _verifiedHash) {
      throw const FormatException('업데이트 파일이 변경되었습니다. 다시 다운로드해 주세요');
    }
    if (Platform.isAndroid) {
      final result = await appUpdateChannel.invokeMethod<String>('install', {
        'path': file.path,
        'sha256': _verifiedHash,
      });
      if (result == 'permission') throw StateError('이 앱의 설치 허용을 켠 뒤 돌아와 설치를 다시 눌러 주세요');
    } else if (Platform.isWindows) {
      final script = File(p.join(file.parent.path, 'install-windows.ps1'));
      await script.writeAsString(await rootBundle.loadString('assets/update/install-windows.ps1'), flush: true);
      final ready = File('${file.path}.ready');
      final failed = File('${file.path}.error');
      for (final flag in [ready, failed]) {
        if (await flag.exists()) await flag.delete();
      }
      final helper = await Process.start('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
        '-Archive',
        file.path,
        '-InstallDir',
        p.dirname(Platform.resolvedExecutable),
        '-AppProcessId',
        '$pid',
        '-ExpectedHash',
        _verifiedHash!,
        '-Version',
        release!.version.name,
      ], mode: ProcessStartMode.detached);
      for (var i = 0; i < 300; i++) {
        if (await failed.exists()) throw StateError(await failed.readAsString());
        if (await ready.exists()) {
          await SystemNavigator.pop();
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      Process.killPid(helper.pid);
      throw StateError('업데이트 준비가 지연되고 있습니다. 앱을 종료하지 말고 다시 확인해 주세요');
    } else {
      if (!await launchUrl(file.uri, mode: LaunchMode.externalApplication)) throw StateError('업데이트 압축 파일을 열지 못했습니다');
    }
  }
}
