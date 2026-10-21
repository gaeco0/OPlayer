import '../settings/resource_access_view.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/media_item.dart';

class PhotoViewer extends StatefulWidget {
  const PhotoViewer({super.key, required this.items, required this.index});
  final List<MediaItem> items;
  final int index;
  static Route<void> route(List<MediaItem> items, int index) => MaterialPageRoute(
    builder: (_) => PhotoViewer(items: items, index: index),
  );
  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer> {
  late int _index = widget.index;
  late final _pages = PageController(initialPage: _index);
  final _resolved = <int, Future<MediaItem>>{};
  final _transforms = <int, TransformationController>{};
  int _rotation = 0;
  bool _zoomed = false;
  @override
  void dispose() {
    _pages.dispose();
    for (final transform in _transforms.values) {
      transform.dispose();
    }
    super.dispose();
  }

  void _move(int by) {
    final next = _index + by;
    if (next >= 0 && next < widget.items.length) {
      _pages.animateToPage(next, duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) => ResourceAccessView(
    resources: [widget.items[_index].key, widget.items[_index].localPath ?? widget.items[_index].uri],
    child: Focus(
      autofocus: true,
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          _move(-1);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          _move(1);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.maybePop(context);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: Text(
            '${widget.items[_index].title} · ${_index + 1}/${widget.items.length}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.rotate_right),
              tooltip: '회전',
              onPressed: () => setState(() => _rotation++),
            ),
          ],
        ),
        body: Stack(
          children: [
            PageView.builder(
              controller: _pages,
              physics: _zoomed ? const NeverScrollableScrollPhysics() : null,
              itemCount: widget.items.length,
              onPageChanged: (index) => setState(() {
                _index = index;
                _rotation = 0;
                _zoomed = false;
              }),
              itemBuilder: (_, index) => FutureBuilder<MediaItem>(
                future: _resolved.putIfAbsent(index, () => widget.items[index].resolve()),
                builder: (_, snapshot) {
                  if (snapshot.hasError) return const Center(child: Text('사진을 열 수 없습니다'));
                  final item = snapshot.data;
                  if (item == null) return const Center(child: CircularProgressIndicator());
                  final uri = Uri.tryParse(item.uri);
                  final ImageProvider provider =
                      item.localPath != null || uri == null || !uri.hasScheme || uri.scheme == 'file'
                      ? FileImage(File(item.localPath ?? (uri?.scheme == 'file' ? uri!.toFilePath() : item.uri)))
                      : NetworkImage(item.uri, headers: item.headers);
                  final transform = _transforms.putIfAbsent(index, TransformationController.new);
                  return InteractiveViewer(
                    transformationController: transform,
                    minScale: 1,
                    maxScale: 8,
                    onInteractionUpdate: (details) {
                      if (index != _index) return;
                      final zoomed = transform.value.getMaxScaleOnAxis() > 1.01;
                      if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
                    },
                    child: GestureDetector(
                      onDoubleTap: () => setState(() {
                        _zoomed = false;
                        transform.value = Matrix4.identity();
                      }),
                      child: Center(
                        child: RotatedBox(
                          quarterTurns: _rotation,
                          child: Image(
                            image: provider,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const Text('지원하지 않는 사진 형식이거나 파일을 읽을 수 없습니다'),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (_index > 0)
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton.filledTonal(onPressed: () => _move(-1), icon: const Icon(Icons.chevron_left)),
              ),
            if (_index + 1 < widget.items.length)
              Align(
                alignment: Alignment.centerRight,
                child: IconButton.filledTonal(onPressed: () => _move(1), icon: const Icon(Icons.chevron_right)),
              ),
          ],
        ),
      ),
    ),
  );
}
