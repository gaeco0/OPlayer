import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('download CPU choices persist; invalid saved choices retain balanced defaults', () async {
    final settings = AppSettings.instance;
    SharedPreferences.setMockInitialValues({'settings_v1': '{}'});
    await settings.init();
    expect(settings.downloadConversionThreads, -1);
    expect(settings.hlsDecryptionWorkers, 2);
    for (final choice in [0, 1, 4, 16]) {
      settings.update((s) {
        s.downloadConversionThreads = choice;
        s.hlsDecryptionWorkers = choice;
      });
      await settings.init();
      expect(settings.downloadConversionThreads, choice);
      expect(settings.hlsDecryptionWorkers, choice);
    }
    for (final value in [null, '4', true, 4.5, -2, 1000]) {
      SharedPreferences.setMockInitialValues({
        'settings_v1': jsonEncode({'downloadConversionThreads': value, 'hlsDecryptionWorkers': value}),
      });
      await settings.init();
      expect(settings.downloadConversionThreads, -1);
      expect(settings.hlsDecryptionWorkers, 2);
    }
  });
}
