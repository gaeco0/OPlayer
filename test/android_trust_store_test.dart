import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:oplayer/core/network/android_trust_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(AndroidTrustStore.channel, null));
  test('Android anchors enable valid TLS while untrusted, wrong-host and expired certificates still fail', () async {
    HttpOverrides.global = null;
    final dir = await Directory.systemTemp.createTemp('oplayer_tls_');
    addTearDown(() async {
      final parent = Directory.systemTemp.resolveSymbolicLinksSync();
      final resolved = dir.resolveSymbolicLinksSync();
      expect(resolved.startsWith('$parent${Platform.pathSeparator}'), true);
      await dir.delete(recursive: true);
    });
    final gitOpenSsl = '${Platform.environment['ProgramFiles'] ?? r'C:\Program Files'}/Git/usr/bin/openssl.exe';
    final openssl = Platform.isWindows && File(gitOpenSsl).existsSync() ? gitOpenSsl : 'openssl';
    Future<void> run(List<String> args) async {
      final result = await Process.run(openssl, args, workingDirectory: dir.path);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    }

    // Private keys exist only in this temporary test directory, never the repo.
    for (final name in ['ca', 'other-ca']) {
      await run([
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-sha256',
        '-days',
        '3',
        '-subj',
        '/CN=OPlayer-$name-TEST',
        '-keyout',
        '$name-key.pem',
        '-out',
        '$name.pem',
        '-addext',
        'basicConstraints=critical,CA:TRUE',
        '-addext',
        'keyUsage=critical,keyCertSign,cRLSign',
      ]);
    }
    await run([
      'req',
      '-new',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-subj',
      '/CN=localhost',
      '-keyout',
      'localhost-test-key.pem',
      '-out',
      'localhost.csr',
    ]);
    await File(
      '${dir.path}/server.ext',
    ).writeAsString('basicConstraints=critical,CA:FALSE\nsubjectAltName=DNS:localhost\nextendedKeyUsage=serverAuth\n');
    for (final entry in {'localhost.pem': '2', 'expired-localhost.pem': '-1'}.entries) {
      await run([
        'x509',
        '-req',
        '-in',
        'localhost.csr',
        '-CA',
        'ca.pem',
        '-CAkey',
        'ca-key.pem',
        '-CAcreateserial',
        '-out',
        entry.key,
        '-days',
        entry.value,
        '-sha256',
        '-extfile',
        'server.ext',
      ]);
    }
    final ca = File('${dir.path}/ca.pem').readAsStringSync();
    var current = ca;
    messenger.setMockMethodCallHandler(AndroidTrustStore.channel, (call) async {
      expect(call.method, 'certificates');
      return current;
    });
    final trust = AndroidTrustStore(enabled: true);
    expect(await trust.refresh(), true);
    final first = trust.context;
    expect(await trust.refresh(), false);
    expect(identical(first, trust.context), true);

    Future<HttpServer> server(String leaf) async {
      final context = SecurityContext()
        ..useCertificateChain('${dir.path}/$leaf')
        ..usePrivateKey('${dir.path}/localhost-test-key.pem');
      final s = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
      s.listen((request) {
        request.response.write('verified');
        request.response.close();
      }, onError: (_) {});
      addTearDown(() => s.close(force: true));
      return s;
    }

    final valid = await server('localhost.pem');
    final expired = await server('expired-localhost.pem');
    Future<String> read(HttpServer s, SecurityContext? context, {String host = 'localhost'}) async {
      final client = HttpClient(context: context)..findProxy = (_) => 'DIRECT';
      try {
        final request = await client.getUrl(Uri.parse('https://$host:${s.port}/')).timeout(const Duration(seconds: 5));
        final response = await request.close();
        return await response.transform(const SystemEncoding().decoder).join();
      } finally {
        client.close(force: true);
      }
    }

    expect(await read(valid, trust.context), 'verified');
    await expectLater(read(valid, SecurityContext(withTrustedRoots: false)), throwsA(isA<HandshakeException>()));
    await expectLater(read(valid, trust.context, host: '127.0.0.1'), throwsA(isA<HandshakeException>()));
    await expectLater(read(expired, trust.context), throwsA(isA<HandshakeException>()));
    current = File('${dir.path}/other-ca.pem').readAsStringSync();
    expect(await trust.refresh(), true);
    expect(identical(first, trust.context), false);
    await expectLater(read(valid, trust.context), throwsA(isA<HandshakeException>()));
    current = 'invalid PEM';
    await expectLater(trust.refresh(), throwsA(anything));
    expect(trust.context, null);
  });
  test('non-Android platforms keep their default trust store and do not call the bridge', () async {
    messenger.setMockMethodCallHandler(AndroidTrustStore.channel, (_) async => fail('Unexpected certificate bridge'));
    final trust = AndroidTrustStore(enabled: false);
    expect(await trust.refresh(), false);
    expect(trust.context, null);
  });
}
