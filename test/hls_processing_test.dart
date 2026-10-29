import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:oplayer/features/web/hls.dart';

void main() {
  test('background AES preserves segment bytes, padding and key validation', () async {
    final key = Uint8List.fromList(List.generate(16, (i) => i));
    final iv = Hls.ivForSequence(37);
    final plain = Uint8List.fromList(List.generate(128 * 1024 + 7, (i) => i % 251));
    final cipher = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
      ..init(true, PaddedBlockCipherParameters(ParametersWithIV(KeyParameter(key), iv), null));
    final encrypted = cipher.process(plain);
    expect(await Hls.decryptAes128Async(encrypted, key, iv), plain);
    expect(encrypted, isNot(plain));
    await expectLater(Hls.decryptAes128Async(encrypted, Uint8List(15), iv), throwsFormatException);
    await expectLater(Hls.decryptAes128Async(encrypted, key, Uint8List(15)), throwsFormatException);
    await expectLater(Hls.decryptAes128Async(encrypted.sublist(1), key, iv), throwsA(isA<ArgumentError>()));
    final next = await Future.wait(List.generate(4, (_) => Hls.decryptAes128Async(encrypted, key, iv)));
    for (final bytes in next) {
      expect(bytes, plain);
    }
    for (final parallelism in [0, 1, 4, 16]) {
      expect(await Hls.decryptAes128Async(encrypted, key, iv, parallelism: parallelism), plain);
    }
  });
}
