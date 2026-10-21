import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

export 'package:flutter_slidable/flutter_slidable.dart' show SlidableAutoCloseBehavior;

/// Sliding only reveals an action. Even a full swipe never deletes an item.
class SwipeDeleteTile extends StatefulWidget {
  const SwipeDeleteTile({super.key, required this.child, required this.onDelete});
  final Widget child;
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
    if (widget.onDelete == null) return widget.child;
    return Slidable(
      useTextDirection: false,
      endActionPane: ActionPane(
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
