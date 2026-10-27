import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../settings/cloud_settings.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../app/theme.dart';
import '../../core/media_item.dart';
import '../../core/resource_locks.dart';
import '../settings/privacy_settings.dart';
import '../../core/open_media.dart';
import '../../core/media_utils.dart';
import '../../core/resume_store.dart';
import '../../sources/cloud/cloud_sources.dart';
import '../../sources/server_store.dart';
import '../../sources/source_registry.dart';
import '../../sources/media_source.dart';
import '../network/dlna_page.dart';
import '../network/remote_browser_page.dart';
import '../network/server_edit_dialog.dart';
import '../player/player_screen.dart';
import '../settings/settings_page.dart';
import '../web/download_manager.dart';
import '../web/downloads_page.dart';
import '../../core/plugins/plugin_store.dart';
import '../../core/plugins/plugin.dart';
import '../web/web_browser_page.dart';
import 'local_browser_page.dart';
import 'recent_page.dart';
import 'playlists_page.dart';

enum SourceKind { device, folder, recent, playlists, downloads, server, dlna, cloud, web, settings }

class Source {
  const Source(this.kind, this.title, this.icon, {this.path, this.id, this.subtitle});
  final SourceKind kind;
  final String title;
  final IconData icon;
  final String? path;
  final String? id; // 서버/계정 ID
  final String? subtitle;

  @override
  bool operator ==(Object other) => other is Source && other.kind == kind && other.path == path && other.id == id;
  @override
  int get hashCode => Object.hash(kind, path, id);
}

IconData serverIcon(ServerType t) => switch (t) {
  ServerType.smb => Icons.lan_outlined,
  ServerType.ftp => Icons.dns_outlined,
  ServerType.sftp => Icons.terminal,
  ServerType.webdav => Icons.public,
};

IconData cloudIcon(CloudProvider p) => switch (p) {
  CloudProvider.gdrive => Icons.add_to_drive,
  CloudProvider.dropbox => Icons.inventory_2_outlined,
  CloudProvider.onedrive => Icons.cloud_outlined,
  CloudProvider.plugin => Icons.extension,
};

/// nPlayer 홈: 좌측 소스 목록(로컬 / 네트워크 / 클라우드 / 도구) + 우측 브라우저.
/// Android는 짧은 변 600dp 이상, 그 외는 폭 900dp 이상에서 고정 사이드바.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  Source? _selected;
  ServerConfig? _serverConfig;
  Future<MediaSource>? _serverSource;
  String? _deviceRoot;

  @override
  void initState() {
    super.initState();
    _resolveDeviceRoot();
    ServerStore.instance.addListener(_refresh);
    ResourceLocks.instance.addListener(_refresh);
    PluginStore.instance.addListener(_refresh);
    DownloadManager.instance.onOpenDownloads = _openDownloads;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) DownloadManager.instance.consumeOpenDownloads();
    });
  }

  @override
  void dispose() {
    DownloadManager.instance.onOpenDownloads = null;
    ServerStore.instance.removeListener(_refresh);
    ResourceLocks.instance.removeListener(_refresh);
    PluginStore.instance.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() => setState(() {});

  void _openDownloads() {
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    _select(Source(SourceKind.downloads, '다운로드', Icons.download));
  }

  Source _deviceSource() => Source(
    SourceKind.device,
    Platform.isAndroid || Platform.isIOS ? '내 기기' : '홈 폴더',
    Platform.isAndroid || Platform.isIOS ? Icons.smartphone : Icons.computer,
    path: _deviceRoot,
  );

  Future<void> _resolveDeviceRoot() async {
    String root;
    if (Platform.isAndroid) {
      root = '/storage/emulated/0';
    } else if (Platform.isIOS) {
      // iOS는 샌드박스: 파일 앱 > OPlayer 폴더 (Info.plist UIFileSharingEnabled)
      root = (await getApplicationDocumentsDirectory()).path;
    } else {
      root = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '/';
    }
    setState(() {
      _deviceRoot = root;
      _selected ??= _deviceSource();
    });
  }

  Future<bool> _ensureStoragePermission() async {
    if (!Platform.isAndroid) return true;
    if (await Permission.manageExternalStorage.isGranted) return true;
    if (await Permission.manageExternalStorage.request().isGranted) return true;
    // Android 12 이하
    return (await Permission.storage.request()).isGranted || (await Permission.videos.request()).isGranted;
  }

  void _openDrawer() => _scaffoldKey.currentState?.openDrawer();

  Future<void> _select(Source s) async {
    final key = _sourceResource(s);
    if (key != null) {
      try {
        await ResourceLocks.instance.requireAccess(key);
      } catch (_) {
        return;
      }
      if (!mounted) return;
    }
    setState(() => _selected = s);
    if (s.kind == SourceKind.server) {
      _serverConfig = null;
      _serverSource = null;
    }
    final scaffold = _scaffoldKey.currentState;
    if (scaffold?.widget.drawer != null && (scaffold?.isDrawerOpen ?? false)) {
      scaffold!.closeDrawer();
    }
  }

  // ---------------------------------------------------------------- 액션
  Future<void> _addFolder() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: '폴더 추가');
    if (dir == null) return;
    await ResumeStore.instance.addFolder(dir);
    _select(Source(SourceKind.folder, p.basename(dir), Icons.folder, path: dir));
  }

  Future<void> _addServer({ServerConfig? edit}) async {
    if (edit != null && !await _resourceAccess(serverResourceKey(edit))) return;
    if (!mounted) return;
    final cfg = await showServerEditDialog(context, existing: edit);
    if (cfg != null) {
      _select(Source(SourceKind.server, cfg.name, serverIcon(cfg.type), id: cfg.id));
    }
  }

  Future<void> _removeServer(ServerConfig c) async {
    if (!await _resourceAccess(serverResourceKey(c)) || !mounted) return;
    final ok = await _confirm('${c.name} 서버를 삭제할까요?');
    if (!ok) return;
    await SourceRegistry.instance.invalidate(c.id);
    await ServerStore.instance.removeServer(c);
    if (_selected?.id == c.id) _select(_deviceSource());
  }

  Future<void> _connectCloud() async {
    final extension = await showModalBottomSheet<OPlugin>(
      context: context,
      backgroundColor: OColors.of(context).surface,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('클라우드 연결', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            for (final plugin in PluginStore.instance.enabled.where((p) => p.cloud))
              ListTile(
                leading: const Icon(Icons.cloud_outlined),
                title: Text(plugin.name),
                onTap: () => Navigator.pop(c, plugin),
              ),
            if (!PluginStore.instance.enabled.any((p) => p.cloud))
              const ListTile(title: Text('설정 → 확장앱에서 클라우드 확장앱을 설치하고 켜 주세요')),
          ],
        ),
      ),
    );
    if (extension == null || !mounted) return;
    final provider = cloudPluginProvider(extension);
    if (!cloudPluginConfigured(extension)) {
      final ready = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(builder: (_) => CloudPluginSettingsPage(pluginId: extension.id, forConnection: true)),
      );
      if (ready != true || !mounted) return;
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(content: Text('${extension.name} 연결 중…')));
    try {
      final a = await connectCloudAccount(provider, pluginId: extension.id);
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      _select(Source(SourceKind.cloud, a.name, cloudIcon(a.provider), id: a.id));
    } catch (e) {
      messenger.hideCurrentSnackBar();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('${provider.label} 연결 실패'),
          content: Text('$e'),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('확인'))],
        ),
      );
    }
  }

  Future<void> _removeAccount(CloudAccount a) async {
    if (!await _resourceAccess('${a.provider.name}://${a.id}') || !mounted) return;
    final ok = await _confirm('${a.name} 연결을 해제할까요?');
    if (!ok) return;
    await SourceRegistry.instance.invalidate(a.id);
    try {
      await ServerStore.instance.removeAccount(a);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('계정 정보를 삭제하지 못했습니다. 다시 시도해 주세요.')));
      }
      return;
    }
    if (_selected?.id == a.id) _select(_deviceSource());
  }

  Future<bool> _confirm(String msg) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          content: Text(msg),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('취소')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('확인')),
          ],
        ),
      ) ??
      false;

  Future<void> _openFile() async {
    final r = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: {
        ...videoExtensions,
        ...audioExtensions,
        ...imageExtensions,
        '.m3u8',
      }.map((e) => e.substring(1)).toList(),
      allowMultiple: true,
    );
    final paths = r?.files.map((f) => f.path).whereType<String>().toList() ?? [];
    if (paths.isEmpty || !mounted) return;
    await openLocalMedia(context, paths);
    if (mounted) setState(() {});
  }

  Future<void> _openUrl() async {
    final ctrl = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('URL 스트림 열기'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'http(s)://, rtsp://, .m3u8 ...'),
          onSubmitted: (v) => Navigator.pop(c, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(c, ctrl.text), child: const Text('재생')),
        ],
      ),
    );
    if (url == null || url.trim().isEmpty || !mounted) return;
    await Navigator.of(context).push(PlayerScreen.route([MediaItem.url(url.trim())], 0));
  }

  // ---------------------------------------------------------------- 본문
  Widget _content(BuildContext context) {
    final s = _selected;
    if (s == null) return const Center(child: CircularProgressIndicator());
    final menu = shouldShowDrawerButton(context)
        ? IconButton(icon: const Icon(Icons.menu), onPressed: _openDrawer)
        : null;
    switch (s.kind) {
      case SourceKind.device:
      case SourceKind.folder:
        return LocalBrowserPage(
          key: ValueKey(s.path),
          rootPath: s.path!,
          rootTitle: s.title,
          ensurePermission: _ensureStoragePermission,
          onOpenDrawer: _openDrawer,
        );
      case SourceKind.recent:
        return RecentPage(onOpenDrawer: _openDrawer);
      case SourceKind.playlists:
        return PlaylistsPage(onOpenDrawer: _openDrawer);
      case SourceKind.downloads:
        return DownloadsPage(leading: menu);
      case SourceKind.server:
        final cfg = ServerStore.instance.server(s.id!);
        if (cfg == null) return const SizedBox.shrink();
        // Lock notifications must not replace the current folder with a new connection.
        if (!identical(_serverConfig, cfg) || _serverSource == null) {
          _serverConfig = cfg;
          _serverSource = SourceRegistry.instance.forServer(cfg);
        }
        return FutureBuilder(
          key: ValueKey('srv-${cfg.id}-${cfg.host}-${cfg.path}'),
          future: _serverSource,
          builder: (_, snap) => snap.data == null
              ? Scaffold(
                  appBar: AppBar(leading: menu, title: Text(cfg.name)),
                  body: Center(
                    child: snap.hasError ? Text('연결할 수 없습니다\n${snap.error}') : const CircularProgressIndicator(),
                  ),
                )
              : RemoteBrowserPage(source: snap.data!, onOpenDrawer: _openDrawer),
        );
      case SourceKind.cloud:
        final a = ServerStore.instance.account(s.id!);
        if (a == null) return const SizedBox.shrink();
        final pluginId = a.pluginId ?? 'cloud.${a.provider.name}';
        if (!PluginStore.instance.installed.containsKey(pluginId) || PluginStore.instance.disabled.contains(pluginId)) {
          return Scaffold(
            appBar: AppBar(leading: menu, title: Text(a.name)),
            body: const Center(child: Text('설정 → 확장앱에서 클라우드 확장앱을 설치하고 켜 주세요')),
          );
        }
        return RemoteBrowserPage(
          key: ValueKey('cloud-${a.id}'),
          source: SourceRegistry.instance.forAccount(a),
          onOpenDrawer: _openDrawer,
        );
      case SourceKind.dlna:
        return DlnaPage(onOpenDrawer: _openDrawer);
      case SourceKind.web:
        return WebBrowserPage(onOpenDrawer: _openDrawer);
      case SourceKind.settings:
        return SettingsPage(onOpenDrawer: _openDrawer);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final wide = Theme.of(context).platform == TargetPlatform.android ? size.shortestSide >= 600 : size.width >= 900;
    final sidebar = _Sidebar(
      selected: _selected,
      device: _deviceRoot == null ? null : _deviceSource(),
      onSelect: _select,
      onAddFolder: _addFolder,
      onRemoveFolder: (path) async {
        await ResumeStore.instance.removeFolder(path);
        setState(() {
          if (_selected?.path == path) _selected = _deviceSource();
        });
      },
      onAddServer: () => _addServer(),
      onEditServer: (c) => _addServer(edit: c),
      onRemoveServer: _removeServer,
      onConnectCloud: _connectCloud,
      onRemoveAccount: _removeAccount,
    );
    final showFab = switch (_selected?.kind) {
      SourceKind.device || SourceKind.folder || SourceKind.recent => true,
      _ => false,
    };

    return Scaffold(
      key: _scaffoldKey,
      drawer: wide ? null : Drawer(width: 300, child: sidebar),
      body: Row(
        children: [
          if (wide)
            SizedBox(
              width: 280,
              child: Material(color: OColors.of(context).surface, child: sidebar),
            ),
          Expanded(
            child: _ShowDrawerButton(
              showMenu: !wide,
              child: Builder(builder: _content),
            ),
          ),
        ],
      ),
      floatingActionButton: showFab ? _OpenFab(onOpenFile: _openFile, onOpenUrl: _openUrl) : null,
    );
  }
}

/// 하위 페이지가 AppBar 왼쪽에 메뉴 버튼을 그릴지 결정하는 InheritedWidget.
class _ShowDrawerButton extends InheritedWidget {
  const _ShowDrawerButton({required this.showMenu, required super.child});
  final bool showMenu;
  @override
  bool updateShouldNotify(_ShowDrawerButton old) => old.showMenu != showMenu;
}

bool shouldShowDrawerButton(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<_ShowDrawerButton>()?.showMenu ?? false;

class _OpenFab extends StatelessWidget {
  const _OpenFab({required this.onOpenFile, required this.onOpenUrl});
  final VoidCallback onOpenFile;
  final VoidCallback onOpenUrl;

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton(
      tooltip: '열기',
      backgroundColor: OColors.of(context).accent,
      foregroundColor: Colors.white,
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        backgroundColor: OColors.of(context).surface,
        builder: (c) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.video_file_outlined),
                title: const Text('파일 열기'),
                onTap: () {
                  Navigator.pop(c);
                  onOpenFile();
                },
              ),
              ListTile(
                leading: const Icon(Icons.link),
                title: const Text('URL 스트림 열기'),
                onTap: () {
                  Navigator.pop(c);
                  onOpenUrl();
                },
              ),
            ],
          ),
        ),
      ),
      child: const Icon(Icons.play_arrow_rounded, size: 30),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.selected,
    required this.device,
    required this.onSelect,
    required this.onAddFolder,
    required this.onRemoveFolder,
    required this.onAddServer,
    required this.onEditServer,
    required this.onRemoveServer,
    required this.onConnectCloud,
    required this.onRemoveAccount,
  });

  final Source? selected;
  final Source? device;
  final ValueChanged<Source> onSelect;
  final VoidCallback onAddFolder;
  final ValueChanged<String> onRemoveFolder;
  final VoidCallback onAddServer;
  final ValueChanged<ServerConfig> onEditServer;
  final ValueChanged<ServerConfig> onRemoveServer;
  final VoidCallback onConnectCloud;
  final ValueChanged<CloudAccount> onRemoveAccount;

  @override
  Widget build(BuildContext context) {
    final store = ServerStore.instance;
    final folders = ResumeStore.instance.folders;

    Widget more(List<(String, VoidCallback)> actions) => PopupMenuButton<int>(
      icon: const Icon(Icons.more_horiz, size: 18),
      onSelected: (i) => actions[i].$2(),
      itemBuilder: (_) => [
        for (var i = 0; i < actions.length; i++) PopupMenuItem(value: i, child: Text(actions[i].$1)),
      ],
    );

    Widget item(Source s, {Widget? trailing}) {
      final resource = _sourceResource(s);
      final locks = ResourceLocks.instance;
      return ListTile(
        dense: true,
        selected: s == selected,
        selectedTileColor: OColors.of(context).accent.withValues(alpha: 0.15),
        selectedColor: OColors.of(context).accent,
        leading: Icon(s.icon, size: 22),
        title: Row(
          children: [
            Expanded(child: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
            if (resource != null && locks.protects(resource))
              Icon(locks.isLocked(resource) ? Icons.lock_outline : Icons.lock_open, size: 15),
          ],
        ),
        subtitle: s.subtitle == null
            ? null
            : Text(
                s.subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: OColors.of(context).textSecondary),
              ),
        trailing:
            trailing ??
            (resource == null
                ? null
                : more([
                    (
                      locks.hasExact(resource) ? '잠금 설정 해제' : '이 리소스 잠금',
                      () => toggleResourceLock(context, resource, s.title),
                    ),
                  ])),
        onTap: () => onSelect(s),
        onLongPress: resource == null ? null : () => toggleResourceLock(context, resource, s.title),
      );
    }

    Widget header(String t, {Widget? action}) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              t,
              style: TextStyle(fontSize: 12, color: OColors.of(context).textSecondary, fontWeight: FontWeight.w600),
            ),
          ),
          if (action != null) action,
        ],
      ),
    );

    return SafeArea(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Row(
              children: [
                Image(image: AssetImage('assets/branding/oplayer.png'), width: 30, height: 30),
                SizedBox(width: 10),
                Text('OPlayer', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
          header(
            '로컬',
            action: IconButton(
              tooltip: '폴더 추가',
              icon: const Icon(Icons.create_new_folder_outlined, size: 20),
              onPressed: onAddFolder,
            ),
          ),
          if (device != null) item(device!),
          for (final f in folders)
            item(
              Source(SourceKind.folder, p.basename(f), Icons.folder, path: f, subtitle: f),
              trailing: more([
                (
                  ResourceLocks.instance.hasExact(f) ? '잠금 설정 해제' : '이 리소스 잠금',
                  () => toggleResourceLock(context, f, p.basename(f)),
                ),
                ('목록에서 제거', () => onRemoveFolder(f)),
              ]),
            ),
          item(const Source(SourceKind.recent, '최근 재생', Icons.history)),
          item(const Source(SourceKind.playlists, '재생목록', Icons.playlist_play)),
          ListenableBuilder(
            listenable: DownloadManager.instance,
            builder: (_, __) {
              final n = DownloadManager.instance.activeCount;
              return item(
                const Source(SourceKind.downloads, '다운로드', Icons.download_outlined),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (n > 0) Badge(label: Text('$n'), backgroundColor: OColors.of(context).accent),
                    more([
                      (
                        ResourceLocks.instance.hasExact(downloadsResourceKey) ? '잠금 설정 해제' : '이 리소스 잠금',
                        () => toggleResourceLock(context, downloadsResourceKey, '다운로드'),
                      ),
                    ]),
                  ],
                ),
              );
            },
          ),
          header(
            '네트워크',
            action: IconButton(tooltip: '서버 추가', icon: const Icon(Icons.add, size: 20), onPressed: onAddServer),
          ),
          for (final s in store.servers)
            item(
              Source(
                SourceKind.server,
                s.name,
                serverIcon(s.type),
                id: s.id,
                subtitle: '${s.type.name.toUpperCase()} · ${s.host}',
              ),
              trailing: more([
                ('편집', () => onEditServer(s)),
                ('삭제', () => onRemoveServer(s)),
                ('잠금 설정/해제', () => toggleResourceLock(context, serverResourceKey(s), s.name)),
              ]),
            ),
          if (store.servers.isEmpty)
            ListTile(
              dense: true,
              leading: const Icon(Icons.add_circle_outline, size: 22),
              title: const Text('SMB / FTP / SFTP / WebDAV 추가'),
              onTap: onAddServer,
            ),
          item(const Source(SourceKind.dlna, 'UPnP / DLNA 검색', Icons.cast)),
          header(
            '클라우드',
            action: IconButton(tooltip: '클라우드 연결', icon: const Icon(Icons.add, size: 20), onPressed: onConnectCloud),
          ),
          for (final a in store.accounts)
            item(
              Source(SourceKind.cloud, a.provider.label, cloudIcon(a.provider), id: a.id, subtitle: a.name),
              trailing: more([
                ('연결 해제', () => onRemoveAccount(a)),
                ('잠금 설정/해제', () => toggleResourceLock(context, '${a.provider.name}://${a.id}', a.name)),
              ]),
            ),
          if (store.accounts.isEmpty)
            ListTile(
              dense: true,
              leading: const Icon(Icons.add_circle_outline, size: 22),
              title: const Text('설치한 클라우드 확장앱'),
              onTap: onConnectCloud,
            ),
          header('도구'),
          item(const Source(SourceKind.web, '웹 브라우저 · 동영상 받기', Icons.travel_explore)),
          const Divider(height: 24),
          item(const Source(SourceKind.settings, '설정', Icons.settings_outlined)),
        ],
      ),
    );
  }
}

String? _sourceResource(Source source) => switch (source.kind) {
  SourceKind.downloads => downloadsResourceKey,
  SourceKind.device || SourceKind.folder => source.path,
  SourceKind.recent => recentResourceKey,
  SourceKind.playlists => playlistsResourceKey,
  SourceKind.server =>
    ServerStore.instance.server(source.id!) == null
        ? null
        : serverResourceKey(ServerStore.instance.server(source.id!)!),
  SourceKind.cloud =>
    ServerStore.instance.account(source.id!) == null
        ? null
        : '${ServerStore.instance.account(source.id!)!.provider.name}://${source.id}',
  _ => null,
};
Future<bool> _resourceAccess(String key) async {
  try {
    await ResourceLocks.instance.requireAccess(key);
    return true;
  } catch (_) {
    return false;
  }
}
