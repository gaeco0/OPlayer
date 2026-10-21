import '../core/resource_locks.dart';
import 'dart:io';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../core/mouse_nav.dart';
import '../core/open_media.dart';
import '../features/player/playback_session.dart';
import 'theme.dart';

class MediaShell extends StatefulWidget {
  const MediaShell({super.key, required this.child, this.initialFiles = const []});
  final Widget child;
  final List<String> initialFiles;
  @override
  State<MediaShell> createState() => _MediaShellState();
}

class _MediaShellState extends State<MediaShell> {
  bool _dragging = false;
  bool _opening = false;
  bool _initialOpened = false;

  @override
  void initState() {
    super.initState();
    ResourceLocks.instance.addListener(_openInitialFiles);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openInitialFiles());
  }

  void _openInitialFiles() {
    if (!mounted || _initialOpened || widget.initialFiles.isEmpty) return;
    final locks = ResourceLocks.instance;
    if (locks.shielded || locks.unavailable || locks.inBackground) return;
    _initialOpened = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final context = MouseNav.navigatorKey.currentContext;
      if (!mounted || context == null) return;
      await openLocalMedia(context, widget.initialFiles, waitForClose: false);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    ResourceLocks.instance.removeListener(_openInitialFiles);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = PlaybackSession.instance;
    final body = ListenableBuilder(
      listenable: Listenable.merge([session, ResourceLocks.instance]),
      builder: (_, __) {
        final c = session.controller;
        return Column(
          children: [
            Expanded(child: widget.child),
            if (Platform.isWindows &&
                c != null &&
                session.minimized &&
                !ResourceLocks.instance.isLocked(c.current.key) &&
                !ResourceLocks.instance.isLocked(c.current.localPath ?? c.current.uri))
              Material(
                color: OColors.of(context).surfaceHigh,
                child: SafeArea(
                  top: false,
                  child: SizedBox(
                    height: 88,
                    child: Row(
                      children: [
                        InkWell(
                          onTap: () => session.restore(),
                          child: SizedBox(
                            width: 112,
                            height: 72,
                            child: c.audioOnly
                                ? const ColoredBox(color: Colors.black, child: Icon(Icons.audiotrack))
                                : Video(controller: c.video, controls: NoVideoControls, fit: BoxFit.contain),
                          ),
                        ),
                        Expanded(
                          child: InkWell(
                            onTap: () => session.restore(),
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                                  if (c.player.state.duration > Duration.zero)
                                    Slider(
                                      value: c.player.state.position.inMilliseconds.toDouble().clamp(
                                        0,
                                        c.player.state.duration.inMilliseconds.toDouble(),
                                      ),
                                      max: c.player.state.duration.inMilliseconds.toDouble(),
                                      onChanged: (v) => c.player.seek(Duration(milliseconds: v.round())),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => c.player.playOrPause(),
                          icon: Icon(c.player.state.playing ? Icons.pause : Icons.play_arrow),
                        ),
                        IconButton(onPressed: c.hasNext ? c.next : null, icon: const Icon(Icons.skip_next)),
                        IconButton(
                          tooltip: '작은 창',
                          onPressed: () => session.restore(compact: true),
                          icon: const Icon(Icons.picture_in_picture_alt),
                        ),
                        IconButton(tooltip: '재생 종료', onPressed: () => session.stop(), icon: const Icon(Icons.close)),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) return body;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) async {
        setState(() => _dragging = false);
        if (_opening) return;
        final context = MouseNav.navigatorKey.currentContext;
        if (context == null) return;
        _opening = true;
        try {
          await openLocalMedia(
            context,
            details.files.whereType<DropItemFile>().map((file) => file.path),
            waitForClose: false,
          );
        } finally {
          _opening = false;
        }
      },
      child: Stack(
        children: [
          Positioned.fill(child: body),
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: const Color(0xBB121214),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.all(32),
                      decoration: BoxDecoration(
                        border: Border.all(color: OColors.of(context).accent, width: 2),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Text(
                        '파일을 놓으면 재생하거나 사진을 엽니다',
                        textDirection: TextDirection.ltr,
                        style: TextStyle(color: Colors.white, fontSize: 20, decoration: TextDecoration.none),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
