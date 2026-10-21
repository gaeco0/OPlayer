import 'package:flutter/material.dart';
import '../../core/resource_locks.dart';

/// Covers cached content when its own resource grant expires, without locking home.
class ResourceAccessView extends StatefulWidget {
  const ResourceAccessView({super.key, required this.resources, required this.child, this.onRefresh});
  final List<String> resources;
  final Widget child;
  final Future<void> Function()? onRefresh;
  @override
  State<ResourceAccessView> createState() => _ResourceAccessViewState();
}

class _ResourceAccessViewState extends State<ResourceAccessView> with WidgetsBindingObserver {
  bool _busy = false;
  bool _away = false;
  bool _pendingRefresh = false;
  bool _scheduled = false;
  late bool _wasShielded;

  @override
  void initState() {
    super.initState();
    _wasShielded = ResourceLocks.instance.shielded;
    WidgetsBinding.instance.addObserver(this);
    ResourceLocks.instance.addListener(_privacyChanged);
  }

  void _privacyChanged() {
    final shielded = ResourceLocks.instance.shielded;
    if (_wasShielded && !shielded) _pendingRefresh = true;
    _wasShielded = shielded;
    _scheduleRefresh();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleRefresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) _away = true;
    if (state == AppLifecycleState.resumed && _away) {
      _away = false;
      _pendingRefresh = true;
      _scheduleRefresh();
    }
  }

  void _scheduleRefresh() {
    if (!mounted || widget.onRefresh == null || !_pendingRefresh || _scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _scheduled = false;
      if (!mounted || _away || _busy || ResourceLocks.instance.shielded || ModalRoute.isCurrentOf(context) == false) {
        return;
      }
      _pendingRefresh = false;
      // Reuse the folder's normal load path, including its resource authentication.
      setState(() => _busy = true);
      try {
        await widget.onRefresh?.call();
      } finally {
        if (mounted) {
          setState(() => _busy = false);
          _scheduleRefresh();
        }
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ResourceLocks.instance.removeListener(_privacyChanged);
    super.dispose();
  }

  Future<void> _open() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      for (final value in widget.resources) {
        await ResourceLocks.instance.requireAccess(value);
      }
      _pendingRefresh = false;
      await widget.onRefresh?.call();
    } catch (error) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _scheduleRefresh();
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: ResourceLocks.instance,
    builder: (_, __) {
      final locked = widget.resources.any(ResourceLocks.instance.isLocked);
      return Stack(
        fit: StackFit.expand,
        children: [
          ExcludeFocus(
            excluding: locked,
            child: Offstage(
              offstage: locked,
              child: TickerMode(enabled: !locked, child: widget.child),
            ),
          ),
          if (locked)
            Positioned.fill(
              child: Material(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.lock_outline, size: 40),
                      const SizedBox(height: 12),
                      const Text('이 리소스는 잠겨 있습니다'),
                      const SizedBox(height: 12),
                      if (_busy) const CircularProgressIndicator(),
                      FilledButton(onPressed: _busy ? null : _open, child: const Text('이 리소스 잠금 해제')),
                    ],
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}
