import 'package:flutter/material.dart';
import '../../core/settings.dart';

class AppearanceSettings extends StatelessWidget {
  const AppearanceSettings({super.key});
  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    return Column(
      children: [
        ListTile(
          title: const Text('화면과 색상', style: TextStyle(fontWeight: FontWeight.bold)),
          trailing: TextButton(
            onPressed: () => s.update((v) {
              v.themeMode = AppThemeMode.system;
              v.primaryColor = 0xFF2D9CFF;
              v.secondaryColor = 0xFF80CBC4;
            }),
            child: const Text('기본값'),
          ),
        ),
        ListTile(
          title: const Text('다크 테마'),
          subtitle: Text(_modeLabel(s.themeMode)),
          onTap: () async {
            final mode = await showDialog<AppThemeMode>(
              context: context,
              builder: (c) => SimpleDialog(
                title: const Text('다크 테마'),
                children: [
                  for (final mode in AppThemeMode.values)
                    SimpleDialogOption(onPressed: () => Navigator.pop(c, mode), child: Text(_modeLabel(mode))),
                ],
              ),
            );
            if (mode != null) s.update((v) => v.themeMode = mode);
          },
        ),
        _colorTile(context, '기본 색상 (Primary)', s.primaryColor, (v) => s.update((x) => x.primaryColor = v)),
        _colorTile(context, '보조 색상 (Secondary)', s.secondaryColor, (v) => s.update((x) => x.secondaryColor = v)),
      ],
    );
  }

  String _modeLabel(AppThemeMode mode) => switch (mode) {
    AppThemeMode.system => '시스템 설정',
    AppThemeMode.light => '밝게',
    AppThemeMode.dark => '어둡게',
  };

  Widget _colorTile(BuildContext context, String title, int color, ValueChanged<int> onChanged) => ListTile(
    title: Text(title),
    subtitle: Text('#${(color & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}'),
    trailing: CircleAvatar(backgroundColor: Color(color), radius: 15),
    onTap: () async {
      final controller = TextEditingController(
        text: (color & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase(),
      );
      final form = GlobalKey<FormState>();
      final result = await showDialog<int>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final v in [0xFF2D9CFF, 0xFF80CBC4, 0xFF6750A4, 0xFFE57373, 0xFFFFB74D, 0xFF4CAF50])
                      IconButton(
                        onPressed: () => Navigator.pop(c, v),
                        icon: Icon(Icons.circle, color: Color(v)),
                        tooltip: '#${v.toRadixString(16).substring(2)}',
                      ),
                  ],
                ),
                TextFormField(
                  controller: controller,
                  decoration: const InputDecoration(labelText: '색상 코드', prefixText: '#'),
                  maxLength: 6,
                  validator: (v) => RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(v ?? '') ? null : '6자리 색상 코드를 입력하세요',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('취소')),
            FilledButton(
              onPressed: () {
                if (form.currentState!.validate()) Navigator.pop(c, int.parse(controller.text, radix: 16) | 0xFF000000);
              },
              child: const Text('적용'),
            ),
          ],
        ),
      );
      controller.dispose();
      if (result != null) onChanged(result);
    },
  );
}

Future<void> editHomepage(BuildContext context) async {
  final controller = TextEditingController(text: AppSettings.instance.homepage);
  final form = GlobalKey<FormState>();
  final value = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('브라우저 홈페이지'),
      content: Form(
        key: form,
        child: TextFormField(
          controller: controller,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(labelText: '홈페이지 URL'),
          validator: (v) => normalizeHomepage(v ?? '') == null ? 'http 또는 https 주소를 입력하세요' : null,
        ),
      ),
      actions: [
        TextButton(onPressed: () => controller.text = 'https://www.google.com', child: const Text('기본값')),
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('취소')),
        FilledButton(
          onPressed: () {
            if (form.currentState!.validate()) Navigator.pop(c, normalizeHomepage(controller.text));
          },
          child: const Text('저장'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (value != null) AppSettings.instance.update((s) => s.homepage = value);
}
