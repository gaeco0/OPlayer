import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oplayer/core/secure_store.dart';
import 'package:oplayer/core/settings.dart';
import 'package:oplayer/sources/cloud/cloud_config.dart';
import 'package:oplayer/sources/cloud/cloud_sources.dart';
import 'package:oplayer/sources/cloud/oauth.dart';
import 'package:oplayer/sources/server_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.init();
  });

  test('desktop authorization validates state before consuming callback and uses PKCE', () async {
    final tokenServer = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() => tokenServer.close(force: true));
    Uri? authorization;
    tokenServer.listen((request) async {
      final body = Uri.splitQueryString(await utf8.decoder.bind(request).join());
      expect(body['client_id'], 'test-client');
      expect(body.containsKey('client_secret'), false);
      expect(body['code'], 'authorized-code');
      final verifier = body['code_verifier']!;
      final challenge = base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');
      expect(challenge, authorization!.queryParameters['code_challenge']);
      expect(body['redirect_uri'], authorization!.queryParameters['redirect_uri']);
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({'access_token': 'access', 'refresh_token': 'refresh', 'expires_in': 3600}),
      );
      await request.response.close();
    });
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final callbacks = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'canLaunch') return true;
      authorization = Uri.parse((call.arguments as Map)['url'] as String);
      unawaited(
        Future<void>(() async {
          final client = HttpClient()..findProxy = (_) => 'DIRECT';
          try {
            final redirect = Uri.parse(authorization!.queryParameters['redirect_uri']!);
            final wrong = await client.getUrl(
              redirect.replace(queryParameters: {'state': 'forged', 'code': 'bad'}),
            );
            expect((await wrong.close()).statusCode, 400);
            final valid = await client.getUrl(
              redirect.replace(
                queryParameters: {
                  'state': authorization!.queryParameters['state']!,
                  'code': 'authorized-code',
                },
              ),
            );
            expect((await valid.close()).statusCode, 200);
            callbacks.complete();
          } catch (e, st) {
            callbacks.completeError(e, st);
          } finally {
            client.close(force: true);
          }
        }),
      );
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final client = OAuthClient(
      authEndpoint: 'https://login.example/authorize',
      tokenEndpoint: 'http://127.0.0.1:${tokenServer.port}/token',
      clientId: 'test-client',
      scopes: ['Files.Read'],
      mobileScheme: CloudConfig.mobileScheme,
      loopbackHost: 'localhost',
    );
    final tokens = await client.authorize().timeout(const Duration(seconds: 10));
    await callbacks.future;
    expect(tokens.accessToken, 'access');
    expect(tokens.refreshToken, 'refresh');
    expect(tokens.expired, false);
  }, skip: !(Platform.isWindows || Platform.isMacOS || Platform.isLinux));

  test('Dropbox retries 401 once, refreshes token, lists next page and resolves playback', () async {
    final account = CloudAccount(
      id: 'db-test',
      provider: CloudProvider.dropbox,
      name: 'Dropbox',
      oauthClientId: 'bound-key',
    );
    final source = DropboxSource(account);
    await source.tokens.save(
      OAuthTokens(
        accessToken: 'old',
        refreshToken: 'refresh',
        expiry: DateTime.now().add(const Duration(hours: 1)),
      ),
    );
    var refreshes = 0;
    var folderRequests = 0;
    await http.runWithClient(
      () async {
        final files = await source.list('');
        expect(files.map((e) => e.name), ['Folder', 'movie.mp4']);
        final stream = await source.streamFor('/movie.mp4');
        expect(stream.url, 'https://download.example/movie.mp4');
        expect(stream.headers, null);
      },
      () => MockClient((request) async {
        Map<String, Object?> body;
        if (request.url.path == '/oauth2/token') {
          refreshes++;
          expect(request.bodyFields['client_id'], 'bound-key');
          expect(request.bodyFields['grant_type'], 'refresh_token');
          body = {'access_token': 'new', 'expires_in': 3600};
        } else {
          if (request.url.path.endsWith('/list_folder')) {
            folderRequests++;
            if (folderRequests == 1) return http.Response('{}', 401);
            expect(jsonDecode(request.body)['path'], '');
            body = {
              'entries': [
                {'.tag': 'folder', 'name': 'Folder', 'path_lower': '/folder'},
              ],
              'has_more': true,
              'cursor': 'next',
            };
          } else if (request.url.path.endsWith('/continue')) {
            expect(jsonDecode(request.body)['cursor'], 'next');
            body = {
              'entries': [
                {'.tag': 'file', 'name': 'movie.mp4', 'path_lower': '/movie.mp4', 'size': 123},
              ],
              'has_more': false,
            };
          } else {
            body = {'link': 'https://download.example/movie.mp4'};
          }
          expect(request.headers['Authorization'], 'Bearer new');
        }
        return http.Response(jsonEncode(body), 200);
      }),
    );
    expect(refreshes, 1);
    final stored = jsonDecode((await SecureStore.instance.read(account.tokenKey))!);
    expect(stored['r'], 'refresh');
    expect(stored['a'], 'new');
    await source.close();
    await expectLater(source.tokens.accessToken(), throwsA(contains('연결이 해제')));
    await ServerStore.instance.init();
    await ServerStore.instance.saveAccount(account);
    await ServerStore.instance.removeAccount(account);
    expect(await SecureStore.instance.read(account.tokenKey), null);
  });

  test('OneDrive follows folder pages and keeps preauthenticated playback URL header-free', () async {
    final account = CloudAccount(
      id: 'od-test',
      provider: CloudProvider.onedrive,
      name: 'OneDrive',
      oauthClientId: '12345678-1234-1234-1234-123456789abc',
    );
    final source = OneDriveSource(account);
    await source.tokens.save(
      OAuthTokens(
        accessToken: 'token',
        refreshToken: 'refresh',
        expiry: DateTime.now().add(const Duration(hours: 1)),
      ),
    );
    await http.runWithClient(
      () async {
        final entries = await source.list('root');
        expect(entries.map((e) => e.name), ['folder', 'video.mp4']);
        final stream = await source.streamFor('file-id');
        expect(stream.url, 'https://download.example/video.mp4');
        expect(stream.headers, null);
      },
      () => MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer token');
        final Object body = request.url.path.endsWith('/file-id')
            ? {'@microsoft.graph.downloadUrl': 'https://download.example/video.mp4'}
            : request.url.queryParameters['page'] == '2'
            ? {
                'value': [
                  {'id': 'file-id', 'name': 'video.mp4'},
                ],
              }
            : {
                'value': [
                  {'id': 'folder-id', 'name': 'folder', 'folder': {}},
                ],
                '@odata.nextLink': 'https://graph.microsoft.com/v1.0/me/drive/root/children?page=2',
              };
        return http.Response(jsonEncode(body), 200);
      }),
    );
    AppSettings.instance.update((s) => s.oneDriveClientId = 'different-client');
    final restored = CloudAccount.fromJson(account.toJson());
    expect(
      oauthClientFor(restored.provider, clientId: restored.oauthClientId).clientId,
      account.oauthClientId,
    );
    expect(CloudConfig.dropboxRedirect, 'com.oplayer.oplayer://oauth/dropbox');
    expect(CloudConfig.oneDriveRedirect, 'com.oplayer.oplayer://oauth/onedrive');
  });
}
