import 'package:flutter/material.dart';
import '../../core/resume_store.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

export 'package:flutter_slidable/flutter_slidable.dart' show SlidableAutoCloseBehavior;

/// Sliding only reveals an action. Even a full swipe never deletes an item.
class SwipeDeleteTile extends StatefulWidget {
  const SwipeDeleteTile({
    super.key,
    required this.child,
    required this.onDelete,
    this.watchedKey,
    this.watchedTitle,
    this.onChanged,
  });
  final Widget child;
  final String? watchedKey, watchedTitle;
  final VoidCallback? onChanged;
  final Future<void> Function()? onDelete;

  @override
  State<SwipeDeleteTile> createState() => _SwipeDeleteTileState();
}

class _SwipeDeleteTileState extends State<SwipeDeleteTile> {
  bool _busy = false;

  Future<void> _delete() async {
    if (_busy || widget.onDelete == null) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await widget.onDelete!();
    } catch (e) {
      if (messenger.mounted) messenger.showSnackBar(SnackBar(content: Text('삭제하지 못했습니다: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.onDelete == null && widget.watchedKey == null) return widget.child;
    final watched = ResumeStore.instance.get(widget.watchedKey ?? '')?.finished ?? false;
    Future<void> toggleWatched() async {
      if (_busy) return;
      setState(() => _busy = true);
      try {
        await ResumeStore.instance.toggleWatched(widget.watchedKey!, title: widget.watchedTitle);
        if (mounted) widget.onChanged?.call();
      } catch (error) {
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }

    return Slidable(
      key: ValueKey(widget.watchedKey ?? widget.key),
      useTextDirection: false,
      startActionPane: widget.watchedKey == null
          ? null
          : ActionPane(
              motion: const BehindMotion(),
              extentRatio: 0.3,
              dismissible: DismissiblePane(
                onDismissed: () {},
                closeOnCancel: true,
                confirmDismiss: () async {
                  await toggleWatched();
                  return false;
                },
              ),
              children: [
                SlidableAction(
                  onPressed: _busy ? null : (_) => toggleWatched(),
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
                  icon: watched ? Icons.remove_done : Icons.done_all,
                  label: watched ? '안 본 상태' : '본 상태',
                ),
              ],
            ),
      endActionPane: widget.onDelete == null
          ? null
          : ActionPane(
              motion: const BehindMotion(),
              extentRatio: 0.28,
              children: [
                CustomSlidableAction(
                  autoClose: false,
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                  onPressed: _busy ? null : (_) => _delete(),
                  child: _busy
                      ? SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Theme.of(context).colorScheme.onError,
                            semanticsLabel: '삭제 중',
                          ),
                        )
                      : const FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [Icon(Icons.delete_outline), SizedBox(height: 4), Text('삭제')],
                          ),
                        ),
                ),
              ],
            ),
      child: IgnorePointer(ignoring: _busy, child: widget.child),
    );
  }
}
