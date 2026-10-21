import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../settings.dart';
import 'bye_dpi.dart';
import 'doh_resolver.dart';
import 'local_proxy.dart';
import 'tunnel_socket.dart';
import 'android_trust_store.dart';

class NetworkService extends ChangeNotifier with WidgetsBindingObserver {
  NetworkService._();
  static final instance = NetworkService._();
  static bool get supported => Platform.isAndroid || Platform.isWindows;
  final _engine = ByeDpi();
  final _trust = AndroidTrustStore();
  LocalProxy? _proxy;
  DohResolver? _resolver;
  String? error;
  bool busy = false;
  bool _doh = false;
  bool _bye = false;
  bool get enabled => _doh || _bye;
  int? get port => _proxy?.port;
  String? get proxyUrl => port == null ? null : 'http://127.0.0.1:$port';

  Future<void> init() async {
    if (!supported || _proxy != null) return;
    await _refreshTrust();
    final bootstrap = _bootstrapClient();
    _resolver = DohResolver(Uri.parse(AppSettings.instance.dohUrl), bootstrap);
    _proxy = LocalProxy(_connect);
    await _proxy!.start();
    HttpOverrides.global = _ProxyOverrides(this);
    WidgetsBinding.instance.addObserver(this);
    _engine.onExit = () {
      error = 'ByeDPI가 종료됐습니다. 끄고 다시 켜 주세요.';
      _proxy?.closeConnections();
      notifyListeners();
    };
    try {
      final s = AppSettings.instance;
      await configure(doh: s.dohEnabled, bye: s.byeDpiEnabled, url: s.dohUrl);
    } catch (e) {
      error = '$e';
      AppSettings.instance.update((s) {
        s.dohEnabled = _doh;
        s.byeDpiEnabled = _bye;
      });
      notifyListeners();
    }
  }

  String findProxy(Uri uri, {bool browser = false}) =>
      port != null &&
          useNetworkProxy(uri, enabled: enabled, browser: browser, resources: AppSettings.instance.networkForResources)
      ? 'PROXY 127.0.0.1:$port'
      : 'DIRECT';

  HttpClient createHttpClient({bool browser = false}) =>
      HttpClient(context: _trust.context)..findProxy = (uri) => findProxy(uri, browser: browser);

  HttpClient _bootstrapClient() => HttpClient(context: _trust.context)
    ..connectionTimeout = const Duration(seconds: 10)
    ..findProxy = (_) => _bye && port != null ? 'PROXY 127.0.0.1:$port' : 'DIRECT';

  Future<void> _refreshTrust() async {
    final before = _trust.context;
    try {
      await _trust.refresh();
    } catch (e) {
      error = 'Android 인증서 저장소 확인 실패: $e';
      notifyListeners();
    } finally {
      if (!identical(before, _trust.context) && _resolver != null) {
        final previous = _resolver!;
        _resolver = DohResolver(previous.endpoint, _bootstrapClient());
        previous.clear();
        previous.client.close();
      }
    }
  }

  String? proxyFor(Uri uri, {bool browser = false}) => findProxy(uri, browser: browser) == 'DIRECT' ? null : proxyUrl;

  Future<TunnelSocket> _connect(String host, int destinationPort) async {
    final local = localNetworkHost(host);
    var addresses = <String>[host];
    if (_doh && !local && host != _resolver!.endpoint.host && InternetAddress.tryParse(host) == null) {
      try {
        addresses = (await _resolver!.lookup(host)).map((a) => a.address).toList();
      } catch (e) {
        error = 'DoH 조회 실패: $e';
        notifyListeners();
        rethrow;
      }
    }
    Object? last;
    for (final address in addresses) {
      try {
        if (_bye && !local && !localNetworkHost(address)) {
          final socksPort = _engine.port;
          if (socksPort == null) throw const SocketException('ByeDPI가 실행되지 않았습니다');
          return await TunnelSocket.socks5('127.0.0.1', socksPort, address, destinationPort);
        }
        return TunnelSocket(await Socket.connect(address, destinationPort, timeout: const Duration(seconds: 10)));
      } catch (e) {
        last = e;
      }
    }
    throw SocketException('서버에 연결할 수 없습니다: $last');
  }

  Future<void> configure({required bool doh, required bool bye, required String url, bool? resources}) async {
    if (busy) throw StateError('네트워크 설정을 적용 중입니다');
    if (!validDohUrl(url)) throw const FormatException('DoH URL은 https://로 시작하는 주소여야 합니다');
    busy = true;
    error = null;
    notifyListeners();
    final oldDoh = _doh, oldBye = _bye;
    final oldUrl = _resolver!.endpoint;
    try {
      if (Platform.isAndroid &&
          (doh || bye) &&
          !await WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)) {
        throw StateError('현재 Android System WebView는 앱 프록시를 지원하지 않습니다. WebView를 업데이트해 주세요.');
      }
      if (bye) await _engine.start();
      _doh = doh;
      _bye = bye;
      _resolver!.endpoint = Uri.parse(url.trim());
      _resolver!.clear();
      if (Platform.isAndroid) {
        if (enabled) {
          await ProxyController.instance().setProxyOverride(
            settings: ProxySettings(
              proxyRules: [ProxyRule(url: proxyUrl!)],
              bypassRules: const ['localhost', '127.0.0.1', '[::1]', '*.local', '*.lan', '*.home.arpa'],
              bypassSimpleHostnames: true,
            ),
          );
        } else if (oldDoh || oldBye) {
          await ProxyController.instance().clearProxyOverride();
        }
      }
      if (!bye) await _engine.stop();
      _proxy!.closeConnections();
      AppSettings.instance.update((s) {
        s.dohEnabled = doh;
        s.byeDpiEnabled = bye;
        s.dohUrl = url.trim();
        if (resources != null) s.networkForResources = resources;
      });
    } catch (e) {
      _doh = oldDoh;
      _bye = oldBye;
      _resolver!.endpoint = oldUrl;
      if (!oldBye) await _engine.stop();
      error = '$e';
      rethrow;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refreshTrust());
    if (state == AppLifecycleState.detached) unawaited(_engine.stop());
  }
}

bool useNetworkProxy(Uri uri, {required bool enabled, required bool browser, required bool resources}) =>
    enabled && (browser || resources) && ['http', 'https'].contains(uri.scheme) && !localNetworkHost(uri.host);

class _ProxyOverrides extends HttpOverrides {
  _ProxyOverrides(this.network);
  final NetworkService network;
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context ?? network._trust.context)..findProxy = network.findProxy;
}
