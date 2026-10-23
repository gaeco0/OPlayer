import 'package:flutter/material.dart';

Future<String?> askName(BuildContext context, String title, {String initial = ''}) => showDialog<String>(
  context: context,
  builder: (_) => _NameDialog(title: title, initial: initial),
);

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, required this.initial});
  final String title, initial;
  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final controller = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void submit() {
    if (controller.text.trim().isNotEmpty) Navigator.pop(context, controller.text.trim());
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(controller: controller, autofocus: true, onSubmitted: (_) => submit()),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
      TextButton(onPressed: submit, child: const Text('확인')),
    ],
  );
}

Future<bool> confirmFileDeletion(BuildContext context, int count) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('$count개 파일 삭제'),
        content: const Text('원본 파일을 삭제합니다. 이 작업은 되돌릴 수 없습니다.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('취소')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('파일 삭제')),
        ],
      ),
    ) ??
    false;

Future<void> runFileAction(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
  } catch (error) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
  }
}

class FileSelectionActions extends StatelessWidget {
  const FileSelectionActions({
    super.key,
    required this.onSelectAll,
    required this.onAdd,
    required this.onDelete,
    this.removeLabel = '파일 삭제',
  });
  final VoidCallback onSelectAll;
  final VoidCallback? onAdd;
  final VoidCallback? onDelete;
  final String removeLabel;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(tooltip: '전체 선택/해제', icon: const Icon(Icons.select_all), onPressed: onSelectAll),
      PopupMenuButton<String>(
        tooltip: '선택 메뉴',
        onSelected: (v) => v == 'add' ? onAdd?.call() : onDelete?.call(),
        itemBuilder: (_) => [
          PopupMenuItem(value: 'add', enabled: onAdd != null, child: const Text('재생목록에 추가')),
          PopupMenuItem(value: 'delete', enabled: onDelete != null, child: Text(removeLabel)),
        ],
      ),
    ],
  );
}

class FileSelectionTile extends StatelessWidget {
  const FileSelectionTile({
    super.key,
    required this.child,
    required this.active,
    required this.selected,
    required this.onToggle,
  });
  final Widget child;
  final bool active;
  final bool selected;
  final VoidCallback onToggle;
  @override
  Widget build(BuildContext context) => !active
      ? child
      : InkWell(
          onTap: onToggle,
          child: Stack(
            children: [
              IgnorePointer(
                child: Opacity(opacity: selected ? 0.65 : 1, child: child),
              ),
              Positioned(
                top: 0,
                left: 0,
                child: Checkbox(value: selected, onChanged: (_) => onToggle()),
              ),
            ],
          ),
        );
}
