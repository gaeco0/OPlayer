import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/app_release.dart';
import 'package:oplayer/core/app_updater.dart';
import 'package:oplayer/features/settings/app_update_page.dart';

Map<String, Object?> releaseJson(String version, {List<int> body = const [1, 2, 3]}) {
  final filename = 'OPlayer-$version-android-mobile-arm64-v8a.apk';
  Map<String, Object?> asset(String name, int size) => {
    'name': name,
    'size': size,
    'browser_download_url': 'https://github.com/gaeco0/OPlayer/releases/download/v$version/$name',
  };
  return {
    'tag_name': 'v$version',
    'draft': false,
    'prerelease': version.contains('-'),
    'body': 'Changes',
    'assets': [asset(filename, body.length), asset('SHA256SUMS.txt', 200)],
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('release versions order stage promotions and numeric identifiers and isolate channels', () {
    final beta2 = AppVersion.parse('v0.1.7-beta.2+2')!;
    expect(beta2.compareTo(AppVersion.parse('0.1.7-beta.10')!), lessThan(0));
    expect(beta2.compareTo(AppVersion.parse('0.1.7')!), lessThan(0));
    expect(beta2.compareTo(AppVersion.parse('0.1.7-nightly.20261023.2')!), greaterThan(0));
    expect(AppVersion.parse('0.1.6')!.compareTo(AppVersion.parse('0.1.7-nightly.1')!), lessThan(0));
    expect(AppVersion.parse('0.1.7-rc.1'), isNull);
    expect(AppVersion.parse('0.1.7-beta..1'), isNull);
    final releases = [
      '0.1.7',
      '0.1.8-nightly.1',
      '0.1.7-beta.10',
      '0.1.7-beta.2',
    ].map((v) => AppRelease.parse(releaseJson(v))!).toList();
    expect(latestRelease(releases, UpdateChannel.beta)!.version.name, '0.1.7-beta.10');
    expect(latestRelease(releases, UpdateChannel.stable)!.version.name, '0.1.7');
  });

  test('release parser rejects drafts and foreign assets; selects ABI and TV separately', () {
    final data = releaseJson('0.1.7');
    expect(AppRelease.parse({...data, 'draft': true}), isNull);
    expect(AppRelease.parse({...data, 'prerelease': true}), isNull);
    final assets = data['assets'] as List;
    final first = assets.first as Map;
    final malicious = {...first, 'browser_download_url': 'https://github.com/other/repo/file.apk'};
    final parsed = AppRelease.parse({
      ...data,
      'assets': [malicious, assets.last],
    })!;
    expect(parsed.assetFor('android', abis: ['arm64-v8a']), isNull);
    final valid = AppRelease.parse(data)!;
    expect(valid.assetFor('android', abis: ['x86_64', 'arm64-v8a']), isNotNull);
    expect(valid.assetFor('android', tv: true, abis: ['arm64-v8a']), isNull);
    expect(valid.assetFor('windows-x64'), isNull);
    final desktops = AppRelease.parse({
      ...data,
      'assets': [
        assets.last,
        for (final target in ['windows-arm64.zip', 'linux-arm64.tar.gz'])
          {
            'name': 'OPlayer-0.1.7-$target',
            'size': 100,
            'browser_download_url': 'https://github.com/gaeco0/OPlayer/releases/download/v0.1.7/OPlayer-0.1.7-$target',
          },
      ],
    })!;
    expect(desktops.assetFor('windows-arm64')!.name, endsWith('windows-arm64.zip'));
    expect(desktops.assetFor('linux-arm64')!.name, endsWith('linux-arm64.tar.gz'));
    expect(desktops.assetFor('windows-x64'), isNull);
  });

  test('build defaults to nightly but update selection defaults to stable and preserves user choice', () async {
    final updater = AppUpdater();
    expect(updater.installedChannel, UpdateChannel.nightly);
    final configured = AppUpdater(installedVersion: '0.1.7-nightly.1');
    await configured.init();
    expect(configured.installedChannel, UpdateChannel.nightly);
    expect(configured.channel, UpdateChannel.stable);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('appUpdateChannel', 'nightly');
    final saved = AppUpdater(installedVersion: '0.1.7-nightly.1');
    await saved.init();
    expect(saved.channel, UpdateChannel.nightly);
    updater.dispose();
    configured.dispose();
    saved.dispose();
  });

  for (final stableVersion in ['0.1.6', '0.1.7']) {
    test('nightly defaults to stable without offering older stable $stableVersion', () async {
      final updater = AppUpdater(
        installedVersion: '0.1.7-nightly.20261023.2',
        clientFactory: () => MockClient((request) async {
          expect(request.url.path.endsWith('/latest'), isTrue);
          return http.Response(jsonEncode(releaseJson(stableVersion)), 200);
        }),
      );
      await updater.check(force: true);
      expect(updater.channel, UpdateChannel.stable);
      expect(updater.available, stableVersion == '0.1.7');
      updater.dispose();
    });
  }

  test('nightly advances to beta while an older stage never triggers a downgrade notification', () async {
    final updater = AppUpdater(
      installedVersion: '0.1.7-nightly.20261023.2',
      clientFactory: () => MockClient((request) async => http.Response(jsonEncode([releaseJson('0.1.7-beta.1')]), 200)),
    );
    await updater.setChannel(UpdateChannel.beta);
    expect(updater.available, isTrue);
    updater.dispose();
    final stable = AppUpdater(
      installedVersion: '0.1.7',
      clientFactory: () =>
          MockClient((request) async => http.Response(jsonEncode([releaseJson('0.1.7-nightly.20261023.3')]), 200)),
    );
    await stable.setChannel(UpdateChannel.nightly);
    expect(stable.available, isFalse);
    stable.dispose();
  });

  test('automatic check throttles, never downloads and stable excludes prereleases', () async {
    var requests = 0;
    final updater = AppUpdater(
      installedVersion: '0.1.6',
      target: 'android',
      abis: ['arm64-v8a'],
      clientFactory: () => MockClient((request) async {
        requests++;
        expect(request.url.path.endsWith('/latest'), isTrue);
        return http.Response(jsonEncode(releaseJson('0.1.7')), 200);
      }),
    );
    await updater.check();
    await updater.check();
    expect(requests, 1);
    expect(updater.available, isTrue);
    expect(updater.verifiedFile, isNull);
    await updater.setAutomatic(false);
    await updater.check();
    expect(requests, 1);
    await updater.check(force: true);
    expect(requests, 2);
    updater.dispose();
  });

  test('channel change ignores a stale response and persists the selected channel', () async {
    final pending = Completer<http.Response>();
    final updater = AppUpdater(
      installedVersion: '0.1.6',
      clientFactory: () => MockClient((r) {
        if (r.url.path.endsWith('/latest')) return pending.future;
        return Future.value(
          http.Response(jsonEncode([releaseJson('0.1.7-beta.1'), releaseJson('0.1.8-nightly.1')]), 200),
        );
      }),
    );
    final original = updater.check(force: true);
    while (!updater.checking) {
      await Future<void>.delayed(Duration.zero);
    }
    await updater.setChannel(UpdateChannel.beta);
    pending.complete(http.Response(jsonEncode(releaseJson('0.1.9')), 200));
    await original;
    expect(updater.release!.version.name, '0.1.7-beta.1');
    expect((await SharedPreferences.getInstance()).getString('appUpdateChannel'), 'beta');
    updater.dispose();
  });

  for (final corrupt in [false, true]) {
    test('download verifies SHA256 and cleans partial files (corrupt=$corrupt)', () async {
      final dir = await Directory.systemTemp.createTemp('oplayer-update-test-');
      final bytes = [1, 2, 3];
      final filename = 'OPlayer-0.1.7-android-mobile-arm64-v8a.apk';
      final updater = AppUpdater(
        installedVersion: '0.1.6',
        target: 'android',
        abis: ['arm64-v8a'],
        cacheDirectory: () async => dir,
        clientFactory: () => MockClient((r) async {
          if (r.url.host == 'api.github.com') return http.Response(jsonEncode(releaseJson('0.1.7')), 200);
          if (r.url.path.endsWith('SHA256SUMS.txt')) return http.Response('${sha256.convert(bytes)}  $filename\n', 200);
          return http.Response.bytes(corrupt ? [3, 2, 1] : bytes, 200);
        }),
      );
      try {
        await updater.check(force: true);
        await updater.download();
        expect(updater.verifiedFile != null, !corrupt);
        expect(updater.error != null, corrupt);
        expect(dir.listSync(recursive: true).whereType<File>().any((f) => f.path.endsWith('.part')), isFalse);
        if (!corrupt) expect(await updater.verifiedFile!.readAsBytes(), bytes);
      } finally {
        updater.dispose();
        await dir.delete(recursive: true);
      }
    });
  }

  test('redirect to another origin cannot supply update metadata', () async {
    var calls = 0;
    final updater = AppUpdater(
      installedVersion: '0.1.6',
      clientFactory: () => MockClient((r) async {
        calls++;
        return http.Response('', 302, headers: {'location': 'https://example.com/releases'});
      }),
    );
    await updater.check(force: true);
    expect(calls, 1);
    expect(updater.error, contains('허용하지 않는'));
    expect(updater.available, isFalse);
    updater.dispose();
  });

  test('cancelled streaming download removes the partial file', () async {
    final dir = await Directory.systemTemp.createTemp('oplayer-update-cancel-');
    final stream = StreamController<List<int>>();
    const filename = 'OPlayer-0.1.7-android-mobile-arm64-v8a.apk';
    final updater = AppUpdater(
      installedVersion: '0.1.6',
      target: 'android',
      abis: ['arm64-v8a'],
      cacheDirectory: () async => dir,
      clientFactory: () => MockClient.streaming((r, body) async {
        if (r.url.host == 'api.github.com') {
          return http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(releaseJson('0.1.7')))), 200);
        }
        if (r.url.path.endsWith('SHA256SUMS.txt')) {
          return http.StreamedResponse(Stream.value(utf8.encode('${sha256.convert([1, 2, 3])}  $filename\n')), 200);
        }
        stream.add([1]);
        return http.StreamedResponse(stream.stream, 200, contentLength: 3);
      }),
    );
    try {
      await updater.check(force: true);
      final pending = updater.download();
      while (updater.received == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      updater.cancelDownload();
      stream.add([2, 3]);
      await pending;
      expect(updater.verifiedFile, isNull);
      expect(updater.phase, '다운로드 취소됨');
      expect(dir.listSync(recursive: true).whereType<File>(), isEmpty);
    } finally {
      await stream.close();
      updater.dispose();
      await dir.delete(recursive: true);
    }
  });

  testWidgets('update settings displays saved channel and manual check result', (tester) async {
    SharedPreferences.setMockInitialValues({'appUpdateChannel': 'beta', 'appUpdateAutomatic': false});
    final updater = AppUpdater(
      installedVersion: '0.1.6',
      clientFactory: () => MockClient((r) async => http.Response('[]', 200)),
    );
    await tester.pumpWidget(MaterialApp(home: AppUpdatePage(updater: updater)));
    await tester.pumpAndSettle();
    expect(find.text('beta'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isFalse);
    expect(find.text('지금 확인'), findsOneWidget);
    await tester.runAsync(() => updater.check(force: true));
    await tester.pumpAndSettle();
    expect(updater.checking, isFalse);
    expect(find.text('선택한 채널에 배포된 업데이트가 없습니다.'), findsOneWidget);
    expect(updater.verifiedFile, isNull);
    await tester.pumpWidget(const SizedBox());
    updater.dispose();
  });
}
