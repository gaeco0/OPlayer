import 'package:flutter/material.dart';

import '../../../core/plugins/plugin.dart';
import '../../../core/plugins/plugin_store.dart';
import '../../../core/plugins/subtitle_plugins.dart';
import '../../settings/plugins_page.dart';
import '../../settings/plugin_settings_dialog.dart';
import '../player_controller.dart';

Future<void> showOnlineSubtitles(BuildContext context, PlayerController player) => showDialog<void>(
  context: context,
  builder: (_) => OnlineSubtitlesDialog(player: player),
);

class OnlineSubtitlesDialog extends StatefulWidget {
  const OnlineSubtitlesDialog({super.key, required this.player});
  final PlayerController player;
  @override
  State<OnlineSubtitlesDialog> createState() => _OnlineSubtitlesDialogState();
}

class _OnlineSubtitlesDialogState extends State<OnlineSubtitlesDialog> {
  late final _query = TextEditingController(text: subtitleSearchTitle(widget.player.title));
  late final String _mediaKey;
  final _language = TextEditingController(text: 'ko');
  final _store = PluginStore.instance;
  OPlugin? _provider;
  SubtitleResults? _results;
  bool _busy = false;
  String? _error;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _mediaKey = widget.player.current.key;
    _provider = widget.player.onlineSubtitles.providers.firstOrNull;
    if (_provider != null) _language.text = '${_store.publicSettings(_provider!)['language'] ?? 'ko'}';
    _store.addListener(_pluginsChanged);
    if (_provider != null && _store.hasCredentials(_provider!.id)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _search());
    }
  }

  void _pluginsChanged() {
    if (!mounted) return;
    setState(() {
      _request++;
      _busy = false;
      _results = null;
      _provider =
          widget.player.onlineSubtitles.providers.where((p) => p.id == _provider?.id).firstOrNull ??
          widget.player.onlineSubtitles.providers.firstOrNull;
    });
  }

  @override
  void dispose() {
    _store.removeListener(_pluginsChanged);
    _query.dispose();
    _language.dispose();
    super.dispose();
  }

  Future<void> _search({int page = 1, bool applyFirst = false}) async {
    final provider = _provider;
    if (_busy || provider == null) return;
    final ticket = ++_request;
    setState(() {
      _busy = true;
      _error = null;
      _results = null;
    });
    try {
      final results = await widget.player.onlineSubtitles.search(
        provider,
        _query.text,
        _language.text.trim(),
        page: page,
      );
      if (!mounted || ticket != _request) return;
      setState(() => _results = results);
      if (applyFirst && results.items.isNotEmpty) await _apply(provider, results.items.first);
    } catch (e) {
      if (mounted && ticket == _request) setState(() => _error = '$e');
    } finally {
      if (mounted && ticket == _request) setState(() => _busy = false);
    }
  }

  Future<void> _apply(OPlugin provider, Map<String, dynamic> item) async {
    if (!mounted) return;
    final ticket = ++_request;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.player.current.key != _mediaKey) throw StateError('재생 항목이 바뀌었습니다. 자막 검색을 다시 열어 주세요');
      final applied = await widget.player.applyOnlineSubtitle(
        provider,
        item,
        active: () => mounted && ticket == _request,
      );
      if (mounted && applied) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _configure() async {
    final provider = _provider;
    if (provider == null) return;
    try {
      if (await showPluginSettingsDialog(context, provider) && mounted) {
        _language.text = '${_store.publicSettings(provider)['language'] ?? 'ko'}';
        await _search();
      }
    } catch (_) {
      if (mounted) setState(() => _error = '확장앱 설정을 열 수 없습니다. 보안 저장소 상태를 확인해 주세요.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final providers = widget.player.onlineSubtitles.providers.toList();
    final provider = _provider;
    return AlertDialog(
      title: const Text('온라인 자막'),
      content: SizedBox(
        width: 640,
        height: MediaQuery.sizeOf(context).height * .65,
        child: ListView(
          children: [
            if (providers.isEmpty) ...[
              const Text('자막 검색 확장앱을 설치하고 켜 주세요.'),
              TextButton(
                onPressed: () async {
                  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PluginsPage()));
                },
                child: const Text('확장앱 관리'),
              ),
            ] else ...[
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      key: ValueKey(provider?.id),
                      initialValue: provider?.id,
                      decoration: const InputDecoration(labelText: '자막 확장앱'),
                      items: [for (final p in providers) DropdownMenuItem(value: p.id, child: Text(p.name))],
                      onChanged: _busy
                          ? null
                          : (id) => setState(() {
                              _provider = providers.firstWhere((p) => p.id == id);
                              _language.text = '${_store.publicSettings(_provider!)['language'] ?? 'ko'}';
                              _results = null;
                              _error = null;
                            }),
                    ),
                  ),
                  IconButton(
                    onPressed: _busy ? null : _configure,
                    icon: const Icon(Icons.settings_outlined),
                    tooltip: '확장앱 설정',
                  ),
                ],
              ),
              TextField(
                controller: _query,
                enabled: !_busy,
                decoration: const InputDecoration(labelText: '영상 제목'),
                onSubmitted: (_) => _search(),
              ),
              TextField(
                controller: _language,
                enabled: !_busy,
                decoration: const InputDecoration(labelText: '언어 코드', hintText: 'ko / en / ja'),
                onSubmitted: (_) => _search(),
              ),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(onPressed: _busy ? null : () => _search(), child: const Text('검색')),
                  TextButton(
                    onPressed: _busy ? null : () => _search(applyFirst: true),
                    child: const Text('검색 후 첫 결과 적용'),
                  ),
                ],
              ),
              if (provider != null && !_store.hasCredentials(provider.id) && provider.settings.isNotEmpty)
                const Text('처음 사용하면 확장앱 설정에서 연결 정보를 입력해 주세요.'),
            ],
            if (_busy) const LinearProgressIndicator(),
            if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            if (_results?.items.isEmpty ?? false) const Text('검색 결과가 없습니다. 제목이나 언어를 변경해 보세요.'),
            for (final item in _results?.items ?? <Map<String, dynamic>>[])
              ListTile(
                title: Text('${item['title']}'),
                subtitle: Text(
                  [item['language'], item['release']].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
                ),
                trailing: const Icon(Icons.download_outlined),
                enabled: !_busy,
                onTap: () => _apply(provider!, item),
              ),
            if (_results != null && _results!.totalPages > 1)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: !_busy && _results!.page > 1 ? () => _search(page: _results!.page - 1) : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text('${_results!.page} / ${_results!.totalPages}'),
                  IconButton(
                    onPressed: !_busy && _results!.page < _results!.totalPages
                        ? () => _search(page: _results!.page + 1)
                        : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('닫기'))],
    );
  }
}
