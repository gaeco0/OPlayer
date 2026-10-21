import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/app/theme.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/features/player/pip_controller.dart';
import 'package:oplayer/features/web/download_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.init();
  });
  test('homepage only accepts HTTP(S) and theme/output preferences survive reload', () async {
    expect(normalizeHomepage(' example.com/watch '), 'https://example.com/watch');
    expect(normalizeHomepage('http://localhost:8080/'), 'http://localhost:8080/');
    for (final bad in ['', 'javascript:alert(1)', 'file:///secret', 'https://u:p@example.com', 'https://a b']) {
      expect(normalizeHomepage(bad), null);
    }
    final s = AppSettings.instance;
    s.update((v) {
      v.homepage = 'https://example.com/start';
      v.primaryColor = 0xFF654321;
      v.secondaryColor = 0xFF123456;
      v.themeMode = AppThemeMode.light;
      v.outputQuality = OutputQuality.audio;
    });
    await Future<void>.delayed(Duration.zero);
    s.homepage = '';
    s.themeMode = AppThemeMode.dark;
    s.outputQuality = OutputQuality.original;
    await s.init();
    expect(s.homepage, 'https://example.com/start');
    expect(s.themeMode, AppThemeMode.light);
    expect(s.outputQuality, OutputQuality.audio);
    final task = DownloadTask(
      id: 'test',
      url: 'https://example.com/v',
      fileName: 'v.mp4',
      kind: DownloadKind.hls,
      outputQuality: OutputQuality.audio,
    );
    expect(DownloadTask.fromJson(task.toJson()).outputQuality, OutputQuality.audio);
    final old = task.toJson()..remove('quality');
    expect(DownloadTask.fromJson(old).outputQuality, OutputQuality.original);
  });
  testWidgets('semantic colors update with light/dark and primary/secondary', (t) async {
    Future<void> render(Brightness brightness) => t.pumpWidget(
      MaterialApp(
        theme: brightness == Brightness.light ? OTheme.light() : OTheme.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Text('sample', style: TextStyle(color: OColors.of(context).textPrimary)),
          ),
        ),
      ),
    );
    await render(Brightness.light);
    final light = t.widget<Text>(find.text('sample')).style!.color!;
    expect(light.computeLuminance(), lessThan(0.2));
    await render(Brightness.dark);
    await t.pumpAndSettle();
    final dark = t.widget<Text>(find.text('sample')).style!.color!;
    expect(dark.computeLuminance(), greaterThan(0.5));
    AppSettings.instance.primaryColor = 0xFF010203;
    AppSettings.instance.secondaryColor = 0xFF112233;
    expect(OTheme.light().colorScheme.primary, const Color(0xFF010203));
    expect(OTheme.dark().colorScheme.secondary, const Color(0xFF112233));
  });
  test('PiP updates immediately when double tap seek interval changes', () async {
    const channel = MethodChannel('oplayer/pip');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final payloads = <Map>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      payloads.add(call.arguments as Map);
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      PlayerPip.instance.available = false;
    });
    final pip = PlayerPip.instance..available = true;
    AppSettings.instance.doubleTapSeekSeconds = 5;
    await pip.update(enabled: true, playing: true);
    AppSettings.instance.doubleTapSeekSeconds = 30;
    await pip.update(enabled: true, playing: true);
    expect(payloads.map((p) => p['seekSeconds']), [5, 30]);
  });
}
