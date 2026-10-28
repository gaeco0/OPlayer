// dart run tool/download_responsiveness_probe.dart
// Compare the UI event-loop gap during a 4 MiB HLS AES segment decryption.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';
import 'package:oplayer/features/web/hls.dart';

Future<void> main() async {
  final plain = Uint8List.fromList(List.generate(4 * 1024 * 1024, (i) => i % 251));
  final key = Uint8List.fromList(List.generate(16, (i) => i));
  final iv = Hls.ivForSequence(32);
  final cipher = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
    ..init(true, PaddedBlockCipherParameters(ParametersWithIV(KeyParameter(key), iv), null));
  final encrypted = cipher.process(plain);
  final expected = sha256.convert(plain);
  // Warm the cipher implementation before timing.
  Hls.decryptAes128(encrypted, key, iv);
  final results = <String, Object>{};
  for (final async in [false, true]) {
    final clock = Stopwatch()..start();
    var previous = 0, maximumGap = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 8), (_) {
      final now = clock.elapsedMicroseconds;
      final gap = now - previous;
      if (gap > maximumGap) maximumGap = gap;
      previous = now;
    });
    await Future<void>.delayed(const Duration(milliseconds: 32));
    final processing = Stopwatch()..start();
    final output = async ? await Hls.decryptAes128Async(encrypted, key, iv) : Hls.decryptAes128(encrypted, key, iv);
    processing.stop();
    await Future<void>.delayed(const Duration(milliseconds: 32));
    timer.cancel();
    if (sha256.convert(output) != expected) throw StateError('Decrypted bytes differ');
    results[async ? 'background' : 'ui'] = {
      'processingMs': processing.elapsedMilliseconds,
      'maximumEventLoopGapMs': maximumGap / 1000,
    };
  }
  stdout.writeln(jsonEncode(results));
}
