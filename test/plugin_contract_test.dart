import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:oplayer/core/plugins/plugin.dart';
import 'package:oplayer/core/plugins/plugin_runtime.dart';
import 'package:oplayer/core/plugins/player_plugins.dart';

OPlugin sample(
  String kind,
  List<String> capabilities,
  String body, {
  Map<String, Object?> extra = const {},
}) => OPlugin.parse(
  '// @oplayer ${jsonEncode({'api': 4, 'id': 'test.contract', 'name': 'Test', 'version': '1', 'kind': kind, 'capabilities': capabilities, 'hosts': <String>[], ...extra})}\nglobalThis.plugin = {$body};',
);

void main() {
  test('only three types and their defined capabilities can be installed', () async {
    expect(() => sample('arbitrary', ['native'], ''), throwsFormatException);
    expect(() => sample('player', ['storage'], ''), throwsFormatException);
    expect(() => sample('player', [], ''), throwsFormatException);
    expect(() => sample('player', ['videoFilter', 'videoFilter'], ''), throwsFormatException);
    expect(
      () => sample(
        'player',
        ['videoFilter'],
        '',
        extra: {
          'sites': ['example.com'],
        },
      ),
      throwsFormatException,
    );
    final filter = sample('player', ['videoFilter'], 'videoFilter(){return {contrast:10}}');
    await callPlugin(filter, 'validate', {}, validateOnly: true);
    await expectLater(callPlugin(filter, 'list', {}), throwsStateError);
    for (final source in [
      sample('player', ['subtitles'], 'searchSubtitles(){}'),
      sample('player', ['videoFilter'], 'videoFilter(){}, list(){}'),
      sample(
        'browser',
        ['blockRequests'],
        '',
        extra: {
          'sites': ['example.com'],
        },
      ),
    ]) {
      await expectLater(callPlugin(source, 'validate', {}, validateOnly: true), throwsStateError);
    }
    final legacy = OPlugin.parse(
      '// @oplayer {"api":1,"id":"old.site","name":"Old","version":"1","kind":"site","sites":["example.com"]}\nglobalThis.plugin={page(){}}',
    );
    expect(legacy.kind, 'browser');
    await callPlugin(legacy, 'validate', {}, validateOnly: true);
  });
  test('catalog and examples all satisfy their declared executable contract', () async {
    for (final entity in Directory(
      'plugins',
    ).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.js'))) {
      final plugin = OPlugin.parse(entity.readAsStringSync());
      expect(plugin.typed, true, reason: entity.path);
      await callPlugin(plugin, 'validate', {}, validateOnly: true);
    }
  });
  test('a newly downloaded player plugin applies bounded data without host registration', () async {
    final plugin = OPlugin.parse(File('plugins/player.video-presets.js').readAsStringSync());
    expect(await videoFilterValues(plugin, {'preset': '흑백'}), {'brightness': 0, 'contrast': 0, 'saturation': -100});
    for (final response in [
      '{contrast:101}',
      '{vf:"file=/private"}',
      '{rotation:45}',
      '{horizontal:1}',
      '{contrast:NaN}',
      '{}',
    ]) {
      await expectLater(
        videoFilterValues(sample('player', ['videoFilter'], 'videoFilter(){return $response}'), {}),
        throwsFormatException,
      );
    }
    await expectLater(
      videoFilterValues(
        sample('player', ['videoFilter'], 'videoFilter(){return OPlayer.request("https://example.com")}'),
        {},
      ),
      throwsStateError,
    );
  });
}
