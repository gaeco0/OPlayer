import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../sources/dlna_source.dart';
import '../browser/home_screen.dart';
import 'remote_browser_page.dart';

/// 같은 네트워크의 UPnP/DLNA 미디어 서버 검색 → 선택 시 폴더 탐색
class DlnaPage extends StatefulWidget {
  const DlnaPage({super.key, required this.onOpenDrawer});
  final VoidCallback onOpenDrawer;

  @override
  State<DlnaPage> createState() => _DlnaPageState();
}

class _DlnaPageState extends State<DlnaPage> {
  final _devices = <DlnaDevice>[];
  StreamSubscription<DlnaDevice>? _sub;
  bool _searching = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _search() {
    _sub?.cancel();
    setState(() {
      _devices.clear();
      _searching = true;
      _error = null;
    });
    _sub = DlnaDiscovery.discover().listen(
      (d) {
        if (_devices.every((x) => x.udn != d.udn)) setState(() => _devices.add(d));
      },
      onError: (Object e) => setState(() => _error = '$e'),
      onDone: () {
        if (mounted) setState(() => _searching = false);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: shouldShowDrawerButton(context)
            ? IconButton(icon: const Icon(Icons.menu), onPressed: widget.onOpenDrawer)
            : null,
        title: const Text('UPnP / DLNA'),
        actions: [
          if (_searching)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            IconButton(icon: const Icon(Icons.refresh), tooltip: '다시 검색', onPressed: _search),
        ],
      ),
      body: _devices.isEmpty
          ? Center(
              child: Text(
                _searching ? '미디어 서버를 찾는 중…' : (_error ?? '찾은 서버가 없습니다\n(같은 Wi-Fi에 있는지 확인하세요)'),
                textAlign: TextAlign.center,
                style: TextStyle(color: OColors.of(context).textSecondary),
              ),
            )
          : ListView(
              children: [
                for (final d in _devices)
                  ListTile(
                    leading: d.iconUrl == null
                        ? const Icon(Icons.dns, size: 32)
                        : Image.network(
                            d.iconUrl!,
                            width: 32,
                            height: 32,
                            errorBuilder: (_, __, ___) => const Icon(Icons.dns, size: 32),
                          ),
                    title: Text(d.name),
                    subtitle: Text(
                      Uri.parse(d.controlUrl).host,
                      style: TextStyle(fontSize: 12, color: OColors.of(context).textSecondary),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(
                      context,
                    ).push(MaterialPageRoute<void>(builder: (_) => RemoteBrowserPage(source: DlnaSource(d)))),
                  ),
              ],
            ),
    );
  }
}
