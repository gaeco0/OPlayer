import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../core/secure_store.dart';
import 'cloud_config.dart';

class OAuthTokens {
  OAuthTokens({required this.accessToken, this.refreshToken, required this.expiry});
  String accessToken;
  String? refreshToken;
  DateTime expiry;

  bool get expired => DateTime.now().isAfter(expiry.subtract(const Duration(minutes: 2)));

  Map<String, dynamic> toJson() => {'a': accessToken, 'r': refreshToken, 'e': expiry.millisecondsSinceEpoch};
  static OAuthTokens fromJson(Map<String, dynamic> j) => OAuthTokens(
    accessToken: j['a'] as String,
    refreshToken: j['r'] as String?,
    expiry: DateTime.fromMillisecondsSinceEpoch(j['e'] as int),
  );
}

/// OAuth 2.0 Authorization Code + PKCE.
/// · Windows/macOS: 시스템 브라우저 + 127.0.0.1 루프백 서버
/// · Android/iOS: flutter_web_auth_2 (Custom Tabs / ASWebAuthenticationSession) + 커스텀 스킴
class OAuthClient {
  OAuthClient({
    required this.authEndpoint,
    required this.tokenEndpoint,
    required this.clientId,
    this.clientSecret,
    this.clientSecretKey,
    this.clientSecretFallbackKey,
    required this.scopes,
    required this.mobileScheme,
    this.mobileRedirectUri,
    this.extraAuthParams = const {},
    this.loopbackHost = '127.0.0.1',
    this.usePkce = true,
    this.loopbackOnMobile = false,
  });

  final String authEndpoint;
  final String tokenEndpoint;
  final String clientId;
  final String? clientSecret;
  final String? clientSecretKey;
  final String? clientSecretFallbackKey;
  final List<String> scopes;

  /// 모바일 리디렉션 스킴 (예: com.googleusercontent.apps.XXX, db-APPKEY, msalCLIENTID)
  final String mobileScheme;
  final String? mobileRedirectUri;
  final Map<String, String> extraAuthParams;
  final String loopbackHost;
  final bool usePkce;
  final bool loopbackOnMobile;

  static bool get _desktop => Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  bool get _useLoopback => _desktop || loopbackOnMobile;

  String get redirectUri => _useLoopback
      ? 'http://$loopbackHost:${CloudConfig.loopbackPort}/callback'
      : mobileRedirectUri ??
            (mobileScheme.startsWith('msal')
                ? '$mobileScheme://auth'
                : mobileScheme.startsWith('db-')
                ? '$mobileScheme://oauth'
                : '$mobileScheme:/oauth');

  static bool _authorizing = false;

  static String _randomString(int len) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final r = Random.secure();
    return List.generate(len, (_) => chars[r.nextInt(chars.length)]).join();
  }

  Future<OAuthTokens> authorize() async {
    if (_authorizing) throw '이미 로그인 중입니다. 열린 로그인 창을 완료하거나 닫아 주세요.';
    _authorizing = true;
    try {
      return await _authorize();
    } finally {
      _authorizing = false;
    }
  }

  Future<OAuthTokens> _authorize() async {
    if (clientId.isEmpty) {
      throw '클라우드 앱 등록 정보가 없습니다. 설정에서 앱 등록 정보를 입력해 주세요.';
    }
    final verifier = _randomString(64);
    final challenge = base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');
    final state = _randomString(24);
    final url = Uri.parse(authEndpoint).replace(
      queryParameters: {
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'response_type': 'code',
        if (scopes.isNotEmpty) 'scope': scopes.join(' '),
        if (usePkce) 'code_challenge': challenge,
        if (usePkce) 'code_challenge_method': 'S256',
        'state': state,
        ...extraAuthParams,
      },
    );

    final Uri callback;
    if (_useLoopback) {
      callback = await _loopback(url);
    } else {
      final result = await FlutterWebAuth2.authenticate(url: url.toString(), callbackUrlScheme: mobileScheme);
      callback = Uri.parse(result);
    }
    final expected = Uri.parse(redirectUri);
    if (callback.path != expected.path ||
        (!_useLoopback && (callback.scheme != expected.scheme || callback.host != expected.host))) {
      throw '잘못된 로그인 복귀 주소입니다';
    }
    if (callback.queryParameters['state'] != state) throw '잘못된 응답(state 불일치)';
    final err = callback.queryParameters['error'];
    if (err != null) throw '로그인 취소/실패: $err';
    final code = callback.queryParameters['code'];
    if (code == null || code.isEmpty) throw '인증 코드가 없습니다';

    return _token({
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': redirectUri,
      if (usePkce) 'code_verifier': verifier,
    });
  }

  Future<Uri> _loopback(Uri authUrl) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, CloudConfig.loopbackPort);
    try {
      if (!await launchUrl(authUrl, mode: LaunchMode.externalApplication)) {
        throw '브라우저를 열 수 없습니다';
      }
      await for (final req in server.timeout(const Duration(minutes: 5))) {
        if (req.uri.path != '/callback') {
          req.response.statusCode = 404;
          await req.response.close();
          continue;
        }
        if (req.uri.queryParameters['state'] != authUrl.queryParameters['state']) {
          req.response.statusCode = 400;
          await req.response.close();
          continue;
        }
        req.response
          ..headers.contentType = ContentType.html
          ..headers.set('Cache-Control', 'no-store')
          ..write(
            '<!doctype html><meta charset="utf-8"><title>OPlayer</title>'
            '<body style="font-family:sans-serif;background:#121214;color:#eee;display:flex;'
            'align-items:center;justify-content:center;height:100vh">'
            '<div><h2>로그인 응답을 받았습니다</h2><p>앱으로 돌아가 연결 결과를 확인하세요.</p></div>',
          );
        await req.response.close();
        return req.uri;
      }
      throw '로그인 시간이 초과되었습니다';
    } on TimeoutException {
      throw '로그인 시간이 초과되었습니다';
    } finally {
      await server.close(force: true);
    }
  }

  Future<OAuthTokens> refresh(OAuthTokens t) async {
    if (t.refreshToken == null) throw '다시 로그인이 필요합니다';
    final n = await _token({'grant_type': 'refresh_token', 'refresh_token': t.refreshToken!});
    n.refreshToken ??= t.refreshToken; // 일부 서비스는 refresh_token을 다시 주지 않음
    return n;
  }

  Future<OAuthTokens> _token(Map<String, String> params) async {
    final secret =
        (clientSecretKey == null ? clientSecret : await SecureStore.instance.readRequired(clientSecretKey!)) ??
        (clientSecretFallbackKey == null ? null : await SecureStore.instance.readRequired(clientSecretFallbackKey!));
    final client = http.Client();
    final http.Response res;
    try {
      final request = http.Request('POST', Uri.parse(tokenEndpoint))
        ..followRedirects = false
        ..bodyFields = {
          'client_id': clientId,
          if (secret != null && secret.isNotEmpty) 'client_secret': secret,
          ...params,
        };
      res = await http.Response.fromStream(
        await client.send(request).timeout(const Duration(seconds: 30)),
      ).timeout(const Duration(seconds: 30));
    } finally {
      client.close();
    }
    final Map<String, dynamic> j;
    try {
      j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw '토큰 서버에서 잘못된 응답을 받았습니다 (HTTP ${res.statusCode})';
    }
    if (res.statusCode >= 300 || j['access_token'] == null) {
      throw '토큰 발급 실패: ${j['error_description'] ?? j['error'] ?? res.statusCode}';
    }
    if (j['access_token'] is! String || (j['access_token'] as String).isEmpty) throw '발급된 액세스 토큰이 비어 있습니다';
    return OAuthTokens(
      accessToken: j['access_token'] as String,
      refreshToken: j['refresh_token'] as String?,
      expiry: DateTime.now().add(Duration(seconds: int.tryParse('${j['expires_in']}') ?? 3600)),
    );
  }
}

/// Android Google authorization uses Play services, not deprecated loopback/custom-scheme OAuth.
class GoogleAndroidOAuthClient extends OAuthClient {
  GoogleAndroidOAuthClient({required super.clientId, this.accountEmail})
    : super(
        authEndpoint: 'https://accounts.google.com/o/oauth2/v2/auth',
        tokenEndpoint: 'https://oauth2.googleapis.com/token',
        scopes: const ['https://www.googleapis.com/auth/drive.readonly'],
        mobileScheme: CloudConfig.mobileScheme,
      );

  final String? accountEmail;
  static const channel = MethodChannel('oplayer/google-drive');

  Future<OAuthTokens> _authorizeNative(bool interactive, [String? invalidateToken]) async {
    final result = await channel.invokeMapMethod<String, dynamic>('authorize', {
      'interactive': interactive,
      'email': accountEmail,
      'invalidateToken': invalidateToken,
    });
    final access = result?['accessToken'];
    if (access is! String || access.isEmpty) throw 'Google Drive 인증 응답이 비어 있습니다';
    return OAuthTokens(accessToken: access, expiry: DateTime.now().add(const Duration(minutes: 50)));
  }

  @override
  Future<OAuthTokens> authorize() => _authorizeNative(true);

  @override
  Future<OAuthTokens> refresh(OAuthTokens t) => _authorizeNative(false, t.accessToken);
}

/// 계정별 토큰 보관 + 자동 갱신
class TokenHolder {
  TokenHolder(this.storageKey, this.client);
  final String storageKey;
  final OAuthClient client;
  OAuthTokens? _t;
  Future<OAuthTokens>? _refreshing;
  bool _closed = false;

  void close() {
    _closed = true;
    _t = null;
  }

  Future<void> save(OAuthTokens t) async {
    if (_closed) throw '계정 연결이 해제되었습니다';
    await SecureStore.instance.writeRequired(storageKey, jsonEncode(t.toJson()));
    if (_closed) {
      await SecureStore.instance.writeRequired(storageKey, null);
      throw '계정 연결이 해제되었습니다';
    }
    _t = t;
  }

  Future<String> accessToken({bool forceRefresh = false}) async {
    if (_closed) throw '계정 연결이 해제되었습니다';
    if (_t == null) {
      final raw = await SecureStore.instance.read(storageKey);
      if (raw == null) throw '다시 로그인이 필요합니다';
      _t = OAuthTokens.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    }
    if (forceRefresh || _t!.expired) {
      _refreshing ??= client
          .refresh(_t!)
          .then((n) async {
            await save(n);
            return n;
          })
          .whenComplete(() => _refreshing = null);
      await _refreshing;
    }
    return _t!.accessToken;
  }

  Future<Map<String, String>> authHeader({bool forceRefresh = false}) async => {
    'Authorization': 'Bearer ${await accessToken(forceRefresh: forceRefresh)}',
  };
}
