import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'tunnel_socket.dart';

bool localNetworkHost(String host) {
  host = host.toLowerCase().replaceAll(RegExp(r'^\[|\]$'), '');
  if (host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local') ||
      host.endsWith('.home.arpa') ||
      host.endsWith('.lan')) {
    return true;
  }
  final ip = InternetAddress.tryParse(host);
  if (ip == null) return !host.contains('.');
  if (ip.isLoopback || ip.isLinkLocal) return true;
  final b = ip.rawAddress;
  if (b.length == 16 && b.take(10).every((x) => x == 0) && b[10] == 255 && b[11] == 255) {
    return localNetworkHost(b.skip(12).join('.'));
  }
  if (b.length == 4) {
    return b[0] == 0 ||
        b[0] == 10 ||
        b[0] == 127 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168);
  }
  return (b[0] & 254) == 252;
}

/// Loopback HTTP proxy. CONNECT tunnels preserve end-to-end TLS and browser headers.
class LocalProxy {
  LocalProxy(this.connect);
  final Future<TunnelSocket> Function(String host, int port) connect;
  ServerSocket? _server;
  final _connections = <TunnelSocket>{};
  int get port => _server!.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((socket) => unawaited(_handle(socket)));
  }

  Future<void> _handle(Socket socket) async {
    final downstream = TunnelSocket(socket);
    _connections.add(downstream);
    TunnelSocket? upstream;
    var connected = false;
    try {
      final header = await downstream.readHeader().timeout(const Duration(seconds: 20));
      final lines = header.split('\r\n');
      final first = lines.first.split(' ');
      if (first.length != 3 || !first[2].startsWith('HTTP/1.')) throw const FormatException('잘못된 프록시 요청');
      final isConnect = first[0] == 'CONNECT';
      final uri = Uri.parse(isConnect ? 'https://${first[1]}' : first[1]);
      if (uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          (!isConnect && uri.scheme != 'http') ||
          (isConnect && uri.path.isNotEmpty) ||
          uri.port < 1 ||
          uri.port > 65535) {
        throw const FormatException('잘못된 프록시 주소');
      }
      upstream = await connect(uri.host, uri.port).timeout(const Duration(seconds: 25));
      _connections.add(upstream);
      if (isConnect) {
        socket.add(ascii.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
      } else {
        final path = uri.path.isEmpty ? '/' : uri.path;
        final target = uri.hasQuery ? '$path?${uri.query}' : path;
        final fields = lines.skip(1).where((line) {
          final name = line.split(':').first.toLowerCase();
          return line.isNotEmpty &&
              name != 'connection' &&
              name != 'proxy-connection' &&
              name != 'proxy-authorization';
        });
        upstream.socket.add(
          latin1.encode(
            '${first[0]} $target ${first[2]}\r\n${fields.join('\r\n')}\r\nConnection: close\r\n\r\n',
          ),
        );
      }
      connected = true;
      final remote = upstream;
      Future<void> pipe(TunnelSocket from, TunnelSocket to) async {
        await to.socket.addStream(from.stream);
        await to.socket.flush();
      }

      // Both futures own error handlers; closing either side cancels the other direction.
      await Future.any([pipe(downstream, remote), pipe(remote, downstream)]);
    } catch (_) {
      if (!connected) {
        try {
          socket.add(
            ascii.encode('HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\nContent-Length: 0\r\n\r\n'),
          );
          await socket.flush();
        } catch (_) {}
      }
    } finally {
      downstream.close();
      upstream?.close();
      _connections.remove(downstream);
      _connections.remove(upstream);
    }
  }

  void closeConnections() {
    for (final connection in _connections.toList()) {
      connection.close();
    }
    _connections.clear();
  }

  Future<void> close() async {
    await _server?.close();
    closeConnections();
  }
}
