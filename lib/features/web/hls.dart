import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// HLS(m3u8) 재생목록 파서 — 다운로드용 최소 구현
class HlsVariant {
  HlsVariant(this.uri, this.bandwidth, this.resolution, {this.audioGroup});
  final Uri uri;
  final int bandwidth;
  final String? resolution;
  final String? audioGroup;

  int get pixels {
    final m = RegExp(r'(\d+)x(\d+)').firstMatch(resolution ?? '');
    return m == null ? 0 : int.parse(m[1]!) * int.parse(m[2]!);
  }
}

/// #EXT-X-MEDIA:TYPE=AUDIO (영상과 음성이 분리된 스트림)
class HlsRendition {
  HlsRendition({required this.groupId, this.uri, this.isDefault = false, this.language});
  final String groupId;
  final Uri? uri;
  final bool isDefault;
  final String? language;
}

class HlsMaster {
  HlsMaster(this.variants, this.audios);

  /// 화질 높은 순
  final List<HlsVariant> variants;
  final List<HlsRendition> audios;

  HlsRendition? audioFor(HlsVariant v) {
    final group = audios.where((a) => a.groupId == v.audioGroup && a.uri != null).toList();
    if (group.isEmpty) return null;
    return group.firstWhere((a) => a.isDefault, orElse: () => group.first);
  }
}

class HlsKey {
  HlsKey({required this.method, this.uri, this.iv});
  final String method; // NONE, AES-128, SAMPLE-AES ...
  final Uri? uri;
  final Uint8List? iv;
}

class HlsSegment {
  HlsSegment({required this.uri, required this.sequence, this.key, this.byteRange});
  final Uri uri;
  final int sequence;
  final HlsKey? key;

  /// (length, offset)
  final (int, int)? byteRange;
}

class HlsMediaPlaylist {
  HlsMediaPlaylist({required this.segments, this.initSegment, required this.totalDuration});
  List<HlsSegment> segments;
  final Uri? initSegment; // fMP4 (#EXT-X-MAP)
  final double totalDuration;
  bool get isFmp4 => initSegment != null;
}

class Hls {
  static bool isMaster(String text) => text.contains('#EXT-X-STREAM-INF');

  static Map<String, String> _attrs(String s) {
    final out = <String, String>{};
    final re = RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)');
    for (final m in re.allMatches(s)) {
      var v = m.group(2)!;
      if (v.startsWith('"')) v = v.substring(1, v.length - 1);
      out[m.group(1)!] = v;
    }
    return out;
  }

  static bool isPlaylist(String text) => text.replaceFirst('\uFEFF', '').trimLeft().startsWith('#EXTM3U');

  static HlsMaster parseMasterFull(String text, Uri base) {
    final audios = <HlsRendition>[];
    for (final l in text.split(RegExp(r'\r?\n')).map((l) => l.trim())) {
      if (!l.startsWith('#EXT-X-MEDIA:')) continue;
      final a = _attrs(l.substring(13));
      if (a['TYPE'] != 'AUDIO') continue;
      audios.add(
        HlsRendition(
          groupId: a['GROUP-ID'] ?? '',
          uri: a['URI'] == null ? null : base.resolve(a['URI']!),
          isDefault: a['DEFAULT'] == 'YES',
          language: a['LANGUAGE'],
        ),
      );
    }
    return HlsMaster(parseMaster(text, base), audios);
  }

  static List<HlsVariant> parseMaster(String text, Uri base) {
    final lines = text.split(RegExp(r'\r?\n')).map((l) => l.trim()).toList();
    final out = <HlsVariant>[];
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i].startsWith('#EXT-X-STREAM-INF:')) continue;
      final a = _attrs(lines[i].substring(18));
      var j = i + 1;
      while (j < lines.length && (lines[j].isEmpty || lines[j].startsWith('#'))) {
        j++;
      }
      if (j >= lines.length) break;
      out.add(
        HlsVariant(
          base.resolve(lines[j]),
          int.tryParse(a['BANDWIDTH'] ?? '') ?? 0,
          a['RESOLUTION'],
          audioGroup: a['AUDIO'],
        ),
      );
    }
    // 해상도 우선, 같으면 비트레이트 높은 순
    out.sort((a, b) {
      final r = b.pixels.compareTo(a.pixels);
      return r != 0 ? r : b.bandwidth.compareTo(a.bandwidth);
    });
    return out;
  }

  static HlsMediaPlaylist parseMedia(String text, Uri base) {
    final lines = text.split(RegExp(r'\r?\n')).map((l) => l.trim());
    final segs = <HlsSegment>[];
    var seq = 0;
    HlsKey? key;
    Uri? init;
    double total = 0;
    (int, int)? range;
    var lastRangeEnd = 0;
    var pendingSeg = false;
    for (final l in lines) {
      if (l.isEmpty) continue;
      if (l.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        seq = int.tryParse(l.substring(22)) ?? 0;
      } else if (l.startsWith('#EXT-X-KEY:')) {
        final a = _attrs(l.substring(11));
        final method = a['METHOD'] ?? 'NONE';
        key = method == 'NONE'
            ? null
            : HlsKey(
                method: method,
                uri: a['URI'] == null ? null : base.resolve(a['URI']!),
                iv: a['IV'] == null ? null : _hex(a['IV']!),
              );
      } else if (l.startsWith('#EXT-X-MAP:')) {
        final a = _attrs(l.substring(11));
        if (a['URI'] != null) init = base.resolve(a['URI']!);
      } else if (l.startsWith('#EXTINF:')) {
        total += double.tryParse(l.substring(8).split(',').first) ?? 0;
        pendingSeg = true;
      } else if (l.startsWith('#EXT-X-BYTERANGE:')) {
        final parts = l.substring(17).split('@');
        final len = int.parse(parts[0]);
        final off = parts.length > 1 ? int.parse(parts[1]) : lastRangeEnd;
        range = (len, off);
        lastRangeEnd = off + len;
      } else if (!l.startsWith('#') && pendingSeg) {
        segs.add(HlsSegment(uri: base.resolve(l), sequence: seq, key: key, byteRange: range));
        seq++;
        range = null;
        pendingSeg = false;
      }
    }
    return HlsMediaPlaylist(segments: segs, initSegment: init, totalDuration: total);
  }

  static Uint8List _hex(String s) {
    var h = s.toLowerCase().startsWith('0x') ? s.substring(2) : s;
    h = h.padLeft(32, '0');
    return Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);
  }

  static Uint8List ivForSequence(int seq) {
    final iv = Uint8List(16);
    var v = seq;
    for (var i = 15; i >= 0 && v > 0; i--) {
      iv[i] = v & 0xff;
      v >>= 8;
    }
    return iv;
  }

  /// Standard HLS keys are 16 raw bytes; some sites wrap an encoded key in JSON.
  static Uint8List parseAes128Key(Uint8List body) {
    if (body.length == 16) return body;
    Uint8List? decodeValue(Object? value) {
      if (value is Map) {
        for (final name in ['key', 'aesKey', 'aes_key', 'data', 'result']) {
          if (value.containsKey(name)) {
            final key = decodeValue(value[name]);
            if (key != null) return key;
          }
        }
      } else if (value is List) {
        if (value.length == 16 && value.every((v) => v is int && v >= 0 && v <= 255)) {
          return Uint8List.fromList(value.cast<int>());
        }
      } else if (value is String) {
        final text = value.trim();
        if (RegExp(r'^(?:0[xX])?[0-9a-fA-F]{32}$').hasMatch(text)) {
          return _hex(text);
        }
        try {
          final key = base64.decode(base64.normalize(text));
          if (key.length == 16) return key;
        } on FormatException {
          // Not a base64-encoded key.
        }
      }
      return null;
    }

    Object? value;
    try {
      final text = utf8.decode(body).replaceFirst('\uFEFF', '').trim();
      try {
        value = jsonDecode(text);
      } on FormatException {
        value = text;
      }
    } on FormatException {
      // Neither a raw 16-byte key nor a supported encoded response.
    }
    if (value is Map && (value.containsKey('encrypted_key') || value.containsKey('bytecode_cipher'))) {
      throw const FormatException('사이트 전용 암호화 키 응답입니다. 브라우저에서 영상을 재생해 실제 AES 키를 받은 뒤 다시 시도해 주세요.');
    }
    final key = decodeValue(value);
    if (key != null) return key;
    throw FormatException(
      'HLS AES-128 키 응답을 해석할 수 없습니다 (${body.length}바이트). '
      '16바이트 바이너리 또는 key/data/result 필드의 base64·hex·바이트 배열이 필요합니다. '
      '인증 오류 응답이거나 사이트 고유의 키 형식일 수 있습니다.',
    );
  }

  // Keep network concurrency independent of CPU work: at most two decryptions
  // across all downloads, leaving CPU time for playback and UI.
  static final _decryptTails = [Future<void>.value(), Future<void>.value()];
  static int _decryptLane = 0;
  static Future<Uint8List> decryptAes128Async(Uint8List data, Uint8List key, Uint8List iv) {
    final lane = _decryptLane++ % _decryptTails.length;
    final result = _decryptTails[lane].then((_) {
      final input = TransferableTypedData.fromList([data]);
      return _decryptTransferred(input, key, iv);
    });
    _decryptTails[lane] = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  // Separate scope prevents the worker closure from retaining the source buffer.
  static Future<Uint8List> _decryptTransferred(TransferableTypedData input, Uint8List key, Uint8List iv) =>
      Isolate.run(() => decryptAes128(input.materialize().asUint8List(), key, iv), debugName: 'hls-aes128');

  /// AES-128-CBC + PKCS7
  static Uint8List decryptAes128(Uint8List data, Uint8List key, Uint8List iv) {
    if (key.length != 16) throw const FormatException('HLS AES-128 키는 정확히 16바이트여야 합니다');
    if (iv.length != 16) throw const FormatException('HLS AES-128 IV는 정확히 16바이트여야 합니다');
    final cipher = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
      ..init(false, PaddedBlockCipherParameters(ParametersWithIV(KeyParameter(key), iv), null));
    return cipher.process(data);
  }
}
