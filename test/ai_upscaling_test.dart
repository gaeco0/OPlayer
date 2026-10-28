import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/settings/upscale_models_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/plugins/plugin.dart';
import 'package:oplayer/core/plugins/plugin_runtime.dart';
import 'package:oplayer/core/plugins/plugin_store.dart';
import 'package:oplayer/core/plugins/upscale_models.dart';
import 'package:oplayer/features/player/video_upscaling.dart';

const shader = '''//!HOOK MAIN
//!BIND MAIN
//!WIDTH MAIN.w 2 *
//!HEIGHT MAIN.h 2 *
vec4 hook() { return MAIN_tex(MAIN_pos); }
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('oplayer-ai-test-');
    PluginStore.instance.installed.clear();
    PluginStore.instance.disabled.clear();
    final provider = OPlugin.parse(await File('plugins/player.ai-upscale.js').readAsString());
    PluginStore.instance.installed[provider.id] = provider;
  });
  tearDown(() => directory.delete(recursive: true));

  test('all three default CNN models execute through JS, verify weights, and work offline', () async {
    final provider = OPlugin.parse(await File('plugins/player.ai-upscale.js').readAsString());
    await callPlugin(provider, 'validate', {}, validateOnly: true);
    final service = UpscaleModels(directory: directory, clientFactory: () => throw StateError('offline'));
    final models = await service.fromPlugin(provider);
    expect(models.length, 3);
    expect(models.map((m) => m.id), ['anime4k-s', 'anime4k-denoise-s', 'fsrcnnx-8']);
    for (final model in models) {
      final file = await service.materialize(model);
      expect(sha256.convert(await file.readAsBytes()).toString(), model.digest);
      expect(
        sha256.convert(await File('third_party/ai-upscale/${model.id}.glsl').readAsBytes()).toString(),
        model.digest,
      );
      final source = await file.readAsString();
      expect(source, contains('mat4'));
      expect(source, contains('//!HOOK'));
      await file.writeAsString('corrupted');
      expect(await (await service.materialize(model)).readAsString(), source);
    }
    expect((await service.catalog()).length, 3);
    expect(PluginStore.instance.installed.keys, ['player.ai-upscale']);
  });

  test('disabled or absent provider cannot resolve even a cached model or add URL models', () async {
    final store = PluginStore.forTesting();
    final service = UpscaleModels(store: store, directory: directory);
    expect(await service.catalog(), isEmpty);
    await expectLater(service.addUrl('https://example.com/model.glsl', 'Model'), throwsStateError);
    final provider = OPlugin.parse(await File('plugins/player.ai-upscale.js').readAsString());
    store.installed[provider.id] = provider;
    final model = (await service.catalog()).first;
    await service.materialize(model);
    final networkPath = await service.network(model.key);
    expect(networkPath, endsWith('.glsl.ous'));
    expect(await File(networkPath!).exists(), true);
    final pending = service.materialize(model);
    store.disabled.add(provider.id);
    await expectLater(pending, throwsStateError);
    expect(await service.catalog(), isEmpty);
    await expectLater(service.materialize(model), throwsStateError);
    await expectLater(service.resolve(model.key), throwsStateError);
    await expectLater(service.network(model.key), throwsStateError);
  });

  test('a new JS provider can return model weights without adding host-side model IDs', () async {
    final digest = sha256.convert(utf8.encode(shader)).toString();
    final provider = OPlugin.parse(
      '''// @oplayer {"api":4,"id":"test.models","name":"Models","version":"1","kind":"player","capabilities":["upscaling"]}
globalThis.plugin={
upscaleModels(){return [{id:'new-model',name:'New',description:'Test',format:'mpv-glsl',scale:2,license:'MIT',source:'https://example.com/model',sha256:'$digest'}]},
upscaleModel(){return {format:'mpv-glsl',shader:${jsonEncode(shader)}}}
};''',
    );
    final store = PluginStore.forTesting();
    store.installed[provider.id] = provider;
    final service = UpscaleModels(store: store, directory: directory);
    final model = (await service.fromPlugin(provider)).single;
    expect(await (await service.materialize(model)).readAsString(), shader);
    expect(await service.resolve(model.key), endsWith('$digest.glsl'));
    expect(await service.network(model.key), isNull);
    store.disabled.add(provider.id);
    await expectLater(service.resolve(model.key), throwsStateError);
  });

  test('URL model survives reload and redirects, sends no auth, and deduplicates by content', () async {
    var requests = 0;
    final service = UpscaleModels(
      directory: directory,
      clientFactory: () => MockClient((request) async {
        requests++;
        expect(request.headers.containsKey('authorization'), false);
        expect(request.headers.containsKey('cookie'), false);
        if (request.url.path == '/redirect') {
          return http.Response('', 302, headers: {'location': 'https://cdn.example/model.glsl'});
        }
        return http.Response(shader, 200);
      }),
    );
    final model = await service.addUrl('https://example.com/redirect', 'Custom');
    expect(requests, 2);
    expect(await (await service.materialize(model)).readAsString(), shader);
    expect((await service.addUrl('https://example.com/model.glsl', '')).name, 'model');
    await service.addUrl('https://example.com/model.glsl', 'Renamed');
    final offline = UpscaleModels(directory: directory, clientFactory: () => throw StateError('offline'));
    final models = (await offline.catalog()).where((m) => m.key.startsWith('url/')).toList();
    expect(models.length, 1);
    expect(models.single.name, 'Renamed');
    expect(await offline.resolve(model.key), endsWith('.glsl'));
    await offline.removeUrl(models.single);
    expect((await offline.catalog()).where((m) => m.key.startsWith('url/')), isEmpty);
  });

  test('unsupported models, insecure redirects and excessive programs are rejected', () async {
    for (final value in [
      '',
      '<html>Not a model</html>',
      'ONNX binary',
      '$shader\n//!TEXTURE external',
      '$shader\n#include "private"',
      '$shader\nvoid bad(){while(true){}}',
      shader.replaceAll('2 *', '100 *'),
      '$shader\n$shader',
    ]) {
      expect(() => validateUpscaleShader(value), throwsFormatException);
    }
    final redirect = UpscaleModels(
      directory: directory,
      clientFactory: () =>
          MockClient((_) async => http.Response('', 302, headers: {'location': 'http://example.com/model'})),
    );
    await expectLater(redirect.addUrl('https://example.com/model', 'Bad'), throwsA(anything));
    final oversized = UpscaleModels(
      directory: directory,
      clientFactory: () => MockClient((_) async => http.Response('x' * (maxUpscaleModelBytes + 1), 200)),
    );
    await expectLater(oversized.addUrl('https://example.com/model', 'Big'), throwsFormatException);
    expect((await SharedPreferences.getInstance()).getStringList('upscaleUrlModels'), isNull);
  });

  test('shader toggles replace only the owned shader and restore previous one after failed replacement', () async {
    final entries = <String>['other.glsl'];
    var fail = true;
    final scaler = UpscaleShader((command) async {
      expect(command.take(2), ['change-list', 'glsl-shaders']);
      if (command[2] == 'append') {
        if (command[3] == 'bad.glsl' && fail) {
          fail = false;
          throw StateError('unsupported shader');
        }
        entries.add(command[3]);
      } else {
        entries.remove(command[3]);
      }
    });
    await scaler.apply('first.glsl');
    await expectLater(scaler.apply('bad.glsl'), throwsStateError);
    expect(entries, ['other.glsl', 'first.glsl']);
    await Future.wait([scaler.apply('next.glsl'), scaler.apply(null)]);
    expect(entries, ['other.glsl']);
  });
  testWidgets('model manager requires an enabled extension and exposes URL entry after installation', (t) async {
    await AppSettings.instance.init();
    final provider = PluginStore.instance.installed.remove('player.ai-upscale')!;
    await t.runAsync(() => UpscaleModels.instance.catalog());
    t.view.physicalSize = const Size(900, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(const MaterialApp(home: UpscaleModelsPage()));
    await t.pumpAndSettle();
    expect(find.text('업스케일 모델 확장앱을 설치하고 켜 주세요'), findsOneWidget);
    expect(find.text('Anime4K CNN S'), findsNothing);
    expect(t.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add_link)).onPressed, isNull);
    PluginStore.instance.installed[provider.id] = provider;
    PluginStore.instance.notifyListeners();
    // The JS runtime owns a native receive port; allow real event dispatch as
    // well as fake-frame timers while its asynchronous catalog call completes.
    for (var i = 0; i < 30 && find.text('Anime4K CNN S').evaluate().isEmpty; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await t.pump(const Duration(milliseconds: 16));
    }
    await t.pumpAndSettle();
    expect(find.text('Anime4K CNN S'), findsOneWidget);
    expect(find.text('Anime4K Denoise CNN S'), findsOneWidget);
    expect(find.text('FSRCNNX 8'), findsOneWidget);
    expect(AppSettings.instance.upscalingModel, 'lanczos');
    expect(PluginStore.instance.installed.keys, ['player.ai-upscale']);
    await t.tap(find.byTooltip('모델 URL 추가'));
    await t.pumpAndSettle();
    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.text('HTTPS .glsl 주소'), findsOneWidget);
    await t.tap(find.text('취소'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
