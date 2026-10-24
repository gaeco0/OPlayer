import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'download_manager.dart';

typedef DownloadNameChoice = ({String name, String? overwriteTarget});

Future<DownloadNameChoice?> askDownloadName(
  BuildContext context, {
  required String initialName,
  bool resource = false,
}) => showDialog<DownloadNameChoice>(
  context: context,
  builder: (_) => _DownloadNameDialog(initialName: initialName, resource: resource),
);

class _DownloadNameDialog extends StatefulWidget {
  const _DownloadNameDialog({required this.initialName, required this.resource});
  final String initialName;
  final bool resource;
  @override
  State<_DownloadNameDialog> createState() => _DownloadNameDialogState();
}

class _DownloadNameDialogState extends State<_DownloadNameDialog> {
  late final controller = TextEditingController(text: widget.initialName);
  final focus = FocusNode();
  bool checking = false;
  String? error;
  @override
  void dispose() {
    controller.dispose();
    focus.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (checking) return;
    if (controller.text.trim().isEmpty) {
      setState(() => error = '파일명을 입력해 주세요');
      return;
    }
    final name = widget.resource
        ? resourceDownloadName(controller.text)
        : browserDownloadName(controller.text, p.extension(widget.initialName));
    controller.text = name;
    setState(() {
      checking = true;
      error = null;
    });
    try {
      final target = await DownloadManager.instance.inspectFileName(name, resource: widget.resource);
      if (!mounted) return;
      if (target.directory) throw StateError('같은 이름의 폴더가 있습니다. 다른 이름을 입력해 주세요');
      if (target.busy) throw StateError('같은 이름으로 다운로드 중입니다. 다른 이름을 입력해 주세요');
      if (target.exists) {
        final choice = await showDialog<String>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('같은 이름의 파일이 있습니다'),
            content: Text('$name\n기존 파일을 덮어쓰시겠습니까?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, 'cancel'), child: const Text('취소')),
              TextButton(onPressed: () => Navigator.pop(c, 'rename'), child: const Text('다른 이름으로 저장')),
              TextButton(onPressed: () => Navigator.pop(c, 'overwrite'), child: const Text('덮어쓰기')),
            ],
          ),
        );
        if (!mounted) return;
        if (choice == 'rename') {
          focus.requestFocus();
          controller.selection = TextSelection(baseOffset: 0, extentOffset: controller.text.length);
          return;
        }
        if (choice != 'overwrite') {
          Navigator.pop(context);
          return;
        }
      }
      if (mounted) Navigator.pop(context, (name: name, overwriteTarget: target.exists ? target.key : null));
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => checking = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('저장 파일명'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: controller,
          focusNode: focus,
          autofocus: true,
          enabled: !checking,
          decoration: InputDecoration(
            labelText: '파일명',
            errorText: error,
            helperText: widget.resource ? '원본 파일명으로 미리 채웠습니다' : '확장자는 최종 저장 형식에 맞춰 적용됩니다',
          ),
          onSubmitted: (_) => submit(),
        ),
        if (checking) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
      TextButton(onPressed: checking ? null : submit, child: const Text('다운로드')),
    ],
  );
}
