import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One subscription covers both the SOCKS handshake and the following tunnel.
class TunnelSocket {
  TunnelSocket(this.socket) : _reader = StreamIterator(socket);
  final Socket socket;
  final StreamIterator<Uint8List> _reader;
  List<int> _pending = [];
  int _offset = 0;
  bool _closed = false;
  Future<String> readHeader() async {
    final bytes = <int>[];
    while (bytes.length < 65536) {
      bytes.add((await read(1))[0]);
      final n = bytes.length;
      if (n >= 4 && bytes[n - 4] == 13 && bytes[n - 3] == 10 && bytes[n - 2] == 13 && bytes[n - 1] == 10) {
        return latin1.decode(bytes);
      }
    }
    throw const FormatException('프록시 요청 헤더가 너무 큽니다');
  }

  Future<Uint8List> read(int length) async {
    final result = BytesBuilder();
    while (result.length < length) {
      if (_offset == _pending.length) {
        if (!await _reader.moveNext().timeout(const Duration(seconds: 15))) {
          throw const SocketException('프록시 연결이 종료됐습니다');
        }
        _pending = _reader.current;
        _offset = 0;
      }
      final needed = length - result.length;
      final available = _pending.length - _offset;
      final take = needed < available ? needed : available;
      result.add(_pending.sublist(_offset, _offset + take));
      _offset += take;
    }
    return result.takeBytes();
  }

  Stream<List<int>> get stream async* {
    if (_offset < _pending.length) {
      yield _pending.sublist(_offset);
      _pending = [];
      _offset = 0;
    }
    while (await _reader.moveNext()) {
      yield _reader.current;
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _reader.cancel();
    socket.destroy();
  }

  static Future<TunnelSocket> socks5(String proxyHost, int proxyPort, String host, int port) async {
    final tunnel = TunnelSocket(
      await Socket.connect(proxyHost, proxyPort, timeout: const Duration(seconds: 10)),
    );
    try {
      tunnel.socket.add([5, 1, 0]);
      final greeting = await tunnel.read(2);
      if (greeting[0] != 5 || greeting[1] != 0) throw const SocketException('ByeDPI SOCKS 인증 협상에 실패했습니다');
      final address = InternetAddress.tryParse(host);
      final bytes = address?.rawAddress ?? utf8.encode(host);
      if (address == null && bytes.length > 255) throw const SocketException('프록시 호스트 이름이 너무 깁니다');
      tunnel.socket.add([
        5,
        1,
        0,
        address == null
            ? 3
            : address.type == InternetAddressType.IPv4
            ? 1
            : 4,
        if (address == null) bytes.length,
        ...bytes,
        port >> 8,
        port & 255,
      ]);
      final reply = await tunnel.read(4);
      if (reply[0] != 5 || reply[1] != 0) throw SocketException('ByeDPI SOCKS 연결 실패 (${reply[1]})');
      final addressLength = switch (reply[3]) {
        1 => 4,
        4 => 16,
        3 => (await tunnel.read(1))[0],
        _ => throw const SocketException('잘못된 SOCKS 응답입니다'),
      };
      await tunnel.read(addressLength + 2);
      return tunnel;
    } catch (_) {
      tunnel.close();
      rethrow;
    }
  }
}
