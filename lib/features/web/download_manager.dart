import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import '../../core/network/network_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/ffmpeg.dart';
import '../../core/settings.dart';
import '../../core/media_utils.dart';
import '../../core/resource_locks.dart';
import '../../sources/server_store.dart';
import '../../sources/source_registry.dart';
import '../../sources/media_source.dart';
import 'hls.dart';
import 'browser_download_transport.dart';
import 'download_foreground.dart';

enum DownloadKind { direct, hls, resource }

enum DownloadStatus { queued, running, paused, done, failed }

class DownloadTask {
  DownloadTask({
    required this.id,
    required this.url,
    required this.fileName,
    required this.kind,
    this.preferredFileName,
    this.overwriteTarget,
    this.headers = const {},
    this.hlsKeys = const {},
    this.hlsPlaylists = const {},
    this.pageUrl,
    this.outputQuality = OutputQuality.original,
    this.resourceSourceId,
    this.resourceScheme,
    this.resourceEntry,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  final String url;
  final OutputQuality outputQuality;
  final String? resourceSourceId;
  final String? resourceScheme;
  final RemoteEntry? resourceEntry;
  bool outputDone = false;
  String fileName;
  String? preferredFileName;
  final String? overwriteTarget;
  DownloadKind kind;
  Map<String, String> headers;

  /// Keys resolved by the page's own HLS loader. Kept in memory only.
  Map<String, Uint8List> hlsKeys;

  /// Preserve the signed key/segment URLs issued to the browser session.
  Map<String, String> hlsPlaylists;
  String? pageUrl;
  final DateTime createdAt;

  DownloadStatus status = DownloadStatus.queued;
  int received = 0;
  int total = 0; // direct: 바이트, hls: 세그먼트 수
  int done = 0; // hls: 완료 세그먼트 수
  String? savePath;
  String? error;
  double speed = 0; // bytes/sec

  /// 진행 단계 표시 (재생목록 분석 / 조각 받는 중 / 합치는 중 …)
  String? phase;

  /// 완료 후 참고 문구 (예: ffmpeg 없어서 .ts로 저장)
  String? note;

  /// 원격 저장 위치 (추가 시점 설정을 고정)
  String? remoteServerId;
  String? remoteDir;
  String? localDirectory;

  /// 로컬 받기 완료 여부 (업로드만 남은 상태에서 재시도할 때 다시 받지 않게)
  bool localDone = false;

  bool uploading = false;
  bool moving = false;

  /// 업로드 완료 후 원격 재생 키 (smb://서버ID/경로 …)
  String? remoteKey;

  bool get isRemote => remoteServerId != null;

  double? get progress {
    if (status == DownloadStatus.done) return 1;
    return kind == DownloadKind.hls && !uploading && !moving
        ? (total == 0 ? null : done / total)
        : (total == 0 ? null : received / total);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'url': url,
    'quality': outputQuality.name,
    'outputDone': outputDone,
    'name': fileName,
    if (preferredFileName != null) 'preferredName': preferredFileName,
    if (overwriteTarget != null) 'overwriteTarget': overwriteTarget,
    'kind': kind.index,
    'h': headers,
    'page': pageUrl,
    'c': createdAt.millisecondsSinceEpoch,
    's': status == DownloadStatus.running ? DownloadStatus.paused.index : status.index,
    'r': received,
    't': total,
    'd': done,
    'path': savePath,
    'e': error,
    'n': note,
    'rs': remoteServerId,
    'rd': remoteDir,
    'localDir': localDirectory,
    'ld': localDone,
    'up': uploading,
    'moving': moving,
    'rk': remoteKey,
    if (resourceEntry != null)
      'source': {
        'id': resourceSourceId,
        'scheme': resourceScheme,
        'path': resourceEntry!.path,
        'name': resourceEntry!.name,
        'size': resourceEntry!.size,
        'modified': resourceEntry!.modified?.millisecondsSinceEpoch,
        'url': resourceEntry!.directUrl,
      },
  };

  static DownloadTask fromJson(Map<String, dynamic> j) =>
      DownloadTask(
          id: j['id'] as String,
          url: j['url'] as String,
          outputQuality: OutputQuality.values.firstWhere(
            (e) => e.name == j['quality'],
            orElse: () => OutputQuality.original,
          ),
          fileName: j['name'] as String,
          preferredFileName: j['preferredName'] as String?,
          overwriteTarget: j['overwriteTarget'] as String?,
          kind: DownloadKind.values[j['kind'] as int],
          headers: (j['h'] as Map?)?.cast<String, String>() ?? const {},
          pageUrl: j['page'] as String?,
          createdAt: DateTime.fromMillisecondsSinceEpoch(j['c'] as int),
          resourceSourceId: j['source']?['id'] as String?,
          resourceScheme: j['source']?['scheme'] as String?,
          resourceEntry: j['source'] == null
              ? null
              : RemoteEntry(
                  path: j['source']['path'] as String,
                  name: j['source']['name'] as String,
                  size: j['source']['size'] as int? ?? 0,
                  modified: j['source']['modified'] == null
                      ? null
                      : DateTime.fromMillisecondsSinceEpoch(j['source']['modified'] as int),
                  directUrl: j['source']['url'] as String?,
                  isDir: false,
                ),
        )
        ..outputDone = j['outputDone'] == true
        ..status = DownloadStatus.values[j['s'] as int]
        ..received = j['r'] as int
        ..total = j['t'] as int
        ..done = (j['d'] as int?) ?? 0
        ..savePath = j['path'] as String?
        ..error = j['e'] as String?
        ..note = j['n'] as String?
        ..remoteServerId = j['rs'] as String?
        ..remoteDir = j['rd'] as String?
        ..localDirectory = j['localDir'] as String?
        ..localDone = (j['ld'] as bool?) ?? false
        ..uploading = (j['up'] as bool?) ?? false
        ..moving = j['moving'] == true
        ..remoteKey = j['rk'] as String?;
}

class _Cancelled implements Exception {}

/// 직접 파일(mp4/webm…) 이어받기 + HLS(m3u8) 세그먼트 병렬 다운로드·AES-128 복호화·병합.
/// DRM(Widevine/FairPlay, SAMPLE-AES)이 걸린 스트림은 지원하지 않는다.
class DownloadManager extends ChangeNotifier {
  DownloadManager._();
  static final instance = DownloadManager._();

  static const _k = 'downloads_v1';
  final tasks = <DownloadTask>[];
  final _cancel = <String>{};
  final _running = <String>{};
  final _uploadCancellation = <String, Completer<void>>{};
  final _resourceCancellation = <String, Completer<void>>{};
  final _resourceFinished = <String, Completer<void>>{};
  final _discoveredSources = <String, MediaSource>{};
  final _reservedPaths = <String>{};
  final _clients = <String, http.Client>{};
  final _browserClients = <http.Client, BrowserDownloadTransport>{};

  String _newTaskId() {
    var value = DateTime.now().microsecondsSinceEpoch;
    while (tasks.any((task) => task.id == value.toRadixString(36))) {
      value++;
    }
    return value.toRadixString(36);
  }

  late SharedPreferences _prefs;
  Timer? _notifyTimer;
  Timer? _persistTimer;
  DownloadForeground? _foreground;
  VoidCallback? onOpenDownloads;
  bool _openPending = false;

  void openDownloads() {
    if (onOpenDownloads == null) {
      _openPending = true;
    } else {
      onOpenDownloads!();
    }
  }

  void consumeOpenDownloads() {
    if (_openPending) {
      _openPending = false;
      onOpenDownloads?.call();
    }
  }

  void pauseAll({String? reason}) {
    for (final task
        in tasks.where((t) => t.status == DownloadStatus.running || t.status == DownloadStatus.queued).toList()) {
      pause(task);
      if (reason != null) task.error = reason;
    }
    _changed(immediate: true);
  }

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    for (final s in _prefs.getStringList(_k) ?? const <String>[]) {
      try {
        tasks.add(DownloadTask.fromJson(jsonDecode(s) as Map<String, dynamic>));
      } catch (_) {}
    }
    if (Platform.isAndroid && _foreground == null) {
      _foreground = DownloadForeground(
        onPause: (reason) => pauseAll(reason: reason),
        onOpen: openDownloads,
        onError: (_) {
          if (tasks.any((t) => t.status == DownloadStatus.running || t.status == DownloadStatus.queued)) {
            pauseAll(reason: '백그라운드 다운로드 서비스를 시작하지 못했습니다. 앱을 열고 다시 시작해 주세요.');
          }
        },
      );
      if (await _foreground!.consumeOpen()) _openPending = true;
      ResourceLocks.instance.addListener(() => _foreground!.schedule(downloadNotificationState(tasks)));
    }
  }

  int get activeCount => tasks.where((t) => t.status == DownloadStatus.running).length;

  static Future<Directory> downloadDir() async {
    final custom = AppSettings.instance.downloadDir;
    Directory d;
    if (custom != null && custom.isNotEmpty) {
      d = Directory(custom);
    } else if (Platform.isAndroid) {
      d = Directory('/storage/emulated/0/Download/OPlayer');
      try {
        await d.create(recursive: true);
      } catch (_) {
        d = Directory(p.join((await getExternalStorageDirectory())!.path, 'Download'));
      }
    } else if (Platform.isIOS) {
      d = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'Downloads'));
    } else {
      Directory? base;
      try {
        base = await getDownloadsDirectory();
      } catch (_) {}
      try {
        base ??= await getApplicationDocumentsDirectory();
      } catch (_) {}
      d = Directory(p.join((base ?? Directory.systemTemp).path, 'OPlayer'));
    }
    await d.create(recursive: true);
    return d;
  }

  DownloadTask add({
    required String url,
    required String title,
    String? fileName,
    String? overwriteTarget,
    Map<String, String> headers = const {},
    Map<String, Uint8List> hlsKeys = const {},
    Map<String, String> hlsPlaylists = const {},
    String? pageUrl,
    bool? hls,
    OutputQuality? outputQuality,
  }) {
    final isHls = hls ?? url.toLowerCase().contains('.m3u8');
    final quality = outputQuality ?? AppSettings.instance.outputQuality;
    final name = suggestedFileName(url: url, title: fileName ?? title, hls: isHls, outputQuality: quality);
    final st = AppSettings.instance;
    final destination =
        st.downloadServerId != null &&
            (ServerStore.instance.server(st.downloadServerId!) != null ||
                ServerStore.instance.account(st.downloadServerId!) != null)
        ? st.downloadServerId
        : null;
    // Reuse the task ID (and its segment cache), but replace expired session data.
    final previous = isHls
        ? tasks
              .where(
                (t) =>
                    t.kind == DownloadKind.hls &&
                    t.url == url &&
                    (t.preferredFileName ?? t.fileName) == name &&
                    t.outputQuality == quality &&
                    t.overwriteTarget == overwriteTarget &&
                    t.remoteServerId == destination &&
                    (destination == null || t.remoteDir == (st.downloadServerDir ?? '/')) &&
                    !t.localDone &&
                    !_running.contains(t.id) &&
                    [DownloadStatus.failed, DownloadStatus.paused].contains(t.status),
              )
              .firstOrNull
        : null;
    if (previous != null) {
      previous
        ..headers = Map.of(headers)
        ..hlsKeys = Map.of(hlsKeys)
        ..hlsPlaylists = Map.of(hlsPlaylists)
        ..pageUrl = pageUrl
        ..speed = 0
        ..phase = '기존 조각 확인 중';
      resume(previous);
      return previous;
    }
    final task = DownloadTask(
      id: _newTaskId(),
      url: url,
      fileName: name,
      preferredFileName: fileName == null ? null : name,
      overwriteTarget: overwriteTarget,
      kind: isHls ? DownloadKind.hls : DownloadKind.direct,
      headers: Map.of(headers),
      hlsKeys: Map.of(hlsKeys),
      hlsPlaylists: Map.of(hlsPlaylists),
      pageUrl: pageUrl,
      outputQuality: quality,
    );
    if (destination != null) {
      task
        ..remoteServerId = st.downloadServerId
        ..remoteDir = st.downloadServerDir ?? '/';
    }
    tasks.insert(0, task);
    _persist();
    _schedule();
    return task;
  }

  void pause(DownloadTask t) {
    if (t.status == DownloadStatus.running) {
      _cancel.add(t.id);
      final cancellation = _uploadCancellation[t.id];
      if (cancellation != null && !cancellation.isCompleted) cancellation.complete();
      final resourceCancellation = _resourceCancellation[t.id];
      if (resourceCancellation != null && !resourceCancellation.isCompleted) resourceCancellation.complete();
      _clients.remove(t.id)?.close();
    }
    t.status = DownloadStatus.paused;
    _changed(immediate: true);
  }

  void resume(DownloadTask t) {
    if (t.status == DownloadStatus.running || t.status == DownloadStatus.done) return;
    t.status = DownloadStatus.queued;
    t.error = null;
    _changed(immediate: true);
    _schedule();
  }

  bool canChangeDestination(DownloadTask task) =>
      tasks.contains(task) &&
      !_running.contains(task.id) &&
      [DownloadStatus.failed, DownloadStatus.paused, DownloadStatus.done].contains(task.status) &&
      task.localDone &&
      task.savePath != null &&
      File(task.savePath!).existsSync();

  /// Retarget only this retained file. Global download settings stay unchanged.
  Future<void> changeDestination(DownloadTask task, {String? serverId, required String directory}) async {
    void check() {
      if (!canChangeDestination(task)) throw StateError('받은 파일이 있는 실패·일시정지·완료 항목만 이동할 수 있습니다');
    }

    check();
    await ResourceLocks.instance.requireAccess(downloadsResourceKey);
    await ResourceLocks.instance.requireAccess(task.savePath!);
    if (directory.trim().isEmpty) throw const FormatException('저장할 폴더를 선택해 주세요');
    if (serverId == null) {
      await ResourceLocks.instance.requireAccess(Directory(directory).absolute.path);
    } else {
      final source = await SourceRegistry.instance.forDestination(serverId);
      if (!source.canUpload) throw UnsupportedError('이 저장소는 업로드를 지원하지 않습니다');
      if (source.scheme == 'smb' && directory == '/') throw StateError('SMB 공유 폴더를 선택해 주세요');
      await ResourceLocks.instance.requireAccess(source.keyFor(directory));
    }
    // The item may have been resumed or removed while a picker/auth dialog was open.
    check();
    task
      ..remoteServerId = serverId
      ..remoteDir = serverId == null ? null : directory
      ..localDirectory = serverId == null ? Directory(directory).absolute.path : null
      ..remoteKey = null
      ..uploading = false
      ..moving = false
      ..phase = null
      ..note = null
      ..error = null
      ..speed = 0
      ..status = DownloadStatus.queued;
    _changed(immediate: true);
    _schedule();
  }

  Future<void> remove(DownloadTask t, {bool deleteFile = false}) async {
    if (t.status == DownloadStatus.running) pause(t);
    tasks.remove(t);
    await _resourceFinished[t.id]?.future;
    final sp = t.savePath;
    if (sp != null) {
      // .part(받다 만 파일)는 항상, 원격 저장용 캐시 파일도 항상, 받은 파일은 요청할 때만 삭제
      final targets = ['$sp.part', if (deleteFile || t.isRemote) sp];
      for (final f in targets) {
        try {
          await File(f).delete();
        } catch (_) {}
      }
    }
    await _cleanupTemp(t);
    _changed(immediate: true);
  }

  /// A resource file is copied byte-for-byte to the device, independent of the
  /// browser's transcoding preset and remote upload destination.
  Future<DownloadTask> addResource(
    MediaSource source,
    RemoteEntry entry, {
    String? fileName,
    String? overwriteTarget,
  }) async {
    if (entry.isDir) throw UnsupportedError('파일을 선택해 주세요. 폴더 다운로드는 지원하지 않습니다');
    await ResourceLocks.instance.requireAccess(source.keyFor(entry.path));
    await ResourceLocks.instance.requireAccess(downloadsResourceKey);
    final task = DownloadTask(
      id: _newTaskId(),
      url: source.keyFor(entry.path),
      fileName: resourceDownloadName(fileName ?? entry.name),
      preferredFileName: fileName == null ? null : resourceDownloadName(fileName),
      overwriteTarget: overwriteTarget,
      kind: DownloadKind.resource,
      resourceSourceId: source.id,
      resourceScheme: source.scheme,
      resourceEntry: entry,
    )..total = entry.size;
    if (source.scheme == 'dlna') _discoveredSources[source.id] = source;
    tasks.insert(0, task);
    _changed(immediate: true);
    _schedule();
    return task;
  }

  /// 목록 정리. 진행 중·대기 중 항목은 남긴다.
  Future<int> clear({bool done = true, bool failed = true, bool paused = false}) async {
    final targets = tasks
        .where(
          (t) =>
              (done && t.status == DownloadStatus.done) ||
              (failed && t.status == DownloadStatus.failed) ||
              (paused && t.status == DownloadStatus.paused),
        )
        .toList();
    for (final t in targets) {
      await remove(t);
    }
    return targets.length;
  }

  void _schedule() {
    final max = AppSettings.instance.maxConcurrentDownloads;
    for (final t in tasks.reversed) {
      if (activeCount >= max) break;
      if (t.status == DownloadStatus.queued && !_running.contains(t.id)) _run(t);
    }
  }

  Future<void> _run(DownloadTask t) async {
    _running.add(t.id);
    t.status = DownloadStatus.running;
    _cancel.remove(t.id);
    _changed();
    if (t.kind == DownloadKind.resource) _resourceFinished[t.id] = Completer<void>();
    final client = IOClient(NetworkService.instance.createHttpClient(browser: t.kind != DownloadKind.resource));
    _clients[t.id] = client;
    String? reservedPath;
    String? overwriteReservation;
    try {
      // Establish Android foreground priority before the first request or file write.
      await _foreground?.update(downloadNotificationState(tasks));
      _check(t);
      if (t.remoteServerId != null) {
        final source = await SourceRegistry.instance.forDestination(t.remoteServerId!, authorizedUpload: true);
        await _requireDestinationAccess(source.keyFor(''));
        await _requireDestinationAccess(source.keyFor(t.remoteDir ?? source.rootPath));
      } else {
        await _requireDestinationAccess(t.localDirectory ?? (await downloadDir()).path);
      }
      // 원격 저장이면 앱 캐시에 받은 뒤 업로드하고 지운다
      final saveDirectory = t.isRemote ? null : await _localDirectory(t);
      if (saveDirectory != null && t.overwriteTarget == resourceKey(p.join(saveDirectory.path, t.fileName))) {
        final key = _reservationKey(t.overwriteTarget!);
        if (!_reservedPaths.add(key)) throw StateError('같은 파일로 다운로드 중입니다');
        overwriteReservation = key;
      }
      final dir = t.isRemote || t.overwriteTarget != null ? await _pendingUploadDir() : saveDirectory!;
      t.savePath ??= await _uniquePath(dir, t.fileName, reserve: true);
      reservedPath = t.savePath;
      _reservedPaths.add(_reservationKey(reservedPath!));
      if (!(t.localDone && await File(t.savePath!).exists())) {
        t.uploading = false;
        if (t.kind == DownloadKind.resource) {
          await _resource(t);
        } else if (t.kind == DownloadKind.direct) {
          await _direct(t, client);
        } else {
          await _hls(t, client);
        }
        t.localDone = true;
      }
      if (t.kind != DownloadKind.resource &&
          !t.outputDone &&
          (t.outputQuality != OutputQuality.original ||
              (t.kind == DownloadKind.direct &&
                  ![
                    '.mp4',
                    '.m4a',
                    '.mp3',
                    '.aac',
                    '.ogg',
                    '.flac',
                    '.wav',
                  ].contains(p.extension(t.savePath!).toLowerCase())))) {
        await _convertTask(t);
      }
      _check(t);
      await _applyPreferredName(t, reservedPath);
      if (t.isRemote) {
        await _upload(t);
      } else {
        await _saveLocally(t, saveDirectory!);
      }
      _check(t);
      t.status = DownloadStatus.done;
      t.speed = 0;
      t.phase = null;
      t.moving = false;
    } on _Cancelled {
      // 일시정지
    } catch (e) {
      if (_cancel.contains(t.id)) {
        // 일시정지 중 발생한 소켓 에러
      } else {
        t.status = DownloadStatus.failed;
        t.error = '$e';
        t.phase = null;
      }
    } finally {
      _uploadCancellation.remove(t.id);
      _clients.remove(t.id);
      try {
        await _browserClients.remove(client)?.close();
      } catch (_) {}
      client.close();
      if (t.status == DownloadStatus.done || t.status == DownloadStatus.failed) {
        try {
          await _foreground?.finished(
            id: t.id,
            name: ResourceLocks.instance.protects(downloadsResourceKey) ? '다운로드' : t.fileName,
            success: t.status == DownloadStatus.done,
          );
        } catch (_) {} // Notification errors must not turn a saved file into a failed download.
      }
      _running.remove(t.id);
      if (reservedPath != null) _reservedPaths.remove(_reservationKey(reservedPath));
      if (overwriteReservation != null) _reservedPaths.remove(overwriteReservation);
      if (t.savePath != null) _reservedPaths.remove(_reservationKey(t.savePath!));
      _resourceCancellation.remove(t.id);
      _resourceFinished.remove(t.id)?.complete();
      _changed(immediate: true);
      _schedule();
    }
  }

  void _check(DownloadTask t) {
    if (_cancel.contains(t.id)) throw _Cancelled();
  }

  Future<Directory> _localDirectory(DownloadTask task) async {
    if (task.localDirectory == null) return downloadDir();
    return Directory(task.localDirectory!).create(recursive: true);
  }

  Future<({String key, bool exists, bool directory, bool busy})> inspectFileName(
    String name, {
    required bool resource,
  }) async {
    name = resourceDownloadName(name);
    final settings = AppSettings.instance;
    final destination = resource ? null : settings.downloadServerId;
    if (destination != null) {
      final source = await SourceRegistry.instance.forDestination(destination);
      if (!source.canUpload) throw UnsupportedError('이 저장소는 업로드를 지원하지 않습니다');
      final directory = settings.downloadServerDir ?? source.rootPath;
      final key = resourceKey(source.keyFor(MediaSource.joinRemote(directory, name)));
      await ResourceLocks.instance.requireAccess(source.keyFor(directory));
      await ResourceLocks.instance.requireAccess(key);
      final entries = await source.list(directory);
      final entry = entries.where((e) => e.name.toLowerCase() == name.toLowerCase()).firstOrNull;
      if (entry != null) await ResourceLocks.instance.requireAccess(source.keyFor(entry.path));
      final busy = tasks.any(
        (t) =>
            [DownloadStatus.running, DownloadStatus.queued].contains(t.status) &&
            t.remoteServerId == destination &&
            resourceKey(source.keyFor(MediaSource.joinRemote(t.remoteDir ?? '/', t.preferredFileName ?? t.fileName))) ==
                key,
      );
      return (key: key, exists: entry != null, directory: entry?.isDir ?? false, busy: busy);
    }
    final path = p.join((await downloadDir()).path, name);
    await ResourceLocks.instance.requireAccess(path);
    final type = await FileSystemEntity.type(path, followLinks: false);
    return (
      key: resourceKey(path),
      exists: type != FileSystemEntityType.notFound,
      directory: type == FileSystemEntityType.directory,
      busy: _reservedPaths.contains(_reservationKey(path)) || await File('$path.part').exists(),
    );
  }

  Future<void> _saveLocally(DownloadTask task, Directory directory) async {
    final original = File(task.savePath!);
    if (p.equals(original.parent.absolute.path, directory.absolute.path)) return;
    await _requireDestinationAccess(original.path);
    _check(task);
    final desired = p.join(directory.path, task.fileName);
    final overwrite = task.overwriteTarget == resourceKey(desired);
    if (overwrite) await _requireDestinationAccess(desired);
    final output = overwrite ? desired : await _uniquePath(directory, task.fileName, reserve: true);
    Directory? stagingDirectory;
    task
      ..moving = true
      ..uploading = false
      ..phase = '기기에 저장 중'
      ..total = await original.length()
      ..received = 0
      ..speed = 0;
    _changed(immediate: true);
    try {
      stagingDirectory = await directory.createTemp('.oplayer-move-');
      final staging = File(p.join(stagingDirectory.path, 'file.part'));
      final sink = staging.openWrite();
      try {
        await sink.addStream(
          original.openRead().map((chunk) {
            _check(task);
            task.received += chunk.length;
            _changed();
            return chunk;
          }),
        );
        await sink.flush();
      } finally {
        await sink.close();
      }
      _check(task);
      if (await staging.length() != task.total) throw const FileSystemException('파일을 끝까지 복사하지 못했습니다');
      // A late name collision must preserve both files, too.
      if (overwrite) await _requireDestinationAccess(output);
      final target = !overwrite && await File(output).exists()
          ? await _uniquePath(directory, task.fileName, reserve: true)
          : output;
      await _requireDestinationAccess(target);
      await staging.rename(target);
      task.savePath = target;
      task.fileName = p.basename(target);
      task.note = '이 기기에 저장됨: $target';
      task.uploading = false;
      // Keep the source until the new local file has been published successfully.
      try {
        await original.delete();
      } catch (_) {
        task.note = '이 기기에 저장됨: $target (기존 파일도 보관됨)';
      }
    } finally {
      _reservedPaths.remove(_reservationKey(output));
      if (stagingDirectory != null && await stagingDirectory.exists()) await stagingDirectory.delete(recursive: true);
    }
  }

  Future<void> _applyPreferredName(DownloadTask task, String? reservedPath) async {
    final preferred = task.preferredFileName;
    if (preferred == null) return;
    final original = File(task.savePath!);
    final name = task.kind == DownloadKind.resource
        ? resourceDownloadName(preferred)
        : browserDownloadName(preferred, p.extension(original.path));
    if (task.isRemote || task.overwriteTarget != null) {
      task.fileName = name;
      task.preferredFileName = null;
      _changed(immediate: true);
      return;
    }
    if (p.basename(original.path) != name) {
      final target = await _uniquePath(
        original.parent,
        name,
        reserve: true,
        reservationOwner: reservedPath,
        currentFile: original.path,
      );
      try {
        _check(task);
        if (!p.equals(original.path, target)) await original.rename(target);
        task.savePath = target;
      } catch (_) {
        _reservedPaths.remove(_reservationKey(target));
        rethrow;
      }
    }
    task.fileName = p.basename(task.savePath!);
    task.preferredFileName = null;
    _changed(immediate: true);
  }

  Future<void> _resource(DownloadTask task) async {
    final entry = task.resourceEntry;
    if (entry == null) throw StateError('원격 파일 정보가 없습니다');
    final cancellation = Completer<void>();
    _resourceCancellation[task.id] = cancellation;
    _check(task);
    final server = ServerStore.instance.server(task.resourceSourceId!);
    final account = ServerStore.instance.account(task.resourceSourceId!);
    final MediaSource source;
    if (server != null) {
      await _requireDestinationAccess(serverResourceKey(server));
      source = await SourceRegistry.instance.forServer(server, authorizedUpload: true);
    } else if (account != null) {
      source = SourceRegistry.instance.forAccount(account);
    } else if (task.resourceScheme == 'dlna' && _discoveredSources.containsKey(task.resourceSourceId)) {
      source = _discoveredSources[task.resourceSourceId]!;
    } else {
      throw StateError('원격 저장소가 삭제되었거나 연결되지 않았습니다. 원격 목록에서 다시 다운로드해 주세요');
    }
    if (source.scheme != task.resourceScheme) throw StateError('원격 저장소 종류가 변경되었습니다');
    await _requireDestinationAccess(source.keyFor(entry.path));
    _check(task);
    task.phase = '${source.displayName}에서 파일 받는 중';
    task.speed = 0;
    _changed(immediate: true);
    var previous = 0;
    final elapsed = Stopwatch()..start();
    var window = 0;
    var first = true;
    final part = File('${task.savePath}.part');
    await source.download(
      entry,
      part,
      cancelled: cancellation.future,
      onProgress: (received, total) {
        _check(task);
        if (first || received < previous) {
          previous = received;
          window = 0;
          elapsed.reset();
          first = false;
        }
        window += received - previous;
        previous = received;
        task.received = received;
        task.total = total;
        if (elapsed.elapsedMilliseconds >= 1000) {
          task.speed = window * 1000 / elapsed.elapsedMilliseconds;
          elapsed.reset();
          window = 0;
        }
        _changed();
      },
    );
    _check(task);
    // Never overwrite another file created while this transfer was paused.
    if (await File(task.savePath!).exists()) {
      task.savePath = await _uniquePath(File(task.savePath!).parent, task.fileName, reserve: true);
    }
    _check(task);
    await part.rename(task.savePath!);
    task.fileName = p.basename(task.savePath!);
    task.received = task.total = await File(task.savePath!).length();
    task.outputDone = true;
  }

  Future<void> _convertTask(DownloadTask t) async {
    _check(t);
    t.phase = '${t.outputQuality.label} 생성 중';
    _changed(immediate: true);
    final input = t.savePath!;
    final ext = t.outputQuality == OutputQuality.audio ? '.m4a' : '.mp4';
    final output = await _uniquePath(
      File(input).parent,
      '${p.basenameWithoutExtension(input)} (${t.outputQuality.name})$ext',
    );
    final (ok, error) = await Ffmpeg.createMp4(video: input, output: output, quality: t.outputQuality);
    if (!ok) {
      if (await File(output).exists()) await File(output).delete();
      if (t.outputQuality == OutputQuality.original) {
        t.note = 'MP4 컨테이너로 옮기지 못해 원본으로 저장했습니다: $error';
        t.outputDone = true;
        return;
      }
      throw '변환 실패 (받은 원본은 보관됨): $error';
    }
    if (_cancel.contains(t.id)) {
      await File(output).delete();
      throw _Cancelled();
    }
    t.savePath = output;
    t.fileName = p.basename(output);
    t.outputDone = true;
    t.received = await File(output).length();
    await File(input).delete();
  }

  Future<void> _requireDestinationAccess(String key) async {
    // Existing jobs may run behind the app lock. Explicit resource locks still
    // require authorization before accessing a protected destination.
    if (ResourceLocks.instance.protects(key)) await ResourceLocks.instance.requireAccess(key);
  }

  // ---------------------------------------------------------------- 직접 다운로드
  Future<void> _direct(DownloadTask t, http.Client client) async {
    final part = File('${t.savePath}.part');
    var start = await part.exists() ? await part.length() : 0;
    final req = http.Request('GET', Uri.parse(t.url))..headers.addAll(t.headers);
    if (start > 0) req.headers['Range'] = 'bytes=$start-';
    final res = await client.send(req);
    if (res.statusCode == 200) {
      start = 0; // 서버가 Range 미지원 → 처음부터
    } else if (res.statusCode != 206) {
      throw _httpError(res.statusCode);
    }
    final len = res.contentLength;
    final iter = StreamIterator(res.stream);

    // 주소에 .m3u8이 없어도 실제 내용이 HLS 재생목록이면 → 조각 받아 합치기로 전환
    final ct = (res.headers['content-type'] ?? '').toLowerCase();
    var first = <int>[];
    if (start == 0 && await iter.moveNext()) first = iter.current;
    final looksPlaylist =
        ct.contains('mpegurl') ||
        (start == 0 &&
            (len == null || len < 8 * 1024 * 1024) &&
            Hls.isPlaylist(utf8.decode(first.take(64).toList(), allowMalformed: true)));
    if (looksPlaylist) {
      await iter.cancel();
      if (await part.exists()) await part.delete();
      t.kind = DownloadKind.hls;
      final ext = t.outputQuality == OutputQuality.audio ? '.m4a' : '.mp4';
      t.savePath = await _uniquePath(File(t.savePath!).parent, '${p.basenameWithoutExtension(t.savePath!)}$ext');
      t.fileName = p.basename(t.savePath!);
      t.received = 0;
      _changed(immediate: true);
      return _hls(t, client);
    }

    t.total = len == null ? 0 : start + len;
    t.received = start;
    final sink = part.openWrite(mode: start > 0 ? FileMode.append : FileMode.write);
    var window = 0;
    var windowStart = DateTime.now();
    Stream<List<int>> rest() async* {
      if (first.isNotEmpty) yield first;
      while (await iter.moveNext()) {
        yield iter.current;
      }
    }

    try {
      await sink.addStream(
        rest().map((chunk) {
          _check(t);
          t.received += chunk.length;
          window += chunk.length;
          final el = DateTime.now().difference(windowStart).inMilliseconds;
          if (el > 1000) {
            t.speed = window * 1000 / el;
            window = 0;
            windowStart = DateTime.now();
          }
          _changed();
          return chunk;
        }),
      );
    } finally {
      await sink.close();
      await iter.cancel();
    }
    _check(t);
    await part.rename(t.savePath!);
    if (t.total == 0) t.total = t.received;
  }

  // ---------------------------------------------------------------- HLS
  Future<Directory> _pendingUploadDir() async {
    final d = Directory(p.join(await _cacheBase(), 'pending_upload'));
    await d.create(recursive: true);
    return d;
  }

  Future<void> _upload(DownloadTask t) async {
    final src = await SourceRegistry.instance.forDestination(t.remoteServerId!, authorizedUpload: true);
    final destinationName = src.displayName;
    if (!src.canUpload) throw '$destinationName 업로드를 지원하지 않습니다';
    final directory = t.remoteDir ?? src.rootPath;
    final entries = await src.list(directory);
    var uploadName = t.fileName;
    final targetKey = resourceKey(src.keyFor(MediaSource.joinRemote(directory, uploadName)));
    final overwrite = t.overwriteTarget == targetKey;
    if (overwrite) {
      await _requireDestinationAccess(targetKey);
      for (final entry in entries.where((e) => e.name.toLowerCase() == uploadName.toLowerCase())) {
        await _requireDestinationAccess(src.keyFor(entry.path));
      }
      if (entries.any((e) => e.name.toLowerCase() == uploadName.toLowerCase() && e.isDir)) {
        throw StateError('같은 이름의 폴더를 덮어쓸 수 없습니다');
      }
    } else {
      final existing = entries.map((e) => e.name.toLowerCase()).toSet();
      final base = p.basenameWithoutExtension(uploadName), extension = p.extension(uploadName);
      for (var n = 1; existing.contains(uploadName.toLowerCase()); n++) {
        uploadName = '$base ($n)$extension';
      }
    }
    await _requireDestinationAccess(src.keyFor(MediaSource.joinRemote(directory, uploadName)));
    final local = File(t.savePath!);
    final size = await local.length();
    _check(t);
    t.uploading = true;
    t.phase = '$destinationName(으)로 업로드 중';
    t.total = size;
    t.received = 0;
    t.done = 0;
    t.speed = 0;
    _changed(immediate: true);
    var window = 0;
    var windowStart = DateTime.now();
    var last = 0;
    final cancellation = Completer<void>();
    _uploadCancellation[t.id] = cancellation;
    final remotePath = await src.upload(
      local,
      directory,
      uploadName,
      overwritePath: overwrite
          ? entries.where((e) => e.name.toLowerCase() == uploadName.toLowerCase() && !e.isDir).firstOrNull?.path
          : null,
      cancelled: cancellation.future,
      onProgress: (sent) {
        _check(t);
        if (sent < last) {
          // A WebDAV connection retry starts a new PUT from byte zero.
          window = 0;
          windowStart = DateTime.now();
          last = 0;
          t.speed = 0;
          t.phase = '$destinationName(으)로 업로드 다시 시도 중';
        }
        window += sent - last;
        last = sent;
        t.received = sent;
        if (sent >= size) t.phase = '$destinationName 서버 저장 확인 중';
        final el = DateTime.now().difference(windowStart).inMilliseconds;
        if (el > 1000) {
          t.speed = window * 1000 / el;
          window = 0;
          windowStart = DateTime.now();
        }
        _changed();
      },
    );
    _check(t);
    t.remoteKey = src.keyFor(remotePath);
    t.fileName = uploadName;
    t.note = '$destinationName:$remotePath에 저장됨';
    t.received = size;
    try {
      await local.delete();
    } catch (_) {}
    t.savePath = null;
  }

  static Future<String> _cacheBase() async {
    try {
      return (await getApplicationCacheDirectory()).path;
    } catch (_) {
      return Directory.systemTemp.path;
    }
  }

  Future<Directory> _tempDir(DownloadTask t) async {
    final d = Directory(p.join(await _cacheBase(), 'hls_${t.id}'));
    await d.create(recursive: true);
    return d;
  }

  Future<void> _cleanupTemp(DownloadTask t) async {
    try {
      final d = Directory(p.join(await _cacheBase(), 'hls_${t.id}'));
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }

  Future<Uint8List> _get(http.Client c, Uri u, Map<String, String> headers, {(int, int)? range}) async {
    final h = {...headers};
    if (range != null) h['Range'] = 'bytes=${range.$2}-${range.$2 + range.$1 - 1}';
    for (var attempt = 0; ; attempt++) {
      try {
        final browser = _browserClients[c];
        if (browser != null) {
          final (status, bytes) = await browser.get(u, h);
          if (status >= 300) throw _httpError(status);
          return bytes;
        }
        final r = await c.get(u, headers: h).timeout(const Duration(seconds: 30));
        if (r.statusCode == 403 && (Platform.isWindows || Platform.isAndroid)) {
          final task = tasks.where((task) => _clients[task.id] == c).firstOrNull;
          if (task?.pageUrl != null) {
            final browser = _browserClients.putIfAbsent(c, () => BrowserDownloadTransport(task!.pageUrl!));
            final (status, bytes) = await browser.get(u, h);
            if (status >= 300) throw _httpError(status);
            return bytes;
          }
        }
        if (r.statusCode >= 300) throw _httpError(r.statusCode);
        return r.bodyBytes;
      } catch (e) {
        if (attempt >= 3) rethrow;
        await Future<void>.delayed(Duration(seconds: 1 << attempt));
      }
    }
  }

  Future<String> _getText(http.Client c, Uri u, Map<String, String> headers) async =>
      utf8.decode(await _get(c, u, headers), allowMalformed: true);

  /// 재생목록을 끝까지 풀어서 실제 조각 목록을 만든다.
  ///  · 마스터(해상도별 목록) → 가장 높은 화질 선택 → 그 목록을 다시 해석 (중첩 마스터도 처리)
  ///  · 미디어 목록 안의 항목이 또 m3u8이면 그 목록을 펼쳐서 이어붙임
  ///  · 영상/음성이 분리된 경우 음성 목록도 함께 반환
  Future<(HlsMediaPlaylist video, HlsMediaPlaylist? audio)> _resolvePlaylist(
    http.Client c,
    Uri uri,
    Map<String, String> headers, {
    int depth = 0,
    Map<String, String> playlists = const {},
  }) async {
    if (depth > 5) throw '재생목록이 너무 깊게 중첩되어 있습니다';
    final text = playlists[uri.toString()] ?? await _getText(c, uri, headers);
    if (!Hls.isPlaylist(text)) throw 'HLS 재생목록이 아닙니다 (응답이 #EXTM3U로 시작하지 않음)';

    if (Hls.isMaster(text)) {
      final master = Hls.parseMasterFull(text, uri);
      if (master.variants.isEmpty) throw '재생목록에 스트림이 없습니다';
      Object? lastError;
      for (final v in master.variants) {
        try {
          final (video, nestedAudio) = await _resolvePlaylist(
            c,
            v.uri,
            headers,
            depth: depth + 1,
            playlists: playlists,
          );
          final rendition = master.audioFor(v);
          HlsMediaPlaylist? audio = nestedAudio;
          if (rendition?.uri != null) {
            audio = (await _resolvePlaylist(c, rendition!.uri!, headers, depth: depth + 1, playlists: playlists)).$1;
          }
          return (video, audio);
        } catch (e) {
          lastError = e; // 최고 화질이 막혀 있으면 다음 화질로
        }
      }
      throw lastError ?? '사용할 수 있는 화질이 없습니다';
    }

    final pl = Hls.parseMedia(text, uri);
    // 항목이 또 m3u8인 경우 펼치기
    final expanded = <HlsSegment>[];
    for (final s in pl.segments) {
      if (s.uri.path.toLowerCase().endsWith('.m3u8')) {
        final (inner, _) = await _resolvePlaylist(c, s.uri, headers, depth: depth + 1, playlists: playlists);
        expanded.addAll(inner.segments);
      } else {
        expanded.add(s);
      }
    }
    pl.segments = expanded;
    return (pl, null);
  }

  Future<void> _hls(DownloadTask t, http.Client client) async {
    t.phase = '재생목록 분석 중';
    _changed(immediate: true);
    final (video, audio) = await _resolvePlaylist(client, Uri.parse(t.url), t.headers, playlists: t.hlsPlaylists);
    final tracks = [video, if (audio != null) audio];
    for (final pl in tracks) {
      if (pl.segments.isEmpty) throw '조각이 없습니다 (라이브 스트림이거나 지원하지 않는 형식)';
      final drm = pl.segments.where((s) => s.key != null && s.key!.method != 'AES-128');
      if (drm.isNotEmpty) throw 'DRM으로 보호된 스트림(${drm.first.key!.method})은 다운로드할 수 없습니다';
    }

    final tmp = await _tempDir(t);
    // Index alone is not an identity: a refreshed/live playlist may contain other
    // segments at the same offsets. Legacy caches without this manifest restart.
    final manifest = File(p.join(tmp.path, 'segments.json'));
    final identity = jsonEncode([
      for (final pl in tracks)
        [
          pl.initSegment?.toString(),
          pl.totalDuration,
          for (final s in pl.segments)
            [
              s.uri.toString(),
              s.sequence,
              s.byteRange?.$1,
              s.byteRange?.$2,
              s.key?.method,
              s.key?.uri?.toString(),
              s.key?.iv == null ? null : base64Encode(s.key!.iv!),
            ],
        ],
    ]);
    if (!await manifest.exists() || await manifest.readAsString() != identity) {
      for (final name in ['v', 'a']) {
        final directory = Directory(p.join(tmp.path, name));
        if (!await directory.exists()) continue;
        await for (final entry in directory.list(followLinks: false)) {
          if (entry is File && ['.seg', '.tmp'].contains(p.extension(entry.path))) await entry.delete();
        }
      }
      await manifest.writeAsString(identity, flush: true);
    }
    final keys = <Uri, Uint8List>{};
    Future<Uint8List> keyFor(Uri u) async =>
        keys[u] ??= t.hlsKeys[u.toString()] ?? Hls.parseAes128Key(await _get(client, u, t.headers));

    String segPath(String track, int i) => p.join(tmp.path, track, '${i.toString().padLeft(6, '0')}.seg');
    final names = ['v', if (audio != null) 'a'];
    final jobs = <(String, int, HlsSegment)>[];
    for (var k = 0; k < tracks.length; k++) {
      await Directory(p.join(tmp.path, names[k])).create(recursive: true);
      for (var i = 0; i < tracks[k].segments.length; i++) {
        jobs.add((names[k], i, tracks[k].segments[i]));
      }
    }
    t.total = jobs.length;
    t.done = 0;
    t.received = 0;
    for (final (track, i, _) in jobs) {
      final file = File(segPath(track, i));
      if (await file.exists() && await file.length() > 0) {
        t.done++;
        t.received += await file.length();
      } else if (await file.exists()) {
        await file.delete();
      }
    }
    t.phase = audio == null ? '조각 받는 중' : '영상·음성 조각 받는 중';
    _changed(immediate: true);

    var next = 0;
    var bytesWindow = 0;
    var windowStart = DateTime.now();
    Future<void> worker() async {
      while (true) {
        _check(t);
        final n = next++;
        if (n >= jobs.length) return;
        final (track, i, s) = jobs[n];
        final f = File(segPath(track, i));
        if (await f.exists()) continue;
        var data = await _get(client, s.uri, t.headers, range: s.byteRange);
        if (s.key != null) {
          final k = await keyFor(s.key!.uri!);
          data = await Hls.decryptAes128Async(
            data,
            k,
            s.key!.iv ?? Hls.ivForSequence(s.sequence),
            parallelism: AppSettings.instance.hlsDecryptionWorkers,
          );
        }
        _check(t);
        await File('${f.path}.tmp').writeAsBytes(data, flush: false);
        await File('${f.path}.tmp').rename(f.path);
        t.done++;
        t.received += data.length;
        bytesWindow += data.length;
        final el = DateTime.now().difference(windowStart).inMilliseconds;
        if (el > 1500) {
          t.speed = bytesWindow * 1000 / el;
          bytesWindow = 0;
          windowStart = DateTime.now();
        }
        _changed();
      }
    }

    final par = AppSettings.instance.hlsParallelSegments.clamp(1, 16);
    await Future.wait(List.generate(par, (_) => worker()));
    _check(t);

    // ---- 트랙별로 조각 이어붙이기
    t.phase = '조각 합치는 중';
    t.speed = 0;
    _changed(immediate: true);
    Future<String> joinTrack(int k) async {
      final pl = tracks[k];
      final ext = pl.isFmp4 ? '.mp4' : '.ts';
      final out = p.join(tmp.path, '${names[k]}_joined$ext');
      final sink = File(out).openWrite();
      try {
        if (pl.initSegment != null) sink.add(await _get(client, pl.initSegment!, t.headers));
        for (var i = 0; i < pl.segments.length; i++) {
          _check(t);
          await sink.addStream(
            File(segPath(names[k], i)).openRead().map((chunk) {
              _check(t);
              return chunk;
            }),
          );
        }
      } finally {
        await sink.close();
      }
      return out;
    }

    final joinedVideo = await joinTrack(0);
    final joinedAudio = audio == null ? null : await joinTrack(1);

    // ---- MP4로 완성 (ffmpeg 스트림 복사, 재인코딩 없음)
    t.phase = 'MP4로 변환 중';
    _changed(immediate: true);
    final extension = t.outputQuality == OutputQuality.audio ? '.m4a' : '.mp4';
    final target = '${p.withoutExtension(t.savePath!)}$extension';
    final (ok, err) = await Ffmpeg.createMp4(
      video: joinedVideo,
      audio: joinedAudio,
      output: target,
      quality: t.outputQuality,
    );
    if (!ok && t.outputQuality != OutputQuality.original) throw '변환 실패 (받은 조각은 보관됨): $err';
    if (ok) {
      t.savePath = target;
      t.note = null;
      t.outputDone = true;
    } else if (joinedAudio == null && video.isFmp4) {
      // fMP4는 이어붙인 것 자체가 MP4
      await _move(joinedVideo, target);
      t.savePath = target;
    } else {
      // ffmpeg 없음/실패 → 이어붙인 원본 형식 그대로 저장
      final tsPath = await _uniquePath(
        File(target).parent,
        '${p.basenameWithoutExtension(target)}${p.extension(joinedVideo)}',
      );
      await _move(joinedVideo, tsPath);
      t.savePath = tsPath;
      if (joinedAudio != null) {
        final aPath = await _uniquePath(
          File(target).parent,
          '${p.basenameWithoutExtension(target)} (음성)${p.extension(joinedAudio)}',
        );
        await _move(joinedAudio, aPath);
      }
      t.note = err == 'ffmpeg 없음'
          ? 'ffmpeg가 없어 ${p.extension(tsPath)}로 저장했습니다 (설정 → 다운로드 → ffmpeg)'
          : 'MP4 변환 실패로 ${p.extension(tsPath)}로 저장: $err';
    }
    t.fileName = p.basename(t.savePath!);
    t.received = await File(t.savePath!).length();
    // 받은 조각·중간 파일 삭제
    await _cleanupTemp(t);
  }

  static Future<void> _move(String from, String to) async {
    try {
      await File(from).rename(to);
    } on FileSystemException {
      // 드라이브가 다르면 rename 불가 → 복사 후 삭제
      await File(from).copy(to);
      await File(from).delete();
    }
  }

  // ---------------------------------------------------------------- utils
  static String _httpError(int code) => switch (code) {
    401 || 403 =>
      'HTTP $code — 서버가 요청을 거부했습니다. 주소의 토큰/쿠키가 만료됐을 수 있으니 '
          '페이지를 새로고침하고 영상을 다시 재생한 뒤 새로 받아보세요.',
    404 || 410 => 'HTTP $code — 파일이 없거나 임시 주소가 만료됐습니다.',
    _ => 'HTTP $code',
  };

  static String _extOf(String url) {
    final path = Uri.tryParse(url)?.path ?? '';
    final e = p.extension(path).toLowerCase();
    return const {'.mp4', '.webm', '.mkv', '.mov', '.m4v', '.flv', '.avi', '.ts'}.contains(e) ? e : '.mp4';
  }

  static String _safeName(String s) {
    final n = s.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    final t = n.isEmpty ? 'video' : n;
    return t.length > 120 ? t.substring(0, 120) : t;
  }

  static String suggestedFileName({
    required String url,
    required String title,
    required bool hls,
    required OutputQuality outputQuality,
  }) {
    final extension = outputQuality == OutputQuality.audio
        ? '.m4a'
        : hls || outputQuality != OutputQuality.original
        ? '.mp4'
        : _extOf(url);
    return browserDownloadName(_safeName(title), extension);
  }

  String _reservationKey(String path) => resourceKey(path);

  Future<String> _uniquePath(
    Directory dir,
    String name, {
    bool reserve = false,
    String? reservationOwner,
    String? currentFile,
  }) async {
    final base = p.basenameWithoutExtension(name), ext = p.extension(name);
    final ownedKey = reservationOwner == null ? null : _reservationKey(reservationOwner);
    final currentKey = currentFile == null ? null : _reservationKey(currentFile);
    var candidate = p.join(dir.path, name);
    var i = 1;
    while ((_reservationKey(candidate) != currentKey && await File(candidate).exists()) ||
        await File('$candidate.part').exists() ||
        (_reservationKey(candidate) != ownedKey &&
            _reservationKey(candidate) != currentKey &&
            (reserve
                ? !_reservedPaths.add(_reservationKey(candidate))
                : _reservedPaths.contains(_reservationKey(candidate))))) {
      candidate = p.join(dir.path, '$base ($i)$ext');
      i++;
    }
    return candidate;
  }

  void _changed({bool immediate = false}) {
    if (immediate) {
      _notifyTimer?.cancel();
      _notifyTimer = null;
      _foreground?.schedule(downloadNotificationState(tasks));
      notifyListeners();
      _persist();
      return;
    }
    _notifyTimer ??= Timer(const Duration(milliseconds: 300), () {
      _notifyTimer = null;
      _foreground?.schedule(downloadNotificationState(tasks));
      notifyListeners();
      _persistTimer ??= Timer(const Duration(seconds: 3), _persist);
    });
  }

  void _persist() {
    _persistTimer?.cancel();
    _persistTimer = null;
    _prefs.setStringList(_k, tasks.map((t) => jsonEncode(t.toJson())).toList());
  }
}

String resourceDownloadName(String name) {
  String clip(String value, int limit) {
    final result = StringBuffer();
    var length = 0;
    for (final rune in value.runes) {
      final character = String.fromCharCode(rune);
      length += utf8.encode(character).length;
      if (length > limit) break;
      result.write(character);
    }
    return result.toString();
  }

  var safe = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim().replaceFirst(RegExp(r'[. ]+$'), '');
  if (safe.isEmpty) safe = 'download';
  var base = p.basenameWithoutExtension(safe);
  final extension = clip(p.extension(safe), 30);
  if (RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$', caseSensitive: false).hasMatch(base)) base = '_$base';
  return '${clip(base, 200)}$extension';
}

String browserDownloadName(String name, String extension) {
  final safe = resourceDownloadName(name);
  final previous = p.extension(safe).toLowerCase();
  final stem = {...videoExtensions, ...audioExtensions, '.m3u8'}.contains(previous)
      ? p.basenameWithoutExtension(safe)
      : safe;
  return resourceDownloadName('$stem$extension');
}

Map<String, Object?> downloadNotificationState(List<DownloadTask> tasks) {
  final active = tasks.where((t) => t.status == DownloadStatus.running || t.status == DownloadStatus.queued).toList();
  final running = active.where((t) => t.status == DownloadStatus.running).toList();
  final first = running.firstOrNull ?? active.firstOrNull;
  final progress = first?.progress;
  return {
    'active': active.isNotEmpty,
    'title': active.length > 1 ? '다운로드 ${active.length}개 진행 중' : '다운로드 중',
    'name': ResourceLocks.instance.protects(downloadsResourceKey) ? '' : first?.fileName ?? '',
    'phase': first?.phase ?? (running.isEmpty ? '다운로드 준비 중' : '파일 받는 중'),
    'progress': progress == null ? -1 : (progress * 100).clamp(0, 100).round(),
  };
}
