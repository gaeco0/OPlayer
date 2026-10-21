import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

bool validDohUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty && uri.userInfo.isEmpty;
}

class DohResolver {
  DohResolver(this.endpoint, this.client);
  Uri endpoint;
  final HttpClient client;
  final _cache = <String, (DateTime, List<InternetAddress>)>{};
  final _pending = <String, Future<List<InternetAddress>>>{};
  int _generation = 0;
  void clear() {
    _generation++;
    _cache.clear();
    _pending.clear();
  }

  Future<List<InternetAddress>> lookup(String host) async {
    host = host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    final cached = _cache[host];
    if (cached != null && DateTime.now().isBefore(cached.$1)) return cached.$2;
    if (_pending.containsKey(host)) return _pending[host]!;
    final query = _lookup(host);
    _pending[host] = query;
    try {
      return await query;
    } finally {
      if (identical(_pending[host], query)) _pending.remove(host);
    }
  }

  Future<List<InternetAddress>> _lookup(String host) async {
    final generation = _generation;
    final server = endpoint;
    var result = await _query(host, 1, server);
    if (result.$1.isEmpty) result = await _query(host, 28, server);
    final (addresses, ttl) = result;
    if (addresses.isEmpty) throw SocketException('DoH에서 주소를 찾지 못했습니다: $host');
    if (generation == _generation) {
      if (_cache.length >= 256) _cache.remove(_cache.keys.first);
      _cache[host] = (DateTime.now().add(Duration(seconds: ttl.clamp(0, 3600))), addresses);
    }
    return addresses;
  }

  Future<(List<InternetAddress>, int)> _query(String host, int queryType, Uri server) async {
    final id = Random.secure().nextInt(65536);
    final packet = BytesBuilder()..add([id >> 8, id & 255, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
    for (final label in host.split('.')) {
      final bytes = utf8.encode(label);
      if (bytes.isEmpty || bytes.length > 63) throw const FormatException('잘못된 DNS 이름입니다');
      packet.add([bytes.length]);
      packet.add(bytes);
    }
    packet.add([0, 0, queryType, 0, 1]);
    final request = await client.postUrl(server).timeout(const Duration(seconds: 10));
    request.headers.set('Content-Type', 'application/dns-message');
    request.headers.set('Accept', 'application/dns-message');
    request.add(packet.takeBytes());
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw HttpException('DoH 서버 응답: HTTP ${response.statusCode}');
    }
    final body = await response
        .fold<BytesBuilder>(BytesBuilder(), (builder, bytes) {
          if (builder.length + bytes.length > 65535) throw const FormatException('DoH 응답이 너무 큽니다');
          return builder..add(bytes);
        })
        .timeout(const Duration(seconds: 10));
    return parseResponse(body.takeBytes(), id);
  }

  static (List<InternetAddress>, int) parseResponse(Uint8List bytes, int expectedId) {
    if (bytes.length < 12) throw const FormatException('잘못된 DoH 응답입니다');
    final data = ByteData.sublistView(bytes);
    int u16(int offset) => data.getUint16(offset, Endian.big);
    if (u16(0) != expectedId || (bytes[2] & 128) == 0 || (bytes[2] & 2) != 0 || (bytes[3] & 15) != 0) {
      throw const FormatException('DoH 응답 ID 또는 상태가 올바르지 않습니다');
    }
    int skipName(int offset) {
      while (offset < bytes.length) {
        final length = bytes[offset++];
        if (length == 0) return offset;
        if ((length & 192) == 192) {
          if (offset >= bytes.length) break;
          return offset + 1;
        }
        if (length > 63 || offset + length > bytes.length) break;
        offset += length;
      }
      throw const FormatException('잘못된 DNS 이름 응답입니다');
    }

    var offset = 12;
    for (var q = 0; q < u16(4); q++) {
      offset = skipName(offset) + 4;
      if (offset > bytes.length) throw const FormatException('잘린 DNS 질문입니다');
    }
    final addresses = <InternetAddress>[];
    var ttl = 3600;
    for (var a = 0; a < u16(6); a++) {
      offset = skipName(offset);
      if (offset + 10 > bytes.length) throw const FormatException('잘린 DNS 응답입니다');
      final type = u16(offset),
          klass = u16(offset + 2),
          recordTtl = data.getUint32(offset + 4, Endian.big),
          length = u16(offset + 8);
      offset += 10;
      if (offset + length > bytes.length) throw const FormatException('잘린 DNS 주소입니다');
      if (klass == 1 && ((type == 1 && length == 4) || (type == 28 && length == 16))) {
        addresses.add(InternetAddress.fromRawAddress(Uint8List.sublistView(bytes, offset, offset + length)));
        ttl = min(ttl, recordTtl);
      }
      offset += length;
    }
    return (addresses, ttl);
  }
}
