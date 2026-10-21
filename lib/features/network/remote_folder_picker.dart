import '../settings/resource_access_view.dart';
import 'package:flutter/material.dart';
import '../../core/resource_locks.dart';

import '../../app/theme.dart';
import '../../core/media_utils.dart';
import '../../sources/media_source.dart';

/// 원격 서버에서 폴더 하나를 고르는 화면. 고른 경로를 pop으로 돌려준다.
class RemoteFolderPicker extends StatefulWidget {
  const RemoteFolderPicker({super.key, required this.source, this.initialPath});
  final MediaSource source;
  final String? initialPath;

  static Future<String?> pick(BuildContext context, MediaSource source, {String? initialPath}) =>
      Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (_) => RemoteFolderPicker(source: source, initialPath: initialPath),
        ),
      );

  @override
  State<RemoteFolderPicker> createState() => _RemoteFolderPickerState();
}

class _RemoteFolderPickerState extends State<RemoteFolderPicker> {
  late final List<(String, String)> _stack = [(widget.source.rootPath, widget.source.displayName)];
  List<RemoteEntry> _dirs = [];
  bool _loading = true;
  String? _error;

  String get _cwd => _stack.last.$1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ResourceLocks.instance.requireAccess(widget.source.keyFor(_cwd));
      final all = await widget.source.list(_cwd);
      _dirs = all.where((e) => e.isDir).toList()..sort((a, b) => naturalCompare(a.name, b.name));
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final crumbs = _stack.skip(1).map((e) => e.$2).join(' / ');
    // SMB 루트("/")는 공유 목록이라 파일을 둘 수 없음
    final canSelect = !(widget.source.scheme == 'smb' && _cwd == '/');
    return PopScope(
      canPop: _stack.length <= 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _stack.removeLast();
          _load();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('저장할 폴더 선택'),
              Text(
                '${widget.source.displayName}:/$crumbs',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: OColors.textSecondary),
              ),
            ],
          ),
        ),
        body: ResourceAccessView(
          resources: [widget.source.keyFor(_cwd)],
          onRefresh: _load,
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? Center(child: Text(_error!, textAlign: TextAlign.center))
              : ListView(
                  children: [
                    if (_dirs.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('하위 폴더가 없습니다', style: TextStyle(color: OColors.textSecondary)),
                      ),
                    for (final d in _dirs)
                      ListTile(
                        leading: const Icon(Icons.folder_rounded, color: Color(0xFFF2B84B)),
                        title: Text(d.name),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          _stack.add((d.path, d.name));
                          _load();
                        },
                      ),
                  ],
                ),
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: FilledButton.icon(
              icon: const Icon(Icons.check),
              label: Text(canSelect ? '이 폴더에 저장' : '공유 폴더를 먼저 여세요'),
              onPressed: canSelect
                  ? () async {
                      try {
                        await ResourceLocks.instance.requireAccess(widget.source.keyFor(_cwd));
                        if (context.mounted) Navigator.pop(context, _cwd);
                      } catch (error) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
                        }
                      }
                    }
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}
