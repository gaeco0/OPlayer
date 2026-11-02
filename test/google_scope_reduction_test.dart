import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oplayer/core/secure_store.dart';
import 'package:oplayer/sources/cloud/oauth.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('oplayer/google-drive');
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
  );

  OAuthClient client(List<String> scopes) => OAuthClient(
    authEndpoint: 'https://accounts.google.com/o/oauth2/v2/auth',
    tokenEndpoint: 'https://oauth2.googleapis.com/token',
    clientId: 'test',
    scopes: scopes,
    mobileScheme: 'test',
  );

  test('scope changes and legacy tokens do not trigger app permission policy', () async {
    final token = OAuthTokens(
      accessToken: 'existing',
      expiry: DateTime.now().add(const Duration(hours: 1)),
      grantedScopes: ['https://www.googleapis.com/auth/drive'],
    );
    await TokenHolder('saved', client(token.grantedScopes!)).save(token);
    final holder = TokenHolder('saved', client([googleDriveFileScope]));
    expect(await holder.accessToken(), 'existing');
    expect(await holder.grantedScopes(), token.grantedScopes);
    final legacy = token.toJson()..remove('grantedScopes');
    await SecureStore.instance.writeRequired('legacy', jsonEncode(legacy));
    final old = TokenHolder('legacy', client(['arbitrary.plugin.scope']));
    expect(await old.accessToken(), 'existing');
    expect(await old.grantedScopes(), null);
  });

  test('native auth passes plugin scopes and any granted result without policy retries', () async {
    final calls = <Map>[];
    var granted = <String>['https://www.googleapis.com/auth/drive', 'other.scope'];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.arguments as Map);
      return {'accessToken': 'token', 'grantedScopes': granted};
    });
    final native = GoogleAndroidOAuthClient(
      clientId: 'test',
      requestedScopes: const ['arbitrary.plugin.scope'],
      extraAuthParams: const {'include_granted_scopes': 'true'},
    );
    expect((await native.authorize()).grantedScopes, granted);
    expect(calls, hasLength(1));
    expect(calls.single['scopes'], ['arbitrary.plugin.scope']);
    expect(calls.single['includeGrantedScopes'], true);
    granted = [];
    expect((await native.authorize()).grantedScopes, isEmpty);
    expect(calls, hasLength(2));
    await native.refresh(OAuthTokens(accessToken: 'expired', expiry: DateTime.now()));
    expect(calls.last['invalidateToken'], 'expired');
    expect(calls.last['interactive'], false);
  });

  test('Picker options are plugin controlled and silent refresh does not open Picker', () async {
    final calls = <Map>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.arguments as Map);
      return {
        'accessToken': 'token',
        'grantedScopes': [googleDriveFileScope],
      };
    });
    final native = GoogleAndroidOAuthClient(
      clientId: 'test',
      requestedScopes: const [googleDriveFileScope],
      extraAuthParams: const {'trigger_onepick': 'true', 'allow_multiple': 'true', 'include_granted_scopes': 'false'},
    );
    final tokens = await native.authorize();
    await native.refresh(tokens);
    expect(calls.first['pickFiles'], true);
    expect(calls.first['pickerOptions'], {'allow_multiple': 'true'});
    expect(calls.first['includeGrantedScopes'], false);
    expect(calls.last['pickFiles'], false);
    expect(calls.last.containsKey('pickerOptions'), false);
  });
}
