import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:oplayer/core/plugins/plugin.dart';
import 'package:oplayer/core/plugins/plugin_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('all compatible official scripts register in the native JS engine', () async {
    for (final file in Directory('plugins').listSync().whereType<File>().where((f) => f.path.endsWith('.js'))) {
      final plugin = OPlugin.parse(file.readAsStringSync());
      if (plugin.compatibilityIssue() != null) continue;
      await callPlugin(plugin, 'validate', {}, validateOnly: true);
    }
  });
  test('native bridge runs asynchronous HTML XML and JSON parser calls on this OS', () async {
    final plugin = OPlugin.parse(
      '// @oplayer ${jsonEncode({
        'api': 5,
        'id': 'test.platform',
        'name': 'Platform',
        'version': '1',
        'kind': 'resource',
        'capabilities': ['storage'],
        'hosts': <String>[],
        'auth': {'type': 'bearer'},
      })}\nglobalThis.plugin={accountName(){return "test"},stream(){return null},async list(){'
      'const html=await OPlayer.parse.html("<b>hello</b>");'
      'const xml=await OPlayer.parse.xml("<root><v>world</v></root>");'
      'return [(await html.querySelector("b")).textContent,(await xml.findAllElements("v"))[0].textContent,OPlayer.parse.json("[1]")[0]];}}',
    );
    expect(await callPlugin(plugin, 'list', {}), ['hello', 'world', 1]);
  });
}
