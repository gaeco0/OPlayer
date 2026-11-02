import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oplayer/core/secure_store.dart';
import 'package:oplayer/sources/cloud/oauth.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const broad = 'https://www.googleapis.com/auth/drive';
  const readonly = 'https://www.googleapis.com/auth/drive.readonly';
  const sync = 'https://www.googleapis.com/auth/drive.appdata';
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  OAuthClient client(List<String> scopes) => OAuthClient(
    authEndpoint: 'https://accounts.google.com/o/oauth2/v2/auth',
    tokenEndpoint: 'https://oauth2.googleapis.com/token',
    clientId: 'test',
    scopes: scopes,
    mobileScheme: 'test',
  );

  test('file authorization accepts only a granted file scope without old broad Drive access', () {
    validateGoogleFileGrant([googleDriveFileScope], [googleDriveFileScope]);
    validateGoogleFileGrant([googleDriveFileScope], [googleDriveFileScope, sync]);
    for (final old in [broad, readonly]) {
      expect(
        () => validateGoogleFileGrant([googleDriveFileScope], [googleDriveFileScope, old]),
        throwsA(contains('기존 전체 Drive')),
      );
    }
    expect(() => validateGoogleFileGrant([googleDriveFileScope], [sync]), throwsA(contains('승인')));
  });

  test('old broad and legacy tokens are not reused; a fresh per-file connection persists normally', () async {
    final token = OAuthTokens(
      accessToken: 'old',
      refreshToken: 'refresh',
      expiry: DateTime.now().add(const Duration(hours: 1)),
    );
    await TokenHolder('broad', client([broad])).save(token);
    await expectLater(TokenHolder('broad', client([googleDriveFileScope])).accessToken(), throwsA(contains('권한이 축소')));
    await SecureStore.instance.writeRequired('legacy', jsonEncode(token.toJson()));
    final narrowed = TokenHolder('legacy', client([googleDriveFileScope]));
    await expectLater(narrowed.accessToken(), throwsA(contains('권한이 축소')));
    await narrowed.save(OAuthTokens(accessToken: 'new', expiry: token.expiry));
    expect(await TokenHolder('legacy', client([googleDriveFileScope])).accessToken(), 'new');
  });

  test('Android requests drive.file and rejects a cumulative old Drive grant', () async {
    const channel = MethodChannel('oplayer/google-drive');
    var granted = [googleDriveFileScope];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      expect((call.arguments as Map)['scopes'], [googleDriveFileScope]);
      return {'accessToken': 'native', 'grantedScopes': granted};
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );
    final native = GoogleAndroidOAuthClient(clientId: 'test');
    expect((await native.authorize()).accessToken, 'native');
    granted = [googleDriveFileScope, broad];
    await expectLater(native.authorize(), throwsA(contains('기존 전체 Drive')));
  });
  test('Android retries a stale cached grant once with token invalidation', () async {
    const channel = MethodChannel('oplayer/google-drive');
    final calls = <Map>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.arguments as Map);
      return {
        'accessToken': calls.length == 1 ? 'stale' : 'fresh',
        'grantedScopes': calls.length == 1 ? [googleDriveFileScope, broad] : [googleDriveFileScope],
      };
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );
    expect((await GoogleAndroidOAuthClient(clientId: 'test').authorize()).accessToken, 'fresh');
    expect(calls, hasLength(2));
    expect(calls.last['invalidateToken'], 'stale');
    expect(calls.last['interactive'], true);
    expect(calls.last['scopes'], [googleDriveFileScope]);
  });

  test('Android persistent broad grants stop after one retry; refresh never loops consent', () async {
    const channel = MethodChannel('oplayer/google-drive');
    var count = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      count++;
      return {
        'accessToken': 'stale',
        'grantedScopes': [googleDriveFileScope, broad],
      };
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );
    final native = GoogleAndroidOAuthClient(clientId: 'test');
    await expectLater(native.authorize(), throwsA(contains('기존 전체 Drive')));
    expect(count, 2);
    count = 0;
    await expectLater(
      native.refresh(OAuthTokens(accessToken: 'old', expiry: DateTime.now())),
      throwsA(contains('기존 전체 Drive')),
    );
    expect(count, 1);
  });
  test('Android Picker is interactive only; silent refresh never opens selection', () async {
    const channel = MethodChannel('oplayer/google-drive');
    final calls = <Map>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.arguments as Map);
      return {
        'accessToken': 'token',
        'grantedScopes': [googleDriveFileScope],
      };
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );
    final client = GoogleAndroidOAuthClient(
      clientId: 'test',
      accountEmail: 'same@example.com',
      extraAuthParams: const {'trigger_onepick': 'true', 'allow_multiple': 'true'},
    );
    final tokens = await client.authorize();
    await client.refresh(tokens);
    expect(calls.first['pickFiles'], true);
    expect(calls.first['email'], 'same@example.com');
    expect(calls.last['pickFiles'], false);
    expect(calls.last['interactive'], false);
  });
}
