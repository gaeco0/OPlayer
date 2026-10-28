import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:oplayer/core/plugins/plugin.dart';
import 'package:oplayer/core/plugins/plugin_store.dart';
import 'package:oplayer/core/plugins/interpolation_models.dart';
import 'package:oplayer/core/plugins/plugin_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('AI interpolation requires installed enabled provider and rejects unsupported native engines', () async {
    final store = PluginStore.forTesting();
    final service = InterpolationModels(store);
    expect(await service.catalog(), isEmpty);
    await expectLater(service.resolve('player.ai-interpolation/rife-v4-6'), throwsStateError);
    final source = await File('plugins/player.ai-interpolation.js').readAsString();
    final plugin = OPlugin.parse(source);
    await callPlugin(plugin, 'validate', {}, validateOnly: true);
    store.installed[plugin.id] = plugin;
    final model = (await service.catalog()).single;
    expect(model.key, 'player.ai-interpolation/rife-v4-6');
    expect((await service.resolve(model.key)).name, contains('RIFE'));
    store.disabled.add(plugin.id);
    expect(await service.catalog(), isEmpty);
    await expectLater(service.resolve(model.key), throwsStateError);
    store.disabled.clear();
    store.installed[plugin.id] = OPlugin.parse(source.replaceAll('rife-v4.6', 'untrusted-engine'));
    expect(await service.catalog(), isEmpty);
    expect(service.errors, isNotEmpty);
  });
}
