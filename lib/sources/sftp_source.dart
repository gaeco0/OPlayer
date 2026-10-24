import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/media_item.dart';
import '../core/secure_store.dart';
import '../core/stream_proxy.dart';
import 'media_source.dart';
import 'server_store.dart';

/// SFTP (SSH). 목록·재생 모두 dartssh2 → 재생은 로컬 HTTP Range 프록시를 거친다.
/// 인증: 비밀번호 또는 개인 키(PEM, 암호 있으면 비밀번호 칸을 암호로 사용).
/// 호스트 키: 처음 접속 시 지문을 저장하고(TOFU), 이후 바뀌면 접속을 거부한다.
class SftpSource extends MediaSource {
  SftpSource(this.cfg, this.password);
  final ServerConfig cfg;
  final String password;

  SSHClient? _ssh;
  SftpClient? _sftp;
  Future<SftpClient>? _connecting;

  @override
  String get scheme => 'sftp';
  @override
  String get id => cfg.id;
  @override
  String get displayName => cfg.name;
  @override
  String get rootPath => (cfg.path.isEmpty || cfg.path == '/') ? '/' : cfg.path;

  static String keyStorageKey(String serverId) => 'sshkey_$serverId';
  static String _hostKeyPref(String serverId) => 'sftp_hostkey_$serverId';

  /// 저장된 호스트 키 지문 삭제 (서버 재설치 등으로 키가 바뀐 경우)
  static Future<void> forgetHostKey(String serverId) async =>
      (await SharedPreferences.getInstance()).remove(_hostKeyPref(serverId));

  Future<SftpClient> _client() {
    if (_sftp != null && !(_ssh?.isClosed ?? true)) return Future.value(_sftp!);
    return _connecting ??= _connect().whenComplete(() => _connecting = null);
  }

  Future<SftpClient> _connect() async {
    final prefs = await SharedPreferences.getInstance();
    final known = prefs.getString(_hostKeyPref(cfg.id));
    String? hostKeyError;

    List<SSHKeyPair>? identities;
    if (cfg.useKey) {
      final pem = await SecureStore.instance.read(keyStorageKey(cfg.id));
      if (pem == null || pem.trim().isEmpty) throw '개인 키가 등록되지 않았습니다';
      try {
        identities = SSHKeyPair.fromPem(pem, password.isEmpty ? null : password);
      } catch (e) {
        throw '개인 키를 읽을 수 없습니다 (암호 확인): $e';
      }
    }

    final socket = await SSHSocket.connect(cfg.host, cfg.effectivePort, timeout: const Duration(seconds: 15));
    final ssh = SSHClient(
      socket,
      username: cfg.username,
      identities: identities,
      onPasswordRequest: cfg.useKey ? null : () => password,
      onVerifyHostKey: (type, fingerprint) {
        final fp = '$type:${base64.encode(fingerprint)}';
        if (known == null) {
          prefs.setString(_hostKeyPref(cfg.id), fp);
          return true;
        }
        if (known == fp) return true;
        hostKeyError =
            '서버의 호스트 키가 바뀌었습니다. 서버를 바꾼 게 아니라면 연결하지 마세요.\n'
            '(서버 편집 → "호스트 키 초기화" 후 다시 연결)';
        return false;
      },
    );
    try {
      await ssh.authenticated.timeout(const Duration(seconds: 20));
    } catch (e) {
      ssh.close();
      if (hostKeyError != null) throw hostKeyError!;
      throw '로그인 실패: $e';
    }
    _ssh = ssh;
    return _sftp = await ssh.sftp();
  }

  Future<T> _retry<T>(Future<T> Function(SftpClient c) fn) async {
    try {
      return await fn(await _client());
    } on SSHError {
      await close();
      return fn(await _client());
    }
  }

  @override
  Future<List<RemoteEntry>> list(String path) => _retry((c) async {
    final names = await c.listdir(path);
    final out = <RemoteEntry>[];
    for (final n in names) {
      if (n.filename == '.' || n.filename == '..') continue;
      final full = p.url.join(path, n.filename);
      var attr = n.attr;
      if (attr.isSymbolicLink) {
        try {
          attr = await c.stat(full); // 링크 대상 확인
        } catch (_) {
          continue; // 깨진 링크
        }
      }
      out.add(
        RemoteEntry(
          name: n.filename,
          path: full,
          isDir: attr.isDirectory,
          size: attr.size ?? 0,
          modified: attr.modifyTime == null ? null : DateTime.fromMillisecondsSinceEpoch(attr.modifyTime! * 1000),
        ),
      );
    }
    return out;
  });

  Future<String> _proxy(String path) async {
    final size = await _retry((c) async => (await c.stat(path)).size ?? 0);
    return StreamProxy.instance.register(
      name: p.url.basename(path),
      length: size,
      opener: (start, end) async {
        final f = await _retry((c) => c.open(path));
        final ctrl = StreamController<List<int>>();
        // 플레이어가 연결을 끊으면(탐색) 파일 핸들도 닫는다
        late StreamSubscription<List<int>> sub;
        ctrl.onListen = () {
          sub = f
              .read(offset: start, length: end - start)
              .listen(
                ctrl.add,
                onError: ctrl.addError,
                onDone: () async {
                  await f.close();
                  await ctrl.close();
                },
              );
        };
        ctrl.onCancel = () async {
          await sub.cancel();
          await f.close();
        };
        ctrl.onPause = () => sub.pause();
        ctrl.onResume = () => sub.resume();
        return ctrl.stream;
      },
    );
  }

  @override
  MediaItem itemFor(RemoteEntry e, List<RemoteEntry> siblings) {
    final subs = MediaSource.matchSubtitles(e, siblings);
    final key = keyFor(e.path);
    final title = p.basenameWithoutExtension(e.name);
    return MediaItem(
      key: key,
      uri: '',
      title: title,
      resolver: () async {
        final url = await _proxy(e.path);
        final refs = <SubtitleRef>[];
        for (final s in subs) {
          try {
            refs.add(SubtitleRef(await _proxy(s.path), s.name));
          } catch (_) {}
        }
        return MediaItem(
          key: key,
          uri: url,
          title: title,
          subtitles: refs,
          onRelease: () async {
            StreamProxy.instance.unregister(url);
            for (final ref in refs) {
              StreamProxy.instance.unregister(ref.uri);
            }
          },
        );
      },
    );
  }

  @override
  Future<MediaItem?> itemForPath(String path, String title) async {
    List<RemoteEntry> siblings = const [];
    try {
      siblings = await list(p.url.dirname(path));
    } catch (_) {}
    return itemFor(RemoteEntry(name: p.url.basename(path), path: path, isDir: false), siblings);
  }

  @override
  bool get canUpload => true;

  @override
  bool get canDelete => true;

  @override
  bool get canRename => true;

  @override
  Future<String> rename(RemoteEntry entry, String name) async {
    final target = renamedPath(entry, name);
    final client = await _client();
    if ((await client.listdir(p.url.dirname(target))).any((e) => e.filename == name)) {
      throw StateError('같은 이름의 항목이 이미 있습니다');
    }
    await client.rename(deletionPath(entry), target);
    return target;
  }

  @override
  Future<void> delete(RemoteEntry entry) async {
    final path = deletionPath(entry);
    final client = await _client();
    Future<void> remove(String path, int depth) async {
      if (depth > 128) throw StateError('삭제할 폴더의 깊이 한도 초과');
      final attr = await client.stat(path, followLink: false);
      if (attr.isDirectory && !attr.isSymbolicLink) {
        for (final child in await client.listdir(path)) {
          if (child.filename == '.' || child.filename == '..') continue;
          if (RegExp(r'[/\\\x00-\x1f]').hasMatch(child.filename)) throw const FormatException('잘못된 SFTP 삭제 경로');
          await remove(p.url.join(path, child.filename), depth + 1);
        }
        await client.rmdir(path);
      } else {
        await client.remove(path);
      }
    }

    // Mutations are not retried: a lost response must not delete a replacement.
    await remove(path, 0);
  }

  @override
  Future<String> upload(
    File local,
    String remoteDir,
    String name, {
    String? overwritePath,
    void Function(int sent)? onProgress,
    Future<void>? cancelled,
  }) async {
    final path = MediaSource.joinRemote(remoteDir, name);
    final f = await _retry(
      (c) => c.open(path, mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate),
    );
    try {
      final writer = f.write(local.openRead().map(Uint8List.fromList), onProgress: onProgress);
      await writer.done;
    } finally {
      await f.close();
    }
    return path;
  }

  @override
  Future<void> close() async {
    try {
      _sftp?.close();
      _ssh?.close();
    } catch (_) {}
    _sftp = null;
    _ssh = null;
  }
}
